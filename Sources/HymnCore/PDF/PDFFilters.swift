import Foundation
import Compression

/// PDF 流过滤器。
///
/// 只用系统 Compression 框架，不链接 libz——注意 Apple 的 `COMPRESSION_ZLIB`
/// 输出的是**裸 deflate（RFC 1951）**，而 PDF 的 FlateDecode 要求 zlib 包装
/// （RFC 1950，两字节头 + 尾部 adler32）。所以解码时要试两种入口，编码时自己包。
public enum PDFFilters {
    public enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case inflateFailed
        case predictorFailed(String)

        public var description: String {
            switch self {
            case .unsupported(let f): return "不支持的过滤器 \(f)"
            case .inflateFailed: return "Flate 解压失败"
            case .predictorFailed(let m): return "预测器失败 \(m)"
            }
        }
    }

    // MARK: - 入口

    /// 按 /Filter 与 /DecodeParms 逐层解码。图像类过滤器（DCT/JPX/CCITT/JBIG2）
    /// 原样返回——我们不解码图片，也不需要解码。
    public static func decode(_ raw: Data, dictionary: [String: PDFValue]) throws -> Data {
        let filters = filterList(dictionary)
        var data = raw
        for (i, name) in filters.enumerated() {
            let parms = decodeParms(dictionary, index: i)
            switch name {
            case "FlateDecode", "Fl":
                var out = try inflate(data)
                out = try applyPredictor(out, parms: parms)
                data = out
            case "ASCIIHexDecode", "AHx":
                data = try asciiHexDecode(data)
            case "ASCII85Decode", "A85":
                data = try ascii85Decode(data)
            case "RunLengthDecode", "RL":
                data = try runLengthDecode(data)
            case "LZWDecode", "LZW":
                var out = try lzwDecode(data, earlyChange: parms?["EarlyChange"]?.intValue ?? 1)
                out = try applyPredictor(out, parms: parms)
                data = out
            case "Crypt":
                throw Failure.unsupported(name) // 加密文档在 Document 层就拒绝
            case "DCTDecode", "DCT", "JPXDecode", "CCITTFaxDecode", "CCF", "JBIG2Decode":
                return data
            default:
                throw Failure.unsupported(name)
            }
        }
        return data
    }

    static func filterList(_ dict: [String: PDFValue]) -> [String] {
        switch dict["Filter"] {
        case .name(let n): return [n]
        case .array(let items): return items.compactMap(\.nameValue)
        default: return []
        }
    }

    static func decodeParms(_ dict: [String: PDFValue], index: Int) -> [String: PDFValue]? {
        switch dict["DecodeParms"] ?? dict["DP"] {
        case .dictionary(let d): return d
        case .array(let items):
            guard index < items.count else { return nil }
            return items[index].dictionaryValue
        default: return nil
        }
    }

    // MARK: - Flate

    public static func inflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let bytes = [UInt8](data)

        // 按 RFC 1950 判断是不是 zlib 包装：CM 必须是 8，且 (CMF*256+FLG) % 31 == 0。
        // 不能只看首字节是不是 0x78——裸 deflate 完全可能恰好以 0x78 开头。
        if isZlibWrapped(bytes) {
            let hasPresetDictionary = (bytes[1] & 0x20) != 0
            let skip = hasPresetDictionary ? 6 : 2
            if bytes.count > skip, let out = inflateRaw(Data(bytes[skip...])), !out.isEmpty {
                // 只要去了头能解出非空内容，就采信 zlib 解释。
                // 注意：不能再退回「整段当裸 deflate」——那会把 0x78 头当成
                // stored block 解出一堆垃圾，且长度非零、不会报错。
                return out
            }
        }
        if let raw = inflateRaw(data) { return raw }
        throw Failure.inflateFailed
    }

    static func isZlibWrapped(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        let cmf = Int(bytes[0])
        let flg = Int(bytes[1])
        return (cmf & 0x0F) == 8 && (cmf << 8 | flg) % 31 == 0
    }

    static func trailingAdler(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 4 else { return 0 }
        let n = bytes.count
        return (UInt32(bytes[n - 4]) << 24) | (UInt32(bytes[n - 3]) << 16)
            | (UInt32(bytes[n - 2]) << 8) | UInt32(bytes[n - 1])
    }

    /// 解裸 deflate。
    ///
    /// 两个坑都踩过：
    /// 1) `compression_decode_buffer` 在缓冲不够时**可能返回一个非零的、被截断的长度**
    ///    而不是 0（实测某些数据下如此），所以「返回值 == 容量」必须当作截断重试，
    ///    否则 xref 流会被悄悄截断，表现为「页数为 0」这种极难定位的症状。
    /// 2) 数据非法时它返回 0，只能靠放大缓冲区分，所以要封顶次数。
    static func inflateRaw(_ data: Data) -> Data? {
        let input = [UInt8](data)
        guard !input.isEmpty else { return Data() }
        var capacity = max(64 * 1024, input.count * 8)
        let hardCap = 256 * 1024 * 1024
        var attempts = 0
        while capacity <= hardCap && attempts < 9 {
            attempts += 1
            var out = [UInt8](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { src -> Int in
                guard let srcBase = src.baseAddress else { return 0 }
                return out.withUnsafeMutableBufferPointer { dst -> Int in
                    guard let dstBase = dst.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase, capacity, srcBase, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity {
                return Data(out[0..<written])
            }
            // written == 0（非法/不适配）或 written == capacity（可能被截断）→ 扩容重试
            capacity *= 4
        }
        return nil
    }

    /// 产出 zlib 包装的 deflate（0x78 0x9C + 裸 deflate + adler32）。
    public static func deflate(_ data: Data) -> Data {
        let input = [UInt8](data)
        guard !input.isEmpty else {
            return Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        }
        var capacity = max(64 * 1024, input.count + input.count / 2 + 64)
        var compressed: [UInt8]?
        var attempts = 0
        while attempts < 4 {
            attempts += 1
            var out = [UInt8](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { src -> Int in
                guard let srcBase = src.baseAddress else { return 0 }
                return out.withUnsafeMutableBufferPointer { dst -> Int in
                    guard let dstBase = dst.baseAddress else { return 0 }
                    return compression_encode_buffer(
                        dstBase, capacity, srcBase, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                compressed = Array(out[0..<written])
                break
            }
            capacity *= 4
        }
        guard let compressedBody = compressed else { return data }
        // 压不小就不压（PDF 允许未压缩流），避免写出比原文更大的数据
        if compressedBody.count >= input.count { return data }
        // 万一某个系统版本直接给了 zlib 包装，就原样返回
        if isZlibWrapped(compressedBody) { return Data(compressedBody) }
        var out = Data([0x78, 0x9C])
        out.append(contentsOf: compressedBody)
        let adler = adler32(input)
        out.append(UInt8((adler >> 24) & 0xFF))
        out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF))
        out.append(UInt8(adler & 0xFF))
        return out
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: - 预测器（PNG / TIFF）

    public static func applyPredictor(_ data: Data, parms: [String: PDFValue]?) throws -> Data {
        let predictor = parms?["Predictor"]?.intValue ?? 1
        guard predictor > 1 else { return data }
        let colors = max(1, parms?["Colors"]?.intValue ?? 1)
        let bpc = max(1, parms?["BitsPerComponent"]?.intValue ?? 8)
        let columns = max(1, parms?["Columns"]?.intValue ?? 1)
        let bytesPerPixel = max(1, (colors * bpc + 7) / 8)
        let rowLength = (colors * bpc * columns + 7) / 8

        if predictor == 2 {
            return tiffPredictor(data, rowLength: rowLength, bytesPerPixel: bytesPerPixel, bpc: bpc, colors: colors)
        }
        guard predictor >= 10 else { return data }

        let input = [UInt8](data)
        let stride = rowLength + 1
        guard stride > 0, input.count >= stride else { return data }
        let rows = input.count / stride
        var out = [UInt8](repeating: 0, count: rows * rowLength)
        var prev = [UInt8](repeating: 0, count: rowLength)
        for r in 0..<rows {
            let base = r * stride
            let type = input[base]
            let rowStart = base + 1
            var cur = [UInt8](repeating: 0, count: rowLength)
            for i in 0..<rowLength {
                let raw = input[rowStart + i]
                let left: UInt8 = i >= bytesPerPixel ? cur[i - bytesPerPixel] : 0
                let up: UInt8 = prev[i]
                let upLeft: UInt8 = i >= bytesPerPixel ? prev[i - bytesPerPixel] : 0
                switch type {
                case 0: cur[i] = raw
                case 1: cur[i] = raw &+ left
                case 2: cur[i] = raw &+ up
                case 3: cur[i] = raw &+ UInt8((Int(left) + Int(up)) / 2)
                case 4: cur[i] = raw &+ paeth(left, up, upLeft)
                default: throw Failure.predictorFailed("未知 PNG 行过滤器 \(type)")
                }
            }
            out.replaceSubrange((r * rowLength)..<((r + 1) * rowLength), with: cur)
            prev = cur
        }
        return Data(out)
    }

    static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a))
        let pb = abs(p - Int(b))
        let pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    static func tiffPredictor(
        _ data: Data, rowLength: Int, bytesPerPixel: Int, bpc: Int, colors: Int
    ) -> Data {
        guard bpc == 8 else { return data }
        let input = [UInt8](data)
        guard rowLength > 0, input.count % rowLength == 0 else { return data }
        var out = input
        let rows = input.count / rowLength
        for r in 0..<rows {
            let base = r * rowLength
            var i = bytesPerPixel
            while i < rowLength {
                out[base + i] = out[base + i] &+ out[base + i - bytesPerPixel]
                i += 1
            }
        }
        return Data(out)
    }

    // MARK: - ASCIIHex

    public static func asciiHexDecode(_ data: Data) throws -> Data {
        var nibbles: [UInt8] = []
        for b in data {
            if b == 0x3E { break } // '>'
            if PDFParser.isWhite(b) { continue }
            let v: UInt8
            switch b {
            case 0x30...0x39: v = b - 0x30
            case 0x41...0x46: v = b - 0x41 + 10
            case 0x61...0x66: v = b - 0x61 + 10
            default: continue
            }
            nibbles.append(v)
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

    // MARK: - ASCII85

    public static func ascii85Decode(_ data: Data) throws -> Data {
        var out = Data()
        var group: [UInt32] = []
        var i = 0
        let bytes = [UInt8](data)
        // 允许 <~ 前缀（PDF 里少见但对 PostScript 兼容文件有好处）
        if bytes.count >= 2 && bytes[0] == 0x3C && bytes[1] == 0x7E { i = 2 }
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            if b == 0x7E { break } // '~>'
            if PDFParser.isWhite(b) { continue }
            if b == 0x7A && group.isEmpty { // 'z'
                out.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            guard b >= 0x21 && b <= 0x75 else { continue }
            group.append(UInt32(b - 0x21))
            if group.count == 5 {
                var value: UInt32 = 0
                for g in group { value = value * 85 + g }
                out.append(UInt8((value >> 24) & 0xFF))
                out.append(UInt8((value >> 16) & 0xFF))
                out.append(UInt8((value >> 8) & 0xFF))
                out.append(UInt8(value & 0xFF))
                group.removeAll(keepingCapacity: true)
            }
        }
        if !group.isEmpty {
            let n = group.count
            while group.count < 5 { group.append(84) } // 'u'
            var value: UInt32 = 0
            for g in group { value = value * 85 + g }
            let full: [UInt8] = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
            out.append(contentsOf: full[0..<(n - 1)])
        }
        return out
    }

    // MARK: - RunLength

    public static func runLengthDecode(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        var out = Data()
        var i = 0
        while i < input.count {
            let length = input[i]
            i += 1
            if length == 128 { break }
            if length < 128 {
                let count = Int(length) + 1
                guard i + count <= input.count else { break }
                out.append(contentsOf: input[i..<(i + count)])
                i += count
            } else {
                guard i < input.count else { break }
                let byte = input[i]
                i += 1
                out.append(contentsOf: Array(repeating: byte, count: 257 - Int(length)))
            }
        }
        return out
    }

    // MARK: - LZW

    public static func lzwDecode(_ data: Data, earlyChange: Int) throws -> Data {
        let input = [UInt8](data)
        var out = Data()
        var dictionary: [[UInt8]] = (0..<256).map { [UInt8($0)] }
        dictionary.append([]) // 256 clear
        dictionary.append([]) // 257 eod
        var codeWidth = 9
        var previous: [UInt8]?
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var i = 0

        while i < input.count || bitCount >= codeWidth {
            while bitCount < codeWidth && i < input.count {
                bitBuffer = (bitBuffer << 8) | UInt32(input[i])
                i += 1
                bitCount += 8
            }
            if bitCount < codeWidth { break }
            let code = Int((bitBuffer >> UInt32(bitCount - codeWidth)) & ((1 << codeWidth) - 1))
            bitCount -= codeWidth

            if code == 256 {
                dictionary = (0..<256).map { [UInt8($0)] }
                dictionary.append([])
                dictionary.append([])
                codeWidth = 9
                previous = nil
                continue
            }
            if code == 257 { break }

            var entry: [UInt8]
            if code < dictionary.count, !dictionary[code].isEmpty {
                entry = dictionary[code]
            } else if let prev = previous {
                entry = prev + [prev[0]]
            } else {
                throw Failure.unsupported("LZW 码流非法")
            }
            out.append(contentsOf: entry)
            if let prev = previous {
                dictionary.append(prev + [entry[0]])
            }
            previous = entry
            let adjust = earlyChange != 0 ? 1 : 0
            if dictionary.count + adjust >= (1 << codeWidth) && codeWidth < 12 {
                codeWidth += 1
            }
        }
        return out
    }
}
