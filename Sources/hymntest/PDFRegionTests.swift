import Foundation
import HymnCore

/// 栏缝（间隔区）切分：两种真实事故的回归。
///
/// ① `Sample/Biodegradation.pdf` 第 1 页：作者行末尾的上标 `1` 正好落在栏缝里，
///    把「作者 + 标题」的间距压到 12 pt；地址那行的角标 `3` 同理，把「地址 + 正文」
///    黏成一段——译文于是变成「Francisco J. Ruiz-Dueñas1 木质纤维素的生物降解」。
/// ② 同文件正文：双栏栏间只有 14 pt（10 pt 正文的 1.4 em），而字距判定阈值是 1.6 em，
///    于是左右两栏被并成一条假行，整页分栏识别失效，段落被左右交错拼在一起。
func pdfRegionSuite() -> [TestResult] {
    let suite = "pdf-region"
    var out: [TestResult] = []

    func run(_ text: String, x: Double, x1: Double, y: Double, size: Double = 10,
             font: String = "Helvetica") -> PDFTextRun {
        PDFTextRun(
            pageIndex: 0, text: text, fontName: font, fontSize: size,
            unscaledFontSize: size,
            origin: PDFPoint(x, y), endPoint: PDFPoint(x1, y),
            bbox: PDFRect(x0: x, y0: y - size * 0.2, x1: x1, y1: y + size * 0.8),
            angle: 0, renderMode: 0, advance: x1 - x,
            glyphCount: text.count, unmappedGlyphs: 0)
    }

    // MARK: - ① 双栏：栏缝只有 14 pt（1.4 em）

    var twoColumn: [PDFTextRun] = []
    for i in 0..<8 {
        let y = 700.0 - Double(i) * 12
        twoColumn.append(run("Left column line \(i)", x: 46, x1: 290, y: y))
        twoColumn.append(run("Right column line \(i)", x: 304, x1: 547, y: y))
    }
    let regions = PDFRegionCutter.regions(twoColumn)
    out.append(check(suite: suite, "14pt 栏缝也能切成两栏",
                     regions.count == 2, detail: "regions=\(regions.count)"))
    out.append(check(
        suite: suite, "两栏各 8 行、互不混入",
        regions.count == 2
            && regions[0].allSatisfy { $0.text.hasPrefix("Left") }
            && regions[1].allSatisfy { $0.text.hasPrefix("Right") },
        detail: regions.map { "\($0.count)" }.joined(separator: "/")))

    let lines = PDFLineBuilder.buildLines(from: twoColumn)
    out.append(check(
        suite: suite, "左右两栏不会被并成假行",
        lines.count == 16 && lines.allSatisfy { line in
            !(line.text.contains("Left") && line.text.contains("Right"))
        },
        detail: "lines=\(lines.count) 首行=\(lines.first?.text ?? "-")"))

    // MARK: - ② 作者行角标落在栏缝里

    var frontPage: [PDFTextRun] = []
    let authors = ["Ángel T. Martínez", "Mariela Speranza", "Francisco J. Ruiz-Dueñas"]
    for (i, name) in authors.enumerated() {
        let y = 690.0 - Double(i) * 15
        // 与真实样本一致：作者名右端**正好**停在上标起点（200.16），
        // 于是名字到标题之间只剩下 12.35 pt，比 1 em（21 pt）小得多。
        frontPage.append(run(name, x: 46, x1: 200.16, y: y, size: 14,
                             font: "TimesNewRomanPS-BoldMT"))
        // 单位角标：落在栏缝里（作者行右侧 200..204）
        frontPage.append(run("1", x: 200.16, x1: 204.36, y: y + 5.3, size: 8.4,
                             font: "TimesNewRomanPS-BoldMT"))
    }
    let titleLines = [
        "Biodegradation of lignocellu-",
        "losics: microbial, chemical,",
        "and enzymatic aspects of",
        "the fungal attack of lignin",
    ]
    for (i, text) in titleLines.enumerated() {
        frontPage.append(run(text, x: 216.71, x1: 542.35, y: 684.29 - Double(i) * 21.0,
                             size: 21, font: "Univers-Black"))
    }
    let frontRegions = PDFRegionCutter.regions(frontPage)
    out.append(check(suite: suite, "作者行与标题分成两个区域",
                     frontRegions.count == 2,
                     detail: frontRegions.map { "\($0.count)" }.joined(separator: "/")))

    let frontLines = PDFLineBuilder.buildLines(from: frontPage)
    out.append(check(
        suite: suite, "作者名不会被粘到标题里",
        frontLines.allSatisfy { line in
            !(line.text.contains("Ruiz-Dueñas") && line.text.contains("losics"))
                && !(line.text.contains("Speranza") && line.text.contains("Biodegradation"))
        },
        detail: frontLines.map(\.text).joined(separator: " | ")))
    out.append(check(
        suite: suite, "作者行的角标仍并回本行",
        frontLines.contains { $0.text == "Ángel T. Martínez1" },
        detail: frontLines.first(where: { $0.text.contains("Ángel") })?.text ?? "nil"))

    // 地址行（12 pt）+ 右栏正文（10 pt）：同一基线、间距 11 pt
    var addressPage: [PDFTextRun] = []
    for i in 0..<4 {
        let y = 500.0 - Double(i) * 13
        addressPage.append(run("Address line \(i)", x: 46, x1: 196, y: y, size: 12))
        addressPage.append(run("Body text on the right side \(i)", x: 215, x1: 546, y: y))
    }
    let addressLines = PDFLineBuilder.buildLines(from: addressPage)
    out.append(check(
        suite: suite, "地址行不会和右栏正文并成一段",
        addressLines.allSatisfy { line in
            !(line.text.contains("Address") && line.text.contains("Body"))
        },
        detail: addressLines.first?.text ?? "-"))

    // MARK: - 保守：单行不吃、宽空格不切

    let cells = [
        run("Sample", x: 60, x1: 90, y: 600, size: 8),
        run("Modulus", x: 300, x1: 340, y: 600, size: 8),
        run("Strength", x: 420, x1: 470, y: 600, size: 8),
    ]
    out.append(check(suite: suite, "只有一条基线时不当分栏",
                     PDFRegionCutter.regions(cells).count == 1, detail: ""))
    out.append(check(suite: suite, "同一行的三个单元格仍是三行",
                     PDFLineBuilder.buildLines(from: cells).count == 3,
                     detail: "\(PDFLineBuilder.buildLines(from: cells).count)"))

    let two = [run("Hello", x: 100, x1: 130, y: 700), run("world", x: 400, x1: 440, y: 700)]
    out.append(check(suite: suite, "两个 run 不单独成一个区域（交给字距判定）",
                     PDFRegionCutter.regions(two).count == 1, detail: ""))

    // MARK: - 横带切分与通栏页眉

    var banded: [PDFTextRun] = []
    for i in 0..<3 {
        banded.append(run("Top block \(i)", x: 60, x1: 400, y: 700 - Double(i) * 12))
        banded.append(run("Bottom block \(i)", x: 60, x1: 400, y: 560 - Double(i) * 12))
    }
    let bands = PDFRegionCutter.regions(banded)
    out.append(check(
        suite: suite, "整幅空白带切成上下两块（顺序不变）",
        bands.count == 2 && bands[0].allSatisfy { $0.text.hasPrefix("Top") }
            && bands[1].allSatisfy { $0.text.hasPrefix("Bottom") },
        detail: bands.map(\.count).description))

    var withHeader: [PDFTextRun] = [run("RUNNING HEAD ACROSS THE PAGE", x: 46, x1: 547, y: 780)]
    for i in 0..<6 {
        let y = 700.0 - Double(i) * 12
        withHeader.append(run("L\(i)", x: 46, x1: 290, y: y))
        withHeader.append(run("R\(i)", x: 304, x1: 547, y: y))
    }
    let headerRegions = PDFRegionCutter.regions(withHeader)
    out.append(check(
        suite: suite, "通栏页眉不阻止分栏",
        headerRegions.count == 3 && headerRegions[0].count == 1,
        detail: headerRegions.map { "\($0.count)" }.joined(separator: "/")))
    let headerLines = PDFLineBuilder.buildLines(from: withHeader)
    out.append(check(
        suite: suite, "页眉单独一行，正文 12 行",
        headerLines.count == 13 && headerLines.allSatisfy { line in
            !(line.text.hasPrefix("L") && line.text.contains("R"))
        },
        detail: "lines=\(headerLines.count)"))

    // MARK: - 扫描线本身

    // 右栏各行起点略有抖动（304/305.5/307）：缝不能被切成三段
    var jittered: [PDFTextRun] = []
    for i in 0..<6 {
        let y = 700.0 - Double(i) * 12
        jittered.append(run("L\(i)", x: 46, x1: 290, y: y))
        jittered.append(run("R\(i)", x: 304 + Double(i % 3) * 1.5, x1: 547, y: y))
    }
    let strips = PDFRegionCutter.freeVerticalStrips(jittered, maxCoverage: 1, minWidth: 6)
    out.append(check(
        suite: suite, "缝不被端点抖动切成碎片",
        strips.count == 1 && (strips.first.map { $0.end - $0.start } ?? 0) >= 10,
        detail: strips.map { String(format: "%.1f..%.1f", $0.start, $0.end) }.joined(separator: " ")))

    out.append(check(suite: suite, "基线计数按 1pt 容差聚簇",
                     PDFRegionCutter.baselineCount([
                        run("a", x: 10, x1: 20, y: 100),
                        run("b", x: 10, x1: 20, y: 100.4),
                        run("c", x: 10, x1: 20, y: 112),
                     ]) == 2, detail: ""))

    // MARK: - 缺字兜底

    out.append(check(
        suite: suite, "缺字的下标换成 ASCII",
        PDFGlyphFallback.apply("H₂O", missing: [0x2082]) == "H2O",
        detail: PDFGlyphFallback.apply("H₂O", missing: [0x2082])))
    out.append(check(
        suite: suite, "没有缺字时文本原样不动",
        PDFGlyphFallback.apply("H₂O", missing: []) == "H₂O", detail: ""))
    out.append(check(
        suite: suite, "装饰符号不被悄悄替换（缺字必须如实报告）",
        PDFGlyphFallback.apply("⇑ 3", missing: [0x21D1]) == "⇑ 3", detail: ""))
    // 参考文献里真实出现的人名：E. Çulcuoğlu / F. Karaosmanoğlu
    out.append(check(
        suite: suite, "缺字的土耳其字母退成基本字母",
        PDFGlyphFallback.apply("Çulcuoğlu", missing: [0x011F]) == "Çulcuoglu",
        detail: PDFGlyphFallback.apply("Çulcuoğlu", missing: [0x011F])))
    out.append(check(
        suite: suite, "字体有的变音字母不动（只在缺字时替换）",
        PDFGlyphFallback.apply("Çulcuoğlu", missing: [0x015F]) == "Çulcuoğlu",
        detail: PDFGlyphFallback.apply("Çulcuoğlu", missing: [0x015F])))

    return out
}
