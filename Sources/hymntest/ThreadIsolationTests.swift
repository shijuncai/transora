import Foundation
import HymnCore

/// 主线程响应性实测：
/// 主线程以 10ms 周期打点，同时在后台执行一批推理负载；
/// 若推理占用主线程，tick 间隔会出现显著毛刺。
func threadIsolationSuite() async throws -> [TestResult] {
    let suite = "MainThreadIsolation"
    var out: [TestResult] = []
    let recorder = TickRecorder()
    let probe = ConcurrencyProbe()
    let engine = TranslationEngine(
        backend: ProbeBackend(probe: probe, tokenCount: 30, tokenDelayNanos: 1_000_000)
    )
    try await engine.prepare()

    // 后台负载：12 条请求 × 30 token，全部走 cooperative thread pool。
    let load = Task.detached(priority: .userInitiated) {
        let reqs = (0..<12).map { InferenceRequest(text: "load-\($0)", maxTokens: 30) }
        return await BatchTranslator(engine: engine).translateAll(reqs, maxInFlight: 12)
    }

    await MainActor.run {
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in recorder.record() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        timer.invalidate()
    }

    let outcomes = await load.value
    let summary = recorder.summary()
    out.append(check(suite: suite, "主线程 tick 正常打点（>=20 次）",
                     summary.count >= 20, detail: "ticks=\(summary.count)"))
    out.append(check(suite: suite, "推理负载期间主线程最大 tick 间隔 < 100 ms",
                     summary.maxGapMs < 100.0,
                     detail: String(format: "max=%.2f ms avg=%.2f ms", summary.maxGapMs, summary.avgGapMs)))
    out.append(check(suite: suite, "后台 12 条负载全部完成",
                     outcomes.count == 12 && outcomes.allSatisfy(\.succeeded)))
    out.append(check(suite: suite, "推理 token 全部来自非主线程",
                     probe.mainThreadTokenCount() == 0 && probe.tokenCount() == 360,
                     detail: "main=\(probe.mainThreadTokenCount()) total=\(probe.tokenCount())"))
    out.append(check(suite: suite, "后端并发峰值恒为 1",
                     probe.peakConcurrency() == 1, detail: "peak=\(probe.peakConcurrency())"))
    return out
}
