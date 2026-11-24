import Foundation
import HymnCore

/// 划词浮窗自适应尺寸的纯逻辑测试：不依赖 AppKit / 窗口，可在 headless 环境验证。
func selectionPopupLayoutSuite() -> [TestResult] {
    let suite = "selection-popup-layout"
    var out: [TestResult] = []

    let short = SelectionPopupContent(source: "Hello", translation: "你好")
    let medium = SelectionPopupContent(
        source: "We are meeting at the conference room tomorrow morning to review the translation quality report.",
        translation: "我们明天上午在会议室开会，审阅翻译质量报告。")
    let long = SelectionPopupContent(
        source: String(repeating: "This is a fairly long selected paragraph. ", count: 20),
        translation: String(repeating: "这是一段相当长的译文内容。", count: 20))
    let loading = SelectionPopupContent(source: "Hello, nice to meet you.", loading: true)
    let huge = SelectionPopupContent(
        source: String(repeating: "这是一段用于验证上限的长文本。", count: 260),
        translation: String(repeating: "This is a very long translation output. ", count: 260))

    let a = SelectionPopupSizer.make(content: short)
    let b = SelectionPopupSizer.make(content: medium)
    let c = SelectionPopupSizer.make(content: long)
    let l = SelectionPopupSizer.make(content: loading)
    let h = SelectionPopupSizer.make(content: huge, screenHeight: 900)

    out.append(check(suite: suite, "短划词使用 compact 档窄窗",
                     a.tier == "compact" && a.width == 320,
                     detail: "tier=\(a.tier) width=\(a.width) height=\(a.height)"))

    out.append(check(suite: suite, "宽度随划词量单调递增且不超上限",
                     a.width < b.width && b.width < c.width && c.width <= SelectionPopupSizer.maxWidth,
                     detail: "\(a.width) < \(b.width) < \(c.width) <= \(SelectionPopupSizer.maxWidth)"))

    out.append(check(suite: suite, "高度随划词量增长且不小于最小高度",
                     a.height < b.height && b.height < c.height
                        && a.height >= SelectionPopupSizer.minHeight,
                     detail: "\(a.height) < \(b.height) < \(c.height) (min=\(SelectionPopupSizer.minHeight))"))

    out.append(check(suite: suite, "加载态 / 空译文给出可用最小窗口",
                     l.height >= SelectionPopupSizer.minHeight
                        && l.translationHeight >= 2 * SelectionPopupSizer.translationLineHeight,
                     detail: "height=\(l.height) translationHeight=\(l.translationHeight)"))

    out.append(check(suite: suite, "视图/面板尺寸恒等式对所有档位成立",
                     [a, b, c, l, h].allSatisfy {
                         abs($0.height - (SelectionPopupSizer.baseHeight
                                          + $0.sourceHeight + $0.translationHeight)) < 1e-9
                     },
                     detail: "height = base + sourceHeight + translationHeight"))

    out.append(check(suite: suite, "超长划词钳到屏幕安全上限并改为窗内滚动",
                     h.scrolls && h.height <= min(SelectionPopupSizer.maxHeightCap,
                                                  900 * SelectionPopupSizer.screenHeightRatio)
                        && h.width <= SelectionPopupSizer.maxWidth,
                     detail: "scrolls=\(h.scrolls) height=\(h.height) tier=\(h.tier)"))

    out.append(check(suite: suite, "原文行数限制随档位放宽",
                     a.sourceLineLimit < c.sourceLineLimit
                        && a.estimatedSourceLines <= a.sourceLineLimit
                        && c.estimatedSourceLines >= a.estimatedSourceLines,
                     detail: "short=\(a.sourceLineLimit)/\(a.estimatedSourceLines) "
                          + "long=\(c.sourceLineLimit)/\(c.estimatedSourceLines)"))

    out.append(check(suite: suite, "复杂脚本按更宽单位估算折行",
                     SelectionPopupSizer.scalarUnit("你") == 2
                        && SelectionPopupSizer.scalarUnit("a") == 1
                        && SelectionPopupSizer.estimateLines(
                            String(repeating: "你", count: 40), availableWidth: 292, unitWidth: 6.2)
                           > SelectionPopupSizer.estimateLines(
                            String(repeating: "a", count: 40), availableWidth: 292, unitWidth: 6.2),
                     detail: "CJK 全角权重 2，拉丁 1"))

    out.append(check(suite: suite, "显式换行按段落累加行数",
                     SelectionPopupSizer.estimateLines("第一行\n第二行\n第三行",
                                                       availableWidth: 292, unitWidth: 6.2) >= 3,
                     detail: "3 段至少 3 行"))

    let narrow = SelectionPopupSizer.make(content: long, screenHeight: 900, screenWidth: 340)
    out.append(check(suite: suite, "窄屏宽度被钳在安全范围内",
                     narrow.width >= SelectionPopupSizer.minWidth && narrow.width < 340,
                     detail: "screenWidth=340 -> width=\(narrow.width)"))

    let err = SelectionPopupSizer.make(
        content: SelectionPopupContent(source: "Hello", error: "模型未就绪，请在设置中选择模型目录"))
    out.append(check(suite: suite, "错误文案参与尺寸计算",
                     err.translationHeight > 0 && err.height >= SelectionPopupSizer.minHeight,
                     detail: "height=\(err.height) translationHeight=\(err.translationHeight)"))

    let again = SelectionPopupSizer.make(content: long)
    out.append(check(suite: suite, "同一输入结果确定性一致",
                     again == c,
                     detail: "纯函数、无随机与状态"))

    return out
}
