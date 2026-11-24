import Foundation

public enum PDFParseError: Error, CustomStringConvertible, Equatable {
    case unexpectedEnd(offset: Int)
    case unexpectedByte(UInt8, offset: Int)
    case malformedNumber(String)
    case malformedHexString(offset: Int)
    case malformedName(offset: Int)
    case dictionaryKeyNotName(offset: Int)
    case unsupportedKeyword(String, offset: Int)

    public var description: String {
        switch self {
        case .unexpectedEnd(let o): return "意外的文件结尾 @\(o)"
        case .unexpectedByte(let b, let o):
            return "意外的字节 0x\(String(b, radix: 16)) @\(o)"
        case .malformedNumber(let s): return "非法数字 \(s)"
        case .malformedHexString(let o): return "非法十六进制字符串 @\(o)"
        case .malformedName(let o): return "非法名称 @\(o)"
        case .dictionaryKeyNotName(let o): return "字典键不是名称 @\(o)"
        case .unsupportedKeyword(let k, let o): return "不支持的关键字 \(k) @\(o)"
        }
    }
}

/// PDF 词法 + 语法。刻意做成「字节数组 + 游标」而非 String，
/// 因为 PDF 里到处是二进制字符串，任何一次 String 转换都可能损坏数据。
public struct PDFParser {
    public let bytes: [UInt8]
    public var index: Int

    public init(_ bytes: [UInt8], index: Int = 0) {
        self.bytes = bytes
        self.index = index
    }

    public init(_ data: Data, index: Int = 0) {
        self.init([UInt8](data), index: index)
    }

    // MARK: - 字符分类

    @inline(__always)
    static func isWhite(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00
    }

    @inline(__always)
    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    @inline(__always)
    static func isRegular(_ b: UInt8) -> Bool {
        !isWhite(b) && !isDelimiter(b)
    }

    public var isAtEnd: Bool { index >= bytes.count }

    @inline(__always)
    mutating func advance() -> UInt8? {
        guard index < bytes.count else { return nil }
        let b = bytes[index]
        index += 1
        return b
    }

    @inline(__always)
    mutating func skipWhiteAndComments() {
        while index < bytes.count {
            let b = bytes[index]
            if Self.isWhite(b) {
                index += 1
            } else if b == 0x25 { // '%'
                while index < bytes.count && bytes[index] != 0x0A && bytes[index] != 0x0D {
                    index += 1
                }
            } else {
                return
            }
        }
    }

    // MARK: - 关键字

    /// 读一段 regular 字符（用于 obj / stream / R / 内容流算子）。
    public mutating func parseKeyword() -> String? {
        skipWhiteAndComments()
        let start = index
        while index < bytes.count && Self.isRegular(bytes[index]) {
            index += 1
        }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// 括号类单字符算子（' 和 "），parseKeyword 读不到，需要单独认。
    public mutating func parseSingleCharOperator() -> String? {
        skipWhiteAndComments()
        guard index < bytes.count else { return nil }
        let b = bytes[index]
        if b == 0x27 || b == 0x22 {
            index += 1
            return String(UnicodeScalar(b))
        }
        return nil
    }

    // MARK: - 对象

    /// 解析一个完整对象。`resolveLength` 用于流：/Length 可能是间接引用，
    /// 由调用方（Document）提供解析能力，这里不陷入循环依赖。
    public mutating func parseValue(
        allowReferences: Bool = true,
        resolveLength: ((PDFRef) -> Int?)? = nil
    ) throws -> PDFValue {
        skipWhiteAndComments()
        guard index < bytes.count else { throw PDFParseError.unexpectedEnd(offset: index) }
        let b = bytes[index]

        switch b {
        case 0x2F: // '/'
            return .name(try parseName())
        case 0x28: // '('
            return .string(try parseLiteralString())
        case 0x3C: // '<'
            if index + 1 < bytes.count && bytes[index + 1] == 0x3C {
                return try parseDictionaryOrStream(resolveLength: resolveLength)
            }
            return .string(try parseHexString())
        case 0x5B: // '['
            return try parseArray(resolveLength: resolveLength)
        case 0x5D, 0x3E:
            throw PDFParseError.unexpectedByte(b, offset: index)
        default:
            break
        }

        // 数字（含 +/-/小数点开头）或关键字
        if b == 0x2B || b == 0x2D || b == 0x2E || (b >= 0x30 && b <= 0x39) {
            let start = index
            let num = try parseNumber()
            if allowReferences, case .int(let n) = num {
                // 尝试 "N G R"
                let save = index
                skipWhiteAndComments()
                if let gen = try? parseNumber(), case .int(let g) = gen, g >= 0 {
                    skipWhiteAndComments()
                    if index < bytes.count && bytes[index] == 0x52,
                       index + 1 >= bytes.count || !Self.isRegular(bytes[index + 1]) {
                        index += 1
                        return .reference(PDFRef(n, g))
                    }
                }
                index = save
            }
            if case .real = num, index == start { throw PDFParseError.malformedNumber("") }
            return num
        }

        let kw = parseKeyword() ?? ""
        switch kw {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default:
            throw PDFParseError.unsupportedKeyword(kw, offset: index)
        }
    }

    // MARK: 数字

    mutating func parseNumber() throws -> PDFValue {
        skipWhiteAndComments()
        let start = index
        var seenDot = false
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        while index < bytes.count {
            let b = bytes[index]
            if b == 0x2E {
                if seenDot { break }
                seenDot = true
                index += 1
            } else if b >= 0x30 && b <= 0x39 {
                index += 1
            } else {
                break
            }
        }
        // PDF 里偶尔出现 "1.2.3" 这类脏数据，取到第一个非法点为止
        guard index > start else {
            // 游标已在末尾（例如引用预读 /Length 缺失）时不能读 bytes[start]
            guard start < bytes.count else { throw PDFParseError.unexpectedEnd(offset: start) }
            throw PDFParseError.unexpectedByte(bytes[start], offset: start)
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if seenDot {
            guard let d = Double(text) else { throw PDFParseError.malformedNumber(text) }
            return .real(d)
        }
        guard let i = Int(text) else {
            // 超出 Int 范围时退化为实数，不失败
            guard let d = Double(text) else { throw PDFParseError.malformedNumber(text) }
            return .real(d)
        }
        return .int(i)
    }

    // MARK: 名称

    mutating func parseName() throws -> String {
        guard index < bytes.count, bytes[index] == 0x2F else {
            throw PDFParseError.malformedName(offset: index)
        }
        index += 1
        var raw: [UInt8] = []
        while index < bytes.count {
            let b = bytes[index]
            guard Self.isRegular(b) else { break }
            raw.append(b)
            index += 1
        }
        // #XX 解码
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            if raw[i] == 0x23, i + 2 < raw.count,
               let hi = hexValue(raw[i + 1]), let lo = hexValue(raw[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(raw[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    // MARK: 字符串

    mutating func parseHexString() throws -> Data {
        index += 1 // '<'
        var nibbles: [UInt8] = []
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            if b == 0x3E { break }
            if Self.isWhite(b) { continue }
            guard let v = hexValue(b) else { throw PDFParseError.malformedHexString(offset: index - 1) }
            nibbles.append(v)
            if index >= bytes.count { throw PDFParseError.malformedHexString(offset: index) }
        }
        if nibbles.count % 2 == 1 { nibbles.append(0) }
        var out = Data(capacity: nibbles.count / 2)
        var i = 0
        while i < nibbles.count {
            out.append(nibbles[i] << 4 | nibbles[i + 1])
            i += 2
        }
        return out
    }

    mutating func parseLiteralString() throws -> Data {
        index += 1 // '('
        var out = Data()
        var depth = 1
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            if b == 0x5C { // 反斜杠转义
                guard index < bytes.count else { break }
                let e = bytes[index]
                index += 1
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x28: out.append(0x28)
                case 0x29: out.append(0x29)
                case 0x5C: out.append(0x5C)
                case 0x0D:
                    // 续行：\ 后跟 CR 或 CRLF
                    if index < bytes.count && bytes[index] == 0x0A { index += 1 }
                case 0x0A:
                    break // 续行
                case 0x30...0x37:
                    // 最多三位八进制
                    var v = Int(e - 0x30)
                    var n = 1
                    while n < 3, index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x37 {
                        v = v * 8 + Int(bytes[index] - 0x30)
                        index += 1
                        n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                default:
                    out.append(e)
                }
                continue
            }
            if b == 0x28 {
                depth += 1
                out.append(b)
                continue
            }
            if b == 0x29 {
                depth -= 1
                if depth == 0 { break }
                out.append(b)
                continue
            }
            out.append(b)
        }
        return out
    }

    // MARK: 数组 / 字典 / 流

    mutating func parseArray(resolveLength: ((PDFRef) -> Int?)?) throws -> PDFValue {
        index += 1 // '['
        var items: [PDFValue] = []
        while true {
            skipWhiteAndComments()
            guard index < bytes.count else { throw PDFParseError.unexpectedEnd(offset: index) }
            if bytes[index] == 0x5D {
                index += 1
                break
            }
            items.append(try parseValue(resolveLength: resolveLength))
        }
        return .array(items)
    }

    mutating func parseDictionaryOrStream(resolveLength: ((PDFRef) -> Int?)?) throws -> PDFValue {
        index += 2 // '<<'
        var dict: [String: PDFValue] = [:]
        while true {
            skipWhiteAndComments()
            guard index < bytes.count else { throw PDFParseError.unexpectedEnd(offset: index) }
            if bytes[index] == 0x3E {
                index += 1
                if index < bytes.count && bytes[index] == 0x3E { index += 1 }
                break
            }
            guard bytes[index] == 0x2F else {
                throw PDFParseError.dictionaryKeyNotName(offset: index)
            }
            let key = try parseName()
            let value = try parseValue(resolveLength: resolveLength)
            dict[key] = value
        }

        // 后面紧跟 stream 才是流对象
        let save = index
        skipWhiteAndComments()
        if index + 6 <= bytes.count,
           String(decoding: bytes[index..<index + 6], as: UTF8.self).hasPrefix("stream") {
            index += 6
            // 跳过 stream 后的行尾（CRLF / LF / CR）
            if index < bytes.count && bytes[index] == 0x0D { index += 1 }
            if index < bytes.count && bytes[index] == 0x0A { index += 1 }
            let start = index

            var length: Int? = dict["Length"]?.intValue
            if length == nil, case .reference(let r)? = dict["Length"] {
                length = resolveLength?(r)
            }
            let end: Int
            if let len = length, len >= 0, start + len <= bytes.count {
                end = start + len
            } else {
                // /Length 不可用：退化为找 endstream（容错路径，真实 PDF 里偶见）
                end = findEndStream(from: start)
            }
            let raw = Data(bytes[start..<min(end, bytes.count)])
            index = min(end, bytes.count)
            // 跳过后面的 endstream
            skipWhiteAndComments()
            if index + 9 <= bytes.count,
               String(decoding: bytes[index..<index + 9], as: UTF8.self) == "endstream" {
                index += 9
            }
            return .stream(PDFStream(dictionary: dict, raw: raw))
        }
        index = save
        return .dictionary(dict)
    }

    func findEndStream(from start: Int) -> Int {
        let needle = Array("endstream".utf8)
        var i = start
        while i + needle.count <= bytes.count {
            if bytes[i] == needle[0] {
                var match = true
                for k in 1..<needle.count where bytes[i + k] != needle[k] {
                    match = false
                    break
                }
                if match {
                    // 回退掉 endstream 前的 EOL
                    var e = i
                    if e > start && bytes[e - 1] == 0x0A { e -= 1 }
                    if e > start && bytes[e - 1] == 0x0D { e -= 1 }
                    return e
                }
            }
            i += 1
        }
        return bytes.count
    }
}
