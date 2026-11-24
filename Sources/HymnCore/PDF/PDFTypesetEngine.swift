import Foundation

/// P3 编排：读结构 → 排译文 → 驱逐原文 → 写回。
///
/// 三条不变量，任何一条被破坏都算 bug：
///     ① **不丢字**：块、表格单元格、以及「没被归进任何块」的孤立 run 都要被画出来。
///        孤立 run 按原坐标重画，宁可观感不一致，也不能让内容消失；
///     ② **不动图**：只替换内容流与页面资源字典，图片/矢量对象一个字节不改（P0/P1 已验证）；
///     ③ **不静默降级**：缺字、占位符损坏、放不下，全部进报告，并计入 needsReview。
///
/// 关于「未翻译的块」：仍然重画原文。原因是驱逐是整页级的——
/// 如果跳过某个块不画，它的原文已经被删了，那一块就成了空白。
public enum PDFTypesetEngine {
    public struct Request {
        public var translations = PDFPlaceholder.TranslationMap()
        public var options = PDFTypeset.Options()
        public var typesetTables = true
        public var typesetOrphanRuns = true
        /// 右侧安全边距（相对 MediaBox）
        public var pageMargin = 36.0
        /// 页脚注释带最多占页面高度的比例
        public var maxNoteBandRatio = 0.28
        /// P4 修复回路下发的段落级指令（空 = 首轮正常排版）
        public var repairs = PDFRepair.Set()
        /// 写完后把增量更新「洗」成干净文件（去掉被替换的旧字节）。
        /// 默认关闭：增量输出能让「没改的对象物理不变」这条性质可复核；
        /// 洗版会重排对象，虽然流字节仍是原样，但不再能逐字节对齐原文件。
        public var scrub = false

        public init() {}
    }

    public struct FaceSet {
        public var regular: TrueTypeFont
        public var bold: TrueTypeFont?

        public init(regular: TrueTypeFont, bold: TrueTypeFont? = nil) {
            self.regular = regular
            self.bold = bold
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: - 报告

    public struct PageReport: Encodable, Sendable {
        public var page: Int
        public var blocks = 0
        public var translated = 0
        public var keptOriginal = 0
        public var placeholderRejected = 0
        public var cells = 0
        public var orphanRuns = 0
        public var pinned = 0
        /// 计划矩形两两相交的块对数（R3 遮挡的前置指标）
        public var overlaps = 0
        /// 相交的块 id 对（最多 5 条，给 P4 的修复回路定位用）
        public var overlapPairs: [String] = []
        public var pinnedNearTable = 0
        public var pinnedCode = 0
        /// 「表格纵列」被钉住的数量（无线表的一列被行归并成段落后，只能原地不动）
        public var pinnedTabular = 0
        /// 落在图表区域里、按规矩保持原文的块数
        public var pinnedChart = 0
        /// 旋转的小字（图边竖排的出版方水印等），按规矩保持原文
        public var pinnedRotated = 0
        public var fit = 0
        public var shrink = 0
        public var expand = 0
        public var inlineNotes = 0
        public var pageNotes = 0
        public var overflowLines = 0
        /// 重排时排不下、只能留在原位的块数（原文保住了，但位置没跟上重排）
        public var unplacedBlocks = 0
        public var reflow = false
        public var skipped = false
        public var note = ""
        public var needsReview = false
        public var baselineFontSize: Double = 0
        public var floorFontSize: Double = 0
        public var missingScalars: [UInt32] = []
        public var removedRuns = 0
        /// 本页内容流的 FNV-1a 64：修复回路用它证明「未受影响页没被改动」
        public var contentHash = ""
        /// 本页一个字节都没动（没有译文、也没有需要重画的块）
        public var unchanged = false
    }

    public struct Report: Encodable, Sendable {
        public init() {}

        /// 增量更新后、洗版前的字节数
        public var incrementalBytes = 0
        public var scrubbed = false
        public var droppedObjects = 0
        /// 全篇没有需要改动的页，输出与原文件逐字节相同
        public var unchangedDocument = false
        public var inputBytes = 0
        public var outputBytes = 0
        public var embeddedFonts: [String] = []
        public var pages: [PageReport] = []
        public var missingScalars: [UInt32] = []
        public var totalOverflowLines = 0
        public var reflowPages: [Int] = []
        public var skippedPages: [Int] = []
        public var needsReviewPages: [Int] = []
        public var warnings: [String] = []

        public var totalBlocks: Int { pages.reduce(0) { $0 + $1.blocks } }
        public var totalTranslated: Int { pages.reduce(0) { $0 + $1.translated } }
        public var totalKeptOriginal: Int { pages.reduce(0) { $0 + $1.keptOriginal } }
    }

    // MARK: - 主流程

    public struct Detailed {
        public var output: Data
        public var report: Report
        /// 逐页诊断（P4 分析器用）。页序与输出一致，`page` 是 0 基。
        public var layouts: [PDFPageLayout]
    }

    public static func run(
        document: PDFDocument,
        faces: FaceSet,
        pageIndices: [Int]? = nil,
        request: Request = Request()
    ) throws -> (output: Data, report: Report) {
        let detailed = try runDetailed(
            document: document, faces: faces, pageIndices: pageIndices, request: request)
        return (detailed.output, detailed.report)
    }

    public static func runDetailed(
        document: PDFDocument,
        faces: FaceSet,
        pageIndices: [Int]? = nil,
        request: Request = Request()
    ) throws -> Detailed {
        if document.isEncrypted {
            throw Failure(description: "文档已加密，本版本不处理 /Encrypt")
        }
        let entries = document.pageEntries()
        let targets = (pageIndices ?? Array(0..<entries.count))
            .filter { $0 >= 0 && $0 < entries.count }
        guard !targets.isEmpty else {
            throw Failure(description: "没有可处理的页面")
        }

        // 1. 逐页读结构（跳过不可译页）
        var works: [PageWork] = []
        for index in targets {
            let entry = entries[index]
            let page = PDFStructureBuilder.buildPage(document: document, index: index, entry: entry)
            let content = PDFTextExtractor.extract(document: document, pageIndex: index, page: entry.dict)
            var work = PageWork(index: index, entry: entry, page: page, content: content)
            work.baseline = PDFTypeset.pageBaselineFontSize(lines: page.blocks.flatMap(\.lines))
            work.floor = PDFTypeset.fontSizeFloor(baseline: work.baseline)
            for block in page.blocks {
                let resolved = resolvedText(for: block, pageIndex: index, request: request)
                work.texts[block.id] = resolved.text
                if resolved.keptOriginal { work.keptOriginal.insert(block.id) }
                if resolved.placeholderRejected { work.placeholderRejected.insert(block.id) }
            }
            works.append(work)
        }

        // 2. 决定字体面（粗体只在真的用到时嵌入，省一个 14MB 子集）
        let needsBold = works.contains { work in
            work.page.blocks.contains { block in
                block.lines.contains { line in line.spans.contains { $0.isBold } }
            }
        }

        // 3. 收集全部要画的字，一次性嵌入
        //
        // **原文也全部收进去**，即使这一段会用译文替换：
        //     - 修复回路可能对某块下发「回落原文」，那时不能因为缺字而画不出来；
        //     - 子集与 CID 映射跨轮稳定（字符集合不变），未受影响页的内容流才能逐字节相同。
        // 代价是子集多收一批已存在的字符，实测体积增量可忽略（CJK 子集本来就以汉字为主）。
        var allText = ""
        for work in works {
            for block in work.page.blocks {
                allText += block.text
                allText += work.texts[block.id] ?? block.text
            }
            for table in work.page.tables {
                for cell in table.cells {
                    allText += cell.text
                    allText += translation(request.translations, table: table.id, row: cell.row,
                                           column: cell.column, pageIndex: work.index) ?? cell.text
                }
            }
            allText += work.content.runs.map(\.text).joined()
        }
        allText += "0123456789[]"   // 脚注编号与括号，保证不会被缺字挡住

        var objects: [(ref: PDFRef, value: PDFValue)] = []
        var allocator = PDFObjectAllocator(startingAt: document.nextFreeObjectNumber)

        let regularName = uniqueFontName(document: document, entries: entries, preferred: "LNR1")
        let regularEmbed = try PDFFontEmbedder.embed(
            font: faces.regular, text: allText, resourceName: regularName,
            firstObjectNumber: allocator.next)
        objects.append(contentsOf: regularEmbed.objects)
        allocator = PDFObjectAllocator(startingAt: regularEmbed.objects.map(\.ref.number).max()! + 1)

        var boldEmbed: PDFFontEmbedder.Embedded?
        var boldName: String?
        if needsBold, let boldFont = faces.bold {
            let name = uniqueFontName(document: document, entries: entries, preferred: "LNR2")
            let embedded = try PDFFontEmbedder.embed(
                font: boldFont, text: allText, resourceName: name,
                firstObjectNumber: allocator.next)
            objects.append(contentsOf: embedded.objects)
            allocator = PDFObjectAllocator(startingAt: embedded.objects.map(\.ref.number).max()! + 1)
            boldEmbed = embedded
            boldName = name
        }

        let regularFace = PDFFace(font: faces.regular, resourceName: regularName, isBold: false)
        let boldFace = boldEmbed.flatMap { embedded in
            boldName.map { PDFFace(font: faces.bold!, resourceName: $0, isBold: true) }
        }

        var report = Report()
        var drewAnything = false
        report.embeddedFonts = [regularEmbed.subsetName] + (boldEmbed.map { [$0.subsetName] } ?? [])
        var pageLayouts: [PDFPageLayout] = []

        // 4. 逐页排
        for work in works {
            var pageReport = PageReport(page: work.index + 1)
            pageReport.baselineFontSize = work.baseline
            pageReport.floorFontSize = work.floor

            guard work.page.translatable else {
                pageReport.skipped = true
                pageReport.needsReview = true
                pageReport.note = "页面不可译（缺 /ToUnicode），保持原样"
                report.pages.append(pageReport)
                report.skippedPages.append(work.index + 1)
                report.needsReviewPages.append(work.index + 1)
                continue
            }

            // 4.1 原文（用于驱逐）与资源
            var original = Data()
            for ref in document.contentRefs(of: work.entry.dict) {
                guard let stream = (try? document.resolve(ref))?.streamValue,
                      let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
                else { continue }
                original.append(decoded)
                if let last = decoded.last, last != 0x0A && last != 0x0D { original.append(0x0A) }
            }
            guard !original.isEmpty else {
                pageReport.skipped = true
                pageReport.note = "没有内容流，保持原样"
                report.pages.append(pageReport)
                report.skippedPages.append(work.index + 1)
                continue
            }

            let geometry = PDFStamper.geometry(of: work.entry.dict)
            let mediaBox = PDFRect(x0: geometry.mediaBox.x0, y0: geometry.mediaBox.y0,
                                   x1: geometry.mediaBox.x1, y1: geometry.mediaBox.y1)
            let region = textRegion(page: work.page, mediaBox: mediaBox,
                                    margin: request.pageMargin)

            // P4 诊断：本页实际画了什么。逐块记录，分析器据此定位溢出/遮挡/缺字。
            var layout = PDFPageLayout(page: work.index, mediaBox: mediaBox,
                                       rotation: geometry.rotation)
            layout.figures = work.page.figures.map(\.box)
            layout.tables = work.page.tables.map(\.box)
            layout.removedText = work.content.runs.map(\.bbox) + work.page.blocks.map(\.box)
            var planMeta: [String: (kind: PDFPageLayout.Kind, source: String, intent: String)] = [:]
            let pageRepair = request.repairs.page(work.index)

            // 4.2 文本归属：块 → 表格单元格 → 孤立 run
            let texts = work.texts
            for block in work.page.blocks {
                if work.keptOriginal.contains(block.id) { pageReport.keptOriginal += 1 }
                else { pageReport.translated += 1 }
                if work.placeholderRejected.contains(block.id) { pageReport.placeholderRejected += 1 }
                pageReport.blocks += 1
            }
            let tableBoxes = work.page.tables.map(\.box)
            let orphans = request.typesetOrphanRuns
                ? orphanRuns(work: work, tableBoxes: tableBoxes)
                : []

            // 4.3 逐块排。碎片块（"*"、"†"、单个数字）钉在原位：
            // 它们没有可翻译的内容，走排版只会被撑开、错位。
            var plans: [PDFTypeset.Plan] = []
            var notes: [(anchor: Int, lines: [String], from: PDFRect)] = []
            var obstacles = work.page.figures.map(\.box) + tableBoxes
            var pinned: [ILBlock] = []

            for block in work.page.blocks {
                let nearTable = isNearTable(block, tables: work.page.tables)
                let code = isCodeBlock(block)
                let strip = isTabularStrip(block)
                let chart = isInsideChart(block, charts: work.page.charts)
                let rotated = isRotatedLabel(block)
                // 只用 `keepsOriginal` 一个判据：以前这里另抄了一份条件清单，
                // 和 `keepsOriginal` 一旦不同步，就会出现「排版时钉住、翻译时照翻」
                // 或反过来的裂口。
                guard keepsOriginal(block, page: work.page) else { continue }
                pinned.append(block)
                pageReport.keptOriginal += 1
                pageReport.blocks += 1
                pageReport.pinned += 1
                if nearTable { pageReport.pinnedNearTable += 1 }
                if code { pageReport.pinnedCode += 1 }
                if strip { pageReport.pinnedTabular += 1 }
                if chart { pageReport.pinnedChart += 1 }
                if rotated { pageReport.pinnedRotated += 1 }
            }

            // 钉住的块（代码、目录、表格邻接）不移动，对邻居来说就是障碍物：
            // 不让邻居往下扩到它们身上，否则译文会压住代码
            obstacles.append(contentsOf: pinned.map(\.box))
            // 没有译文、原样保留的块也占着位置：邻居不许扩进来
            obstacles.append(contentsOf: work.page.blocks
                .filter { work.keptOriginal.contains($0.id) }.map(\.box))

            for block in work.page.blocks
            where !keepsOriginal(block, page: work.page)
                && !work.keptOriginal.contains(block.id) {
                let repair = pageRepair?.blocks[block.id]
                // 回落原文：原文当初就在这个框里，它一定放得下
                let text = repair?.revertToSource == true
                    ? block.text
                    : (texts[block.id] ?? block.text)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let face = faceFor(block: block, regular: regularFace, bold: boldFace)
                let limits = blockLimits(block: block, page: work.page, region: region,
                                        mediaBox: mediaBox, obstacles: obstacles,
                                        margin: request.pageMargin)
                // 少数块的框会超出页面（某个 run 的 advance 异常大）：
                // 夹回页内再排，否则文字会画到纸外面
                let clamped = PDFRect(
                    x0: max(block.box.x0, mediaBox.x0 + 6),
                    y0: max(block.box.y0, mediaBox.y0 + 6),
                    x1: min(block.box.x1, mediaBox.x1 - 6),
                    y1: min(block.box.y1, mediaBox.y1 - 6))
                let planBox = clamped.width > 4 ? clamped : block.box

                var options = request.options
                var floor = work.floor
                if let repair {
                    if let minimum = repair.minFontSize { floor = min(floor, max(4, minimum)) }
                    options.maxRightExpandRatio *= repair.rightExpand
                    options.maxDownExpandRatio *= repair.downExpand
                }

                var plan = PDFTypeset.plan(
                    text: text, blockID: block.id, face: face,
                    baseFontSize: max(1, block.fontSize),
                    space: PDFTypeset.Space(box: planBox, rightLimit: limits.right,
                                            downLimit: limits.down),
                    floorSize: floor, options: options)
                planMeta[block.id] = (.block, block.text, text)

                switch plan.tier {
                case .fit: pageReport.fit += 1
                case .shrink: pageReport.shrink += 1
                case .expand: pageReport.expand += 1
                case .overflowShort:
                    // 短溢：先试框下空白处的小字注释。
                    // 起点必须取 `min(扩后底边, 原底边)`：块若是向下扩过，
                    // 扩出来的区域已经贴到下一段，从扩后底边再往下排就会压字。
                    let noteTop = min(plan.box.y0, block.box.y0) - 4
                    let noteHeight = noteTop - limits.down
                    let noteText = plan.overflow.joined(separator: " ")
                    let note = PDFTypeset.plan(
                        text: noteText, blockID: block.id + "#note",
                        face: face, baseFontSize: max(8, plan.fontSize * 0.88),
                        space: PDFTypeset.Space(
                            box: PDFRect(x0: block.box.x0 + 10, y0: limits.down,
                                         x1: limits.right, y1: noteTop),
                            rightLimit: limits.right, downLimit: limits.down),
                        floorSize: max(6, work.floor * 0.9), options: request.options)
                    if noteHeight > max(8, plan.fontSize * 0.9),
                       note.tier != .overflowShort && note.tier != .overflowLong,
                       !note.lines.isEmpty {
                        plan.overflow = []
                        pageReport.inlineNotes += 1
                        planMeta[note.blockID] = (.note, block.text, noteText)
                        plans.append(plan)
                        plans.append(note)
                        continue
                    }
                    pageReport.overflowLines += plan.overflow.count
                    notes.append((notes.count + 1, plan.overflow, plan.box))
                    plan.overflow = []
                    pageReport.pageNotes += 1
                case .overflowLong:
                    pageReport.overflowLines += plan.overflow.count
                    notes.append((notes.count + 1, plan.overflow, plan.box))
                    plan.overflow = []
                    pageReport.pageNotes += 1
                case .skipped:
                    continue
                }
                plans.append(plan)
            }

            // 4.4 页脚注释放不下 → 整页重排
            // 修复回路也可以在「注释放得下」的情况下强制重排（阅读顺序错了）
            let pageNotesCount = pageReport.pageNotes
            if pageNotesCount >= 2 || pageRepair?.forceReflow == true {
                // 重排只处理「真的要重画」的块：
                // 图表里的文字、公式、代码、表格邻接块本来就保持原字节，
                // 把它们塞进重排会让图里的刻度被驱逐后重新画到别处（真实样本踩过）。
                // 页眉页脚同理——重排会把它们当正文推进流里，于是「M.G. Pelletier et al.」
                // 出现在页面中间、图注上方。
                let reflowBlocks = work.page.blocks.filter {
                    !keepsOriginal($0, page: work.page) && !isRunningHeadOrFoot($0, page: work.page)
                }
                var reflow = PDFPageReflow.flow(
                    blocks: reflowBlocks, texts: texts, region: region,
                    obstacles: obstacles,
                    face: { faceFor(block: $0, regular: regularFace, bold: boldFace) },
                    floorSize: work.floor, options: request.options)
                // 排不下的块会留在原位（下面按「保持原字节」处理），但重排本身并不知道
                // 它们挡在哪里。把它们的原框补成障碍物再排一遍，避免新文字压上去。
                if !reflow.unplaced.isEmpty {
                    let stranded = reflowBlocks
                        .filter { reflow.unplaced.contains($0.id) }
                        .map(\.box)
                    let retry = PDFPageReflow.flow(
                        blocks: reflowBlocks, texts: texts, region: region,
                        obstacles: obstacles + stranded,
                        face: { faceFor(block: $0, regular: regularFace, bold: boldFace) },
                        floorSize: work.floor, options: request.options)
                    if retry.plans.count > reflow.plans.count { reflow = retry }
                }
                if !reflow.plans.isEmpty {
                    plans = reflow.plans
                    // 重排后块 id 不变，但计划是新的：重新登记「打算画什么」，
                    // 否则 R5 会把重排当成人手改过的文本
                    for plan in plans {
                        let block = work.page.blocks.first { $0.id == plan.blockID }
                        planMeta[plan.blockID] = (.block, block?.text ?? "",
                                                  texts[plan.blockID] ?? block?.text ?? "")
                    }
                    notes = []
                    pageReport.reflow = true
                    pageReport.pageNotes = 0
                    pageReport.inlineNotes = 0
                    pageReport.overflowLines = reflow.overflowLines
                    pageReport.unplacedBlocks = reflow.unplacedBlocks
                    if reflow.unplacedBlocks > 0 { pageReport.needsReview = true }
                    if reflow.overflowLines > 0 { pageReport.needsReview = true }
                    report.reflowPages.append(work.index + 1)
                }
            }

            // 4.5 表格单元格（就地排，不参与页脚注释）
            var cellPlans: [PDFTypeset.Plan] = []
            var keptCells: [ILCell] = []
            if request.typesetTables {
                for table in work.page.tables {
                    for cell in table.cells where !cell.text.isEmpty {
                        // 没有译文（或译文与原文一致）的单元格保持原字节：
                        // 重画一遍只会把它的字体换掉，还可能撑破单元格。
                        guard let translatedCell = translation(
                                request.translations, table: table.id,
                                row: cell.row, column: cell.column, pageIndex: work.index),
                              translatedCell != cell.text else {
                            keptCells.append(cell)
                            continue
                        }
                        let text = translatedCell
                        // 竖直方向只留 1 pt：数据表的行距本来就只有 1.3 个字高，
                        // 上下各留 2 pt 会把可用高度压到**低于一行**，
                        // 于是每一格都判「放不下」，最后画出来的还是原文。
                        let inset = PDFRect(x0: cell.box.x0 + 2, y0: cell.box.y0 + 1,
                                            x1: cell.box.x1 - 2, y1: cell.box.y1 - 1)
                        guard inset.width > 6, inset.height > 5 else { continue }
                        // 字号跟原格子一致：格子只有一行高时，用「框高 × 0.62」算出来的
                        // 5 pt 既放不下又不像原文，纯属自找溢出。
                        let cellSize = cellFontSize(cell, runs: work.content.runs)
                            ?? (work.baseline > 0 ? work.baseline : 8)
                        let baseSize = max(4.5, min(cellSize, inset.height * 1.15))
                        // 单元格**不许扩框**：向右扩就压到邻列，向下扩就压到下一行。
                        var cellOptions = request.options
                        cellOptions.maxRightExpandRatio = 0
                        cellOptions.maxDownExpandRatio = 0
                        var plan = PDFTypeset.plan(
                            text: text, blockID: "\(table.id):\(cell.row):\(cell.column)",
                            face: regularFace, baseFontSize: baseSize,
                            space: PDFTypeset.Space(box: inset, rightLimit: inset.x1,
                                                    downLimit: inset.y0),
                            floorSize: max(4.5, baseSize * 0.75), options: cellOptions)
                        // 译文放不下就退到原文；连原文都放不下，这一格保持原字节。
                        // 「画半截」是最差的结果：看起来翻过了，实际字被切掉。
                        if plan.tier == .overflowShort || plan.tier == .overflowLong,
                           cell.text != text {
                            let fallback = PDFTypeset.plan(
                                text: cell.text, blockID: "\(table.id):\(cell.row):\(cell.column)",
                                face: regularFace, baseFontSize: baseSize,
                                space: PDFTypeset.Space(box: inset, rightLimit: inset.x1,
                                                        downLimit: inset.y0),
                                floorSize: max(4.5, baseSize * 0.75), options: cellOptions)
                            if fallback.tier != .overflowShort && fallback.tier != .overflowLong {
                                plan = fallback
                                pageReport.keptOriginal += 1
                            } else {
                                keptCells.append(cell)
                                continue
                            }
                        }
                        cellPlans.append(plan)
                        planMeta[plan.blockID] = (.cell, cell.text,
                                                  plan.tier == .skipped ? "" : text)
                        pageReport.cells += 1
                        if plan.tier == .overflowShort || plan.tier == .overflowLong {
                            pageReport.overflowLines += plan.overflow.count
                        }
                    }
                }
            }

            // 4.5a 算出「哪些文本算子要保留原字节」
            //
            // 规则只有一句：**除了我们要重画的，其余一个算子都不动**。
            // 所以这里是「默认全保留，再逐个扣掉重画的部分」，而不是
            // 「挑出保留的」——后者会漏掉那些没进任何 span 的 run（行首空格、
            // 被行归并丢掉的重叠字），实测一页代码块就被静默删掉 24 个算子，
            // 缩进整段消失。
            //
            // 这条规则对「整页重排」同样成立，而且更关键：重排只是换位置，
            // 不等于这一页的文字都归我们重画。排不下的块会留在原位，
            // 钉住的块（图表文字、公式、代码、页眉、表格单元格）根本不参与重排——
            // 它们必须原字节留下，否则就是静默删字（整页重排曾经把页眉、
            // 上标、表格里的数字一起吞掉）。
            var keepRanges: [Range<Int>] = []
            var forcedRuns: [PDFTextRun] = []
            var keptBlocks = work.keptOriginal
            for block in pinned { keptBlocks.insert(block.id) }
            let drawnIDs = Set((plans + cellPlans).map(\.blockID))
            for block in work.page.blocks where !drawnIDs.contains(block.id) {
                keptBlocks.insert(block.id)
            }

            // 诊断项：保留原字节的块也要登记，否则逐段对照报告里会「凭空少一段」
            for block in work.page.blocks where keptBlocks.contains(block.id) {
                let isPinnedBlock = pinned.contains { $0.id == block.id }
                layout.items.append(PDFPageLayout.Item(
                    id: block.id,
                    kind: isPinnedBlock ? .pinned : .kept,
                    box: block.box,
                    lines: block.lines.map(\.box),
                    intent: block.text, drawn: block.text, source: block.text,
                    fontSize: block.fontSize, overflow: [],
                    missingScalars: [], tier: isPinnedBlock ? "pinned" : "kept"))
            }
            for cell in keptCells {
                layout.items.append(PDFPageLayout.Item(
                    id: "cell-\(cell.row):\(cell.column)", kind: .kept,
                    box: cell.box, lines: [cell.box],
                    intent: cell.text, drawn: cell.text, source: cell.text,
                    fontSize: 0, overflow: [], missingScalars: [], tier: "kept"))
            }

            // 默认全部保留
            var keepIndices = Set(work.content.runs.indices)
            var drawnRanges: Set<Range<Int>> = []

            // 扣掉「要重画的块」对应的 run
            for block in work.page.blocks where drawnIDs.contains(block.id) {
                for line in block.lines {
                    for span in line.spans where span.runIndex >= 0 {
                        keepIndices.remove(span.runIndex)
                        if span.runIndex < work.content.runs.count,
                           let range = work.content.runs[span.runIndex].sourceRange {
                            drawnRanges.insert(range)
                        }
                    }
                }
            }
            // 扣掉「要重画的单元格」里的 run（按中心点归属）
            for table in work.page.tables {
                for cell in table.cells where !keptCells.contains(where: {
                    $0.row == cell.row && $0.column == cell.column && $0.box == cell.box
                }) {
                    for run in work.content.runs where run.runIndex >= 0 {
                        let center = PDFPoint((run.bbox.x0 + run.bbox.x1) / 2,
                                              (run.bbox.y0 + run.bbox.y1) / 2)
                        guard center.x >= cell.box.x0, center.x <= cell.box.x1,
                              center.y >= cell.box.y0, center.y <= cell.box.y1 else { continue }
                        keepIndices.remove(run.runIndex)
                        if let range = run.sourceRange { drawnRanges.insert(range) }
                    }
                }
            }

            // 掩膜只覆盖「真的被驱逐的文本」。
            // 没动的区域必须严格 0 差异——这比「掩膜大一点更安全」强得多：
            // 把没碰的文本也遮住，等于自己放水。
            var evictedBoxes: [PDFRect] = []
            for (index, run) in work.content.runs.enumerated()
            where !keepIndices.contains(index) {
                evictedBoxes.append(run.bbox)
            }
            layout.removedText = evictedBoxes
                + work.page.blocks.filter { drawnIDs.contains($0.id) }.map(\.box)

            // 一个 TJ 数组里的多个 run 共用同一个算子区间。若这区间属于
            // 「要重画的块」，那么区间里的其它 run 也留不下来——
            // 这时候把它们按原坐标重画一份，保证不丢字。
            for index in keepIndices.sorted() {
                guard index >= 0, index < work.content.runs.count else { continue }
                let run = work.content.runs[index]
                guard let range = run.sourceRange else { continue }
                if drawnRanges.contains(range) {
                    forcedRuns.append(run)
                    continue
                }
                keepRanges.append(range)
            }

            // 4.5b 诊断：登记实际绘制项（供 P4 的 R2/R3/R4/R5/R7 定位）
            for plan in plans + cellPlans {
                let meta = planMeta[plan.blockID]
                let kind = meta?.kind ?? .block
                let face = kind == .cell ? regularFace : faceForPlan(
                    plan, page: work.page, regular: regularFace, bold: boldFace)
                let rects = plan.lines.map {
                    inkRect(line: $0, size: plan.fontSize, font: face.font)
                }
                layout.items.append(PDFPageLayout.Item(
                    id: plan.blockID, kind: kind, box: plan.box, lines: rects,
                    intent: plan.content.isEmpty
                        ? (meta?.intent ?? plan.lines.map(\.text).joined())
                        : plan.content,
                    // 溢出到页脚注的字没有丢，只是换了位置，所以算进「已落版」
                    drawn: (plan.lines.map(\.text) + plan.overflow).joined(),
                    source: meta?.source ?? "", fontSize: plan.fontSize,
                    overflow: plan.overflow, missingScalars: plan.missingScalars,
                    tier: plan.tier.rawValue))
            }

            // 4.6 组装内容流
            let evicted = TextEvictor.evictText(from: original, keeping: keepRanges)
            var body = PDFTextStamp.wrap(original: evicted.data)
            pageReport.removedRuns = evicted.removedRuns
            var drawnMissing: [UInt32] = []

            for plan in plans {
                let face = plan.blockID.hasSuffix("#note") ? regularFace
                    : faceForPlan(plan, page: work.page, regular: regularFace, bold: boldFace)
                drawnMissing += appendPlan(plan, face: face, embed: regularEmbed,
                                           boldEmbed: boldEmbed, to: &body)
            }
            for plan in cellPlans {
                drawnMissing += appendPlan(plan, face: regularFace, embed: regularEmbed,
                                           boldEmbed: boldEmbed, to: &body)
            }
            // 孤立 run 与钉子块：原坐标重画，保证「不丢字」。
            // 跟随所属段落做纵向位移，否则重排后项目符号会留在原地。
            let shifts = planShifts(plans: plans, page: work.page)
            // 钉子块（代码、目录点线、表格邻接、碎片）**不再重画**：
            // 它们的原文留在内容流里，字体、宽度、缩进一个字节都没动。
            // 之前是「驱逐 + 宋体原坐标重画」，代码块行宽全变、和缩进对不上。
            let fixedRuns = forcedRuns
            if !fixedRuns.isEmpty {
                pageReport.orphanRuns = orphans.count
                body.append(drawRuns(fixedRuns, face: regularFace, embed: regularEmbed,
                                     boldEmbed: boldEmbed,
                                     shift: { run in shiftFor(run: run, shifts: shifts) }))
                // 诊断：原坐标重画的实际落点（含纵向位移）。这些区域一定要进掩膜，
                // 因为换了字体，字形本身必然变。
                for (order, run) in fixedRuns.enumerated() where !run.text.isEmpty {
                    let dy = shiftFor(run: run, shifts: shifts)
                    let box = PDFRect(x0: run.bbox.x0, y0: run.bbox.y0 + dy,
                                      x1: run.bbox.x1, y1: run.bbox.y1 + dy)
                    layout.items.append(PDFPageLayout.Item(
                        id: order < orphans.count ? "orphan-\(order)" : "pinned-\(order)",
                        kind: order < orphans.count ? .orphan : .pinned,
                        box: box, lines: [box], intent: run.text, drawn: run.text,
                        source: run.text, fontSize: run.fontSize, tier: "fixed"))
                }
            }

            // 脚注带
            if !notes.isEmpty && !pageReport.reflow {
                body.append(drawNotes(notes, region: region, mediaBox: mediaBox,
                                      face: regularFace, embed: regularEmbed,
                                      maxBandRatio: request.maxNoteBandRatio,
                                      into: &pageReport,
                                      record: { rect, text in
                    if let text {
                        layout.items.append(PDFPageLayout.Item(
                            id: "note-\(layout.items.count)", kind: .note, box: rect,
                            lines: [rect], intent: text, drawn: text, source: "",
                            fontSize: rect.height, tier: "page-note"))
                    } else {
                        // 分隔线是我们主动新画的矢量，必须进掩膜，
                        // 否则 R1 会把它当成「图片被改了」
                        layout.addedInk.append(rect)
                    }
                }))
            }

            pageReport.missingScalars = Array(Set(drawnMissing)).sorted()
            if !pageReport.missingScalars.isEmpty {
                pageReport.needsReview = true
                report.missingScalars = Array(Set(report.missingScalars + drawnMissing)).sorted()
            }
            if pageReport.overflowLines > 0 || pageReport.pageNotes > 0 {
                pageReport.needsReview = pageReport.needsReview || pageReport.pageNotes > 0
            }

            // 4.6b 自检：计划矩形两两相交的数量。
            // 这是 R3（遮挡）的廉价前置指标——有相交就说明排版逻辑本身有问题，
            // 不必等到像素比对才发现。
            let overlapCheck = countOverlaps(plans: plans + cellPlans)
            pageReport.overlaps = overlapCheck.count
            pageReport.overlapPairs = overlapCheck.samples
            if pageReport.overlaps > 0 { pageReport.needsReview = true }

            // 4.6c 这一页什么都没改？那就**连一个字节都不写**。
            //
            // 整页驱逐的时代，即使没有译文也会把原文重画一遍（换字体、重排），
            // 于是「没翻译的页」在输出里体积膨胀而且像素会变。现在驱逐是按区间的，
            // 没有译文 ⇒ 没有算子被删 ⇒ 页面对不上任何改动 ⇒ 保持原样最保真。
            if evicted.removedRuns == 0, plans.isEmpty, cellPlans.isEmpty,
               fixedRuns.isEmpty, notes.isEmpty {
                pageReport.unchanged = true
                pageReport.contentHash = FNV1a.hash(original)
                layout.contentHash = pageReport.contentHash
                layout.notes = "无译文改动，保持原样"
                pageLayouts.append(layout)
                report.pages.append(pageReport)
                if pageReport.needsReview { report.needsReviewPages.append(work.index + 1) }
                continue
            }

            // 4.7 写回页面
            let pageDict = work.entry.dict
            var fonts: [(name: String, ref: PDFRef)] = [(regularName, regularEmbed.type0Ref)]
            if let boldName, let boldEmbed {
                fonts.append((boldName, boldEmbed.type0Ref))
            }
            let reusable = PDFPageRewriter.singleContentStream(
                document: document, page: pageDict, newContent: body)?.ref
            let planObjects = PDFPageRewriter.replaceContent(
                document: document, pageRef: work.entry.ref, pageDict: pageDict,
                newContent: body, fonts: fonts, reuseContentRef: reusable,
                allocator: &allocator)
            objects.append(contentsOf: planObjects.objects)

            drewAnything = true
            pageReport.contentHash = FNV1a.hash(body)
            layout.contentHash = pageReport.contentHash
            layout.notes = pageReport.note
            pageLayouts.append(layout)

            report.pages.append(pageReport)
            if pageReport.needsReview { report.needsReviewPages.append(work.index + 1) }
        }

        // 被跳过的页也要有诊断记录（分析器据此区分「跳过」与「没有数据」）
        for work in works where !pageLayouts.contains(where: { $0.page == work.index }) {
            let geometry = PDFStamper.geometry(of: work.entry.dict)
            var skipped = PDFPageLayout(
                page: work.index,
                mediaBox: PDFRect(x0: geometry.mediaBox.x0, y0: geometry.mediaBox.y0,
                                  x1: geometry.mediaBox.x1, y1: geometry.mediaBox.y1),
                rotation: geometry.rotation)
            skipped.skipped = true
            skipped.notes = "该页未参与排版（保持原样）"
            pageLayouts.append(skipped)
        }
        pageLayouts.sort { $0.page < $1.page }

        // 5. 一次增量写入（可选再洗版）
        //
        // 全篇一页都没画过（没有译文）⇒ 直接交回原文件字节。
        // 这一步不是为了省事：它让「跑了一遍没改动」这件事可被逐字节验证。
        if !drewAnything {
            report.unchangedDocument = true
            report.inputBytes = document.data.count
            report.outputBytes = document.data.count
            report.warnings.append("没有任何页面需要改动，输出与原文件逐字节相同")
            return Detailed(output: document.data, report: report, layouts: pageLayouts)
        }
        var output = try PDFIncrementalWriter.append(
            original: document.data, document: document, objects: objects)
        report.incrementalBytes = output.count
        if request.scrub {
            let scrubbed = try PDFScrub.rewrite(document: document, overrides: objects)
            output = scrubbed.data
            report.scrubbed = true
            report.droppedObjects = scrubbed.droppedObjects
        }
        report.inputBytes = document.data.count
        report.outputBytes = output.count
        report.totalOverflowLines = report.pages.reduce(0) { $0 + $1.overflowLines }
        if !report.needsReviewPages.isEmpty {
            report.warnings.append("需人工复核的页：\(report.needsReviewPages.map(String.init).joined(separator: ","))")
        }
        return Detailed(output: output, report: report, layouts: pageLayouts)
    }

    // MARK: - 页面工作数据

    struct PageWork {
        var index: Int
        var entry: (ref: PDFRef, dict: [String: PDFValue])
        var page: ILPage
        var content: PDFTextExtractor.PageContent
        var baseline = 0.0
        var floor = 6.0
        /// 块 id → 实际要画的文字（译文或回落原文）。
        /// 在结构阶段算一次就够：`allText` 与逐块排版都要用，
        /// 重复算等于把占位符校验跑两遍（实测这一项就占排版耗时的 60%）。
        var texts: [String: String] = [:]
        var keptOriginal: Set<String> = []
        var placeholderRejected: Set<String> = []
    }

    struct Resolved {
        var text: String
        var keptOriginal: Bool
        var placeholderRejected: Bool
    }

    /// 译文查表。
    ///
    /// **键必须带页码前缀**：`ILBlock.id`（`p0-b0`）只在页内唯一，
    /// 多页文档里第 1 页和第 2 页都有 `p0-b0`，用裸 id 会串号。
    /// `pdf-structure --json` 导出的就是 `p1-p0-b0` 这种带前缀的形态。
    /// 无前缀也接受，方便「只处理一页」的调试场景。
    static func translation(
        _ map: PDFPlaceholder.TranslationMap, blockID: String, pageIndex: Int
    ) -> String? {
        map["p\(pageIndex + 1)-\(blockID)"] ?? map[blockID]
    }

    static func translation(
        _ map: PDFPlaceholder.TranslationMap, table: String, row: Int, column: Int, pageIndex: Int
    ) -> String? {
        let suffix = "\(row):\(column)"
        return map["p\(pageIndex + 1)-\(table):\(suffix)"] ?? map["\(table):\(suffix)"]
    }

    static func resolvedText(
        for block: ILBlock, pageIndex: Int, request: Request
    ) -> Resolved {
        guard let translated = translation(request.translations, blockID: block.id, pageIndex: pageIndex),
              !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Resolved(text: block.text, keptOriginal: true, placeholderRejected: false)
        }
        let check = PDFPlaceholder.verify(source: block.text, translation: translated)
        if check.isClean {
            return Resolved(text: translated, keptOriginal: false, placeholderRejected: false)
        }
        // 占位符损坏：宁可显示原文，也不能让行内对象错位
        return Resolved(text: block.text, keptOriginal: true, placeholderRejected: true)
    }

    /// 单元格原本的字号：取格子里所有 run 的中位数。
    /// 表格单元格没有自己的字号字段，只能从落进来的 run 反推。
    static func cellFontSize(_ cell: ILCell, runs: [PDFTextRun]) -> Double? {
        var sizes: [Double] = []
        for run in runs {
            let center = PDFPoint((run.bbox.x0 + run.bbox.x1) / 2,
                                  (run.bbox.y0 + run.bbox.y1) / 2)
            guard center.x >= cell.box.x0, center.x <= cell.box.x1,
                  center.y >= cell.box.y0, center.y <= cell.box.y1,
                  run.fontSize > 0.5 else { continue }
            sizes.append(run.fontSize)
        }
        guard !sizes.isEmpty else { return nil }
        sizes.sort()
        return sizes[sizes.count / 2]
    }

    static func faceFor(block: ILBlock, regular: PDFFace, bold: PDFFace?) -> PDFFace {
        guard let bold else { return regular }
        let boldGlyphs = block.lines.reduce(0) { sum, line in
            sum + line.spans.filter(\.isBold).reduce(0) { $0 + $1.text.count }
        }
        let total = block.lines.reduce(0) { $0 + $1.text.count }
        return total > 0 && Double(boldGlyphs) / Double(total) > 0.5 ? bold : regular
    }

    static func faceForPlan(
        _ plan: PDFTypeset.Plan, page: ILPage, regular: PDFFace, bold: PDFFace?
    ) -> PDFFace {
        guard let bold else { return regular }
        guard let block = page.blocks.first(where: { $0.id == plan.blockID }) else { return regular }
        return faceFor(block: block, regular: regular, bold: bold)
    }

    /// 页面正文区域：块与表格的并集，向下延伸到页边距。
    static func textRegion(page: ILPage, mediaBox: PDFRect, margin: Double) -> PDFRect {
        let boxes = page.blocks.map(\.box) + page.tables.map(\.box)
        guard var region = boxes.first else {
            return PDFRect(x0: mediaBox.x0 + margin, y0: mediaBox.y0 + margin,
                           x1: mediaBox.x1 - margin, y1: mediaBox.y1 - margin)
        }
        for box in boxes.dropFirst() { region = region.union(box) }
        region.x0 = max(region.x0, mediaBox.x0 + 12)
        region.x1 = min(max(region.x1, region.x0 + 40), mediaBox.x1 - 12)
        region.y1 = min(region.y1, mediaBox.y1 - 12)
        region.y0 = mediaBox.y0 + margin
        return region
    }

    /// 块可用的右边界与下边界。
    ///
    /// 右边界取「同栏最宽行」的右沿：这才是真实的栏内空白。
    /// 不能取整页右边距——那会让左栏文字直接压到右栏上。
    static func blockLimits(
        block: ILBlock, page: ILPage, region: PDFRect, mediaBox: PDFRect,
        obstacles: [PDFRect], margin: Double
    ) -> (right: Double, down: Double) {
        let pageLimit = mediaBox.x1 - 12
        var right = PDFTypeset.columnRightEdge(
            for: block, in: page.blocks, limit: pageLimit)

        // 右边界不能越过「同一纵向带里的右边邻居」。
        //
        // `columnRightEdge` 只看「左边界相同的块」，取它们最宽的右边界——首页的左栏
        // 往往分成两截（前部信息窄、正文宽），于是窄块（通讯作者的电话/邮件行）
        // 会按正文的栏宽去扩，直接压到右栏的前部信息上。
        // 真实样本：`电话：+34-918373112 传真：+34-925360432 电子邮件：…`
        // 一直排到「关键词：木腐真菌…」上，两个字叠成一个。
        for other in page.blocks where other.id != block.id {
            guard other.box.y1 > block.box.y0 + 1,
                  other.box.y0 < block.box.y1 - 1 else { continue }
            guard other.box.x0 >= block.box.x1 - 1 else { continue }
            right = min(right, other.box.x0 - 2)
        }
        // 原框已经贴着邻居时也不要缩到框内（原框是原文放得下的地方）
        right = max(right, block.box.x1)

        // 下方最近的块
        var down = region.y0
        let below = page.blocks
            .filter { $0.id != block.id && $0.box.y1 < block.box.y0 - 1 }
            .filter { abs($0.box.x0 - block.box.x0) <= 24 }
            .sorted { $0.box.y1 > $1.box.y1 }
        if let next = below.first {
            down = max(down, next.box.y1 + 2)
        }
        // 下方障碍物（图、表）不能压
        for obstacle in obstacles
        where obstacle.y1 <= block.box.y0 + 1 && obstacle.intersects(
            PDFRect(x0: block.box.x0, y0: mediaBox.y0, x1: right, y1: block.box.y0)) {
            down = max(down, obstacle.y1 + 2)
        }
        return (right, min(down, block.box.y0))
    }

    /// 没有被任何块/表格覆盖的 run。
    ///
    /// 这些通常是被段落归并丢掉的页眉页脚、页边注、孤立数字。
    /// 数量应该很小；一旦变大，说明 P2 的分块漏了东西，报告里要看得见。
    static func orphanRuns(work: PageWork, tableBoxes: [PDFRect]) -> [PDFTextRun] {
        let boxes = work.page.blocks.map(\.box) + tableBoxes
        return work.content.runs.filter { run in
            guard !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let center = PDFPoint((run.bbox.x0 + run.bbox.x1) / 2,
                                  (run.bbox.y0 + run.bbox.y1) / 2)
            for box in boxes where center.x >= box.x0 - 0.5 && center.x <= box.x1 + 0.5
                && center.y >= box.y0 - 0.5 && center.y <= box.y1 + 0.5 {
                return false
            }
            return true
        }
    }

    // MARK: - 绘制

    /// 一行文字的**排版框**（不是墨迹框）。
    ///
    /// 必须和 `PDFTypeset.plan` 摆放基线用的是同一套模型，否则 R2 会全页误报：
    /// 首行基线相对行顶下移 `clamp(ascent×0.8, 0.75, 0.92)em`，
    /// 若这里改用 hhea 的 ascent（思源宋体 ≈1.16em），算出来的「墨迹顶」会比框顶高 0.24em，
    /// 每一段都会「溢出」——实测 409 页里 213 次全是这么来的。
    /// 字形真实墨迹偶尔超过这个框（全角括号、带声调的字母），交给掩膜的外扩去兜。
    static func inkRect(line: PDFTypeset.Line, size: Double, font: TrueTypeFont) -> PDFRect {
        let ascentEm = Double(font.ascent) / 1000
        let up = min(max(ascentEm * 0.8, 0.75), 0.92) * size
        let down = size * 0.22
        return PDFRect(x0: line.origin.x, y0: line.origin.y - down,
                       x1: line.origin.x + line.width, y1: line.origin.y + up)
    }

    static func appendPlan(
        _ plan: PDFTypeset.Plan, face: PDFFace,
        embed: PDFFontEmbedder.Embedded, boldEmbed: PDFFontEmbedder.Embedded?,
        to body: inout Data
    ) -> [UInt32] {
        guard !plan.lines.isEmpty else { return [] }
        let cid = (face.isBold ? boldEmbed : embed)?.cidForScalar ?? embed.cidForScalar
        var missing: [UInt32] = []
        var out = Data()
        out.append(contentsOf: Array("q\nBT\n".utf8))
        out.append(contentsOf: Array("/\(face.resourceName) \(PDFTextStamp.format(plan.fontSize)) Tf\n".utf8))
        out.append(contentsOf: Array("0 g\n".utf8))
        for line in plan.lines where !line.text.isEmpty {
            let encoded = PDFFontEmbedder.encode(text: line.text, cidForScalar: cid)
            missing += encoded.missing
            out.append(contentsOf: Array(
                "1 0 0 1 \(PDFTextStamp.format(line.origin.x)) \(PDFTextStamp.format(line.origin.y)) Tm\n".utf8))
            out.append(contentsOf: Array("<".utf8))
            let hex = Array("0123456789ABCDEF".utf8)
            for byte in encoded.data {
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
            out.append(contentsOf: Array("> Tj\n".utf8))
        }
        out.append(contentsOf: Array("ET\nQ\n".utf8))
        body.append(out)
        return missing
    }

    /// 孤立 run：按原坐标、原字号重画。
    static func drawRuns(
        _ runs: [PDFTextRun], face: PDFFace,
        embed: PDFFontEmbedder.Embedded, boldEmbed: PDFFontEmbedder.Embedded?,
        shift: (PDFTextRun) -> Double = { _ in 0 }
    ) -> Data {
        var out = Data()
        for run in runs where !run.text.isEmpty {
            let size = max(1, run.fontSize)
            let width = PDFTextMetrics.width(run.text, font: face.font, size: size)
            var x = run.origin.x
            // 若我们字体比原字体宽，右对齐的页眉会往右溢出 → 往左收一点
            if run.endPoint.x < run.origin.x {
                x = run.origin.x - max(0, width - abs(run.endPoint.x - run.origin.x))
            }
            let encoded = PDFFontEmbedder.encode(text: run.text, cidForScalar: embed.cidForScalar)
            guard !encoded.data.isEmpty else { continue }
            // 宋体比原字体宽 5~10%，按自然宽度重画会把词间空隙吃掉
            // （实测「Expanded Polystyrene」变成「ExpandedPolystyrene」）。
            // 用 Tz 把每个 run 横向压回它原本的推进宽度：位置一个点不动，
            // 只保证右边界仍然落在原来的地方。收得比 0.8 更狠就不像话了，因此设下限。
            let target = max(1, run.advance)
            let horizontalScale = min(1, max(0.8, target / max(width, 0.01)))
            out.append(contentsOf: Array("q\nBT\n/".utf8))
            out.append(contentsOf: Array("\(face.resourceName) \(PDFTextStamp.format(size)) Tf\n".utf8))
            out.append(contentsOf: Array(
                "0 g\n\(PDFTextStamp.format(horizontalScale * 100)) Tz\n".utf8))
            out.append(contentsOf: Array(
                "1 0 0 1 \(PDFTextStamp.format(x)) \(PDFTextStamp.format(run.origin.y + shift(run))) Tm\n<".utf8))
            let hex = Array("0123456789ABCDEF".utf8)
            for byte in encoded.data {
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
            out.append(contentsOf: Array("> Tj\nET\nQ\n".utf8))
        }
        return out
    }

    /// 页脚注释带：从页面底部往上排，顶部画一条分隔细线。
    static func drawNotes(
        _ notes: [(anchor: Int, lines: [String], from: PDFRect)],
        region: PDFRect, mediaBox: PDFRect, face: PDFFace,
        embed: PDFFontEmbedder.Embedded, maxBandRatio: Double,
        into report: inout PageReport,
        record: ((PDFRect, String?) -> Void)? = nil
    ) -> Data {
        let size = max(6, min(9, (report.floorFontSize > 0 ? report.floorFontSize : 9) * 0.9))
        let lineHeight = size * 1.25
        let bandTop = mediaBox.y0 + mediaBox.height * maxBandRatio
        var y = mediaBox.y0 + 12
        var out = Data()
        var drawnLines = 0

        for note in notes {
            for (offset, line) in note.lines.enumerated() {
                let text = offset == 0 ? "[\(note.anchor)] \(line)" : "    \(line)"
                let width = PDFTextMetrics.width(text, font: face.font, size: size)
                guard y + lineHeight <= bandTop else {
                    report.needsReview = true
                    return out
                }
                let encoded = PDFFontEmbedder.encode(text: text, cidForScalar: embed.cidForScalar)
                guard !encoded.data.isEmpty else { continue }
                out.append(contentsOf: Array("q\nBT\n/\(face.resourceName) \(PDFTextStamp.format(size)) Tf\n".utf8))
                out.append(contentsOf: Array(
                    "0 g\n1 0 0 1 \(PDFTextStamp.format(region.x0)) \(PDFTextStamp.format(y)) Tm\n<".utf8))
                let hex = Array("0123456789ABCDEF".utf8)
                for byte in encoded.data {
                    out.append(hex[Int(byte >> 4)])
                    out.append(hex[Int(byte & 0x0F)])
                }
                out.append(contentsOf: Array("> Tj\nET\nQ\n".utf8))
                record?(PDFRect(x0: region.x0, y0: y + size * 0.05,
                                x1: region.x0 + width, y1: y + size * 1.05), text)
                y += lineHeight
                drawnLines += 1
            }
        }
        if drawnLines > 0 {
            let rule = "q\n0.5 w\n0.55 g\n\(PDFTextStamp.format(region.x0)) \(PDFTextStamp.format(y + 2)) m "
                + "\(PDFTextStamp.format(region.x1)) \(PDFTextStamp.format(y + 2)) l\nS\nQ\n"
            out.append(contentsOf: Array(rule.utf8))
            record?(PDFRect(x0: region.x0, y0: y + 1, x1: region.x1, y1: y + 3), nil)
        }
        return out
    }

    /// 表格邻接块：落在「整页表格的纵向带」里，或横向紧贴表格右侧。
    ///
    /// P2 的表格检测可能漏列（右边界只到第三列），未检出的单元格文字会掉成块。
    /// 这些块如果当正文重排，会直接压在表格线上——**叠字比不翻译更糟**，
    /// 所以一律钉在原位，并在报告里标出来（提示 P2 的表格检测需要修）。
    static func isNearTable(_ block: ILBlock, tables: [ILTable]) -> Bool {
        guard !tables.isEmpty else { return false }
        var band = tables[0].box
        for table in tables.dropFirst() { band = band.union(table.box) }
        let centerY = (block.box.y0 + block.box.y1) / 2
        let centerX = (block.box.x0 + block.box.x1) / 2
        let inBand = centerY >= band.y0 - 4 && centerY <= band.y1 + 4
        let inSpan = centerX >= band.x0 - 12 && centerX <= band.x1 + 160
        return inBand && inSpan
    }

    /// 等宽字体块：代码、终端输出、清单。
    ///
    /// **代码不翻译**——翻译会破坏语法，而且等宽列对齐依赖逐字符宽度。
    /// 钉住后按原位置用正文字体重画：行首缩进（N 个空格）仍然成立，
    /// 但行内列对齐会有偏移，这是换字体必然的代价，报告里如实标注。
    static func isCodeBlock(_ block: ILBlock) -> Bool {
        let markers = ["courier", "mono", "consol", "menlo", "lucidaconsole", "cmtt", "fixed"]
        return block.lines.contains { line in
            line.spans.contains { span in
                let name = span.fontName.lowercased()
                return markers.contains { name.contains($0) }
            }
        }
    }

    /// 带点线引导（目录条目）的块。
    ///
    /// 「第 3 章 ...... 45」这种结构里，点线是独立的文本 run，
    /// 译文一变长，点线就与条目错位，看起来像乱码。P3 不重建点线，
    /// 所以这类块钉住不排——宁可目录保持原文，也不输出错位的点线。
    static func hasDotLeader(_ block: ILBlock) -> Bool {
        block.lines.contains { line in
            line.text.contains("....") || line.text.contains("……") || line.text.contains("···")
        }
    }

    /// 计划矩形两两相交计数，并给出示例对。
    static func countOverlaps(plans: [PDFTypeset.Plan]) -> (count: Int, samples: [String]) {
        let rects: [(id: String, rect: PDFRect)] = plans.compactMap { plan in
            guard !plan.lines.isEmpty else { return nil }
            return (plan.blockID,
                    PDFRect(x0: plan.box.x0,
                            y0: plan.box.y1 - Double(plan.lines.count) * plan.lineHeight,
                            x1: plan.box.x1, y1: plan.box.y1))
        }
        var pairs = 0
        var samples: [String] = []
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count
            where rects[i].rect.intersectionArea(rects[j].rect) > 1 {
                pairs += 1
                if samples.count < 5 {
                    let a = rects[i].rect, b = rects[j].rect
                    samples.append(String(
                        format: "%@[%.0f-%.0f,%.0f-%.0f]×%@[%.0f-%.0f,%.0f-%.0f]",
                        rects[i].id, a.x0, a.x1, a.y0, a.y1,
                        rects[j].id, b.x0, b.x1, b.y0, b.y1))
                }
            }
        }
        return (pairs, samples)
    }

    /// 碎片块：文本极短且不含实义字符（标点、符号、单个数字）。
    static func isPinned(_ block: ILBlock) -> Bool {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 极小的框（24pt 宽、一行高）大多是孤立符号/页码/项目符号，
        // 但它们也可能是**表格的表头单元格**（「Sample」「Sl.no」「Table 2」）——
        // 那些是实打实要翻的字。所以「窄」只是必要条件，还要文字本身短、或者不含字母。
        if block.box.width < 24 && block.box.height <= block.fontSize * 1.8 {
            return text.count <= 4 || !text.contains(where: { $0.isLetter })
        }
        guard text.count <= 2 else { return false }
        let meaningful = text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                && !CharacterSet.decimalDigits.contains(scalar)
        }
        return !meaningful
    }

    /// 「表格纵列」块：一行一个单元格、行行很短、数字占多数。
    ///
    /// `PDFTableDetector` 只认有框线的表；期刊里大量表格靠空白对齐（无线表），
    /// 这种表的一列会被行归并成**一个普通段落块**：表头 + 4 个数值。
    /// 一旦送去翻译再按段落重排，数值会被当成正文连排，几行数字叠在一起——
    /// 实测「0.305 / 0.126 / 0.351 / 0.854」就叠成一行 `0..3531 0.854`。
    ///
    /// 钉住不动是这里唯一安全的处理：数字排错比不翻译糟得多。
    static func isTabularStrip(_ block: ILBlock) -> Bool {
        guard block.lines.count >= 3 else { return false }
        var numeric = 0
        for line in block.lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 32 else { return false }
            var digits = 0
            var letters = 0
            for scalar in text.unicodeScalars {
                if CharacterSet.decimalDigits.contains(scalar) { digits += 1 }
                if CharacterSet.letters.contains(scalar) { letters += 1 }
            }
            if digits > 0 && digits >= letters { numeric += 1 }
        }
        return numeric * 2 >= block.lines.count
    }

    /// 这个块「整块保持原字节、不翻译」吗？
    ///
    /// 排版阶段用它决定不排版；翻译阶段（`PDFRebuildPipeline`）也应该用它跳过推理——
    /// 图表里那 90 多个品种名送进模型纯粹是浪费：翻了也不会被用上。
    public static func keepsOriginal(_ block: ILBlock, page: ILPage) -> Bool {
        isPinned(block)
            || isNearTable(block, tables: page.tables)
            || hasDotLeader(block)
            || isCodeBlock(block)
            || isTabularStrip(block)
            || isInsideChart(block, charts: page.charts)
            || isFormulaBlock(block)
            || isRotatedLabel(block)
    }

    /// 旋转的小字：图边竖排的出版方水印（`Int. Microbiol.`）、侧边标签。
    ///
    /// 这类文字属于插图的一部分：翻成中文没有意义，重排后还会压到图上
    /// （真实样本 10 页里两条 6 pt 的 `Int. Microbiol.` 正好贴在插图右缘）。
    /// 判据只看「角度非零 + 单行 + 很短」——正文永远不旋转，
    /// 横排的表格/图注也永远不会命中。
    public static func isRotatedLabel(_ block: ILBlock) -> Bool {
        guard block.lines.count <= 2 else { return false }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80 else { return false }
        return block.lines.contains { abs($0.angle) > 0.05 }
    }

    /// 块是否落在矢量图表区域里。
    ///
    /// 图表里的文字（刻度、轴标题、图例、竖排品种名）没有任何翻译价值：
    /// 翻对了也没人看，翻错就会像真实样本那样把柱子压满「我曾经是」「哇，超级英雄」。
    /// 这里按**块中心**落在区域内判断——按相交判断会把紧贴图表的正文一起钉住。
    ///
    /// 例外：图注（`Fig. 3. …` / `Table 2 …`）是给人读的句子，仍然要翻。
    static func isInsideChart(_ block: ILBlock, charts: [ILChart]) -> Bool {
        guard !charts.isEmpty else { return false }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCaption(text) { return false }
        let box = block.box
        return charts.contains { chart in
            // ① 整块落在（略外扩的）区域里：轴标题、刻度、图内标注都属这一类。
            //    12pt 余量是必需的——纵轴刻度数字往往贴在绘图区左侧外面一点
            //    （真实样本 x0 差 8pt，竖排轴标题差 16pt）。
            //    只看「中心在内」不够：横轴标题的块中心会刚好落在绘图区下沿之外。
            let region = chart.box.expanded(by: 12)
            if box.x0 >= region.x0, box.x1 <= region.x1,
               box.y0 >= region.y0, box.y1 <= region.y1 { return true }

            // ② 贴在绘图区侧边的单行短标签：图例常排在右边框外面（真实样本里
            //    「Sorghum Fiber 100%」在绘图区右侧 13pt 处），整块并不在图内。
            //    限制「单行、≤48 字、不以句号收尾」，避免把相邻栏的正文吸进来。
            guard text.count <= 48, box.height <= 16,
                  !text.hasSuffix("."), !text.hasSuffix("。") else { return false }
            guard box.verticalOverlap(chart.box) >= 0.5 else { return false }
            let dx = max(chart.box.x0 - box.x1, box.x0 - chart.box.x1, 0)
            return dx <= 40
        }
    }

    /// 图注/表注：以 Fig./Figure/Table/图/表 开头，且不是单个词。
    static func isCaption(_ text: String) -> Bool {
        guard text.count >= 8 else { return false }
        let head = text.prefix(12).lowercased()
        for marker in ["fig.", "fig ", "figure", "table", "图 ", "图1", "图2", "图3", "表 ", "表1", "表2"] {
            if head.hasPrefix(marker) { return true }
        }
        return false
    }

    /// 公式块：整段基本是数学排版，不是句子。
    ///
    /// 真实样本里 `S_wr = P_maxima / P_minima (1)` 被翻成「Swr = 最大值 … 皮米纳」，
    /// 下标被当成单词。公式没有人指望它被翻译，原地不动才是对的。
    /// 判据刻意收紧：必须有等号/关系符，符号占比高，且行数很少。
    static func isFormulaBlock(_ block: ILBlock) -> Bool {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 220, block.lines.count <= 4 else { return false }
        let mathy = CharacterSet(charactersIn: "=±×÷≈≤≥√∑∫∏∂∞∆ΓαβγδθλμσφωΩ→←↔·′″^_/")
        var symbols = 0
        var letters = 0
        var digits = 0
        for scalar in text.unicodeScalars {
            if mathy.contains(scalar) { symbols += 1 }
            else if CharacterSet.letters.contains(scalar) { letters += 1 }
            else if CharacterSet.decimalDigits.contains(scalar) { digits += 1 }
        }
        let total = max(1, symbols + letters + digits)
        let hasRelation = text.contains("=") || text.contains("≈") || text.contains("≤")
            || text.contains("≥")
        guard hasRelation else { return false }
        // 典型公式就是「一行、很短、带等号」：真实样本里的 `Swr = Pmaxima`（16 字、高 21pt，
        // 分子分母被拆成上下两行）、`= (Swr + 1)`（11 字）都属于这一类。
        // 变量名是字母，符号占比往往只有 0.08，所以不能只靠符号比例。
        if text.count <= 40 && block.box.height <= 26 { return true }
        let symbolRatio = Double(symbols) / Double(total)
        // 长一点的公式（多行推导）：符号占比高、字母占比低
        return symbolRatio >= 0.22 && Double(letters) / Double(total) <= 0.55
    }

    /// 页眉 / 页脚：贴着页面上下边缘的单行短文本。
    ///
    /// 这类块（期刊的 running head、页码、DOI 行）参与页内重排时会被当成正文推进流里，
    /// 结果跑到页面中间、压在图上。保持原位、保持原文才是对的。
    static func isRunningHeadOrFoot(_ block: ILBlock, page: ILPage) -> Bool {
        guard block.lines.count == 1 else { return false }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 120 else { return false }
        let band = 55.0
        return block.box.y1 >= page.height - band || block.box.y0 <= band
    }

    /// 「每个块「新顶边 − 原顶边」的位移，用于让孤立 run 跟随段落。
    static func planShifts(
        plans: [PDFTypeset.Plan], page: ILPage
    ) -> [(x0: Double, x1: Double, oldTop: Double, newTop: Double)] {
        plans.compactMap { plan in
            guard let block = page.blocks.first(where: { $0.id == plan.blockID }) else { return nil }
            return (block.box.x0, block.box.x1, block.box.y1, plan.box.y1)
        }
    }

    static func shiftFor(
        run: PDFTextRun,
        shifts: [(x0: Double, x1: Double, oldTop: Double, newTop: Double)]
    ) -> Double {
        let y = (run.bbox.y0 + run.bbox.y1) / 2
        var best: (distance: Double, shift: Double)?
        for item in shifts {
            // 不能用「横向重叠」判归属：项目符号在段落左外侧，与正文不重叠。
            // 改用「横向间隙」——符号离段落几 pt，页眉离得远，自然区分开。
            let overlap = min(item.x1, run.bbox.x1) - max(item.x0, run.bbox.x0)
            let gap = max(item.x0 - run.bbox.x1, run.bbox.x0 - item.x1, 0)
            guard overlap > 0 || gap <= 24 else { continue }
            // 段落顶边与这一行的垂直距离：取最近的，且必须同属一片区域
            let distance = abs(item.oldTop - y)
            guard distance < max(28, run.fontSize * 2.2) else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, item.newTop - item.oldTop)
            }
        }
        return best?.shift ?? 0
    }

    /// 选一个全文档都没用过的字体资源名。
    static func uniqueFontName(
        document: PDFDocument, entries: [(ref: PDFRef, dict: [String: PDFValue])], preferred: String
    ) -> String {
        var used = Set<String>()
        for entry in entries {
            let resources = document.resolvedResources(entry.dict["Resources"])
            if case .reference(let r)? = resources["Font"] {
                used.formUnion((try? document.resolve(r))?.dictionaryValue?.keys ?? [:].keys)
            } else if let inline = resources["Font"]?.dictionaryValue {
                used.formUnion(inline.keys)
            }
        }
        if !used.contains(preferred) { return preferred }
        var index = 10
        while used.contains("LNR\(index)") { index += 1 }
        return "LNR\(index)"
    }
}
