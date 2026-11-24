import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import HymnCore

/// 读取**当前前台应用**中被选中的文本。
///
/// 三条路径，全部**绝不预先清空剪贴板**：
/// 1. **AX 读取**（首选，不碰剪贴板）：焦点元素 + 父链 3 层 + 直接子节点，
///    覆盖 Electron / 网页把 `kAXSelectedTextAttribute` 放在容器上的情况。
///    不再用 `AXIsProcessTrusted()` 的布尔值当门槛（它会误报），
///    而是直接调用并按 `AXError` 判断真实原因。
/// 2. **模拟 ⌘C**（AX 拿不到时）：先记录 `changeCount` 与剪贴板完整快照，
///    再发按键；若在 450 ms 内出现新内容，说明模拟生效 —— 采用并**恢复原剪贴板**，
///    `⌘V` 仍粘贴用户原本复制的内容。
/// 3. **用户手动 ⌘C**（前两条都不可用，通常是辅助功能未真正生效）：
///    模拟失败后继续只读观察 `changeCount` 1.2 s，用户自己复制即弹窗；
///    因为是用户自己的复制动作，不做恢复。
///
/// v0.7.4 的「哨兵剪贴板」会先 `clearContents()`，是「直接划词不弹、只有 ⌘C 才弹、
/// ⌘V 粘贴混乱」的根因，已彻底移除。
///
/// 调用方保证串行调用；完成回调携带捕获时的 PID，由调用方校验前台应用未切换。
/// 全部在主线程执行，避免 Swift 6 下跨并发域传递 AppKit 对象。
enum SelectionCapture {
    struct Result {
        let text: String
        let source: String
        let capturedPID: Int32?
    }

    /// 最近一次捕获的诊断结果，供设置页给出可操作指引（不主动弹任何窗口）。
    enum Diagnosis: String {
        case none = "none"
        /// AX API 返回 apiDisabled：辅助功能权限对当前 App **没有真正生效**。
        case axDisabled = "ax-disabled"
        /// AX 可用，但当前应用没有暴露选区（网页 / 部分 Electron / PDF）。
        case axEmpty = "ax-empty"
        /// 模拟 ⌘C 生效，已恢复原剪贴板。
        case simulatedCopy = "simulated-copy"
        /// 用户自己按了 ⌘C，剪贴板归用户所有，不做恢复。
        case userCopy = "user-copy"
        /// 三条路径都没有结果。
        case noSelection = "no-selection"
    }

    @MainActor private(set) static var lastDiagnosis: Diagnosis = .none

    /// 授权状态仅用于 UI 展示与监听重装，不再作为是否尝试 AX 的门槛。
    /// `HYMN_FORCE_UNTRUSTED=1` 是诊断开关（默认关闭），用于复现「系统设置里
    /// 已授权、但 AXIsProcessTrusted() 误报 false」的现场。
    static var accessibilityTrusted: Bool {
        if ProcessInfo.processInfo.environment["HYMN_FORCE_UNTRUSTED"] == "1" { return false }
        return AXIsProcessTrusted()
    }

    /// 前台应用的进程号；浮窗是 nonactivating panel，不会抢走前台身份。
    static var frontmostPID: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// 弹出系统授权引导。**仅由用户主动点击**（设置页按钮 / 主菜单划词开关）调用，
    /// 启动或捕获失败时一律不弹，避免反复打断用户。
    static func promptAccessibility() {
        debug("promptAccessibility invoked (user-initiated only)")
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 直接打开「系统设置 → 隐私与安全性 → 辅助功能」，不依赖系统弹窗。
    @MainActor
    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private static func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["HYMN_SELECTION_DEBUG"] == "1" {
            print("[SELECTION] \(message)")
            fflush(stdout)
        }
    }

    /// 捕获一次选区。**串行调度由 SelectionWatcher 保证，本函数不可并发调用。**
    @MainActor
    static func capture(completion: @escaping @MainActor (Result?) -> Void) {
        let pid = frontmostPID
        debug("capture start pid=\(pid.map(String.init) ?? "nil") trusted=\(accessibilityTrusted)")
        // 诊断开关（默认关闭）：强制跳过 AX，用于验证「模拟 ⌘C + 恢复剪贴板」路径。
        if ProcessInfo.processInfo.environment["HYMN_SKIP_AX"] == "1" {
            debug("HYMN_SKIP_AX=1 -> clipboard path")
            captureViaClipboard(pid: pid, completion: completion)
            return
        }
        // 采样 5 次（60 ms 间隔）给 Electron / 网页应用更多时间把选区写入 AX 树。
        attemptAX(samples: [], attemptsLeft: 5, pid: pid, completion: completion)
    }

    // MARK: - Accessibility 路径（不碰剪贴板）

    @MainActor
    private static func attemptAX(
        samples: [String], attemptsLeft: Int, pid: Int32?,
        completion: @escaping @MainActor (Result?) -> Void
    ) {
        var next = samples
        // 无条件尝试 AX。以前这里写成
        //   accessibilityTrusted ? (selectedTextViaAX(...) ?? "") : ""
        // 一旦 AXIsProcessTrusted() 误报 false（用户已在系统设置授权、但 TCC 记录
        // 指向旧路径副本或 App 尚未重启），整条 AX 路径被跳过，只剩剪贴板兜底，
        // 于是「直接划词完全不弹窗」。API 本身在权限不足时会返回失败，不需要预判。
        let read = selectedTextViaAX(pid: pid)
        next.append(read.text ?? "")
        if let stable = SelectionCapturePolicy.stableSelection(next) {
            debug("ax stable pid=\(pid.map(String.init) ?? "nil") text=\(stable.prefix(60))")
            lastDiagnosis = .none
            completion(Result(text: stable, source: "ax", capturedPID: pid))
            return
        }
        guard attemptsLeft > 1 else {
            if read.disabled {
                debug("ax apiDisabled -> 辅助功能对当前 App 未生效，继续尝试模拟 ⌘C")
                lastDiagnosis = .axDisabled
            } else {
                debug("ax empty -> 模拟 ⌘C")
                lastDiagnosis = .axEmpty
            }
            captureViaClipboard(pid: pid, completion: completion)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: SelectionCapturePolicy.sampleIntervalNanos)
            // 采样期间用户切走了应用：这次结果已无意义。
            guard frontmostPID == pid else {
                debug("ax aborted: frontmost app changed")
                completion(nil)
                return
            }
            attemptAX(samples: next, attemptsLeft: attemptsLeft - 1,
                       pid: pid, completion: completion)
        }
    }

    /// 焦点元素优先，其次沿父链向上 3 层、再看直接子节点，最后系统级焦点元素兜底。
    /// 网页 / Electron 常把 `kAXSelectedTextAttribute` 放在 AXWebArea 之类的容器上，
    /// 只查焦点元素会漏掉。取第一个非空结果，避免把整页文本当成选区。
    @MainActor
    private static func selectedTextViaAX(pid: Int32?) -> (text: String?, disabled: Bool) {
        var roots: [AXUIElement] = []
        if let pid {
            roots.append(AXUIElementCreateApplication(pid_t(pid)))
        }
        roots.append(AXUIElementCreateSystemWide())
        var disabled = false
        for root in roots {
            var focused: CFTypeRef?
            let focusedError = AXUIElementCopyAttributeValue(
                root, kAXFocusedUIElementAttribute as CFString, &focused)
            if focusedError == .apiDisabled {
                disabled = true
                continue
            }
            guard focusedError == .success,
                  let element = focused,
                  CFGetTypeID(element) == AXUIElementGetTypeID()
            else { continue }
            let start = unsafeDowncast(element, to: AXUIElement.self)
            if let text = selectedText(in: start) { return (text, disabled) }

            var current = start
            for _ in 0..<3 {
                var parentRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    current, kAXParentAttribute as CFString, &parentRef) == .success,
                      let parent = parentRef,
                      CFGetTypeID(parent) == AXUIElementGetTypeID()
                else { break }
                current = unsafeDowncast(parent, to: AXUIElement.self)
                if let text = selectedText(in: current) { return (text, disabled) }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                start, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AnyObject] {
                for child in children.prefix(12) where CFGetTypeID(child) == AXUIElementGetTypeID() {
                    if let text = selectedText(in: unsafeDowncast(child, to: AXUIElement.self)) {
                        return (text, disabled)
                    }
                }
            }
        }
        return (nil, disabled)
    }

    private static func selectedText(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let raw = value as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(4000))
    }

    // MARK: - 剪贴板兜底（模拟 ⌘C，但绝不清空剪贴板）

    /// 剪贴板完整快照（所有类型的数据），仅在「模拟 ⌘C 生效」后恢复。
    /// 使用 String + Data 而非 NSPasteboardItem，保证 Swift 6 下可安全跨 actor 传递。
    private struct ClipboardSnapshot: Sendable {
        let entries: [(String, Data)]

        init(_ pasteboard: NSPasteboard) {
            var items: [(String, Data)] = []
            for type in pasteboard.types ?? [] {
                if let data = pasteboard.data(forType: type) {
                    items.append((type.rawValue, data))
                }
            }
            entries = items
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            for (rawValue, data) in entries {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(rawValue))
            }
        }
    }

    /// 模拟 ⌘C 生效的判定窗口（秒）。窗口内出现新内容视为本次模拟的结果。
    private static let simulationWindow: TimeInterval = 0.45
    /// 模拟失败后继续只读观察用户手动 ⌘C 的总时长（秒）。
    private static let userCopyWindow: TimeInterval = 1.2

    @MainActor
    private static func captureViaClipboard(
        pid: Int32?, completion: @escaping @MainActor (Result?) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let saved = ClipboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        let startedAt = Date()
        // 只发按键，**不 clearContents、不写任何数据**。权限不足时事件会被系统丢弃，
        // 剪贴板保持原样，⌘V 不受影响。
        postCopyShortcut()
        poll(attempt: 0, previous: nil, saved: saved, before: before, startedAt: startedAt,
             pid: pid, completion: completion)

        @MainActor
        func poll(
            attempt: Int, previous: String?, saved: ClipboardSnapshot, before: Int,
            startedAt: Date, pid: Int32?,
            completion: @escaping @MainActor (Result?) -> Void
        ) {
            let pb = NSPasteboard.general
            let changed = pb.changeCount != before
            let candidate = changed
                ? pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let elapsed = Date().timeIntervalSince(startedAt)

            // 连续两次读到相同文本才采用（避开复制过程中的半截内容）。
            if changed, let candidate, !candidate.isEmpty,
               candidate == previous,
               SelectionCapturePolicy.clipboardTextIsUsable(candidate) {
                let value = String(candidate.prefix(4000))
                if elapsed <= simulationWindow {
                    // 模拟按键生效：剪贴板被本次选区覆盖，恢复用户原本的内容，
                    // 让 ⌘V 仍然粘贴用户自己复制的东西。
                    saved.restore(to: pb)
                    lastDiagnosis = .simulatedCopy
                    debug("simulated ⌘C ok, clipboard restored; text=\(value.prefix(50))")
                } else {
                    // 用户自己按的 ⌘C：剪贴板归用户所有，不做恢复。
                    lastDiagnosis = .userCopy
                    debug("user ⌘C observed; text=\(value.prefix(50))")
                }
                completion(Result(text: value, source: "clipboard", capturedPID: pid))
                return
            }

            if elapsed < userCopyWindow {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    guard frontmostPID == pid else {
                        debug("clipboard observation aborted: frontmost app changed")
                        completion(nil)
                        return
                    }
                    poll(attempt: attempt + 1, previous: candidate ?? (changed ? "" : nil),
                         saved: saved, before: before, startedAt: startedAt,
                         pid: pid, completion: completion)
                }
            } else {
                // 超时不猜内容：宁可不弹窗，也不把任何残留当成选区。
                // 模拟按键若未生效，剪贴板从未被本进程改动，无需恢复。
                lastDiagnosis = .noSelection
                debug("no selection: simulated ⌘C ineffective and no user copy; "
                      + "pasteboard untouched")
                completion(nil)
            }
        }
    }

    /// 模拟 ⌘C。事件之间留短间隔，避免目标应用把瞬时按键合成误判为无效输入。
    private static func postCopyShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let command: CGKeyCode = 0x37
        let c: CGKeyCode = 0x08
        let sequence: [(CGKeyCode, Bool, CGEventFlags)] = [
            (command, true, .maskCommand),
            (c, true, .maskCommand),
            (c, false, .maskCommand),
            (command, false, []),
        ]
        for (key, isDown, flags) in sequence {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: key, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }
}
