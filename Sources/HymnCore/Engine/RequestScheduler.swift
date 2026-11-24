import Foundation

public struct SchedulerSnapshot: Sendable, Equatable {
    public let running: UUID?
    public let queued: Int
    public let completed: Int
    public let cancelledQueued: Int
    public let maxConcurrency: Int
}

/// 单模型实例调度器。
///
/// 设计约束：模型权重只有一份，GPU/Metal 命令队列由该实例独占，
/// 因此 `maxConcurrency = 1`。多个请求按 (priority DESC, seq ASC) 排队，
/// 同一时刻只有一个请求能进入推理后端。
///
/// 取消语义：
/// - 排队中被取消 → 立即从队列移除，`acquire` 返回 false，不占用模型；
/// - 运行中取消 → 由 CancellationRegistry 通知推理循环协作式退出。
public actor RequestScheduler {
    public let maxConcurrency: Int = 1

    private struct Pending {
        let id: UUID
        let priority: Int
        let seq: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var queue: [Pending] = []
    private var runningID: UUID?
    private var cancelledIDs: Set<UUID> = []
    private var sequence: UInt64 = 0
    private var completedCount: Int = 0
    private var cancelledQueuedCount: Int = 0

    public init() {}

    public func snapshot() -> SchedulerSnapshot {
        SchedulerSnapshot(
            running: runningID,
            queued: queue.count,
            completed: completedCount,
            cancelledQueued: cancelledQueuedCount,
            maxConcurrency: maxConcurrency
        )
    }

    /// 申请模型使用权；返回 false 表示请求在排队期间被取消（或已预先取消）。
    public func acquire(id: UUID, priority: Int = 0) async -> Bool {
        if cancelledIDs.contains(id) { return false }

        if runningID == nil && queue.isEmpty {
            runningID = id
            return true
        }

        sequence += 1
        let seq = sequence
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                queue.append(Pending(id: id, priority: priority, seq: seq, continuation: c))
                queue.sort { $0.priority == $1.priority ? $0.seq < $1.seq : $0.priority > $1.priority }
            }
        } onCancel: {
            Task { await self.cancelQueued(id) }
        }
    }

    public func release(id: UUID) {
        guard runningID == id else { return }
        runningID = nil
        completedCount += 1

        // 弹出下一个未取消的请求；被取消的排队项直接丢弃并计数。
        while let nextIndex = queue.firstIndex(where: { !cancelledIDs.contains($0.id) }) {
            let next = queue.remove(at: nextIndex)
            runningID = next.id
            next.continuation.resume(returning: true)
            return
        }
        let dropped = queue.count
        if dropped > 0 {
            cancelledQueuedCount += dropped
            for p in queue { p.continuation.resume(returning: false) }
            queue.removeAll()
        }
    }

    public func cancel(id: UUID) {
        cancelledIDs.insert(id)
        cancelQueued(id)
    }

    private func cancelQueued(_ id: UUID) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let p = queue.remove(at: idx)
        cancelledQueuedCount += 1
        p.continuation.resume(returning: false)
    }

    public func clearCancelled(_ id: UUID) {
        cancelledIDs.remove(id)
    }
}
