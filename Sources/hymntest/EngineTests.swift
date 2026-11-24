import Foundation
import HymnCore

func schedulerSuite() async -> [TestResult] {
    let suite = "Scheduler"
    var out: [TestResult] = []
    let scheduler = RequestScheduler()

    let a = UUID(), b = UUID(), c = UUID()
    let gotA = await scheduler.acquire(id: a, priority: 0)
    out.append(check(suite: suite, "首个请求立即获得模型使用权", gotA))

    let snap1 = await scheduler.snapshot()
    out.append(check(suite: suite, "快照 running == 首个请求",
                     snap1.running == a && snap1.maxConcurrency == 1))

    // 排队 + 优先级：b(低) 与 c(高) 同时排队，释放 a 后应由 c 先接手。
    async let low = scheduler.acquire(id: b, priority: 0)
    async let high = scheduler.acquire(id: c, priority: 10)
    try? await Task.sleep(nanoseconds: 20_000_000)
    let queued = await scheduler.snapshot()
    out.append(check(suite: suite, "两个请求进入队列且并发度保持 1",
                     queued.queued == 2 && queued.running == a,
                     detail: "queued=\(queued.queued)"))

    // 释放 a 后应先由高优先级的 c 接手；随后释放 c 才能让 b 的续体唤醒。
    // 注意：不能在等待 (low, high) 之前只释放一次，否则会形成自锁。
    await scheduler.release(id: a)
    let runningAfterA = await scheduler.snapshot().running
    await scheduler.release(id: c)
    let (gotLow, gotHigh) = await (low, high)
    await scheduler.release(id: b)
    out.append(check(suite: suite, "高优先级请求优先获得模型",
                     runningAfterA == c && gotHigh && gotLow,
                     detail: "runningAfterA=\(String(describing: runningAfterA)) low=\(gotLow) high=\(gotHigh)"))

    // 排队中取消：不应占用模型。
    let s2 = RequestScheduler()
    let x = UUID(), y = UUID()
    let gotX = await s2.acquire(id: x, priority: 0)
    let pending = Task { await s2.acquire(id: y, priority: 0) }
    try? await Task.sleep(nanoseconds: 20_000_000)
    await s2.cancel(id: y)
    let gotY = await pending.value
    let snap3 = await s2.snapshot()
    out.append(check(suite: suite, "排队中的请求被取消后 acquire 返回 false",
                     gotX && !gotY && snap3.queued == 0 && snap3.running == x,
                     detail: "gotY=\(gotY) queued=\(snap3.queued)"))
    await s2.release(id: x)

    let finalSnap = await scheduler.snapshot()
    out.append(check(suite: suite, "completed 计数与释放次数一致",
                     finalSnap.completed == 3, detail: "\(finalSnap.completed)"))
    return out
}

func engineSuite() async throws -> [TestResult] {
    let suite = "Engine"
    var out: [TestResult] = []
    let probe = ConcurrencyProbe()
    let backend = ProbeBackend(probe: probe, tokenCount: 8, tokenDelayNanos: 500_000)
    let engine = TranslationEngine(backend: backend)
    try await engine.prepare()

    let isRealInference = await engine.isRealInference()
    let backendID = await engine.backendIdentifier()
    out.append(check(suite: suite, "后端如实声明「非真实模型推理」",
                     isRealInference == false, detail: backendID))

    // 流式输出
    let req = InferenceRequest(text: "Hello", maxTokens: 8)
    var chunks: [TokenChunk] = []
    for try await chunk in await engine.stream(req) { chunks.append(chunk) }
    out.append(check(suite: suite, "流式输出 8 个 token + 1 个 final 标记",
                     chunks.count == 9 && chunks.last?.isFinal == true,
                     detail: "chunks=\(chunks.count)"))
    out.append(check(suite: suite, "token 序号严格递增且属于同一请求",
                     chunks.dropLast().enumerated().allSatisfy { $0.element.index == $0.offset }
                        && chunks.allSatisfy { $0.requestID == req.id }))

    // 一次性翻译聚合
    let result = try await engine.translate(InferenceRequest(text: "聚合测试", maxTokens: 8))
    out.append(check(suite: suite, "一次性翻译聚合文本与 token 数",
                     result.tokenCount == 8 && result.text == (0..<8).map { "[probe:\($0)]" }.joined()
                        && !result.wasCancelled && result.firstTokenNanos != nil,
                     detail: "tokens=\(result.tokenCount) firstTokenNs=\(result.firstTokenNanos ?? 0)"))

    // 取消：长任务中途取消
    let longBackend = ProbeBackend(probe: ConcurrencyProbe(), tokenCount: 200, tokenDelayNanos: 3_000_000)
    let longEngine = TranslationEngine(backend: longBackend)
    try await longEngine.prepare()
    let longReq = InferenceRequest(text: "cancellation", maxTokens: 200)
    let cancelStart = DispatchTime.now().uptimeNanoseconds
    let cancelTask = Task { try await longEngine.translate(longReq) }
    try await Task.sleep(nanoseconds: 25_000_000)
    await longEngine.cancel(id: longReq.id)
    let cancelledResult = try await cancelTask.value
    let cancelLatencyNs = DispatchTime.now().uptimeNanoseconds - cancelStart
    out.append(check(suite: suite, "任务取消：wasCancelled=true 且提前停止",
                     cancelledResult.wasCancelled && cancelledResult.tokenCount < 200,
                     detail: "tokens=\(cancelledResult.tokenCount)/200"))
    out.append(check(suite: suite, "取消响应延迟 < 100 ms",
                     cancelLatencyNs < 100_000_000,
                     detail: String(format: "%.2f ms", Double(cancelLatencyNs) / 1_000_000)))

    // 单实例：并发提交 12 个请求，后端并发峰值必须为 1
    let sharedProbe = ConcurrencyProbe()
    let sharedBackend = ProbeBackend(probe: sharedProbe, tokenCount: 4, tokenDelayNanos: 300_000)
    let sharedEngine = TranslationEngine(backend: sharedBackend)
    try await sharedEngine.prepare()
    let many = (0..<12).map { InferenceRequest(text: "req-\($0)", maxTokens: 4) }
    let outcomes = await BatchTranslator(engine: sharedEngine).translateAll(many, maxInFlight: 12)
    let peak = sharedProbe.peakConcurrency()
    out.append(check(suite: suite, "12 个并发请求全部完成",
                     outcomes.count == 12 && outcomes.allSatisfy(\.succeeded),
                     detail: "\(outcomes.filter(\.succeeded).count)/12"))
    out.append(check(suite: suite, "单模型实例：后端并发峰值恒为 1",
                     peak == 1, detail: "peak=\(peak)"))
    out.append(check(suite: suite, "所有推理 token 均不在主线程产出",
                     sharedProbe.mainThreadTokenCount() == 0 && sharedProbe.tokenCount() == 48,
                     detail: "main=\(sharedProbe.mainThreadTokenCount()) total=\(sharedProbe.tokenCount())"))

    let snap = await sharedEngine.snapshot()
    out.append(check(suite: suite, "引擎快照 maxConcurrency=1 且 completed=12",
                     snap.scheduler.maxConcurrency == 1 && snap.scheduler.completed == 12,
                     detail: "completed=\(snap.scheduler.completed)"))

    // 批量整体取消
    let cancelBatchEngine = TranslationEngine(
        backend: ProbeBackend(probe: ConcurrencyProbe(), tokenCount: 400, tokenDelayNanos: 2_000_000)
    )
    try await cancelBatchEngine.prepare()
    let batchReqs = (0..<6).map { InferenceRequest(text: "b-\($0)", maxTokens: 400) }
    let translator = BatchTranslator(engine: cancelBatchEngine)
    let batchTask = Task { await translator.translateAll(batchReqs, maxInFlight: 6) }
    try await Task.sleep(nanoseconds: 20_000_000)
    await translator.cancelAll(batchReqs)
    let batchOutcomes = await batchTask.value
    out.append(check(suite: suite, "批量整体取消：无请求完整跑完 400 token",
                     batchOutcomes.count == 6 && batchOutcomes.allSatisfy { !$0.succeeded },
                     detail: batchOutcomes.map { $0.errorCode ?? "ok" }.joined(separator: ",")))

    return out
}
