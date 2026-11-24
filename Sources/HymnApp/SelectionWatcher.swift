import AppKit
import HymnCore

/// 全局 + 本地鼠标监听：在其他应用（或 TransOra 自己的窗口）中松开左键即尝试读取选中文本。
/// 整个类隔离在 MainActor，事件回调只做一次跳转，状态不跨线程共享。
///
/// **严格串行捕获**：任意时刻只有一个任务在读 AX / 模拟 ⌘C / 改写剪贴板。
/// 之前的版本每次 mouseUp 都并发发起捕获，多个任务互相把对方「恢复剪贴板」的动作
/// 当成新选区，导致浮窗显示旧窗口的词或半截文本。现在多次划词只排队最新的一次，
/// 旧请求即使晚完成也会被 token / 前台应用 PID 双重校验丢弃。
///
/// v0.7.4 补三处「完全不弹窗」的成因：
/// 1. 无辅助功能授权时全局监听静默不投递 —— 授权状态变化后重装监听，
///    但**不自动弹系统授权框**（v0.7.5：反复弹框会打断用户且对已授权用户无效）；
/// 2. 只装 global monitor，用户在本 App 窗口里划词毫无反应 —— 现在同时装 local monitor；
/// 3. finish 里「2 秒内相同文本不重复弹」会把用户反复划同一个词的第二次起全部吞掉，
///    现在去掉文本去重，每个有效手势都给出一次结果。
@MainActor
final class SelectionWatcher {
    static let enabledKey = "linguanova.selectionEnabled"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { refreshAuthorization() }
        }
    }
    var onSelection: ((String, NSPoint) -> Void)?
    var onOutsideClick: (() -> Void)?
    /// 每次捕获结束都回调（无论成功失败），供设置页刷新诊断状态。
    var onCaptureFinished: (() -> Void)?
    /// 本地事件来自划词浮窗自身时返回 true（否则点浮窗按钮会被当成一次划词手势）。
    var shouldIgnoreLocalWindow: ((Int) -> Bool)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTrusted: Bool?

    private var latestToken = 0
    private var pending: (token: Int, point: NSPoint)?
    private var busy = false
    private var busyToken: Int?
    private var busyStarted = Date.distantPast

    // 手势判定：只有「拖拽划词」或「双击选词」才算划词，普通单击 / 切窗口不再捕获。
    private var gestureStart: CGPoint?
    private var gestureDragged = false
    private var lastClickAt = Date.distantPast
    private var lastClickPoint = CGPoint.zero

    // 手势级去重：部分应用（及合成事件）会在一次拖拽后紧接着补发第二组
    // down/dragged/up，选区还在动画中，于是同一次划词被读成「完整 + 半截」两条。
    // 这里只在「两次都已通过手势判定、间隔 < 0.5s、终点几乎相同」时挡掉第二次；
    // 用户手工反复划同一个词（间隔通常 > 0.5s）不受影响，双击选词的第一次
    // 普通单击本来就不会通过手势判定，因此也不会被误伤。
    private var lastAcceptedGestureTimestamp: TimeInterval = 0
    private var lastAcceptedGesturePoint = CGPoint.zero

    private let eventMask: NSEvent.EventTypeMask =
        [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

    init() {
        isEnabled = (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    private func log(_ message: String) {
        if ProcessInfo.processInfo.environment["HYMN_SELECTION_DEBUG"] == "1" {
            print("[SELECTION] \(message)")
            fflush(stdout)
        }
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            let type = event.type
            // 事件自身的屏幕坐标（CGEvent 左上原点）必须在派发前同步读取；
            // 若在 MainActor 的异步 Task 里再读 NSEvent.mouseLocation，连串事件会
            // 全部读到「当前」位置，把单击误判成拖拽。anchor 用 AppKit 左下原点供浮窗定位。
            let eventPoint = event.cgEvent?.location ?? .zero
            let anchor = NSEvent.mouseLocation
            let timestamp = event.timestamp
            Task { @MainActor in
                self?.handle(type: type, eventPoint: eventPoint, anchor: anchor,
                             timestamp: timestamp, isLocal: false, windowNumber: nil)
            }
        }
        // 本地监听：global monitor 只接收其它应用的事件。用户在 TransOra 主窗口里
        // 选中一段文字时也必须能划词翻译；浮窗自身的事件由 delegate 过滤掉。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            let type = event.type
            let eventPoint = event.cgEvent?.location ?? .zero
            let anchor = NSEvent.mouseLocation
            let windowNumber = event.windowNumber
            let timestamp = event.timestamp
            Task { @MainActor in
                guard self?.shouldIgnoreLocalWindow?(windowNumber) != true else { return }
                self?.handle(type: type, eventPoint: eventPoint, anchor: anchor,
                             timestamp: timestamp, isLocal: true, windowNumber: windowNumber)
            }
            return event
        }
        lastTrusted = SelectionCapture.accessibilityTrusted
        log("monitors installed trusted=\(lastTrusted.map(String.init) ?? "nil") "
            + "enabled=\(isEnabled)")
        // v0.7.5：不再在启动时自动弹系统授权框。AXIsProcessTrustedWithOptions
        // 每次调用都会弹出「隐私与安全性」引导，即使权限其实已经打开；
        // 用户反馈「已经打开了还一直跳」。授权引导只保留在设置页按钮与
        // 主菜单「划词翻译 开/关」这类**用户主动点击**的入口。
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        pending = nil
        busy = false
        busyToken = nil
        gestureStart = nil
        gestureDragged = false
        lastAcceptedGestureTimestamp = 0
    }

    /// 授权状态变化后重装监听：未授权期间创建的全局 monitor 不会自动开始投递事件。
    /// 由 AppDelegate 在应用激活时和定时轮询中调用。
    func refreshAuthorization() {
        let trusted = SelectionCapture.accessibilityTrusted
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        stop()
        start()
        log("authorization changed -> trusted=\(trusted), monitors reinstalled")
    }

    private func handle(type: NSEvent.EventType, eventPoint: CGPoint, anchor: NSPoint,
                        timestamp: TimeInterval, isLocal: Bool, windowNumber: Int?) {
        switch type {
        case .leftMouseDown:
            gestureStart = eventPoint
            gestureDragged = false
            onOutsideClick?()
        case .leftMouseDragged:
            gestureDragged = true
        case .leftMouseUp:
            let start = gestureStart ?? eventPoint
            let now = Date()
            let sample = SelectionCapturePolicy.GestureSample(
                startX: start.x, startY: start.y, endX: eventPoint.x, endY: eventPoint.y,
                dragged: gestureDragged,
                secondsSinceLastClick: now.timeIntervalSince(lastClickAt),
                distanceFromLastClick: hypot(eventPoint.x - lastClickPoint.x,
                                             eventPoint.y - lastClickPoint.y))
            lastClickAt = now
            lastClickPoint = eventPoint
            gestureStart = nil
            gestureDragged = false
            guard isEnabled else { return }
            guard SelectionCapturePolicy.isSelectionGesture(sample) else {
                log("mouseUp ignored (not a selection gesture) local=\(isLocal)")
                return
            }
            // 用事件自身的时间戳（而非 MainActor 执行时间）判断重复手势。
            if timestamp - lastAcceptedGestureTimestamp < 0.5,
               hypot(eventPoint.x - lastAcceptedGesturePoint.x,
                     eventPoint.y - lastAcceptedGesturePoint.y) < 14 {
                log("duplicate gesture within 0.5s at same point -> ignored")
                return
            }
            lastAcceptedGestureTimestamp = timestamp
            lastAcceptedGesturePoint = eventPoint
            log("gesture accepted local=\(isLocal) window=\(windowNumber.map(String.init) ?? "-") "
                + "dragged=\(sample.dragged)")
            scheduleCapture(at: anchor)
        default:
            break
        }
    }

    private func scheduleCapture(at point: NSPoint) {
        guard isEnabled else { return }
        latestToken += 1
        // 只保留最新一次请求：用户快速连划时不为中间状态各跑一次捕获。
        pending = (latestToken, point)
        drain()
    }

    private func drain() {
        // 异常情况下某次捕获未回调：超过硬超时直接释放串行槽位，划词不会永久卡死。
        if busy, Date().timeIntervalSince(busyStarted) > SelectionCapturePolicy.hardTimeoutSeconds {
            log("hard timeout released busy slot")
            releaseSlot()
        }
        guard !busy, let request = pending else { return }
        pending = nil
        busy = true
        busyToken = request.token
        busyStarted = Date()
        let token = request.token
        let point = request.point

        // 超时看门狗：即便用户之后没有任何 mouseUp，也能自动恢复。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:
                SelectionCapturePolicy.settleNanos
                + UInt64(SelectionCapturePolicy.hardTimeoutSeconds * 1_000_000_000))
            guard let self, self.busyToken == token else { return }
            self.releaseSlot()
            self.drain()
        }

        Task { [weak self] in
            // 松开鼠标后等待目标应用把选区写入 AX / 剪贴板。
            try? await Task.sleep(nanoseconds: SelectionCapturePolicy.settleNanos)
            guard let self, self.busyToken == token else { return }
            log("capture start token=\(token) trusted=\(SelectionCapture.accessibilityTrusted)")
            SelectionCapture.capture { [weak self] result in
                guard let self, self.busyToken == token else { return }
                self.finish(token: token, result: result, point: point)
            }
        }
    }

    private func releaseSlot() {
        busy = false
        busyToken = nil
    }

    private func finish(token: Int, result: SelectionCapture.Result?, point: NSPoint) {
        releaseSlot()
        defer { drain() }   // 排队中的最新请求接着执行，始终保持串行
        onCaptureFinished?()

        guard let result else {
            // 捕获失败只记日志，不弹系统授权框（见 start() 注释）。
            log("capture produced no selection; trusted=\(SelectionCapture.accessibilityTrusted)")
            return
        }
        // 旧请求晚完成、或用户中途切到别的应用，结果一律作废。
        guard SelectionCapturePolicy.shouldAccept(
            token: token, latestToken: latestToken,
            capturedPID: result.capturedPID, currentPID: SelectionCapture.frontmostPID,
            selectionIsStable: true)
        else {
            log("result rejected by token/PID check")
            return
        }
        // 不再做「2 秒内相同文本」去重：串行调度已保证一个手势只产生一个结果，
        // 旧去重会让用户反复划同一个词时第二次起完全不弹窗。
        log("accepted source=\(result.source) text=\(result.text.prefix(50))")
        onSelection?(result.text, point)
    }
}
