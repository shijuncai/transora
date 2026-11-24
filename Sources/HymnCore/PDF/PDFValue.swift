import Foundation

// MARK: - PDF 对象模型
//
// 只做 P0 需要的事：把 PDF 的 8 种基本对象完整表达出来，并且能无损往返
// （字符串保留原始字节，名称解码后保留，流保留原始字节）。
//
// 不在这里做坐标、字体、版面——那是 IL 层的事。这一层唯一的职责是
// 「读得进来、写得出去、字节可查」。

public struct PDFRef: Sendable, Hashable, CustomStringConvertible {
    public var number: Int
    public var generation: Int

    public init(_ number: Int, _ generation: Int = 0) {
        self.number = number
        self.generation = generation
    }

    public var description: String { "\(number) \(generation) R" }
}

public struct PDFStream: Sendable, Equatable {
    public var dictionary: [String: PDFValue]
    /// 解码前的原始字节（已去掉 stream / endstream 与行尾）。
    public var raw: Data

    public init(dictionary: [String: PDFValue], raw: Data) {
        self.dictionary = dictionary
        self.raw = raw
    }
}

public indirect enum PDFValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    /// 字符串保留原始字节，不做 unicode 解释——PDF 的字符串可能是任意编码。
    case string(Data)
    case name(String)
    case array([PDFValue])
    case dictionary([String: PDFValue])
    case reference(PDFRef)
    case stream(PDFStream)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: 取值便捷方法（缺失/类型不符一律 nil，不抛错）

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .real(let v): return Int(v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .real(let v): return v
        default: return nil
        }
    }

    public var nameValue: String? {
        if case .name(let v) = self { return v }
        return nil
    }

    public var arrayValue: [PDFValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var dictionaryValue: [String: PDFValue]? {
        switch self {
        case .dictionary(let v): return v
        case .stream(let s): return s.dictionary
        default: return nil
        }
    }

    public var streamValue: PDFStream? {
        if case .stream(let s) = self { return s }
        return nil
    }

    public subscript(key: String) -> PDFValue? {
        dictionaryValue?[key]
    }
}

// MARK: - 序列化

public enum PDFSerialize {
    /// 把对象写回 PDF 语法。字典顺序不影响语义，按 key 排序保证确定性输出。
    public static func value(_ v: PDFValue) -> Data {
        var out = Data()
        write(v, into: &out)
        return out
    }

    public static func write(_ v: PDFValue, into out: inout Data) {
        switch v {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i):
            out.append(contentsOf: Array(String(i).utf8))
        case .real(let d):
            out.append(contentsOf: Array(formatReal(d).utf8))
        case .string(let data):
            writeString(data, into: &out)
        case .name(let n):
            out.append(0x2F) // '/'
            out.append(contentsOf: Array(encodeName(n).utf8))
        case .array(let items):
            out.append(0x5B) // '['
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                write(item, into: &out)
            }
            out.append(0x5D) // ']'
        case .dictionary(let dict):
            out.append(contentsOf: Array("<<".utf8))
            for key in dict.keys.sorted() {
                out.append(0x20)
                out.append(0x2F)
                out.append(contentsOf: Array(encodeName(key).utf8))
                out.append(0x20)
                write(dict[key] ?? .null, into: &out)
            }
            out.append(contentsOf: Array(" >>".utf8))
        case .reference(let r):
            out.append(contentsOf: Array("\(r.number) \(r.generation) R".utf8))
        case .stream(let s):
            var dict = s.dictionary
            // 重新计算 /Length，且必须落成直接整数（间接引用会指向旧值）
            dict["Length"] = .int(s.raw.count)
            write(.dictionary(dict), into: &out)
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(s.raw)
            out.append(contentsOf: Array("\nendstream".utf8))
        }
    }

    /// 一律用十六进制字符串：不涉及转义、不涉及编码，任何字节都能原样往返。
    static func writeString(_ data: Data, into out: inout Data) {
        out.append(0x3C) // '<'
        let hex = Array("0123456789ABCDEF".utf8)
        for byte in data {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
        out.append(0x3E) // '>'
    }

    /// 名称里的分隔符与不可打印字节必须转成 #XX，否则重新解析会断。
    static func encodeName(_ name: String) -> String {
        var out = ""
        for byte in Array(name.utf8) {
            let isRegular = byte > 0x20 && byte < 0x7F
                && !"()<>[]{}/%#".utf8.contains(byte)
            if isRegular {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "#%02X", byte)
            }
        }
        return out
    }

    /// PDF 实数不能写科学计数法，也不能有尾随 0。
    static func formatReal(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d))
        }
        var s = String(format: "%.6f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
