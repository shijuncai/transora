import Foundation
import HymnCore

/// 图表区域（柱状图/折线图）识别 + 图表内文字不翻译 + 上标碎片不打断段落。
///
/// 全部来自 `Sample/An evaluation study of mycelium based.pdf` 的真实事故：
/// 期刊版面上的柱状图 x 轴有 24 个竖排品种名，被当成正文翻成「我曾经是」「哇，超级英雄」；
/// 另有一段正文被 `g/cm³` 的上标切成三块，分别翻译后排版成「前后有译文、中间空一段」。
func pdfChartSuite() -> [TestResult] {
    let suite = "pdf-chart"
    var out: [TestResult] = []

    // MARK: - 图表识别

    func bar(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PDFPaintedPath {
        PDFPaintedPath(box: PDFRect(x0: x, y0: y, x1: x + w, y1: y + h), points: 4, filled: true)
    }

    var bars: [PDFPaintedPath] = []
    for i in 0..<20 {
        bars.append(bar(100 + Double(i) * 12, 300, 7, 100 + Double(i % 5) * 10))
    }
    let barChart = PDFChartDetector.detect(
        paths: bars, pageWidth: 600, pageHeight: 800, tables: [])
    out.append(check(suite: suite, "柱状图被识别成图表区域",
                     barChart.count == 1,
                     detail: barChart.map { "\($0.box)" }.joined(separator: " ")))
    out.append(check(suite: suite, "图表区域覆盖所有柱子并略外扩",
                     barChart.first.map { chart in
                         chart.box.x0 <= 100 && chart.box.x1 >= 100 + 19 * 12 + 7
                             && chart.box.y0 <= 300 && chart.box.y1 >= 400
                     } ?? false,
                     detail: barChart.first.map { "\($0.box)" } ?? "nil"))

    // 折线图：路径少但点数多
    let polyline = PDFPaintedPath(
        box: PDFRect(x0: 120, y0: 320, x1: 480, y1: 460), points: 260, filled: false)
    let axes = PDFPaintedPath(
        box: PDFRect(x0: 120, y0: 320, x1: 480, y1: 460), points: 8, filled: false)
    let lineChart = PDFChartDetector.detect(
        paths: [polyline, axes], pageWidth: 600, pageHeight: 800, tables: [])
    out.append(check(suite: suite, "折线图按端点数识别（路径只有 2 条）",
                     lineChart.count == 1, detail: "\(lineChart.count)"))

    // 整页底色不是图表
    let background = PDFPaintedPath(
        box: PDFRect(x0: 0, y0: 0, x1: 600, y1: 800), points: 4, filled: true)
    out.append(check(suite: suite, "整页底色不算图表",
                     PDFChartDetector.detect(paths: [background], pageWidth: 600,
                                             pageHeight: 800, tables: []).isEmpty))

    // 表格网格形状相似，但已经有表格框时不能再判成图表
    var grid: [PDFPaintedPath] = []
    for i in 0..<12 {
        grid.append(PDFPaintedPath(
            box: PDFRect(x0: 100, y0: 300 + Double(i) * 12, x1: 500, y1: 300 + Double(i) * 12 + 1),
            points: 2, filled: false))
    }
    let table = ILTable(id: "t0", box: PDFRect(x0: 95, y0: 295, x1: 505, y1: 450),
                        rowCount: 12, columnCount: 3, cells: [], confidence: 1)
    out.append(check(suite: suite, "已识别的表格网格不会被当图表",
                     PDFChartDetector.detect(paths: grid, pageWidth: 600, pageHeight: 800,
                                             tables: [table]).isEmpty,
                     detail: "\(PDFChartDetector.detect(paths: grid, pageWidth: 600, pageHeight: 800, tables: [table]).count)"))

    // 太小的簇不是图表（三个小装饰点）
    out.append(check(suite: suite, "小装饰框不触发图表识别",
                     PDFChartDetector.detect(
                        paths: [bar(10, 10, 3, 3), bar(20, 10, 3, 3), bar(30, 10, 3, 3)],
                        pageWidth: 600, pageHeight: 800, tables: []).isEmpty))

    // MARK: - 图表内文字钉住 / 图注仍然翻译

    func line(_ text: String, _ box: PDFRect, size: Double = 7) -> ILLine {
        ILLine(text: text, box: box, baseline: box.y0 + size * 0.2, fontSize: size,
               spans: [], angle: 0)
    }
    func block(_ id: String, _ text: String, _ box: PDFRect, size: Double = 7) -> ILBlock {
        ILBlock(id: id, type: .paragraph, box: box, lines: [line(text, box, size: size)],
                fontSize: size, text: text, confidence: 1, column: 0)
    }

    var page = ILPage(index: 0, width: 600, height: 800, rotation: 0)
    page.charts = [
        ILChart(id: "c0", box: PDFRect(x0: 340, y0: 560, x1: 560, y1: 790),
                pathCount: 20, pointCount: 200),
        // 第二张图：用来验证「贴在绘图区右侧的图例」也能被认出来
        ILChart(id: "c1", box: PDFRect(x0: 120, y0: 130, x1: 520, y1: 290),
                pathCount: 18, pointCount: 180),
    ]
    let tick = block("b0", "70", PDFRect(x0: 345, y0: 700, x1: 360, y1: 708))
    let axisTitle = block("b1", "Sound Pressure Level (dB A)",
                          PDFRect(x0: 343, y0: 640, x1: 353, y1: 730))
    let legend = block("b2", "A-weighted Road Noise",
                       PDFRect(x0: 460, y0: 760, x1: 555, y1: 770))
    let caption = block("b3", "Fig. 3. Test comparing the audio spectrum.",
                        PDFRect(x0: 340, y0: 520, x1: 560, y1: 545))
    let body = block("b4", "In looking at the performance of the various mixtures, one of the test parameters.",
                     PDFRect(x0: 60, y0: 600, x1: 330, y1: 660), size: 8)
    out.append(check(suite: suite, "图表内刻度/轴标题/图例保持原文",
                     PDFTypesetEngine.keepsOriginal(tick, page: page)
                        && PDFTypesetEngine.keepsOriginal(axisTitle, page: page)
                        && PDFTypesetEngine.keepsOriginal(legend, page: page),
                     detail: "tick=\(PDFTypesetEngine.keepsOriginal(tick, page: page)) "
                        + "axis=\(PDFTypesetEngine.keepsOriginal(axisTitle, page: page)) "
                        + "legend=\(PDFTypesetEngine.keepsOriginal(legend, page: page))"))
    out.append(check(suite: suite, "图注（Fig. 3. …）仍然翻译",
                     !PDFTypesetEngine.keepsOriginal(caption, page: page)))
    out.append(check(suite: suite, "图表外的正文段落照常翻译",
                     !PDFTypesetEngine.keepsOriginal(body, page: page)))

    // 图例排在绘图区右边框外面（真实样本差 13pt），也要钉住
    let sideLegend = block("b6", "Hemp Pith 50%, Switch Grass 50%",
                           PDFRect(x0: 533, y0: 174, x1: 600, y1: 189))
    out.append(check(suite: suite, "绘图区右侧的图例也保持原文",
                     PDFTypesetEngine.keepsOriginal(sideLegend, page: page),
                     detail: "\(PDFTypesetEngine.keepsOriginal(sideLegend, page: page))"))
    // 同一位置若是整句正文（以句号收尾），不能跟着一起钉
    let sideSentence = block("b7", "Results were normalized to the brass plug response.",
                             PDFRect(x0: 533, y0: 174, x1: 600, y1: 189))
    out.append(check(suite: suite, "侧边整句不被当图例",
                     !PDFTypesetEngine.keepsOriginal(sideSentence, page: page)))

    // 半截探进图区的正文（整块并不在图内）不能被钉住
    let straddling = block("b5", "the critical frequency range for absorption",
                           PDFRect(x0: 300, y0: 600, x1: 470, y1: 620), size: 8)
    out.append(check(suite: suite, "伸进图区的正文段落不被误钉",
                     !PDFTypesetEngine.keepsOriginal(straddling, page: page)))

    // MARK: - 公式钉住

    let formula = block("f0", "Swr = Pmaxima / Pminima (1)",
                        PDFRect(x0: 80, y0: 300, x1: 260, y1: 320), size: 9)
    out.append(check(suite: suite, "公式块保持原文",
                     PDFTypesetEngine.keepsOriginal(formula, page: page)))
    let sentence = block("f1", "The ratio Swr equals 1.0079 and is reported in Eq. 1 for each sample",
                         PDFRect(x0: 80, y0: 260, x1: 330, y1: 280), size: 8)
    out.append(check(suite: suite, "带等号的句子不算公式",
                     !PDFTypesetEngine.keepsOriginal(sentence, page: page)))

    // MARK: - 上标碎片不打断段落

    let body1 = line("test parameters that was quantiﬁed was board density. The mean",
                     PDFRect(x0: 73.8, y0: 355.1, x1: 325.4, y1: 363.0), size: 8)
    let superscript = line("3", PDFRect(x0: 302, y0: 347.9, x1: 305.6, y1: 353.9), size: 6)
    let body2 = line("density of the entire set of boards was found to be 0.340 g/cm with",
                     PDFRect(x0: 73.8, y0: 344.6, x1: 325.4, y1: 352.6), size: 8)
    let blocks = PDFParagraphBuilder.buildBlocks(
        lines: [body1, superscript, body2], pageWidth: 600)
    let bodies = blocks.filter { $0.text.count > 20 }
    out.append(check(suite: suite, "上标碎片把两行并回同一段",
                     bodies.count == 1,
                     detail: blocks.map { "\($0.text.prefix(18))" }.joined(separator: " | ")))
    out.append(check(suite: suite, "上标碎片单独成块（将来按碎片钉住）",
                     blocks.contains { $0.text == "3" },
                     detail: "\(blocks.count) 块"))
    out.append(check(suite: suite, "段落文本不被上标污染",
                     bodies.first?.text.contains("The mean density of the entire") == true,
                     detail: bodies.first?.text ?? "nil"))

    out.append(check(suite: suite, "项目符号 `◦` 也算碎片",
                     PDFParagraphBuilder.isFragmentLine(
                        line("◦", PDFRect(x0: 73.8, y0: 200, x1: 79, y1: 208), size: 8))))
    out.append(check(suite: suite, "8pt 的数字不算上标碎片（可能是列表序号）",
                     !PDFParagraphBuilder.isFragmentLine(
                        line("3", PDFRect(x0: 73.8, y0: 200, x1: 78, y1: 208), size: 8))))

    // MARK: - 词间空格：按字体实际词距补，不再硬套 0.25em

    func run(_ text: String, x0: Double, x1: Double, size: Double = 8) -> PDFTextRun {
        PDFTextRun(
            pageIndex: 0, text: text, fontName: "GulliverRM", fontSize: size,
            unscaledFontSize: size,
            origin: PDFPoint(x0, 360), endPoint: PDFPoint(x1, 360),
            bbox: PDFRect(x0: x0, y0: 356, x1: x1, y1: 364),
            angle: 0, renderMode: 0, advance: x1 - x0,
            glyphCount: text.count, unmappedGlyphs: 0)
    }
    // 真实样本：GulliverRM 的 space 只有 0.19em（1.51pt @ 8pt）
    let tight = PDFLineBuilder.buildLines(from: [
        run("In", x0: 85.78, x1: 93.36), run("looking", x0: 94.87, x1: 123.36),
        run("at", x0: 124.86, x1: 132.25),
    ])
    out.append(check(suite: suite, "0.19em 的词距也补空格（原 0.25em 阈值会粘连）",
                     tight.first?.text == "In looking at",
                     detail: tight.first?.text ?? "nil"))
    // 同一单词被字体切换切开：间距≈0.2pt，不能补空格
    let split = PDFLineBuilder.buildLines(from: [
        run("myce", x0: 100, x1: 120), run("lium", x0: 120.2, x1: 140),
    ])
    out.append(check(suite: suite, "词内 0.2pt 间隙不插空格",
                     split.first?.text == "mycelium", detail: split.first?.text ?? "nil"))

    return out
}
