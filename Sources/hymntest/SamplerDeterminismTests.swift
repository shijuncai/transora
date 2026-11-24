import Foundation
import HymnCore
import HymnSTQ

// 请求级可复现验收：
//  1) 纯 Sampler 单元测试（无模型、毫秒级）：同 seed 序列一致、不同 seed 生效、greedy 确定。
//  2) 真实后端端到端：同一请求在插入其他请求之后复跑，译文必须逐字一致。
// 第 2 项是修复前做不到的：旧 Sampler 的 RNG state 会跨请求延续。

private func determinismModelDirectory() -> URL {
    if let d = ProcessInfo.processInfo.environment["HYMN_SHERRY_MODEL_DIR"] {
        return URL(fileURLWithPath: d)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Models/Hy-MT2-1.8B-1.25Bit-GGUF", isDirectory: true)
}

private func collectText(_ engine: TranslationEngine,
                         _ req: InferenceRequest) async throws -> String {
    var text = ""
    for try await chunk in await engine.stream(req) {
        if chunk.isFinal { continue }
        text += chunk.text
    }
    return text
}

public func samplerDeterminismSuite() async throws -> [TestResult] {
    let suite = "sampler-determinism"
    var out: [TestResult] = []

    // MARK: - 1) 纯采样器单元测试

    // 固定、非退化的 logits：有一定熵，采样路径会真正消耗 RNG。
    let logits: [Float] = (0..<64).map { i in
        Float(sin(Double(i) * 0.37) * 3.0) + Float(i) * 0.01
    }
    let history = [1, 5, 9]

    func sequence(_ config: SamplingConfig, rounds: Int) -> [Int] {
        var s = Sampler(seed: config.seed)
        var h = history
        var result: [Int] = []
        for _ in 0..<rounds {
            let id = s.sample(logits: logits, history: h, config: config)
            result.append(id)
            h.append(id)
        }
        return result
    }

    let cfgA = SamplingConfig(seed: 0x1234_5678_9ABC_DEF0)
    let cfgB = SamplingConfig(seed: 0xFEDC_BA98_7654_3210)
    let s1 = sequence(cfgA, rounds: 24)
    let s2 = sequence(cfgA, rounds: 24)
    let s3 = sequence(cfgB, rounds: 24)

    out.append(check(suite: suite, "同一 seed 两次采样序列逐项一致", s1 == s2,
                     detail: "len=\(s1.count) head=\(Array(s1.prefix(6)))"))
    out.append(check(suite: suite, "不同 seed 产出不同序列（seed 真正生效，非死字段）",
                     s1 != s3, detail: "A=\(Array(s1.prefix(5))) B=\(Array(s3.prefix(5)))"))

    let g1 = sequence(SamplingConfig.greedy, rounds: 12)
    let g2 = sequence(SamplingConfig.greedy, rounds: 12)
    out.append(check(suite: suite, "greedy 序列确定且恒定 argmax",
                     g1 == g2 && Set(g1).count == 1 && g1.first == logits.indices.max(by: { logits[$0] < logits[$1] }),
                     detail: "argmax=\(g1.first ?? -1)"))

    // 模拟「前一个请求消耗了 RNG」：重建 Sampler 后必须与全新实例完全一致。
    var polluted = Sampler(seed: cfgA.seed)
    for _ in 0..<17 { _ = polluted.sample(logits: logits, history: history, config: cfgA) }
    let rebuilt = sequence(cfgA, rounds: 24)
    out.append(check(suite: suite, "重建 Sampler 后不受前序 RNG 消耗影响",
                     rebuilt == s1, detail: "rebuilt=\(Array(rebuilt.prefix(6)))"))

    // MARK: - 2) 真实后端端到端（需要 1.25bit GGUF）

    let dir = determinismModelDirectory()
    let gguf = dir.appendingPathComponent("Hy-MT2-1.8B-1.25Bit.gguf")
    guard FileManager.default.fileExists(atPath: gguf.path) else {
        out.append(check(suite: suite, "端到端复现（模型可用时执行）", false,
                         detail: "SKIP: 缺少 \(gguf.path)"))
        return out
    }

    let reqA = InferenceRequest(text: "Hello, nice to meet you.",
                                languages: LanguagePair(source: "en", target: "zh"),
                                maxTokens: 32)
    let reqB = InferenceRequest(text: "Machine learning is changing the world.",
                                languages: LanguagePair(source: "en", target: "zh"),
                                maxTokens: 32)

    do {
        let backend = SherryBackend(modelDirectory: dir)
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()

        let a1 = try await collectText(engine, reqA)
        let b = try await collectText(engine, reqB)
        let a2 = try await collectText(engine, reqA)
        let a3 = try await collectText(engine, reqA)

        out.append(check(suite: suite, "端到端：同一请求跨其他请求复跑译文逐字一致",
                         !a1.isEmpty && a1 == a2 && a2 == a3,
                         detail: "a1=\(a1) | interrupt=\(b.prefix(24)) | a2=\(a2) | a3=\(a3)"))
        out.append(check(suite: suite, "端到端：不同输入确实产出不同译文（排除恒等假通过）",
                         !b.isEmpty && a1 != b,
                         detail: "a=\(a1.prefix(24)) b=\(b.prefix(24))"))
        await engine.shutdown()
    } catch {
        out.append(check(suite: suite, "端到端：同一请求跨其他请求复跑译文逐字一致", false,
                         detail: "threw: \(error)"))
    }

    do {
        let greedyBackend = SherryBackend(modelDirectory: dir, sampling: .greedy)
        let greedyEngine = TranslationEngine(backend: greedyBackend)
        try await greedyEngine.prepare()
        let g1 = try await collectText(greedyEngine, reqA)
        let g2 = try await collectText(greedyEngine, reqA)
        out.append(check(suite: suite, "端到端：greedy 模式译文确定且不为空",
                         !g1.isEmpty && g1 == g2, detail: "greedy=\(g1)"))
        await greedyEngine.shutdown()
    } catch {
        out.append(check(suite: suite, "端到端：greedy 模式译文确定且不为空", false,
                         detail: "threw: \(error)"))
    }

    return out
}
