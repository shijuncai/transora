import Foundation

/// 字体模型（只读）。
///
/// 只做「读文本」需要的事：把内容流里的字节串翻译成
/// （码字、unicode、字宽、是否词间空格）四元组。
///
/// 三种情况必须区分清楚：
/// - **简单字体**（Type1 / TrueType / Type3）：1 字节一个码，`/Widths` 按 `/FirstChar` 起算；
/// - **Type0 + Identity-H**：2 字节一个 CID，字宽查 `/W`，缺省 `/DW`；
/// - **没有 `/ToUnicode`**：unicode 拿不到。此时**不猜编码**（猜就是乱码的源头），
///   该字形标记为 unmapped，由上层决定「整页不可译」。
public final class PDFFont {
    public enum Kind: Sendable {
        case simple
        case type0
        case unsupported(String)
    }

    public let kind: Kind
    public let subtype: String
    public let baseFont: String
    public let isVertical: Bool
    public let ascent: Double
    public let descent: Double
    public let capHeight: Double
    public let boundingBox: PDFRect?
    public let toUnicode: PDFCMap?
    public let codeLength: Int
    /// 是否真的读到了 `/Widths` 或 `/W`；false 时字宽是估算值，断行会有误差
    public let hasRealWidths: Bool

    let widths: [Int: Double]
    let defaultWidth: Double
    /// 简单字体的码 → unicode（由 /Encoding 与 /Differences 合成）。
    /// 这是「没有 /ToUnicode」时的唯一可靠来源。
    let codeToUnicode: [Int: String]
    /// 判断「一个码是不是空格」用：简单字体是码 32，CID 字体按 unicode 判
    let spaceCodes: Set<Int>

    public struct Glyph: Sendable {
        public var code: Int
        public var unicode: String?
        /// 千分单位字宽
        public var width: Double
        /// 是否加词间距（wordSpacing）——PDF 规定只对单字节码 32 生效
        public var applyWordSpacing: Bool
        public var isSpace: Bool
    }

    public init(
        kind: Kind, subtype: String, baseFont: String, isVertical: Bool,
        ascent: Double, descent: Double, capHeight: Double, boundingBox: PDFRect?,
        toUnicode: PDFCMap?, codeLength: Int, hasRealWidths: Bool,
        widths: [Int: Double], defaultWidth: Double,
        codeToUnicode: [Int: String], spaceCodes: Set<Int>
    ) {
        self.kind = kind
        self.subtype = subtype
        self.baseFont = baseFont
        self.isVertical = isVertical
        self.ascent = ascent
        self.descent = descent
        self.capHeight = capHeight
        self.boundingBox = boundingBox
        self.toUnicode = toUnicode
        self.codeLength = codeLength
        self.hasRealWidths = hasRealWidths
        self.widths = widths
        self.defaultWidth = defaultWidth
        self.codeToUnicode = codeToUnicode
        self.spaceCodes = spaceCodes
    }

    public func width(of code: Int) -> Double {
        widths[code] ?? defaultWidth
    }

    /// 把内容流里的字符串切成字形序列。
    public func glyphs(from data: Data) -> [Glyph] {
        let bytes = [UInt8](data)
        var out: [Glyph] = []
        let step = max(1, codeLength)

        // 有 CMap 时按它的 codespace 切；没有就按固定长度切
        let codes: [UInt32]
        if case .type0 = kind, let cmap = toUnicode, !cmap.codespaces.isEmpty {
            // 只有 Type0 才信 CMap 的 codespace
            codes = cmap.decode(bytes, fallbackLength: step)
        } else {
            // 简单字体的码长**由字体决定**（1 字节），不能信 CMap 的 codespace。
            // 实测某本书的 Monospace 子集字体：ToUnicode 里全是 `<20> <0020>`
            // 这样的 1 字节码，但 codespace 写的是 `<0000> <FFFF>`。
            // 按 codespace 切会把两个字节拼成一个码，561 个字形里 471 个取不到 unicode。
            var raw: [UInt32] = []
            var index = 0
            while index + step <= bytes.count {
                var value: UInt32 = 0
                for k in 0..<step { value = (value << 8) | UInt32(bytes[index + k]) }
                raw.append(value)
                index += step
            }
            codes = raw
        }

        for code32 in codes {
            let code = Int(code32)
            let unicode = toUnicode?.unicode(for: code32) ?? fallbackUnicode(code)
            let isSpace = spaceCodes.contains(code) || unicode == " "
            out.append(Glyph(
                code: code,
                unicode: unicode,
                width: width(of: code),
                applyWordSpacing: step == 1 && code == 0x20,
                isSpace: isSpace))
        }
        return out
    }

    /// 没有 `/ToUnicode` 时的回落：只查 `/Encoding`（预定义表 + `/Differences`）。
    /// 表里没有就是没有，**不做任何编码猜测**——猜出来的乱码比缺失更糟。
    func fallbackUnicode(_ code: Int) -> String? {
        if let mapped = codeToUnicode[code] { return mapped }
        return nil
    }

    // MARK: - 从文档装载

    public static func load(
        document: PDFDocument,
        dict: [String: PDFValue]
    ) -> PDFFont {
        let subtype = dict["Subtype"]?.nameValue ?? "?"
        let baseFont = dict["BaseFont"]?.nameValue ?? "(unnamed)"

        // Type0 的度量放在「后代 CIDFont」里，不在 Type0 自己身上。
        // 读错地方的表现是 ascent/descent 全 0，文本框高度为 0——
        // 段落行高完全失效，而这个 bug 不会报错。
        var descendant: [String: PDFValue]?
        if subtype == "Type0" {
            let array: [PDFValue]?
            if case .reference(let ref)? = dict["DescendantFonts"] {
                array = (try? document.resolve(ref))?.arrayValue
            } else {
                array = dict["DescendantFonts"]?.arrayValue
            }
            if let first = array?.first {
                if case .reference(let ref) = first {
                    descendant = (try? document.resolve(ref))?.dictionaryValue
                } else {
                    descendant = first.dictionaryValue
                }
            }
        }

        let descriptor = resolveDict(document, descendant?["FontDescriptor"])
            ?? resolveDict(document, dict["FontDescriptor"])

        var ascent = descriptor?["Ascent"]?.doubleValue ?? 0
        var descent = descriptor?["Descent"]?.doubleValue ?? 0
        var capHeight = descriptor?["CapHeight"]?.doubleValue ?? 0
        var box: PDFRect?
        if let arr = descriptor?["FontBBox"]?.arrayValue?.compactMap(\.doubleValue), arr.count == 4 {
            box = PDFRect(x0: arr[0], y0: arr[1], x1: arr[2], y1: arr[3])
        }
        if ascent == 0, let box { ascent = box.y1 }
        if descent == 0, let box { descent = box.y0 }
        if capHeight == 0 { capHeight = ascent * 0.7 }

        var toUnicode: PDFCMap?
        if let value = dict["ToUnicode"],
           case .reference(let ref) = value,
           let stream = (try? document.resolve(ref))?.streamValue,
           let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary) {
            toUnicode = try? PDFCMap.parse(decoded)
        } else if let stream = dict["ToUnicode"]?.streamValue,
                  let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary) {
            toUnicode = try? PDFCMap.parse(decoded)
        }

        if subtype == "Type0" {
            return loadType0(document: document, dict: dict, descendant: descendant,
                             baseFont: baseFont,
                             subtype: subtype, descriptor: descriptor,
                             ascent: ascent, descent: descent, capHeight: capHeight,
                             box: box, toUnicode: toUnicode)
        }

        if subtype == "Type3" {
            // Type3 的字形来自它自己的 CharProcs，本版不解码，但字宽仍然可用
            return loadSimple(document: document, dict: dict, baseFont: baseFont,
                              subtype: subtype, kind: .unsupported("Type3"),
                              descriptor: descriptor, ascent: ascent, descent: descent,
                              capHeight: capHeight, box: box, toUnicode: toUnicode)
        }

        return loadSimple(document: document, dict: dict, baseFont: baseFont,
                          subtype: subtype, kind: .simple,
                          descriptor: descriptor, ascent: ascent, descent: descent,
                          capHeight: capHeight, box: box, toUnicode: toUnicode)
    }

    static func loadSimple(
        document: PDFDocument, dict: [String: PDFValue], baseFont: String,
        subtype: String, kind: Kind, descriptor: [String: PDFValue]?,
        ascent: Double, descent: Double, capHeight: Double, box: PDFRect?,
        toUnicode: PDFCMap?
    ) -> PDFFont {
        let firstChar = dict["FirstChar"]?.intValue ?? 0
        let widthsArray = dict["Widths"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        var widths: [Int: Double] = [:]
        for (offset, width) in widthsArray.enumerated() {
            widths[firstChar + offset] = width
        }
        let missingWidth = descriptor?["MissingWidth"]?.doubleValue ?? 0

        let encoding = simpleEncoding(document: document, dict: dict, subtype: subtype)
        let codeToUnicode = encoding.codeToUnicode

        return PDFFont(
            kind: kind, subtype: subtype, baseFont: sanitizeName(baseFont),
            isVertical: false,
            ascent: ascent, descent: descent, capHeight: capHeight, boundingBox: box,
            toUnicode: toUnicode, codeLength: 1,
            hasRealWidths: !widths.isEmpty,
            widths: widths,
            defaultWidth: missingWidth > 0 ? missingWidth : 500,
            codeToUnicode: codeToUnicode,
            spaceCodes: [0x20])
    }

    static func loadType0(
        document: PDFDocument, dict: [String: PDFValue],
        descendant: [String: PDFValue]?,
        baseFont: String,
        subtype: String, descriptor: [String: PDFValue]?,
        ascent: Double, descent: Double, capHeight: Double, box: PDFRect?,
        toUnicode: PDFCMap?
    ) -> PDFFont {
        let encoding = dict["Encoding"]?.nameValue ?? ""
        let isVertical = encoding.contains("V")
        // Identity-H/V 是 2 字节码；其他预定义 CMap（如 UniGB-UCS2-H）也是 2 字节
        let codeLength = 2

        var widths: [Int: Double] = [:]
        var hasRealWidths = false
        var defaultWidth: Double = 1000

        if let cidFont = descendant {
            if let dw = cidFont["DW"]?.doubleValue { defaultWidth = dw }
            if let wArray = cidFont["W"]?.arrayValue {
                parseCIDWidths(wArray, into: &widths)
                hasRealWidths = !widths.isEmpty
            }
        }

        return PDFFont(
            kind: .type0, subtype: subtype, baseFont: sanitizeName(baseFont),
            isVertical: isVertical,
            ascent: ascent, descent: descent, capHeight: capHeight, boundingBox: box,
            toUnicode: toUnicode, codeLength: codeLength,
            hasRealWidths: hasRealWidths,
            widths: widths, defaultWidth: defaultWidth,
            codeToUnicode: [:], spaceCodes: [])
    }

    /// `/W [ c [w1 w2 …] cFirst cLast w … ]` 两种写法都要认。
    static func parseCIDWidths(_ array: [PDFValue], into widths: inout [Int: Double]) {
        var index = 0
        while index < array.count {
            guard let first = array[index].intValue else {
                index += 1
                continue
            }
            if index + 1 < array.count, let list = array[index + 1].arrayValue {
                for (offset, item) in list.enumerated() {
                    if let width = item.doubleValue { widths[first + offset] = width }
                }
                index += 2
            } else if index + 2 < array.count,
                      let last = array[index + 1].intValue,
                      let width = array[index + 2].doubleValue {
                if last >= first && last - first <= 0x1_0000 {
                    for cid in first...last { widths[cid] = width }
                }
                index += 3
            } else {
                index += 1
            }
        }
    }

    /// 合成简单字体的码 → unicode 表。
    ///
    /// 顺序：预定义编码表（`/WinAnsiEncoding` 等）→ 叠加 `/Differences` 的字形名。
    /// 没有 `/Encoding` 时按字体类型给默认值（TrueType 用 WinAnsi、Type1 用 Standard），
    /// 这是 Windows/Mac 生成器的实际惯例，比「只认 ASCII」准得多。
    static func simpleEncoding(
        document: PDFDocument, dict: [String: PDFValue], subtype: String
    ) -> (kind: PDFEncoding.Kind?, codeToUnicode: [Int: String]) {
        var baseName: String?
        var differences: [Int: String] = [:]

        let encodingValue: PDFValue?
        if case .reference(let ref)? = dict["Encoding"] {
            encodingValue = (try? document.resolve(ref))
        } else {
            encodingValue = dict["Encoding"]
        }

        if let name = encodingValue?.nameValue {
            baseName = name
        } else if let encodingDict = encodingValue?.dictionaryValue {
            baseName = encodingDict["BaseEncoding"]?.nameValue
            if let array = encodingDict["Differences"]?.arrayValue {
                var code = 0
                for item in array {
                    if let number = item.intValue {
                        code = number
                    } else if let name = item.nameValue {
                        differences[code] = name
                        code += 1
                    }
                }
            }
        }

        let kind: PDFEncoding.Kind?
        if let baseName {
            kind = PDFEncoding.Kind(rawValue: baseName)
        } else if subtype == "TrueType" {
            kind = .winAnsi
        } else {
            kind = .standard
        }

        var table: [Int: String] = [:]
        if let kind {
            for code in 0...255 {
                if let text = PDFEncoding.unicode(for: kind, code: code) { table[code] = text }
            }
        }
        for (code, name) in differences {
            if let text = GlyphNames.unicode(for: name) {
                table[code] = text
            } else {
                // 字形名明确存在但解析不出来：删掉基表映射，避免「看着像对了其实是错的字」
                table.removeValue(forKey: code)
            }
        }
        return (kind, table)
    }

    static func resolveDict(_ document: PDFDocument, _ value: PDFValue?) -> [String: PDFValue]? {
        guard let value else { return nil }
        if case .reference(let ref) = value {
            return (try? document.resolve(ref))?.dictionaryValue
        }
        return value.dictionaryValue
    }

    /// 子集字体名形如 `ABCDEF+SimSun`，前缀只是标签，展示时去掉更干净。
    static func sanitizeName(_ name: String) -> String {
        if name.count > 7, name[name.index(name.startIndex, offsetBy: 6)] == "+" {
            return String(name.dropFirst(7))
        }
        return name
    }
}

// MARK: - 字形名 → unicode

/// Adobe Glyph List 的一个**有意识子集**。
///
/// 只覆盖 ASCII、Latin-1 与常见排版符号。理由：CJK 文档几乎总带 `/ToUnicode`，
/// 真正靠字形名回落的场景是西文 PDF；而完整 AGL 有 4000+ 条，抄进来既臃肿
/// 又容易抄错。查不到的返回 nil，上层会标记 unmapped，**不猜**。
public enum GlyphNames {
    public static func unicode(for name: String) -> String? {
        if let value = table[name], let scalar = UnicodeScalar(value) { return String(scalar) }

        // "uni4E2D" / "uni4E2D4E2D"
        if name.hasPrefix("uni"), name.count >= 7 {
            let hex = String(name.dropFirst(3))
            var scalars: [UnicodeScalar] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: min(4, hex.distance(from: index, to: hex.endIndex)))
                guard let value = UInt32(hex[index..<end], radix: 16),
                      let scalar = UnicodeScalar(value) else { break }
                scalars.append(scalar)
                index = end
            }
            if !scalars.isEmpty { return String(String.UnicodeScalarView(scalars)) }
        }
        // "u1F600"
        if name.hasPrefix("u"), name.count >= 5 {
            let hex = String(name.dropFirst())
            if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                return String(scalar)
            }
        }
        // 单字母名（A、b 等）在子集字体里很常见
        if name.count == 1 { return name }
        return nil
    }

    static let table: [String: UInt32] = [
        "space": 0x20, "exclam": 0x21, "quotedbl": 0x22, "numbersign": 0x23,
        "dollar": 0x24, "percent": 0x25, "ampersand": 0x26, "quotesingle": 0x27,
        "parenleft": 0x28, "parenright": 0x29, "asterisk": 0x2A, "plus": 0x2B,
        "comma": 0x2C, "hyphen": 0x2D, "period": 0x2E, "slash": 0x2F,
        "zero": 0x30, "one": 0x31, "two": 0x32, "three": 0x33, "four": 0x34,
        "five": 0x35, "six": 0x36, "seven": 0x37, "eight": 0x38, "nine": 0x39,
        "colon": 0x3A, "semicolon": 0x3B, "less": 0x3C, "equal": 0x3D,
        "greater": 0x3E, "question": 0x3F, "at": 0x40,
        "bracketleft": 0x5B, "backslash": 0x5C, "bracketright": 0x5D,
        "asciicircum": 0x5E, "underscore": 0x5F, "grave": 0x60,
        "braceleft": 0x7B, "bar": 0x7C, "braceright": 0x7D, "asciitilde": 0x7E,
        "exclamdown": 0xA1, "cent": 0xA2, "sterling": 0xA3, "currency": 0xA4,
        "yen": 0xA5, "brokenbar": 0xA6, "section": 0xA7, "dieresis": 0xA8,
        "copyright": 0xA9, "ordfeminine": 0xAA, "guillemotleft": 0xAB,
        "logicalnot": 0xAC, "registered": 0xAE, "macron": 0xAF,
        "degree": 0xB0, "plusminus": 0xB1, "twosuperior": 0xB2,
        "threesuperior": 0xB3, "acute": 0xB4, "mu": 0xB5, "paragraph": 0xB6,
        "periodcentered": 0xB7, "cedilla": 0xB8, "onesuperior": 0xB9,
        "ordmasculine": 0xBA, "guillemotright": 0xBB, "onequarter": 0xBC,
        "onehalf": 0xBD, "threequarters": 0xBE, "questiondown": 0xBF,
        "Agrave": 0xC0, "Aacute": 0xC1, "Acircumflex": 0xC2, "Atilde": 0xC3,
        "Adieresis": 0xC4, "Aring": 0xC5, "AE": 0xC6, "Ccedilla": 0xC7,
        "Egrave": 0xC8, "Eacute": 0xC9, "Ecircumflex": 0xCA, "Edieresis": 0xCB,
        "Igrave": 0xCC, "Iacute": 0xCD, "Icircumflex": 0xCE, "Idieresis": 0xCF,
        "Eth": 0xD0, "Ntilde": 0xD1, "Ograve": 0xD2, "Oacute": 0xD3,
        "Ocircumflex": 0xD4, "Otilde": 0xD5, "Odieresis": 0xD6,
        "multiply": 0xD7, "Oslash": 0xD8, "Ugrave": 0xD9, "Uacute": 0xDA,
        "Ucircumflex": 0xDB, "Udieresis": 0xDC, "Yacute": 0xDD, "Thorn": 0xDE,
        "germandbls": 0xDF, "agrave": 0xE0, "aacute": 0xE1,
        "acircumflex": 0xE2, "atilde": 0xE3, "adieresis": 0xE4, "aring": 0xE5,
        "ae": 0xE6, "ccedilla": 0xE7, "egrave": 0xE8, "eacute": 0xE9,
        "ecircumflex": 0xEA, "edieresis": 0xEB, "igrave": 0xEC, "iacute": 0xED,
        "icircumflex": 0xEE, "idieresis": 0xEF, "eth": 0xF0, "ntilde": 0xF1,
        "ograve": 0xF2, "oacute": 0xF3, "ocircumflex": 0xF4, "otilde": 0xF5,
        "odieresis": 0xF6, "divide": 0xF7, "oslash": 0xF8, "ugrave": 0xF9,
        "uacute": 0xFA, "ucircumflex": 0xFB, "udieresis": 0xFC, "yacute": 0xFD,
        "thorn": 0xFE, "ydieresis": 0xFF,
        "dotlessi": 0x131, "Lslash": 0x141, "lslash": 0x142, "OE": 0x152,
        "oe": 0x153, "Scaron": 0x160, "scaron": 0x161, "Zcaron": 0x17D,
        "zcaron": 0x17E, "Ydieresis": 0x178, "florin": 0x192,
        "circumflex": 0x2C6, "caron": 0x2C7, "breve": 0x2D8, "dotaccent": 0x2D9,
        "ring": 0x2DA, "ogonek": 0x2DB, "tilde": 0x2DC, "hungarumlaut": 0x2DD,
        "endash": 0x2013, "emdash": 0x2014, "quoteleft": 0x2018,
        "quoteright": 0x2019, "quotesinglbase": 0x201A, "quotedblleft": 0x201C,
        "quotedblright": 0x201D, "quotedblbase": 0x201E, "dagger": 0x2020,
        "daggerdbl": 0x2021, "bullet": 0x2022, "ellipsis": 0x2026,
        "perthousand": 0x2030, "guilsinglleft": 0x2039,
        "guilsinglright": 0x203A, "fraction": 0x2044, "Euro": 0x20AC,
        "trademark": 0x2122, "minus": 0x2212, "fi": 0xFB01, "fl": 0xFB02,
        "ff": 0xFB00, "ffi": 0xFB03, "ffl": 0xFB04, "nbspace": 0xA0,
        "sfthyphen": 0xAD, "middot": 0xB7, "nbhyphen": 0x2011,
    ]
}
