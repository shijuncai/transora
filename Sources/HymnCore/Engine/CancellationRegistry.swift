import Foundation

/// 协作式取消登记处。
///
/// 与 Swift 原生 Task cancellation 并存：
/// - 外部按 requestID 主动取消（UI 按钮、批量任务整体取消）走这里；
/// - Task 被系统取消时由 `withTaskCancellationHandler` 汇入同一个登记处。
public actor CancellationRegistry {
    private var cancelled: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var count: Int = 0

    public init() {}

    public var cancellationCount: Int { count }

    public func isCancelled(_ id: UUID) -> Bool { cancelled.contains(id) }

    public func cancel(_ id: UUID) {
        guard !cancelled.contains(id) else { return }
        cancelled.insert(id)
        count += 1
        let list = waiters.removeValue(forKey: id) ?? []
        for c in list { c.resume() }
    }

    public func cancelAll(_ ids: [UUID]) {
        for id in ids { cancel(id) }
    }

    /// 等待某个请求被取消；已被取消则立即返回。
    public func waitUntilCancelled(_ id: UUID) async {
        if cancelled.contains(id) { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[id, default: []].append(c)
        }
    }

    public func reset(_ id: UUID) {
        cancelled.remove(id)
        let list = waiters.removeValue(forKey: id) ?? []
        for c in list { c.resume() }
    }

    public func resetAll() {
        cancelled.removeAll()
        let all = waiters.values.flatMap { $0 }
        waiters.removeAll()
        for c in all { c.resume() }
    }
}
