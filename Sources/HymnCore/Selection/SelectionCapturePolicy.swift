import Foundation

/// 划词选区捕获的判定策略（纯计算，不依赖 AppKit / Accessibility，便于独立测试）。
///
/// 背景：v0.7.2 之前多个 mouseUp 会并发发起捕获，各自模拟 ⌘C、改写并恢复剪贴板，
/// 彼此串扰；AX 路径又取「系统键盘焦点」而非「前台应用选区」，于是浮窗会显示
/// 旧窗口的词、只截到一半的选区、甚至其它文档的段落。这里固化三条判定规则：
/// 选区必须连续两次读到相同文本、结果必须仍属于最新请求、前台应用不得中途切换。
public enum SelectionCapturePolicy {
    /// 选区稳定采样所需的连续一致次数。
    public static let requiredStableSamples = 2

    /// 采样的最小间隔（纳秒），避开选区动画 / 焦点切换的中间态。
    public static let sampleIntervalNanos: UInt64 = 60_000_000

    /// 捕获开始前的稳定等待（纳秒）：松开鼠标后目标应用需要时间写入选区。
    public static let settleNanos: UInt64 = 180_000_000

    /// 单次捕获的硬超时（秒）：超时后释放串行槽位，绝不永久卡死划词。
    public static let hardTimeoutSeconds: Double = 3.0

    /// 判定为「拖拽」的最小位移（pt）。
    public static let dragThreshold: Double = 6
    /// 双击选词的最大间隔（秒）与最大位移（pt）。
    public static let doubleClickInterval: Double = 0.35
    public static let doubleClickDistance: Double = 8

    /// 一次鼠标手势的采样（纯数值，避免 HymnCore 依赖 AppKit）。
    public struct GestureSample: Sendable {
        public let startX: Double
        public let startY: Double
        public let endX: Double
        public let endY: Double
        public let dragged: Bool
        public let secondsSinceLastClick: Double
        public let distanceFromLastClick: Double

        public init(startX: Double, startY: Double, endX: Double, endY: Double,
                    dragged: Bool, secondsSinceLastClick: Double,
                    distanceFromLastClick: Double) {
            self.startX = startX
            self.startY = startY
            self.endX = endX
            self.endY = endY
            self.dragged = dragged
            self.secondsSinceLastClick = secondsSinceLastClick
            self.distanceFromLastClick = distanceFromLastClick
        }
    }

    /// 只有「真实拖拽划词」或「双击选词」才值得发起捕获。
    /// 必须同时有 `leftMouseDragged` 事件且位移达到阈值——只靠 down/up 的坐标差
    /// 会被事件异步派发造成的位置漂移误判成拖拽。普通单击、切窗口、拖滚动条一律忽略。
    public static func isSelectionGesture(_ g: GestureSample) -> Bool {
        let dragDistance = (g.endX - g.startX) * (g.endX - g.startX)
            + (g.endY - g.startY) * (g.endY - g.startY)
        let draggedFar = g.dragged && dragDistance >= dragThreshold * dragThreshold
        let doubleClick = g.secondsSinceLastClick < doubleClickInterval
            && g.distanceFromLastClick < doubleClickDistance
        return draggedFar || doubleClick
    }

    /// 连续采样必须最后 N 次完全一致，且非空，才认为选中文本已稳定。
    /// 返回归一化后的文本（去首尾空白、最多 4000 字符），否则 nil。
    public static func stableSelection(_ samples: [String]) -> String? {
        guard samples.count >= requiredStableSamples else { return nil }
        let tail = samples.suffix(requiredStableSamples)
        guard let first = tail.first, tail.allSatisfy({ $0 == first }) else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(4000))
    }

    /// 一次捕获结果是否仍应被采用。
    /// - token 必须是最新请求（旧请求晚完成时不能覆盖新结果）；
    /// - 若捕获时与完成时的前台应用不同，说明用户已切走，结果作废。
    public static func shouldAccept(
        token: Int, latestToken: Int,
        capturedPID: Int32?, currentPID: Int32?,
        selectionIsStable: Bool
    ) -> Bool {
        guard token == latestToken, selectionIsStable else { return false }
        if let capturedPID, let currentPID, capturedPID != currentPID { return false }
        return true
    }

    /// 旧版（v0.7.3）剪贴板回退规则：内容与原剪贴板完全一致时不能认定是本次选区。
    /// v0.7.5 起不再作为运行时判定（保留供回归测试对照）；它曾让「选区恰好等于
    /// 剪贴板已有内容」被主动放弃，是「划词不弹窗」的成因之一。
    public static func clipboardTextIsNew(_ text: String?, original: String?) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return text != original
    }

    /// v0.7.5「只读观察剪贴板」路径专用：本进程不写剪贴板、不模拟 ⌘C，
    /// 因此 changeCount 一旦变化，读到的文本就来自用户/目标应用自己的复制动作，
    /// 只要非空即可采用，无需（也不应）与旧内容比较。
    ///
    /// v0.7.4 曾用「哨兵剪贴板」（清空 + 模拟 ⌘C），在授权未生效时会把剪贴板
    /// 清空近一秒并破坏 ⌘V，已撤销。现在剪贴板全程只读。
    public static func clipboardTextIsUsable(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
