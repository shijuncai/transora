import AppKit
import SwiftUI
import Combine
import HymnCore

/// 浮窗尺寸状态的单一数据源：SwiftUI 视图与 NSPanel 都读它，避免两边尺寸不一致。
@MainActor
final class SelectionPopupState: ObservableObject {
    @Published var layout: SelectionPopupLayout

    init(layout: SelectionPopupLayout) {
        self.layout = layout
    }
}

/// 划词译文浮窗：非激活面板，不抢走用户正在使用的应用焦点。
///
/// 尺寸随划词原文与流式译文自适应（`SelectionPopupSizer`），按行数量化并节流，
/// 避免逐 token 抖动；用户手动拖拽调整后，本轮不再被自动尺寸覆盖。
@MainActor
final class SelectionPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let model: AppModel
    private let onOpenMain: () -> Void
    private let state: SelectionPopupState
    private var cancellable: AnyCancellable?

    private var anchor = NSPoint.zero
    private var userResized = false
    private var lastAppliedSize: NSSize?

    init(model: AppModel, onOpenMain: @escaping () -> Void) {
        self.model = model
        self.onOpenMain = onOpenMain
        self.state = SelectionPopupState(
            layout: SelectionPopupSizer.make(
                content: SelectionPopupContent(source: "", loading: true)))
        super.init()
        bindModel()
    }

    func show(at point: NSPoint) {
        anchor = point
        userResized = false
        lastAppliedSize = nil
        ensurePanel()
        apply(content: currentContent(), force: true)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// 浮窗自身的窗口号，供 SelectionWatcher 过滤本地事件：
    /// 否则点击浮窗上的「复制译文 / 存为txt」会被当成一次划词手势。
    var windowNumber: Int? { panel?.windowNumber }

    // MARK: - 尺寸自适应

    private func bindModel() {
        cancellable = Publishers.CombineLatest4(
            model.$selectionSource,
            model.$selectionTranslation,
            model.$selectionError,
            model.$isSelectionTranslating
        ).sink { [weak self] _, _, _, _ in
            guard let self else { return }
            self.apply(content: self.currentContent(), force: false)
        }
    }

    private func currentContent() -> SelectionPopupContent {
        let loading = model.isSelectionTranslating
            && model.selectionTranslation.isEmpty
            && model.selectionError == nil
        return SelectionPopupContent(
            source: model.selectionSource,
            translation: model.selectionTranslation,
            error: model.selectionError,
            loading: loading)
    }

    private func apply(content: SelectionPopupContent, force: Bool) {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = SelectionPopupSizer.make(
            content: content,
            screenHeight: Double(screen.height),
            screenWidth: Double(screen.width))
        state.layout = layout

        guard let panel, !userResized, force || panel.isVisible else { return }
        let size = NSSize(width: layout.width, height: layout.height)
        if !force, let last = lastAppliedSize {
            let widthChanged = abs(last.width - size.width) >= 1
            let heightChanged = abs(last.height - size.height) >= 12
            if !widthChanged && !heightChanged { return }
        }
        let frame = NSRect(origin: clampedOrigin(for: size, in: screen), size: size)
        lastAppliedSize = size
        // 不使用窗口动画：流式译文逐 token 更新时动画会持续抖动，且异步帧会
        // 干扰「用户是否手动调整过尺寸」的判定。按行数量化 + 节流已足够平滑。
        panel.setFrame(frame, display: true)
    }

    private func clampedOrigin(for size: NSSize, in visible: NSRect) -> NSPoint {
        var origin = NSPoint(x: anchor.x + 14, y: anchor.y - size.height - 18)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }

    /// 用户手动拖拽过窗口后，停止自动改尺寸（仍会跟随显示/隐藏）。
    func windowDidResize(_ notification: Notification) {
        guard let panel, let last = lastAppliedSize else { return }
        let size = panel.frame.size
        if abs(size.width - last.width) < 1 && abs(size.height - last.height) < 1 { return }
        userResized = true
    }

    // MARK: - 面板构造

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = SilentFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 182),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.title = AppBrand.displayName
        p.level = .floating
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.minSize = NSSize(width: 280, height: 160)
        p.delegate = self
        p.contentView = NSHostingView(rootView:
            SelectionPopupView(
                state: state,
                onClose: { [weak self] in self?.hide() },
                onOpenMain: { [weak self] in
                    self?.hide()
                    self?.onOpenMain()
                })
                .environmentObject(model))
        panel = p
    }
}
