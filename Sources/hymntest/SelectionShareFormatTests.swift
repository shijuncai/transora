import Foundation
import HymnCore

/// 划词结果 → 备忘录 / 提醒事项文本的组装规则。
/// 这部分是纯字符串处理，AppleScript 侧无法在 CI 里验证，但格式必须可回归。
func selectionShareFormatSuite() -> [TestResult] {
    let suite = "selection-share"
    let f = SelectionShareFormat.self
    var out: [TestResult] = []

    // MARK: 纯文本正文（提醒事项）

    let plain = f.plainBody(source: "第一行\n第二行", translation: "L1\nL2", pair: "中 → 英")
    out.append(check(suite: suite, "纯文本保留换行与语言对",
                     plain == "原文（中 → 英）\n第一行\n第二行\n\n译文\nL1\nL2",
                     detail: plain))

    // MARK: 标题

    out.append(check(suite: suite, "标题取译文首行",
                     f.title(from: "你好，很高兴见到你。\n第二行", limit: 40) == "你好，很高兴见到你。"))
    out.append(check(suite: suite, "标题超长截断并加省略号",
                     f.title(from: String(repeating: "长", count: 60), limit: 10)
                        == String(repeating: "长", count: 10) + "…"))
    out.append(check(suite: suite, "标题长度恰好等于上限时不截断",
                     f.title(from: String(repeating: "字", count: 10), limit: 10)
                        == String(repeating: "字", count: 10)))
    out.append(check(suite: suite, "空译文标题为空（不产生省略号垃圾）",
                     f.title(from: "\n\n", limit: 40).isEmpty))
    out.append(check(suite: suite, "首行为空时回落到整体内容",
                     f.title(from: "\n实际内容", limit: 40) == "实际内容",
                     detail: f.title(from: "\n实际内容", limit: 40)))

    return out
}
