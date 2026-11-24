import Foundation

// 请求级可复现（H1 / 评测方法学修复）：
// 采样器不再作为实例属性跨请求复用。每次 generate 开头按 sampling.seed 重建 Sampler，
// 使「同一 prompt + 同一 seed + 同一采样参数」恒定产出同一 token 序列，
// 且不受此前任何请求的 RNG 状态影响。SamplingConfig.seed 由此真正生效。
//
// 注：默认 seed 与修复前 Sampler 的初始种子相同，因此**首个请求**的译文不变；
// 变化的是第 2 个及之后的请求（此前会延续前序请求消耗掉的 RNG state）。
// 权重格式口径不变：STQ1_0 1.3125 bpw（NOT LUT4 / NOT affine INT4）。

public final class SherryGenerator: @unchecked Sendable {
    public let model: SherryResidentModel
    public let tokenizer: HymnTokenizer
    /// 后端级兜底种子；仅当请求的 sampling.seed == 0 时使用。
    private let defaultSeed: UInt64

    public init(model: SherryResidentModel, tokenizer: HymnTokenizer,
                seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.model = model
        self.tokenizer = tokenizer
        self.defaultSeed = seed
    }

    public func generate(
        promptIDs: [Int],
        maxTokens: Int,
        sampling: SamplingConfig = SamplingConfig(),
        onToken: (Int) -> Void,
        isCancelled: () -> Bool = { false }
    ) throws -> GenerationMetrics {
        guard !promptIDs.isEmpty else {
            throw SherryResidentError.buffer("EMPTY_PROMPT")
        }
        // 超出 KV 窗口不该直接失败：调用方（尤其是 PDF 逐段翻译）给的是
        // 「希望生成多少」，而不是「确定能放下多少」。硬抛的后果是整段回落原文——
        // 一页 1300 字的长段落会整段保留英文。这里改成按剩余窗口截断，
        // 并如实记录，让上层自己决定是否重试/分段。
        let capacity = model.maxSeq - promptIDs.count
        guard capacity >= 16 else {
            throw SherryResidentError.buffer(
                "PROMPT_TOO_LONG prompt=\(promptIDs.count) max=\(model.maxSeq)")
        }
        let limit = min(maxTokens, capacity)
        var metrics = GenerationMetrics(promptTokens: promptIDs.count)
        metrics.hitTokenLimit = limit < maxTokens && maxTokens > 0
        let t0 = DispatchTime.now().uptimeNanoseconds

        // 每请求独立实例化：局部量天然线程安全，无需 NSLock；
        // 单实例调度（maxConcurrency = 1）之外也不会出现共享可变状态。
        var sampler = Sampler(seed: sampling.seed == 0 ? defaultSeed : sampling.seed)

        // H1 batched prefill：数值与逐 token forward 逐元素等价，但只提交 ceil(n/8)
        // 个 command buffer、中间不等待、跳过中间 token 的 lm_head。
        // HYMN_BATCHED_PREFILL=0 可回退到原逐 token 路径做 A/B 基准对照。
        let batched = ProcessInfo.processInfo.environment["HYMN_BATCHED_PREFILL"] != "0"
        var logits: [Float]
        if batched && promptIDs.count > 1 {
            if isCancelled() { metrics.cancelled = true; return metrics }
            logits = try model.prefill(ids: promptIDs)
        } else {
            logits = []
            for (pos, tid) in promptIDs.enumerated() {
                if isCancelled() { metrics.cancelled = true; return metrics }
                logits = try model.forward(tokenID: tid, position: pos)
            }
        }
        let prefillEnd = DispatchTime.now().uptimeNanoseconds
        metrics.prefillMs = Double(prefillEnd - t0) / 1e6

        var history = promptIDs
        var position = promptIDs.count
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        var firstTokenAt: UInt64 = 0

        for _ in 0..<max(1, limit) {
            if isCancelled() { metrics.cancelled = true; break }
            let next = sampler.sample(logits: logits, history: history, config: sampling)
            if firstTokenAt == 0 { firstTokenAt = DispatchTime.now().uptimeNanoseconds }
            if next == tokenizer.eosID {
                metrics.eosReached = true
                break
            }
            onToken(next)
            history.append(next)
            metrics.generatedTokens += 1
            position += 1
            if isCancelled() { metrics.cancelled = true; break }
            logits = try model.forward(tokenID: next, position: position - 1)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        metrics.decodeMs = Double(end - decodeStart) / 1e6
        metrics.ttftMs = metrics.prefillMs
            + (firstTokenAt == 0 ? 0 : Double(firstTokenAt - prefillEnd) / 1e6)
        if metrics.generatedTokens > 0 {
            metrics.tokensPerSecond = Double(metrics.generatedTokens) / (metrics.decodeMs / 1000.0)
        }
        return metrics
    }
}
