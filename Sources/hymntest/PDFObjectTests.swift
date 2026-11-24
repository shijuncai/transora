import Foundation
import HymnCore

/// P0 对象层的测试集。
///
/// 全部样本在内存里构造，不依赖外部 PDF 文件——保证「同输入同输出」，
/// 也保证在别人的机器上、在 CI 里跑出来的结论一样。
public func pdfObjectSuite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-object"

    // MARK: 词法 / 语法

    func parse(_ text: String) -> PDFValue? {
        var p = PDFParser([UInt8](text.utf8))
        return try? p.parseValue()
    }

    results.append(check(
        suite: suite, "number-int",
        parse("42") == .int(42),
        detail: "42"))

    results.append(check(
        suite: suite, "number-real",
        parse("-3.25") == .real(-3.25),
        detail: "-3.25"))

    results.append(check(
        suite: suite, "number-leading-dot",
        parse(".5") == .real(0.5),
        detail: ".5"))

    results.append(check(
        suite: suite, "reference",
        parse("12 0 R") == .reference(PDFRef(12, 0)),
        detail: "12 0 R"))

    results.append(check(
        suite: suite, "reference-not-confused-with-array",
        parse("[12 0 R 13 0 R]")?.arrayValue?.count == 2,
        detail: "数组里两个引用"))

    results.append(check(
        suite: suite, "name-escaped",
        parse("/A#20B") == .name("A B"),
        detail: "A#20B → A B"))

    results.append(check(
        suite: suite, "string-nested-parens",
        parse("(a(b)c)") == .string(Data([0x61, 0x28, 0x62, 0x29, 0x63])),
        detail: "嵌套括号"))

    results.append(check(
        suite: suite, "string-octal-escape",
        parse("(\\101\\102)") == .string(Data([0x41, 0x42])),
        detail: "八进制 \\101\\102 → AB"))

    results.append(check(
        suite: suite, "string-hex-odd",
        parse("<41424>") == .string(Data([0x41, 0x42, 0x40])),
        detail: "奇数位补 0"))

    let dict = parse("<< /Type /Page /Count 3 /Kids [4 0 R] >>")?.dictionaryValue
    results.append(check(
        suite: suite, "dictionary",
        dict?["Type"] == .name("Page") && dict?["Count"] == .int(3),
        detail: "Type/Count"))

    results.append(check(
        suite: suite, "dictionary-serialize-roundtrip",
        {
            guard let original = parse("<< /A 1 /B (hi) /C [/X 2 0 R] >>") else { return false }
            let bytes = PDFSerialize.value(original)
            var p = PDFParser(bytes)
            guard let again = try? p.parseValue() else { return false }
            return again == original
        }(),
        detail: "序列化后再解析应相等"))

    results.append(check(
        suite: suite, "real-format-no-exponent",
        PDFSerialize.value(.real(1.0)) == Data("1".utf8)
            && PDFSerialize.value(.real(1.5)) == Data("1.5".utf8),
        detail: "1.0→1 / 1.5→1.5"))

    // MARK: 过滤器

    let sample = Data(String(repeating: "PDF fidelity 宋体测试 ", count: 200).utf8)
    let deflated = PDFFilters.deflate(sample)
    let inflated = try? PDFFilters.inflate(deflated)
    results.append(check(
        suite: suite, "flate-roundtrip",
        inflated == sample,
        detail: "原始 \(sample.count) B → 压缩 \(deflated.count) B"))

    results.append(check(
        suite: suite, "flate-zlib-header",
        deflated.count > 2 && deflated[0] == 0x78,
        detail: "首字节 \(deflated.first.map { String(format: "0x%02X", $0) } ?? "?")"))

    results.append(check(
        suite: suite, "flate-raw-deflate-fallback",
        {
            // 去掉 zlib 头与 adler32，剩下裸 deflate，必须也能解
            let bytes = [UInt8](deflated)
            guard bytes.count > 6 else { return false }
            let raw = Data(bytes[2..<(bytes.count - 4)])
            return (try? PDFFilters.inflate(raw)) == sample
        }(),
        detail: "裸 deflate 兜底"))

    results.append(check(
        suite: suite, "asciihex",
        (try? PDFFilters.asciiHexDecode(Data("48656C6C6F>".utf8))) == Data("Hello".utf8),
        detail: "48656C6C6F → Hello"))

    // 用本地编码器往返，避免把记错的常量当成事实
    func ascii85Encode(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let n = min(4, bytes.count - i)
            var value: UInt32 = 0
            for k in 0..<4 {
                value = value << 8 | (k < n ? UInt32(bytes[i + k]) : 0)
            }
            if n == 4 && value == 0 {
                out.append(0x7A) // 'z'
                i += 4
                continue
            }
            var digits = [UInt8](repeating: 0, count: 5)
            var v = value
            for k in stride(from: 4, through: 0, by: -1) {
                digits[k] = UInt8(v % 85)
                v /= 85
            }
            for k in 0..<(n + 1) { out.append(digits[k] + 33) }
            i += n
        }
        out.append(contentsOf: Array("~>".utf8))
        return out
    }

    let a85 = ascii85Encode(Data("Hello world".utf8))
    results.append(check(
        suite: suite, "ascii85-roundtrip",
        (try? PDFFilters.ascii85Decode(a85)) == Data("Hello world".utf8),
        detail: "\"Hello world\" → \(String(decoding: a85, as: UTF8.self))"))

    results.append(check(
        suite: suite, "ascii85-zero-shorthand",
        (try? PDFFilters.ascii85Decode(Data("z~>".utf8))) == Data([0, 0, 0, 0]),
        detail: "z → 4 个 0 字节"))

    // RunLength: 0x02(长度3) + abc, 0xFD(重复 4 个) + X, 0x80(EOD)
    var runLength = Data([0x02])
    runLength.append(Data("abc".utf8))
    runLength.append(0xFD)
    runLength.append(0x58)
    runLength.append(0x80)
    results.append(check(
        suite: suite, "runlength",
        (try? PDFFilters.runLengthDecode(runLength)) == Data("abcXXXX".utf8),
        detail: "abc + 4×X"))

    // PNG 预测器 type 2(Up)，两行 4 字节
    var pngRows = Data()
    pngRows.append(contentsOf: [2, 10, 20, 30, 40])   // 第一行 up 于全 0
    pngRows.append(contentsOf: [2, 1, 1, 1, 1])       // 第二行每字节 +1
    let predicted = try? PDFFilters.applyPredictor(
        pngRows, parms: ["Predictor": .int(12), "Columns": .int(4), "Colors": .int(1)])
    results.append(check(
        suite: suite, "predictor-png-up",
        predicted == Data([10, 20, 30, 40, 11, 21, 31, 41]),
        detail: "两行 4 列 up"))

    // MARK: 文档结构

    let built = SyntheticPDF.make()
    guard let document = try? PDFDocument(data: built) else {
        results.append(check(suite: suite, "document-parse", false, detail: "构造的 PDF 解析失败"))
        return results
    }

    results.append(check(
        suite: suite, "document-header",
        document.version == "1.7",
        detail: "版本 \(document.version)"))

    results.append(check(
        suite: suite, "document-startxref",
        document.startXRef > 0,
        detail: "startxref @\(document.startXRef)"))

    results.append(check(
        suite: suite, "document-pagecount",
        document.pageCount == 1,
        detail: "\(document.pageCount) 页"))

    results.append(check(
        suite: suite, "document-catalog",
        document.catalog["Type"] == .name("Catalog"),
        detail: "Catalog 可解析"))

    results.append(check(
        suite: suite, "document-not-encrypted",
        document.isEncrypted == false,
        detail: "未加密"))

    let pages = document.pages()
    let contents = (try? document.contentData(of: pages[0])) ?? []
    let text = contents.first.map { String(decoding: $0, as: UTF8.self) } ?? ""
    results.append(check(
        suite: suite, "document-content-decoded",
        text.contains("(Hello) Tj") && text.contains("100 100 re f"),
        detail: "解出 \(text.count) 字符"))

    // MARK: 内容流分析

    let analysis = PDFContentStream.analyze(Data(text.utf8))
    results.append(check(
        suite: suite, "content-analyze-text-ops",
        analysis.textShowingCount == 1 && analysis.textBlockCount == 1,
        detail: "Tj=\(analysis.textShowingCount) BT=\(analysis.textBlockCount)"))

    results.append(check(
        suite: suite, "content-analyze-graphics-ops",
        (analysis.operatorCounts["re"] ?? 0) == 1 && (analysis.operatorCounts["S"] ?? 0) == 1,
        detail: "re=\(analysis.operatorCounts["re"] ?? 0) S=\(analysis.operatorCounts["S"] ?? 0)"))

    // MARK: 文本驱逐

    let evicted = TextEvictor.evictText(from: Data(text.utf8))
    let evictedText = String(decoding: evicted.data, as: UTF8.self)
    results.append(check(
        suite: suite, "evict-removes-glyphs",
        !evictedText.contains("Hello") && !evictedText.contains("Tj"),
        detail: "删了 \(evicted.removedRuns) 段 / \(evicted.bytesRemoved) 字节"))

    results.append(check(
        suite: suite, "evict-keeps-graphics-bytes",
        evictedText.contains("0 0 100 100 re f") && evictedText.contains("100 0 m 200 0 l S"),
        detail: "图形算子原样保留"))

    results.append(check(
        suite: suite, "evict-keeps-text-block-shell",
        evictedText.contains("BT") && evictedText.contains("ET") && evictedText.contains("/F1"),
        detail: "BT/ET/Tf 残留无害"))

    // TJ 数组 + ' 与 " 也要删
    let mixed = #"BT /F1 10 Tf [(A) -200 (B)] TJ (C) ' 1 2 (D) " ET 0 0 50 50 re f"#
    let mixedEvicted = TextEvictor.evictText(from: Data(mixed.utf8))
    let mixedText = String(decoding: mixedEvicted.data, as: UTF8.self)
    results.append(check(
        suite: suite, "evict-four-operators",
        mixedEvicted.removedRuns == 3
            && !mixedText.contains("TJ")
            && mixedText.contains("0 0 50 50 re f"),
        detail: "TJ/'/\" 三段，re 保留"))

    // 内联图像：二进制里可能含 "Tj" 字样，绝不能被误删或截断
    var inline = Data("BI /W 4 /H 1 /BPC 8 /CS /G ID ".utf8)
    inline.append(contentsOf: [0x00, 0x54, 0x6A, 0x00]) // 含 'T' 'j' 字节
    inline.append(contentsOf: Data(" EI BT /F1 9 Tf (x) Tj ET".utf8))
    let inlineEvicted = TextEvictor.evictText(from: inline)
    results.append(check(
        suite: suite, "evict-inline-image-intact",
        inlineEvicted.data.count > 0
            && [UInt8](inlineEvicted.data).contains(0x54)
            && String(decoding: inlineEvicted.data, as: UTF8.self).contains("EI")
            && !String(decoding: inlineEvicted.data, as: UTF8.self).contains("(x)"),
        detail: "内联图像字节保留，正文删除"))

    let inlineAnalysis = PDFContentStream.analyze(inline)
    results.append(check(
        suite: suite, "analyze-inline-image",
        inlineAnalysis.inlineImageCount == 1,
        detail: "BI=\(inlineAnalysis.inlineImageCount)"))

    // 没有文本算子的内容流必须原样返回（CAD/纯图页）
    let noTextSource = Data("0 0 10 10 re f 0 0 m 10 10 l S".utf8)
    let noTextResult = TextEvictor.evictText(from: noTextSource)
    results.append(check(
        suite: suite, "evict-no-text-is-noop",
        noTextResult.removedRuns == 0 && noTextResult.data == noTextSource,
        detail: "无文本时字节不变"))

    // MARK: 增量写回

    let (output, report) = try! PDFEvictor.evictText(document: document)
    results.append(check(
        suite: suite, "writer-grows-file",
        output.count > document.data.count,
        detail: "\(document.data.count) → \(output.count) B"))

    results.append(check(
        suite: suite, "writer-report",
        report.changedObjects == 1 && report.totalRemovedRuns == 1,
        detail: "改 \(report.changedObjects) 个对象"))

    guard let rewritten = try? PDFDocument(data: output) else {
        results.append(check(suite: suite, "writer-reparse", false, detail: "重解析失败"))
        return results
    }

    results.append(check(
        suite: suite, "writer-reparse-pages",
        rewritten.pageCount == 1,
        detail: "\(rewritten.pageCount) 页"))

    let newPages = rewritten.pages()
    let newText = ((try? rewritten.contentData(of: newPages[0])) ?? [])
        .first.map { String(decoding: $0, as: UTF8.self) } ?? ""
    results.append(check(
        suite: suite, "writer-reparse-content",
        !newText.contains("Hello") && newText.contains("100 100 re f"),
        detail: "文本已消失，图形仍在"))

    // 未被改动的对象必须逐字节一致：字体对象是 5 0 R
    let oldFont = (try? document.resolve(PDFRef(5, 0))) ?? .null
    let newFont = (try? rewritten.resolve(PDFRef(5, 0))) ?? .null
    results.append(check(
        suite: suite, "writer-untouched-object-identical",
        oldFont == newFont && oldFont != .null,
        detail: "5 0 R 字体对象未变"))

    results.append(check(
        suite: suite, "writer-new-startxref",
        rewritten.startXRef > document.startXRef,
        detail: "startxref \(document.startXRef) → \(rewritten.startXRef)"))

    results.append(check(
        suite: suite, "writer-prev-chain",
        rewritten.trailer["Prev"]?.intValue == document.startXRef,
        detail: "/Prev 指回旧 xref"))

    results.append(check(
        suite: suite, "writer-end-marker",
        String(decoding: output.suffix(8), as: UTF8.self).contains("%%EOF"),
        detail: "以 %%EOF 结尾"))

    // MARK: 交叉引用流路径（PDF 1.5+ 常见，带对象流的文件都走这条）
    //
    // 回归用例：经典表 + /Prev 指向 xref 流会让 CoreGraphics 直接
    // 报 "failed to find start of cross-reference section"，
    // 所以必须照样写 xref 流。

    let streamPDF = SyntheticPDF.makeWithXRefStream()
    guard let streamDoc = try? PDFDocument(data: streamPDF) else {
        results.append(check(suite: suite, "xrefstream-parse", false, detail: "解析失败"))
        return results
    }
    results.append(check(
        suite: suite, "xrefstream-parse",
        streamDoc.pageCount == 1 && streamDoc.xrefSections.first?.kind == "stream",
        detail: "\(streamDoc.pageCount) 页，首段=\(streamDoc.xrefSections.first?.kind ?? "?")"))

    let streamText = ((try? streamDoc.contentData(of: streamDoc.pages()[0])) ?? [])
        .first.map { String(decoding: $0, as: UTF8.self) } ?? ""
    results.append(check(
        suite: suite, "xrefstream-content",
        streamText.contains("(Hello) Tj"),
        detail: "内容流可解码"))

    guard let streamEvicted = try? PDFEvictor.evictText(document: streamDoc) else {
        results.append(check(suite: suite, "xrefstream-evict", false, detail: "驱逐失败"))
        return results
    }
    results.append(check(
        suite: suite, "xrefstream-writes-xref-stream",
        String(decoding: streamEvicted.output.suffix(2000), as: UTF8.self).contains("/Type /XRef")
            || String(decoding: streamEvicted.output.suffix(2000), as: UTF8.self).contains("/Type/XRef"),
        detail: "新版仍是交叉引用流"))

    if let streamRewritten = try? PDFDocument(data: streamEvicted.output) {
        let rewrittenText = ((try? streamRewritten.contentData(of: streamRewritten.pages()[0])) ?? [])
            .first.map { String(decoding: $0, as: UTF8.self) } ?? ""
        results.append(check(
            suite: suite, "xrefstream-reparse",
            streamRewritten.pageCount == 1
                && !rewrittenText.contains("Hello")
                && rewrittenText.contains("100 100 re f"),
            detail: "\(streamRewritten.pageCount) 页，文本已消失"))
    } else {
        results.append(check(suite: suite, "xrefstream-reparse", false, detail: "重解析失败"))
    }

    return results
}

/// 在内存里拼一份最小但合法的 PDF（含 xref 偏移计算）。
enum SyntheticPDF {
    static func make() -> Data {
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
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
        /Resources << /Font << /F1 5 0 R >> /XObject << >> >> /Contents 4 0 R >>
        """)

        let content = """
        BT /F1 12 Tf 72 700 Td (Hello) Tj ET
        q 1 0 0 1 0 0 cm
        0 0 100 100 re f
        100 0 m 200 0 l S
        Q
        """
        let contentBytes = Data(content.utf8)
        offsets.append(out.count)
        out.append(Data("4 0 obj\n<< /Length \(contentBytes.count) >>\nstream\n".utf8))
        out.append(contentBytes)
        out.append(Data("\nendstream\nendobj\n".utf8))

        append(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        let xrefOffset = out.count
        out.append(Data("xref\n0 6\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    /// 与 make() 对象相同，但用**交叉引用流**收尾（模拟 PDF 1.5+ / 带对象流的文件）。
    static func makeWithXRefStream() -> Data {
        var out = Data()
        out.append(Data("%PDF-1.5\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8))

        var offsets: [Int] = []
        func append(_ number: Int, _ body: String) {
            offsets.append(out.count)
            out.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }

        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        append(3, """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
        /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>
        """)

        let content = """
        BT /F1 12 Tf 72 700 Td (Hello) Tj ET
        0 0 100 100 re f
        """
        let contentBytes = Data(content.utf8)
        offsets.append(out.count)
        out.append(Data("4 0 obj\n<< /Length \(contentBytes.count) >>\nstream\n".utf8))
        out.append(contentBytes)
        out.append(Data("\nendstream\nendobj\n".utf8))

        append(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        // 对象 6 就是交叉引用流本身
        let xrefOffset = out.count
        var table = Data()
        // 行 0：free（type=0，offset=0，gen=65535）——必须正好 7 字节
        table.append(contentsOf: [0, 0, 0, 0, 0, 0xFF, 0xFF])
        for offset in offsets {
            table.append(1)
            let v = UInt32(offset)
            table.append(UInt8((v >> 24) & 0xFF))
            table.append(UInt8((v >> 16) & 0xFF))
            table.append(UInt8((v >> 8) & 0xFF))
            table.append(UInt8(v & 0xFF))
            table.append(0)
            table.append(0)
        }
        // 行 6：xref 流自身
        table.append(1)
        let selfOffset = UInt32(xrefOffset)
        table.append(UInt8((selfOffset >> 24) & 0xFF))
        table.append(UInt8((selfOffset >> 16) & 0xFF))
        table.append(UInt8((selfOffset >> 8) & 0xFF))
        table.append(UInt8(selfOffset & 0xFF))
        table.append(0)
        table.append(0)

        let xrefHeader = "6 0 obj\n<< /Type /XRef /Size 7 /W [1 4 2] /Index [0 7] "
            + "/Root 1 0 R /Length \(table.count) >>\nstream\n"
        out.append(Data(xrefHeader.utf8))
        out.append(table)
        out.append(Data("\nendstream\nendobj\n".utf8))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }
}
