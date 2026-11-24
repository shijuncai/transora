import Foundation
import HymnCore

/// 划词浮窗底排按钮的可配置性：清单约束（≤7 / ≥1）、偏好序列化、网页跳转编码。
func selectionActionSuite() -> [TestResult] {
    let suite = "selection-actions"
    var out: [TestResult] = []

    // MARK: 出厂清单

    let factory = SelectionActionPreferences(rawValue: nil)
    out.append(check(suite: suite, "出厂 7 个按钮且顺序固定",
                     factory.ordered == [.copyTranslation, .saveTxt, .saveDocx,
                                         .saveNotes, .saveReminders, .speak, .openMain],
                     detail: factory.serialized))
    out.append(check(suite: suite, "出厂清单恰好等于上限",
                     factory.count == SelectionActionPreferences.maxCount
                        && !factory.canAddMore,
                     detail: "\(factory.count)"))
    out.append(check(suite: suite, "出厂清单不含任何在线动作",
                     factory.ordered.allSatisfy { !$0.isOnline }))

    // MARK: 序列化往返

    out.append(check(suite: suite, "序列化往返一致",
                     SelectionActionPreferences(
                        rawValue: factory.serialized).ordered == factory.ordered,
                     detail: factory.serialized))
    out.append(check(suite: suite, "空字符串回落到出厂清单",
                     SelectionActionPreferences(rawValue: "").ordered
                        == SelectionActionPreferences.defaultOrder))
    out.append(check(suite: suite, "未知码被忽略并回落到出厂清单",
                     SelectionActionPreferences(rawValue: "copy,nope,,").ordered == [.copyTranslation],
                     detail: SelectionActionPreferences(rawValue: "copy,nope,,").serialized))
    out.append(check(suite: suite, "重复码去重",
                     SelectionActionPreferences(
                        rawValue: "copy,copy,txt").ordered == [.copyTranslation, .saveTxt]))
    out.append(check(suite: suite, "乱序输入按声明顺序归一",
                     SelectionActionPreferences(
                        rawValue: "main,txt,copy").ordered
                        == [.copyTranslation, .saveTxt, .openMain],
                     detail: SelectionActionPreferences(rawValue: "main,txt,copy").serialized))

    // MARK: 增删与上限

    let full = SelectionActionPreferences.defaultOrder
    var prefs = SelectionActionPreferences(ordered: full)
    out.append(check(suite: suite, "已满 7 个时不能再加",
                     prefs.toggled(.searchBing) == prefs,
                     detail: "\(prefs.toggled(.searchBing).count)"))

    prefs = prefs.toggled(.saveDocx)
    out.append(check(suite: suite, "取消一个后剩 6 个",
                     prefs.count == 6 && !prefs.contains(.saveDocx),
                     detail: prefs.serialized))

    prefs = prefs.toggled(.searchBing)
    out.append(check(suite: suite, "空位后可以加入 Bing",
                     prefs.count == 7 && prefs.contains(.searchBing),
                     detail: prefs.serialized))
    out.append(check(suite: suite, "新加入的按钮排在声明顺序位置（末尾）",
                     prefs.ordered.last == .searchBing,
                     detail: prefs.serialized))

    out.append(check(suite: suite, "再次点击即移除（开关语义）",
                     prefs.toggled(.searchBing).contains(.searchBing) == false))

    var single = SelectionActionPreferences(ordered: [.openMain])
    out.append(check(suite: suite, "只剩 1 个时不能再关",
                     single.toggled(.openMain) == single))
    single = single.toggled(.speak)
    out.append(check(suite: suite, "只剩 1 个时仍可再开",
                     single.ordered == [.speak, .openMain], detail: single.serialized))

    out.append(check(suite: suite, "全部在线动作可同时开启（4 个）",
                     SelectionActionPreferences(ordered: SelectionActionID.onlineActions).count == 4,
                     detail: SelectionActionID.onlineActions.map(\.rawValue).joined(separator: ",")))

    // MARK: 查询串整理

    out.append(check(suite: suite, "换行与连续空白压成单个空格",
                     SelectionActionID.webQuery(from: "  hello\n\nworld  ") == "hello world",
                     detail: SelectionActionID.webQuery(from: "  hello\n\nworld  ") ?? "nil"))
    out.append(check(suite: suite, "纯空白返回 nil",
                     SelectionActionID.webQuery(from: " \n\t ") == nil))
    let long = String(repeating: "长", count: 1500)
    out.append(check(suite: suite, "超长文本按 1000 字符截断",
                     SelectionActionID.webQuery(from: long)?.count == 1000,
                     detail: "\(SelectionActionID.webQuery(from: long)?.count ?? -1)"))

    // MARK: 网页跳转

    func query(_ url: URL?) -> (host: String, name: String, value: String)? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = c.queryItems?.first else { return nil }
        return (c.host ?? "", item.name, item.value ?? "")
    }

    let tricky = "C++ & Rust=快 #1"
    let bing = query(SelectionActionID.searchBing.webURL(for: tricky))
    out.append(check(suite: suite, "Bing 主机与查询参数名正确",
                     bing?.host == "www.bing.com" && bing?.name == "q",
                     detail: bing?.host ?? "nil"))
    out.append(check(suite: suite, "Bing 查询串保留 & = # 等特殊字符（不截断）",
                     bing?.value == "C++ & Rust=快 #1",
                     detail: bing?.value ?? "nil"))
    out.append(check(suite: suite, "Google 主机正确",
                     query(SelectionActionID.searchGoogle.webURL(for: "你好"))?.host
                        == "www.google.com"))
    out.append(check(suite: suite, "淘宝主机正确",
                     query(SelectionActionID.searchTaobao.webURL(for: "机械键盘"))?.host
                        == "s.taobao.com"))
    let weibo = query(SelectionActionID.shareWeibo.webURL(for: "今天天气不错"))
    out.append(check(suite: suite, "微博走分享页且参数名为 title",
                     weibo?.host == "service.weibo.com" && weibo?.name == "title"
                        && weibo?.value == "今天天气不错",
                     detail: weibo.map { "\($0.host) \($0.name)=\($0.value)" } ?? "nil"))
    out.append(check(suite: suite, "全部为 https",
                     SelectionActionID.allCases
                        .filter(\.isOnline)
                        .allSatisfy { $0.webURL(for: "x")?.scheme == "https" }))
    out.append(check(suite: suite, "本机动作没有网页地址",
                     SelectionActionID.localActions.allSatisfy { $0.webURL(for: "x") == nil }))
    out.append(check(suite: suite, "空译文不产出网页地址",
                     SelectionActionID.onlineActions.allSatisfy { $0.webURL(for: "  ") == nil }))

    // MARK: 可用性标记

    out.append(check(suite: suite, "存文件与回主窗口不要求译文",
                     !SelectionActionID.saveTxt.requiresTranslation
                        && !SelectionActionID.saveDocx.requiresTranslation
                        && !SelectionActionID.openMain.requiresTranslation))
    out.append(check(suite: suite, "复制/朗读/网页动作要求有译文",
                     [SelectionActionID.copyTranslation, .speak, .searchBing,
                      .searchGoogle, .shareWeibo, .searchTaobao].allSatisfy(\.requiresTranslation)))
    out.append(check(suite: suite, "在线标记只覆盖 4 个网页动作",
                     SelectionActionID.onlineActions == [.searchBing, .searchGoogle,
                                                         .shareWeibo, .searchTaobao],
                     detail: SelectionActionID.onlineActions.map(\.rawValue).joined(separator: ",")))
    out.append(check(suite: suite, "每个动作都有名称/图标/说明且图标互不重复",
                     { let icons = SelectionActionID.allCases.map(\.symbol)
                       return Set(icons).count == icons.count
                          && SelectionActionID.allCases.allSatisfy {
                              !$0.title.isEmpty && !$0.detail.isEmpty } }()))

    return out
}
