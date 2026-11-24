import AppKit
import SwiftUI
import Dispatch
import HymnCore
import HymnStore
import HymnSTQ

@main
struct TransOraApp {
    @MainActor
    private static var strongDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate          // NSApplication.delegate 为弱引用，需额外持有
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        buildMenu(app, delegate: delegate)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    @MainActor
    private static func buildMenu(_ app: NSApplication, delegate: AppDelegate) {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: AppBrand.displayName)
        let about = NSMenuItem(title: "关于\(AppBrand.displayName)",
                               action: #selector(AppDelegate.showAbout(_:)),
                               keyEquivalent: "")
        about.target = delegate
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(AppDelegate.openSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = delegate
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出\(AppBrand.displayName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单（系统标准 action，保证输入框内复制/粘贴可用）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // 翻译菜单
        let translateItem = NSMenuItem()
        mainMenu.addItem(translateItem)
        let menu = NSMenu(title: "翻译")
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = delegate
            menu.addItem(entry)
        }
        item("翻译", #selector(AppDelegate.menuTranslate(_:)), "\r")
        item("取消当前翻译", #selector(AppDelegate.menuCancel(_:)), ".")
        menu.addItem(NSMenuItem.separator())
        item("交换语言", #selector(AppDelegate.menuSwapLanguages(_:)), "s", [.command, .shift])
        item("复制译文", #selector(AppDelegate.menuCopyOutput(_:)), "c", [.command, .shift])
        item("清空输入与译文", #selector(AppDelegate.menuClear(_:)), "k")
        menu.addItem(NSMenuItem.separator())
        item("划词翻译 开/关", #selector(AppDelegate.menuToggleSelection(_:)), "t", [.command, .shift])
        item("重新检测模型", #selector(AppDelegate.menuRetryModel(_:)), "r", [.command, .shift])
        translateItem.submenu = menu

        // 视图菜单
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        for (index, section) in AppSection.allCases.enumerated() {
            let entry = NSMenuItem(title: section.title, action: #selector(AppDelegate.menuSection(_:)),
                                   keyEquivalent: "\(index + 1)")
            entry.tag = index
            entry.target = delegate
            viewMenu.addItem(entry)
        }
        viewItem.submenu = viewMenu

        app.mainMenu = mainMenu
    }
}

/// 主线程 10 ms 心跳探针：验证推理期间主线程仍可自由刷新 UI。
private final class TickCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [UInt64] = []

    func record() {
        lock.lock(); stamps.append(DispatchTime.now().uptimeNanoseconds); lock.unlock()
    }

    func summary() -> (count: Int, maxMs: Double, avgMs: Double) {
        lock.lock(); defer { lock.unlock() }
        guard stamps.count >= 2 else { return (stamps.count, 0, 0) }
        var gaps: [UInt64] = []
        for i in 1..<stamps.count { gaps.append(stamps[i] - stamps[i - 1]) }
        let maxNs = gaps.max() ?? 0
        let sum = gaps.reduce(UInt64(0), +)
        return (stamps.count,
                Double(maxNs) / 1_000_000.0,
                Double(sum / UInt64(gaps.count)) / 1_000_000.0)
    }
}

@MainActor
private final class MainThreadTicker {
    private let collector = TickCollector()
    private var timer: Timer?

    func start() {
        collector.record()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [collector] _ in
            collector.record()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() -> (count: Int, maxMs: Double, avgMs: Double) {
        timer?.invalidate()
        timer = nil
        return collector.summary()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let model = AppModel()
    private let watcher = SelectionWatcher()
    private let tray = TrayController()
    private var selectionPanel: SelectionPanelController?
    private var aboutWindow: NSWindow?
    private var authorizationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let headless = env["HYMN_HEADLESS_SMOKE"] == "1"
        let window = SilentMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "\(AppBrand.fullName) — \(AppBrand.tagline)"
        window.minSize = NSSize(width: 980, height: 660)
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: RootView().environmentObject(model))
        if !headless { window.makeKeyAndOrderFront(nil) }
        self.window = window

        if !headless {
            installTrayAndSelection()
        }

        Task {
            await model.bootstrap()
            if headless {
                if env["HYMN_SMOKE_TRANSLATE"] == "1" {
                    let ticker = MainThreadTicker()
                    ticker.start()
                    await model.translate()
                    let tick = ticker.stop()
                    print("HYMN_SMOKE_TRANSLATION output=\(model.outputText) status=\(model.status)")
                    print(String(format: "HYMN_SMOKE_TICKS count=%d maxMs=%.2f avgMs=%.2f",
                                 tick.count, tick.maxMs, tick.avgMs))
                    fflush(stdout)
                }
                if env["HYMN_SELECTION_SELFTEST"] == "1" {
                    // 可用 HYMN_SELECTION_SELFTEST_TEXT 指定选区文本，用于验证
                    // 「主窗口 en→zh 时划中文自动改为 zh→en」的回归。
                    let probe = env["HYMN_SELECTION_SELFTEST_TEXT"]
                        ?? "Hello, nice to meet you."
                    model.translateSelection(probe)
                    var waited = 0
                    while model.isSelectionTranslating && waited < 480 {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        waited += 1
                    }
                    print("HYMN_SELECTION_SELFTEST source=\(model.selectionSource) "
                          + "output=\(model.selectionTranslation) "
                          + "pair=\(model.selectionSourceLang)->\(model.selectionTargetLang) "
                          + "error=\(model.selectionError ?? "none")")
                    fflush(stdout)
                }
                if let rebuildPath = env["HYMN_PDF_REBUILD_PATH"], !rebuildPath.isEmpty {
                    let limit = Int(env["HYMN_PDF_REBUILD_BLOCKS"] ?? "6") ?? 6
                    let summary = await model.smokeRebuildPDF(
                        url: URL(fileURLWithPath: rebuildPath), maxBlocks: limit)
                    print("HYMN_PDF_REBUILD \(summary)")
                }
                if let pdfPath = env["HYMN_PDF_SMOKE_PATH"], !pdfPath.isEmpty {
                    let limit = Int(env["HYMN_PDF_SMOKE_LIMIT"] ?? "2") ?? 2
                    let summary = await model.smokeTranslatePDF(
                        url: URL(fileURLWithPath: pdfPath), limit: limit)
                    print("HYMN_PDF_SMOKE \(summary)")
                    fflush(stdout)
                }
                print("HYMN_SMOKE_OK ready=\(model.runtimeStatus.ready) "
                      + "real=\(model.isRealInference) "
                      + "status=\(model.status) "
                      + "history=\(model.history.count) "
                      + "error=\(model.errorMessage ?? "none")")
                fflush(stdout)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func installTrayAndSelection() {
        selectionPanel = SelectionPanelController(model: model) { [weak self] in
            self?.model.stopSelectionSpeech()
            self?.model.openSelectionInMain()
            self?.showMainWindow()
        }
        watcher.onSelection = { [weak self] text, point in
            guard let self else { return }
            // 先同步划词内容再显示浮窗，使首次布局就基于本次选区而非上一次的译文。
            self.model.translateSelection(text)
            self.selectionPanel?.show(at: point)
        }
        watcher.onOutsideClick = { [weak self] in
            self?.model.stopSelectionSpeech()
            self?.selectionPanel?.hide()
        }
        // 捕获结束即刷新诊断，设置页可显示「辅助功能未生效 / 应用不暴露选区」。
        watcher.onCaptureFinished = { [weak self] in
            self?.model.refreshAccessibilityStatus()
        }
        // 浮窗自身的鼠标事件不进入划词手势判定，否则点浮窗按钮会被误当划词。
        watcher.shouldIgnoreLocalWindow = { [weak self] number in
            self?.selectionPanel?.windowNumber == number
        }
        // 不再设置任何自动授权回调：系统「隐私与安全性」引导只在用户主动点击
        // 设置页按钮或主菜单划词开关时出现，启动与捕获失败一律静默。
        watcher.start()

        // 用户在系统设置里事后授权时，检测状态变化并重装全局监听；这里只刷新状态，
        // 不会触发任何弹窗。
        authorizationTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.watcher.refreshAuthorization()
                self.model.refreshAccessibilityStatus()
            }
        }

        tray.selectionEnabled = { [weak self] in self?.watcher.isEnabled ?? false }
        tray.onOpenMain = { [weak self] in self?.showMainWindow() }
        tray.onAbout = { [weak self] in self?.showAbout(nil) }
        tray.onToggleSelection = { [weak self] in
            guard let self else { return false }
            self.watcher.isEnabled.toggle()
            return self.watcher.isEnabled
        }
        tray.onQuit = { NSApp.terminate(nil) }
        tray.install()
    }

    private func showMainWindow() {
        applyLaunchSectionHook()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自定义关于窗口。系统标准的 `orderFrontStandardAboutPanel` 在 App 处于托盘态、
    /// 主窗口已隐藏或前台是其它应用时会落到其它窗口下面；这里自建窗口、显式
    /// 提升 level 并 `orderFrontRegardless`，保证一定显示在桌面最上层。
    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 252),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = "关于\(AppBrand.displayName)"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: AboutView())
            aboutWindow = w
        }
        aboutWindow?.center()
        aboutWindow?.orderFrontRegardless()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    /// 截图/巡检用的启动钩子：`HYMN_UI_SECTION=pdf` 直接打开指定分区。
    /// 只影响首屏选中项，不改变任何业务状态。
    func applyLaunchSectionHook() {
        guard let raw = ProcessInfo.processInfo.environment["HYMN_UI_SECTION"],
              let section = AppSection(rawValue: raw) else { return }
        model.selectedSection = section
        if let mode = ProcessInfo.processInfo.environment["HYMN_UI_PDF_MODE"],
           let workMode = PDFWorkMode(rawValue: mode) {
            model.pdfWorkMode = workMode
        }
    }

    /// 关闭主窗口 = 缩到托盘，不退出 App，划词翻译继续在后台可用。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 用户可能在「系统设置 → 隐私与安全性 → 辅助功能」里刚授权，切回 App 时立即刷新状态。
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAccessibilityStatus()
        watcher.refreshAuthorization()
        tray.refreshSelectionTitle()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: - 菜单动作

    @objc func menuTranslate(_ sender: Any?) {
        model.selectedSection = .translate
        Task { await model.translate() }
    }

    @objc func menuCancel(_ sender: Any?) {
        Task { await model.cancelCurrent() }
    }

    @objc func menuSwapLanguages(_ sender: Any?) { model.swapLanguages() }
    @objc func menuCopyOutput(_ sender: Any?) { model.copyOutput() }
    @objc func menuClear(_ sender: Any?) { model.clearTexts() }
    @objc func openSettings(_ sender: Any?) { model.selectedSection = .settings }

    @objc func menuRetryModel(_ sender: Any?) {
        model.selectedSection = .settings
        Task { await model.retryPreparation() }
    }

    @objc func menuToggleSelection(_ sender: Any?) {
        watcher.isEnabled.toggle()
        if watcher.isEnabled && !SelectionCapture.accessibilityTrusted {
            SelectionCapture.promptAccessibility()
        }
        tray.refreshSelectionTitle()
    }

    @objc func menuSection(_ sender: NSMenuItem) {
        let all = AppSection.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        model.selectedSection = all[sender.tag]
    }
}
