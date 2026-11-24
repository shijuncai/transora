import Foundation
import CoreGraphics

/// Similarity Analyzer：把「看起来还行」翻译成「可计算的结论」。
///
/// 七项检查分两类，不能混为一谈：
///     **硬约束**（R1 非文本区保真、R2 溢出、R3 遮挡、R4 缺字、R5 内容完整、R7 阅读顺序）
///         —— 破坏任何一条都是错，必须进修复回路；
///     **软指标**（R6 版面相似度）
///         —— 单语同版式下文字内容整体替换，逐像素相似度必然大跌，
///            它只能用来发现「版式结构塌了」，不能用来当门禁。
///
/// 设计上刻意**不做整页截图比对**当主判据：截图会随渲染器版本变，
/// 出了问题也说不出是哪一段。这里的每一项都定位到块（`blockID`）与页面坐标。
public enum PDFSimilarityAnalyzer {

    public enum Check: String, CaseIterable, Sendable, Encodable {
        case r1 = "R1"
        case r2 = "R2"
        case r3 = "R3"
        case r4 = "R4"
        case r5 = "R5"
        case r6 = "R6"
        case r7 = "R7"

        public var title: String {
            switch self {
            case .r1: return "非文本区保真"
            case .r2: return "文本溢出"
            case .r3: return "遮挡"
            case .r4: return "字形缺失"
            case .r5: return "内容完整性"
            case .r6: return "版面相似度"
            case .r7: return "阅读顺序"
            }
        }
    }

    public enum Severity: String, Sendable, Encodable {
        case error
        case warning
        case info
    }

    public struct Options: Sendable {
        public var checks: Set<Check> = Set(Check.allCases)
        /// 144 dpi 才能分辨 0.5pt 细线
        public var dpi = 144.0
        /// 掩膜外扩（pt）。字形抗锯齿边缘会溢出 bbox，不外扩就会报一圈假差异
        public var maskDilation = 1.5
        /// 单像素容差（0…255）。2 是「肉眼不可见」的经验值
        public var pixelTolerance = 2
        /// 掩膜外差异像素占比上限：0.02%
        public var diffRatioLimit = 0.0002
        /// 溢出容差（pt）
        public var overflowTolerance = 0.5
        /// 相交面积容差（pt²）：小于它算「贴着」
        public var overlapTolerance = 1.0
        /// 版面相似度下限（模糊后 SSIM）
        public var layoutSSIMLimit = 0.86
        /// 结构连通域下限：小于它的墨迹算「文字」，不参与结构比对
        public var minStructurePixels = 240
        /// 结构差允许的绝对像素数。
        /// 64 px @144dpi ≈ 8pt×8pt：一个真正有意义的结构元素（细线、图标、色块）都比它大；
        /// 小于它的差异多半是「文字贴着图形」被撕下来的边角。
        public var structuralSlack = 64
        /// 结构差允许的相对比例（占结构像素总量）。2% 以内是「文字贴着图形」带来的边界噪声
        public var structuralSlackRatio = 0.02
        /// 只检查前 N 页（调试用）
        public var maxPages: Int?
        /// 抽页步长：大文档里按固定间隔抽样，既覆盖全篇又控制耗时
        public var pageStride = 1

        public init() {}
    }

    public struct Finding: Sendable, Encodable {
        public var check: String
        /// 1 基，与人看的报告一致
        public var page: Int
        public var blockID: String?
        public var severity: Severity
        public var code: String
        public var metric: Double
        public var limit: Double
        public var detail: String
        public var repairable: Bool
        public var box: [Double]?

        public init(check: String, page: Int, blockID: String?, severity: Severity,
                    code: String, metric: Double, limit: Double, detail: String,
                    repairable: Bool, box: [Double]?) {
            self.check = check
            self.page = page
            self.blockID = blockID
            self.severity = severity
            self.code = code
            self.metric = metric
            self.limit = limit
            self.detail = detail
            self.repairable = repairable
            self.box = box
        }
    }

    public struct PageResult: Sendable, Encodable {
        public var page = 0
        public var skipped = false
        public var passed = true
        public var note = ""

        // R1
        public var diffPixels = 0
        public var comparedPixels = 0
        /// 掩膜覆盖率：太低说明文本框没算出来（R1 会因此假报），太高说明掩膜过宽
        public var maskRatio = 0.0
        public var diffRatio = 0.0
        public var maxDelta = 0
        public var diffRegions: [PDFSimilarity.Region] = []

        /// 结构级差异（R1 的硬判据）：只在 A 有 / 只在 B 有
        public var structureLost = 0
        public var structureGained = 0
        /// 被当作文字丢掉的小连通域占比
        public var textRatio = 0.0

        // R2
        public var overflowItems = 0
        public var overflowPoints = 0.0

        // R3
        public var overlapPairs = 0

        // R4
        public var missingGlyphs = 0

        // R5
        public var truncatedItems = 0
        public var placeholderIssues = 0

        // R6
        public var ssim = 0.0
        public var layoutSSIM = 0.0

        // R7
        public var inversions = 0

        public var elapsedMS = 0.0
        public var findings: [Finding] = []

        public var errors: Int { findings.filter { $0.severity == .error }.count }
        public var warnings: Int { findings.filter { $0.severity == .warning }.count }

        public init() {}
    }

    public struct Result: Sendable, Encodable {
        public var pages: [PageResult] = []
        public var failedPages: [Int] = []
        public var skippedPages: [Int] = []
        public var errorCount = 0
        public var warningCount = 0
        public var durationMS = 0.0
        public var fatal = ""

        public var passed: Bool { fatal.isEmpty && errorCount == 0 }
        public var checkedPages: Int { pages.count - skippedPages.count }

        public init() {}

        public func page(_ index: Int) -> PageResult? {
            pages.first { $0.page == index + 1 }
        }
    }

    // MARK: - 入口

    /// - Parameters:
    ///   - original: 原始 PDF 字节
    ///   - output: 排版后的 PDF 字节
    ///   - layouts: 引擎给出的逐页诊断（键为 0 基页号）
    ///   - pages: 要检查的 0 基页号；nil = 全部
    ///   - cache: 原页渲染缓存，多轮分析时复用（原页不会变）
    public static func analyze(
        original: Data,
        output: Data,
        layouts: [Int: PDFPageLayout],
        pages: [Int]? = nil,
        options: Options = Options(),
        cache: PDFRenderingCache? = nil
    ) -> Result {
        let started = Date()
        var result = Result()
        let renderOptions = PDFPageRenderer.Options(dpi: options.dpi)

        guard let outputDocument = PDFPageRenderer.open(output) else {
            result.fatal = "输出 PDF 无法被 CoreGraphics 打开（文件结构损坏）"
            return result
        }
        let outputPageCount = outputDocument.numberOfPages
        let originalDocument = PDFPageRenderer.open(original)
        guard originalDocument == nil || originalDocument!.numberOfPages == outputPageCount else {
            result.fatal = "原页数与输出页数不一致（\(originalDocument?.numberOfPages ?? 0) vs \(outputPageCount)）"
            return result
        }

        let allPages = (pages ?? Array(0..<outputPageCount)).sorted()
        var sampled = allPages
        if options.pageStride > 1 {
            sampled = stride(from: 0, to: allPages.count, by: options.pageStride).map { allPages[$0] }
        }
        let targets = options.maxPages.map { Array(sampled.prefix($0)) } ?? sampled
        let store = cache ?? PDFRenderingCache()

        for index in targets {
            var page = PageResult()
            page.page = index + 1
            let pageStart = Date()
            guard index < outputPageCount else {
                page.skipped = true
                page.note = "页号越界"
                result.pages.append(page)
                result.skippedPages.append(index + 1)
                continue
            }
            guard let layout = layouts[index] else {
                page.skipped = true
                page.note = "该页没有排版诊断（未参与排版）"
                result.pages.append(page)
                result.skippedPages.append(index + 1)
                continue
            }
            if layout.skipped {
                page.skipped = true
                page.note = layout.notes.isEmpty ? "该页被跳过（保持原样）" : layout.notes
                result.pages.append(page)
                result.skippedPages.append(index + 1)
                continue
            }

            // 结构性检查（不需要渲染）
            if options.checks.contains(.r2) { checkOverflow(layout, into: &page, options: options) }
            if options.checks.contains(.r3) { checkOverlap(layout, into: &page, options: options) }
            if options.checks.contains(.r4) { checkMissingGlyphs(layout, into: &page) }
            if options.checks.contains(.r5) { checkCompleteness(layout, into: &page) }
            if options.checks.contains(.r7) { checkReadOrder(layout, into: &page) }

            // 像素检查
            let wantPixels = options.checks.contains(.r1) || options.checks.contains(.r6)
            if wantPixels {
                if layout.rotation % 360 != 0 {
                    page.note = "页面带 /Rotate \(layout.rotation)，像素级检查跳过（坐标系不一致）"
                    page.findings.append(Finding(
                        check: Check.r1.rawValue, page: index + 1, blockID: nil,
                        severity: .info, code: "rotated-page", metric: Double(layout.rotation),
                        limit: 0, detail: page.note, repairable: false, box: nil))
                } else if let originalDocument,
                          let originalImage = store.originalImage(
                            document: originalDocument, index: index, options: renderOptions),
                          let outputImage = PDFPageRenderer.render(
                            document: outputDocument, index: index, options: renderOptions) {
                    if options.checks.contains(.r1) {
                        checkStructure(original: originalImage, output: outputImage,
                                       layout: layout, into: &page, options: options)
                        checkFidelity(original: originalImage, output: outputImage,
                                      layout: layout, into: &page, options: options)
                    }
                    if options.checks.contains(.r6) {
                        let ssim = PDFSimilarity.layoutSSIM(originalImage, outputImage)
                        page.layoutSSIM = round(ssim.mean * 10000) / 10000
                        page.ssim = round(
                            PDFSimilarity.rawSSIM(originalImage, outputImage).mean * 10000) / 10000
                        if ssim.mean < options.layoutSSIMLimit {
                            page.findings.append(Finding(
                                check: Check.r6.rawValue, page: index + 1, blockID: nil,
                                severity: .warning, code: "layout-similarity-low",
                                metric: round(ssim.mean * 10000) / 10000,
                                limit: options.layoutSSIMLimit,
                                detail: String(format: "版面相似度 %.3f 低于 %.3f（墨迹分布与原文差异过大，需人工看一眼）",
                                               ssim.mean, options.layoutSSIMLimit),
                                repairable: false, box: nil))
                        }
                    }
                } else {
                    page.findings.append(Finding(
                        check: Check.r1.rawValue, page: index + 1, blockID: nil,
                        severity: .error, code: "render-failed", metric: 0, limit: 0,
                        detail: "原页或输出页渲染失败，无法做像素级校验", repairable: false,
                        box: nil))
                }
            }

            page.passed = page.errors == 0
            page.elapsedMS = round(Date().timeIntervalSince(pageStart) * 1000 * 10) / 10
            if !page.passed { result.failedPages.append(index + 1) }
            result.errorCount += page.errors
            result.warningCount += page.warnings
            result.pages.append(page)
        }

        result.durationMS = round(Date().timeIntervalSince(started) * 1000 * 10) / 10
        return result
    }

    // MARK: - R1 非文本区保真

    /// 结构级判据（硬门禁）：文字怎么换都行，图片/色块/表格线一个像素都不能动。
    ///
    /// 不依赖 IL 坐标，因此不受「文本提取框和渲染墨迹偏移」的影响。
    static func checkStructure(
        original: PDFPageImage, output: PDFPageImage,
        layout: PDFPageLayout,
        into page: inout PageResult, options: Options
    ) {
        // 结构比对要忽略「文字自己的地盘」：
        //     - 原文墨迹框（我们把它驱逐并重画了，换字体必然改变字形像素；
        //       汉字贴着边框时，「字母」本身也会被算进结构连通域）
        //     - 我们自己新画的非文本墨迹（页脚注释分隔线）
        // 图、表、矢量、底色都不在这些框里，所以「结构消失」照样抓得到。
        let ignore = layout.removedText + layout.addedInk
        let diff = PDFStructuralDiff.compare(
            original, output, minComponentPixels: options.minStructurePixels,
            ignore: ignore)
        guard diff.comparable else {
            page.findings.append(Finding(
                check: Check.r1.rawValue, page: page.page, blockID: nil,
                severity: .error, code: "image-size-mismatch", metric: 0, limit: 0,
                detail: "原页与输出页位图尺寸不一致（MediaBox 或 /Rotate 被改动）",
                repairable: false, box: nil))
            return
        }
        page.structureLost = diff.lostPixels
        page.structureGained = diff.gainedPixels
        page.textRatio = round(diff.textRatio * 10000) / 10000
        // **只判「丢失」**：结构不见了才是内容损失。
        // 「多出来的结构」通常是我们自己画的注释分隔线、或者文字压到图形边缘，
        // 它进指标但不进错误——否则每次加注释都会把页面判成失败。
        let allowed = max(Double(options.structuralSlack),
                          Double(diff.structurePixels) * options.structuralSlackRatio)
        if diff.gainedPixels > Int(allowed) {
            page.findings.append(Finding(
                check: Check.r1.rawValue, page: page.page, blockID: nil,
                severity: .info, code: "structure-gained",
                metric: Double(diff.gainedPixels), limit: round(allowed * 10) / 10,
                detail: "新增结构墨迹 \(diff.gainedPixels) px（多为我们自己画的注释线或文字贴边，仅记录）",
                repairable: false, box: nil))
        }
        guard Double(diff.lostPixels) > allowed else { return }
        let where_ = diff.regions.first.map {
            String(format: "(%.1f,%.1f)-(%.1f,%.1f) %d 像素", $0.x0, $0.y0, $0.x1, $0.y1, $0.pixels)
        } ?? ""
        page.findings.append(Finding(
            check: Check.r1.rawValue, page: page.page, blockID: nil,
            severity: .error, code: "structure-changed",
            metric: Double(diff.lostPixels), limit: round(allowed * 10) / 10,
            detail: "结构区丢失 \(diff.lostPixels) px（最大差 \(diff.maxDelta)/255）\(where_)",
            repairable: false, box: nil))
    }

    static func checkFidelity(
        original: PDFPageImage, output: PDFPageImage,
        layout: PDFPageLayout, into page: inout PageResult, options: Options
    ) {
        let mask = PDFPixelMask.build(
            image: original, rects: layout.maskRects, dilatePoints: options.maskDilation)
        let diff = PDFSimilarity.diff(
            original, output, mask: mask, tolerance: options.pixelTolerance)
        guard diff.comparable else {
            page.findings.append(Finding(
                check: Check.r1.rawValue, page: page.page, blockID: nil,
                severity: .error, code: "image-size-mismatch", metric: 0, limit: 0,
                detail: "原页与输出页位图尺寸不一致（MediaBox 或 /Rotate 被改动）",
                repairable: false, box: nil))
            return
        }
        page.maskRatio = round(mask.ratio * 10000) / 10000
        page.diffPixels = diff.diffPixels
        page.comparedPixels = diff.comparedPixels
        page.diffRatio = diff.ratio
        page.maxDelta = diff.maxDelta
        page.diffRegions = diff.regions

        // maxDelta 也纳入判据：掩膜外只要出现「明显不同」的像素，
        // 哪怕只有十几个，也说明图片/矢量真的被动了，不能用比例摊薄掉。
        let ratioExceeded = diff.ratio > options.diffRatioLimit && diff.diffPixels > 16
        if ratioExceeded || diff.maxDelta > 24 && diff.diffPixels > 16 {
            let where_ = diff.regions.first.map {
                String(format: "首个差异区 (%.1f,%.1f)-(%.1f,%.1f) %d 像素",
                       $0.x0, $0.y0, $0.x1, $0.y1, $0.pixels)
            } ?? ""
            // 掩膜法**不是硬门禁**：IL 框与渲染墨迹只要偏几 pt，换字体的差异就会漏到掩膜外。
            // 真正判「结构有没有被动」的是 checkStructure。这里降级为警告，
            // 它的价值是「精确到像素」——结构差为 0 时，它若还有大量差异，
            // 说明文本框几何不可信，需要人工看一眼。
            page.findings.append(Finding(
                check: Check.r1.rawValue, page: page.page, blockID: nil,
                severity: .warning, code: "nontext-diff",
                metric: round(diff.ratio * 1_000_000) / 1e6,
                limit: options.diffRatioLimit,
                detail: String(format: "掩膜外 %d/%d 像素不同（%.4f%%），最大差 %d/255。%@",
                               diff.diffPixels, diff.comparedPixels,
                               diff.ratio * 100, diff.maxDelta, where_),
                repairable: false, box: nil))
        }
    }

    // MARK: - R2 溢出

    static func checkOverflow(
        _ layout: PDFPageLayout, into page: inout PageResult, options: Options
    ) {
        let tolerance = options.overflowTolerance
        for item in layout.items {
            var worst = 0.0
            var detail = ""
            if !item.overflow.isEmpty {
                worst = max(worst, Double(item.overflow.count))
                detail = "有 \(item.overflow.count) 行没排进去（已转页脚注或丢弃）"
            }
            guard !item.lines.isEmpty else {
                if worst > 0 {
                    page.overflowItems += 1
                    page.overflowPoints += worst
                    page.findings.append(Finding(
                        check: Check.r2.rawValue, page: page.page, blockID: item.id,
                        severity: .error, code: "text-overflow",
                        metric: worst, limit: 0, detail: detail, repairable: true,
                        box: [item.box.x0, item.box.y0, item.box.x1, item.box.y1]))
                }
                continue
            }
            let right = item.lines.map(\.x1).max()! - item.box.x1
            let left = item.box.x0 - item.lines.map(\.x0).min()!
            let top = item.lines.map(\.y1).max()! - item.box.y1
            let bottom = item.box.y0 - item.lines.map(\.y0).min()!
            let overflow = max(max(right, left), max(top, bottom))
            if overflow > tolerance {
                worst = max(worst, overflow)
                if detail.isEmpty {
                    detail = String(format: "墨迹超出分配框 %.2fpt（右 %.2f / 左 %.2f / 上 %.2f / 下 %.2f）",
                                    overflow, right, left, top, bottom)
                }
            }
            if worst > 0 {
                page.overflowItems += 1
                page.overflowPoints += worst
                page.findings.append(Finding(
                    check: Check.r2.rawValue, page: page.page, blockID: item.id,
                    severity: .error, code: "text-overflow",
                    metric: round(worst * 100) / 100, limit: tolerance,
                    detail: detail, repairable: true,
                    box: [item.box.x0, item.box.y0, item.box.x1, item.box.y1]))
            }
        }
    }

    // MARK: - R3 遮挡

    static func checkOverlap(
        _ layout: PDFPageLayout, into page: inout PageResult, options: Options
    ) {
        let items = layout.items
        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                let a = items[i], b = items[j]
                // 同一张表的单元格之间不判（相邻单元格共享边框，内缩后仍可能贴住）
                if a.kind == .cell && b.kind == .cell { continue }
                // 钉子块按原坐标重画（符号、脚注标记、代码行），它和所属段落本来就是
                // 同一块区域里的两份墨迹——不是「叠字」，是「行内对象」
                if a.kind == .pinned || b.kind == .pinned { continue }
                // 保留原字节的块根本没有重画过：它们之间的重叠是原文档本来的样子，
                // 不是我们排出来的问题。只有「我们画的」和「我们画的」相撞才算叠字。
                if a.kind == .kept || b.kind == .kept { continue }
                // 「叠字」的判据是**纵向真的压在一起**，不是两个框挨着。
                // 行距压缩后相邻两段的框会贴住甚至交叠 1–2pt，那是正常排版。
                let area = a.inkBox.intersectionArea(b.inkBox)
                let vertical = a.inkBox.verticalOverlap(b.inkBox)
                guard area > options.overlapTolerance, vertical > 0.45 else { continue }
                page.overlapPairs += 1
                page.findings.append(Finding(
                    check: Check.r3.rawValue, page: page.page, blockID: a.id,
                    severity: .error, code: "text-overlap",
                    metric: round(area * 100) / 100, limit: options.overlapTolerance,
                    detail: "「\(a.id)」与「\(b.id)」墨迹相交 \(String(format: "%.1f", area))pt²",
                    repairable: true,
                    box: [a.inkBox.x0, a.inkBox.y0, a.inkBox.x1, a.inkBox.y1]))
            }
        }

        // 文字压图 / 压表
        //
        // 整页背景图（封面、满版插图）不算：书封上的标题本来就压在图上，
        // 这不是排版事故。判据用面积占比（>55% 页面），比「和文字相交」稳得多。
        let pageArea = max(1, layout.mediaBox.width * layout.mediaBox.height)
        let backgrounds = layout.figures.filter {
            $0.width * $0.height / pageArea > 0.55
        }
        for item in items {
            guard item.kind == .block else { continue }
            // 封面/满版底图常被切成多块 XObject，单块都不到 55%，但拼起来盖住整段文字。
            // 判据改成看「这段文字整个是不是坐在图上」：覆盖率 > 80% 就是底图，不是撞图。
            let itemArea = max(1, item.inkBox.width * item.inkBox.height)
            let covered = layout.figures.reduce(0.0) {
                $0 + $1.intersectionArea(item.inkBox)
            }
            if covered / itemArea > 0.8 { continue }
            for figure in layout.figures where !backgrounds.contains(figure) {
                let area = item.inkBox.intersectionArea(figure)
                guard area > max(options.overlapTolerance, 4) else { continue }
                page.overlapPairs += 1
                page.findings.append(Finding(
                    check: Check.r3.rawValue, page: page.page, blockID: item.id,
                    severity: .error, code: "text-over-figure",
                    metric: round(area * 100) / 100, limit: options.overlapTolerance,
                    detail: "译文压住了插图（相交 \(String(format: "%.1f", area))pt²）",
                    repairable: true,
                    box: [figure.x0, figure.y0, figure.x1, figure.y1]))
                break
            }
            for table in layout.tables {
                let area = item.inkBox.intersectionArea(table)
                guard area > max(options.overlapTolerance, 4) else { continue }
                page.overlapPairs += 1
                page.findings.append(Finding(
                    check: Check.r3.rawValue, page: page.page, blockID: item.id,
                    severity: .error, code: "text-over-table",
                    metric: round(area * 100) / 100, limit: options.overlapTolerance,
                    detail: "译文压住了表格（相交 \(String(format: "%.1f", area))pt²）",
                    repairable: true,
                    box: [table.x0, table.y0, table.x1, table.y1]))
                break
            }
        }
    }

    // MARK: - R4 缺字

    static func checkMissingGlyphs(_ layout: PDFPageLayout, into page: inout PageResult) {
        for item in layout.items where !item.missingScalars.isEmpty {
            page.missingGlyphs += item.missingScalars.count
            let hex = item.missingScalars.map { String(format: "U+%04X", $0) }.joined(separator: " ")
            page.findings.append(Finding(
                check: Check.r4.rawValue, page: page.page, blockID: item.id,
                severity: .error, code: "glyph-missing",
                metric: Double(item.missingScalars.count), limit: 0,
                detail: "字体缺字：\(hex)", repairable: false, box: nil))
        }
    }

    // MARK: - R5 内容完整性

    static func checkCompleteness(_ layout: PDFPageLayout, into page: inout PageResult) {
        for item in layout.items {
            let intent = normalize(item.intent)
            let drawn = normalize(item.drawn)
            if !intent.isEmpty && intent != drawn {
                let missing = max(0, intent.count - drawn.count)
                page.truncatedItems += 1
                page.findings.append(Finding(
                    check: Check.r5.rawValue, page: page.page, blockID: item.id,
                    severity: .error, code: "text-truncated",
                    metric: Double(missing), limit: 0,
                    detail: "打算画 \(intent.count) 字，实际落版 \(drawn.count) 字（少 \(missing)）",
                    repairable: true,
                    box: [item.box.x0, item.box.y0, item.box.x1, item.box.y1]))
            }
            // 占位符：行内对象/公式的锚点，错了后面所有东西都会错位，
            // 引擎已经回落原文，这里把它记成「需要重译」而不是「需要重排」
            if !item.source.isEmpty, item.intent != item.source {
                let report = PDFPlaceholder.verify(source: item.source, translation: item.intent)
                if !report.isClean {
                    page.placeholderIssues += 1
                    page.findings.append(Finding(
                        check: Check.r5.rawValue, page: page.page, blockID: item.id,
                        severity: .warning, code: "placeholder-mismatch",
                        metric: Double(report.missing.count + report.extra.count),
                        limit: 0,
                        detail: "占位符对不上（缺 \(report.missing.count) / 多 \(report.extra.count) / 顺序 \(report.orderChanged ? "变" : "正常")），已回落原文",
                        repairable: false, box: nil))
                }
            }
        }
    }

    // MARK: - R7 阅读顺序

    static func checkReadOrder(_ layout: PDFPageLayout, into page: inout PageResult) {
        // 只比「段落」。钉子块（"*"、"†"、页码碎片）是装饰，按原位重画，
        // 它们的投放顺序本来就跟段落无关；单元格在表格内自有序，页脚注在页底。
        // 把它们算进来只会制造假逆序（实测 84 项里有 78 项是钉子块）。
        let items = layout.items
            .filter { $0.kind == .block }
            .map { PDFReadOrder.Item(id: $0.id, box: $0.box) }
        let order = PDFReadOrder.check(items: items)
        page.inversions = order.inversions
        if order.inversions > 0 {
            page.findings.append(Finding(
                check: Check.r7.rawValue, page: page.page,
                blockID: order.samples.first,
                severity: .error, code: "reading-order",
                metric: Double(order.inversions), limit: 0,
                detail: "阅读顺序逆序 \(order.inversions) 对：\(order.samples.joined(separator: "；"))",
                repairable: true, box: nil))
        }
    }

    // MARK: - 工具

    /// 只去掉空白与零宽字符：断行会在行尾吃掉空格，这不是内容缺失。
    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00A0}":
                continue
            default:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// 原页渲染缓存：多轮分析里原页不变，重复渲染纯属浪费（144dpi 一页约 60ms）。
public final class PDFRenderingCache {
    private var images: [Int: PDFPageImage] = [:]
    public init() {}

    public func originalImage(
        document: CGPDFDocument?, index: Int, options: PDFPageRenderer.Options
    ) -> PDFPageImage? {
        if let cached = images[index] { return cached }
        guard let document,
              let image = PDFPageRenderer.render(document: document, index: index, options: options)
        else { return nil }
        images[index] = image
        return image
    }

    public var count: Int { images.count }
    public func purge() { images.removeAll() }
}
