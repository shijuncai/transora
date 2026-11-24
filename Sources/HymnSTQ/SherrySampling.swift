import Foundation

// MARK: - 采样配置（真实 generation_config.json 参数）

public struct SamplingConfig: Sendable, Equatable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var repetitionPenalty: Float
    public var seed: UInt64

    /// checkpoint generation_config.json: temp 0.7 / top_p 0.8 / top_k 20 / rep_penalty 1.05
    public init(temperature: Float = 0.7, topP: Float = 0.8, topK: Int = 20,
                repetitionPenalty: Float = 1.05, seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
    }

    public static let greedy = SamplingConfig(temperature: 0, topP: 1, topK: 1,
                                              repetitionPenalty: 1.0)
}

// MARK: - 采样器
//
// 顺序严格遵循 HF generation：repetition penalty → temperature → top-k → top-p → softmax → 采样。
// 使用 xorshift64 保证测试可复现（默认种子固定）。

public struct Sampler: Sendable {
    private var state: UInt64

    public init(seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    private mutating func nextUnit() -> Double {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return Double(x) / Double(UInt64.max)
    }

    public mutating func sample(logits: [Float], history: [Int], config: SamplingConfig) -> Int {
        guard !logits.isEmpty else { return 0 }
        var scores = logits

        // 1) repetition penalty
        if config.repetitionPenalty != 1.0 {
            var seen = Set<Int>()
            for id in history where id >= 0 && id < scores.count && seen.insert(id).inserted {
                if scores[id] > 0 { scores[id] /= config.repetitionPenalty }
                else { scores[id] *= config.repetitionPenalty }
            }
        }
        // 2) temperature
        if config.temperature > 0 {
            let t = config.temperature
            for i in 0..<scores.count { scores[i] /= t }
        } else {
            // greedy
            var best = 0
            for i in 1..<scores.count where scores[i] > scores[best] { best = i }
            return best
        }

        // 3) top-k（维护大小为 k 的最小堆，O(n log k)）
        let k = min(max(1, config.topK), scores.count)
        var heapIdx = [Int](repeating: 0, count: k)
        var heapVal = [Float](repeating: -.infinity, count: k)
        for i in 0..<scores.count {
            if i < k {
                heapIdx[i] = i; heapVal[i] = scores[i]
                if i == k - 1 { buildMinHeap(&heapIdx, &heapVal) }
            } else if scores[i] > heapVal[0] {
                heapIdx[0] = i; heapVal[0] = scores[i]
                siftDown(&heapIdx, &heapVal, 0)
            }
        }
        var candidates = [(index: Int, score: Float)]()
        candidates.reserveCapacity(k)
        for j in 0..<k where heapVal[j].isFinite {
            candidates.append((heapIdx[j], heapVal[j]))
        }
        candidates.sort { $0.score > $1.score }
        if candidates.isEmpty { return 0 }

        // 4) top-p（在 top-k 内按概率累积截断）
        var probs = [Double]()
        probs.reserveCapacity(candidates.count)
        let maxScore = candidates[0].score
        var sum = 0.0
        for c in candidates {
            let p = Double(exp(c.score - maxScore))
            probs.append(p)
            sum += p
        }
        var cutoff = candidates.count
        if config.topP > 0 && config.topP < 1 {
            var cumulative = 0.0
            for i in 0..<probs.count {
                cumulative += probs[i] / sum
                if cumulative >= Double(config.topP) { cutoff = i + 1; break }
            }
        }
        var targetSum = 0.0
        for i in 0..<cutoff { targetSum += probs[i] }
        // 5) 采样
        let r = nextUnit() * targetSum
        var acc = 0.0
        for i in 0..<cutoff {
            acc += probs[i]
            if r <= acc { return candidates[i].index }
        }
        return candidates[cutoff - 1].index
    }

    private func buildMinHeap(_ idx: inout [Int], _ val: inout [Float]) {
        guard idx.count > 1 else { return }
        for i in stride(from: idx.count / 2 - 1, through: 0, by: -1) {
            siftDown(&idx, &val, i)
        }
    }

    private func siftDown(_ idx: inout [Int], _ val: inout [Float], _ start: Int) {
        var i = start
        let n = idx.count
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < n && val[l] < val[smallest] { smallest = l }
            if r < n && val[r] < val[smallest] { smallest = r }
            if smallest == i { return }
            idx.swapAt(i, smallest); val.swapAt(i, smallest)
            i = smallest
        }
    }
}

// MARK: - 生成循环

public struct GenerationMetrics: Sendable, CustomStringConvertible {
    public var promptTokens: Int = 0
    public var generatedTokens: Int = 0
    public var prefillMs: Double = 0
    public var decodeMs: Double = 0
    public var ttftMs: Double = 0
    public var tokensPerSecond: Double = 0
    public var cancelled: Bool = false
    public var eosReached: Bool = false
    /// 请求的 `maxTokens` 放不进剩余 KV 窗口，已被截断。
    /// 上层据此判断「译文可能不完整」，而不是把半截译文当成完整译文。
    public var hitTokenLimit: Bool = false

    /// 跨模块（HymnSTQ 常驻 GEMV 生成循环）构造用；字段默认值与 D-1 完全一致。
    public init(promptTokens: Int = 0, generatedTokens: Int = 0,
                prefillMs: Double = 0, decodeMs: Double = 0, ttftMs: Double = 0,
                tokensPerSecond: Double = 0, cancelled: Bool = false,
                eosReached: Bool = false, hitTokenLimit: Bool = false) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.prefillMs = prefillMs
        self.decodeMs = decodeMs
        self.ttftMs = ttftMs
        self.tokensPerSecond = tokensPerSecond
        self.cancelled = cancelled
        self.eosReached = eosReached
        self.hitTokenLimit = hitTokenLimit
    }

    public var description: String {
        String(format: "prompt=%d generated=%d prefill=%.1fms ttft=%.1fms decode=%.1fms %.2f tok/s cancelled=%@ eos=%@",
               promptTokens, generatedTokens, prefillMs, ttftMs, decodeMs, tokensPerSecond,
               cancelled ? "yes" : "no", eosReached ? "yes" : "no")
            + (hitTokenLimit ? " TRUNCATED" : "")
    }
}
