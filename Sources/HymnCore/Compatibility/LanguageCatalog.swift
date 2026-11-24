import Foundation

/// 模型卡实证支持的语言目录（H2：全部语言对覆盖的基础设施）。
///
/// 来源：`tencent/Hy-MT2-1.8B` 模型卡 `language:` 字段，共 **36 种**，
/// 2026-11-21 通过 `hf-mirror.com/tencent/Hy-MT2-1.8B/raw/main/README.md` 实证读取。
/// 此前 `RealModelBackend.languageName` 只映射 10 个代码，其余语言会把裸代码
/// （如 `"th"`）塞进中文提示词；本目录补齐后 UI 与 CLI 均可显式选择全部语言。
///
/// 口径：这里登记的是**模型卡声明**的支持范围，不等于「36×35 个方向都做过质量评测」。
/// 实际译文质量以 `Reports/translation-quality-*.json` 的 BLEU 数据为准。
public enum LanguageCatalog: Sendable {
    public struct Entry: Sendable, Equatable {
        public let code: String
        public let chineseName: String
        public let shortLabel: String

        public init(code: String, chineseName: String, shortLabel: String) {
            self.code = code
            self.chineseName = chineseName
            self.shortLabel = shortLabel
        }
    }

    /// H2 评测实测修正（2026-11-21）：1.25bit Sherry 常驻后端对「XX文」措辞的
    /// 指令遵循退化，会把 en→es / gu / he / km / mr / te / ur 直接译成中文；
    /// 改为「XX语」后 7/7 均正确输出目标语言，D-1 / MLX 对两种措辞都正常。
    /// 只改这 7 个有实证问题的语言，其余（含已验证的简体中文/英文/日文）保持原样。
    /// 36 种语言，顺序与模型卡一致。
    public static let all: [Entry] = [
        .init(code: "zh", chineseName: "简体中文",   shortLabel: "中"),
        .init(code: "en", chineseName: "英文",       shortLabel: "英"),
        .init(code: "fr", chineseName: "法文",       shortLabel: "法"),
        .init(code: "pt", chineseName: "葡萄牙文",   shortLabel: "葡"),
        .init(code: "es", chineseName: "西班牙语",   shortLabel: "西"),
        .init(code: "ja", chineseName: "日文",       shortLabel: "日"),
        .init(code: "tr", chineseName: "土耳其文",   shortLabel: "土"),
        .init(code: "ru", chineseName: "俄文",       shortLabel: "俄"),
        .init(code: "ar", chineseName: "阿拉伯文",   shortLabel: "阿"),
        .init(code: "ko", chineseName: "韩文",       shortLabel: "韩"),
        .init(code: "th", chineseName: "泰文",       shortLabel: "泰"),
        .init(code: "it", chineseName: "意大利文",   shortLabel: "意"),
        .init(code: "de", chineseName: "德文",       shortLabel: "德"),
        .init(code: "vi", chineseName: "越南文",     shortLabel: "越"),
        .init(code: "ms", chineseName: "马来文",     shortLabel: "马"),
        .init(code: "id", chineseName: "印尼文",     shortLabel: "印尼"),
        .init(code: "tl", chineseName: "菲律宾文",   shortLabel: "菲"),
        .init(code: "hi", chineseName: "印地文",     shortLabel: "印地"),
        .init(code: "pl", chineseName: "波兰文",     shortLabel: "波"),
        .init(code: "cs", chineseName: "捷克文",     shortLabel: "捷"),
        .init(code: "nl", chineseName: "荷兰文",     shortLabel: "荷"),
        .init(code: "km", chineseName: "高棉语",     shortLabel: "柬"),
        .init(code: "my", chineseName: "缅甸文",     shortLabel: "缅"),
        .init(code: "fa", chineseName: "波斯文",     shortLabel: "波斯"),
        .init(code: "gu", chineseName: "古吉拉特语", shortLabel: "古吉"),
        .init(code: "ur", chineseName: "乌尔都语",   shortLabel: "乌尔"),
        .init(code: "te", chineseName: "泰卢固语",   shortLabel: "泰卢"),
        .init(code: "mr", chineseName: "马拉地语",   shortLabel: "马拉"),
        .init(code: "he", chineseName: "希伯来语",   shortLabel: "希伯"),
        .init(code: "bn", chineseName: "孟加拉文",   shortLabel: "孟"),
        .init(code: "ta", chineseName: "泰米尔文",   shortLabel: "泰米"),
        .init(code: "uk", chineseName: "乌克兰文",   shortLabel: "乌克"),
        .init(code: "bo", chineseName: "藏文",       shortLabel: "藏"),
        .init(code: "kk", chineseName: "哈萨克文",   shortLabel: "哈萨"),
        .init(code: "mn", chineseName: "蒙古文",     shortLabel: "蒙"),
        .init(code: "ug", chineseName: "维吾尔文",   shortLabel: "维"),
    ]

    public static var codes: [String] { all.map(\.code) }
    public static var count: Int { all.count }

    /// 面向用户的常用 14 种语言（含简体中文）。
    ///
    /// 2026-11-21 产品收敛：主界面语言选择器只展示这 14 种，降低选择成本。
    /// **底层仍保留模型卡实证的 36 种映射**：CLI `evaluate` / 1260 全方向评测、
    /// 历史记录里旧语言代码的显示都依赖完整目录，不因 UI 收敛而删数据或伪造支持范围。
    /// 顺序按中文用户常用度排列，不按字母序。
    public static let featuredCodes: [String] = [
        "zh", "en", "ja", "ko", "fr", "de", "es",
        "pt", "ru", "it", "ar", "th", "vi", "id",
    ]

    public static var featured: [Entry] { featuredCodes.compactMap { byCode[$0] } }
    public static var featuredCount: Int { featuredCodes.count }

    /// 常见别名 → 中文名。繁体中文不在模型卡 36 种里，但项目历史上已支持，保留兼容。
    private static let aliases: [String: String] = [
        "zh-cn": "简体中文", "zh-hans": "简体中文",
        "zh-tw": "繁体中文", "zh-hant": "繁体中文",
        "fil": "菲律宾文", "iw": "希伯来语", "in": "印尼文",
    ]

    private static let byCode: [String: Entry] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0) }
    )

    /// 提示词用的语言名。未知代码原样返回（不臆造语言名）。
    public static func name(for code: String) -> String {
        let key = code.lowercased()
        if let alias = aliases[key] { return alias }
        return byCode[key]?.chineseName ?? code
    }

    public static func shortLabel(for code: String) -> String {
        byCode[code.lowercased()]?.shortLabel ?? code
    }

    public static func contains(_ code: String) -> Bool {
        byCode[code.lowercased()] != nil
    }
}
