import Foundation
import Metal

/// Sherry 常驻 GEMV 运行时错误（D-1 退役后不再依赖 safetensors 解析层）。
public struct SherryRuntimeError: Error, Sendable, CustomStringConvertible, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "[\(code)] \(message)" }
}

// MARK: - 模型超参数（来自 GGUF 目录的 config.json，不由代码发明）

public struct HymnModelConfig: Sendable, Equatable {
    public let hiddenSize: Int
    public let layerCount: Int
    public let intermediateSize: Int
    public let heads: Int
    public let kvHeads: Int
    public let headDim: Int
    public let vocabularySize: Int
    public let rmsNormEps: Float
    public let ropeTheta: Float
    public let ropeAlpha: Float
    public let tieWordEmbeddings: Bool
    public let maxSequenceLength: Int

    public var effectiveRopeBase: Double {
        Double(ropeTheta) * pow(Double(ropeAlpha), Double(headDim) / Double(headDim - 2))
    }
    public var attentionScale: Float { 1.0 / Float(headDim).squareRoot() }
    public var qDimension: Int { heads * headDim }
    public var kvDimension: Int { kvHeads * headDim }

    public init(modelDirectory: URL) throws {
        let data = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        guard let c = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SherryRuntimeError(code: "CONFIG_JSON", message: "config.json 解析失败")
        }
        func int(_ k: String, _ d: Int) -> Int { (c[k] as? Int) ?? d }
        func flt(_ k: String, _ d: Float) -> Float { (c[k] as? NSNumber)?.floatValue ?? d }
        self.hiddenSize = int("hidden_size", 2048)
        self.layerCount = int("num_hidden_layers", 32)
        self.intermediateSize = int("intermediate_size", 6144)
        self.heads = int("num_attention_heads", 16)
        self.kvHeads = int("num_key_value_heads", 4)
        self.headDim = int("head_dim", 128)
        self.vocabularySize = int("vocab_size", 120818)
        self.rmsNormEps = flt("rms_norm_eps", 1e-5)
        self.ropeTheta = flt("rope_theta", 10000)
        self.tieWordEmbeddings = (c["tie_word_embeddings"] as? Bool) ?? true
        self.maxSequenceLength = int("max_position_embeddings", 32768)
        if let rs = c["rope_scaling"] as? [String: Any] {
            self.ropeAlpha = (rs["alpha"] as? NSNumber)?.floatValue ?? 1
        } else { self.ropeAlpha = 1 }
    }
}

// MARK: - Metal 算子层
//
// 语义来源（非臆造）：hunyuan_v1_dense 的官方模型结构（32L / 2048 / 16Q / 4KV /
// head_dim 128 / post-RoPE QK-Norm）与 DynamicNTKAlphaRoPE。
// 逐算子离线 golden 见 Golden/ops-*.f32（运行时不读取、不依赖任何上游源码副本）。

public final class MetalOps: @unchecked Sendable {

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]

    public let headDim: Int
    public let heads: Int
    public let kvHeads: Int
    public let eps: Float
    public let maxSeq: Int

    /// invFreq[i] = adjustedBase^(-2i/headDim)，与上游 freqs 互为倒数
    public let invFreqs: [Float]

    public init(config: HymnModelConfig, maxSequenceLength: Int = 1024) throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw SherryRuntimeError(code: "NO_METAL", message: "Metal 不可用")
        }
        self.device = d
        self.queue = q
        self.headDim = config.headDim
        self.heads = config.heads
        self.kvHeads = config.kvHeads
        self.eps = config.rmsNormEps
        self.maxSeq = maxSequenceLength
        let base = config.effectiveRopeBase
        self.invFreqs = (0..<config.headDim / 2).map { i in
            Float(pow(base, -Double(2 * i) / Double(config.headDim)))
        }
        self.library = try d.makeLibrary(source: Self.shaderSource, options: nil)
        for name in ["rms_norm_multi", "rope_apply", "kv_write", "attention_decode",
                     "silu_mul", "residual_add", "kv_write_int8", "attention_decode_int8"] {
            guard let fn = library.makeFunction(name: name) else {
                throw SherryRuntimeError(code: "NO_KERNEL", message: name)
            }
            pipelines[name] = try d.makeComputePipelineState(function: fn)
        }
    }

    @inline(__always)
    private func pipe(_ name: String) throws -> MTLComputePipelineState {
        guard let p = pipelines[name] else {
            throw SherryRuntimeError(code: "NO_PIPELINE", message: name)
        }
        return p
    }

    // MARK: - 便捷执行

    public func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let cb = queue.makeCommandBuffer() else {
            throw SherryRuntimeError(code: "NO_CB", message: "makeCommandBuffer")
        }
        return cb
    }

    public func commit(_ cb: MTLCommandBuffer) throws {
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error {
            throw SherryRuntimeError(code: "GPU_ERROR", message: "\(e)")
        }
    }

    /// H1 batched prefill：只提交、不等待。同一 MTLCommandQueue 保证 FIFO，
    /// 后续最后一次 commit(wait) 排空队列时，此前所有 submit 的 buffer 均已完成，
    /// 因此 KV cache 的写入顺序与逐 token commit 完全等价，但不产生 N 次 CPU-GPU 同步。
    public func submit(_ cb: MTLCommandBuffer) {
        cb.commit()
    }

    // MARK: - 算子

    /// RMSNorm：y[row,i] = x[row,i] * rsqrt(mean(x[row]^2)+eps) * w[i]
    /// 同时用于 input/post_attention norm（rows=1）与 post-RoPE QK-Norm（rows=16/4）。
    public func rmsNorm(
        _ cb: MTLCommandBuffer, x: MTLBuffer, weight: MTLBuffer, out: MTLBuffer,
        rows: Int, n: Int, weightOffset: Int = 0
    ) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("rms_norm_multi"))
        enc.setBuffer(x, offset: 0, index: 0)
        enc.setBuffer(weight, offset: weightOffset, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        var nn = UInt32(n), rr = UInt32(rows), e = eps
        enc.setBytes(&nn, length: 4, index: 3)
        enc.setBytes(&e, length: 4, index: 4)
        enc.setBytes(&rr, length: 4, index: 5)
        // 256 必须是 2 的幂（reduction 用 s >>= 1），且不超过 MSL 里的 partial[1024]
        let threads = 256
        enc.dispatchThreadgroups(MTLSize(width: rows, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// RoPE（traditional=false，half-split），angle = pos / freqs[i]，in-place。
    public func rope(
        _ cb: MTLCommandBuffer, x: MTLBuffer, rows: Int, position: Int,
        invFreqBuffer: MTLBuffer? = nil
    ) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("rope_apply"))
        enc.setBuffer(x, offset: 0, index: 0)
        let freqs = try invFreqBuffer ?? makeInvFreqBuffer()
        enc.setBuffer(freqs, offset: 0, index: 1)
        var rr = UInt32(rows), p = Float(position)
        enc.setBytes(&rr, length: 4, index: 2)
        enc.setBytes(&p, length: 4, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: headDim / 2, height: rows, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: headDim / 2, height: 1, depth: 1))
        enc.endEncoding()
    }

    public func makeInvFreqBuffer() throws -> MTLBuffer {
        guard let b = device.makeBuffer(bytes: invFreqs,
                                        length: invFreqs.count * 4, options: .storageModeShared) else {
            throw SherryRuntimeError(code: "NO_BUFFER", message: "invFreqs")
        }
        return b
    }

    /// 把本 token 的 K/V（已 RoPE + QK-Norm）写入每层 cache 的 pos 行。
    public func kvWrite(
        _ cb: MTLCommandBuffer, k: MTLBuffer, v: MTLBuffer,
        kCache: MTLBuffer, vCache: MTLBuffer, position: Int
    ) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("kv_write"))
        enc.setBuffer(k, offset: 0, index: 0)
        enc.setBuffer(v, offset: 0, index: 1)
        enc.setBuffer(kCache, offset: 0, index: 2)
        enc.setBuffer(vCache, offset: 0, index: 3)
        var p = UInt32(position)
        enc.setBytes(&p, length: 4, index: 4)
        let n = kvHeads * headDim
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(n, 512), height: 1, depth: 1))
        enc.endEncoding()
    }

    /// H1 量化 KV cache：写入 int8 K/V + per-(token, kvHead) fp32 scale。
    /// scale = max(|x|)/127，量化为 round(x/scale) 后 clamp 到 [-127,127]。
    /// 这是有损优化，默认不启用（HYMN_KV_INT8=1 或显式 .int8 才走此路径）。
    public func kvWriteInt8(
        _ cb: MTLCommandBuffer, k: MTLBuffer, v: MTLBuffer,
        kCache: MTLBuffer, vCache: MTLBuffer,
        kScale: MTLBuffer, vScale: MTLBuffer, position: Int
    ) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("kv_write_int8"))
        enc.setBuffer(k, offset: 0, index: 0)
        enc.setBuffer(v, offset: 0, index: 1)
        enc.setBuffer(kCache, offset: 0, index: 2)
        enc.setBuffer(vCache, offset: 0, index: 3)
        enc.setBuffer(kScale, offset: 0, index: 4)
        enc.setBuffer(vScale, offset: 0, index: 5)
        var p = UInt32(position), kvh = UInt32(kvHeads), hd = UInt32(headDim)
        enc.setBytes(&p, length: 4, index: 6)
        enc.setBytes(&kvh, length: 4, index: 7)
        enc.setBytes(&hd, length: 4, index: 8)
        enc.setThreadgroupMemoryLength(headDim * 2 * 4, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: kvHeads, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: headDim, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// GQA decode attention：q[heads,headDim] × K/V cache[seq,kvHeads,headDim] → out[heads,headDim]
    public func attention(
        _ cb: MTLCommandBuffer, q: MTLBuffer, kCache: MTLBuffer, vCache: MTLBuffer,
        out: MTLBuffer, sequenceLength: Int, scale: Float
    ) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("attention_decode"))
        enc.setBuffer(q, offset: 0, index: 0)
        enc.setBuffer(kCache, offset: 0, index: 1)
        enc.setBuffer(vCache, offset: 0, index: 2)
        enc.setBuffer(out, offset: 0, index: 3)
        var s = UInt32(sequenceLength), sc = scale
        var h = UInt32(headDim), kvh = UInt32(kvHeads), gh = UInt32(heads / kvHeads)
        enc.setBytes(&s, length: 4, index: 4)
        enc.setBytes(&sc, length: 4, index: 5)
        enc.setBytes(&h, length: 4, index: 6)
        enc.setBytes(&kvh, length: 4, index: 7)
        enc.setBytes(&gh, length: 4, index: 8)
        enc.setThreadgroupMemoryLength(maxSeq * 4 * 2, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: heads, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(headDim, 128), height: 1, depth: 1))
        enc.endEncoding()
    }

    /// H1 量化 KV cache 对应的 attention：读取 int8 K/V 并按 per-(token, kvHead) scale 反量化。
    /// 数值路径与 fp16 版相同，只多一次 scale 乘法，因此会引入量化误差。
    public func attentionInt8(
        _ cb: MTLCommandBuffer, q: MTLBuffer, kCache: MTLBuffer, vCache: MTLBuffer,
        kScale: MTLBuffer, vScale: MTLBuffer,
        out: MTLBuffer, sequenceLength: Int, scale: Float
    ) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("attention_decode_int8"))
        enc.setBuffer(q, offset: 0, index: 0)
        enc.setBuffer(kCache, offset: 0, index: 1)
        enc.setBuffer(vCache, offset: 0, index: 2)
        enc.setBuffer(kScale, offset: 0, index: 3)
        enc.setBuffer(vScale, offset: 0, index: 4)
        enc.setBuffer(out, offset: 0, index: 5)
        var s = UInt32(sequenceLength), sc = scale
        var h = UInt32(headDim), kvh = UInt32(kvHeads), gh = UInt32(heads / kvHeads)
        enc.setBytes(&s, length: 4, index: 6)
        enc.setBytes(&sc, length: 4, index: 7)
        enc.setBytes(&h, length: 4, index: 8)
        enc.setBytes(&kvh, length: 4, index: 9)
        enc.setBytes(&gh, length: 4, index: 10)
        enc.setThreadgroupMemoryLength(maxSeq * 4 * 2, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: heads, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: min(headDim, 128), height: 1, depth: 1))
        enc.endEncoding()
    }

    public func siluMul(_ cb: MTLCommandBuffer, gate: MTLBuffer, up: MTLBuffer,
                        out: MTLBuffer, n: Int) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("silu_mul"))
        enc.setBuffer(gate, offset: 0, index: 0)
        enc.setBuffer(up, offset: 0, index: 1)
        enc.setBuffer(out, offset: 0, index: 2)
        var nn = UInt32(n)
        enc.setBytes(&nn, length: 4, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: (n + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
    }

    public func residualAdd(_ cb: MTLCommandBuffer, x: MTLBuffer, y: MTLBuffer, n: Int) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(try pipe("residual_add"))
        enc.setBuffer(x, offset: 0, index: 0)
        enc.setBuffer(y, offset: 0, index: 1)
        var nn = UInt32(n)
        enc.setBytes(&nn, length: 4, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: (n + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
    }

    // MARK: - MSL

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // RMSNorm：每个 threadgroup 处理一行；w 在 rows 间共享。
    kernel void rms_norm_multi(
        device const half* x  [[buffer(0)]],
        device const half* w  [[buffer(1)]],
        device half* y        [[buffer(2)]],
        constant uint&  n     [[buffer(3)]],
        constant float& eps   [[buffer(4)]],
        constant uint&  rows  [[buffer(5)]],
        uint tid [[thread_position_in_threadgroup]],
        uint tpt [[threads_per_threadgroup]],
        uint row [[threadgroup_position_in_grid]])
    {
        threadgroup float partial[1024];
        if (row >= rows) return;
        device const half* xr = x + row * n;
        device half* yr = y + row * n;
        float acc = 0.0f;
        for (uint i = tid; i < n; i += tpt) { float v = float(xr[i]); acc += v * v; }
        partial[tid] = acc;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = tpt >> 1; s > 0; s >>= 1) {
            if (tid < s) partial[tid] += partial[tid + s];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        float inv = rsqrt(partial[0] / float(n) + eps);
        for (uint i = tid; i < n; i += tpt) {
            yr[i] = half((float(xr[i]) * inv) * float(w[i]));
        }
    }

    // RoPE half-split (traditional=false)：x[row, i] 与 x[row, i+hd/2] 组成一对
    kernel void rope_apply(
        device half* x            [[buffer(0)]],
        device const float* invF  [[buffer(1)]],
        constant uint& rows       [[buffer(2)]],
        constant float& pos       [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint i = gid.x, row = gid.y;
        if (row >= rows || i >= 64) return;
        float ang = pos * invF[i];
        float c = cos(ang), s = sin(ang);
        uint base = row * 128;
        float a = float(x[base + i]);
        float b = float(x[base + i + 64]);
        x[base + i]      = half(a * c - b * s);
        x[base + i + 64] = half(b * c + a * s);
    }

    kernel void kv_write(
        device const half* k    [[buffer(0)]],
        device const half* v    [[buffer(1)]],
        device half* kCache     [[buffer(2)]],
        device half* vCache     [[buffer(3)]],
        constant uint& pos      [[buffer(4)]],
        uint i [[thread_position_in_grid]])
    {
        uint n = 512;
        if (i >= n) return;
        kCache[pos * n + i] = k[i];
        vCache[pos * n + i] = v[i];
    }

    // GQA decode attention：一个 threadgroup 处理一个 query head
    kernel void attention_decode(
        device const half* q      [[buffer(0)]],
        device const half* kCache [[buffer(1)]],
        device const half* vCache [[buffer(2)]],
        device half* out          [[buffer(3)]],
        constant uint& seqLen     [[buffer(4)]],
        constant float& scale     [[buffer(5)]],
        constant uint& hd         [[buffer(6)]],
        constant uint& kvh        [[buffer(7)]],
        constant uint& groupSize  [[buffer(8)]],
        threadgroup float* scratch [[threadgroup(0)]],
        uint tid [[thread_position_in_threadgroup]],
        uint tpt [[threads_per_threadgroup]],
        uint head [[threadgroup_position_in_grid]])
    {
        threadgroup float* scores = scratch;
        threadgroup float* probs  = scratch + 1024;
        uint kvHead = head / groupSize;
        uint stride = kvh * hd;
        // 1) scores[t] = dot(q_head, K[t, kvHead]) * scale
        for (uint t = tid; t < seqLen; t += tpt) {
            float acc = 0.0f;
            for (uint i = 0; i < hd; ++i) {
                acc += float(q[head * hd + i]) * float(kCache[t * stride + kvHead * hd + i]);
            }
            scores[t] = acc * scale;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // 2) softmax（单线程，seq 较短）
        if (tid == 0) {
            float mx = -INFINITY;
            for (uint t = 0; t < seqLen; ++t) mx = max(mx, scores[t]);
            float sum = 0.0f;
            for (uint t = 0; t < seqLen; ++t) { probs[t] = exp(scores[t] - mx); sum += probs[t]; }
            for (uint t = 0; t < seqLen; ++t) probs[t] /= sum;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // 3) out[i] = sum_t probs[t] * V[t, kvHead, i]
        for (uint i = tid; i < hd; i += tpt) {
            float acc = 0.0f;
            for (uint t = 0; t < seqLen; ++t) {
                acc += probs[t] * float(vCache[t * stride + kvHead * hd + i]);
            }
            out[head * hd + i] = half(acc);
        }
    }

    kernel void silu_mul(
        device const half* gate [[buffer(0)]],
        device const half* up   [[buffer(1)]],
        device half* out        [[buffer(2)]],
        constant uint& n        [[buffer(3)]],
        uint i [[thread_position_in_grid]])
    {
        if (i >= n) return;
        float g = float(gate[i]);
        float s = g / (1.0f + exp(-g));
        out[i] = half(s * float(up[i]));
    }

    kernel void residual_add(
        device half* x          [[buffer(0)]],
        device const half* y    [[buffer(1)]],
        constant uint& n        [[buffer(2)]],
        uint i [[thread_position_in_grid]])
    {
        if (i >= n) return;
        x[i] = half(float(x[i]) + float(y[i]));
    }

    // H1 量化 KV cache：per-(token, kvHead) 动态 scale，K/V 各写 int8 + scale。
    // 一个 threadgroup 处理一个 kvHead 的 hd 个分量，组内 reduction 求 max|x|。
    kernel void kv_write_int8(
        device const half* k       [[buffer(0)]],
        device const half* v       [[buffer(1)]],
        device char* kCache        [[buffer(2)]],
        device char* vCache        [[buffer(3)]],
        device float* kScale       [[buffer(4)]],
        device float* vScale       [[buffer(5)]],
        constant uint& pos         [[buffer(6)]],
        constant uint& kvh         [[buffer(7)]],
        constant uint& hd          [[buffer(8)]],
        threadgroup float* scratch [[threadgroup(0)]],
        uint kvHead [[threadgroup_position_in_grid]],
        uint tid    [[thread_position_in_threadgroup]])
    {
        uint stride = kvh * hd;
        uint base = kvHead * hd;
        scratch[tid] = (tid < hd) ? fabs(float(k[base + tid])) : 0.0f;
        scratch[hd + tid] = (tid < hd) ? fabs(float(v[base + tid])) : 0.0f;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = hd >> 1; s > 0; s >>= 1) {
            if (tid < s) {
                scratch[tid] = max(scratch[tid], scratch[tid + s]);
                scratch[hd + tid] = max(scratch[hd + tid], scratch[hd + tid + s]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        float ks = max(scratch[0] / 127.0f, 1e-8f);
        float vs = max(scratch[hd] / 127.0f, 1e-8f);
        if (tid == 0) {
            kScale[pos * kvh + kvHead] = ks;
            vScale[pos * kvh + kvHead] = vs;
        }
        if (tid < hd) {
            uint idx = pos * stride + base + tid;
            kCache[idx] = char(clamp(round(float(k[base + tid]) / ks), -127.0f, 127.0f));
            vCache[idx] = char(clamp(round(float(v[base + tid]) / vs), -127.0f, 127.0f));
        }
    }

    // H1 量化 KV cache 对应的 GQA decode attention（反量化后与 fp16 版同构）。
    kernel void attention_decode_int8(
        device const half* q       [[buffer(0)]],
        device const char* kCache  [[buffer(1)]],
        device const char* vCache  [[buffer(2)]],
        device const float* kScale [[buffer(3)]],
        device const float* vScale [[buffer(4)]],
        device half* out           [[buffer(5)]],
        constant uint& seqLen      [[buffer(6)]],
        constant float& scale      [[buffer(7)]],
        constant uint& hd          [[buffer(8)]],
        constant uint& kvh         [[buffer(9)]],
        constant uint& groupSize   [[buffer(10)]],
        threadgroup float* scratch [[threadgroup(0)]],
        uint tid [[thread_position_in_threadgroup]],
        uint tpt [[threads_per_threadgroup]],
        uint head [[threadgroup_position_in_grid]])
    {
        threadgroup float* scores = scratch;
        threadgroup float* probs  = scratch + 1024;
        uint kvHead = head / groupSize;
        uint stride = kvh * hd;
        for (uint t = tid; t < seqLen; t += tpt) {
            float ks = kScale[t * kvh + kvHead];
            float acc = 0.0f;
            for (uint i = 0; i < hd; ++i) {
                acc += float(q[head * hd + i]) *
                       (float(kCache[t * stride + kvHead * hd + i]) * ks);
            }
            scores[t] = acc * scale;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid == 0) {
            float mx = -INFINITY;
            for (uint t = 0; t < seqLen; ++t) mx = max(mx, scores[t]);
            float sum = 0.0f;
            for (uint t = 0; t < seqLen; ++t) { probs[t] = exp(scores[t] - mx); sum += probs[t]; }
            for (uint t = 0; t < seqLen; ++t) probs[t] /= sum;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = tid; i < hd; i += tpt) {
            float acc = 0.0f;
            for (uint t = 0; t < seqLen; ++t) {
                float vs = vScale[t * kvh + kvHead];
                acc += probs[t] *
                       (float(vCache[t * stride + kvHead * hd + i]) * vs);
            }
            out[head * hd + i] = half(acc);
        }
    }

    """
}
