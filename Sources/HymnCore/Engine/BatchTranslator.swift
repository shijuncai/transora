import Foundation

public struct BatchOutcome: Sendable, Equatable {
    public let requestID: UUID
    public let text: String
    public let tokenCount: Int
    public let totalNanos: UInt64
    public let succeeded: Bool
    public let errorCode: String?
}

/// 批量翻译：并发提交请求，但由引擎的单实例调度器保证同一时刻只有一个
/// 请求真正占用模型。整体取消时所有未开始/进行中的请求都会协作式退出。
public struct BatchTranslator: Sendable {
    public let engine: TranslationEngine

    public init(engine: TranslationEngine) { self.engine = engine }

    /// - Parameter maxInFlight: 同时"在调度器里排队/运行"的提交上限，
    ///   防止一次性把上万条请求全部塞进队列造成内存压力。
    public func translateAll(
        _ requests: [InferenceRequest],
        maxInFlight: Int = 16
    ) async -> [BatchOutcome] {
        guard !requests.isEmpty else { return [] }
        let window = max(1, maxInFlight)
        var outcomes: [BatchOutcome] = []
        outcomes.reserveCapacity(requests.count)

        var cursor = 0
        while cursor < requests.count {
            let end = min(cursor + window, requests.count)
            let slice = Array(requests[cursor..<end])
            let partial = await withTaskGroup(of: BatchOutcome.self) { group in
                for request in slice {
                    group.addTask {
                        let start = DispatchTime.now().uptimeNanoseconds
                        do {
                            let result = try await engine.translate(request)
                            return BatchOutcome(
                                requestID: request.id,
                                text: result.wasCancelled ? "" : result.text,
                                tokenCount: result.tokenCount,
                                totalNanos: DispatchTime.now().uptimeNanoseconds - start,
                                succeeded: !result.wasCancelled,
                                errorCode: result.wasCancelled ? "CANCELLED" : nil
                            )
                        } catch let failure as HymnFailure {
                            return BatchOutcome(
                                requestID: request.id, text: "", tokenCount: 0,
                                totalNanos: DispatchTime.now().uptimeNanoseconds - start,
                                succeeded: false, errorCode: failure.code
                            )
                        } catch {
                            return BatchOutcome(
                                requestID: request.id, text: "", tokenCount: 0,
                                totalNanos: DispatchTime.now().uptimeNanoseconds - start,
                                succeeded: false, errorCode: "UNKNOWN"
                            )
                        }
                    }
                }
                var collected: [BatchOutcome] = []
                collected.reserveCapacity(slice.count)
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            outcomes.append(contentsOf: partial)
            cursor = end
        }
        return outcomes
    }

    public func cancelAll(_ requests: [InferenceRequest]) async {
        await engine.cancelAll(ids: requests.map(\.id))
    }
}
