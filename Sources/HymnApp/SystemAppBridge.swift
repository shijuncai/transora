import AppKit
import EventKit
import Foundation
import HymnCore

/// 把划词内容交给系统「备忘录」「提醒事项」。
///
/// **为什么不用 AppleScript（v0.7.11 起弃用）**：Apple Events 需要「自动化」授权，
/// 而 ad-hoc 签名的 App 每次重新构建 cdhash 都会变，授权记录随之失效；实测在已授权
/// 的情况下 `make new note` 仍被系统以 -10004 拒绝，只有 `activate` 能通过。
/// 因此换成两条不需要「自动化」的官方通道：
///
/// - **备忘录**：把内容写成临时 `.txt`，交给 LaunchServices 让备忘录导入。
///   实测可行（首行成为标题，其余为正文），不需要任何权限、也没有弹窗。
/// - **提醒事项**：用 EventKit（`EKReminder`）直接写入，走的是标准「提醒事项」隐私授权
///   （`NSRemindersFullAccessUsageDescription`），与「自动化」无关。
enum SystemAppBridge {
    enum BridgeError: LocalizedError {
        /// 缺少对应隐私授权。
        case notAuthorized(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized(let app): return "需要授权访问「\(app)」"
            case .failed(let app, let message): return "\(app) 返回错误：\(message)"
            }
        }

        var isNotAuthorized: Bool {
            if case .notAuthorized = self { return true }
            return false
        }
    }

    // MARK: - 备忘录（文件导入）

    /// 新建一条备忘录：首行成为标题，其余为正文。
    /// - Parameter completion: 在后台线程回调（失败时带原因，成功传 nil），
    ///   调用方需自行切回主线程。用 `String?` 而不是 `Result` 是为了满足 Sendable。
    static func addNote(
        title: String, body: String,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        let content = title + "\n\n" + body
        let url: URL
        do {
            url = try writeTemporary(text: content)
        } catch {
            completion(error.localizedDescription)
            return
        }
        guard let notes = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Notes") else {
            completion("系统里找不到备忘录 App")
            return
        }
        // activates = false：导入时把备忘录留在后台，不抢走用户当前焦点。
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: notes, configuration: config) {
            _, error in
            completion(error?.localizedDescription)
        }
    }

    // MARK: - 提醒事项（EventKit）

    /// 新建一条提醒事项：标题 + 备注，写入默认列表。
    static func addReminder(title: String, body: String) async throws {
        // 已明确拒绝时不再发起请求，直接给出可操作提示。
        if EKEventStore.authorizationStatus(for: .reminder) == .denied {
            throw BridgeError.notAuthorized("提醒事项")
        }
        let store = EKEventStore()
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw BridgeError.notAuthorized("提醒事项")
        }
        guard granted else { throw BridgeError.notAuthorized("提醒事项") }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw BridgeError.failed("提醒事项", "没有可用的提醒列表")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = body
        reminder.calendar = calendar
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw BridgeError.failed("提醒事项", error.localizedDescription)
        }
    }

    /// 当前是否已获得提醒事项的完整访问权限（不弹窗，用于给出准确提示）。
    static var reminderAuthorizationDenied: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .denied
    }

    // MARK: - 临时文件

    /// 导入用的临时文件放在 Caches 下，并顺手清掉一天前的旧文件。
    private static func writeTemporary(text: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HymnTranslate/ShareQueue", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        purgeOldFiles(in: dir)

        // 文件名只做定位用途；备忘录用文件首行作为标题。
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("划词译文-\(stamp)-\(UUID().uuidString.prefix(6)).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private static func purgeOldFiles(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: item) }
        }
    }
}
