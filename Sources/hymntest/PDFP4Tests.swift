import Foundation
import CoreGraphics
import HymnCore

/// P4 测试集：渲染、掩膜、SSIM、结构比对、阅读顺序、修复指令、闭环。
///
/// 这一组的写法刻意「反截图」：不比对渲染出的 PNG，而是断言可证伪的性质——
/// 同一页渲染两次必须逐字节相同；结构区少一个像素就必须报；
/// 三个汉字大小的墨点消失必须不报；修复指令只能越修越保守。
public func pdfP4Suite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-p4"

    // MARK: - 渲染

    let fixture = PDFFixtureP2.blankPage()
    let renderOptions = PDFPageRenderer.Options(dpi: 144)

    let first = PDFPageRenderer.render(data: fixture, index: 0, options: renderOptions)
    let second = PDFPageRenderer.render(data: fixture, index: 0, options: renderOptions)
    results.append(check(
        suite: suite, "render-available", first != nil,
        detail: first.map { "\($0.width)×\($0.height) @144dpi" } ?? "渲染失败"))

    results.append(check(
        suite: suite, "render-deterministic",
        first != nil && second != nil && first!.rgb == second!.rgb,
        detail: "同一页渲染两次逐字节相同（\(first?.rgb.count ?? 0) 字节）"))

    results.append(check(
        suite: suite, "render-size-a4",
        first.map { $0.width == 1190 && $0.height == 1684 } ?? false,
        detail: "A4 595×842pt @144dpi 应为 1190×1684，实际 "
            + (first.map { "\($0.width)×\($0.height)" } ?? "-")))

    results.append(check(
        suite: suite, "render-blank-is-white",
        first.map { $0.inkPixelCount() == 0 } ?? false,
        detail: "空白页非白像素 \(first?.inkPixelCount() ?? -1)"))

    results.append(check(
        suite: suite, "render-bad-data",
        PDFPageRenderer.render(data: Data([0x25, 0x50, 0x44, 0x46]), index: 0) == nil,
        detail: "非法输入应返回 nil 而不是崩溃"))

    // MARK: - 掩膜

    guard let image = first else { return results }
    let box = PDFRect(x0: 72, y0: 700, x1: 272, y1: 720)
    let mask = PDFPixelMask.build(image: image, rects: [box], dilatePoints: 0)
    let centerX = Int(image.pixelX(172)), centerY = Int(image.pixelY(710))
    let outsideX = Int(image.pixelX(500)), outsideY = Int(image.pixelY(150))
    results.append(check(
        suite: suite, "mask-hit",
        mask.contains(x: centerX, y: centerY) && !mask.contains(x: outsideX, y: outsideY),
        detail: "框内命中 / 框外不命中"))

    // 200×20pt @2× = 400×40 px = 16000 px，允许 ±5% 的取整误差
    let expected = 400.0 * 40.0
    results.append(check(
        suite: suite, "mask-area",
        abs(Double(mask.coveredPixels) - expected) / expected < 0.05,
        detail: "覆盖 \(mask.coveredPixels) px，期望 \(Int(expected))"))

    let dilated = PDFPixelMask.build(image: image, rects: [box], dilatePoints: 3)
    results.append(check(
        suite: suite, "mask-dilate",
        dilated.coveredPixels > mask.coveredPixels,
        detail: "膨胀 3pt 后 \(dilated.coveredPixels) > \(mask.coveredPixels)"))

    // MARK: - 像素差

    let zeroDiff = PDFSimilarity.diff(image, image, mask: nil, tolerance: 2)
    results.append(check(
        suite: suite, "diff-identical", zeroDiff.diffPixels == 0 && zeroDiff.maxDelta == 0,
        detail: "同图最大差 \(zeroDiff.maxDelta)"))

    // 位移检测要在一张「有内容」的图上做：空白图平移一行仍然全白，什么也测不出来
    var withBar = image
    fill(&withBar, PDFRect(x0: 100, y0: 300, x1: 400, y1: 320), value: 0)
    var shifted = withBar
    let stride = withBar.width * 3
    shifted.rgb = Array(withBar.rgb.dropFirst(stride * 3)) + Array(repeating: 255, count: stride * 3)
    let shiftedDiff = PDFSimilarity.diff(withBar, shifted, mask: nil, tolerance: 2)
    results.append(check(
        suite: suite, "diff-shift-detected",
        shiftedDiff.diffPixels > 1000 && shiftedDiff.maxDelta == 255,
        detail: "内容整体下移 3 行 → 差异 \(shiftedDiff.diffPixels) px，最大差 \(shiftedDiff.maxDelta)"))

    // MARK: - SSIM

    let gray = image.gray()
    let selfSSIM = PDFSimilarity.ssim(gray, gray, width: image.width, height: image.height)
    results.append(check(
        suite: suite, "ssim-identical", abs(selfSSIM.mean - 1) < 1e-9,
        detail: String(format: "自比 %.9f", selfSSIM.mean)))

    // 半黑半白 vs 反相：结构完全不同，SSIM 必须明显低
    var left = [UInt8](repeating: 255, count: 400 * 400)
    var right = left
    for y in 0..<400 {
        for x in 0..<400 {
            if x < 200 { left[y * 400 + x] = 0 } else { right[y * 400 + x] = 0 }
        }
    }
    let inverted = PDFSimilarity.ssim(left, right, width: 400, height: 400)
    results.append(check(
        suite: suite, "ssim-inverted-low", inverted.mean < 0.5,
        detail: String(format: "反相 %.4f", inverted.mean)))

    // MARK: - 结构比对

    let sameStructure = PDFStructuralDiff.compare(image, image)
    results.append(check(
        suite: suite, "structure-identical",
        sameStructure.lostPixels == 0 && sameStructure.gainedPixels == 0,
        detail: "同图结构差 \(sameStructure.diffPixels)"))

    // 在「有图」的页面上抹掉一块 200×200pt 的实心方块 → 必须报丢失
    var withBlock = image
    fill(&withBlock, PDFRect(x0: 100, y0: 400, x1: 300, y1: 600), value: 0)
    var withoutBlock = withBlock
    fill(&withoutBlock, PDFRect(x0: 100, y0: 400, x1: 300, y1: 600), value: 255)
    let lostBlock = PDFStructuralDiff.compare(withBlock, withoutBlock)
    results.append(check(
        suite: suite, "structure-lost-block", lostBlock.lostPixels > 10000,
        detail: "抹掉 200×200pt 实心块 → 丢失 \(lostBlock.lostPixels) px"))

    // 只有小墨点（模拟文字）消失 → 不应算结构丢失
    var withGlyphs = image
    for i in 0..<40 {
        let x = 100 + Double(i % 20) * 8
        let y = 500 + Double(i / 20) * 12
        fill(&withGlyphs, PDFRect(x0: x, y0: y, x1: x + 4, y1: y + 6), value: 0)
    }
    let lostGlyphs = PDFStructuralDiff.compare(withGlyphs, image)
    results.append(check(
        suite: suite, "structure-ignores-glyphs", lostGlyphs.lostPixels == 0,
        detail: "40 个 4×6pt 墨点消失 → 结构丢失 \(lostGlyphs.lostPixels) px"))

    // MARK: - 阅读顺序

    let stacked = [
        PDFReadOrder.Item(id: "a", box: PDFRect(x0: 72, y0: 700, x1: 400, y1: 720)),
        PDFReadOrder.Item(id: "b", box: PDFRect(x0: 72, y0: 660, x1: 400, y1: 680)),
    ]
    results.append(check(
        suite: suite, "order-single-column",
        PDFReadOrder.check(items: stacked).inversions == 0,
        detail: "两段自上而下，逆序 0"))

    let swapped = [stacked[1], stacked[0]]
    results.append(check(
        suite: suite, "order-inversion-detected",
        PDFReadOrder.check(items: swapped).inversions > 0,
        detail: "顺序颠倒后逆序 \(PDFReadOrder.check(items: swapped).inversions)"))

    let twoColumns = [
        PDFReadOrder.Item(id: "l1", box: PDFRect(x0: 72, y0: 700, x1: 280, y1: 720)),
        PDFReadOrder.Item(id: "l2", box: PDFRect(x0: 72, y0: 660, x1: 280, y1: 680)),
        PDFReadOrder.Item(id: "r1", box: PDFRect(x0: 320, y0: 700, x1: 520, y1: 720)),
        PDFReadOrder.Item(id: "r2", box: PDFRect(x0: 320, y0: 660, x1: 520, y1: 680)),
    ]
    let columns = PDFReadOrder.check(items: twoColumns)
    results.append(check(
        suite: suite, "order-two-columns",
        columns.columns == 2 && columns.inversions == 0,
        detail: "两栏识别 \(columns.columns) 栏，逆序 \(columns.inversions)"))

    // MARK: - 修复指令

    func pageResult(_ findings: [PDFSimilarityAnalyzer.Finding], page: Int = 1)
        -> PDFSimilarityAnalyzer.Result {
        var pageResult = PDFSimilarityAnalyzer.PageResult()
        pageResult.page = page
        pageResult.findings = findings
        pageResult.passed = findings.allSatisfy { $0.severity != .error }
        var result = PDFSimilarityAnalyzer.Result()
        result.pages = [pageResult]
        result.errorCount = pageResult.errors
        return result
    }

    var layout = PDFPageLayout(page: 0, mediaBox: PDFRect(x0: 0, y0: 0, x1: 595, y1: 842))
    layout.items = [PDFPageLayout.Item(
        id: "p0-b0", kind: .block, box: PDFRect(x0: 72, y0: 600, x1: 500, y1: 700),
        lines: [PDFRect(x0: 72, y0: 600, x1: 500, y1: 620)],
        intent: "文本", drawn: "文本", source: "text", fontSize: 12, tier: "shrink")]

    let overflow = PDFSimilarityAnalyzer.Finding(
        check: "R2", page: 1, blockID: "p0-b0", severity: .error, code: "text-overflow",
        metric: 3, limit: 0, detail: "", repairable: true, box: nil)
    let derived = PDFRepair.derive(from: pageResult([overflow]), layouts: [0: layout], round: 1)
    results.append(check(
        suite: suite, "repair-shrink-derived",
        derived.repairs.page(0)?.blocks["p0-b0"]?.minFontSize == 10.8,
        detail: "12pt 溢出 → 下限 "
            + String(format: "%.1f", derived.repairs.page(0)?.blocks["p0-b0"]?.minFontSize ?? -1)))

    let orderFinding = PDFSimilarityAnalyzer.Finding(
        check: "R7", page: 1, blockID: "p0-b0", severity: .error, code: "reading-order",
        metric: 2, limit: 0, detail: "", repairable: true, box: nil)
    let reflow = PDFRepair.derive(from: pageResult([orderFinding]), layouts: [0: layout], round: 1)
    results.append(check(
        suite: suite, "repair-reflow-derived",
        reflow.repairs.page(0)?.forceReflow == true,
        detail: "阅读顺序错误 → 整页重排"))

    // 已经缩到 5.6pt 还溢出 → 回落原文（而不是继续缩到看不清）
    layout.items[0].fontSize = 5.6
    let tiny = PDFRepair.derive(from: pageResult([overflow]), layouts: [0: layout], round: 1)
    results.append(check(
        suite: suite, "repair-revert-when-tiny",
        tiny.repairs.page(0)?.blocks["p0-b0"]?.revertToSource == true,
        detail: "5.6pt 仍溢出 → 回落原文"))

    // 指令单调：合并两次取更保守的一方
    var a = PDFRepair.Set()
    var pa = PDFRepair.PageRepair()
    pa.blocks["p0-b0"] = PDFRepair.BlockRepair(minFontSize: 10, rightExpand: 1, downExpand: 1)
    a.pages[0] = pa
    var b = PDFRepair.Set()
    var pb = PDFRepair.PageRepair()
    pb.blocks["p0-b0"] = PDFRepair.BlockRepair(minFontSize: 8, revertToSource: true)
    b.pages[0] = pb
    a.merge(b)
    let merged = a.page(0)?.blocks["p0-b0"]
    results.append(check(
        suite: suite, "repair-merge-monotonic",
        merged?.minFontSize == 8 && merged?.revertToSource == true,
        detail: "合并后 minFontSize \(merged?.minFontSize ?? -1)，revert \(merged?.revertToSource ?? false)"))

    // 缺字不可由排版修复 → 不进 repairs，进人工清单
    let glyphFinding = PDFSimilarityAnalyzer.Finding(
        check: "R4", page: 1, blockID: "p0-b0", severity: .error, code: "glyph-missing",
        metric: 1, limit: 0, detail: "", repairable: false, box: nil)
    let unreachable = PDFRepair.derive(from: pageResult([glyphFinding]), layouts: [0: layout], round: 1)
    results.append(check(
        suite: suite, "repair-skip-unfixable",
        unreachable.repairs.isEmpty && unreachable.manual.count == 1,
        detail: "缺字 → repairs 空、人工 \(unreachable.manual.count) 条"))

    // MARK: - 端到端：排版 → 分析 → 收敛

    guard let fontURL = p3FontURLForP4("LinguaNovaSong-Regular.ttf"),
          let font = try? TrueTypeFont(url: fontURL) else {
        results.append(check(suite: suite, "font-available", false, detail: "缺少字体"))
        return results
    }

    if let document = try? PDFDocument(data: fixture),
       let stamped = try? PDFStamper.stamp(
        document: document, pageIndex: 0, text: "综合比对链路测试：这一行会被驱逐、重排、再验证。",
        font: font, fontSize: 14, origin: (x: 72, y: 700)) {
        results.append(check(
            suite: suite, "e2e-typeset-stamp", true,
            detail: "\(stamped.output.count) 字节"))

        if let stampedDoc = try? PDFDocument(data: stamped.output) {
            let outcome = try? PDFVerifyLoop.run(
                document: stampedDoc,
                faces: PDFTypesetEngine.FaceSet(regular: font),
                request: PDFTypesetEngine.Request(),
                options: { var o = PDFVerifyLoop.Options(); o.maxRounds = 1; return o }())
            results.append(check(
                suite: suite, "e2e-loop-runs", outcome != nil,
                detail: outcome.map { "\($0.rounds.count) 轮，页 \($0.analysis.pages.count)" } ?? "失败"))

            if let outcome {
                let page = outcome.analysis.pages.first
                results.append(check(
                    suite: suite, "e2e-structure-intact",
                    (page?.structureLost ?? -1) == 0,
                    detail: "结构丢失 \(page?.structureLost ?? -1) px"))
                results.append(check(
                    suite: suite, "e2e-report-json",
                    (try? JSONEncoder().encode(outcome.analysis)) != nil,
                    detail: "分析结果可编码为 JSON"))
                results.append(check(
                    suite: suite, "e2e-page-count", outcome.report.pages.count == 1,
                    detail: "页数 \(outcome.report.pages.count)"))
                results.append(check(
                    suite: suite, "e2e-content-hash",
                    outcome.layouts[0]?.contentHash.isEmpty == false,
                    detail: "内容哈希 \(outcome.layouts[0]?.contentHash ?? "-")"))
            }
        }
    }

    return results
}

// MARK: - 工具

private func fill(_ image: inout PDFPageImage, _ rect: PDFRect, value: UInt8) {
    let mask = PDFPixelMask.build(image: image, rects: [rect], dilatePoints: 0)
    for y in 0..<image.height {
        for x in 0..<image.width where mask.contains(x: x, y: y) {
            let i = (y * image.width + x) * 3
            image.rgb[i] = value
            image.rgb[i + 1] = value
            image.rgb[i + 2] = value
        }
    }
}

private func p3FontURLForP4(_ name: String) -> URL? {
    let thisFile = URL(fileURLWithPath: #filePath)
    let root = thisFile.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = root.appendingPathComponent("Resources/Fonts/\(name)")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}
