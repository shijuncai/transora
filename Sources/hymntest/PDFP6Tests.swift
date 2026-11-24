import Foundation
import HymnCore

/// P6「真实文档上暴露出来的结构缺陷」回归。
///
/// 这一套全部来自 `Sample/Development of a novel mycelium bio-composite.pdf`
/// 的实测：前五套在合成样本上全绿，真实期刊版面上却整页塌掉。
public func pdfP6Suite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-p6"

    // MARK: - 一页多条内容流：数组在 A、算子 TJ 在 B

    // Elsevier 的生成器会把语句切在操作数之间。逐流各跑一遍解释器，
    // 流 A 末尾累积的数组就丢了 —— 整行作者单位读不出来（渲染却正常）。
    do {
        let split = PDFFixtureP5.multiStream(contents: [
            "BT /F1 12 Tf 100 500 Td [(Centre) -300 (for) -300 (Renewable)]",
            " TJ ET",
        ], resources: "<< /Font << /F1 6 0 R >> >>",
           extraRefs: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"])
        let document = try PDFDocument(data: split)
        let entry = document.pageEntries()[0]
        let content = PDFTextExtractor.extract(
            document: document, pageIndex: 0, page: entry.dict)
        let text = content.runs.map(\.text).joined()
        results.append(check(
            suite: suite, "multistream-tj-continuation",
            text.contains("Centre") && text.contains("Renewable") && content.runs.count == 3,
            detail: "跨流数组 + TJ：runs=\(content.runs.count) text=\(text)"))
    } catch {
        results.append(check(suite: suite, "multistream-tj-continuation", false,
                             detail: "构造失败 \(error)"))
    }

    // 反证：把同一条流拆成两半、但**语句完整**时，两边行为必须一致，
    // 说明修复不是靠「猜」，而是真的按一条逻辑流跑了。
    do {
        let whole = PDFFixtureP5.build(contents: [
            "BT /F1 12 Tf 100 500 Td [(Alpha)] TJ (Beta) Tj ET",
        ], extraObjects: [],
           resources: "<< /Font << /F1 5 0 R >> >>",
           extraRefs: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"])
        let document = try PDFDocument(data: whole)
        let entry = document.pageEntries()[0]
        let content = PDFTextExtractor.extract(
            document: document, pageIndex: 0, page: entry.dict)
        let text = content.runs.map(\.text).joined()
        results.append(check(
            suite: suite, "multistream-single-stream-baseline",
            text.contains("Alpha") && text.contains("Beta"),
            detail: "单流基线 runs=\(content.runs.count) text=\(text)"))
    } catch {
        results.append(check(suite: suite, "multistream-single-stream-baseline", false,
                             detail: "构造失败 \(error)"))
    }

    // MARK: - 分栏：XY 切分

    func line(_ text: String, x0: Double, x1: Double, y: Double,
              size: Double = 8) -> ILLine {
        let box = PDFRect(x0: x0, y0: y - size * 0.8, x1: x1, y1: y + size * 0.2)
        return ILLine(
            text: text, box: box, baseline: y, fontSize: size,
            spans: [ILSpan(text: text, fontName: "F", fontSize: size,
                           isBold: false, isItalic: false, box: box)],
            angle: 0)
    }

    // 双栏正文 + 居中页码。页码横跨栏缝，旧算法（区间并集找空档）直接判单栏。
    var paper: [ILLine] = []
    for i in 0..<12 {
        let y = 700.0 - Double(i) * 10
        paper.append(line("left \(i)", x0: 38, x1: 289, y: y))
        paper.append(line("right \(i)", x0: 307, x1: 558, y: y))
    }
    paper.append(line("5039", x0: 290, x1: 305, y: 40, size: 7))
    let groups = PDFParagraphBuilder.detectColumns(lines: paper, pageWidth: 595, gutter: 14)
    let leftCount = groups.reduce(0) { $0 + $1.filter { $0.text.hasPrefix("left") }.count }
    let rightCount = groups.reduce(0) { $0 + $1.filter { $0.text.hasPrefix("right") }.count }
    let firstIsLeft = groups.first?.first?.text.hasPrefix("left") ?? false
    let lastIsNumber = groups.last?.first?.text == "5039"
    results.append(check(
        suite: suite, "columns-two-columns-with-straddling-page-number",
        groups.count == 3 && leftCount == 12 && rightCount == 12
            && firstIsLeft && lastIsNumber,
        detail: "groups=\(groups.count) left=\(leftCount) right=\(rightCount) "
            + "first=\(groups.first?.first?.text ?? "-") last=\(groups.last?.first?.text ?? "-")"))

    // 单栏：不能因为短行（标题、关键词）就切出第二栏
    var single: [ILLine] = []
    for i in 0..<10 {
        single.append(line("body \(i), which is a full measure line of text.",
                           x0: 38, x1: 558, y: 700 - Double(i) * 10))
    }
    single.append(line("Title", x0: 200, x1: 260, y: 720, size: 14))
    let singleGroups = PDFParagraphBuilder.detectColumns(lines: single, pageWidth: 595, gutter: 14)
    results.append(check(
        suite: suite, "columns-single-column-not-split",
        singleGroups.count == 1,
        detail: "groups=\(singleGroups.count)（标题不单独成栏，正文不拆）"))

    // MARK: - 行内碎片：上标与「取不到 unicode 的空 run」

    // 作者的 a/b 上标基线高 5pt、字号更小，必须并回本行；
    // 否则中文重排后上标留在原位，和名字脱开。
    // 上标落在正文**前面/后面**（kg/m³、名字^a）时必须并回本行：
    // 否则中文重排后上标留在原位，和名字脱开。
    let superscriptLines = PDFLineBuilder.buildLines(from: [
        PDFFixtureP5.run("S. Sivaprasad", x0: 38, x1: 100, y: 565, size: 10),
        PDFFixtureP5.run("a", x0: 103, x1: 108, y: 568, size: 7.5),
        PDFFixtureP5.run(", Sidharth K. Byju", x0: 120, x1: 200, y: 565, size: 10),
    ])
    results.append(check(
        suite: suite, "line-merge-superscript",
        superscriptLines.contains { $0.text == "S. Sivaprasada" },
        detail: "lines=\(superscriptLines.map(\.text))"))

    // 落在长行**内部**的上标不合并（判据要求两段水平前后相邻）。
    // 它们会作为单字符块钉在原位、原字形重画——位置不丢，只是不参与重排。
    let inlineSuper = PDFLineBuilder.buildLines(from: [
        PDFFixtureP5.run("S. Sivaprasad", x0: 38, x1: 100, y: 565, size: 10),
        PDFFixtureP5.run("a", x0: 103, x1: 108, y: 568, size: 7.5),
        PDFFixtureP5.run(", Sidharth K. Byju", x0: 112, x1: 200, y: 565, size: 10),
    ])
    results.append(check(
        suite: suite, "line-inline-superscript-left-alone",
        inlineSuper.count == 2 && inlineSuper.contains { $0.text.contains("Byju") },
        detail: "lines=\(inlineSuper.map(\.text))（行内上标保持独立，钉在原位）"))

    // 取不到 unicode 的 run（Symbol 字体的 ×）没有文字但占宽度，
    // 不能丢：丢了以后「30 cm × 30 cm × 1 cm」被撕成三块分别送翻译，语序直接乱。
    let withHole = PDFLineBuilder.buildLines(from: [
        PDFFixtureP5.run("The samples of dimension 30 cm", x0: 60, x1: 170, y: 600, size: 8),
        PDFFixtureP5.run("", x0: 176, x1: 184, y: 600, size: 8, advance: 8),
        PDFFixtureP5.run("30 cm", x0: 188, x1: 212, y: 600, size: 8),
        PDFFixtureP5.run("", x0: 218, x1: 226, y: 600, size: 8, advance: 8),
        PDFFixtureP5.run("1 cm is placed", x0: 230, x1: 288, y: 600, size: 8),
    ])
    results.append(check(
        suite: suite, "line-unmapped-run-keeps-line-together",
        withHole.count == 1,
        detail: "lines=\(withHole.count) text=\(withHole.first?.text ?? "-")"))

    // 表格里并排的单元格不能因为「同一基线」被并成一条假行
    let cells = PDFLineBuilder.buildLines(from: [
        PDFFixtureP5.run("Sample", x0: 60, x1: 90, y: 600, size: 8),
        PDFFixtureP5.run("Modulus", x0: 300, x1: 340, y: 600, size: 8),
        PDFFixtureP5.run("Strength", x0: 420, x1: 470, y: 600, size: 8),
    ])
    results.append(check(
        suite: suite, "line-table-cells-stay-separate",
        cells.count == 3,
        detail: "lines=\(cells.count)"))

    // MARK: - 长段落切分

    let longSentence = String(repeating: "This is a sentence about mycelium. ", count: 40)
    let chunks = PDFSentenceSplitter.chunks(longSentence, limit: 200)
    results.append(check(
        suite: suite, "splitter-respects-sentence-boundary",
        chunks.count > 1 && chunks.allSatisfy { $0.count <= 200 + 40 }
            && chunks.allSatisfy { $0.hasSuffix(" ") || $0.hasSuffix(".") },
        detail: "chunks=\(chunks.count) sizes=\(chunks.map(\.count))"))

    let abbreviated = "As shown in Fig. 3 and Eq. 4, the values differ. "
        + String(repeating: "x", count: 60) + ". Tail."
    let abbreviatedChunks = PDFSentenceSplitter.chunks(abbreviated, limit: 40)
    results.append(check(
        suite: suite, "splitter-keeps-abbreviation",
        abbreviatedChunks.first?.contains("Fig. 3 and Eq. 4") ?? false,
        detail: "first=\(abbreviatedChunks.first ?? "-")"))

    let noPunctuation = String(repeating: "A1B2C3D4", count: 60)
    let hacked = PDFSentenceSplitter.chunks(noPunctuation, limit: 100)
    results.append(check(
        suite: suite, "splitter-hard-cut-without-punctuation",
        hacked.count > 1 && hacked.allSatisfy { $0.count <= 100 },
        detail: "pieces=\(hacked.count) max=\(hacked.map(\.count).max() ?? 0)"))

    results.append(check(
        suite: suite, "splitter-short-text-untouched",
        PDFSentenceSplitter.chunks("Hello world.", limit: 900) == ["Hello world."],
        detail: "短文本不应被切"))

    // MARK: - 控制字符不能当字形

    // 译文里偶尔会带换行（模型输出、跨句拼接）。原样交给字体会画不出来，
    // 报告里就会出现一条「字体画不出 U+000A」的假缺陷。
    if let fontURL = p3FontURL("LinguaNovaSong-Regular.ttf"),
       let font = try? TrueTypeFont(url: fontURL) {
        let face = PDFFace(font: font, resourceName: "LNR1", isBold: false)
        let box = PDFRect(x0: 0, y0: 0, x1: 400, y1: 60)
        let plan = PDFTypeset.plan(
            text: "第一行\n第二行\t带制表", face: face, baseFontSize: 10,
            space: PDFTypeset.Space(box: box, rightLimit: 400, downLimit: 0), floorSize: 6)
        let hasControl = plan.lines.contains { line in
            line.text.unicodeScalars.contains { $0.value < 0x20 }
        }
        results.append(check(
            suite: suite, "typesetter-strips-control-characters",
            !hasControl && !plan.missingScalars.contains { $0 < 0x20 },
            detail: "lines=\(plan.lines.map(\.text)) missing=\(plan.missingScalars.map { String(Unicode.Scalar($0) ?? "?") })"))
    } else {
        results.append(check(suite: suite, "typesetter-strips-control-characters", false,
                             detail: "找不到内置字体"))
    }

    return results
}
