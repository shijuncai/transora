import Foundation
import HymnCore

/// P2 测试集：CMap、编码、几何、行/段归并、分栏、表格网格、端到端往返。
///
/// 这一组里最值钱的不是「功能对不对」，而是**把 P2 踩过的坑钉死**：
/// 1 字节码的 CMap 却写着 2 字节 codespace；
/// 同一基线上的两个表格单元格被并成一行；
/// 一条横跨两栏的坏行把整页判成单栏。
public func pdfP2Suite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-p2"

    // MARK: - 几何：矩阵乘法顺序

    let translate = PDFMatrix.translation(10, 0)
    let scale = PDFMatrix(2, 0, 0, 2, 0, 0)
    let combined = translate * scale        // 先平移再缩放
    let viaSteps = scale.applied(to: translate.applied(to: PDFPoint(1, 1)))
    results.append(check(
        suite: suite, "matrix-order",
        combined.applied(to: PDFPoint(1, 1)) == viaSteps && viaSteps == PDFPoint(22, 2),
        detail: "(1,1) → 先平移(10,0) 再缩放×2 = (22,2)"))

    results.append(check(
        suite: suite, "rect-iou",
        abs(PDFRect(x0: 0, y0: 0, x1: 10, y1: 10)
            .iou(PDFRect(x0: 0, y0: 0, x1: 10, y1: 10)) - 1.0) < 1e-9,
        detail: "同一矩形 IoU = 1"))

    // MARK: - CMap

    func parseCMap(_ text: String) -> PDFCMap? {
        try? PDFCMap.parse(Data(text.utf8))
    }

    let bfcharCMap = parseCMap("""
    /CIDInit /ProcSet findresource begin
    12 dict begin
    begincmap
    /CMapName /Adobe-Identity-UCS def
    1 begincodespacerange
    <0000> <FFFF>
    endcodespacerange
    2 beginbfchar
    <0003> <0020>
    <0024> <4E2D>
    endbfchar
    endcmap
    end
    end
    """)
    results.append(check(
        suite: suite, "cmap-bfchar",
        bfcharCMap?.mapping[3] == " " && bfcharCMap?.mapping[0x24] == "中",
        detail: "两条 bfchar"))

    let rangeCMap = parseCMap("""
    begincmap
    1 begincodespacerange
    <0000> <FFFF>
    endcodespacerange
    2 beginbfrange
    <0024> <0026> <0041>
    <0030> <0031> [<4E00> <4E8C>]
    endbfrange
    endcmap
    """)
    results.append(check(
        suite: suite, "cmap-bfrange",
        rangeCMap?.mapping[0x24] == "A" && rangeCMap?.mapping[0x26] == "C"
            && rangeCMap?.mapping[0x30] == "一" && rangeCMap?.mapping[0x31] == "二",
        detail: "递增区间 + 数组目标"))

    // 回归：简单字体的 ToUnicode 里写 1 字节码，codespace 却写 <0000> <FFFF>
    let oneByteCMap = parseCMap("""
    begincmap
    1 begincodespacerange
    <0000> <FFFF>
    endcodespacerange
    2 beginbfchar
    <20> <0020>
    <41> <0041>
    endbfchar
    endcmap
    """)
    results.append(check(
        suite: suite, "cmap-one-byte-codes",
        oneByteCMap?.mapping[0x20] == " " && oneByteCMap?.mapping[0x41] == "A",
        detail: "1 字节码解析正确（不按 codespace 的 2 字节解释）"))

    results.append(check(
        suite: suite, "cmap-decode-two-byte",
        bfcharCMap?.decode([0x00, 0x03, 0x00, 0x24]) == [3, 0x24],
        detail: "Type0 双字节切分"))

    // MARK: - 编码表

    results.append(check(
        suite: suite, "encoding-winansi-specials",
        PDFEncoding.unicode(for: .winAnsi, code: 0x92) == "\u{2019}"
            && PDFEncoding.unicode(for: .winAnsi, code: 0x80) == "\u{20AC}"
            && PDFEncoding.unicode(for: .winAnsi, code: 0x41) == "A",
        detail: "0x92 → ’，0x80 → €"))

    results.append(check(
        suite: suite, "encoding-macroman",
        PDFEncoding.unicode(for: .macRoman, code: 0xA5) == "\u{2022}"
            && PDFEncoding.unicode(for: .macRoman, code: 0x80) == "\u{00C4}",
        detail: "0xA5 → •，0x80 → Ä"))

    results.append(check(
        suite: suite, "glyph-name-uni",
        GlyphNames.unicode(for: "uni4E2D") == "中"
            && GlyphNames.unicode(for: "quotesingle") == "'"
            && GlyphNames.unicode(for: "unresolvable-name") == nil,
        detail: "uniXXXX 与标准名；未知名返回 nil"))

    // MARK: - 行归并

    func run(_ text: String, x: Double, y: Double, size: Double = 10,
             font: String = "Helvetica") -> PDFTextRun {
        let width = Double(text.count) * size * 0.5
        return PDFTextRun(
            pageIndex: 0, text: text, fontName: font, fontSize: size,
            unscaledFontSize: size,
            origin: PDFPoint(x, y), endPoint: PDFPoint(x + width, y),
            bbox: PDFRect(x0: x, y0: y - size * 0.2, x1: x + width, y1: y + size * 0.8),
            angle: 0, renderMode: 0, advance: width,
            glyphCount: text.count, unmappedGlyphs: 0)
    }

    // 同一基线上的两个表格单元格不应该被并成一行
    let sameBaseline = PDFLineBuilder.buildLines(from: [
        run("药品类", x: 55, y: 700),
        run("类内药物", x: 240, y: 700),
    ])
    results.append(check(
        suite: suite, "line-split-by-gap",
        sameBaseline.count == 2,
        detail: "间隙 185pt 的两段文字 → \(sameBaseline.count) 行"))

    // 正常词间距不该被切开
    let tightWords = PDFLineBuilder.buildLines(from: [
        run("Hello", x: 100, y: 700),
        run("world", x: 130, y: 700),
    ])
    results.append(check(
        suite: suite, "line-keeps-close-runs",
        tightWords.count == 1 && tightWords[0].text == "Hello world",
        detail: "间隙 5pt → 一行：\(tightWords.first?.text ?? "nil")"))

    results.append(check(
        suite: suite, "line-cjk-no-space",
        PDFLineBuilder.needsSpace(between: "中文", and: "继续") == false
            && PDFLineBuilder.needsSpace(between: "Hello", and: "world") == true,
        detail: "中文不补空格，西文补"))

    // MARK: - 分栏

    func columnPage(spans: [(String, Double, Double)]) -> [ILLine] {
        spans.enumerated().map { index, item in
            ILLine(text: item.0,
                   box: PDFRect(x0: item.1, y0: item.2 - 10, x1: item.1 + 200, y1: item.2),
                   baseline: item.2, fontSize: 10,
                   spans: [], angle: 0)
        }
    }

    var twoColumn: [ILLine] = []
    for i in 0..<10 {
        twoColumn.append(contentsOf: columnPage(spans: [("L\(i)", 61, 700 - Double(i) * 14)]))
        twoColumn.append(contentsOf: columnPage(spans: [("R\(i)", 320, 700 - Double(i) * 14)]))
    }
    let columns = PDFParagraphBuilder.detectColumns(lines: twoColumn, pageWidth: 595, gutter: 14)
    results.append(check(
        suite: suite, "columns-two",
        columns.count == 2 && columns[0].count == 10 && columns[1].count == 10,
        detail: "\(columns.count) 栏，各 \(columns.map(\.count)) 行"))

    // 单栏文档即使行长差别很大也不能被误判成两栏
    var singleColumn: [ILLine] = []
    for i in 0..<12 {
        let width = i % 3 == 0 ? 120.0 : 460.0
        singleColumn.append(ILLine(
            text: "S\(i)",
            box: PDFRect(x0: 61, y0: 700 - Double(i) * 14 - 10,
                         x1: 61 + width, y1: 700 - Double(i) * 14),
            baseline: 700 - Double(i) * 14, fontSize: 10, spans: [], angle: 0))
    }
    let single = PDFParagraphBuilder.detectColumns(lines: singleColumn, pageWidth: 595, gutter: 14)
    results.append(check(
        suite: suite, "columns-single-not-split",
        single.count == 1,
        detail: "单栏 → \(single.count) 栏"))

    // MARK: - 表格

    let tableSegments = p2GridSegments(rows: 3, columns: 2,
                                          origin: PDFPoint(50, 400), cell: (200, 40))
    let tableLines = [
        ILLine(text: "药品类", box: PDFRect(x0: 60, y0: 415, x1: 120, y1: 432),
               baseline: 418, fontSize: 10, spans: [], angle: 0),
        ILLine(text: "类内药物", box: PDFRect(x0: 260, y0: 415, x1: 320, y1: 432),
               baseline: 418, fontSize: 10, spans: [], angle: 0),
    ]
    let tables = PDFTableDetector.detect(
        segments: tableSegments, runs: [], lines: tableLines,
        pageBox: PDFRect(x0: 0, y0: 0, x1: 595, y1: 842))
    results.append(check(
        suite: suite, "table-detected",
        tables.count == 1 && tables[0].rowCount == 3 && tables[0].columnCount == 2,
        detail: tables.isEmpty ? "未检出"
            : "\(tables[0].rowCount)×\(tables[0].columnCount)"))

    // 单个方框不是表格：这是这类算法最典型的误报
    let boxSegments = p2GridSegments(rows: 1, columns: 1,
                                        origin: PDFPoint(50, 400), cell: (300, 100))
    let boxOnly = PDFTableDetector.detect(
        segments: boxSegments, runs: [], lines: [],
        pageBox: PDFRect(x0: 0, y0: 0, x1: 595, y1: 842))
    results.append(check(
        suite: suite, "table-rejects-single-box",
        boxOnly.isEmpty,
        detail: "1×1 方框 → \(boxOnly.count) 张表"))

    // 只有外框没有内线、行靠文字分隔（大量真实表格就是这样）
    let sparse = p2GridSegments(rows: 1, columns: 2,
                                   origin: PDFPoint(50, 400), cell: (200, 200))
    var sparseLines: [ILLine] = []
    for i in 0..<3 {
        let y = 570.0 - Double(i) * 40
        sparseLines.append(ILLine(text: "行\(i)甲", box: PDFRect(x0: 60, y0: y - 8, x1: 120, y1: y + 8),
                                  baseline: y, fontSize: 10, spans: [], angle: 0))
        sparseLines.append(ILLine(text: "行\(i)乙", box: PDFRect(x0: 260, y0: y - 8, x1: 320, y1: y + 8),
                                  baseline: y, fontSize: 10, spans: [], angle: 0))
    }
    let sparseTables = PDFTableDetector.detect(
        segments: sparse, runs: [], lines: sparseLines,
        pageBox: PDFRect(x0: 0, y0: 0, x1: 595, y1: 842))
    results.append(check(
        suite: suite, "table-rows-from-first-column",
        sparseTables.count == 1 && sparseTables[0].rowCount == 3,
        detail: sparseTables.first.map { "\($0.rowCount)×\($0.columnCount)" } ?? "未检出"))

    // MARK: - 端到端往返：写进去的中文，读回来必须一字不差

    guard let fontURL = p2FontURL(), let font = try? TrueTypeFont(url: fontURL) else {
        results.append(check(suite: suite, "roundtrip-font", false,
                             detail: "缺少 Resources/Fonts/LinguaNovaSong-Regular.ttf"))
        return results
    }

    let sample = "高保真 PDF 翻译：图片与表格保持原样。"
    if let document = try? PDFDocument(data: PDFFixtureP2.blankPage()) {
        let outcome = try? PDFStamper.stamp(
            document: document, pageIndex: 0, text: sample, font: font, fontSize: 12)
        results.append(check(suite: suite, "roundtrip-stamp", outcome != nil,
                             detail: outcome.map { "\($0.subsetGlyphs) 字形" } ?? "失败"))

        if let outcome, let after = try? PDFDocument(data: outcome.output) {
            let page = PDFStructureBuilder.buildPage(
                document: after, index: 0, entry: after.pageEntries()[0])
            let text = page.blocks.map(\.text).joined()
            results.append(check(
                suite: suite, "roundtrip-read-back",
                text.contains(sample),
                detail: "读回：\(String(text.prefix(40)))"))
            results.append(check(
                suite: suite, "roundtrip-translatable",
                page.translatable && page.unmappedGlyphs == 0,
                detail: "translatable=\(page.translatable) unmapped=\(page.unmappedGlyphs)"))
            let json = String(decoding: ILJSON.encode(
                PDFStructureBuilder.build(document: after)), as: UTF8.self)
            results.append(check(
                suite: suite, "roundtrip-json-box",
                json.contains("\"box_top_down\"") && json.contains("\"baseline\""),
                detail: "块/行坐标与 top-down 盒子都在"))
        }
    } else {
        results.append(check(suite: suite, "roundtrip-stamp", false, detail: "样本构造失败"))
    }

    // MARK: - IL JSON 契约

    if let document = try? PDFDocument(data: PDFFixtureP2.blankPage()) {
        let il = PDFStructureBuilder.build(document: document)
        let json = ILJSON.encode(il)
        let text = String(decoding: json, as: UTF8.self)
        results.append(check(
            suite: suite, "il-json-schema",
            text.contains("linguanova.il/1") && text.contains("\"pages\"")
                && text.contains("\"translatable\""),
            detail: "含 schema / pages / translatable"))
        results.append(check(
            suite: suite, "il-json-parses",
            (try? JSONSerialization.jsonObject(with: json)) != nil,
            detail: "是合法 JSON"))
    }

    return results
}

// MARK: - 辅助

private func p2FontURL() -> URL? {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = root.appendingPathComponent("Resources/Fonts/LinguaNovaSong-Regular.ttf")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// 造一个 rows×columns 的网格线段集合（含外框）。
func p2GridSegments(rows: Int, columns: Int,
                    origin: PDFPoint, cell: (Double, Double)) -> [PDFPathSegment] {
    var segments: [PDFPathSegment] = []
    let width = cell.0 * Double(columns)
    let height = cell.1 * Double(rows)
    for row in 0...rows {
        let y = origin.y + Double(row) * cell.1
        segments.append(PDFPathSegment(start: PDFPoint(origin.x, y),
                                       end: PDFPoint(origin.x + width, y), thickness: 0.6))
    }
    for column in 0...columns {
        let x = origin.x + Double(column) * cell.0
        segments.append(PDFPathSegment(start: PDFPoint(x, origin.y),
                                       end: PDFPoint(x, origin.y + height), thickness: 0.6))
    }
    return segments
}

enum PDFFixtureP2 {
    /// 一页空白 A4，作为往返回合的起点。
    static func blankPage() -> Data {
        var out = Data()
        out.append(Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8))
        var offsets: [Int] = []
        func append(_ number: Int, _ body: String) {
            offsets.append(out.count)
            out.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        append(3, """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] \
        /Resources << /Font << >> >> /Contents 4 0 R >>
        """)
        let content = "q Q\n"
        offsets.append(out.count)
        out.append(Data("4 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n".utf8))
        out.append(Data(content.utf8))
        out.append(Data("\nendstream\nendobj\n".utf8))

        let xrefOffset = out.count
        out.append(Data("xref\n0 5\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }
}
