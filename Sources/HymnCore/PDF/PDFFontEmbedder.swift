import Foundation

/// 把 TrueType 字体嵌进 PDF 并生成内容流里的文本编码。
///
/// 结构（PDF 32000-1 §9.7）：
///     Type0（/Encoding /Identity-H）
///       └── DescendantFonts → CIDFontType2
///             ├── /CIDToGIDMap /Identity     （CID 直接用子集里的 GID）
///             ├── /W                          （字宽，千分单位）
///             └── /FontDescriptor
///                   └── /FontFile2 → 子集 TTF
///     另加 /ToUnicode CMap，让复制/检索能拿到原文，否则译文在阅读器里是「不可提取」
///
/// 三条容易踩的规则：
///     ① 文本必须写成 2 字节大端 CID 的十六进制串，不能写 UTF-8；
///     ② 子集字体的 GID 与 CID 必须一一对应，否则字宽和字形会错位；
///     ③ /FontFile2 的流不带 /Length1 也能用，但带上更兼容老阅读器（记录解压后长度）。
public enum PDFFontEmbedder {
    public struct Embedded {
        public var objects: [(ref: PDFRef, value: PDFValue)]
        public var type0Ref: PDFRef
        public var resourceName: String
        public var subsetGlyphCount: Int
        public var subsetBytes: Int
        public var missingScalars: [UInt32]
        /// 码位 → CID（等于子集内新 GID）
        public var cidForScalar: [UInt32: Int]
        /// 已编码的文本（2 字节大端 CID 串）
        public var encodedText: Data
        /// 子集字体名（带子集前缀，如 ABCDEF+LinguaNovaSong-Regular）
        public var subsetName: String
    }

    /// - Parameters:
    ///   - firstObjectNumber: 分配对象的起始编号（调用方保证不与已有对象冲突）
    public static func embed(
        font: TrueTypeFont,
        text: String,
        resourceName: String,
        firstObjectNumber: Int
    ) throws -> Embedded {
        // 1. 文本 → GID 集合
        var gids = Set<Int>()
        var missing: [UInt32] = []
        var scalarOrder: [(scalar: UInt32, gid: Int?)] = []
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if let gid = font.glyphID(for: value) {
                gids.insert(gid)
                scalarOrder.append((value, gid))
            } else {
                missing.append(value)
                scalarOrder.append((value, nil))
            }
        }
        // 全部缺字时不嵌子集（只留 .notdef 没有意义），由调用方回落到「不画」
        let subset = try font.subset(glyphs: gids)

        // 2. 编码：CID = 子集内新 GID
        var cidForScalar: [UInt32: Int] = [:]
        var encoded = Data()
        for item in scalarOrder {
            guard let gid = item.gid, let cid = subset.glyphMap[gid] else { continue }
            cidForScalar[item.scalar] = cid
            encoded.append(UInt8((cid >> 8) & 0xFF))
            encoded.append(UInt8(cid & 0xFF))
        }

        let tag = Self.subsetTag(subset.data)
        let baseName = font.postScriptName.replacingOccurrences(of: " ", with: "-")
        let subsetName = "\(tag)+\(baseName)"

        let fileRef = PDFRef(firstObjectNumber, 0)
        let descriptorRef = PDFRef(firstObjectNumber + 1, 0)
        let cidFontRef = PDFRef(firstObjectNumber + 2, 0)
        let toUnicodeRef = PDFRef(firstObjectNumber + 3, 0)
        let type0Ref = PDFRef(firstObjectNumber + 4, 0)

        // 3. FontFile2：子集 TTF，Flate 压缩
        let compressed = PDFFilters.deflate(subset.data)
        let useFilter = compressed.count < subset.data.count
        var fileDict: [String: PDFValue] = [
            "Length1": .int(subset.data.count),
            "Length": .int(useFilter ? compressed.count : subset.data.count),
        ]
        if useFilter { fileDict["Filter"] = .name("FlateDecode") }
        let fontFile = PDFStream(dictionary: fileDict, raw: useFilter ? compressed : subset.data)

        // 4. FontDescriptor
        let stemV = font.weightClass >= 600 ? 140 : 80
        let flags = 4   // Symbolic：Identity 编码下不能声明 Nonsymbolic，否则部分阅读器按单字节解
        let descriptor: [String: PDFValue] = [
            "Type": .name("FontDescriptor"),
            "FontName": .name(subsetName),
            "Flags": .int(flags),
            "FontBBox": .array([
                .int(font.boundingBox.xMin), .int(font.boundingBox.yMin),
                .int(font.boundingBox.xMax), .int(font.boundingBox.yMax),
            ]),
            "ItalicAngle": .real(font.italicAngle),
            "Ascent": .int(font.ascent),
            "Descent": .int(font.descent),
            "CapHeight": .int(font.capHeight),
            "StemV": .int(stemV),
            "FontFile2": .reference(fileRef),
        ]

        // 5. CIDFont：/W 按连续 CID 分段
        let cidFont: [String: PDFValue] = [
            "Type": .name("Font"),
            "Subtype": .name("CIDFontType2"),
            "BaseFont": .name(subsetName),
            "CIDSystemInfo": .dictionary([
                "Registry": .string(Data("Adobe".utf8)),
                "Ordering": .string(Data("Identity".utf8)),
                "Supplement": .int(0),
            ]),
            "FontDescriptor": .reference(descriptorRef),
            "CIDToGIDMap": .name("Identity"),
            "DW": .int(1000),
            "W": widthsArray(subset.widths1000),
        ]

        // 6. Type0
        let type0: [String: PDFValue] = [
            "Type": .name("Font"),
            "Subtype": .name("Type0"),
            "BaseFont": .name(subsetName),
            "Encoding": .name("Identity-H"),
            "DescendantFonts": .array([.reference(cidFontRef)]),
            "ToUnicode": .reference(toUnicodeRef),
        ]

        // 7. ToUnicode：CID → UTF-16BE
        let cmapText = toUnicodeCMap(cidForScalar: cidForScalar)
        let cmapData = Data(cmapText.utf8)
        let cmapCompressed = PDFFilters.deflate(cmapData)
        let cmapUseFilter = cmapCompressed.count < cmapData.count
        var cmapDict: [String: PDFValue] = [
            "Length": .int(cmapUseFilter ? cmapCompressed.count : cmapData.count)
        ]
        if cmapUseFilter { cmapDict["Filter"] = .name("FlateDecode") }
        let cmapStream = PDFStream(dictionary: cmapDict,
                                   raw: cmapUseFilter ? cmapCompressed : cmapData)

        let objects: [(ref: PDFRef, value: PDFValue)] = [
            (fileRef, .stream(fontFile)),
            (descriptorRef, .dictionary(descriptor)),
            (cidFontRef, .dictionary(cidFont)),
            (toUnicodeRef, .stream(cmapStream)),
            (type0Ref, .dictionary(type0)),
        ]

        return Embedded(
            objects: objects,
            type0Ref: type0Ref,
            resourceName: resourceName,
            subsetGlyphCount: subset.glyphCount,
            subsetBytes: subset.data.count,
            missingScalars: missing,
            cidForScalar: cidForScalar,
            encodedText: encoded,
            subsetName: subsetName)
    }

    /// 单独编码一段文本（不嵌入字体）。
    ///
    /// 文档级排版必须把字体一次性嵌好、再逐行编码：如果每行都调 `embed`，
    /// 每行都会生成一份子集和 5 个对象，300 页文档会爆炸。
    public struct Encoded {
        public var data: Data
        public var missing: [UInt32]
    }

    public static func encode(text: String, cidForScalar: [UInt32: Int]) -> Encoded {
        var out = Data()
        out.reserveCapacity(text.unicodeScalars.count * 2)
        var missing: [UInt32] = []
        for scalar in text.unicodeScalars {
            guard let cid = cidForScalar[scalar.value] else {
                missing.append(scalar.value)
                continue
            }
            out.append(UInt8((cid >> 8) & 0xFF))
            out.append(UInt8(cid & 0xFF))
        }
        return Encoded(data: out, missing: missing)
    }

    /// /W 数组：`[ 起始CID [w0 w1 …] 起始CID w … ]`
    /// 连续 CID 合成一段，比逐个写省一半以上字节。
    static func widthsArray(_ widths: [Int]) -> PDFValue {
        var items: [PDFValue] = []
        var index = 0
        while index < widths.count {
            var end = index
            while end + 1 < widths.count && end - index < 255 { end += 1 }
            items.append(.int(index))
            items.append(.array((index...end).map { .int(widths[$0]) }))
            index = end + 1
        }
        return .array(items)
    }

    /// 子集前缀：规范要求 6 个大写字母 + '+'，用于区分同名不同子集的字体。
    /// 用子集内容的校验和推导，保证同样输入产出同样前缀（golden 可比）。
    static func subsetTag(_ data: Data) -> String {
        var hash: UInt32 = 2166136261
        for byte in data.prefix(4096) {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        var tag = ""
        var value = hash
        for _ in 0..<6 {
            tag.append(Character(UnicodeScalar(UInt8(65 + value % 26))))
            value /= 26
        }
        return tag
    }

    static func toUnicodeCMap(cidForScalar: [UInt32: Int]) -> String {
        let entries = cidForScalar.sorted { $0.value < $1.value }
        var out = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange

        """
        // bfchar 建议每块不超过 100 条
        var index = 0
        while index < entries.count {
            let end = min(index + 100, entries.count)
            out += "\(end - index) beginbfchar\n"
            for i in index..<end {
                let cid = entries[i].value
                let scalar = entries[i].key
                out += String(format: "<%04X> <%@>\n", cid, utf16Hex(scalar))
            }
            out += "endbfchar\n"
            index = end
        }
        out += """
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end

        """
        return out
    }

    /// 码位 → UTF-16BE 十六进制。BMP 外要拆成代理对，否则复制出来的字是乱码。
    static func utf16Hex(_ scalar: UInt32) -> String {
        if scalar <= 0xFFFF {
            return String(format: "%04X", scalar)
        }
        let value = scalar - 0x10000
        let high = 0xD800 + (value >> 10)
        let low = 0xDC00 + (value & 0x3FF)
        return String(format: "%04X%04X", high, low)
    }
}
