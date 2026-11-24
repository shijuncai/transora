import Foundation
import HymnCore

/// H2：语言目录（模型卡 36 种语言）独立测试。
public func languageCatalogSuite() -> [TestResult] {
    let s = "language-catalog"
    var out: [TestResult] = []

    out.append(check(suite: s, "模型卡 36 种语言全部登记",
                     LanguageCatalog.count == 36,
                     detail: "count=\(LanguageCatalog.count)"))
    out.append(check(suite: s, "语言代码无重复",
                     Set(LanguageCatalog.codes).count == LanguageCatalog.count))
    out.append(check(suite: s, "代码清单与模型卡一致",
                     LanguageCatalog.codes == [
                        "zh", "en", "fr", "pt", "es", "ja", "tr", "ru", "ar", "ko",
                        "th", "it", "de", "vi", "ms", "id", "tl", "hi", "pl", "cs",
                        "nl", "km", "my", "fa", "gu", "ur", "te", "mr", "he", "bn",
                        "ta", "uk", "bo", "kk", "mn", "ug"
                     ]))

    // 除 H2 评测实证需修正的 7 个语言外，其余旧映射必须逐字不变，
    // 尤其「简体中文」/「英文」直接决定已验证的 en→zh / zh→en 译文。
    let legacy: [String: String] = [
        "zh": "简体中文", "en": "英文", "ja": "日文", "ko": "韩文",
        "fr": "法文", "de": "德文", "ru": "俄文",
    ]
    let legacyOK = legacy.allSatisfy { LanguageCatalog.name(for: $0.key) == $0.value }
    out.append(check(suite: s, "未受措辞修复影响的 7 个语言名逐字不变", legacyOK))

    // H2 系统级 BLEU 评测发现：Sherry 1.25bit 常驻后端对「XX文」措辞会退化成输出中文，
    // 改「XX语」后 7/7 正确输出目标语言（D-1 / MLX 两种措辞均正常）。
    let fixed: [String: String] = [
        "es": "西班牙语", "gu": "古吉拉特语", "he": "希伯来语",
        "km": "高棉语", "mr": "马拉地语", "te": "泰卢固语", "ur": "乌尔都语",
    ]
    let fixedOK = fixed.allSatisfy { LanguageCatalog.name(for: $0.key) == $0.value }
    out.append(check(suite: s, "评测发现的 7 个语言名已改为 XX语", fixedOK,
                     detail: fixed.map { "\($0.key)=\(LanguageCatalog.name(for: $0.key))" }
                        .joined(separator: " ")))
    out.append(check(suite: s, "别名 iw 同步为希伯来语",
                     LanguageCatalog.name(for: "iw") == "希伯来语"))

    let allNamed = LanguageCatalog.all.allSatisfy {
        !$0.chineseName.isEmpty && !$0.shortLabel.isEmpty
            && $0.chineseName != $0.code && $0.shortLabel != $0.code
    }
    out.append(check(suite: s, "36 种语言全部有真实中文名与短标签（无裸代码）", allNamed))

    out.append(check(suite: s, "别名 zh-cn / zh-hans → 简体中文",
                     LanguageCatalog.name(for: "zh-CN") == "简体中文"
                        && LanguageCatalog.name(for: "zh-HANS") == "简体中文"))
    out.append(check(suite: s, "别名 zh-tw / zh-hant → 繁体中文",
                     LanguageCatalog.name(for: "zh-TW") == "繁体中文"
                        && LanguageCatalog.name(for: "zh-hant") == "繁体中文"))
    out.append(check(suite: s, "未知代码原样返回，不臆造语言名",
                     LanguageCatalog.name(for: "xx-unknown") == "xx-unknown"))
    out.append(check(suite: s, "contains 对全部 36 个代码为真",
                     LanguageCatalog.codes.allSatisfy { LanguageCatalog.contains($0) }))
    out.append(check(suite: s, "contains 对未知代码为假",
                     !LanguageCatalog.contains("xx")))

    // 新增语言必须不再把裸代码写进提示词：抽查此前会漏掉的几种。
    let newly = ["th", "bo", "ug", "kk", "mn", "my", "km", "te"]
    let newlyOK = newly.allSatisfy { LanguageCatalog.name(for: $0) != $0 }
    out.append(check(suite: s, "此前漏映射的 8 种语言已有中文名", newlyOK,
                     detail: newly.map { "\($0)=\(LanguageCatalog.name(for: $0))" }
                        .joined(separator: " ")))

    return out
}
