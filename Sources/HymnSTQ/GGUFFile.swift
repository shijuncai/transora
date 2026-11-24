import Foundation

// MARK: - GGUF v3 读取器（G1 / G2 阶段）
//
// 只依赖 Foundation，运行时零外部依赖。文件用 Data(.mappedIfSafe) 只读 mmap，
// 与 D-1 的 SafeTensorsFile / WeightCache 同思路，不把 440 MB 权重复制进堆。
// 格式依据：GGUF v3 官方规范 + 本地 AngelSlim GGUF 头部实证（见 Reports/model-migration-plan.md）。
// ⚠️ 张量类型编号用的是该 checkpoint 生成时的 llama.cpp PR #22836 **早期枚举**：
//    type 42 = STQ1_0（当前 mainline 已改为 43），type 14 = Q6_K，type 0 = F32。

public struct GGUFTensorInfo: Sendable, Equatable {
    public let name: String
    /// ggml 维度顺序 [ne0, ne1, ...]；本模型中 ne0 = in_features, ne1 = out_features。
    public let dimensions: [Int]
    public let type: UInt32
    /// 相对 data 区起点的字节偏移。
    public let offset: Int
    public let elementCount: Int

    public var inFeatures: Int { dimensions.first ?? 0 }
    public var outFeatures: Int { dimensions.count > 1 ? dimensions[1] : 1 }
}

public enum GGUFMetadataValue: Sendable {
    case uint(UInt64)
    case int(Int64)
    case float(Double)
    case boolean(Bool)
    case string(String)
    case array(elementType: UInt32, count: Int, sample: [String])
    case other(UInt32)

    public var uintValue: UInt64? { if case .uint(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var doubleValue: Double? {
        if case .float(let v) = self { return v }
        if case .uint(let v) = self { return Double(v) }
        return nil
    }
    public var arrayCount: Int? { if case .array(_, let n, _) = self { return n }; return nil }
}

public enum GGUFError: Error, Sendable, CustomStringConvertible {
    case badMagic(String)
    case truncated(String)
    case unsupportedVersion(UInt32)
    case unsupportedValueType(UInt32)
    case tensorNotFound(String)
    case unsupportedTensorType(String, UInt32)
    case misaligned(String)

    public var description: String {
        switch self {
        case .badMagic(let s): return "GGUF magic 不正确: \(s)"
        case .truncated(let s): return "GGUF 数据截断: \(s)"
        case .unsupportedVersion(let v): return "不支持的 GGUF 版本: \(v)"
        case .unsupportedValueType(let t): return "不支持的 metadata 类型: \(t)"
        case .tensorNotFound(let n): return "张量不存在: \(n)"
        case .unsupportedTensorType(let n, let t): return "张量 \(n) 类型 \(t) 暂无解码实现"
        case .misaligned(let s): return "GGUF 对齐异常: \(s)"
        }
    }
}

private struct GGUFReader {
    let bytes: UnsafeRawBufferPointer
    var offset: Int = 4  // 跳过已校验的 magic

    mutating func u8() throws -> UInt8 {
        guard offset + 1 <= bytes.count else { throw GGUFError.truncated("u8 @\(offset)") }
        let v = bytes[offset]; offset += 1; return v
    }
    mutating func u16() throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw GGUFError.truncated("u16 @\(offset)") }
        let v = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        offset += 2; return v
    }
    mutating func u32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw GGUFError.truncated("u32 @\(offset)") }
        let v = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4; return v
    }
    mutating func u64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw GGUFError.truncated("u64 @\(offset)") }
        let v = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8; return v
    }
    mutating func string() throws -> String {
        let n = try u64()
        guard n <= UInt64(bytes.count - offset) else { throw GGUFError.truncated("string len \(n) @\(offset)") }
        let start = bytes.baseAddress!.advanced(by: offset)
        let buf = UnsafeRawBufferPointer(start: start, count: Int(n))
        offset += Int(n)
        return String(decoding: buf, as: UTF8.self)
    }
    mutating func value(_ t: UInt32) throws -> GGUFMetadataValue {
        switch t {
        case 0:  return .uint(UInt64(try u8()))
        case 1:  return .int(Int64(Int8(bitPattern: try u8())))
        case 2:  return .uint(UInt64(try u16()))
        case 3:  return .int(Int64(Int16(bitPattern: try u16())))
        case 4:  return .uint(UInt64(try u32()))
        case 5:  return .int(Int64(Int32(bitPattern: try u32())))
        case 6:  return .float(Double(Float(bitPattern: try u32())))
        case 7:  return .boolean((try u8()) != 0)
        case 8:  return .string(try string())
        case 9:
            let et = try u32()
            let n = try u64()
            var sample: [String] = []
            for i in 0..<n {
                let v = try value(et)
                if i < 3, case .string(let s) = v { sample.append(s) }
            }
            return .array(elementType: et, count: Int(n), sample: sample)
        case 10: return .uint(try u64())
        case 11: return .int(Int64(bitPattern: try u64()))
        case 12: return .float(Double(bitPattern: try u64()))
        default: throw GGUFError.unsupportedValueType(t)
        }
    }
    mutating func skip() {}
}

public final class GGUFFile: @unchecked Sendable {
    public let url: URL
    public let fileSize: Int
    public let version: UInt32
    public let metadata: [String: GGUFMetadataValue]
    public let tensors: [GGUFTensorInfo]
    /// metadata + tensor-info 区结束后的对齐起点（张量 offset 均相对此地址）。
    public let dataStart: Int
    public let headerEnd: Int

    private let data: Data
    private let index: [String: GGUFTensorInfo]

    private struct Parsed {
        let version: UInt32
        let metadata: [String: GGUFMetadataValue]
        let tensors: [GGUFTensorInfo]
        let headerEnd: Int
        let dataStart: Int
    }

    public init(url: URL) throws {
        self.url = url
        let mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.data = mapped
        self.fileSize = mapped.count

        let parsed: Parsed = try mapped.withUnsafeBytes { raw -> Parsed in
            guard raw.count >= 4 else { throw GGUFError.truncated("header") }
            let magic = String(decoding: raw[0..<4], as: UTF8.self)
            guard magic == "GGUF" else { throw GGUFError.badMagic(magic) }

            var r = GGUFReader(bytes: raw)
            let version = try r.u32()
            guard version == 3 else { throw GGUFError.unsupportedVersion(version) }
            let tensorCount = try r.u64()
            let kvCount = try r.u64()

            var metadata: [String: GGUFMetadataValue] = [:]
            for _ in 0..<kvCount {
                let key = try r.string()
                let t = try r.u32()
                metadata[key] = try r.value(t)
            }

            var tensors: [GGUFTensorInfo] = []
            tensors.reserveCapacity(Int(tensorCount))
            for _ in 0..<tensorCount {
                let name = try r.string()
                let nd = try r.u32()
                var dims: [Int] = []
                var elements = 1
                for _ in 0..<nd {
                    let d = try r.u64()
                    dims.append(Int(d))
                    elements *= Int(d)
                }
                let type = try r.u32()
                let off = try r.u64()
                tensors.append(GGUFTensorInfo(
                    name: name, dimensions: dims, type: type,
                    offset: Int(off), elementCount: elements))
            }

            let headerEnd = r.offset
            let alignment = Int(metadata["general.alignment"]?.uintValue ?? 32)
            let align = max(1, alignment)
            let dataStart = ((headerEnd + align - 1) / align) * align
            return Parsed(version: version, metadata: metadata, tensors: tensors,
                          headerEnd: headerEnd, dataStart: dataStart)
        }

        self.version = parsed.version
        self.metadata = parsed.metadata
        self.tensors = parsed.tensors
        self.headerEnd = parsed.headerEnd
        self.dataStart = parsed.dataStart
        var idx: [String: GGUFTensorInfo] = [:]
        for t in parsed.tensors { idx[t.name] = t }
        self.index = idx
    }

    public func tensor(named name: String) -> GGUFTensorInfo? { index[name] }

    public func metadataString(_ key: String) -> String? { metadata[key]?.stringValue }
    public func metadataUInt(_ key: String) -> UInt64? { metadata[key]?.uintValue }

    /// 该张量在文件中占用的字节数（按已知类型的 block 结构计算）。
    public func byteCount(for info: GGUFTensorInfo) throws -> Int {
        switch info.type {
        case 0:  return info.elementCount * 4                       // F32
        case 14: return (info.elementCount / 256) * 210            // Q6_K: 210 B / 256
        case 42: return (info.elementCount / 256) * 42             // STQ1_0: 42 B / 256
        default: throw GGUFError.unsupportedTensorType(info.name, info.type)
        }
    }

    /// 只读访问某个张量的原始字节（mmap 零拷贝，不复制整个张量）。
    public func withBytes<T>(
        for name: String,
        _ body: (UnsafeRawBufferPointer) throws -> T
    ) throws -> T {
        guard let info = index[name] else { throw GGUFError.tensorNotFound(name) }
        let count = try byteCount(for: info)
        let start = dataStart + info.offset
        guard start >= 0, start + count <= data.count else {
            throw GGUFError.truncated("tensor \(name) [\(start)..\(start + count)] vs \(data.count)")
        }
        return try data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: start)
            return try body(UnsafeRawBufferPointer(start: ptr, count: count))
        }
    }

    public func typeHistogram() -> [UInt32: Int] {
        var h: [UInt32: Int] = [:]
        for t in tensors { h[t.type, default: 0] += 1 }
        return h
    }
}
