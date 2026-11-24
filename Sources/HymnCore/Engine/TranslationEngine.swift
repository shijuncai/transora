import Foundation

public struct TranslationResult: Sendable, Equatable {
    public let requestID: UUID
    public let text: String
    public let tokenCount: Int
    public let firstTokenNanos: UInt64?
    public let totalNanos: UInt64
    public let wasCancelled: Bool
}

public struct EngineSnapshot: Sendable {
    public let scheduler: SchedulerSnapshot
    public let cancellationCount: Int
    public let backendIdentifier: String
    public let performsRealModelInference: Bool
}

/// 单模型实例编排层。
///
/// - 引擎持有一个且仅一个 `InferenceBackend`；
/// - 所有请求经 `RequestScheduler` 串行取得模型使用权；
/// - 所有推理循环运行在 `Task.detached`（cooperative thread pool），
///   不会占用主线程；
/// - 取消通过 `CancellationRegistry` + Swift Task cancellation 双重传播。
public actor TranslationEngine {
    private let backend: any InferenceBackend
    private let scheduler = RequestScheduler()
    private let cancellations = CancellationRegistry()
    private var prepared = false

    public init(backend: any InferenceBackend) {
        self.backend = backend
    }

    public func prepare() async throws {
        guard !prepared else { return }
        try await backend.prepare()
        prepared = true
    }

    public func backendIdentifier() -> String { backend.identifier }
    public func isRealInference() -> Bool { backend.performsRealModelInference }

    /// 流式翻译。返回的 AsyncThrowingStream 由调用方在任意 actor（含 MainActor）消费。
    public func stream(
        _ request: InferenceRequest
    ) -> AsyncThrowingStream<TokenChunk, any Error> {
        let backend = self.backend
        let scheduler = self.scheduler
        let cancellations = self.cancellations

        return AsyncThrowingStream<TokenChunk, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let granted = await scheduler.acquire(id: request.id, priority: request.priority)
                if !granted {
                    continuation.finish(throwing: HymnFailure.cancelled(request.id))
                    return
                }

                do {
                    for try await chunk in backend.stream(request, cancellation: cancellations) {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch let failure as HymnFailure {
                    continuation.finish(throwing: failure)
                } catch is CancellationError {
                    continuation.finish(throwing: HymnFailure.cancelled(request.id))
                } catch {
                    continuation.finish(
                        throwing: HymnFailure(code: "UNKNOWN", message: String(describing: error))
                    )
                }

                await scheduler.release(id: request.id)
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 一次性（非流式）翻译，内部同样走调度器。
    public func translate(_ request: InferenceRequest) async throws -> TranslationResult {
        let start = DispatchTime.now().uptimeNanoseconds
        var text = ""
        var count = 0
        var first: UInt64?
        do {
            for try await chunk in stream(request) {
                if chunk.isFinal { continue }
                if first == nil { first = DispatchTime.now().uptimeNanoseconds - start }
                text += chunk.text
                count += 1
            }
        } catch let failure as HymnFailure where failure.code == "CANCELLED" {
            return TranslationResult(
                requestID: request.id, text: text, tokenCount: count,
                firstTokenNanos: first,
                totalNanos: DispatchTime.now().uptimeNanoseconds - start,
                wasCancelled: true
            )
        }
        return TranslationResult(
            requestID: request.id, text: text, tokenCount: count,
            firstTokenNanos: first,
            totalNanos: DispatchTime.now().uptimeNanoseconds - start,
            wasCancelled: false
        )
    }

    public func cancel(id: UUID) async {
        await cancellations.cancel(id)
        await scheduler.cancel(id: id)
    }

    public func cancelAll(ids: [UUID]) async {
        await cancellations.cancelAll(ids)
        for id in ids { await scheduler.cancel(id: id) }
    }

    public func snapshot() async -> EngineSnapshot {
        EngineSnapshot(
            scheduler: await scheduler.snapshot(),
            cancellationCount: await cancellations.cancellationCount,
            backendIdentifier: backend.identifier,
            performsRealModelInference: backend.performsRealModelInference
        )
    }

    public func shutdown() async {
        await backend.shutdown()
        prepared = false
    }
}
