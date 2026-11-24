import Foundation
import Metal

// G4：常驻 STQ1_0 / Q6_K 的原生 Metal GEMV。
//
// 权威来源（与 Sources/HymnSTQ/QuantizedBlocks.swift、Scripts/gen-gguf-golden.py 同源）：
//   llama.cpp PR #22836 stq1_0_codebook / dequantize_row_stq1_0
//   ggml-quants.c dequantize_row_q6_K + ggml-common.h block_q6_K
//   源码副本见 research/upstream/stq1_0-reference/
// 这里只做「解码即乘加」：权重始终保持 42 B / 256（STQ1_0）或 210 B / 256（Q6_K）
// 的原始字节，绝不展开成 fp16 缓存。
// ⚠️ type 42 是该 checkpoint 生成时的 PR 早期编号，当前 mainline 为 43，按新编号读会全错。

public enum SherryGEMVError: Error, CustomStringConvertible {
    case noPipeline(String)
    case noEncoder(String)
    case badOffset(String)

    public var description: String {
        switch self {
        case .noPipeline(let n): return "缺少 Metal pipeline: \(n)"
        case .noEncoder(let n): return "无法创建 compute encoder: \(n)"
        case .badOffset(let n): return "权重偏移未按 16 字节对齐: \(n)"
        }
    }
}

public final class SherryGEMV: @unchecked Sendable {
    public let device: MTLDevice
    private let stqPipeline: MTLComputePipelineState
    private let q6EmbedPipeline: MTLComputePipelineState
    private let q6GemvPipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw SherryGEMVError.noPipeline(name)
            }
            return try device.makeComputePipelineState(function: fn)
        }
        stqPipeline = try pipeline("stq1_0_gemv")
        q6EmbedPipeline = try pipeline("q6_k_embed_row")
        q6GemvPipeline = try pipeline("q6_k_gemv")
    }

    private func encoder(_ cb: MTLCommandBuffer, _ name: String) throws -> MTLComputeCommandEncoder {
        guard let enc = cb.makeComputeCommandEncoder() else {
            throw SherryGEMVError.noEncoder(name)
        }
        return enc
    }

    private static func threads(_ n: Int) -> MTLSize {
        MTLSize(width: max(1, min(256, n)), height: 1, depth: 1)
    }

    /// y[out] = W_stq1_0[out, in] · x[in]，权重为 GGUF 原始 42B/256 block。
    public func stq1_0(
        _ cb: MTLCommandBuffer, x: MTLBuffer, weights: MTLBuffer, weightOffset: Int,
        inFeatures: Int, outFeatures: Int, out: MTLBuffer
    ) throws {
        guard weightOffset % 16 == 0 else { throw SherryGEMVError.badOffset("\(weightOffset)") }
        let enc = try encoder(cb, "stq1_0_gemv")
        enc.setComputePipelineState(stqPipeline)
        enc.setBuffer(x, offset: 0, index: 0)
        enc.setBuffer(weights, offset: weightOffset, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        var inf = UInt32(inFeatures), outf = UInt32(outFeatures)
        enc.setBytes(&inf, length: 4, index: 3)
        enc.setBytes(&outf, length: 4, index: 4)
        enc.dispatchThreads(MTLSize(width: outFeatures, height: 1, depth: 1),
                            threadsPerThreadgroup: Self.threads(outFeatures))
        enc.endEncoding()
    }

    /// 从 Q6_K tied embedding 直接解码 tokenID 对应的整行（hiddenSize 个 half）。
    public func q6kEmbedRow(
        _ cb: MTLCommandBuffer, weights: MTLBuffer, weightOffset: Int,
        tokenID: Int, n: Int, out: MTLBuffer
    ) throws {
        guard weightOffset % 16 == 0 else { throw SherryGEMVError.badOffset("\(weightOffset)") }
        let enc = try encoder(cb, "q6_k_embed_row")
        enc.setComputePipelineState(q6EmbedPipeline)
        enc.setBuffer(weights, offset: weightOffset, index: 0)
        enc.setBuffer(out, offset: 0, index: 1)
        var tok = UInt32(tokenID), nn = UInt32(n), bpr = UInt32(n / 256)
        enc.setBytes(&tok, length: 4, index: 2)
        enc.setBytes(&nn, length: 4, index: 3)
        enc.setBytes(&bpr, length: 4, index: 4)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                            threadsPerThreadgroup: Self.threads(n))
        enc.endEncoding()
    }

    /// y[vocab] = W_q6k[vocab, hidden] · x[hidden]（tied lm_head），权重常驻 Q6_K block。
    public func q6kGEMV(
        _ cb: MTLCommandBuffer, x: MTLBuffer, weights: MTLBuffer, weightOffset: Int,
        inFeatures: Int, outFeatures: Int, out: MTLBuffer
    ) throws {
        guard weightOffset % 16 == 0 else { throw SherryGEMVError.badOffset("\(weightOffset)") }
        let enc = try encoder(cb, "q6_k_gemv")
        enc.setComputePipelineState(q6GemvPipeline)
        enc.setBuffer(x, offset: 0, index: 0)
        enc.setBuffer(weights, offset: weightOffset, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        var inf = UInt32(inFeatures), outf = UInt32(outFeatures)
        enc.setBytes(&inf, length: 4, index: 3)
        enc.setBytes(&outf, length: 4, index: 4)
        enc.dispatchThreads(MTLSize(width: outFeatures, height: 1, depth: 1),
                            threadsPerThreadgroup: Self.threads(outFeatures))
        enc.endEncoding()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // PR #22836 stq1_0_codebook[32]，与 QuantizedBlocks.swift / gen-gguf-golden.py 逐项一致。
    constant uchar stq_codebook[32] = {
        0xA9, 0x89, 0x29, 0x09, 0xA6, 0x86, 0x26, 0x06,
        0x9A, 0x92, 0x1A, 0x12, 0x6A, 0x62, 0x4A, 0x42,
        0x01, 0x21, 0x81, 0xA1, 0x04, 0x24, 0x84, 0xA4,
        0x10, 0x18, 0x90, 0x98, 0x40, 0x48, 0x60, 0x68,
    };

    inline half read_half(device const uchar* p, uint off) {
        return *((device const half*)(p + off));
    }

    // 单个 Q6_K block 内第 pos 个权重（0..255），按 ggml-quants.c 公式。
    inline float q6k_value(device const uchar* block, uint pos) {
        uint halfIndex = pos / 128;
        uint r = pos % 128;
        uint l = r % 32;
        uint group = r / 32;
        uint qlOff = halfIndex * 64;
        uint qhOff = 128 + halfIndex * 32;
        uint scOff = 192 + halfIndex * 8;
        uchar qhl = block[qhOff + l];
        int q;
        if (group == 0) {
            q = (int(block[qlOff + l] & 0x0F) | (int((qhl >> 0) & 3) << 4)) - 32;
        } else if (group == 1) {
            q = (int(block[qlOff + l + 32] & 0x0F) | (int((qhl >> 2) & 3) << 4)) - 32;
        } else if (group == 2) {
            q = (int(block[qlOff + l] >> 4) | (int((qhl >> 4) & 3) << 4)) - 32;
        } else {
            q = (int(block[qlOff + l + 32] >> 4) | (int((qhl >> 6) & 3) << 4)) - 32;
        }
        uint isIdx = l / 16;
        uint sb = block[scOff + isIdx + 2 * group];
        int s = int(sb);
        if (s >= 128) s -= 256;
        half d = read_half(block, 208);
        // 与 fp16 缓存同精度：先舍入到 half 再参与乘加。
        half w = half(float(d) * float(s) * float(q));
        return float(w);
    }

    kernel void stq1_0_gemv(
        device const half* x        [[buffer(0)]],
        device const uchar* w       [[buffer(1)]],
        device half* y              [[buffer(2)]],
        constant uint& inFeatures   [[buffer(3)]],
        constant uint& outFeatures  [[buffer(4)]],
        uint row [[thread_position_in_grid]])
    {
        if (row >= outFeatures) return;
        uint blocksPerRow = inFeatures / 256;
        float acc = 0.0f;
        for (uint b = 0; b < blocksPerRow; ++b) {
            device const uchar* block = w + (row * blocksPerRow + b) * 42;
            half d = read_half(block, 40);
            for (uint g = 0; g < 64; ++g) {
                uchar code = (block[g / 2] >> (4 * (g & 1))) & 0x0F;
                uchar sign = (block[32 + g / 8] >> (g % 8)) & 0x01;
                uchar qpack = stq_codebook[(sign << 4) | code];
                uint rowIdx = (g / 16) * 64 + (g % 16);
                for (uint p = 0; p < 4; ++p) {
                    int q = int((qpack >> (2 * p)) & 3) - 1;
                    half wv = half(float(q) * float(d));
                    acc += float(x[b * 256 + rowIdx + p * 16]) * float(wv);
                }
            }
        }
        y[row] = half(acc);
    }

    kernel void q6_k_embed_row(
        device const uchar* w       [[buffer(0)]],
        device half* out            [[buffer(1)]],
        constant uint& token        [[buffer(2)]],
        constant uint& n            [[buffer(3)]],
        constant uint& blocksPerRow [[buffer(4)]],
        uint i [[thread_position_in_grid]])
    {
        if (i >= n) return;
        uint b = i / 256;
        uint pos = i % 256;
        device const uchar* block = w + (token * blocksPerRow + b) * 210;
        out[i] = half(q6k_value(block, pos));
    }

    kernel void q6_k_gemv(
        device const half* x        [[buffer(0)]],
        device const uchar* w       [[buffer(1)]],
        device half* y              [[buffer(2)]],
        constant uint& inFeatures   [[buffer(3)]],
        constant uint& outFeatures  [[buffer(4)]],
        uint row [[thread_position_in_grid]])
    {
        if (row >= outFeatures) return;
        uint blocksPerRow = inFeatures / 256;
        float acc = 0.0f;
        for (uint b = 0; b < blocksPerRow; ++b) {
            device const uchar* block = w + (row * blocksPerRow + b) * 210;
            for (uint j = 0; j < 256; ++j) {
                acc += float(x[b * 256 + j]) * q6k_value(block, j);
            }
        }
        y[row] = half(acc);
    }
    """
}
