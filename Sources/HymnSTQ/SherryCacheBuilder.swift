import Foundation
import Darwin

// MARK: - GGUF → fp16 权重缓存（G1 / G5 阶段）
//
// 把 AngelSlim 1.25bit GGUF 的 224 个 STQ1_0 线性层 + 1 个 Q6_K embedding +
// 129 个 F32 norm 解码为 fp16，写出与 D-1 `WeightCache` **完全同构**的
// `[8B headerLen][JSON header][页对齐 padding][fp16 张量]` 文件。
// 这样现有 `HymnModel` 的 32 层 Metal/MPS forward 可以原样复用，无需重写算子。
//
// ⚠️ 如实标注：这是「GGUF 权重驱动的推理」，但权重在运行时展开为 3.58 GB fp16
// mmap 缓存，**不是 1.31 bpw 常驻推理**。常驻 GEMV 优化属于后续阶段。
// 权重格式永远是 Sherry STQ1_0 1.3125 bpw，**不是 LUT4、不是 affine INT4**。

public struct SherryCacheBuildReport: Sendable, CustomStringConvertible {
    public let destination: String
    public let tensorCount: Int
    public let stqTensorCount: Int
    public let q6TensorCount: Int
    public let f32TensorCount: Int
    public let outputBytes: Int
    public let elapsedMs: Double

    public var description: String {
        "tensors=\(tensorCount) (stq=\(stqTensorCount) q6=\(q6TensorCount) f32=\(f32TensorCount)) "
            + "bytes=\(outputBytes) elapsed=\(String(format: "%.1f", elapsedMs)) ms"
    }
}

public enum SherryCacheError: Error, Sendable, CustomStringConvertible {
    case unmappedTensor(String)
    case unexpectedType(String, UInt32)
    case unaligned(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unmappedTensor(let n): return "无 HF 名称映射: \(n)"
        case .unexpectedType(let n, let t): return "张量 \(n) 类型 \(t) 未预期"
        case .unaligned(let n): return "张量 \(n) 字节数未按 16 对齐"
        case .writeFailed(let s): return "缓存写入失败: \(s)"
        }
    }
}

// 与 HymnNative 的 WeightCacheHeader / CachedTensor 字段名逐一对应，
// 用本地 Codable 结构生成同构 JSON，避免跨模块访问 internal memberwise init。
private struct CacheEntry: Codable {
    let name: String
    let shape: [Int]
    let offset: Int
    let byteCount: Int
    let kind: String
}
private struct CacheHeader: Codable {
    let version: Int
    let format: String
    let sourceFile: String
    let sourceBytes: Int
    let dataStart: Int
    let dataBytes: Int
    let tensors: [CacheEntry]
}

public enum SherryCacheBuilder {

    /// GGUF(llama.cpp 风格) 张量名 → HymnModel 使用的 HF 风格张量名。
    public static func hfName(_ ggufName: String) -> String? {
        if ggufName == "token_embd.weight" { return "model.embed_tokens" }
        if ggufName == "output_norm.weight" { return "model.norm.weight" }
        let parts = ggufName.split(separator: ".")
        guard parts.count == 4, parts[0] == "blk", parts[3] == "weight",
              let layer = Int(parts[1]) else { return nil }
        let p = "model.layers.\(layer)"
        switch parts[2] {
        case "attn_norm":   return "\(p).input_layernorm.weight"
        case "ffn_norm":    return "\(p).post_attention_layernorm.weight"
        case "attn_q_norm": return "\(p).self_attn.query_layernorm.weight"
        case "attn_k_norm": return "\(p).self_attn.key_layernorm.weight"
        case "attn_q":      return "\(p).self_attn.q_proj"
        case "attn_k":      return "\(p).self_attn.k_proj"
        case "attn_v":      return "\(p).self_attn.v_proj"
        case "attn_output": return "\(p).self_attn.o_proj"
        case "ffn_gate":    return "\(p).mlp.gate_proj"
        case "ffn_up":      return "\(p).mlp.up_proj"
        case "ffn_down":    return "\(p).mlp.down_proj"
        default: return nil
        }
    }

    public struct Plan: Sendable {
        let ggufName: String
        let hfName: String
        let info: GGUFTensorInfo
        let shape: [Int]
        let kind: String
    }

    public static func buildPlan(_ gguf: GGUFFile) throws -> [Plan] {
        var plans: [Plan] = []
        for t in gguf.tensors {
            guard let hf = hfName(t.name) else {
                throw SherryCacheError.unmappedTensor(t.name)
            }
            guard t.type == 0 || t.type == 14 || t.type == 42 else {
                throw SherryCacheError.unexpectedType(t.name, t.type)
            }
            let shape = t.dimensions.count >= 2
                ? [t.dimensions[1], t.dimensions[0]]   // ggml [ne0=in, ne1=out] → [out, in]
                : t.dimensions
            let kind = t.type == 42 ? "stq1_0" : (t.type == 14 ? "q6_k" : "f32")
            plans.append(Plan(ggufName: t.name, hfName: hf, info: t, shape: shape, kind: kind))
        }
        return plans
    }

    /// 生成 fp16 缓存。逐张量 / 逐行块流式写入，避免 1 GB 级中间数组。
    public static func build(gguf: GGUFFile, destination: URL) throws -> SherryCacheBuildReport {
        let start = DispatchTime.now().uptimeNanoseconds
        let plans = try buildPlan(gguf)

        var entries: [CacheEntry] = []
        var cursor = 0
        for p in plans {
            let bytes = p.info.elementCount * 2
            guard bytes % 16 == 0 else { throw SherryCacheError.unaligned(p.ggufName) }
            entries.append(CacheEntry(name: p.hfName, shape: p.shape,
                                      offset: cursor, byteCount: bytes, kind: p.kind))
            cursor += bytes
        }
        let dataBytes = cursor
        let pageSize = Int(getpagesize())

        let probe = CacheHeader(version: 1, format: "fp16-rowmajor",
                                sourceFile: gguf.url.lastPathComponent,
                                sourceBytes: gguf.fileSize, dataStart: 0,
                                dataBytes: dataBytes, tensors: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let probeData = try encoder.encode(probe)
        let dataStart = ((8 + probeData.count + pageSize - 1) / pageSize) * pageSize
        let finalHeader = CacheHeader(version: 1, format: "fp16-rowmajor",
                                      sourceFile: gguf.url.lastPathComponent,
                                      sourceBytes: gguf.fileSize, dataStart: dataStart,
                                      dataBytes: dataBytes, tensors: entries)
        let headerData = try encoder.encode(finalHeader)
        precondition(8 + headerData.count <= dataStart)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw SherryCacheError.writeFailed(destination.path)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var headerLen = UInt64(headerData.count).littleEndian
        handle.write(Data(bytes: &headerLen, count: 8))
        handle.write(headerData)
        if 8 + headerData.count < dataStart {
            handle.write(Data(count: dataStart - 8 - headerData.count))
        }

        var stqCount = 0, q6Count = 0, f32Count = 0
        for p in plans {
            let info = p.info
            try gguf.withBytes(for: p.ggufName) { raw in
                switch info.type {
                case 42:
                    stqCount += 1
                    let blocksPerRow = info.inFeatures / STQ1_0.blockElements
                    let rows = info.outFeatures
                    let chunkRows = 64
                    for rowStart in stride(from: 0, to: rows, by: chunkRows) {
                        let nRows = min(chunkRows, rows - rowStart)
                        let nBlocks = nRows * blocksPerRow
                        let byteOffset = rowStart * blocksPerRow * STQ1_0.blockBytes
                        let slice = UnsafeRawBufferPointer(
                            start: raw.baseAddress!.advanced(by: byteOffset),
                            count: nBlocks * STQ1_0.blockBytes)
                        let floats = try STQ1_0.dequantize(slice, blocks: nBlocks)
                        var bits = [UInt16]()
                        bits.reserveCapacity(floats.count)
                        for f in floats { bits.append(Float16(f).bitPattern) }
                        handle.write(Data(bytes: bits, count: bits.count * 2))
                    }
                case 14:
                    q6Count += 1
                    let blocksPerRow = info.inFeatures / Q6_K.blockElements
                    let rows = info.outFeatures
                    let chunkRows = 32
                    for rowStart in stride(from: 0, to: rows, by: chunkRows) {
                        let nRows = min(chunkRows, rows - rowStart)
                        let nBlocks = nRows * blocksPerRow
                        let byteOffset = rowStart * blocksPerRow * Q6_K.blockBytes
                        let slice = UnsafeRawBufferPointer(
                            start: raw.baseAddress!.advanced(by: byteOffset),
                            count: nBlocks * Q6_K.blockBytes)
                        let floats = try Q6_K.dequantize(slice, blocks: nBlocks)
                        var bits = [UInt16]()
                        bits.reserveCapacity(floats.count)
                        for f in floats { bits.append(Float16(f).bitPattern) }
                        handle.write(Data(bytes: bits, count: bits.count * 2))
                    }
                default:
                    f32Count += 1
                    let floats = try GGUF_F32.read(raw, count: info.elementCount)
                    var bits = [UInt16]()
                    bits.reserveCapacity(floats.count)
                    for f in floats { bits.append(Float16(f).bitPattern) }
                    handle.write(Data(bytes: bits, count: bits.count * 2))
                }
            }
        }

        let total = dataStart + dataBytes
        let padded = ((total + pageSize - 1) / pageSize) * pageSize
        if padded > total { handle.write(Data(count: padded - total)) }
        try handle.synchronize()

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return SherryCacheBuildReport(
            destination: destination.path, tensorCount: plans.count,
            stqTensorCount: stqCount, q6TensorCount: q6Count, f32TensorCount: f32Count,
            outputBytes: dataBytes, elapsedMs: elapsed)
    }
}
