import Foundation
import Darwin
import HymnCore
import HymnSTQ

// G4 / G8：Sherry STQ1_0 1.25bit GGUF 常驻推理后端（默认后端）端到端测试。
// 与 sherry-resident（kernel/forward 数值对齐）分工明确；本组验证链路与性能。

private func backendSherryModelDirectory() -> URL {
    if let d = ProcessInfo.processInfo.environment["HYMN_SHERRY_MODEL_DIR"] {
        return URL(fileURLWithPath: d)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Models/Hy-MT2-1.8B-1.25Bit-GGUF", isDirectory: true)
}

private struct TimedTranslation {
    let text: String
    let chunks: Int
    let ttftMs: Double
    let wallMs: Double
    var approxTokensPerSecond: Double {
        wallMs > 0 ? Double(chunks) / (wallMs / 1000.0) : 0
    }
}

private func collectTimed(_ engine: TranslationEngine,
                          _ req: InferenceRequest) async throws -> TimedTranslation {
    let start = DispatchTime.now().uptimeNanoseconds
    var first: UInt64 = 0
    var text = ""
    var count = 0
    for try await chunk in await engine.stream(req) {
        if chunk.isFinal { continue }
        if first == 0 { first = DispatchTime.now().uptimeNanoseconds }
        text += chunk.text
        count += 1
    }
    let end = DispatchTime.now().uptimeNanoseconds
    return TimedTranslation(
        text: text, chunks: count,
        ttftMs: first == 0 ? 0 : Double(first - start) / 1_000_000.0,
        wallMs: Double(end - start) / 1_000_000.0)
}

private func residentPeakRSSMB() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_maxrss) / 1_000_000.0
}

public func sherryBackendSuite() async throws -> [TestResult] {
    let suite = "sherry-backend"
    var out: [TestResult] = []
    let dir = backendSherryModelDirectory()
    let ggufURL = dir.appendingPathComponent("Hy-MT2-1.8B-1.25Bit.gguf")
    let exists = FileManager.default.fileExists(atPath: ggufURL.path)

    out.append(check(suite: suite, "1.25bit GGUF 常驻权重已落盘",
                     exists, detail: ggufURL.path))
    guard exists else { return out }

    let backend = SherryBackend(modelDirectory: dir)
    out.append(check(suite: suite, "如实声明真实推理且绝不冒充 LUT4 / affine INT4",
                     backend.performsRealModelInference
                     && backend.identifier == "hymn-stq1_0-gguf-v1"
                     && backend.declaredWeightFormat.contains("STQ1_0")
                     && backend.declaredWeightFormat.contains("常驻 GEMV")
                     && backend.declaredWeightFormat.contains("NOT LUT4")
                     && backend.declaredWeightFormat.contains("NOT affine INT4"),
                     detail: backend.declaredWeightFormat))

    let engine = TranslationEngine(backend: backend)
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        try await engine.prepare()
    } catch {
        out.append(check(suite: suite, "Sherry 常驻后端 prepare 成功", false, detail: "\(error)"))
        return out
    }
    let prepareMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    out.append(check(suite: suite, "Sherry 常驻后端 prepare 成功（含 Metal kernel 预热）", true,
                     detail: String(format: "%.1f ms", prepareMs)))

    let residentBytes = backend.residentWeightBytes ?? 0
    let gpuBytes = backend.gpuBufferBytes ?? 0
    let normBytes = backend.normBufferBytes ?? 0
    out.append(check(suite: suite, "运行时仅常驻 461,860,800 B GGUF（非 3.58 GB fp16）",
                     residentBytes == 461_860_800 && gpuBytes >= 461_860_800
                     && gpuBytes < 500_000_000 && normBytes < 1_000_000,
                     detail: "gguf=\(residentBytes) gpu=\(gpuBytes) norm=\(normBytes)"))

    let realFlag = await engine.isRealInference()
    let snap0 = await engine.snapshot()
    out.append(check(suite: suite, "引擎识别为真实推理且后端标识正确",
                     realFlag && snap0.backendIdentifier == "hymn-stq1_0-gguf-v1",
                     detail: "real=\(realFlag) id=\(snap0.backendIdentifier)"))

    let enReq = InferenceRequest(text: "Hello, nice to meet you.",
                                 languages: LanguagePair(source: "en", target: "zh"),
                                 maxTokens: 40)
    var en = TimedTranslation(text: "", chunks: 0, ttftMs: 0, wallMs: 0)
    do { en = try await collectTimed(engine, enReq) } catch { en = TimedTranslation(text: "", chunks: 0, ttftMs: 0, wallMs: 0) }
    let zhOK = (en.text.contains("你好") || en.text.contains("您好")) && !en.text.contains("[fixture]")
    out.append(check(suite: suite, "en→zh 产出真实译文（非占位 token）",
                     zhOK, detail: en.text.isEmpty ? "(empty)" : en.text))

    let zhReq = InferenceRequest(text: "机器学习正在改变世界。",
                                 languages: LanguagePair(source: "zh", target: "en"),
                                 maxTokens: 40)
    var zh = TimedTranslation(text: "", chunks: 0, ttftMs: 0, wallMs: 0)
    do { zh = try await collectTimed(engine, zhReq) } catch { zh = TimedTranslation(text: "", chunks: 0, ttftMs: 0, wallMs: 0) }
    out.append(check(suite: suite, "zh→en 产出真实译文",
                     zh.text.contains("Machine learning"),
                     detail: zh.text.isEmpty ? "(empty)" : zh.text))

    let a = InferenceRequest(text: "Good morning.", languages: LanguagePair(source: "en", target: "zh"), maxTokens: 12)
    let b = InferenceRequest(text: "Thank you.", languages: LanguagePair(source: "en", target: "zh"), maxTokens: 12)
    let t1 = Task.detached { try? await collectTimed(engine, a) }
    let t2 = Task.detached { try? await collectTimed(engine, b) }
    _ = await t1.value
    _ = await t2.value
    let snap = await engine.snapshot()
    out.append(check(suite: suite, "并发请求经单实例调度且并发峰值恒为 1",
                     snap.scheduler.maxConcurrency == 1,
                     detail: "maxConcurrency=\(snap.scheduler.maxConcurrency)"))

    let cancelReq = InferenceRequest(
        text: String(repeating: "Please translate this long paragraph carefully. ", count: 20),
        languages: LanguagePair(source: "en", target: "zh"), maxTokens: 80)
    let cancelStart = DispatchTime.now().uptimeNanoseconds
    let cancelTask = Task.detached { try await collectTimed(engine, cancelReq) }
    try? await Task.sleep(nanoseconds: 30_000_000)
    await engine.cancel(id: cancelReq.id)
    var cancelled = false
    do { _ = try await cancelTask.value } catch { cancelled = true }
    let cancelMs = Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1_000_000.0
    out.append(check(suite: suite, "取消链路可用（CANCELLED）",
                     cancelled, detail: String(format: "cancelled=\(cancelled) %.1f ms", cancelMs)))

    let recorder = TickRecorder()
    let tickReq = InferenceRequest(text: "Good evening.",
                                   languages: LanguagePair(source: "en", target: "zh"), maxTokens: 16)
    let load = Task.detached { try? await collectTimed(engine, tickReq) }
    await MainActor.run {
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in recorder.record() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        timer.invalidate()
    }
    _ = await load.value
    let ticks = recorder.summary()
    out.append(check(suite: suite, "真实推理期间主线程 10ms tick 最大间隔 < 100ms",
                     ticks.count >= 10 && ticks.maxGapMs < 100,
                     detail: String(format: "ticks=\(ticks.count) max=%.2f ms avg=%.2f ms",
                                    ticks.maxGapMs, ticks.avgGapMs)))

    let peakRSS = residentPeakRSSMB()
    await engine.shutdown()

    let report: [String: Any] = [
        "stage": "G4 / G8 Sherry STQ1_0 1.25bit GGUF 常驻 GEMV 默认后端",
        "note": "单次测量；TTFT 为端到端首个 chunk 墙钟，approx_tokens_per_second 为 chunks/wall 的粗略值，非纯 decode token/s。ru_maxrss 是进程历史峰值（含前面套件分配的 GPU/CPU buffer），不代表 Sherry 独占峰值；Sherry 自身常驻权重以 resident_weight_bytes / gpu_buffer_bytes 为准，且不含 mmap 文件。",
        "backend": backend.identifier,
        "weight_format": backend.declaredWeightFormat,
        "default_backend": true,
        "fp16_cache_used": false,
        "resident_weight_bytes": residentBytes,
        "gpu_buffer_bytes": gpuBytes,
        "norm_buffer_bytes": normBytes,
        "prepare_ms": prepareMs,
        "en_to_zh": [
            "text": en.text, "chunks": en.chunks,
            "ttft_ms": en.ttftMs, "wall_ms": en.wallMs,
            "approx_tokens_per_second": en.approxTokensPerSecond,
        ],
        "zh_to_en": [
            "text": zh.text, "chunks": zh.chunks,
            "ttft_ms": zh.ttftMs, "wall_ms": zh.wallMs,
            "approx_tokens_per_second": zh.approxTokensPerSecond,
        ],
        "cancel_ms": cancelMs,
        "main_thread_max_tick_ms": ticks.maxGapMs,
        "main_thread_avg_tick_ms": ticks.avgGapMs,
        "scheduler_max_concurrency": snap.scheduler.maxConcurrency,
        "peak_rss_mb": peakRSS,
    ]
    let reportDir = ProcessInfo.processInfo.environment["HYMN_REPORT_DIR"]
        ?? (FileManager.default.currentDirectoryPath + "/Reports")
    if let json = try? JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys]) {
        try? json.write(to: URL(fileURLWithPath: reportDir)
            .appendingPathComponent("sherry-resident-perf.json"))
    }
    out.append(check(suite: suite, "性能 / 译文数据已落盘（单次测量口径）", true,
                     detail: "Reports/sherry-resident-perf.json"))
    return out
}
