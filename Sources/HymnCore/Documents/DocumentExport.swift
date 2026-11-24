import Foundation

// MARK: - 导出文档模型

/// 所有导出场景（划词浮窗 / 历史单条或合并 / PDF 译文）共用的文档结构。
public struct TranslationDocument: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let heading: String
        public let source: String
        public let translation: String
        public let note: String

        public init(heading: String, source: String, translation: String, note: String = "") {
            self.heading = heading
            self.source = source
            self.translation = translation
            self.note = note
        }
    }

    public let title: String
    public let subtitle: String
    public let items: [Item]

    public init(title: String, subtitle: String = "", items: [Item]) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

// MARK: - 文档写出（TXT / OOXML DOCX）

/// 零外部依赖的文档写出器。
///
/// `.txt` 直接 UTF-8；`.docx` 生成标准 OOXML 包（`[Content_Types].xml` / `_rels/.rels` /
/// `word/document.xml` / `word/_rels/document.xml.rels`），ZIP 采用 store 模式，
/// CRC32 与目录结构按 PKWARE APPNOTE 手写，不链接 zlib、不启动外部进程、不访问网络。
public enum TranslationDocumentWriter {
    public static func txtData(_ document: TranslationDocument) -> Data {
        var lines: [String] = []
        lines.append(document.title)
        if !document.subtitle.isEmpty { lines.append(document.subtitle) }
        lines.append(String(repeating: "=", count: 48))
        lines.append("")
        for (index, item) in document.items.enumerated() {
            lines.append("【\(index + 1)】\(item.heading)")
            if !item.note.isEmpty { lines.append(item.note) }
            lines.append("原文：")
            lines.append(item.source)
            lines.append("")
            lines.append("译文：")
            lines.append(item.translation)
            lines.append("")
            lines.append(String(repeating: "-", count: 48))
            lines.append("")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    public static func docxData(_ document: TranslationDocument) throws -> Data {
        var body = ""
        body += paragraph(document.title, bold: true)
        if !document.subtitle.isEmpty {
            body += paragraph(document.subtitle)
        }
        for (index, item) in document.items.enumerated() {
            body += paragraph("【\(index + 1)】\(item.heading)", bold: true)
            if !item.note.isEmpty { body += paragraph(item.note) }
            body += paragraph("原文：", bold: true)
            body += paragraphs(item.source)
            body += paragraph("译文：", bold: true)
            body += paragraphs(item.translation)
            body += "<w:p/>"
        }
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
        </w:body></w:document>
        """

        let entries = [
            ZipEntry(name: "[Content_Types].xml", data: Data(contentTypesXML.utf8)),
            ZipEntry(name: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            ZipEntry(name: "word/document.xml", data: Data(documentXML.utf8)),
            ZipEntry(name: "word/_rels/document.xml.rels", data: Data(documentRelsXML.utf8)),
        ]
        return zipStore(entries)
    }

    // MARK: OOXML 片段

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
    """

    private static func paragraph(_ text: String, bold: Bool = false) -> String {
        let run = bold
            ? "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(escapeXML(text))</w:t></w:r>"
            : "<w:r><w:t xml:space=\"preserve\">\(escapeXML(text))</w:t></w:r>"
        return "<w:p>\(run)</w:p>"
    }

    private static func paragraphs(_ text: String) -> String {
        // 每个换行生成一个 Word 段落；空段落保留，避免格式塌陷。
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { paragraph(String($0)) }
            .joined()
    }

    /// XML 1.0 字符与实体转义；非法控制字符直接丢弃，避免 Word/Pages 拒绝打开。
    public static func escapeXML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D || (v >= 0x20 && v <= 0xD7FF)
                || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&apos;"
                default: out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - ZIP（store，无压缩）

    private struct ZipEntry {
        let name: String
        let data: Data
    }

    /// CRC-32 (IEEE 802.3)，逐字节位运算，确定性强、无需查表内存。
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }

    private static func le16(_ value: UInt16, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func le32(_ value: UInt32, into data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func zipStore(_ entries: [ZipEntry]) -> Data {
        // 固定 DOS 时间戳 1980-01-01，保证相同文档两次生成字节完全一致。
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021
        var out = Data()
        var central = Data()
        var localOffset: UInt32 = 0

        for entry in entries {
            let name = Data(entry.name.utf8)
            let size = UInt32(entry.data.count)
            let crc = crc32(entry.data)

            // Local file header
            le32(0x0403_4B50, into: &out)
            le16(20, into: &out)                 // version needed
            le16(0, into: &out)                  // flags
            le16(0, into: &out)                  // method: store
            le16(dosTime, into: &out)
            le16(dosDate, into: &out)
            le32(crc, into: &out)
            le32(size, into: &out)
            le32(size, into: &out)
            le16(UInt16(name.count), into: &out)
            le16(0, into: &out)                  // extra length
            out.append(name)
            out.append(entry.data)

            // Central directory header
            le32(0x0201_4B50, into: &central)
            le16(20, into: &central)             // version made by
            le16(20, into: &central)             // version needed
            le16(0, into: &central)
            le16(0, into: &central)
            le16(dosTime, into: &central)
            le16(dosDate, into: &central)
            le32(crc, into: &central)
            le32(size, into: &central)
            le32(size, into: &central)
            le16(UInt16(name.count), into: &central)
            le16(0, into: &central)              // extra
            le16(0, into: &central)              // comment
            le16(0, into: &central)              // disk start
            le16(0, into: &central)              // internal attrs
            le32(0, into: &central)              // external attrs
            le32(localOffset, into: &central)
            central.append(name)

            localOffset += UInt32(30 + name.count + entry.data.count)
        }

        let centralOffset = UInt32(out.count)
        let centralSize = UInt32(central.count)
        out.append(central)

        // End of central directory
        le32(0x0605_4B50, into: &out)
        le16(0, into: &out)
        le16(0, into: &out)
        le16(UInt16(entries.count), into: &out)
        le16(UInt16(entries.count), into: &out)
        le32(centralSize, into: &out)
        le32(centralOffset, into: &out)
        le16(0, into: &out)
        return out
    }
}
