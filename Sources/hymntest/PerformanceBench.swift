import Foundation
import HymnCore
import HymnStore

struct PerfReport: Encodable {
    let generatedAt: String
    let machine: String
    let osVersion: String
    let swiftVersion: String
    let backend: String
    let disclaimer: String
    let metrics: [String: Double]
}

private func ms(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000.0 }

func performanceBench() async throws -> PerfReport {
    var m: [String: Double] = [:]
    let fixture = FixtureBackend(tokenCount: 1, tokenDelayNanos: 0)

    // 1) 调度器吞吐：300 个请求，零模拟延迟，测纯调度开销
    do {
        let engine = TranslationEngine(backend: fixture)
        try await engine.prepare()
        let n = 300
        let reqs = (0..<n).map { InferenceRequest(text: "bench-\($0)", maxTokens: 1) }
        let start = DispatchTime.now().uptimeNanoseconds
        let outcomes = await BatchTranslator(engine: engine).translateAll(reqs, maxInFlight: 32)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        m["scheduler_requests_per_sec"] = Double(n) / (Double(elapsed) / 1_000_000_000.0)
        m["scheduler_300_total_ms"] = ms(elapsed)
        m["scheduler_success_rate_pct"] = Double(outcomes.filter(\.succeeded).count) / Double(n) * 100
    }

    // 2) 流式首 token 延迟（40 次顺序采样）
    do {
        let backend = FixtureBackend(tokenCount: 6, tokenDelayNanos: 400_000)
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()
        var samples: [Double] = []
        for i in 0..<40 {
            let req = InferenceRequest(text: "lat-\(i)", maxTokens: 6)
            let start = DispatchTime.now().uptimeNanoseconds
            for try await chunk in await engine.stream(req) where !chunk.isFinal {
                samples.append(ms(DispatchTime.now().uptimeNanoseconds - start))
                break
            }
        }
        samples.sort()
        if !samples.isEmpty {
            m["stream_first_token_avg_ms"] = samples.reduce(0, +) / Double(samples.count)
            m["stream_first_token_p50_ms"] = samples[samples.count / 2]
            m["stream_first_token_p95_ms"] = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
            m["stream_first_token_max_ms"] = samples.last ?? 0
        }
    }

    // 3) 批量吞吐（含每 token 计算占位）
    do {
        let backend = FixtureBackend(tokenCount: 8, tokenDelayNanos: 200_000)
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()
        let n = 100
        let reqs = (0..<n).map { InferenceRequest(text: "batch-\($0)", maxTokens: 8) }
        let start = DispatchTime.now().uptimeNanoseconds
        let outcomes = await BatchTranslator(engine: engine).translateAll(reqs, maxInFlight: 16)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        m["batch_100_requests_per_sec"] = Double(n) / (Double(elapsed) / 1_000_000_000.0)
        m["batch_100_total_ms"] = ms(elapsed)
        m["batch_tokens_emitted"] = Double(outcomes.reduce(0) { $0 + $1.tokenCount })
    }

    // 4) 取消响应延迟
    do {
        let backend = FixtureBackend(tokenCount: 100_000, tokenDelayNanos: 1_000_000)
        let engine = TranslationEngine(backend: backend)
        try await engine.prepare()
        let req = InferenceRequest(text: "cancel", maxTokens: 100_000)
        let task = Task { try await engine.translate(req) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        await engine.cancel(id: req.id)
        let result = try await task.value
        m["cancel_response_ms"] = ms(DispatchTime.now().uptimeNanoseconds - start)
        m["cancel_tokens_before_stop"] = Double(result.tokenCount)
    }

    // 5) SQLite 写入 / 查询
    do {
        let store = try SQLiteStore(path: ":memory:")
        defer { store.close() }
        let rows = 5000
        let records = (0..<rows).map { i in
            HistoryRecord(sourceLang: "en", targetLang: "zh",
                          sourceText: "bench sentence \(i)", targetText: "[fixture] \(i)",
                          createdAt: Int64(1_700_000_000_000 + i))
        }
        let writeNs = try store.insertHistoryBatch(records)
        m["sqlite_insert_rows_per_sec"] = Double(rows) / (Double(writeNs) / 1_000_000_000.0)
        m["sqlite_insert_5000_ms"] = ms(writeNs)
        let qStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { _ = try store.fetchHistory(limit: 20) }
        m["sqlite_query_avg_ms"] = ms(DispatchTime.now().uptimeNanoseconds - qStart) / 200.0
        m["sqlite_row_count"] = Double(try store.countHistory())
    }

    // 6) 主线程响应性（10ms ticker，后台满载）
    do {
        let recorder = TickRecorder()
        let engine = TranslationEngine(
            backend: FixtureBackend(tokenCount: 20, tokenDelayNanos: 800_000)
        )
        try await engine.prepare()
        let load = Task.detached(priority: .userInitiated) {
            let reqs = (0..<16).map { InferenceRequest(text: "mt-\($0)", maxTokens: 20) }
            return await BatchTranslator(engine: engine).translateAll(reqs, maxInFlight: 16)
        }
        await MainActor.run {
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in recorder.record() }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            timer.invalidate()
        }
        _ = await load.value
        let s = recorder.summary()
        m["main_thread_tick_count"] = Double(s.count)
        m["main_thread_max_gap_ms"] = s.maxGapMs
        m["main_thread_avg_gap_ms"] = s.avgGapMs
    }

    let formatter = ISO8601DateFormatter()
    var sys = utsname()
    uname(&sys)
    let machineSize = MemoryLayout.size(ofValue: sys.machine)
    let machine = withUnsafePointer(to: &sys.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
            String(cString: $0)
        }
    }

    return PerfReport(
        generatedAt: formatter.string(from: Date()),
        machine: machine,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        swiftVersion: "Swift 6.4 (swiftlang-6.4.0.34.1) / swift-tools-version 6.0",
        backend: fixture.identifier,
        disclaimer: "本性能数据来自 TEST DOUBLE 后端，仅度量调度/流式/取消/SQLite/主线程隔离的原生链路开销；不包含任何模型推理，不代表 Hy-MT2 1.8B 的 token/s。真实推理性能见 Reports/sherry-backend-perf.json 与 Reports/sherry-resident-perf.json（Sherry STQ1_0 常驻 GEMV 端到端实测）。",
        metrics: m
    )
}
