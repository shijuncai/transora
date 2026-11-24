import Foundation
import Darwin
import HymnCore

public struct TestResult: Sendable, Equatable {
    public let suite: String
    public let name: String
    public let passed: Bool
    public let detail: String
    public let nanos: UInt64
}

public func check(
    suite: String,
    _ name: String,
    _ condition: @autoclosure () -> Bool,
    detail: @autoclosure () -> String = ""
) -> TestResult {
    let start = DispatchTime.now().uptimeNanoseconds
    let ok = condition()
    return TestResult(
        suite: suite,
        name: name,
        passed: ok,
        detail: detail(),
        nanos: DispatchTime.now().uptimeNanoseconds - start
    )
}

public func measured<T>(
    suite: String,
    _ name: String,
    _ body: () throws -> T,
    validate: (T) -> Bool,
    detail: (T) -> String = { _ in "" }
) -> TestResult {
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        let value = try body()
        return TestResult(
            suite: suite, name: name, passed: validate(value),
            detail: detail(value),
            nanos: DispatchTime.now().uptimeNanoseconds - start
        )
    } catch {
        return TestResult(
            suite: suite, name: name, passed: false,
            detail: "threw: \(error)",
            nanos: DispatchTime.now().uptimeNanoseconds - start
        )
    }
}

/// 记录推理后端被同时占用的峰值，用于验证「单模型实例」约束。
public final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0
    private var mainThreadTokens = 0
    private var observedTokens = 0

    public init() {}

    public func enter() {
        lock.lock(); defer { lock.unlock() }
        current += 1
        if current > peak { peak = current }
    }

    public func leave() {
        lock.lock(); defer { lock.unlock() }
        current -= 1
    }

    public func token(onMainThread: Bool) {
        lock.lock(); defer { lock.unlock() }
        observedTokens += 1
        if onMainThread { mainThreadTokens += 1 }
    }

    public func peakConcurrency() -> Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    public func mainThreadTokenCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return mainThreadTokens
    }

    public func tokenCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return observedTokens
    }
}

/// 可观测的测试替身后端：记录并发峰值、token 产出线程。
public struct ProbeBackend: InferenceBackend {
    public let identifier: String = "probe-v0 (TEST DOUBLE / NOT MODEL INFERENCE)"
    public let declaredWeightFormat: String = "none"
    public let performsRealModelInference: Bool = false
    public let probe: ConcurrencyProbe
    public let tokenCount: Int
    public let tokenDelayNanos: UInt64

    public init(probe: ConcurrencyProbe, tokenCount: Int = 6, tokenDelayNanos: UInt64 = 1_000_000) {
        self.probe = probe
        self.tokenCount = tokenCount
        self.tokenDelayNanos = tokenDelayNanos
    }

    public func prepare() async throws {}

    public func stream(
        _ request: InferenceRequest,
        cancellation: CancellationRegistry
    ) -> AsyncThrowingStream<TokenChunk, any Error> {
        let count = min(tokenCount, max(1, request.maxTokens))
        let delay = tokenDelayNanos
        let probe = self.probe
        return AsyncThrowingStream<TokenChunk, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                probe.enter()
                defer { probe.leave() }
                for i in 0..<count {
                    if await cancellation.isCancelled(request.id) {
                        continuation.finish(throwing: HymnFailure.cancelled(request.id))
                        return
                    }
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    // Thread.isMainThread 在 async 上下文被 Swift 6 禁用，改用 POSIX 主线程判定。
                    probe.token(onMainThread: pthread_main_np() != 0)
                    continuation.yield(TokenChunk(requestID: request.id, index: i, text: "[probe:\(i)]"))
                }
                continuation.yield(TokenChunk(requestID: request.id, index: count, text: "", isFinal: true))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func shutdown() async {}
}

/// 主线程 tick 记录器，用于量化推理负载期间的主线程响应性。
public final class TickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [UInt64] = []

    public init() {}

    public func record() {
        lock.lock(); defer { lock.unlock() }
        stamps.append(DispatchTime.now().uptimeNanoseconds)
    }

    public func summary() -> (count: Int, maxGapMs: Double, avgGapMs: Double) {
        lock.lock(); defer { lock.unlock() }
        guard stamps.count >= 2 else { return (stamps.count, 0, 0) }
        var gaps: [UInt64] = []
        for i in 1..<stamps.count { gaps.append(stamps[i] - stamps[i - 1]) }
        let maxNs = gaps.max() ?? 0
        let sum = gaps.reduce(UInt64(0), +)
        return (
            stamps.count,
            Double(maxNs) / 1_000_000.0,
            Double(sum / UInt64(gaps.count)) / 1_000_000.0
        )
    }
}
