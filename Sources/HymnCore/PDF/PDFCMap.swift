import Foundation

/// ToUnicode CMap 解析。
///
/// 这是「读」这一半的关键：PDF 内容流里的字符串是**字形编号**，不是 unicode。
/// 没有 `/ToUnicode` 就拿不到原文——除非猜编码，而猜编码正是各种乱码的来源。
/// 所以这里的策略是：**能拿到就译，拿不到就标记 `untranslatable`，绝不猜**。
///
/// 支持的语法（PDF 32000-1 §9.10.3 的子集）：
///     begincodespacerange … endcodespacerange   码字长度与取值范围
///     beginbfchar … endbfchar                   单个映射
///     beginbfrange … endbfrange                 区间映射（目标可为字符串或数组）
public struct PDFCMap {
    public struct Codespace: Sendable, Equatable {
        public var length: Int
        public var low: UInt32
        public var high: UInt32
    }

    public var name: String?
    public var codespaces: [Codespace] = []
    /// 码字 → unicode 字符串（可能是多个标量，例如连字 "fi"）
    public var mapping: [UInt32: String] = [:]

    public var isEmpty: Bool { mapping.isEmpty }

    /// 该 CMap 允许的码字长度（升序去重）。
    public var codeLengths: [Int] {
        let lengths = Set(codespaces.map(\.length)).sorted()
        return lengths.isEmpty ? [1] : lengths
    }

    public func unicode(for code: UInt32) -> String? { mapping[code] }

    // MARK: - 解码字节串

    /// 按 codespace 把字节串切成码字。
    ///
    /// 现实里 CMap 的 codespace 经常写得不完整（只写 `<0000> <FFFF>` 而实际有 1 字节码），
    /// 所以匹配不上时退化到 `fallbackLength`，而不是直接失败——但会记下来，
    /// 由调用方决定要不要采信（见 `decodeReport`）。
    public func decode(_ bytes: [UInt8], fallbackLength: Int = 2) -> [UInt32] {
        decodeDetailed(bytes, fallbackLength: fallbackLength).codes
    }

    public struct DecodeReport: Sendable {
        public var codes: [UInt32] = []
        /// 有多少字节没能落到任何 codespace 上（>0 说明 CMap 不完整）
        public var unmatchedBytes = 0
    }

    public func decodeDetailed(_ bytes: [UInt8], fallbackLength: Int = 2) -> DecodeReport {
        var report = DecodeReport()
        var i = 0
        let ordered = codeLengths
        while i < bytes.count {
            var matched = false
            for length in ordered where i + length <= bytes.count {
                var value: UInt32 = 0
                for k in 0..<length { value = (value << 8) | UInt32(bytes[i + k]) }
                if codespaces.contains(where: { $0.length == length && value >= $0.low && value <= $0.high }) {
                    report.codes.append(value)
                    i += length
                    matched = true
                    break
                }
            }
            if !matched {
                report.unmatchedBytes += 1
                let take = min(max(1, fallbackLength), bytes.count - i)
                var value: UInt32 = 0
                for k in 0..<take { value = (value << 8) | UInt32(bytes[i + k]) }
                report.codes.append(value)
                i += take
            }
        }
        return report
    }

    // MARK: - 解析

    public enum Failure: Error, CustomStringConvertible {
        case notCMap

        public var description: String {
            switch self {
            case .notCMap: return "不是可识别的 CMap 流"
            }
        }
    }

    enum Token {
        case hex([UInt8])
        case array([[UInt8]])
        case word(String)
        case literal([UInt8])
    }

    public static func parse(_ data: Data) throws -> PDFCMap {
        var cmap = PDFCMap()
        var scanner = Scanner(bytes: [UInt8](data))
        var pending: [Token] = []
        var sawBegin = false

        while let token = scanner.next() {
            guard case .word(let word) = token else {
                pending.append(token)
                if pending.count > 3 { pending.removeFirst() }
                continue
            }
            switch word {
            case "begincmap":
                sawBegin = true
                pending.removeAll()
            case "begincodespacerange", "beginbfchar", "beginbfrange":
                pending.removeAll()
                let kind = word
                while let inner = scanner.next() {
                    if case .word(let end) = inner,
                       end == "endcodespacerange" || end == "endbfchar" || end == "endbfrange" {
                        break
                    }
                    pending.append(inner)

                    switch kind {
                    case "begincodespacerange":
                        // 每两个 hex 组成一段
                        if pending.count == 2, case .hex(let loBytes) = pending[0],
                           case .hex(let hiBytes) = pending[1] {
                            if let lo = beUInt32(loBytes), let hi = beUInt32(hiBytes) {
                                cmap.codespaces.append(
                                    Codespace(length: max(loBytes.count, 1), low: lo, high: hi))
                            }
                            pending.removeAll()
                        }
                    case "beginbfchar":
                        if pending.count == 2, case .hex(let src) = pending[0] {
                            if let code = beUInt32(src) {
                                cmap.mapping[code] = decodeDestination(pending[1])
                            }
                            pending.removeAll()
                        } else if pending.count > 2 {
                            pending.removeFirst()
                        }
                    default:   // begincodespacerange 之外，bfrange 每三个一组
                        if pending.count == 3 {
                            applyRange(&cmap, lo: pending[0], hi: pending[1], dst: pending[2])
                            pending.removeAll()
                        } else if pending.count > 3 {
                            pending.removeFirst()
                        }
                    }
                }
                pending.removeAll()
            case "CMapName":
                // "/CMapName /Adobe-Identity-UCS def" 里名字是下一个 word
                if let next = scanner.peekWord(), !next.hasPrefix("/") == false {
                    cmap.name = next
                }
            default:
                continue
            }
        }
        guard sawBegin || !cmap.mapping.isEmpty else { throw Failure.notCMap }
        return cmap
    }

    static func applyRange(_ cmap: inout PDFCMap, lo: Token, hi: Token, dst: Token) {
        guard case .hex(let loBytes) = lo, case .hex(let hiBytes) = hi,
              let low = beUInt32(loBytes), let high = beUInt32(hiBytes), high >= low,
              high - low <= 0x1_0000
        else { return }

        switch dst {
        case .hex(let dstBytes):
            // 目标字符串逐码递增：只增加最后一个 16 位单元
            let base = dstBytes
            for offset in 0...(high - low) {
                var incremented = base
                if incremented.count >= 2 {
                    let lastIndex = incremented.count - 2
                    let unit = UInt16(incremented[lastIndex]) << 8 | UInt16(incremented[lastIndex + 1])
                    let bumped = unit &+ UInt16(truncatingIfNeeded: offset)
                    incremented[lastIndex] = UInt8((bumped >> 8) & 0xFF)
                    incremented[lastIndex + 1] = UInt8(bumped & 0xFF)
                }
                cmap.mapping[low + offset] = decodeUnicodeBytes(incremented)
            }
        case .array(let items):
            for (offset, item) in items.enumerated() where low + UInt32(offset) <= high {
                cmap.mapping[low + UInt32(offset)] = decodeUnicodeBytes(item)
            }
        default:
            break
        }
    }

    static func decodeDestination(_ token: Token) -> String {
        switch token {
        case .hex(let bytes), .literal(let bytes): return decodeUnicodeBytes(bytes)
        case .array(let items): return items.map(decodeUnicodeBytes).joined()
        case .word: return ""
        }
    }

    /// 目标串按 UTF-16BE 解；只有 1 字节时按 Latin-1 处理（少数生成器这么写）。
    static func decodeUnicodeBytes(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        if bytes.count == 1 { return String(UnicodeScalar(bytes[0])) }
        var units: [UInt16] = []
        var i = 0
        while i + 1 < bytes.count {
            units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        // 末尾落单的字节按 Latin-1 补一个字符，不丢信息
        var text = String(decoding: units, as: UTF16.self)
        if i < bytes.count { text.append(String(UnicodeScalar(bytes[i]))) }
        return text
    }

    static func beUInt32(_ bytes: [UInt8]) -> UInt32? {
        guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
        var value: UInt32 = 0
        for byte in bytes { value = (value << 8) | UInt32(byte) }
        return value
    }

    // MARK: - 词法

    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count {
                let b = bytes[index]
                if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00 {
                    index += 1
                } else if b == 0x25 {   // '%'
                    while index < bytes.count && bytes[index] != 0x0A && bytes[index] != 0x0D {
                        index += 1
                    }
                } else {
                    return
                }
            }
        }

        mutating func peekWord() -> String? {
            let saved = index
            defer { index = saved }
            skipSpace()
            let start = index
            while index < bytes.count, isWordByte(bytes[index]) { index += 1 }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func next() -> Token? {
            skipSpace()
            guard index < bytes.count else { return nil }
            let b = bytes[index]

            if b == 0x3C {   // '<'
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C {
                    // 跳过整个字典（ToUnicode 头部有 << /CIDSystemInfo ... >>）
                    index += 2
                    var depth = 1
                    while index < bytes.count && depth > 0 {
                        if bytes[index] == 0x3C, index + 1 < bytes.count, bytes[index + 1] == 0x3C {
                            depth += 1; index += 2
                        } else if bytes[index] == 0x3E, index + 1 < bytes.count, bytes[index + 1] == 0x3E {
                            depth -= 1; index += 2
                        } else {
                            index += 1
                        }
                    }
                    return .word("<<>>")
                }
                index += 1
                var hex: [UInt8] = []
                var high: UInt8?
                while index < bytes.count && bytes[index] != 0x3E {
                    let c = bytes[index]
                    index += 1
                    guard let nibble = hexNibble(c) else { continue }
                    if let h = high {
                        hex.append(h << 4 | nibble)
                        high = nil
                    } else {
                        high = nibble
                    }
                }
                if index < bytes.count { index += 1 }
                if let h = high { hex.append(h << 4) }   // 奇数位补 0
                return .hex(hex)
            }

            if b == 0x5B {   // '['
                index += 1
                var items: [[UInt8]] = []
                while index < bytes.count && bytes[index] != 0x5D {
                    if let inner = next() {
                        if case .hex(let h) = inner { items.append(h) }
                        if case .literal(let l) = inner { items.append(l) }
                    } else {
                        break
                    }
                }
                if index < bytes.count { index += 1 }
                return .array(items)
            }

            if b == 0x28 {   // '('
                index += 1
                var depth = 1
                var out: [UInt8] = []
                while index < bytes.count && depth > 0 {
                    let c = bytes[index]
                    if c == 0x5C, index + 1 < bytes.count {
                        let n = bytes[index + 1]
                        let mapped: UInt8
                        switch n {
                        case 0x6E: mapped = 0x0A
                        case 0x72: mapped = 0x0D
                        case 0x74: mapped = 0x09
                        case 0x62: mapped = 0x08
                        case 0x66: mapped = 0x0C
                        default: mapped = n
                        }
                        out.append(mapped)
                        index += 2
                    } else if c == 0x28 {
                        depth += 1; out.append(c); index += 1
                    } else if c == 0x29 {
                        depth -= 1
                        if depth > 0 { out.append(c) }
                        index += 1
                    } else {
                        out.append(c); index += 1
                    }
                }
                return .literal(out)
            }

            if isWordByte(b) {
                let start = index
                while index < bytes.count && isWordByte(bytes[index]) { index += 1 }
                return .word(String(decoding: bytes[start..<index], as: UTF8.self))
            }

            index += 1
            return next()
        }

        func isWordByte(_ b: UInt8) -> Bool {
            b > 0x20 && b < 0x7F && b != 0x28 && b != 0x29 && b != 0x3C
                && b != 0x3E && b != 0x5B && b != 0x5D && b != 0x7B && b != 0x7D
                && b != 0x2F && b != 0x25
        }

        func hexNibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
    }
}
