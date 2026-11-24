import Foundation
import CoreGraphics
import HymnCore

/// P5 测试集：渲染缩放、选择性驱逐、洗版、逐段对照报告。
///
/// 这一组专门补 P4 漏掉的那类断言：**只测尺寸不测内容**。
/// 渲染器出过「画布 1920×1080、页面按 1:1 画在正中」的错，`render-size-a4` 照样通过。
/// 所以这里改成「画一个已知矩形，再把墨迹位置读回来」。
public func pdfP5Suite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-p5"

    // MARK: - 渲染缩放（P4 漏掉的那条）

    let boxed = PDFFixtureP5.page(content: """
    q 0 0 0 rg 100 100 200 100 re f Q
    """)
    let image = PDFPageRenderer.render(
        data: boxed, index: 0, options: .init(dpi: 144))
    let bounds = image?.inkBounds()
    let placementOK: Bool = {
        guard let bounds else { return false }
        return abs(bounds.x0 - 100) < 2 && abs(bounds.y0 - 100) < 2
            && abs(bounds.x1 - 300) < 2 && abs(bounds.y1 - 200) < 2
    }()
    results.append(check(
        suite: suite, "render-content-scale",
        placementOK,
        detail: "矩形 (100,100)-(300,200) 渲染后墨迹 "
            + (bounds.map { String(format: "(%.1f,%.1f)-(%.1f,%.1f)", $0.x0, $0.y0, $0.x1, $0.y1) }
               ?? "读不到")))

    // 同一页在 72dpi 与 144dpi 下的墨迹页面坐标必须一致（缩放不改几何）
    let at72 = PDFPageRenderer.render(data: boxed, index: 0, options: .init(dpi: 72))?.inkBounds()
    let at144 = bounds
    let consistent: Bool = {
        guard let at72, let at144 else { return false }
        return abs(at72.x0 - at144.x0) < 2 && abs(at72.y1 - at144.y1) < 2
    }()
    results.append(check(
        suite: suite, "render-scale-invariant", consistent,
        detail: "72dpi 与 144dpi 的页面坐标一致：\(at72.map { "\($0.x0)" } ?? "-") / "
            + "\(at144.map { "\($0.x0)" } ?? "-")"))

    // MARK: - 选择性驱逐

    let twoRuns = PDFFixtureP5.textPage([
        ("Hello", 700), ("World", 600)
    ])
    let helloRange = PDFFixtureP5.operatorRange(in: twoRuns.pageContent, text: "Hello")
    let worldRange = PDFFixtureP5.operatorRange(in: twoRuns.pageContent, text: "World")

    let keepSecond = TextEvictor.evictText(
        from: twoRuns.pageContent, keeping: worldRange.map { [$0] } ?? [])
    results.append(check(
        suite: suite, "evict-keeps-range",
        keepSecond.data.range(of: Data("Hello".utf8)) == nil
            && keepSecond.data.range(of: Data("World".utf8)) != nil
            && keepSecond.removedRuns == 1,
        detail: "保留 World 后：Hello 在=\(keepSecond.data.range(of: Data("Hello".utf8)) != nil) "
            + "World 在=\(keepSecond.data.range(of: Data("World".utf8)) != nil) "
            + "删除算子 \(keepSecond.removedRuns) 个"))

    let keepBoth = TextEvictor.evictText(
        from: twoRuns.pageContent,
        keeping: [helloRange, worldRange].compactMap { $0 })
    results.append(check(
        suite: suite, "evict-keeps-all-is-noop",
        keepBoth.removedRuns == 0 && keepBoth.data == twoRuns.pageContent,
        detail: "全部保留时删除 \(keepBoth.removedRuns) 个算子，字节是否原样 \(keepBoth.data == twoRuns.pageContent)"))

    let evictAll = TextEvictor.evictText(from: twoRuns.pageContent, keeping: [])
    results.append(check(
        suite: suite, "evict-all-removes-both",
        evictAll.data.range(of: Data("Hello".utf8)) == nil
            && evictAll.data.range(of: Data("World".utf8)) == nil
            && evictAll.removedRuns == 2,
        detail: "删除 \(evictAll.removedRuns) 个算子"))

    // 保留区间错位一字节就必须失效：宁可多删也不能少删（少删=重叠文字）
    if let helloRange {
        let shifted = TextEvictor.evictText(
            from: twoRuns.pageContent,
            keeping: [helloRange.lowerBound + 40..<helloRange.upperBound + 40])
        results.append(check(
            suite: suite, "evict-range-must-match",
            shifted.removedRuns == 2,
            detail: "区间整体后移 40 字节后仍删除 \(shifted.removedRuns) 个算子（应为 2）"))
    }

    // MARK: - 洗版

    let withGarbage = PDFFixtureP5.pageWithUnreferencedObject(marker: "DEADBEEF")
    let document = try? PDFDocument(data: withGarbage)
    var scrubResult: PDFScrub.Result?
    if let document {
        scrubResult = try? PDFScrub.rewrite(document: document)
    }
    results.append(check(
        suite: suite, "scrub-drops-unreferenced",
        scrubResult.map {
            $0.data.range(of: Data("DEADBEEF".utf8)) == nil && $0.droppedObjects >= 1
        } ?? false,
        detail: scrubResult.map {
            "活对象 \($0.liveObjects)，丢弃 \($0.droppedObjects)，"
                + "标记字节还在=\($0.data.range(of: Data("DEADBEEF".utf8)) != nil)"
        } ?? "洗版失败"))

    if let scrubResult {
        let reopened = try? PDFDocument(data: scrubResult.data)
        results.append(check(
            suite: suite, "scrub-roundtrip-valid",
            reopened?.pageCount == 1,
            detail: "洗版后重新解析：页数 \(reopened?.pageCount ?? -1)，字节 \(scrubResult.afterBytes)"))
        results.append(check(
            suite: suite, "scrub-keeps-stream-bytes",
            scrubResult.data.range(of: Data("0 0 0 rg 100 100 200 100 re f".utf8)) != nil,
            detail: "内容流字节原样保留（只重算 /Length 与字典顺序）"))
    }

    // MARK: - 逐段对照报告

    var entry = PDFComparisonReport.Entry(
        id: "p0-b0", kind: "段落", source: "The <Python> & Workbook",
        output: "《Python》工作簿", status: "已译", detail: "", fontSize: 12, sourceFontSize: 12)
    entry.detail = "缩至 10.5pt"
    let section = PDFComparisonReport.PageSection(page: 3, entries: [entry])
    var report = PDFTypesetEngine.Report()
    report.pages = []
    let html = PDFComparisonReport.html(
        sections: [section], report: report, options: .init())
    results.append(check(
        suite: suite, "report-escapes-html",
        html.contains("The &lt;Python&gt; &amp; Workbook")
            && !html.contains("<Python>"),
        detail: "尖括号与 & 已转义"))
    results.append(check(
        suite: suite, "report-has-both-columns",
        html.contains("《Python》工作簿") && html.contains("第 3 页")
            && html.contains("缩至 10.5pt"),
        detail: "译文、页码、处理说明都在"))
    results.append(check(
        suite: suite, "report-json-roundtrip",
        (try? PDFComparisonReport.json(sections: [section]))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .contains("linguanova.compare/1") ?? false,
        detail: "JSON schema 标记存在"))

    // MARK: - 语言判断（跳过纯符号段用）

    results.append(check(
        suite: suite, "script-cjk-detect",
        PDFScript.isCJK(Unicode.Scalar("汉"))
            && PDFScript.isCJK(Unicode.Scalar("あ"))
            && !PDFScript.isCJK(Unicode.Scalar("a"))
            && !PDFScript.hasTranslatableCharacters("— ● 12")
            && PDFScript.hasTranslatableCharacters("Hello"),
        detail: "汉字/假名算 CJK；纯符号与数字不值得送模型"))

    return results
}

/// P5 用的极简 PDF 构造器：内容流可以随便写，用来验证几何与驱逐。
enum PDFFixtureP5 {
    struct TextPage {
        var file: Data
        var pageContent: Data
    }

    static func page(content: String) -> Data {
        build(contents: [content], extraObjects: [])
    }

    /// 两段独立文本，各占一个 BT/ET 块。
    static func textPage(_ runs: [(text: String, y: Int)]) -> TextPage {
        var content = ""
        for run in runs {
            content += "BT /F1 12 Tf 100 \(run.y) Td (\(run.text)) Tj ET\n"
        }
        let data = build(contents: [content],
                         extraObjects: [],
                         resources: "<< /Font << /F1 5 0 R >> >>",
                         extraRefs: ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"])
        return TextPage(file: data, pageContent: Data(content.utf8))
    }

    /// 造一个文本 run（只关心几何与文字，字体信息给常量）。
    /// `text` 为空 + `advance > 0` 用来模拟「取不到 unicode 但占宽度」的字形。
    static func run(_ text: String, x0: Double, x1: Double, y: Double,
                    size: Double, advance: Double? = nil) -> PDFTextRun {
        let box = PDFRect(x0: x0, y0: y - size * 0.8, x1: x1, y1: y + size * 0.2)
        return PDFTextRun(
            pageIndex: 0, text: text, fontName: "Fixture", fontSize: size,
            unscaledFontSize: size,
            origin: PDFPoint(x0, y - size * 0.2),
            endPoint: PDFPoint(x1, y - size * 0.2),
            bbox: box, angle: 0, renderMode: 0,
            advance: advance ?? (x1 - x0),
            glyphCount: max(1, text.count), unmappedGlyphs: text.isEmpty ? 1 : 0,
            runIndex: 0, sourceRange: nil)
    }

    /// 找出包含 `text` 的那个 `Tj` 算子在内容流里的字节区间。
    static func operatorRange(in content: Data, text: String) -> Range<Int>? {
        let bytes = [UInt8](content)
        guard let needle = text.data(using: .utf8) else { return nil }
        let haystack = [UInt8](needle)
        var i = 0
        while i + haystack.count <= bytes.count {
            if Array(bytes[i..<(i + haystack.count)]) == haystack {
                // 往后找 "Tj"
                var j = i + haystack.count
                while j + 1 < bytes.count {
                    if bytes[j] == 0x54, bytes[j + 1] == 0x6A {  // "Tj"
                        return j..<(j + 2)
                    }
                    j += 1
                }
                return nil
            }
            i += 1
        }
        return nil
    }

    /// **多内容流**页面：`/Contents` 是一个数组，每段内容各自一个流对象。
    ///
    /// 真实期刊（Elsevier）就是这样，而且会把语句切在操作数与算子之间：
    /// 数组在一段流的末尾、`TJ` 在下一段流的开头。
    static func multiStream(
        contents: [String], resources: String = "<< >>", extraRefs: [String] = []
    ) -> Data {
        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        func append(_ number: Int, _ body: String) {
            offsets.append(out.count)
            out.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let streamNumbers = (0..<contents.count).map { 4 + $0 }
        let contentsRef = streamNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        append(3, """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] \
        /Resources \(resources) /Contents [\(contentsRef)] >>
        """)
        for (index, content) in contents.enumerated() {
            offsets.append(out.count)
            let body = "\(streamNumbers[index]) 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n"
            out.append(Data(body.utf8))
            out.append(Data(content.utf8))
            out.append(Data("\nendstream\nendobj\n".utf8))
        }
        var next = streamNumbers.last.map { $0 + 1 } ?? 4
        for ref in extraRefs {
            append(next, ref)
            next += 1
        }
        let xrefOffset = out.count
        out.append(Data("xref\n0 \(next)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data("trailer\n<< /Size \(next) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    /// 一页正常内容 + 一个没人引用的对象（洗版应当丢掉它）。
    static func pageWithUnreferencedObject(marker: String) -> Data {
        build(contents: ["q 0 0 0 rg 100 100 200 100 re f Q"],
              extraObjects: ["<< /Marker (\(marker)) >>"])
    }

    static func build(
        contents: [String], extraObjects: [String],
        resources: String = "<< >>", extraRefs: [String] = []
    ) -> Data {
        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        func append(_ number: Int, _ body: String) {
            offsets.append(out.count)
            out.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        append(3, """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] \
        /Resources \(resources) /Contents 4 0 R >>
        """)
        let content = contents.joined(separator: "\n")
        offsets.append(out.count)
        out.append(Data("4 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n".utf8))
        out.append(Data(content.utf8))
        out.append(Data("\nendstream\nendobj\n".utf8))

        var next = 5
        for ref in extraRefs {
            append(next, ref)
            next += 1
        }
        for extra in extraObjects {
            append(next, extra)
            next += 1
        }

        let xrefOffset = out.count
        out.append(Data("xref\n0 \(next)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data("trailer\n<< /Size \(next) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }
}
