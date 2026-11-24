import Foundation
import Metal

// G4：1.25bit GGUF 常驻推理模型。
//
// 与 G1 的 SherryBackend（GGUF → 3.58 GB fp16 展开缓存 → MPS GEMM）本质区别：
//   · 权重始终是 GGUF 原始字节：224 个 STQ1_0 线性层 42 B/256、1 个 Q6_K embedding 210 B/256；
//   · 461,860,800 B 一次性拷入常驻 MTLBuffer，运行时不再读写 weights.fp16.bin；
//   · 所有线性层由 SherryGEMV 的 MSL kernel 做「解码即乘加」；
//   · RMSNorm / RoPE / GQA / SiLU / residual 复用已 golden 对齐的 MetalOps；
//   · 129 个 F32 norm 权重（约 0.5 MB）在 prepare 时转成 fp16 小 buffer，属非量化元数据，
//     不影响「线性层 1.3125 bpw 常驻」这一口径。
// 权重格式：Sherry STQ1_0 1.3125 bpw，NOT LUT4 / NOT affine INT4。
//
// H1 优化（2026-11-21）：
//   · batched prefill：把 prompt 的多个 token 编码进按 chunk 提交的 command buffer，
//     中间 token 跳过最终 norm + lm_head（只有最后一个 token 的 logits 需要采样），
//     并用 submit(不等待) 取代逐 token commit(wait)。kernel 顺序与临时 buffer 复用
//     与逐 token forward 完全一致，因此数值**逐元素不变**（bench-h1 实证）。
//   · 量化 KV cache：可选 int8 + per-(token,kvHead) fp32 scale 路径（HYMN_KV_INT8=1
//     或显式 .int8）。这是**有损**优化，默认关闭，收益与误差见 Reports/h1-optimization-bench.json。
//   · fused dequant-GEMM：stq1_0_gemv 自 G4 起已是「解码即乘加」融合，无中间 fp16 权重，
//     本轮不重复实现、不重复计功。

/// KV cache 精度模式。`.auto` 读 HYMN_KV_INT8 环境变量，默认 fp16（不改变生产译文）。
public enum KVCacheMode: Sendable, Equatable {
    case fp16
    case int8
    case auto
}

public enum SherryResidentError: Error, CustomStringConvertible {
    case noGGUF(String)
    case unmapped(String)
    case missingOffset(String)
    case unsupportedType(String, UInt32)
    case buffer(String)

    public var description: String {
        switch self {
        case .noGGUF(let p): return "缺少 1.25bit GGUF: \(p)"
        case .unmapped(let n): return "GGUF 张量无 HF 名称映射: \(n)"
        case .missingOffset(let n): return "权重偏移缺失: \(n)"
        case .unsupportedType(let n, let t): return "张量 \(n) 类型 \(t) 无常驻 GEMV 实现"
        case .buffer(let n): return "MTLBuffer 创建失败: \(n)"
        }
    }
}

public final class SherryResidentModel: @unchecked Sendable {
    public let config: HymnModelConfig
    public let ops: MetalOps
    public let gemv: SherryGEMV
    public let gguf: GGUFFile
    public let residentWeightBytes: Int
    public let gpuBufferBytes: Int
    public let normBufferBytes: Int
    public let maxSeq: Int
    public let kvCacheMode: KVCacheMode
    /// KV cache 实际占用字节数（含 int8 路径的 scale buffer），供内存口径报告。
    public let kvCacheBytes: Int

    private let device: MTLDevice
    private let weightBuffer: MTLBuffer
    private let normBuffer: MTLBuffer
    private let invFreqBuffer: MTLBuffer
    private var offsets: [String: Int] = [:]
    private var normOffsets: [String: Int] = [:]

    private var xBuf: MTLBuffer
    private var normBuf: MTLBuffer
    private var qBuf: MTLBuffer
    private var kBuf: MTLBuffer
    private var vBuf: MTLBuffer
    private var qNormBuf: MTLBuffer
    private var kNormBuf: MTLBuffer
    private var attnOutBuf: MTLBuffer
    private var oProjBuf: MTLBuffer
    private var gateBuf: MTLBuffer
    private var upBuf: MTLBuffer
    private var mlpInBuf: MTLBuffer
    private var mlpOutBuf: MTLBuffer
    private var logitsBuf: MTLBuffer
    private var kCaches: [MTLBuffer] = []
    private var vCaches: [MTLBuffer] = []
    private var kScales: [MTLBuffer] = []
    private var vScales: [MTLBuffer] = []

    public private(set) var lastMetrics = ForwardMetrics()

    private static func aligned(_ n: Int) -> Int { (n + 15) & ~15 }

    public init(modelDirectory: URL, maxSequenceLength: Int = 1024,
                kvCacheMode: KVCacheMode = .auto) throws {
        let cfg = try HymnModelConfig(modelDirectory: modelDirectory)
        let o = try MetalOps(config: cfg, maxSequenceLength: maxSequenceLength)
        let g = try SherryGEMV(device: o.device)
        let ggufURL = modelDirectory.appendingPathComponent("Hy-MT2-1.8B-1.25Bit.gguf")
        guard FileManager.default.fileExists(atPath: ggufURL.path) else {
            throw SherryResidentError.noGGUF(ggufURL.path)
        }
        let file = try GGUFFile(url: ggufURL)

        // 一次性把 GGUF 原始字节拷入常驻 GPU buffer；不生成、不打开 3.58 GB fp16 缓存。
        let mapped = try Data(contentsOf: ggufURL, options: [.mappedIfSafe])
        let wb: MTLBuffer = try mapped.withUnsafeBytes { raw -> MTLBuffer in
            guard let base = raw.baseAddress else { throw SherryResidentError.buffer("GGUF mmap") }
            guard let b = o.device.makeBuffer(bytes: base, length: raw.count,
                                              options: .storageModeShared) else {
                throw SherryResidentError.buffer("GGUF 461 MB")
            }
            return b
        }

        var offs: [String: Int] = [:]
        for t in file.tensors {
            guard let hf = SherryCacheBuilder.hfName(t.name) else {
                throw SherryResidentError.unmapped(t.name)
            }
            offs[hf] = file.dataStart + t.offset
        }

        // F32 norm 权重 → fp16 小 buffer（非量化元数据，约 0.5 MB）。
        var normBits: [UInt16] = []
        var nOffs: [String: Int] = [:]
        for t in file.tensors where t.type == 0 {
            guard let hf = SherryCacheBuilder.hfName(t.name) else {
                throw SherryResidentError.unmapped(t.name)
            }
            let vals = try file.withBytes(for: t.name) { raw in
                try GGUF_F32.read(raw, count: t.elementCount)
            }
            nOffs[hf] = normBits.count * 2
            for v in vals { normBits.append(Float16(v).bitPattern) }
        }
        guard let nb = o.device.makeBuffer(bytes: normBits,
                                           length: max(16, normBits.count * 2),
                                           options: .storageModeShared) else {
            throw SherryResidentError.buffer("norm fp16")
        }

        let resolved: KVCacheMode
        switch kvCacheMode {
        case .fp16, .int8: resolved = kvCacheMode
        case .auto:
            resolved = ProcessInfo.processInfo.environment["HYMN_KV_INT8"] == "1" ? .int8 : .fp16
        }

        self.config = cfg
        self.ops = o
        self.gemv = g
        self.gguf = file
        self.device = o.device
        self.weightBuffer = wb
        self.normBuffer = nb
        self.invFreqBuffer = try o.makeInvFreqBuffer()
        self.offsets = offs
        self.normOffsets = nOffs
        self.residentWeightBytes = file.fileSize
        self.gpuBufferBytes = wb.length
        self.normBufferBytes = nb.length
        self.maxSeq = maxSequenceLength
        self.kvCacheMode = resolved

        let dev = o.device
        func act(_ n: Int) -> MTLBuffer {
            dev.makeBuffer(length: Self.aligned(n * 2), options: .storageModeShared)!
        }
        func raw(_ n: Int) -> MTLBuffer {
            dev.makeBuffer(length: Self.aligned(n), options: .storageModeShared)!
        }
        func f32(_ n: Int) -> MTLBuffer {
            dev.makeBuffer(length: Self.aligned(n * 4), options: .storageModeShared)!
        }

        xBuf = act(cfg.hiddenSize)
        normBuf = act(cfg.hiddenSize)
        qBuf = act(cfg.qDimension)
        kBuf = act(cfg.kvDimension)
        vBuf = act(cfg.kvDimension)
        qNormBuf = act(cfg.qDimension)
        kNormBuf = act(cfg.kvDimension)
        attnOutBuf = act(cfg.qDimension)
        oProjBuf = act(cfg.hiddenSize)
        gateBuf = act(cfg.intermediateSize)
        upBuf = act(cfg.intermediateSize)
        mlpInBuf = act(cfg.intermediateSize)
        mlpOutBuf = act(cfg.hiddenSize)
        logitsBuf = act(cfg.vocabularySize)

        let kvElems = maxSequenceLength * cfg.kvDimension
        let scaleElems = maxSequenceLength * cfg.kvHeads
        var kvBytes = 0
        for _ in 0..<cfg.layerCount {
            switch resolved {
            case .fp16, .auto:
                kCaches.append(raw(kvElems * 2))
                vCaches.append(raw(kvElems * 2))
                kvBytes += Self.aligned(kvElems * 2) * 2
            case .int8:
                kCaches.append(raw(kvElems))
                vCaches.append(raw(kvElems))
                kScales.append(f32(scaleElems))
                vScales.append(f32(scaleElems))
                kvBytes += Self.aligned(kvElems) * 2 + Self.aligned(scaleElems * 4) * 2
            }
        }
        self.kvCacheBytes = kvBytes
    }

    private func weightOffset(_ name: String) throws -> Int {
        guard let v = offsets[name] else { throw SherryResidentError.missingOffset(name) }
        return v
    }
    private func normOffset(_ name: String) throws -> Int {
        guard let v = normOffsets[name] else { throw SherryResidentError.missingOffset(name) }
        return v
    }

    private func stq(_ cb: MTLCommandBuffer, _ x: MTLBuffer, _ name: String,
                     inFeatures: Int, outFeatures: Int, _ out: MTLBuffer) throws {
        try gemv.stq1_0(cb, x: x, weights: weightBuffer,
                        weightOffset: try weightOffset(name),
                        inFeatures: inFeatures, outFeatures: outFeatures, out: out)
    }

    // MARK: - 单 token 编码（forward 与 batched prefill 共用同一数值路径）

    /// 把一个 token 的全部层编码进外部 command buffer。
    /// `emitLogits=false` 时跳过最终 norm + tied lm_head：中间 prompt token 的 logits
    /// 从不被采样，且这两步只写 normBuf/logitsBuf、不修改 xBuf，故对后续 token 无影响。
    private func encodeToken(
        _ cb: MTLCommandBuffer, tokenID: Int, position: Int,
        emitLogits: Bool, metrics: inout ForwardMetrics
    ) throws {
        let cfg = config
        let embOffset = try weightOffset("model.embed_tokens")

        try gemv.q6kEmbedRow(cb, weights: weightBuffer, weightOffset: embOffset,
                             tokenID: tokenID, n: cfg.hiddenSize, out: xBuf)
        metrics.computeKernelCount += 1

        for layer in 0..<cfg.layerCount {
            let p = "model.layers.\(layer)"
            let a = "\(p).self_attn"
            let mlp = "\(p).mlp"

            try ops.rmsNorm(cb, x: xBuf, weight: normBuffer, out: normBuf,
                            rows: 1, n: cfg.hiddenSize,
                            weightOffset: try normOffset("\(p).input_layernorm.weight"))
            try stq(cb, normBuf, "\(a).q_proj", inFeatures: cfg.hiddenSize,
                    outFeatures: cfg.qDimension, qBuf)
            try stq(cb, normBuf, "\(a).k_proj", inFeatures: cfg.hiddenSize,
                    outFeatures: cfg.kvDimension, kBuf)
            try stq(cb, normBuf, "\(a).v_proj", inFeatures: cfg.hiddenSize,
                    outFeatures: cfg.kvDimension, vBuf)
            metrics.gemmCount += 3

            try ops.rope(cb, x: qBuf, rows: cfg.heads, position: position,
                         invFreqBuffer: invFreqBuffer)
            try ops.rope(cb, x: kBuf, rows: cfg.kvHeads, position: position,
                         invFreqBuffer: invFreqBuffer)
            try ops.rmsNorm(cb, x: qBuf, weight: normBuffer, out: qNormBuf,
                            rows: cfg.heads, n: cfg.headDim,
                            weightOffset: try normOffset("\(a).query_layernorm.weight"))
            try ops.rmsNorm(cb, x: kBuf, weight: normBuffer, out: kNormBuf,
                            rows: cfg.kvHeads, n: cfg.headDim,
                            weightOffset: try normOffset("\(a).key_layernorm.weight"))
            if kvCacheMode == .int8 {
                try ops.kvWriteInt8(cb, k: kNormBuf, v: vBuf,
                                    kCache: kCaches[layer], vCache: vCaches[layer],
                                    kScale: kScales[layer], vScale: vScales[layer],
                                    position: position)
                try ops.attentionInt8(cb, q: qNormBuf,
                                      kCache: kCaches[layer], vCache: vCaches[layer],
                                      kScale: kScales[layer], vScale: vScales[layer],
                                      out: attnOutBuf, sequenceLength: position + 1,
                                      scale: cfg.attentionScale)
            } else {
                try ops.kvWrite(cb, k: kNormBuf, v: vBuf,
                                kCache: kCaches[layer], vCache: vCaches[layer], position: position)
                try ops.attention(cb, q: qNormBuf, kCache: kCaches[layer], vCache: vCaches[layer],
                                  out: attnOutBuf, sequenceLength: position + 1,
                                  scale: cfg.attentionScale)
            }
            metrics.computeKernelCount += 5

            try stq(cb, attnOutBuf, "\(a).o_proj", inFeatures: cfg.qDimension,
                    outFeatures: cfg.hiddenSize, oProjBuf)
            metrics.gemmCount += 1
            try ops.residualAdd(cb, x: xBuf, y: oProjBuf, n: cfg.hiddenSize)

            try ops.rmsNorm(cb, x: xBuf, weight: normBuffer, out: normBuf,
                            rows: 1, n: cfg.hiddenSize,
                            weightOffset: try normOffset("\(p).post_attention_layernorm.weight"))
            try stq(cb, normBuf, "\(mlp).gate_proj", inFeatures: cfg.hiddenSize,
                    outFeatures: cfg.intermediateSize, gateBuf)
            try stq(cb, normBuf, "\(mlp).up_proj", inFeatures: cfg.hiddenSize,
                    outFeatures: cfg.intermediateSize, upBuf)
            metrics.gemmCount += 2
            try ops.siluMul(cb, gate: gateBuf, up: upBuf, out: mlpInBuf, n: cfg.intermediateSize)
            try stq(cb, mlpInBuf, "\(mlp).down_proj", inFeatures: cfg.intermediateSize,
                    outFeatures: cfg.hiddenSize, mlpOutBuf)
            metrics.gemmCount += 1
            try ops.residualAdd(cb, x: xBuf, y: mlpOutBuf, n: cfg.hiddenSize)
            metrics.computeKernelCount += 3
        }

        if emitLogits {
            try ops.rmsNorm(cb, x: xBuf, weight: normBuffer, out: normBuf,
                            rows: 1, n: cfg.hiddenSize,
                            weightOffset: try normOffset("model.norm.weight"))
            try gemv.q6kGEMV(cb, x: normBuf, weights: weightBuffer, weightOffset: embOffset,
                             inFeatures: cfg.hiddenSize, outFeatures: cfg.vocabularySize,
                             out: logitsBuf)
            metrics.gemmCount += 1
            metrics.computeKernelCount += 1
        }
    }

    private func readLogits() -> [Float] {
        let p = logitsBuf.contents().assumingMemoryBound(to: UInt16.self)
        var result = [Float](repeating: 0, count: config.vocabularySize)
        for i in 0..<config.vocabularySize { result[i] = Float(Float16(bitPattern: p[i])) }
        return result
    }

    /// 单 token 前向，返回 [vocabSize] fp32 logits。必须在 Task.detached 中执行。
    /// 行为与 G4 完全一致（1 个 command buffer、225 次 GEMV、258 个算子），golden 断言不变。
    public func forward(tokenID: Int, position: Int) throws -> [Float] {
        guard position >= 0, position < maxSeq else {
            throw SherryResidentError.buffer("POSITION_OVERFLOW pos=\(position) max=\(maxSeq)")
        }
        guard tokenID >= 0, tokenID < config.vocabularySize else {
            throw SherryResidentError.buffer("BAD_TOKEN id=\(tokenID)")
        }
        var m = ForwardMetrics()
        m.commandBuffers = 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        let cb = try ops.makeCommandBuffer()
        try encodeToken(cb, tokenID: tokenID, position: position, emitLogits: true, metrics: &m)
        let gpuStart = DispatchTime.now().uptimeNanoseconds
        try ops.commit(cb)
        m.gpuMs = Double(DispatchTime.now().uptimeNanoseconds - gpuStart) / 1e6
        m.wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        lastMetrics = m
        return readLogits()
    }

    /// H1 batched prefill：返回最后一个 prompt token 的 logits。
    /// 与「逐 token forward 并丢弃中间 logits」逐元素等价；但只提交 ceil(n/chunk)
    /// 个 command buffer，且中间提交不等待，显著减少 CPU-GPU 同步与 12 万维 logits 回读。
    public func prefill(ids: [Int], chunkSize: Int = 8) throws -> [Float] {
        guard !ids.isEmpty else { throw SherryResidentError.buffer("EMPTY_PREFILL") }
        guard ids.count <= maxSeq else { throw SherryResidentError.buffer("PREFILL_TOO_LONG") }
        for t in ids where t < 0 || t >= config.vocabularySize {
            throw SherryResidentError.buffer("BAD_TOKEN id=\(t)")
        }
        let chunk = max(1, chunkSize)
        var m = ForwardMetrics()
        m.commandBuffers = 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        var cb = try ops.makeCommandBuffer()
        var pending: [MTLCommandBuffer] = []
        let last = ids.count - 1
        let submitStart = DispatchTime.now().uptimeNanoseconds

        for (pos, tid) in ids.enumerated() {
            let isLast = pos == last
            try encodeToken(cb, tokenID: tid, position: pos,
                            emitLogits: isLast, metrics: &m)
            if (pos + 1) % chunk == 0 || isLast {
                if isLast {
                    try ops.commit(cb)          // 最后一块等待（FIFO 保证此前全部完成）
                } else {
                    ops.submit(cb)              // 中间块只提交、不等待
                }
                pending.append(cb)
                if !isLast {
                    cb = try ops.makeCommandBuffer()
                    m.commandBuffers += 1
                }
            }
        }
        // 最后一个 commit 已排空队列，此时所有中间 buffer 的 error 均已确定。
        for c in pending {
            if let e = c.error {
                throw SherryRuntimeError(code: "GPU_ERROR", message: "\(e)")
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        m.gpuMs = Double(end - submitStart) / 1e6
        m.wallMs = Double(end - t0) / 1e6
        lastMetrics = m
        return readLogits()
    }

    /// 最后一层 residual 之后的 hidden state（pre-final-norm），供 golden 对照。
    public func readHidden() -> [Float] {
        let p = xBuf.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<config.hiddenSize).map { Float(Float16(bitPattern: p[$0])) }
    }

    // MARK: - 独立 kernel 测试入口（不用于生产 forward）

    /// 对单个 GGUF 张量的前 maxOutFeatures 行做常驻 GEMV，返回 fp32 y。
    public func gemv(ggufTensorName: String, x: [Float],
                     maxOutFeatures: Int? = nil) throws -> [Float] {
        guard let info = gguf.tensor(named: ggufTensorName) else {
            throw SherryResidentError.unmapped(ggufTensorName)
        }
        let inF = info.inFeatures
        let outF = min(info.outFeatures, maxOutFeatures ?? info.outFeatures)
        guard let xb = device.makeBuffer(length: Self.aligned(inF * 2),
                                         options: .storageModeShared),
              let yb = device.makeBuffer(length: Self.aligned(outF * 2),
                                         options: .storageModeShared) else {
            throw SherryResidentError.buffer("gemv test")
        }
        let px = xb.contents().assumingMemoryBound(to: UInt16.self)
        for i in 0..<inF { px[i] = i < x.count ? Float16(x[i]).bitPattern : 0 }
        let cb = try ops.makeCommandBuffer()
        let abs = gguf.dataStart + info.offset
        switch info.type {
        case 42:
            try gemv.stq1_0(cb, x: xb, weights: weightBuffer, weightOffset: abs,
                            inFeatures: inF, outFeatures: outF, out: yb)
        case 14:
            try gemv.q6kGEMV(cb, x: xb, weights: weightBuffer, weightOffset: abs,
                             inFeatures: inF, outFeatures: outF, out: yb)
        default:
            throw SherryResidentError.unsupportedType(ggufTensorName, info.type)
        }
        try ops.commit(cb)
        let py = yb.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<outF).map { Float(Float16(bitPattern: py[$0])) }
    }

    /// 直接解码 Q6_K tied embedding 的某一行，供独立 golden 对照。
    public func embedRow(tokenID: Int) throws -> [Float] {
        guard let info = gguf.tensor(named: "token_embd.weight") else {
            throw SherryResidentError.missingOffset("token_embd.weight")
        }
        let n = info.inFeatures
        guard let out = device.makeBuffer(length: Self.aligned(n * 2),
                                          options: .storageModeShared) else {
            throw SherryResidentError.buffer("embed test")
        }
        let cb = try ops.makeCommandBuffer()
        try gemv.q6kEmbedRow(cb, weights: weightBuffer,
                             weightOffset: gguf.dataStart + info.offset,
                             tokenID: tokenID, n: n, out: out)
        try ops.commit(cb)
        let p = out.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<n).map { Float(Float16(bitPattern: p[$0])) }
    }
}
