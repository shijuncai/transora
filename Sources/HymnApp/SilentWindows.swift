import AppKit

/// 抑制系统「嘀嗒」提示音。
///
/// AppKit 在 responder chain 没有对象响应某个按键/动作时会调用 `noResponderFor(_:)`，
/// 其默认实现播放系统提示音。这里只做空覆盖、不调用 `super`：
/// 已注册的菜单快捷键、文本输入、按钮操作全部照常走原有链路，
/// 只有「本来就不会有任何效果」的事件被静默，不影响功能，也不修改系统全局音效设置。
final class SilentMainWindow: NSWindow {
    override func noResponder(for eventSelector: Selector) {}
}

final class SilentFloatingPanel: NSPanel {
    override func noResponder(for eventSelector: Selector) {}
}
