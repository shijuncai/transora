import AppKit

/// 菜单栏常驻图标与菜单。关闭主窗口后 App 继续留在托盘，划词翻译保持可用。
@MainActor
final class TrayController {
    private var statusItem: NSStatusItem?
    private var selectionItem: NSMenuItem?

    var onOpenMain: (() -> Void)?
    var onToggleSelection: (() -> Bool)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?
    var selectionEnabled: (() -> Bool)?

    /// 菜单栏图标：直接使用品牌 icns（透明 TO 标记），与 Dock / 界面保持一致。
    /// 菜单栏高度约 24 pt，按 18 pt 绘制；图标缺失时回退到系统符号。
    private func brandStatusImage() -> NSImage? {
        if let icon = AppIconMark.brandImage {
            let side: CGFloat = 18
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                icon.draw(in: rect, from: NSRect(origin: .zero, size: icon.size),
                          operation: .sourceOver, fraction: 1.0)
                return true
            }
            image.isTemplate = false
            return image
        }
        let fallback = NSImage(systemSymbolName: "sparkles",
                               accessibilityDescription: AppBrand.displayName)
        fallback?.isTemplate = true
        return fallback
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = brandStatusImage()
        item.button?.toolTip = AppBrand.fullName

        let menu = NSMenu()
        let open = NSMenuItem(title: "打开\(AppBrand.displayName)",
                              action: #selector(openMain(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(NSMenuItem.separator())
        let toggle = NSMenuItem(title: selectionTitle,
                                action: #selector(toggleSelection(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        selectionItem = toggle

        menu.addItem(NSMenuItem.separator())
        let about = NSMenuItem(title: "关于\(AppBrand.displayName)",
                               action: #selector(about(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出\(AppBrand.displayName)",
                              action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private var selectionTitle: String {
        (selectionEnabled?() ?? false) ? "划词翻译：开启" : "划词翻译：关闭"
    }

    func refreshSelectionTitle() {
        selectionItem?.title = selectionTitle
    }

    @objc func openMain(_ sender: Any?) { onOpenMain?() }

    @objc func toggleSelection(_ sender: Any?) {
        let enabled = onToggleSelection?() ?? false
        if enabled && !SelectionCapture.accessibilityTrusted {
            SelectionCapture.promptAccessibility()
        }
        refreshSelectionTitle()
    }

    @objc func about(_ sender: Any?) {
        // 走主窗口的自定义关于窗口（层级可控），不要再弹系统标准面板。
        onAbout?()
    }

    @objc func quit(_ sender: Any?) { onQuit?() }
}
