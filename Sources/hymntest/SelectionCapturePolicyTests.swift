import Foundation
import HymnCore

/// 划词选区捕获策略：复现「浮窗显示旧窗口的词 / 半截选区 / 别的文档」并验证判定规则。
func selectionCapturePolicySuite() -> [TestResult] {
    let suite = "selection-capture-policy"
    let p = SelectionCapturePolicy.self
    var out: [TestResult] = []

    // MARK: 选区稳定双读

    out.append(check(suite: suite, "空采样不采用", p.stableSelection([]) == nil))
    out.append(check(suite: suite, "单样本不采用（必须连续两次一致）",
                     p.stableSelection(["你好"]) == nil))
    out.append(check(suite: suite, "两次一致才采用",
                     p.stableSelection(["Hello world", "Hello world"]) == "Hello world"))
    out.append(check(suite: suite, "两次不一致不采用（避免半截选区）",
                     p.stableSelection(["物通常不会", "植入物通常不会随着时间而磨损。"]) == nil))
    out.append(check(suite: suite, "三样本只看最后两次，旧采样不干扰",
                     p.stableSelection(["旧窗口的词", "植入物通常不会磨损", "植入物通常不会磨损"])
                     == "植入物通常不会磨损"))
    out.append(check(suite: suite, "三样本最后两次不一致仍不采用",
                     p.stableSelection(["A", "B", "C"]) == nil))
    out.append(check(suite: suite, "纯空白选区不采用",
                     p.stableSelection(["   \n  ", "   \n  "]) == nil))
    out.append(check(suite: suite, "首尾空白被归一化",
                     p.stableSelection(["  你好 \n", "  你好 \n"]) == "你好"))
    let long = String(repeating: "译", count: 4200)
    out.append(check(suite: suite, "超长选区钳到 4000 字符",
                     p.stableSelection([long, long])?.count == 4000))

    // MARK: 结果有效性（token / 前台应用 / 稳定性）

    out.append(check(suite: suite, "旧 token 晚完成不能覆盖新结果",
                     !p.shouldAccept(token: 7, latestToken: 8, capturedPID: 100,
                                     currentPID: 100, selectionIsStable: true)))
    out.append(check(suite: suite, "前台应用中途切换则结果作废",
                     !p.shouldAccept(token: 7, latestToken: 7, capturedPID: 100,
                                     currentPID: 200, selectionIsStable: true)))
    out.append(check(suite: suite, "选区不稳定则结果作废",
                     !p.shouldAccept(token: 7, latestToken: 7, capturedPID: 100,
                                     currentPID: 100, selectionIsStable: false)))
    out.append(check(suite: suite, "最新 token + 同应用 + 稳定则采用",
                     p.shouldAccept(token: 7, latestToken: 7, capturedPID: 100,
                                    currentPID: 100, selectionIsStable: true)))
    out.append(check(suite: suite, "PID 未知时不做额外否决",
                     p.shouldAccept(token: 7, latestToken: 7, capturedPID: nil,
                                    currentPID: nil, selectionIsStable: true)))

    // MARK: 剪贴板假阳性

    out.append(check(suite: suite, "剪贴板内容未变化视为 ⌘C 未生效",
                     !p.clipboardTextIsNew("旧剪贴板", original: "旧剪贴板")))
    out.append(check(suite: suite, "剪贴板出现新文本视为有效",
                     p.clipboardTextIsNew("本次选区", original: "旧剪贴板")))
    out.append(check(suite: suite, "剪贴板空白文本视为无效",
                     !p.clipboardTextIsNew("  \n ", original: "旧剪贴板")))
    out.append(check(suite: suite, "剪贴板无文本视为无效",
                     !p.clipboardTextIsNew(nil, original: "旧剪贴板")))

    // MARK: v0.7.5 只读观察剪贴板（撤销 v0.7.4 哨兵，修复不弹窗 + ⌘V 混乱）

    out.append(check(suite: suite, "只读观察：nil 文本不采用",
                     !p.clipboardTextIsUsable(nil)))
    out.append(check(suite: suite, "只读观察：纯空白不采用",
                     !p.clipboardTextIsUsable("  \n ")))
    out.append(check(suite: suite, "只读观察：用户 ⌘C 的内容等于原剪贴板仍采用（旧规则会放弃）",
                     p.clipboardTextIsUsable("The quick brown fox")
                     && !p.clipboardTextIsNew("The quick brown fox",
                                              original: "The quick brown fox")))
    out.append(check(suite: suite, "只读观察：反复划同一个词每次都采用",
                     p.clipboardTextIsUsable("植入物通常不会随着时间而磨损。")
                     && p.clipboardTextIsUsable("植入物通常不会随着时间而磨损。")))

    // MARK: 手势判定（只有真实划词才发起捕获）

    func g(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double,
           dragged: Bool = false, since: Double = 10,
           lastDist: Double = 100) -> SelectionCapturePolicy.GestureSample {
        SelectionCapturePolicy.GestureSample(
            startX: sx, startY: sy, endX: ex, endY: ey, dragged: dragged,
            secondsSinceLastClick: since, distanceFromLastClick: lastDist)
    }

    out.append(check(suite: suite, "普通单击不触发捕获",
                     !p.isSelectionGesture(g(100, 100, 100, 100))))
    out.append(check(suite: suite, "真实拖拽 20pt 触发捕获",
                     p.isSelectionGesture(g(100, 100, 120, 100, dragged: true))))
    out.append(check(suite: suite, "有 dragged 但位移仅 1pt 不触发（抖动）",
                     !p.isSelectionGesture(g(100, 100, 101, 100, dragged: true))))
    out.append(check(suite: suite, "仅坐标差大但无 dragged 事件不触发（异步漂移防护）",
                     !p.isSelectionGesture(g(100, 100, 140, 100))))
    out.append(check(suite: suite, "微小位移 5pt 不算拖拽",
                     !p.isSelectionGesture(g(100, 100, 105, 100, dragged: true))))
    out.append(check(suite: suite, "双击选词触发捕获",
                     p.isSelectionGesture(g(100, 100, 100, 100, since: 0.2, lastDist: 2))))
    out.append(check(suite: suite, "两次点击间隔过长不算双击",
                     !p.isSelectionGesture(g(100, 100, 100, 100, since: 1.0, lastDist: 2))))
    out.append(check(suite: suite, "两次点击位置相距过远不算双击",
                     !p.isSelectionGesture(g(100, 100, 100, 100, since: 0.2, lastDist: 20))))
    out.append(check(suite: suite, "斜向拖拽按欧氏距离判定",
                     p.isSelectionGesture(g(0, 0, 5, 5, dragged: true))
                     && !p.isSelectionGesture(g(0, 0, 3, 3, dragged: true))))

    // MARK: 时序常量

    out.append(check(suite: suite, "稳定等待长于采样间隔，硬超时更长",
                     p.settleNanos > p.sampleIntervalNanos
                     && p.hardTimeoutSeconds * 1_000_000_000 > Double(p.settleNanos)))

    return out
}
