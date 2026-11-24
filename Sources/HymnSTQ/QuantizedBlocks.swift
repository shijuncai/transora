import Foundation
import Darwin

// MARK: - fp16 位模式 → Float（不依赖 Float16 平台可用性，逐位实现）
@inline(__always)
internal func hymnFP16ToFloat(_ h: UInt16) -> Float {
    let sign: Float = (h & 0x8000) != 0 ? -1.0 : 1.0
    let e = Int((h >> 10) & 0x1F)
    let m = UInt32(h & 0x03FF)
    if e == 0 {
        // 次正规：m × 2^-24
        return sign * Float(m) * 0.000000059604644775390625
    }
    if e == 31 { return m == 0 ? sign * Float.infinity : Float.nan }
    // 正规：(1024 + m) × 2^(e-25)
    return sign * Float(1024 + m) * exp2(Float(e - 25))
}

@inline(__always)
internal func hymnReadFP16(_ raw: UnsafeRawBufferPointer, _ byteOffset: Int) -> Float {
    hymnFP16ToFloat(raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self))
}

// MARK: - STQ1_0（Sherry 稀疏三值，1.3125 bpw）
//
// 权威来源：llama.cpp PR #22836 `ggml/src/ggml-common.h` 的 block_stq1_0 / stq1_0_codebook
// 与 `ggml-quants.c` 的 dequantize_row_stq1_0。源码副本见
// research/upstream/stq1_0-reference/pr22836.patch。**未自行编造任何算子**。
//
// 每 256 权重一个 block = 42 B：
//   qs[32]   每 4 权重一个 4-bit codebook slot（低 nibble 在前）
//   sign[8]  每 4 权重一个 1-bit table select
//   d        fp16 整 block scale
// 权重取值 {-d, 0, +d}，每 4 个 lane 恰有 1 个零（3:4 稀疏），32 项码本。
// 位置映射为 stride-16：group g 覆盖 y[(g/16)*64 + (g%16) + p*16], p ∈ 0..3。
public enum STQ1_0: Sendable {
    public static let blockElements = 256
    public static let blockBytes = 42
    public static let ggmlType: UInt32 = 42  // 该 checkpoint 生成时的 PR 早期编号

    /// PR #22836 `stq1_0_codebook[32]`（与第三方 hy-mt2-mlx 的 _CODEBOOK 逐项一致）。
    public static let codebook: [UInt8] = [
        0xA9, 0x89, 0x29, 0x09, 0xA6, 0x86, 0x26, 0x06,
        0x9A, 0x92, 0x1A, 0x12, 0x6A, 0x62, 0x4A, 0x42,
        0x01, 0x21, 0x81, 0xA1, 0x04, 0x24, 0x84, 0xA4,
        0x10, 0x18, 0x90, 0x98, 0x40, 0x48, 0x60, 0x68,
    ]

    /// 解码 `blocks` 个连续 block 为 Float 权重（长度 blocks × 256）。
    public static func dequantize(_ raw: UnsafeRawBufferPointer, blocks: Int) throws -> [Float] {
        guard raw.count >= blocks * blockBytes else {
            throw GGUFError.truncated("STQ1_0 need \(blocks * blockBytes) B, got \(raw.count)")
        }
        var out = [Float](repeating: 0, count: blocks * blockElements)
        let cb = codebook
        for b in 0..<blocks {
            let base = b * blockBytes
            let d = hymnReadFP16(raw, base + 40)
            let outBase = b * blockElements
            for g in 0..<64 {
                let code = (raw[base + g / 2] >> (4 * (g & 1))) & 0x0F
                let sign = (raw[base + 32 + g / 8] >> (g % 8)) & 0x01
                let qpack = cb[(Int(sign) << 4) | Int(code)]
                let chunk = g / 16
                let gloc = g % 16
                let row = chunk * 64 + gloc
                for p in 0..<4 {
                    let q = Int((qpack >> (2 * p)) & 0x03)
                    out[outBase + row + p * 16] = Float(q - 1) * d
                }
            }
        }
        return out
    }

    /// 该张量需要的 block 数（in_features 必须是 256 的倍数）。
    public static func blockCount(elements: Int) throws -> Int {
        guard elements % blockElements == 0 else {
            throw GGUFError.misaligned("STQ1_0 elements=\(elements) 不是 256 的倍数")
        }
        return elements / blockElements
    }
}

// MARK: - Q6_K（标准 ggml k-quant，6.5625 bpw，用于 tied embedding）
//
// 权威来源：llama.cpp `ggml/src/ggml-common.h` block_q6_K 与
// `ggml-quants.c` dequantize_row_q6_K，副本见
// research/upstream/stq1_0-reference/{ggml-common.h,q6k-dequant.c}。
// 每 256 权重 210 B：ql[128] + qh[64] + scales[16] (int8) + d (fp16)。
public enum Q6_K: Sendable {
    public static let blockElements = 256
    public static let blockBytes = 210
    public static let ggmlType: UInt32 = 14

    public static func dequantize(_ raw: UnsafeRawBufferPointer, blocks: Int) throws -> [Float] {
        guard raw.count >= blocks * blockBytes else {
            throw GGUFError.truncated("Q6_K need \(blocks * blockBytes) B, got \(raw.count)")
        }
        var out = [Float](repeating: 0, count: blocks * blockElements)
        for b in 0..<blocks {
            let base = b * blockBytes
            let d = hymnReadFP16(raw, base + 208)
            let ql = base          // 128 B
            let qh = base + 128    // 64 B
            let sc = base + 192    // 16 × int8
            let outBase = b * blockElements
            for half in 0..<2 {
                let qlOff = ql + half * 64
                let qhOff = qh + half * 32
                let scOff = sc + half * 8
                let yOff = outBase + half * 128
                for l in 0..<32 {
                    let isIdx = l / 16
                    let qh_l = raw[qhOff + l]
                    // 与 C 参考一致：先合成 6-bit 量化值，再整体减 32（括号不可省）。
                    let q1 = (Int32(raw[qlOff + l] & 0x0F) | (Int32((qh_l >> 0) & 3) << 4)) - 32
                    let q2 = (Int32(raw[qlOff + l + 32] & 0x0F) | (Int32((qh_l >> 2) & 3) << 4)) - 32
                    let q3 = (Int32(raw[qlOff + l] >> 4) | (Int32((qh_l >> 4) & 3) << 4)) - 32
                    let q4 = (Int32(raw[qlOff + l + 32] >> 4) | (Int32((qh_l >> 6) & 3) << 4)) - 32
                    let s0 = Float(Int8(bitPattern: raw[scOff + isIdx + 0]))
                    let s2 = Float(Int8(bitPattern: raw[scOff + isIdx + 2]))
                    let s4 = Float(Int8(bitPattern: raw[scOff + isIdx + 4]))
                    let s6 = Float(Int8(bitPattern: raw[scOff + isIdx + 6]))
                    out[yOff + l]      = d * s0 * Float(q1)
                    out[yOff + l + 32] = d * s2 * Float(q2)
                    out[yOff + l + 64] = d * s4 * Float(q3)
                    out[yOff + l + 96] = d * s6 * Float(q4)
                }
            }
        }
        return out
    }
}

// MARK: - F32（norm 权重）
public enum GGUF_F32: Sendable {
    public static func read(_ raw: UnsafeRawBufferPointer, count: Int) throws -> [Float] {
        guard raw.count >= count * 4 else {
            throw GGUFError.truncated("F32 need \(count * 4) B, got \(raw.count)")
        }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
        }
        return out
    }
}
