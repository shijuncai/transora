import Foundation
import HymnCore

/// 「只有横线的表格」识别。
///
/// 全部来自 `Sample/mycelia strains and sustainable growth.pdf` 第 5 页的真实事故：
/// Table 2 只画了两条通栏横线、一根竖线都没有，于是 74 个单元格被当成 74 个段落，
/// 中式译文在 6.4 pt 的格子里全部溢出 → 触发整页重排 → 重排挤不下的
/// 831 字段落被直接丢掉。表格认出来，这一串连锁反应就都不会发生。
func pdfRuledTableSuite() -> [TestResult] {
    let suite = "pdf-ruled-table"
    var out: [TestResult] = []

    func rule(_ y: Double, _ x0: Double, _ x1: Double) -> PDFPathSegment {
        PDFPathSegment(start: PDFPoint(x0, y), end: PDFPoint(x1, y), thickness: 0.5)
    }

    func run(_ text: String, x: Double, y: Double, size: Double = 6.4,
             width: Double? = nil) -> PDFTextRun {
        let w = width ?? Double(text.count) * size * 0.5
        return PDFTextRun(
            pageIndex: 0, text: text, fontName: "AdvTT", fontSize: size,
            unscaledFontSize: size,
            origin: PDFPoint(x, y), endPoint: PDFPoint(x + w, y),
            bbox: PDFRect(x0: x, y0: y - size * 0.36, x1: x + w, y1: y + size * 0.64),
            angle: 0, renderMode: 0, advance: w,
            glyphCount: text.count, unmappedGlyphs: 0)
    }

    let columns: [Double] = [42.5, 153.4, 301.7, 340.7, 379.7, 418.7, 457.7, 517.8]
    let pageBox = PDFRect(x0: 0, y0: 0, x1: 595, y1: 793)

    /// 12 行 × 8 列，字号 6.4、行距 8.6 —— 与真实样本一致
    func tableRuns() -> [PDFTextRun] {
        var runs: [PDFTextRun] = []
        let headers = ["Assignment", "component", "TA", "AB", "PO", "GL", "RS", "OH"]
        for (column, header) in headers.enumerated() {
            runs.append(run(header, x: columns[column], y: 707.8))
        }
        for row in 0..<11 {
            let y = 694.8 - Double(row) * 8.6
            runs.append(run("band \(row)", x: columns[0], y: y))
            runs.append(run("Lipids", x: columns[1], y: y))
            for column in 2..<8 {
                runs.append(run("\(1000 + row * 7 + column)", x: columns[column], y: y))
            }
        }
        return runs
    }

    let segments = [rule(716.6, 42.5, 561.6), rule(604.9, 42.5, 561.6)]
    let detected = PDFRuledTable.detect(
        segments: segments, runs: tableRuns(), pageBox: pageBox)

    out.append(check(suite: suite, "两条横线 + 对齐小字 → 认出表格",
                     detected.count == 1, detail: "\(detected.count)"))
    out.append(check(suite: suite, "行数按基线数（含表头 12 行）",
                     detected.first?.rowCount == 12,
                     detail: "\(detected.first?.rowCount ?? -1)"))
    out.append(check(suite: suite, "列数按列首对齐（含表头 8 列）",
                     detected.first?.columnCount == 8,
                     detail: "\(detected.first?.columnCount ?? -1)"))
    let grid = (detected.first?.cells ?? []).reduce(into: [String]()) { result, cell in
        if cell.row == 1 { result.append(cell.text) }
    }
    out.append(check(suite: suite, "一格的文字不会被邻列吸走",
                     grid.count == 8 && grid[0] == "band 0" && grid[1] == "Lipids"
                        && grid[7] == "1007",
                     detail: grid.joined(separator: " | ")))
    out.append(check(suite: suite, "表头行属于表格（带子取最高的那一对横线）",
                     (detected.first?.cells.first { $0.row == 0 && $0.column == 2 }?.text) == "TA",
                     detail: detected.first?.cells.first { $0.row == 0 && $0.column == 2 }?.text ?? "nil"))

    // 上标：`CH2` 的 2 比基线高 2.4 pt，不能单独成行
    var withSuperscript = tableRuns()
    withSuperscript.append(run("2", x: 78.0, y: 697.2, size: 4.5))
    let superscript = PDFRuledTable.detect(
        segments: segments, runs: withSuperscript, pageBox: pageBox)
    out.append(check(suite: suite, "上标碎片并进所在行，不多出一行",
                     superscript.first?.rowCount == 12,
                     detail: "\(superscript.first?.rowCount ?? -1)"))

    // 正文夹在两条横线之间：每行横贯整幅，必须拒绝
    var prose: [PDFTextRun] = []
    for row in 0..<14 {
        prose.append(run("this is a full width line of body text that runs across the page",
                         x: 42.5, y: 700 - Double(row) * 9.5, width: 519))
    }
    out.append(check(suite: suite, "两条横线之间的正文段落不被当表格",
                     PDFRuledTable.detect(segments: segments, runs: prose, pageBox: pageBox).isEmpty))

    // 只有一条横线：没有上下边界
    out.append(check(suite: suite, "只有一条横线时不猜表格",
                     PDFRuledTable.detect(segments: [rule(716.6, 42.5, 561.6)],
                                          runs: tableRuns(), pageBox: pageBox).isEmpty))

    // 每行都有一根跨列的长 run：列边界不成立
    var crossing: [PDFTextRun] = []
    for row in 0..<12 {
        let y = 707.8 - Double(row) * 8.6
        crossing.append(run("band", x: columns[0], y: y))
        crossing.append(run("a wide cell that spans three columns", x: 301.7, y: y,
                            width: 160))
        crossing.append(run("1000", x: columns[6], y: y))
    }
    out.append(check(suite: suite, "跨列长行让列边界不成立 → 不认",
                     PDFRuledTable.detect(segments: segments, runs: crossing,
                                          pageBox: pageBox).isEmpty))

    // 竖排的图边水印不能进表
    var rotated = tableRuns()
    var label = run("Int. Microbiol.", x: 540, y: 660, size: 6)
    label.angle = 1.5708
    rotated.append(label)
    let rotatedTable = PDFRuledTable.detect(
        segments: segments, runs: rotated, pageBox: pageBox)
    let polluted = rotatedTable.first?.cells.contains { $0.text.contains("Microbiol") } ?? false
    out.append(check(suite: suite, "旋转的竖排标签不进表格", !polluted))

    return out
}
