import Foundation
import HymnCore

/// P1 测试集：Form XObject 递归驱逐、共享 form 深拷贝、字体子集化与嵌入。
///
/// 样本同样全部在内存里构造。字体是唯一的二进制依赖，用 `#filePath` 定位到
/// 仓库里的 `Resources/Fonts`，不依赖当前工作目录——换机器、换 CI 都一样。
public func pdfP1Suite() -> [TestResult] {
    var results: [TestResult] = []
    let suite = "pdf-p1"

    // MARK: - Form XObject 递归驱逐

    if let document = try? PDFDocument(data: PDFFixture.withForm()) {
        results.append(check(
            suite: suite, "form-detected",
            document.formXObjectRefs(of: document.pages()[0]).count == 1,
            detail: "页面资源里 1 个 Form"))

        let nodes = PDFFormGraph.reachableForms(
            document: document,
            resources: document.resolvedResources(document.pages()[0]["Resources"]))
        results.append(check(
            suite: suite, "form-reachable",
            nodes.count == 1 && nodes[0].ref.number == 6,
            detail: "\(nodes.map(\.ref.number))"))

        if let evicted = try? PDFEvictor.evictText(document: document) {
            let pageText = contentText(evicted.output)
            let formText = formContentText(evicted.output, formNumber: 6)
            results.append(check(
                suite: suite, "form-evict-page-text",
                !pageText.contains("PageText") && pageText.contains("/Fm1 Do"),
                detail: "页面文字已删，Do 算子保留"))
            results.append(check(
                suite: suite, "form-evict-form-text",
                !formText.contains("FormText"),
                detail: "Form 内文字已删（P0 漏掉的正是这一层）"))
            results.append(check(
                suite: suite, "form-evict-keeps-graphics",
                formText.contains("10 10 50 50 re f"),
                detail: "Form 内矢量图形保留"))
            results.append(check(
                suite: suite, "form-evict-report",
                evicted.report.totalFormStreams == 1 && evicted.report.totalRemovedRuns == 2,
                detail: "Form 1 个，删 2 段"))
        } else {
            results.append(check(suite: suite, "form-evict", false, detail: "驱逐失败"))
        }
    } else {
        results.append(check(suite: suite, "form-detected", false, detail: "样本解析失败"))
    }

    // MARK: - 嵌套 Form（Form 里还有 Form）

    if let document = try? PDFDocument(data: PDFFixture.withNestedForm()) {
        let nodes = PDFFormGraph.reachableForms(
            document: document,
            resources: document.resolvedResources(document.pages()[0]["Resources"]))
        results.append(check(
            suite: suite, "nested-form-reachable",
            nodes.count == 2,
            detail: "外层 + 内层共 \(nodes.count) 个"))

        if let evicted = try? PDFEvictor.evictText(document: document) {
            let outer = formContentText(evicted.output, formNumber: 6)
            let inner = formContentText(evicted.output, formNumber: 7)
            results.append(check(
                suite: suite, "nested-form-both-evicted",
                !outer.contains("OuterText") && !inner.contains("InnerText"),
                detail: "两层文字都删掉"))
        } else {
            results.append(check(suite: suite, "nested-form", false, detail: "驱逐失败"))
        }
    }

    // MARK: - 共享 Form：只改一页时必须深拷贝

    if let document = try? PDFDocument(data: PDFFixture.sharedForm()) {
        let usage = PDFFormGraph.usageByPage(document: document)
        results.append(check(
            suite: suite, "shared-form-usage",
            usage[6]?.count == 2,
            detail: "Form 6 被 \(usage[6]?.count ?? 0) 页引用"))

        let beforeForm = (try? document.resolve(PDFRef(6, 0)))?.streamValue.flatMap {
            try? PDFFilters.decode($0.raw, dictionary: $0.dictionary)
        }.map { String(decoding: $0, as: UTF8.self) } ?? ""

        if let evicted = try? PDFEvictor.evictText(document: document, pageIndices: [0]) {
            let after = try? PDFDocument(data: evicted.output)
            let page2Text = after.map { pageFormText($0, pageIndex: 1, name: "Fm1") } ?? ""
            results.append(check(
                suite: suite, "shared-form-cloned-not-mutated",
                page2Text.contains("SharedText"),
                detail: "未处理的第 2 页仍能读到原文"))

            let page1Text = after.map { pageFormText($0, pageIndex: 0, name: "Fm1") } ?? ""
            results.append(check(
                suite: suite, "shared-form-clone-evicted",
                !page1Text.contains("SharedText"),
                detail: "第 1 页的副本已删字"))

            let originalStillThere: String
            if let after {
                let stream = (try? after.resolve(PDFRef(6, 0)))?.streamValue
                let decoded = stream.flatMap {
                    try? PDFFilters.decode($0.raw, dictionary: $0.dictionary)
                }
                originalStillThere = decoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
            } else {
                originalStillThere = ""
            }
            results.append(check(
                suite: suite, "shared-form-original-untouched",
                originalStillThere.contains("SharedText") && beforeForm.contains("SharedText"),
                detail: "原对象 6 0 R 一个字节没动"))
            results.append(check(
                suite: suite, "shared-form-clone-count",
                evicted.report.clonedForms == 1 && evicted.report.sharedForms == 1,
                detail: "克隆 \(evicted.report.clonedForms) 个"))
        } else {
            results.append(check(suite: suite, "shared-form", false, detail: "驱逐失败"))
        }
    }

    // MARK: - 字体子集化

    guard let fontURL = fontURL("LinguaNovaSong-Regular.ttf"),
          let font = try? TrueTypeFont(url: fontURL) else {
        results.append(check(
            suite: suite, "font-load", false,
            detail: "找不到 Resources/Fonts/LinguaNovaSong-Regular.ttf（先跑 Scripts/make-fonts.py）"))
        return results
    }

    results.append(check(
        suite: suite, "font-load",
        font.unitsPerEm == 1000 && font.numGlyphs > 20000 && font.postScriptName == "LinguaNovaSong-Regular",
        detail: "\(font.numGlyphs) 字形 / upem \(font.unitsPerEm) / \(font.postScriptName)"))

    let cjkGID = font.glyphID(for: 0x4E2D)   // 中
    results.append(check(
        suite: suite, "font-cmap-cjk",
        cjkGID != nil,
        detail: "「中」→ GID \(cjkGID.map(String.init) ?? "nil")"))

    // 复合字形是子集化最容易出错的地方：重编号后组件必须同步改写，
    // 漏改只会让「个别字」显示成别的字，肉眼很难发现。
    //
    // 这里分两层测：
    //   ① 记录真实字体里有多少复合字形。`varLib.instancer` 在实例化时通常会把
    //      组件展开成简单轮廓，所以「0 个」是这个字体的正常状态，不是失败。
    //   ② 用合成的复合字形字节序列单独测重编号逻辑，不依赖字体里恰好有复合字形。
    var compositeCount = 0
    for codepoint in font.cmap.keys.sorted() {
        guard let gid = font.cmap[codepoint], gid > 0 else { continue }
        if !font.components(of: gid).isEmpty { compositeCount += 1 }
    }
    results.append(check(
        suite: suite, "font-composite-survey",
        true,
        detail: "\(compositeCount) 个复合字形（instancer 一般已扁平化）"))

    // 合成复合字形：2 个组件，flags 带 MORE_COMPONENTS 与 ARG_1_AND_2_ARE_WORDS
    var synthetic = Data()
    synthetic.append(contentsOf: [0xFF, 0xFF])   // numberOfContours = -1
    for _ in 0..<4 { synthetic.append(contentsOf: [0, 0]) }   // bbox
    synthetic.append(contentsOf: [0x00, 0x23])   // flags: words|xy|more
    synthetic.append(contentsOf: [0x00, 0x64])   // glyphIndex = 100
    synthetic.append(contentsOf: [0, 5, 0, 6])   // 两个 int16 参数
    synthetic.append(contentsOf: [0x00, 0x03])   // flags: words|xy
    synthetic.append(contentsOf: [0x00, 0xC8])   // glyphIndex = 200
    synthetic.append(contentsOf: [0, 7, 0, 8])
    let remapped = TrueTypeFont.remapComposite([UInt8](synthetic), map: [100: 3, 200: 4])
    results.append(check(
        suite: suite, "composite-remap-synthetic",
        remapped.count == synthetic.count
            && remapped[12] == 0 && remapped[13] == 3      // 第一个组件 100 → 3
            && remapped[20] == 0 && remapped[21] == 4      // 第二个组件 200 → 4
            && remapped[10] == 0x00 && remapped[11] == 0x23,   // flags 未动
        detail: "组件 100/200 → 3/4，flags 与参数保留"))

    if let subsetResult = try? font.subset(glyphs: Set([cjkGID ?? 1])) {
        results.append(check(
            suite: suite, "font-subset-size",
            subsetResult.data.count < font.data.count / 4,
            detail: "\(font.data.count) → \(subsetResult.data.count) 字节"))

        results.append(check(
            suite: suite, "font-subset-notdef",
            subsetResult.glyphMap[0] == 0,
            detail: ".notdef 固定为 0"))

        if let reparsed = try? TrueTypeFont(data: subsetResult.data) {
            results.append(check(
                suite: suite, "font-subset-reparse",
                reparsed.numGlyphs == subsetResult.glyphCount && reparsed.unitsPerEm == font.unitsPerEm,
                detail: "\(reparsed.numGlyphs) 字形可回读"))

            // 组件编号必须落在新范围内，否则说明复合字形没改写
            var maxComponent = 0
            for gid in 0..<reparsed.numGlyphs {
                for component in reparsed.components(of: gid) { maxComponent = max(maxComponent, component) }
            }
            results.append(check(
                suite: suite, "font-subset-composite-remap",
                maxComponent < reparsed.numGlyphs,
                detail: "组件最大 GID \(maxComponent) < \(reparsed.numGlyphs)"))

            let widthOK = reparsed.width1000(gid: subsetResult.glyphMap[cjkGID ?? 1] ?? 1) == font.width1000(gid: cjkGID ?? 1)
            results.append(check(
                suite: suite, "font-subset-width",
                widthOK,
                detail: "「中」字宽保持 \(font.width1000(gid: cjkGID ?? 1))"))

            // 字形轮廓必须逐字节搬过去：子集化的目的只是「少装几个字」，
            // 不许顺手改字形（重算 bbox、重新量化都会让字变形）。
            let newGID = subsetResult.glyphMap[cjkGID ?? 1] ?? 1
            let original = [UInt8](font.glyphData(gid: cjkGID ?? 1))
            let copied = [UInt8](reparsed.glyphData(gid: newGID))
            let trimmed = Array(copied.prefix(original.count))
            results.append(check(
                suite: suite, "font-subset-outline-preserved",
                !original.isEmpty && trimmed == original,
                detail: "「中」轮廓 \(original.count) 字节逐字节一致"))
        } else {
            results.append(check(suite: suite, "font-subset-reparse", false, detail: "子集回读失败"))
        }
    }

    // MARK: - 嵌入 + 插字（含图片字节不变）

    if let document = try? PDFDocument(data: PDFFixture.withImageAndForm()) {
        let imageBefore = (try? document.resolve(PDFRef(5, 0)))?.streamValue
        let outcome = try? PDFStamper.stamp(
            document: document, pageIndex: 0, text: "译文测试", font: font, fontSize: 14)
        results.append(check(
            suite: suite, "stamp-runs",
            outcome != nil,
            detail: outcome.map { "\($0.cidCount) 个 CID，子集 \($0.subsetBytes) 字节" } ?? "失败"))

        if let outcome, let after = try? PDFDocument(data: outcome.output) {
            results.append(check(
                suite: suite, "stamp-page-count",
                after.pageCount == document.pageCount,
                detail: "\(after.pageCount) 页"))

            let imageAfter = (try? after.resolve(PDFRef(5, 0)))?.streamValue
            results.append(check(
                suite: suite, "stamp-image-bytes-identical",
                imageBefore != nil && imageAfter != nil
                    && imageBefore!.raw == imageAfter!.raw
                    && imageBefore!.dictionary == imageAfter!.dictionary,
                detail: "图片流字节与字典完全一致"))

            let page = after.pages()[0]
            let resources = after.resolvedResources(page["Resources"])
            var fontDict: [String: PDFValue] = [:]
            if case .reference(let r)? = resources["Font"] {
                fontDict = (try? after.resolve(r))?.dictionaryValue ?? [:]
            } else {
                fontDict = resources["Font"]?.dictionaryValue ?? [:]
            }
            let type0 = fontDict["LNF1"].flatMap { value -> [String: PDFValue]? in
                if case .reference(let r) = value { return (try? after.resolve(r))?.dictionaryValue }
                return value.dictionaryValue
            }
            results.append(check(
                suite: suite, "stamp-font-type0",
                type0?["Subtype"]?.nameValue == "Type0"
                    && type0?["Encoding"]?.nameValue == "Identity-H",
                detail: "Type0 / Identity-H"))

            let descendantOK: Bool = {
                guard case .reference(let d)? = type0?["DescendantFonts"]?.arrayValue?.first else { return false }
                let dict = (try? after.resolve(d))?.dictionaryValue
                return dict?["Subtype"]?.nameValue == "CIDFontType2"
                    && dict?["CIDToGIDMap"]?.nameValue == "Identity"
            }()
            results.append(check(
                suite: suite, "stamp-font-cidfont",
                descendantOK,
                detail: "CIDFontType2 / CIDToGIDMap Identity"))

            let hasFontFile: Bool = {
                guard case .reference(let d)? = type0?["DescendantFonts"]?.arrayValue?.first,
                      let cid = (try? after.resolve(d))?.dictionaryValue,
                      case .reference(let fd)? = cid["FontDescriptor"],
                      let descriptor = (try? after.resolve(fd))?.dictionaryValue,
                      case .reference(let ff)? = descriptor["FontFile2"],
                      let stream = (try? after.resolve(ff))?.streamValue
                else { return false }
                // 解出来必须还能当字体读，否则嵌进去的是一堆乱码
                guard let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary),
                      let embedded = try? TrueTypeFont(data: decoded) else { return false }
                return embedded.postScriptName.contains("LinguaNovaSong")
            }()
            results.append(check(
                suite: suite, "stamp-fontfile-readable",
                hasFontFile,
                detail: "FontFile2 解压后是可解析的 TTF"))

            let toUnicodeOK: Bool = {
                guard case .reference(let tu)? = type0?["ToUnicode"],
                      let stream = (try? after.resolve(tu))?.streamValue,
                      let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
                else { return false }
                let text = String(decoding: decoded, as: UTF8.self)
                return text.contains("beginbfchar") && text.contains("endcmap")
            }()
            results.append(check(
                suite: suite, "stamp-tounicode",
                toUnicodeOK,
                detail: "ToUnicode CMap 存在且结构完整"))

            let contentText = ((try? after.contentData(of: after.pages()[0])) ?? [])
                .reduce("") { $0 + String(decoding: $1, as: UTF8.self) }
            results.append(check(
                suite: suite, "stamp-content-operators",
                contentText.contains("/LNF1 14 Tf") && contentText.contains(" Tj")
                    && contentText.contains("q\n") && !contentText.contains("PageText"),
                detail: "BT..ET 已追加，原文字已删"))
        }
    }

    return results
}

// MARK: - 辅助

private func fontURL(_ name: String) -> URL? {
    // #filePath 是编译期常量：Sources/hymntest/PDFP1Tests.swift → 仓库根
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // hymntest
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    let url = root.appendingPathComponent("Resources/Fonts/\(name)")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private func contentText(_ data: Data, pageIndex: Int = 0) -> String {
    guard let document = try? PDFDocument(data: data) else { return "" }
    let pages = document.pages()
    guard pageIndex < pages.count else { return "" }
    return ((try? document.contentData(of: pages[pageIndex])) ?? [])
        .reduce("") { $0 + String(decoding: $1, as: UTF8.self) }
}

private func formContentText(_ data: Data, formNumber: Int) -> String {
    guard let document = try? PDFDocument(data: data),
          let stream = (try? document.resolve(PDFRef(formNumber, 0)))?.streamValue,
          let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
    else { return "" }
    return String(decoding: decoded, as: UTF8.self)
}

/// 取某页资源里某个名字指向的 Form 的内容。
private func pageFormText(_ document: PDFDocument, pageIndex: Int, name: String) -> String {
    let pages = document.pages()
    guard pageIndex < pages.count else { return "" }
    let resources = document.resolvedResources(pages[pageIndex]["Resources"])
    let xobjects: [String: PDFValue]
    if case .reference(let xoRef)? = resources["XObject"] {
        xobjects = (try? document.resolve(xoRef))?.dictionaryValue ?? [:]
    } else {
        xobjects = resources["XObject"]?.dictionaryValue ?? [:]
    }
    guard case .reference(let formRef)? = xobjects[name],
          let stream = (try? document.resolve(formRef))?.streamValue,
          let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
    else { return "" }
    return String(decoding: decoded, as: UTF8.self)
}

// MARK: - 合成样本

enum PDFFixture {
    /// 页面内容流里有一句文本 + 一个 `Do`；Form 里另有文本和一条矩形。
    static func withForm() -> Data {
        assemble(objects: [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
            /Resources << /Font << /F1 5 0 R >> /XObject << /Fm1 6 0 R >> >> /Contents 4 0 R >>
            """),
            (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            (6, """
            << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
            /Resources << /Font << /F1 5 0 R >> >> /Length \(formWithText.count) >>
            """),
        ], streams: [
            4: Data("BT /F1 12 Tf 72 700 Td (PageText) Tj ET\nq /Fm1 Do Q\n0 0 30 30 re f\n".utf8),
            6: Data(formWithText.utf8),
        ])
    }

    /// Form 里套 Form：外层 Do 内层。
    static func withNestedForm() -> Data {
        assemble(objects: [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
            /Resources << /XObject << /Fm1 6 0 R >> >> /Contents 4 0 R >>
            """),
            (6, """
            << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
            /Resources << /XObject << /Fm2 7 0 R >> >> /Length \(outerText.count) >>
            """),
            (7, """
            << /Type /XObject /Subtype /Form /BBox [0 0 612 792] \
            /Length \(innerText.count) >>
            """),
        ], streams: [
            4: Data("q /Fm1 Do Q\n".utf8),
            6: Data(outerText.utf8),
            7: Data(innerText.utf8),
        ])
    }

    /// 两页共用一个 Form：只处理第 1 页时必须深拷贝。
    static func sharedForm() -> Data {
        let page = { (parent: Int, contents: Int) in """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
        /Resources << /XObject << /Fm1 6 0 R >> >> /Contents \(contents) 0 R >>
        """ }
        return assemble(objects: [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R 8 0 R] /Count 2 >>"),
            (3, page(2, 4)),
            (8, page(2, 9)),
            (6, """
            << /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Length \(sharedText.count) >>
            """),
        ], streams: [
            4: Data("q /Fm1 Do Q\n".utf8),
            9: Data("q /Fm1 Do Q\n".utf8),
            6: Data(sharedText.utf8),
        ])
    }

    /// 页面里有图片 XObject + Form：用来验证插入文字后图片字节完全不变。
    static func withImageAndForm() -> Data {
        // 2x2 RGB 图，12 字节原始数据
        let imageBytes = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0])
        return assemble(objects: [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
            /Resources << /XObject << /Im1 5 0 R /Fm1 6 0 R >> >> /Contents 4 0 R >>
            """),
            (5, """
            << /Type /XObject /Subtype /Image /Width 2 /Height 2 \
            /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(imageBytes.count) >>
            """),
            (6, """
            << /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Length \(formWithText.count) >>
            """),
        ], streams: [
            4: Data("q 40 0 0 40 100 100 cm /Im1 Do Q\nBT /F1 12 Tf 72 700 Td (PageText) Tj ET\nq /Fm1 Do Q\n".utf8),
            5: imageBytes,
            6: Data(formWithText.utf8),
        ])
    }

    static let formWithText = "BT /F1 10 Tf 72 600 Td (FormText) Tj ET\n10 10 50 50 re f\n"
    static let outerText = "BT /F1 10 Tf 72 600 Td (OuterText) Tj ET\nq /Fm2 Do Q\n"
    static let innerText = "BT /F1 10 Tf 72 500 Td (InnerText) Tj ET\n"
    static let sharedText = "BT /F1 10 Tf 72 600 Td (SharedText) Tj ET\n"

    /// 拼一份带经典 xref 表的 PDF。
    /// 只给 `streams` 而不在 `objects` 里列出的对象，自动补 `<< /Length n >>`。
    static func assemble(
        objects: [(number: Int, body: String)],
        streams: [Int: Data]
    ) -> Data {
        var bodies = Dictionary(uniqueKeysWithValues: objects.map { ($0.number, $0.body) })
        for (number, payload) in streams where bodies[number] == nil {
            bodies[number] = "<< /Length \(payload.count) >>"
        }
        let numbers = bodies.keys.sorted()
        let maxNumber = numbers.max() ?? 0

        var out = Data()
        out.append(Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8))
        var offsets: [Int: Int] = [:]

        for number in numbers {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n".utf8))
            if let payload = streams[number] {
                out.append(Data((bodies[number]! + "\nstream\n").utf8))
                out.append(payload)
                out.append(Data("\nendstream".utf8))
            } else {
                out.append(Data(bodies[number]!.utf8))
            }
            out.append(Data("\nendobj\n".utf8))
        }

        let xrefOffset = out.count
        out.append(Data("xref\n0 \(maxNumber + 1)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for number in 1...maxNumber {
            if let offset = offsets[number] {
                out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            } else {
                out.append(Data("0000000000 65535 f \n".utf8))
            }
        }
        out.append(Data("trailer\n<< /Size \(maxNumber + 1) /Root 1 0 R >>\n".utf8))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }
}
