import Foundation
import CryptoKit
import HymnCore

// MARK: - PDF 对象层命令（P0）
//
// 三个命令都不改语义、不联网、不调用外部进程：
//   pdf-dump     只看结构，验证解析器能用
//   pdf-inspect  看内容流算子分布，验证分词器能正确跳过内联图像
//   pdf-evict    真删文本显示算子并增量写回，验证「非文本字节不变」

extension HymnCtl {
    static func requirePath(_ args: [String], at index: Int, label: String) -> String {
        guard args.count > index else {
            fputs("缺少参数：\(label)\n", stderr)
            exit(2)
        }
        return args[index]
    }

    static func openDocument(_ path: String) -> PDFDocument {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            fputs("文件不存在：\(path)\n", stderr)
            exit(2)
        }
        do {
            return try PDFDocument(url: url)
        } catch {
            fputs("解析失败：\(error)\n", stderr)
            exit(3)
        }
    }

    static func jsonLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    // MARK: pdf-dump

    struct DumpReport: Encodable {
        var file: String
        var bytes: Int
        var version: String
        var pageCount: Int
        var encrypted: Bool
        var objectCount: Int
        var xrefEntries: Int
        var startXRef: Int
        var pages: [PageSummary]
    }

    struct PageSummary: Encodable {
        var page: Int
        var contentStreams: Int
        var contentBytes: Int
        var formXObjects: Int
        var mediaBox: String
    }

    static func pdfDump(_ args: [String]) throws {
        let path = requirePath(args, at: 1, label: "输入 PDF")
        let document = openDocument(path)
        let pages = document.pages()

        var summaries: [PageSummary] = []
        for (i, page) in pages.enumerated() {
            let data = (try? document.contentData(of: page)) ?? []
            let box = page["MediaBox"]?.arrayValue?.compactMap(\.doubleValue) ?? []
            summaries.append(PageSummary(
                page: i + 1,
                contentStreams: data.count,
                contentBytes: data.reduce(0) { $0 + $1.count },
                formXObjects: document.formXObjectRefs(of: page).count,
                mediaBox: box.count == 4
                    ? box.map { String(format: "%.1f", $0) }.joined(separator: " ")
                    : "?"))
        }

        let report = DumpReport(
            file: URL(fileURLWithPath: path).lastPathComponent,
            bytes: document.data.count,
            version: document.version,
            pageCount: pages.count,
            encrypted: document.isEncrypted,
            objectCount: document.cachedObjectCount,
            xrefEntries: document.xrefEntryCount,
            startXRef: document.startXRef,
            pages: summaries)

        if args.contains("--json") {
            jsonLine(report)
        } else {
            print("文件      \(report.file)（\(report.bytes) 字节）")
            print("版本      PDF \(report.version)")
            print("页数      \(report.pageCount)")
            print("xref      \(report.xrefEntries) 条，startxref @\(report.startXRef)")
            print("加密      \(report.encrypted ? "是（本版本拒绝处理）" : "否")")
            if pages.isEmpty {
                print("")
                print("⚠️ 页数为 0，诊断：")
                print("  trailer 键  \(document.trailer.keys.sorted().joined(separator: " "))")
                let sections = document.xrefSections
                print("  xref 段     \(sections.count) 个："
                      + sections.prefix(3).map { "\($0.kind)@\($0.offset)" }.joined(separator: " ← ")
                      + (sections.count > 3 ? " … 末段 \(sections.last?.kind ?? "?")@\(sections.last?.offset ?? 0)" : ""))
                if let root = document.catalogRef {
                    let resolved = (try? document.resolve(root)) ?? .null
                    print("  /Root       \(root) → "
                          + (resolved.isNull ? "解析为 null（对象缺失或偏移错误）"
                             : "Type=\(resolved["Type"]?.nameValue ?? "?")"))
                    print("  /Pages      \(resolved["Pages"].map { "\($0)" } ?? "缺失")")
                    if case .reference(let pr)? = resolved["Pages"] {
                        let pageObject = (try? document.resolve(pr)) ?? .null
                        print("              在 xref 中=\(document.xrefHasObject(pr.number))"
                              + "  解析=\(pageObject.isNull ? "null" : "OK")"
                              + "  Kids=\(pageObject["Kids"]?.arrayValue?.count ?? -1)")
                    }
                } else {
                    print("  /Root       缺失")
                }
            }
            print("")
            print("页  内容流  解码字节    Form   MediaBox")
            for p in summaries.prefix(40) {
                print(String(format: "%3d  %5d  %8d  %6d   %@",
                             p.page, p.contentStreams, p.contentBytes, p.formXObjects, p.mediaBox))
            }
            if summaries.count > 40 { print("… 其余 \(summaries.count - 40) 页省略") }
        }
    }

    // MARK: pdf-inspect

    struct InspectReport: Encodable {
        var page: Int
        var streams: Int
        var bytes: Int
        var textShowingOperators: Int
        var textBlocks: Int
        var inlineImages: Int
        var topOperators: [String: Int]
    }

    static func pdfInspect(_ args: [String]) throws {
        let path = requirePath(args, at: 1, label: "输入 PDF")
        let document = openDocument(path)
        let pages = document.pages()
        let only = Int(option(args, "--page", ""))

        var reports: [InspectReport] = []
        for (i, page) in pages.enumerated() {
            if let only, only != i + 1 { continue }
            let data = (try? document.contentData(of: page)) ?? []
            var merged = PDFContentStream.Analysis()
            var total = 0
            for d in data {
                total += d.count
                let a = PDFContentStream.analyze(d)
                merged.textShowingCount += a.textShowingCount
                merged.textBlockCount += a.textBlockCount
                merged.inlineImageCount += a.inlineImageCount
                for (k, v) in a.operatorCounts { merged.operatorCounts[k, default: 0] += v }
            }
            reports.append(InspectReport(
                page: i + 1,
                streams: data.count,
                bytes: total,
                textShowingOperators: merged.textShowingCount,
                textBlocks: merged.textBlockCount,
                inlineImages: merged.inlineImageCount,
                topOperators: Dictionary(uniqueKeysWithValues: merged.topOperators)))
        }

        if args.contains("--json") {
            jsonLine(reports)
        } else {
            for r in reports {
                print("第 \(r.page) 页：\(r.streams) 个内容流 / \(r.bytes) 字节")
                print("  文本显示算子 \(r.textShowingOperators)  BT 块 \(r.textBlocks)  内联图像 \(r.inlineImages)")
                let ops = r.topOperators.sorted { $0.value > $1.value }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
                print("  算子  \(ops)")
                print("")
            }
        }
    }

    // MARK: pdf-evict

    static func pdfEvict(_ args: [String]) throws {
        let input = requirePath(args, at: 1, label: "输入 PDF")
        let output = requirePath(args, at: 2, label: "输出 PDF")
        let document = openDocument(input)
        if document.isEncrypted {
            fputs("拒绝：文档已加密（本版本不处理 /Encrypt）\n", stderr)
            exit(4)
        }

        var pageIndices: [Int]? = nil
        if let raw = Int(option(args, "--page", "")), raw > 0 {
            pageIndices = [raw - 1]
        }

        let (data, report) = try PDFEvictor.evictText(document: document, pageIndices: pageIndices)
        try data.write(to: URL(fileURLWithPath: output))

        struct EvictReport: Encodable {
            var input: String
            var output: String
            var inputBytes: Int
            var outputBytes: Int
            var changedObjects: Int
            var removedRuns: Int
            var formStreams: Int
            var formsSkipped: Int
            var sharedForms: Int
            var clonedForms: Int
            var pages: [PageLine]
        }
        struct PageLine: Encodable {
            var page: Int
            var streams: Int
            var formStreams: Int
            var removedRuns: Int
            var bytesBefore: Int
            var bytesAfter: Int
            var formsSkipped: Int
            var sharedFormsCloned: Int
            var note: String
        }
        let payload = EvictReport(
            input: input, output: output,
            inputBytes: report.inputBytes, outputBytes: report.outputBytes,
            changedObjects: report.changedObjects,
            removedRuns: report.totalRemovedRuns,
            formStreams: report.totalFormStreams,
            formsSkipped: report.totalFormsSkipped,
            sharedForms: report.sharedForms,
            clonedForms: report.clonedForms,
            pages: report.pages.map {
                PageLine(page: $0.pageNumber, streams: $0.streams, formStreams: $0.formStreams,
                         removedRuns: $0.removedRuns,
                         bytesBefore: $0.bytesBefore, bytesAfter: $0.bytesAfter,
                         formsSkipped: $0.formsSkipped,
                         sharedFormsCloned: $0.sharedFormsCloned, note: $0.note)
            })

        if args.contains("--json") {
            jsonLine(payload)
        } else {
            print("输入  \(report.inputBytes) 字节")
            print("输出  \(report.outputBytes) 字节（增量写入 \(deltaText(report.outputBytes - report.inputBytes))）")
            print("改写对象 \(report.changedObjects) 个，删除文本算子段 \(report.totalRemovedRuns) 处")
            print("Form XObject  递归处理 \(report.totalFormStreams) 个"
                  + (report.totalFormsSkipped > 0 ? "，跳过 \(report.totalFormsSkipped) 个" : ""))
            if report.clonedForms > 0 {
                print("共享 Form  \(report.sharedForms) 个被多页共用，本次深拷贝 \(report.clonedForms) 个（原对象未改动）")
            }
            if report.changedObjects == 0 {
                print("⚠️ 未找到文本显示算子。可能原因：")
                print("   ① 整页是扫描图，本就没有文字层")
                print("   ② 文字已被转成曲线（CAD/设计稿常见），无法按文本处理")
            }
            for p in report.pages.prefix(20) where p.removedRuns > 0 || !p.note.isEmpty {
                print("  第 \(p.pageNumber) 页：删 \(p.removedRuns) 处"
                      + (p.formStreams > 0 ? "（含 Form \(p.formStreams) 个）" : "")
                      + "，\(p.bytesBefore) → \(p.bytesAfter) 字节"
                      + (p.note.isEmpty ? "" : "　\(p.note)"))
            }
        }
    }

    static func deltaText(_ delta: Int) -> String {
        delta == 0 ? "±0" : (delta > 0 ? "+\(delta)" : "\(delta)")
    }

    // MARK: pdf-stamp

    /// 定位字体文件：显式路径 > 环境变量 > 工作目录 Resources/Fonts > 可执行文件同级。
    static func findFontFile(_ explicit: String?, bold: Bool) -> String? {
        let name = bold ? "LinguaNovaSong-Bold.ttf" : "LinguaNovaSong-Regular.ttf"
        var candidates: [String] = []
        if let explicit { candidates.append(explicit) }
        if let env = ProcessInfo.processInfo.environment["HYMN_FONT_PATH"] { candidates.append(env) }
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append("\(cwd)/Resources/Fonts/\(name)")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/\(name)").path)
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func pdfStamp(_ args: [String]) throws {
        let input = requirePath(args, at: 1, label: "输入 PDF")
        let output = requirePath(args, at: 2, label: "输出 PDF")
        let text = option(args, "--text", "")
        guard !text.isEmpty else {
            fputs("缺少 --text \"要画的文字\"\n", stderr)
            exit(2)
        }
        let document = openDocument(input)
        if document.isEncrypted {
            fputs("拒绝：文档已加密（本版本不处理 /Encrypt）\n", stderr)
            exit(4)
        }

        let bold = args.contains("--bold")
        let explicitFont = option(args, "--font", "")
        guard let fontPath = findFontFile(explicitFont.isEmpty ? nil : explicitFont, bold: bold) else {
            fputs("找不到字体文件（LinguaNovaSong-*.ttf）。\n"
                  + "先用 Scripts/make-fonts.py 生成，或用 --font 指定路径。\n", stderr)
            exit(2)
        }

        let font: TrueTypeFont
        do {
            font = try TrueTypeFont(url: URL(fileURLWithPath: fontPath))
        } catch {
            fputs("字体解析失败：\(error)\n", stderr)
            exit(3)
        }

        let pageNumber = Int(option(args, "--page", "")) ?? 1
        let fontSize = Double(option(args, "--size", "")) ?? 14
        var origin: (x: Double, y: Double)?
        if let x = Double(option(args, "--x", "")), let y = Double(option(args, "--y", "")) {
            origin = (x, y)
        }

        let outcome: PDFStamper.Outcome
        do {
            outcome = try PDFStamper.stamp(
                document: document, pageIndex: pageNumber - 1, text: text,
                font: font, fontSize: fontSize, origin: origin,
                evictForms: !args.contains("--keep-forms"))
        } catch {
            fputs("插字失败：\(error)\n", stderr)
            exit(3)
        }
        try outcome.output.write(to: URL(fileURLWithPath: output))

        struct StampReport: Encodable {
            var input: String
            var output: String
            var page: Int
            var text: String
            var fontFile: String
            var fontFamily: String
            var subsetName: String
            var subsetGlyphs: Int
            var subsetBytes: Int
            var removedRuns: Int
            var formStreams: Int
            var cids: Int
            var missingScalars: [UInt32]
            var originX: Double
            var originY: Double
            var fontSize: Double
            var newObjects: Int
            var inputBytes: Int
            var outputBytes: Int
        }
        let report = StampReport(
            input: input, output: output, page: outcome.pageNumber, text: text,
            fontFile: fontPath, fontFamily: font.familyName,
            subsetName: outcome.subsetName, subsetGlyphs: outcome.subsetGlyphs,
            subsetBytes: outcome.subsetBytes, removedRuns: outcome.removedRuns,
            formStreams: outcome.formStreams, cids: outcome.cidCount,
            missingScalars: outcome.missingScalars,
            originX: outcome.origin.x, originY: outcome.origin.y,
            fontSize: outcome.fontSize, newObjects: outcome.newObjectCount,
            inputBytes: document.data.count, outputBytes: outcome.output.count)

        if args.contains("--json") {
            jsonLine(report)
        } else {
            print("第 \(outcome.pageNumber) 页  删除文本算子段 \(outcome.removedRuns) 处"
                  + (outcome.formStreams > 0 ? "（Form \(outcome.formStreams) 个）" : ""))
            print("字体  \(font.familyName) → 子集 \(outcome.subsetName)")
            print("      \(outcome.subsetGlyphs) 字形 / \(outcome.subsetBytes) 字节")
            print("文本  \(outcome.cidCount) 个 CID，基线原点 "
                  + "(\(String(format: "%.1f", outcome.origin.x)), "
                  + "\(String(format: "%.1f", outcome.origin.y)))，字号 \(outcome.fontSize)")
            if !outcome.missingScalars.isEmpty {
                let list = outcome.missingScalars.prefix(8)
                    .map { String(format: "U+%04X", $0) }.joined(separator: " ")
                print("⚠️ 缺字 \(outcome.missingScalars.count) 个：\(list)")
            }
            print("新增对象 \(outcome.newObjectCount) 个，"
                  + "输出 \(document.data.count) → \(outcome.output.count) 字节"
                  + "（\(deltaText(outcome.output.count - document.data.count))）")
        }
    }

    // MARK: pdf-verify

    /// 逐对象比对：除了显式改写的对象，其余必须逐字节等价。
    /// 这是「图片/矢量保真」的机器可判定形式——不靠眼看，靠对象相等。
    struct VerifyReport: Encodable {
        var pageCountBefore: Int
        var pageCountAfter: Int
        var objectsCompared: Int
        var changedObjects: [Int]
        var imageObjects: Int
        var imageHashesIdentical: Bool
        var imageHashMismatch: [Int]
        var verdict: String
    }

    static func pdfVerify(_ args: [String]) throws {
        let beforePath = requirePath(args, at: 1, label: "原文件")
        let afterPath = requirePath(args, at: 2, label: "处理后文件")
        let before = openDocument(beforePath)
        let after = openDocument(afterPath)

        var compared = 0
        var changed: [Int] = []
        var imageNumbers: [Int] = []
        var mismatchedImages: [Int] = []
        var hashesBefore: [Int: String] = [:]

        for number in before.objectNumbers {
            compared += 1
            let a = (try? before.resolve(PDFRef(number, 0))) ?? .null
            let b = (try? after.resolve(PDFRef(number, 0))) ?? .null
            if a != b { changed.append(number) }

            if let stream = a.streamValue,
               stream.dictionary["Subtype"]?.nameValue == "Image" {
                imageNumbers.append(number)
                hashesBefore[number] = sha256(stream.raw)
                let afterHash = b.streamValue.map { sha256($0.raw) }
                if hashesBefore[number] != afterHash { mismatchedImages.append(number) }
            }
        }

        let pagesOK = before.pageCount == after.pageCount
        let imagesOK = mismatchedImages.isEmpty
        let report = VerifyReport(
            pageCountBefore: before.pageCount,
            pageCountAfter: after.pageCount,
            objectsCompared: compared,
            changedObjects: changed,
            imageObjects: imageNumbers.count,
            imageHashesIdentical: imagesOK,
            imageHashMismatch: mismatchedImages,
            verdict: pagesOK && imagesOK ? "PASS" : "FAIL")

        if args.contains("--json") {
            jsonLine(report)
        } else {
            print("页数      \(report.pageCountBefore) → \(report.pageCountAfter)"
                  + (pagesOK ? "  ✓" : "  ✗"))
            print("比对对象  \(report.objectsCompared) 个，其中 \(report.changedObjects.count) 个被改写")
            if !report.changedObjects.isEmpty {
                let head = report.changedObjects.prefix(8).map(String.init).joined(separator: ", ")
                let more = report.changedObjects.count > 8
                    ? " …（共 \(report.changedObjects.count) 个）" : ""
                print("改写对象  \(head)\(more)")
            }
            print("图片对象  \(report.imageObjects) 个，"
                  + (imagesOK ? "原始字节逐一相同 ✓" : "有 \(report.imageHashMismatch.count) 个不一致 ✗"))
            print(report.verdict == "PASS"
                  ? "VERIFY_PASS 非文本对象未被改动，页数一致。"
                  : "VERIFY_FAIL 存在非预期差异，需排查。")
        }
        if report.verdict != "PASS" { exit(5) }
    }

    static func sha256(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - pdf-structure（P2：读结构）

extension HymnCtl {
    /// 结构提取：文本行 → 段落块 → 表格/插图，输出 IL JSON。
    static func pdfStructure(_ args: [String]) throws {
        let input = requirePath(args, at: 1, label: "输入 PDF")
        let document = openDocument(input)
        if document.isEncrypted {
            fputs("拒绝：文档已加密（本版本不处理 /Encrypt）\n", stderr)
            exit(4)
        }

        var options = PDFStructureBuilder.Options()
        options.detectTables = !args.contains("--no-tables")
        if let snap = Double(option(args, "--snap", "")) { options.table.snap = snap }

        var pageIndices: [Int]? = nil
        if let raw = Int(option(args, "--page", "")), raw > 0 {
            pageIndices = [raw - 1]
        }

        let started = Date()
        let il = PDFStructureBuilder.build(document: document, pageIndices: pageIndices, options: options)
        let elapsed = Date().timeIntervalSince(started)

        // 诊断：把原始文本 run 打成表。行/块对不上时，先看 run 到底有没有被读出来。
        if args.contains("--runs") {
            let entries = document.pageEntries()
            for index in pageIndices ?? Array(0..<document.pageCount) {
                print("# 第 \(index + 1) 页 内容流：")
                var merged = Data()
                for ref in document.contentRefs(of: entries[index].dict) {
                    let stream = (try? document.resolve(ref))?.streamValue
                    let decoded = stream.flatMap {
                        try? PDFFilters.decode($0.raw, dictionary: $0.dictionary)
                    }
                    let filter = stream?.dictionary["Filter"].map { "\($0)" } ?? "无"
                    print("  \(ref) raw=\(stream?.raw.count ?? -1) decoded=\(decoded?.count ?? -1) filter=\(filter)")
                    if let decoded {
                        merged.append(decoded)
                        if decoded.last != 0x0A, decoded.last != 0x0D { merged.append(0x0A) }
                    }
                }
                let dumpPath = option(args, "--dump-content", "")
                if !dumpPath.isEmpty {
                    let target = document.pageCount == 1
                        ? dumpPath
                        : dumpPath.replacingOccurrences(of: ".txt", with: "-p\(index + 1).txt")
                    try merged.write(to: URL(fileURLWithPath: target))
                    print("  已写出 \(target)（\(merged.count) 字节）")
                }
                let content = PDFTextExtractor.extract(
                    document: document, pageIndex: index, page: entries[index].dict)
                print("# 第 \(index + 1) 页  runs=\(content.runs.count)  unmapped=\(content.unmappedGlyphs)"
                      + "  unreadable=\(content.unreadableTextOps)")
                for run in content.runs.sorted(by: { $0.origin.y > $1.origin.y }) {
                    let range = run.sourceRange.map { "\($0.lowerBound)..\($0.upperBound)" } ?? "nil"
                    print(String(format: "y=%7.2f x=%7.2f..%7.2f  %-22@ %5.1f  a=%6.2f  r=%@  %@",
                                 run.origin.y, run.bbox.x0, run.bbox.x1,
                                 run.fontName as NSString, run.fontSize, run.advance,
                                 range as NSString, run.text as NSString))
                }
                print("")
            }
            return
        }

        var export = ILJSON.ExportOptions()
        export.includeLines = !args.contains("--no-lines")
        export.includeSpans = args.contains("--spans")
        export.pretty = !args.contains("--minified")
        let json = ILJSON.encode(il, options: export)

        let outPath = option(args, "--out", "")
        if !outPath.isEmpty {
            try json.write(to: URL(fileURLWithPath: outPath))
        }

        // 调试叠加图：块框（红）、表格（蓝）、插图（绿）画到渲染图上
        let overlayPath = option(args, "--overlay", "")
        if !overlayPath.isEmpty {
            for page in il.pages {
                var boxes: [PDFOverlay.Box] = []
                for block in page.blocks {
                    boxes.append(.init(rect: block.box, color: (0.9, 0.1, 0.1), label: block.id))
                }
                for table in page.tables {
                    boxes.append(.init(rect: table.box, color: (0.1, 0.3, 0.9), label: table.id))
                }
                for figure in page.figures {
                    boxes.append(.init(rect: figure.box, color: (0.9, 0.55, 0.1), label: figure.id))
                }
                // 矢量图表区域（绿）：区域内的文字按新规则保持原文
                for chart in page.charts {
                    boxes.append(.init(rect: chart.box, color: (0.1, 0.7, 0.2), label: chart.id))
                }
                let target = il.pages.count == 1
                    ? overlayPath
                    : overlayPath.replacingOccurrences(
                        of: ".png", with: "-p\(page.index + 1).png")
                try PDFOverlay.write(pdf: input, page: page.index + 1, boxes: boxes, to: target)
                print("叠加图  \(target)（\(page.blocks.count) 块）")
            }
        }

        let blockCount = il.pages.reduce(0) { $0 + $1.blocks.count }
        let lineCount = il.pages.reduce(0) { sum, page in
            sum + page.blocks.reduce(0) { $0 + $1.lines.count }
        }
        let tableCount = il.pages.reduce(0) { $0 + $1.tables.count }
        let figureCount = il.pages.reduce(0) { $0 + $1.figures.count }
        let chartCount = il.pages.reduce(0) { $0 + $1.charts.count }
        let untranslatable = il.pages.filter { !$0.translatable }.map { $0.index + 1 }

        if args.contains("--json") && outPath.isEmpty {
            print(String(decoding: json, as: UTF8.self))
            return
        }

        print("文件      \(URL(fileURLWithPath: input).lastPathComponent)")
        print("页数      \(il.pages.count)   耗时 \(String(format: "%.0f", elapsed * 1000)) ms")
        print("结构      \(blockCount) 块 / \(lineCount) 行 / \(tableCount) 表 / \(figureCount) 图"
              + " / \(chartCount) 图表区")
        if !untranslatable.isEmpty {
            print("⚠️ 不可译页  \(untranslatable.prefix(12).map(String.init).joined(separator: ","))"
                  + (untranslatable.count > 12 ? " …（共 \(untranslatable.count) 页）" : ""))
        }
        print("")
        print("页   块   行   表(行×列)   图   字号        首块文本")
        for page in il.pages.prefix(30) {
            let lines = page.blocks.reduce(0) { $0 + $1.lines.count }
            let tableDesc = page.tables.map { "\($0.rowCount)×\($0.columnCount)" }
                .joined(separator: ",")
            let sizes = Set(page.blocks.map { String(format: "%.0f", $0.fontSize) }).sorted()
            let preview = page.blocks.first?.text.prefix(24) ?? ""
            print(String(format: "%3d %4d %4d   %-9@  %3d   %-10@  %@",
                         page.index + 1, page.blocks.count, lines,
                         (tableDesc.isEmpty ? "-" : tableDesc) as NSString,
                         page.figures.count,
                         (sizes.prefix(3).joined(separator: "/")) as NSString,
                         String(preview)))
        }
        if il.pages.count > 30 { print("… 其余 \(il.pages.count - 30) 页省略") }

        let warnings = il.pages.flatMap { page in page.warnings.map { "第\(page.index + 1)页 \($0)" } }
        if !warnings.isEmpty {
            print("")
            print("警告 \(warnings.count) 条：")
            for line in Array(Set(warnings)).sorted().prefix(8) { print("  \(line)") }
        }
        if !outPath.isEmpty {
            print("")
            print("已写 \(outPath)（\(json.count) 字节）")
        }
    }
}

// MARK: - pdf-typeset（P3：把译文排回版式）

extension HymnCtl {
    /// 读结构 → 排译文 → 驱逐原文 → 写回。
    ///
    /// `--translations` 给的是 `blockID → 译文` 的 JSON（也支持 `pages[].blocks` 形态）。
    /// 没给译文的块会**重画原文**——因为驱逐是整页级的，跳过不画会留下空白。
    static func pdfTypeset(_ args: [String]) throws {
        let input = requirePath(args, at: 1, label: "输入 PDF")
        guard args.count > 2 else {
            fputs("缺少输出路径\n", stderr)
            exit(2)
        }
        let output = args[2]
        let document = openDocument(input)
        if document.isEncrypted {
            fputs("拒绝：文档已加密（本版本不处理 /Encrypt）\n", stderr)
            exit(4)
        }

        // 字体
        let regularExplicit = option(args, "--font-regular", "")
        guard let regularPath = findFontFile(regularExplicit.isEmpty ? nil : regularExplicit, bold: false) else {
            fputs("找不到正文字体（Resources/Fonts/LinguaNovaSong-Regular.ttf）\n", stderr)
            exit(2)
        }
        let regular: TrueTypeFont
        do {
            regular = try TrueTypeFont(url: URL(fileURLWithPath: regularPath))
        } catch {
            fputs("正文字体加载失败：\(error)\n", stderr)
            exit(3)
        }
        var bold: TrueTypeFont?
        let boldExplicit = option(args, "--font-bold", "")
        if let boldPath = findFontFile(boldExplicit.isEmpty ? nil : boldExplicit, bold: true),
           let font = try? TrueTypeFont(url: URL(fileURLWithPath: boldPath)) {
            bold = font
        }

        // 译文
        var request = PDFTypesetEngine.Request()
        let mapPath = option(args, "--translations", "")
        if !mapPath.isEmpty {
            do {
                request.translations = try PDFPlaceholder.TranslationMap.load(
                    from: URL(fileURLWithPath: mapPath))
            } catch {
                fputs("译文映射读取失败：\(error)\n", stderr)
                exit(3)
            }
        }
        if args.contains("--pseudo") {
            request.translations = PDFPlaceholder.TranslationMap(
                entries: pseudoTranslations(document: document))
        }
        request.typesetTables = !args.contains("--no-tables")
        request.scrub = args.contains("--scrub")
        request.typesetOrphanRuns = !args.contains("--no-orphans")
        if let margin = Double(option(args, "--margin", "")), margin > 0 {
            request.pageMargin = margin
        }

        var pageIndices: [Int]?
        if let raw = Int(option(args, "--page", "")), raw > 0 { pageIndices = [raw - 1] }

        let started = Date()
        let result: (output: Data, report: PDFTypesetEngine.Report)
        do {
            result = try PDFTypesetEngine.run(
                document: document,
                faces: PDFTypesetEngine.FaceSet(regular: regular, bold: bold),
                pageIndices: pageIndices, request: request)
        } catch {
            fputs("排版失败：\(error)\n", stderr)
            exit(5)
        }
        let elapsed = Date().timeIntervalSince(started)
        try result.output.write(to: URL(fileURLWithPath: output))

        let reportPath = option(args, "--report", "")
        if !reportPath.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result.report) {
                try data.write(to: URL(fileURLWithPath: reportPath))
            }
        }
        if args.contains("--json") {
            jsonLine(result.report)
            return
        }

        let report = result.report
        print("输入      \(report.inputBytes) 字节")
        print("输出      \(report.outputBytes) 字节（+\(report.outputBytes - report.inputBytes)）")
        print("耗时      \(String(format: "%.0f", elapsed * 1000)) ms")
        print("字体      \(report.embeddedFonts.joined(separator: "、"))")
        print("块        \(report.totalBlocks)，已译 \(report.totalTranslated)，保留原文 \(report.totalKeptOriginal)")
        print("溢出      \(report.totalOverflowLines) 行")
        if !report.reflowPages.isEmpty {
            print("整页重排  第 \(report.reflowPages.map(String.init).joined(separator: ",")) 页")
        }
        if !report.skippedPages.isEmpty {
            print("跳过      第 \(report.skippedPages.map(String.init).joined(separator: ",")) 页（不可译/无内容）")
        }
        if !report.missingScalars.isEmpty {
            print("缺字      \(report.missingScalars.count) 个：\(report.missingScalars.prefix(10).map { String(format: "U+%04X", $0) }.joined(separator: " "))")
        }
        print("")
        print("页  块  译  原文  适配 缩 扩  行注 页注 溢出  重排  备注")
        for page in report.pages.prefix(40) {
            var note = page.note
            if page.placeholderRejected > 0 { note += " 占位符拒译 \(page.placeholderRejected)" }
            if page.cells > 0 { note += " 单元格 \(page.cells)" }
            if page.orphanRuns > 0 { note += " 孤立run \(page.orphanRuns)" }
            if page.pinnedNearTable > 0 { note += " 表邻接块 \(page.pinnedNearTable)" }
            if page.pinnedCode > 0 { note += " 代码块 \(page.pinnedCode)" }
            if page.overlaps > 0 { note += " 相交 \(page.overlaps) \(page.overlapPairs.joined(separator: ","))" }
            if page.needsReview { note += " ⚠️" }
            print(String(format: "%3d %3d %3d %4d %4d %2d %2d %4d %4d %4d  %@  %@",
                         page.page, page.blocks, page.translated, page.keptOriginal,
                         page.fit, page.shrink, page.expand,
                         page.inlineNotes, page.pageNotes, page.overflowLines,
                         (page.reflow ? "是" : "-") as NSString,
                         note as NSString))
        }
        if report.pages.count > 40 { print("… 其余 \(report.pages.count - 40) 页省略") }
        for warning in report.warnings { print("⚠️ \(warning)") }
        print("")
        print("已写 \(output)")
    }

    /// 伪译文：给每个块加中文前缀。用来在没有模型的情况下压测排版，**不是翻译结果**。
    static func pseudoTranslations(document: PDFDocument) -> [String: String] {
        var entries: [String: String] = [:]
        let il = PDFStructureBuilder.build(document: document)
        for page in il.pages {
            for block in page.blocks {
                entries["p\(page.index + 1)-\(block.id)"] = "【译文示例】" + block.text
            }
            for table in page.tables {
                for cell in table.cells where !cell.text.isEmpty {
                    entries["p\(page.index + 1)-\(table.id):\(cell.row):\(cell.column)"] = "【译】" + cell.text
                }
            }
        }
        return entries
    }
}

// MARK: - pdf-analyze（P4：渲染比对 + 段落级修复闭环）

extension HymnCtl {
    /// 排版 → 渲染 → R1–R7 分析 → 修复 → 再分析（≤`--rounds` 轮）。
    ///
    /// 与 `pdf-typeset` 的区别：`pdf-typeset` 只保证「排出来」，
    /// 这个命令还要证明「排对了」——用掩膜外像素差证明图片/矢量没被碰过，
    /// 并把修不好的地方连页码、块号、坐标一起列出来。
    static func pdfAnalyze(_ args: [String]) throws {
        let input = requirePath(args, at: 1, label: "输入 PDF")
        guard args.count > 2 else {
            fputs("缺少输出路径\n", stderr)
            exit(2)
        }
        let output = args[2]
        let document = openDocument(input)
        if document.isEncrypted {
            fputs("拒绝：文档已加密（本版本不处理 /Encrypt）\n", stderr)
            exit(4)
        }

        // 字体
        let regularExplicit = option(args, "--font-regular", "")
        guard let regularPath = findFontFile(regularExplicit.isEmpty ? nil : regularExplicit, bold: false) else {
            fputs("找不到正文字体（Resources/Fonts/LinguaNovaSong-Regular.ttf）\n", stderr)
            exit(2)
        }
        let regular: TrueTypeFont
        do {
            regular = try TrueTypeFont(url: URL(fileURLWithPath: regularPath))
        } catch {
            fputs("正文字体加载失败：\(error)\n", stderr)
            exit(3)
        }
        var bold: TrueTypeFont?
        let boldExplicit = option(args, "--font-bold", "")
        if let boldPath = findFontFile(boldExplicit.isEmpty ? nil : boldExplicit, bold: true),
           let font = try? TrueTypeFont(url: URL(fileURLWithPath: boldPath)) {
            bold = font
        }

        // 译文
        var request = PDFTypesetEngine.Request()
        let mapPath = option(args, "--translations", "")
        if !mapPath.isEmpty {
            do {
                request.translations = try PDFPlaceholder.TranslationMap.load(
                    from: URL(fileURLWithPath: mapPath))
            } catch {
                fputs("译文映射读取失败：\(error)\n", stderr)
                exit(3)
            }
        }
        if args.contains("--pseudo") {
            request.translations = PDFPlaceholder.TranslationMap(
                entries: pseudoTranslations(document: document))
        }
        request.typesetTables = !args.contains("--no-tables")
        request.scrub = args.contains("--scrub")
        request.typesetOrphanRuns = !args.contains("--no-orphans")
        if let margin = Double(option(args, "--margin", "")), margin > 0 {
            request.pageMargin = margin
        }

        var pageIndices: [Int]?
        if let raw = Int(option(args, "--page", "")), raw > 0 { pageIndices = [raw - 1] }

        var options = PDFVerifyLoop.Options()
        if let rounds = Int(option(args, "--rounds", "")), rounds >= 0 { options.maxRounds = rounds }
        if let dpi = Double(option(args, "--dpi", "")), dpi >= 72 { options.analysis.dpi = dpi }
        if let limit = Int(option(args, "--max-pages", "")), limit > 0 {
            options.analysis.maxPages = limit
        }
        if let strideValue = Int(option(args, "--stride", "")), strideValue > 1 {
            options.analysis.pageStride = strideValue
        }
        if args.contains("--no-pixels") {
            options.analysis.checks.remove(.r1)
            options.analysis.checks.remove(.r6)
        }
        options.verifyPages = pageIndices

        let started = Date()
        let outcome: PDFVerifyLoop.Outcome
        do {
            outcome = try PDFVerifyLoop.run(
                document: document,
                faces: PDFTypesetEngine.FaceSet(regular: regular, bold: bold),
                pageIndices: pageIndices, request: request, options: options)
        } catch {
            fputs("闭环失败：\(error)\n", stderr)
            exit(5)
        }
        let elapsed = Date().timeIntervalSince(started)
        try outcome.output.write(to: URL(fileURLWithPath: output))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if args.contains("--dump-layout") {
            for (index, layout) in outcome.layouts.sorted(by: { $0.key < $1.key }) {
                print("布局 第 \(index + 1) 页  \(layout.items.count) 项  图 \(layout.figures.count)  被驱逐文本 \(layout.removedText.count)")
                for item in layout.items.prefix(6) {
                    print(String(format: "  %@ %@ box(%.1f,%.1f,%.1f,%.1f) fs %.1f tier %@",
                                 item.kind.rawValue, item.id as NSString,
                                 item.box.x0, item.box.y0, item.box.x1, item.box.y1,
                                 item.fontSize, item.tier as NSString))
                }
            }
        }

        let analysisPath = option(args, "--analysis", "")
        if !analysisPath.isEmpty {
            try encoder.encode(outcome.analysis).write(to: URL(fileURLWithPath: analysisPath))
        }

        if args.contains("--json") {
            jsonLine(outcome.analysis)
            return
        }

        let report = outcome.report
        let analysis = outcome.analysis
        print("输入      \(report.inputBytes) 字节")
        print("输出      \(report.outputBytes) 字节（+\(report.outputBytes - report.inputBytes)）")
        print("总耗时    \(String(format: "%.0f", elapsed * 1000)) ms（\(outcome.rounds.count) 轮）")
        print("字体      \(report.embeddedFonts.joined(separator: "、"))")
        print("块        \(report.totalBlocks)，已译 \(report.totalTranslated)，保留原文 \(report.totalKeptOriginal)")
        print("")
        for round in outcome.rounds {
            let status = round.passed ? "通过" : "未通过"
            print(String(format: "第 %d 轮  %@  检查 %d 页  错 %d  排版 %.0fms  分析 %.0fms  修复 %d 条",
                         round.round, status as NSString, round.checkedPages, round.errorCount,
                         round.typesetMS, round.analysisMS, round.actions.count))
            if !round.churnedPages.isEmpty {
                print("        内容流变化页：\(round.churnedPages.count) 页"
                      + (round.unexpectedPages.isEmpty ? "" : "（其中已通过页 \(round.unexpectedPages.map { $0 + 1 })，已重查）"))
            }
            for action in round.actions.prefix(8) {
                print("        · 第 \(action.page) 页 \(action.blockID ?? "-") \(action.action)：\(action.detail)")
            }
            if round.actions.count > 8 { print("        · 其余 \(round.actions.count - 8) 条省略") }
        }
        print("")
        print(String(format: "R1 非文本区  掩膜外差异 %@",
                     analysis.errorCount == 0 ? "全部 0 像素超差" as NSString
                        : "\(analysis.pages.reduce(0) { $0 + $1.diffPixels }) 像素超差" as NSString))
        print("R2 溢出      \(analysis.pages.reduce(0) { $0 + $1.overflowItems }) 处")
        print("R3 遮挡      \(analysis.pages.reduce(0) { $0 + $1.overlapPairs }) 对")
        print("R4 缺字      \(analysis.pages.reduce(0) { $0 + $1.missingGlyphs }) 个")
        print("R5 截断/占位 \(analysis.pages.reduce(0) { $0 + $1.truncatedItems }) / \(analysis.pages.reduce(0) { $0 + $1.placeholderIssues })")
        let layoutScores = analysis.pages.filter { $0.layoutSSIM > 0 }.map(\.layoutSSIM)
        print(String(format: "R6 版面 SSIM 均值 %.4f（最低 %.4f，%d 页）",
                     layoutScores.isEmpty ? 0 : layoutScores.reduce(0, +) / Double(layoutScores.count),
                     layoutScores.min() ?? 0, layoutScores.count))
        print("R7 阅读顺序  \(analysis.pages.reduce(0) { $0 + $1.inversions }) 对逆序")
        print("")
        print("结论      \(analysis.passed ? "全部通过" : "有 \(analysis.errorCount) 项错误 / \(analysis.failedPages.count) 页未通过")")
        if !outcome.repairedPages.isEmpty {
            print("已修复    第 \(outcome.repairedPages.map(String.init).joined(separator: ",")) 页")
        }
        if !outcome.unresolvedPages.isEmpty {
            print("仍需复核  第 \(outcome.unresolvedPages.map(String.init).joined(separator: ",")) 页")
        }
        if !outcome.manualActions.isEmpty {
            print("人工处理  \(outcome.manualActions.count) 条")
            for action in outcome.manualActions.prefix(6) {
                print("        · 第 \(action.page) 页 \(action.blockID ?? "-")：\(action.detail)")
            }
        }
        print("")
        print("已写 \(output)")

        if !analysis.pages.isEmpty {
            print("")
            print("页  差异px  最大差  SSIM   版面  溢出 遮挡 缺字 截断 逆序")
            for page in analysis.pages.prefix(30) {
                print(String(format: "%3d %7d %5d  %.3f  %.3f %4d %4d %4d %4d %4d",
                             page.page, page.diffPixels, page.maxDelta, page.ssim,
                             page.layoutSSIM, page.overflowItems, page.overlapPairs,
                             page.missingGlyphs, page.truncatedItems, page.inversions))
            }
            if analysis.pages.count > 30 { print("… 其余 \(analysis.pages.count - 30) 页省略") }
        }
    }
}

// MARK: - pdf-diff（P4 诊断：两版 PDF 逐像素差，标出差异区域）

extension HymnCtl {
    /// 不做掩膜、直接比两张渲染图，并把差异像素标成品红输出 PNG。
    ///
    /// 用来回答「这一块到底哪来的差异」：是原文没删干净、译文没画上去，
    /// 还是图片/矢量真的被改了。R1 只告诉你「有差异」，这个命令告诉你在哪、长什么样。
    static func pdfDiff(_ args: [String]) throws {
        let a = requirePath(args, at: 1, label: "第一份 PDF")
        let b = requirePath(args, at: 2, label: "第二份 PDF")
        let page = Int(option(args, "--page", "1")) ?? 1
        let dpi = Double(option(args, "--dpi", "144")) ?? 144
        let options = PDFPageRenderer.Options(dpi: dpi)
        guard let left = PDFPageRenderer.render(data: try Data(contentsOf: URL(fileURLWithPath: a)),
                                               index: page - 1, options: options),
              let right = PDFPageRenderer.render(data: try Data(contentsOf: URL(fileURLWithPath: b)),
                                                index: page - 1, options: options)
        else {
            fputs("渲染失败\n", stderr)
            exit(5)
        }
        let diff = PDFSimilarity.diff(left, right, mask: nil, tolerance: 8)
        print("页        \(page)  \(left.width)×\(left.height) @\(Int(dpi))dpi")
        print("不同像素  \(diff.diffPixels) / \(diff.comparedPixels)"
              + String(format: "（%.4f%%）最大差 %d", diff.ratio * 100, diff.maxDelta))
        for region in diff.regions {
            print(String(format: "  区域 (%.1f,%.1f)-(%.1f,%.1f)  %d 像素",
                         region.x0, region.y0, region.x1, region.y1, region.pixels))
        }
        // 坐标探针：把给定页面矩形涂红，用来验证「矩形→像素」映射是否符合预期
        if let probe = option(args, "--probe", "") as String?, !probe.isEmpty {
            let nums = probe.split(separator: ",").compactMap { Double($0) }
            if nums.count == 4 {
                let rect = PDFRect(x0: nums[0], y0: nums[1], x1: nums[2], y1: nums[3])
                let mask = PDFPixelMask.build(image: left, rects: [rect], dilatePoints: 0)
                var marked = left
                marked.rgb.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<left.height {
                        for x in 0..<left.width where mask.contains(x: x, y: y) {
                            let i = (y * left.width + x) * 3
                            dst[i] = 255; dst[i + 1] = 0; dst[i + 2] = 0
                        }
                    }
                }
                let probePath = option(args, "--mark", "-")
                try PDFOverlay.writeImage(marked, to: probePath)
                print("探针      矩形 \(probe) 涂红 → \(probePath)")
                return
            }
        }

        let outPath = option(args, "--mark", "")
        if !outPath.isEmpty {
            var marked = left
            marked.rgb.withUnsafeMutableBufferPointer { dst in
                left.rgb.withUnsafeBufferPointer { pa in
                    right.rgb.withUnsafeBufferPointer { pb in
                        for i in stride(from: 0, to: dst.count, by: 3) {
                            let d = max(abs(Int(pa[i]) - Int(pb[i])),
                                        max(abs(Int(pa[i + 1]) - Int(pb[i + 1])),
                                            abs(Int(pa[i + 2]) - Int(pb[i + 2]))))
                            if d > 8 {
                                dst[i] = 255; dst[i + 1] = 0; dst[i + 2] = 255
                            }
                        }
                    }
                }
            }
            try PDFOverlay.writeImage(marked, to: outPath)
            print("标注图    \(outPath)")
        }
    }
}

// MARK: - pdf-report（P5：逐段对照报告）

extension HymnCtl {
    /// 版式重建 + 逐段对照报告。
    ///
    /// 单语同版式的成品里只有译文，原文已经不在 PDF 里了。这份报告把原文补回来，
    /// 并逐段标注处理结果（缩到几号字、扩了框、挪进页脚注、还是回落原文），
    /// 让校对的人能看出「哪一段没翻、哪一段被挤压」。
    static func pdfReport(_ args: [String]) throws {
        let input = requirePath(args, at: 1, label: "输入 PDF")
        guard args.count > 2 else {
            fputs("缺少输出路径（html 或 pdf）\n", stderr)
            exit(2)
        }
        let output = args[2]
        let document = openDocument(input)
        if document.isEncrypted {
            fputs("拒绝：文档已加密（本版本不处理 /Encrypt）\n", stderr)
            exit(4)
        }

        guard let regularPath = findFontFile(option(args, "--font-regular", "").isEmpty
                                            ? nil : option(args, "--font-regular", ""),
                                            bold: false),
              let regular = try? TrueTypeFont(url: URL(fileURLWithPath: regularPath)) else {
            fputs("找不到正文字体（Resources/Fonts/LinguaNovaSong-Regular.ttf）\n", stderr)
            exit(2)
        }
        var bold: TrueTypeFont?
        let boldExplicit = option(args, "--font-bold", "")
        if let boldPath = findFontFile(boldExplicit.isEmpty ? nil : boldExplicit, bold: true),
           let font = try? TrueTypeFont(url: URL(fileURLWithPath: boldPath)) {
            bold = font
        }

        var request = PDFTypesetEngine.Request()
        let mapPath = option(args, "--translations", "")
        if !mapPath.isEmpty {
            do {
                request.translations = try PDFPlaceholder.TranslationMap.load(
                    from: URL(fileURLWithPath: mapPath))
            } catch {
                fputs("译文映射读取失败：\(error)\n", stderr)
                exit(3)
            }
        }
        if args.contains("--pseudo") {
            request.translations = PDFPlaceholder.TranslationMap(
                entries: pseudoTranslations(document: document))
        }
        request.typesetTables = !args.contains("--no-tables")
        request.scrub = args.contains("--scrub")

        var pageIndices: [Int]?
        if let raw = Int(option(args, "--page", "")), raw > 0 { pageIndices = [raw - 1] }

        let started = Date()
        let detailed: PDFTypesetEngine.Detailed
        do {
            detailed = try PDFTypesetEngine.runDetailed(
                document: document, faces: PDFTypesetEngine.FaceSet(regular: regular, bold: bold),
                pageIndices: pageIndices, request: request)
        } catch {
            fputs("排版失败：\(error)\n", stderr)
            exit(5)
        }
        let elapsed = Date().timeIntervalSince(started)

        let sections = PDFComparisonReport.sections(
            layouts: detailed.layouts, report: detailed.report)
        var options = PDFComparisonReport.Options()
        options.documentName = (input as NSString).lastPathComponent
        if let limit = Int(option(args, "--max-pages", "")), limit > 0 { options.maxPages = limit }
        options.expandPages = args.contains("--expand")
        let html = PDFComparisonReport.html(
            sections: sections, report: detailed.report, options: options)
        try html.write(toFile: output, atomically: true, encoding: .utf8)

        let pdfPath = option(args, "--pdf", "")
        if !pdfPath.isEmpty {
            try detailed.output.write(to: URL(fileURLWithPath: pdfPath))
        }
        let jsonPath = option(args, "--json", "")
        if !jsonPath.isEmpty {
            try PDFComparisonReport.json(sections: sections)
                .write(to: URL(fileURLWithPath: jsonPath))
        }

        let blocks = sections.reduce(0) { $0 + $1.entries.count }
        print("页数      \(sections.count)，对照 \(blocks) 段")
        print("已译      \(detailed.report.pages.reduce(0) { $0 + $1.translated })   "
              + "保留原文 \(detailed.report.pages.reduce(0) { $0 + $1.keptOriginal })")
        print(String(format: "耗时      %.0f ms", elapsed * 1000))
        print("已写      \(output)")
    }
}
