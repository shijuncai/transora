import Foundation
import HymnCore

/// P3 测试集：度量、断行禁则、占位符、三档投放、页内重排、端到端写回。
///
/// 这些用例的共同点是「断言一条不该被破坏的性质」而不是「比对一张截图」：
/// 行首不出现句号、字号不低于下限、排完的块两两不重叠、原文真的消失了。
/// 截图会随字体版本变，性质不会。
public func pdfP3Suite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-p3"

    guard let fontURL = p3FontURL("LinguaNovaSong-Regular.ttf"),
          let font = try? TrueTypeFont(url: fontURL) else {
        results.append(check(
            suite: suite, "font-available", false,
            detail: "找不到 Resources/Fonts/LinguaNovaSong-Regular.ttf（先跑 Scripts/make-fonts.sh）"))
        return results
    }
    let face = PDFFace(font: font, resourceName: "LNR1", isBold: false)

    // MARK: - 度量

    let single = PDFTextMetrics.width("中", font: font, size: 12)
    let double = PDFTextMetrics.width("中中", font: font, size: 12)
    results.append(check(
        suite: suite, "metrics-linear",
        single > 0 && abs(double - single * 2) < 0.01,
        detail: "「中」\(round(single * 100) / 100)pt ×2 = \(round(double * 100) / 100)pt"))

    results.append(check(
        suite: suite, "metrics-scale",
        abs(PDFTextMetrics.width("中文测试", font: font, size: 24)
            - PDFTextMetrics.width("中文测试", font: font, size: 12) * 2) < 0.01,
        detail: "宽度与字号成正比"))

    results.append(check(
        suite: suite, "metrics-missing",
        PDFTextMetrics.missingScalars("中文\u{10FFFD}", font: font).count == 1,
        detail: "私用区码位应报缺字"))

    // MARK: - 断行与禁则

    let size = 12.0
    let charWidth = PDFTextMetrics.width("字", font: font, size: size)

    // 「。」不能出现在行首：10 个字 + 句号，宽度只够 10 个字
    let kinsokuText = "一二三四五六七八九十。二三四五六七八九十。"
    let kinsokuLines = PDFLineBreaker.breakLines(
        text: kinsokuText, font: font, size: size, maxWidth: charWidth * 10 + 0.1)
    results.append(check(
        suite: suite, "kinsoku-no-leading-period",
        kinsokuLines.allSatisfy { !$0.text.hasPrefix("。") },
        detail: "行首句号 \(kinsokuLines.filter { $0.text.hasPrefix("。") }.count) 处"))

    // 「（」不能留在行尾
    let bracketText = "一二三四五六七八九（十）一二三四五六七八九十一"
    let bracketLines = PDFLineBreaker.breakLines(
        text: bracketText, font: font, size: size, maxWidth: charWidth * 10 + 0.1)
    results.append(check(
        suite: suite, "kinsoku-no-trailing-open",
        bracketLines.allSatisfy { !$0.text.hasSuffix("（") },
        detail: "行尾左括号 \(bracketLines.filter { $0.text.hasSuffix("（") }.count) 处"))

    // 拉丁词内不断
    let latin = "hello wonderful world"
    // 宽度取「hello wonderful」减去 1pt：整句放不下，但每个单词都放得下
    let latinWidth = PDFTextMetrics.width("hello wonderful", font: font, size: size) - 1
    let latinLines = PDFLineBreaker.breakLines(
        text: latin, font: font, size: size, maxWidth: latinWidth)
    results.append(check(
        suite: suite, "latin-word-boundary",
        latinLines.allSatisfy { line in
            ["hello", "wonderful", "world"].contains(line.text.trimmingCharacters(in: .whitespaces))
        },
        detail: "切成 \(latinLines.map(\.text).joined(separator: "|"))"))

    // 数字与 % 不断
    let unitLines = PDFLineBreaker.breakLines(
        text: "达到 500mg。剂量 50% 以上", font: font, size: size, maxWidth: charWidth * 6)
    results.append(check(
        suite: suite, "no-break-number-unit",
        unitLines.allSatisfy { !$0.text.hasSuffix("50") },
        detail: "行尾孤零零的数字 \(unitLines.filter { $0.text.hasSuffix("50") }.count) 处"))

    // 显式换行必须保留
    let hardLines = PDFLineBreaker.breakLines(
        text: "第一行\n第二行", font: font, size: size, maxWidth: charWidth * 40)
    results.append(check(
        suite: suite, "hard-break-preserved",
        hardLines.count == 2 && hardLines[0].text == "第一行",
        detail: "2 行，首行=\(hardLines.first?.text ?? "")"))

    // MARK: - 占位符

    results.append(check(
        suite: suite, "placeholder-normalize",
        PDFPlaceholder.normalize("见 {{ 12 }} 与｛｛3｝｝") == "见 {{12}} 与{{3}}",
        detail: PDFPlaceholder.normalize("见 {{ 12 }} 与｛｛3｝｝")))

    let missing = PDFPlaceholder.verify(source: "见图 {{1}} 和 {{2}}", translation: "见图 1")
    results.append(check(
        suite: suite, "placeholder-missing",
        missing.missing == [1, 2] && !missing.isClean,
        detail: missing.summary))

    let duplicated = PDFPlaceholder.verify(source: "见图 {{1}}", translation: "见图 {{1}}{{1}}")
    results.append(check(
        suite: suite, "placeholder-duplicated",
        duplicated.duplicated == [1] && !duplicated.isClean,
        detail: duplicated.summary))

    let reordered = PDFPlaceholder.verify(source: "{{1}} 与 {{2}}", translation: "{{2}} 与 {{1}}")
    results.append(check(
        suite: suite, "placeholder-order",
        reordered.orderChanged && reordered.missing.isEmpty,
        detail: reordered.summary))

    let clean = PDFPlaceholder.verify(source: "见图 {{1}}", translation: "见图{{1}}")
    results.append(check(
        suite: suite, "placeholder-clean",
        clean.isClean,
        detail: clean.summary))

    // MARK: - 三档投放

    let roomy = PDFRect(x0: 0, y0: 0, x1: 240, y1: 120)
    let fitPlan = PDFTypeset.plan(
        text: "这是一句短译文。", face: face, baseFontSize: 12,
        space: PDFTypeset.Space(box: roomy, rightLimit: 240, downLimit: 0), floorSize: 8)
    results.append(check(
        suite: suite, "typeset-fit",
        fitPlan.tier == .fit && fitPlan.fontSize == 12 && fitPlan.lines.count == 1,
        detail: "\(fitPlan.tier.rawValue) \(fitPlan.fontSize)pt"))

    let narrow = PDFRect(x0: 0, y0: 0, x1: 80, y1: 60)
    let longText = String(repeating: "这是一段比较长的译文内容。", count: 6)
    let shrinkPlan = PDFTypeset.plan(
        text: longText, face: face, baseFontSize: 12,
        space: PDFTypeset.Space(box: narrow, rightLimit: 80, downLimit: 0), floorSize: 6)
    results.append(check(
        suite: suite, "typeset-shrink-above-floor",
        (shrinkPlan.tier == .shrink || shrinkPlan.tier == .expand)
            && shrinkPlan.fontSize < 12 && shrinkPlan.fontSize >= 6,
        detail: "\(shrinkPlan.tier.rawValue) \(shrinkPlan.fontSize)pt"))

    // 极窄框：无论怎么缩都不低于下限
    let tiny = PDFRect(x0: 0, y0: 0, x1: 24, y1: 24)
    let floorPlan = PDFTypeset.plan(
        text: longText, face: face, baseFontSize: 12,
        space: PDFTypeset.Space(box: tiny, rightLimit: 24, downLimit: 0), floorSize: 6)
    results.append(check(
        suite: suite, "typeset-respects-floor",
        floorPlan.fontSize >= 6 - 0.001,
        detail: "下限 6pt，实际 \(floorPlan.fontSize)pt"))

    // 右侧有空白可扩：宽 40 时无论怎么缩都放不下，扩到 58 就能放下
    let growable = PDFTypeset.Space(
        box: PDFRect(x0: 0, y0: 60, x1: 40, y1: 84), rightLimit: 220, downLimit: 0)
    let expandPlan = PDFTypeset.plan(
        text: "一二三四五六七八九十", face: face,
        baseFontSize: 12, space: growable, floorSize: 9)
    results.append(check(
        suite: suite, "typeset-expand-right",
        expandPlan.tier == .expand && expandPlan.box.width > 40,
        detail: "\(expandPlan.tier.rawValue) 宽度 40 → \(round(expandPlan.box.width))"))

    // 放不下：必须给出出口，且溢出内容非空
    let hopeless = PDFRect(x0: 0, y0: 0, x1: 30, y1: 16)
    let overflowPlan = PDFTypeset.plan(
        text: String(repeating: "这一段无论如何都放不下。", count: 10), face: face,
        baseFontSize: 12,
        space: PDFTypeset.Space(box: hopeless, rightLimit: 30, downLimit: 0), floorSize: 6)
    results.append(check(
        suite: suite, "typeset-overflow-exit",
        (overflowPlan.tier == .overflowShort || overflowPlan.tier == .overflowLong)
            && !overflowPlan.overflow.isEmpty,
        detail: "\(overflowPlan.tier.rawValue) 溢出 \(overflowPlan.overflow.count) 行"))

    // MARK: - 页内重排

    func block(_ id: String, x0: Double, x1: Double, y0: Double, y1: Double) -> ILBlock {
        ILBlock(id: id, type: .paragraph,
                box: PDFRect(x0: x0, y0: y0, x1: x1, y1: y1),
                lines: [], fontSize: 10, text: "占位", confidence: 0.8, column: 0)
    }
    let left = [block("l1", x0: 40, x1: 280, y0: 600, y1: 700),
                block("l2", x0: 40, x1: 280, y0: 500, y1: 560)]
    let right = [block("r1", x0: 310, x1: 550, y0: 600, y1: 700),
                 block("r2", x0: 310, x1: 550, y0: 500, y1: 560)]
    let order = PDFPageReflow.readingOrder(left + right)
    results.append(check(
        suite: suite, "reflow-reading-order",
        order.map(\.id) == ["l1", "l2", "r1", "r2"],
        detail: order.map(\.id).joined(separator: "→")))

    // 每段都塞三倍文字，必须顺延且互不重叠
    let texts = Dictionary(uniqueKeysWithValues: (left + right).map {
        ($0.id, String(repeating: "重排测试文本内容。", count: 6))
    })
    let flowed = PDFPageReflow.flow(
        blocks: left + right, texts: texts,
        region: PDFRect(x0: 40, y0: 60, x1: 550, y1: 760),
        obstacles: [], face: { _ in face }, floorSize: 7)
    var overlaps = 0
    for i in 0..<flowed.plans.count {
        for j in (i + 1)..<flowed.plans.count {
            let a = flowed.plans[i], b = flowed.plans[j]
            let ra = PDFRect(x0: a.box.x0, y0: a.box.y1 - Double(a.lines.count) * a.lineHeight,
                             x1: a.box.x1, y1: a.box.y1)
            let rb = PDFRect(x0: b.box.x0, y0: b.box.y1 - Double(b.lines.count) * b.lineHeight,
                             x1: b.box.x1, y1: b.box.y1)
            if ra.intersects(rb) { overlaps += 1 }
        }
    }
    results.append(check(
        suite: suite, "reflow-no-overlap",
        flowed.plans.count == 4 && overlaps == 0,
        detail: "\(flowed.plans.count) 块，重叠 \(overlaps) 对"))

    // MARK: - 交错块合并（P2 结构修正）

    func line(_ text: String, x0: Double, x1: Double, baseline: Double) -> ILLine {
        ILLine(text: text, box: PDFRect(x0: x0, y0: baseline - 6, x1: x1, y1: baseline + 6),
               baseline: baseline, fontSize: 10, spans: [], angle: 0)
    }
    func blockWith(_ id: String, _ lines: [ILLine]) -> ILBlock {
        ILBlock(id: id, type: .paragraph, box: lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) },
                lines: lines, fontSize: 10, text: lines.map(\.text).joined(),
                confidence: 0.8, column: 0)
    }
    let a = blockWith("a", [line("上", x0: 84, x1: 480, baseline: 100),
                            line("下", x0: 84, x1: 480, baseline: 60)])
    let b = blockWith("b", [line("中", x0: 63, x1: 290, baseline: 80)])
    let merged = PDFParagraphBuilder.mergeInterleaved([a, b])
    results.append(check(
        suite: suite, "merge-interleaved-blocks",
        merged.count == 1 && merged[0].lines.map(\.text) == ["上", "中", "下"],
        detail: "合并为 \(merged.count) 块，行序 \(merged.first?.lines.map(\.text) ?? [])"))

    // 左右并排的两个块不能被误合并
    let leftCol = blockWith("l", [line("左一", x0: 40, x1: 280, baseline: 100),
                                  line("左二", x0: 40, x1: 280, baseline: 80)])
    let rightCol = blockWith("r", [line("右一", x0: 310, x1: 550, baseline: 100),
                                   line("右二", x0: 310, x1: 550, baseline: 80)])
    results.append(check(
        suite: suite, "merge-keeps-columns",
        PDFParagraphBuilder.mergeInterleaved([leftCol, rightCol]).count == 2,
        detail: "两栏保持 2 块"))

    // MARK: - 端到端写回

    if let document = try? PDFDocument(data: SyntheticPDF.make()) {
        let before = document.pages()[0]
        let beforeText = (PDFStructureBuilder.buildPage(
            document: document, index: 0, entry: (PDFRef(3, 0), before))).blocks.map(\.text).joined()
        results.append(check(
            suite: suite, "engine-source-text",
            beforeText.contains("Hello"),
            detail: "原文=\(beforeText.prefix(20))"))

        var request = PDFTypesetEngine.Request()
        request.translations = PDFPlaceholder.TranslationMap(entries: ["p1-p0-b0": "你好世界"])
        if let result = try? PDFTypesetEngine.run(
            document: document, faces: .init(regular: font), request: request) {
            let after = (try? PDFDocument(data: result.output))
            let page = after?.pages().first
            var afterText = ""
            if let after, let page {
                afterText = PDFStructureBuilder.buildPage(
                    document: after, index: 0, entry: (PDFRef(3, 0), page)).blocks.map(\.text).joined()
            }
            results.append(check(
                suite: suite, "engine-translated",
                result.report.pages.first?.translated == 1 && afterText.contains("你好"),
                detail: "translated=\(result.report.pages.first?.translated ?? -1) 文本=\(afterText.prefix(20))"))

            results.append(check(
                suite: suite, "engine-original-gone",
                !afterText.contains("Hello"),
                detail: "旧文本已删除=\(!afterText.contains("Hello"))"))

            results.append(check(
                suite: suite, "engine-vector-kept",
                page != nil && String(decoding: result.output, as: UTF8.self).contains("re f"),
                detail: "矩形绘制算子仍在"))

            results.append(check(
                suite: suite, "engine-page-count",
                after?.pages().count == 1,
                detail: "1 页 → \(after?.pages().count ?? -1) 页"))
        } else {
            results.append(check(suite: suite, "engine-translated", false, detail: "引擎抛错"))
        }

        // 没有译文时保留原文，不能把页面清空
        if let result = try? PDFTypesetEngine.run(
            document: document, faces: .init(regular: font), request: PDFTypesetEngine.Request()) {
            let after = (try? PDFDocument(data: result.output))
            var text = ""
            if let after, let page = after.pages().first {
                text = PDFStructureBuilder.buildPage(
                    document: after, index: 0, entry: (PDFRef(3, 0), page)).blocks.map(\.text).joined()
            }
            results.append(check(
                suite: suite, "engine-keeps-original",
                text.contains("Hello")
                    && (result.report.pages.first?.keptOriginal ?? 0) >= 1,
                detail: "保留原文 \(result.report.pages.first?.keptOriginal ?? 0) 块"))
        }
    }

    return results
}

/// P3/P6 共用：从仓库根定位内置字体
func p3FontURL(_ name: String) -> URL? {
    let thisFile = URL(fileURLWithPath: #filePath)
    let root = thisFile.deletingLastPathComponent()   // Sources/hymntest
        .deletingLastPathComponent()                   // Sources
        .deletingLastPathComponent()                   // 仓库根
    let url = root.appendingPathComponent("Resources/Fonts/\(name)")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}
