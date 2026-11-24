import Foundation
import HymnCore

// MARK: - ZIP 读取（测试侧独立实现，不复用生产代码，避免自证）

private struct ZipProbeEntry {
    let name: String
    let payload: Data
    let storedCRC: UInt32
}

private func le16(_ data: Data, _ offset: Int) -> UInt16 {
    let base = data.startIndex + offset
    return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
}

private func le32(_ data: Data, _ offset: Int) -> UInt32 {
    let base = data.startIndex + offset
    return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
        | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
}

private func probeZIP(_ data: Data) -> (entries: [ZipProbeEntry], eocdOK: Bool) {
    guard data.count >= 22 else { return ([], false) }
    let eocd = data.count - 22
    guard le32(data, eocd) == 0x0605_4B50 else { return ([], false) }
    let count = Int(le16(data, eocd + 10))
    var cursor = Int(le32(data, eocd + 16))
    var entries: [ZipProbeEntry] = []
    for _ in 0..<count {
        guard cursor + 46 <= data.count, le32(data, cursor) == 0x0201_4B50 else { break }
        let crc = le32(data, cursor + 16)
        let size = Int(le32(data, cursor + 24))
        let nameLen = Int(le16(data, cursor + 28))
        let extraLen = Int(le16(data, cursor + 30))
        let commentLen = Int(le16(data, cursor + 32))
        let localOffset = Int(le32(data, cursor + 42))
        let nameStart = cursor + 46
        guard nameStart + nameLen <= data.count,
              let name = String(bytes: data[nameStart..<(nameStart + nameLen)], encoding: .utf8),
              localOffset + 30 <= data.count,
              le32(data, localOffset) == 0x0403_4B50 else { break }
        let localNameLen = Int(le16(data, localOffset + 26))
        let localExtraLen = Int(le16(data, localOffset + 28))
        let payloadStart = localOffset + 30 + localNameLen + localExtraLen
        guard payloadStart + size <= data.count else { break }
        entries.append(ZipProbeEntry(
            name: name,
            payload: Data(data[payloadStart..<(payloadStart + size)]),
            storedCRC: crc))
        cursor = nameStart + nameLen + extraLen + commentLen
    }
    return (entries, entries.count == count)
}

/// 文档写出（TXT / OOXML DOCX）与 14 语言目录的独立测试。
func documentWriterSuite() -> [TestResult] {
    let suite = "document-export"
    var out: [TestResult] = []
    let sample = TranslationDocument(
        title: "TransOra 译文",
        subtitle: "本机离线 · 不上传",
        items: [
            .init(heading: "第 1 条 · en → zh",
                  source: "Hello & <world> \"quotes\"",
                  translation: "你好，世界 🌍\n第二行", note: "记录 #1"),
            .init(heading: "第 2 条",
                  source: "Line A", translation: "甲行", note: ""),
        ])

    let txt = TranslationDocumentWriter.txtData(sample)
    let txtString = String(decoding: txt, as: UTF8.self)
    out.append(check(suite: suite, "TXT 含标题、原文、译文与多记录顺序",
                     txtString.contains("TransOra 译文")
                        && txtString.contains("Hello & <world>")
                        && txtString.contains("你好，世界 🌍")
                        && txtString.contains("甲行")
                        && txtString.range(of: "Hello &")!.lowerBound
                            < txtString.range(of: "Line A")!.lowerBound,
                     detail: "bytes=\(txt.count)"))

    out.append(check(suite: suite, "CRC32 通过标准校验向量 123456789",
                     TranslationDocumentWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926))

    let docx: Data
    do {
        docx = try TranslationDocumentWriter.docxData(sample)
    } catch {
        out.append(check(suite: suite, "DOCX 生成不抛错", false, detail: "\(error)"))
        return out
    }
    let probe = probeZIP(docx)
    let names = Set(probe.entries.map(\.name))
    out.append(check(suite: suite, "DOCX 是完整 ZIP（EOCD + 4 个 OOXML 部件）",
                     probe.eocdOK && probe.entries.count == 4
                        && names.contains("[Content_Types].xml")
                        && names.contains("_rels/.rels")
                        && names.contains("word/document.xml")
                        && names.contains("word/_rels/document.xml.rels"),
                     detail: "parts=\(probe.entries.count) names=\(names.sorted().joined(separator: ","))"))

    out.append(check(suite: suite, "ZIP 每个部件的 CRC 与实际数据一致",
                     probe.entries.allSatisfy {
                         TranslationDocumentWriter.crc32($0.payload) == $0.storedCRC
                     }))

    let documentPart = probe.entries.first { $0.name == "word/document.xml" }?.payload
    let xml = documentPart.map { String(decoding: $0, as: UTF8.self) } ?? ""
    out.append(check(suite: suite, "document.xml 转义 XML 特殊字符并保留中文/emoji",
                     xml.contains("Hello &amp; &lt;world&gt; &quot;quotes&quot;")
                        && xml.contains("你好，世界 🌍")
                        && !xml.contains("<world>")))
    out.append(check(suite: suite, "document.xml 声明 OOXML 命名空间与正文结构",
                     xml.contains("schemas.openxmlformats.org/wordprocessingml/2006/main")
                        && xml.contains("<w:body>") && xml.contains("<w:sectPr>")
                        && xml.contains("xml:space=\"preserve\"")))

    out.append(check(suite: suite, "非法控制字符被剔除",
                     !TranslationDocumentWriter.escapeXML("a\u{01}b\u{0B}c")
                        .contains("\u{01}")
                        && TranslationDocumentWriter.escapeXML("a\u{01}b") == "ab"))

    let again = try? TranslationDocumentWriter.docxData(sample)
    out.append(check(suite: suite, "同一文档两次生成字节完全一致（确定性）",
                     again == docx))

    let emptyDoc = TranslationDocument(title: "空", items: [])
    let emptyData = try? TranslationDocumentWriter.docxData(emptyDoc)
    out.append(check(suite: suite, "空记录文档仍生成合法 DOCX",
                     emptyData != nil && (emptyData?.count ?? 0) > 200
                        && probeZIP(emptyData ?? Data()).eocdOK))

    out.append(check(suite: suite, "UI 语言目录恰为 14 种且含简体中文",
                     LanguageCatalog.featuredCount == 14
                        && LanguageCatalog.featured.count == 14
                        && LanguageCatalog.featuredCodes.contains("zh")
                        && Set(LanguageCatalog.featuredCodes).count == 14,
                     detail: LanguageCatalog.featuredCodes.joined(separator: ",")))
    out.append(check(suite: suite, "14 种均在模型卡 36 种之中，底层目录未缩水",
                     LanguageCatalog.count == 36
                        && LanguageCatalog.featuredCodes.allSatisfy { LanguageCatalog.contains($0) }
                        && LanguageCatalog.name(for: "th") == "泰文"))

    // 落盘样品，便于用系统工具 / Python zipfile 独立验证 DOCX 可打开。
    let dir = HymnTestMain.reportDir()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? docx.write(to: URL(fileURLWithPath: dir).appendingPathComponent("export-sample.docx"))
    try? txt.write(to: URL(fileURLWithPath: dir).appendingPathComponent("export-sample.txt"))

    return out
}
