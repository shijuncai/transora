import Foundation

/// ⚠️ 测试替身（TEST DOUBLE）—— 明确不执行任何模型推理。
///
/// 用途：在不加载 1.25bit GGUF 模型的前提下，验证「单实例调度 / 流式输出 /
/// 批量 / 取消 / 主线程隔离」这几条链路的正确性。它产出的 token 一律带
/// `[fixture]` 前缀，绝不可被当作译文，也不产生任何模型算子。
///
/// 唯一真实后端是 HymnSTQ 的 SherryBackend；模型资源缺失时 App 会显式切换到
/// 本替身并在界面上标注「输出不是译文」，绝不静默冒充真实翻译。
public struct FixtureBackend: InferenceBackend {
    public let identifier: String = "fixture-v0 (TEST DOUBLE / NOT MODEL INFERENCE)"
    public let declaredWeightFormat: String = "none"
    public let performsRealModelInference: Bool = false

    public let tokenCount: Int
    public let tokenDelayNanos: UInt64

    public init(tokenCount: Int = 12, tokenDelayNanos: UInt64 = 2_000_000) {
        self.tokenCount = max(1, tokenCount)
        self.tokenDelayNanos = tokenDelayNanos
    }

    public func prepare() async throws {}

    public func stream(
        _ request: InferenceRequest,
        cancellation: CancellationRegistry
    ) -> AsyncThrowingStream<TokenChunk, any Error> {
        let count = min(tokenCount, max(1, request.maxTokens))
        let delay = tokenDelayNanos
        return AsyncThrowingStream<TokenChunk, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                for i in 0..<count {
                    if Task.isCancelled { break }
                    if await cancellation.isCancelled(request.id) {
                        continuation.finish(throwing: HymnFailure.cancelled(request.id))
                        return
                    }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    continuation.yield(
                        TokenChunk(requestID: request.id, index: i, text: "[fixture:\(i)]")
                    )
                }
                if await cancellation.isCancelled(request.id) {
                    continuation.finish(throwing: HymnFailure.cancelled(request.id))
                } else {
                    continuation.yield(
                        TokenChunk(requestID: request.id, index: count, text: "", isFinal: true)
                    )
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func shutdown() async {}
}
