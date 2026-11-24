import Foundation

// MARK: - 划词浮窗底部按钮的动作清单
//
// 用户在「设置 → 划词面板按钮」里增删动作。约束：
//   - 最多 7 个（与浮窗底排的等宽网格一致，第 8 个会挤成一列挤不下的碎图标）；
//   - 至少 1 个（否则浮窗底部只剩一条空白，用户无法再找回入口）；
//   - 显示顺序恒为枚举声明顺序，不随增删跳动；
//   - 偏好以逗号分隔的短码存进 UserDefaults，解析时忽略未知/重复项。

public enum SelectionActionID: String, CaseIterable, Identifiable, Sendable {
    case copyTranslation = "copy"
    case saveTxt = "txt"
    case saveDocx = "docx"
    case saveNotes = "notes"
    case saveReminders = "reminders"
    case speak = "speak"
    case openMain = "main"
    case searchBing = "bing"
    case searchGoogle = "google"
    case shareWeibo = "weibo"
    case searchTaobao = "taobao"

    public var id: String { rawValue }

    /// 浮窗悬停 2 秒后显示的按钮名，同时作为 VoiceOver 的 accessibilityLabel。
    public var title: String {
        switch self {
        case .copyTranslation: return "复制译文"
        case .saveTxt:         return "存为 TXT"
        case .saveDocx:        return "存为 DOCX"
        case .saveNotes:       return "存入备忘录"
        case .saveReminders:   return "加入提醒事项"
        case .speak:           return "朗读译文"
        case .openMain:        return "在主窗口打开"
        case .searchBing:      return "译文 Bing 搜索"
        case .searchGoogle:    return "译文 Google 搜索"
        case .shareWeibo:      return "译文发送微博"
        case .searchTaobao:    return "译文淘宝搜索"
        }
    }

    /// 底排统一纯图标（SF Symbol）。
    public var symbol: String {
        switch self {
        case .copyTranslation: return "doc.on.doc"
        case .saveTxt:         return "doc.plaintext"
        case .saveDocx:        return "doc.richtext"
        case .saveNotes:       return "note.text"
        case .saveReminders:   return "checklist"
        case .speak:           return "speaker.wave.2.fill"   // 朗读中由视图换成 wave.3.fill
        case .openMain:        return "macwindow"
        case .searchBing:      return "b.circle"
        case .searchGoogle:    return "g.circle"
        case .shareWeibo:      return "paperplane"
        case .searchTaobao:    return "bag"
        }
    }

    /// 设置页的一行说明，用一句话讲清「点了会发生什么」。
    public var detail: String {
        switch self {
        case .copyTranslation: return "把译文复制到剪贴板"
        case .saveTxt:         return "保存为纯文本文件"
        case .saveDocx:        return "保存为 Word 文档"
        case .saveNotes:       return "导入到「备忘录」"
        case .saveReminders:   return "加入「提醒事项」"
        case .speak:           return "用系统语音朗读译文"
        case .openMain:        return "在译澜主窗口继续处理"
        case .searchBing:      return "在默认浏览器搜索译文"
        case .searchGoogle:    return "在默认浏览器搜索译文"
        case .shareWeibo:      return "打开微博分享页发送译文，译文同时复制到剪贴板"
        case .searchTaobao:    return "在淘宝搜索译文"
        }
    }

    /// 是否会把译文带到本机之外的网站：设置页据此单独给出隐私说明。
    public var isOnline: Bool {
        switch self {
        case .searchBing, .searchGoogle, .shareWeibo, .searchTaobao: return true
        default: return false
        }
    }

    /// 没有译文时是否禁用。存文件与「回主窗口」只依赖原文，因此保持可用。
    public var requiresTranslation: Bool {
        switch self {
        case .saveTxt, .saveDocx, .openMain: return false
        default: return true
        }
    }

    public static var localActions: [SelectionActionID] { allCases.filter { !$0.isOnline } }
    public static var onlineActions: [SelectionActionID] { allCases.filter(\.isOnline) }

    // MARK: 网页动作

    /// 网页查询串的长度上限。超长段落塞进 URL 会被站点截断或直接 414，
    /// 这里先按字符截断，保证链接可用（截断不改变按钮可用性）。
    public static let maxWebQueryLength = 1000

    /// 把划词译文整理成查询串：去首尾空白、换行与连续空白压成一个空格、限长。
    /// 纯空白返回 nil（不出一个搜空串的链接）。
    public static func webQuery(from text: String) -> String? {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxWebQueryLength))
    }

    /// 网页动作的跳转地址；本机动作或文本为空时返回 nil。
    public func webURL(for text: String) -> URL? {
        guard let query = Self.webQuery(from: text) else { return nil }
        switch self {
        case .searchBing:
            return Self.makeURL(host: "www.bing.com", path: "/search", name: "q", value: query)
        case .searchGoogle:
            return Self.makeURL(host: "www.google.com", path: "/search", name: "q", value: query)
        case .searchTaobao:
            return Self.makeURL(host: "s.taobao.com", path: "/search", name: "q", value: query)
        case .shareWeibo:
            return Self.makeURL(host: "service.weibo.com", path: "/share/share.php",
                                 name: "title", value: query)
        default:
            return nil
        }
    }

    /// 用 URLComponents 组装，交给系统做百分号编码：
    /// 手写 `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)` 会漏掉
    /// `&` `+` `=` `#`，中文译文里一出现这些字符查询串就被截断。
    private static func makeURL(host: String, path: String, name: String, value: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: name, value: value)]
        return components.url
    }
}

// MARK: - 底排按钮偏好

public struct SelectionActionPreferences: Equatable, Sendable {
    /// 浮窗底排最多 7 个等宽图标（与 `SelectionPopupSizer` 的网格一致）。
    public static let maxCount = 7
    /// 至少留 1 个，避免底部变成一条空白、用户找不到入口。
    public static let minCount = 1
    /// 出厂顺序 = v0.7.11 的固定 7 个按钮，升级后界面不跳变。
    public static let defaultOrder: [SelectionActionID] = [
        .copyTranslation, .saveTxt, .saveDocx, .saveNotes, .saveReminders, .speak, .openMain,
    ]

    public private(set) var ordered: [SelectionActionID]

    public init(ordered: [SelectionActionID]) {
        self.ordered = Self.normalized(ordered)
    }

    /// 从 UserDefaults 的字符串还原；从未设置过（nil）用出厂顺序。
    public init(rawValue: String?) {
        guard let rawValue else {
            self.ordered = Self.defaultOrder
            return
        }
        let ids = rawValue
            .split(separator: ",")
            .compactMap { SelectionActionID(rawValue: String($0)) }
        self.ordered = Self.normalized(ids)
    }

    /// 去重、按枚举声明顺序排序、夹在 [minCount, maxCount] 之间。
    /// 空输入（全部未知码 / 旧版本遗留值）回落到出厂顺序，绝不产出空按钮行。
    public static func normalized(_ ids: [SelectionActionID]) -> [SelectionActionID] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return defaultOrder }
        let ordered = SelectionActionID.allCases.filter { wanted.contains($0) }
        return Array(ordered.prefix(maxCount))
    }

    public var serialized: String { ordered.map(\.rawValue).joined(separator: ",") }
    public var count: Int { ordered.count }
    public var canAddMore: Bool { ordered.count < Self.maxCount }
    public var isDefault: Bool { ordered == Self.defaultOrder }

    public func contains(_ id: SelectionActionID) -> Bool { ordered.contains(id) }

    /// 打开 / 关闭一个动作。已满 7 个时再开无效，只剩 1 个时再关无效——都返回原值，
    /// 由调用方比对前后是否相等来给出「已达上限」之类的提示。
    public func toggled(_ id: SelectionActionID) -> SelectionActionPreferences {
        if ordered.contains(id) {
            guard ordered.count > Self.minCount else { return self }
            return SelectionActionPreferences(ordered: ordered.filter { $0 != id })
        }
        guard canAddMore else { return self }
        return SelectionActionPreferences(ordered: ordered + [id])
    }
}
