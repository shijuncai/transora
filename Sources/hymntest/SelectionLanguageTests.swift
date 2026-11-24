import Foundation
import HymnCore

/// 划词语言对解析：复现「主窗口 en→zh，划中文却原样输出」的回归，并验证修复。
func selectionLanguageSuite() -> [TestResult] {
    let suite = "selection-language"
    let r = SelectionLanguageResolver.self
    var out: [TestResult] = []

    // MARK: 书写系统判定

    out.append(check(suite: suite, "中文短句判为 zh",
                     r.detect("你好，很高兴见到你。") == "zh",
                     detail: String(describing: r.detect("你好，很高兴见到你。"))))
    out.append(check(suite: suite, "中文长段落判为 zh",
                     r.detect("植入物通常不会随着时间而磨损。植入物随时间失效的主要原因在于无菌松动。") == "zh"))
    out.append(check(suite: suite, "日文假名混汉字优先判为 ja（不误判为 zh）",
                     r.detect("こんにちは、翻訳機能を確認します。") == "ja",
                     detail: String(describing: r.detect("こんにちは、翻訳機能を確認します。"))))
    out.append(check(suite: suite, "韩文判为 ko",
                     r.detect("안녕하세요, 만나서 반갑습니다.") == "ko"))
    out.append(check(suite: suite, "泰文判为 th", r.detect("สวัสดีครับ ยินดีที่ได้รู้จัก") == "th"))
    out.append(check(suite: suite, "阿拉伯文判为 ar", r.detect("مرحبا، سعيد بلقائك") == "ar"))
    out.append(check(suite: suite, "西里尔文字判为 ru", r.detect("Здравствуйте, приятно познакомиться") == "ru"))
    out.append(check(suite: suite, "英文句子判为 en",
                     r.detect("Hello, nice to meet you.") == "en",
                     detail: String(describing: r.detect("Hello, nice to meet you."))))
    out.append(check(suite: suite, "长英文夹单个汉字不误判为中文",
                     r.detect("This is a fairly long English sentence with one 中 character inside it.") == "en",
                     detail: String(describing: r.detect("This is a fairly long English sentence with one 中 character inside it."))))

    // MARK: 拉丁语系细分（v0.7.9：修复「非英语也显示 英→中」）
    // 归属：`Reports/ui-v079-*`、计划表第 23 节

    let latinCases: [(String, String, String)] = [
        ("fr", "Bonjour, je voudrais réserver une table pour deux personnes ce soir.", "法语句子"),
        ("de", "Guten Tag, ich möchte einen Tisch für zwei Personen reservieren.", "德语句子"),
        ("es", "Buenos días, quiero reservar una mesa para dos personas.", "西班牙语句子"),
        ("pt", "Bom dia, gostaria de reservar uma mesa para duas pessoas.", "葡萄牙语句子"),
        ("it", "Buongiorno, vorrei prenotare un tavolo per due persone.", "意大利语句子"),
        ("vi", "Xin chào, tôi muốn đặt bàn cho hai người.", "越南语句子"),
        ("id", "Selamat pagi, saya ingin memesan meja untuk dua orang.", "印尼语句子"),
        ("fr", "Bonjour", "法语单词问候"),
        ("es", "Hola amigo", "西班牙语短问候"),
        ("de", "Danke schön", "德语短谢"),
    ]
    for (expected, text, label) in latinCases {
        out.append(check(suite: suite, "\(label)判为 \(expected)",
                         r.detect(text) == expected,
                         detail: "\(String(describing: r.detect(text))) ← \(text.prefix(20))"))
    }

    // 无信息量的短词不得被臆造成随机语言（回落由 resolve 处理）。
    for noise in ["OK", "test", "Hello", "a", "123", "3.14"] {
        out.append(check(suite: suite, "噪声短词 \(noise) 不臆造语言",
                         r.detect(noise) == nil,
                         detail: String(describing: r.detect(noise))))
    }

    // 主窗口 en→zh 时划法语，语言对应为 fr→zh（此前错标成 en→zh）。
    let frPair = r.resolve(text: "Bonjour, je voudrais réserver une table pour deux personnes.",
                           preferredSource: "en", preferredTarget: "zh")
    out.append(check(suite: suite, "en→zh 划法语改为 fr→zh（不再标成英文）",
                     frPair.source == "fr" && frPair.target == "zh",
                     detail: "\(frPair.source)→\(frPair.target)"))

    let dePair = r.resolve(text: "Guten Tag, ich möchte einen Tisch reservieren.",
                           preferredSource: "zh", preferredTarget: "en")
    out.append(check(suite: suite, "zh→en 划德语改为 de→en（目标不被改写成中文）",
                     dePair.source == "de" && dePair.target == "en",
                     detail: "\(dePair.source)→\(dePair.target)"))
    out.append(check(suite: suite, "中英混排以中文为主时判为 zh",
                     r.detect("iPhone 很好用，翻译也很准确") == "zh",
                     detail: String(describing: r.detect("iPhone 很好用，翻译也很准确"))))

    // MARK: 语言对解析（核心回归）

    let zhCase = r.resolve(text: "植入物通常不会随着时间而磨损。",
                           preferredSource: "en", preferredTarget: "zh")
    out.append(check(suite: suite, "en→zh 划中文时改为 zh→en（不再原样照抄）",
                     zhCase.source == "zh" && zhCase.target == "en",
                     detail: "\(zhCase.source)→\(zhCase.target)"))

    let enCase = r.resolve(text: "Hello, nice to meet you.",
                           preferredSource: "en", preferredTarget: "zh")
    out.append(check(suite: suite, "en→zh 划英文保持 en→zh",
                     enCase.source == "en" && enCase.target == "zh",
                     detail: "\(enCase.source)→\(enCase.target)"))

    let reverseCase = r.resolve(text: "Hello, nice to meet you.",
                                preferredSource: "zh", preferredTarget: "en")
    out.append(check(suite: suite, "zh→en 划英文时改为 en→zh（不自译）",
                     reverseCase.source == "en" && reverseCase.target == "zh",
                     detail: "\(reverseCase.source)→\(reverseCase.target)"))

    let jaCase = r.resolve(text: "こんにちは、翻訳します。",
                           preferredSource: "en", preferredTarget: "zh")
    out.append(check(suite: suite, "en→zh 划日文保持目标 zh",
                     jaCase.source == "ja" && jaCase.target == "zh",
                     detail: "\(jaCase.source)→\(jaCase.target)"))

    let sameCase = r.resolve(text: "你好，世界",
                             preferredSource: "zh", preferredTarget: "zh")
    out.append(check(suite: suite, "源目标同为 zh 时自动选非同语言目标",
                     sameCase.target != sameCase.source,
                     detail: "\(sameCase.source)→\(sameCase.target)"))

    // 任意组合都不得产生「源==目标」的自译请求。
    let texts = ["你好，世界", "Hello, nice to meet you.", "こんにちは", "안녕하세요",
                 "Здравствуйте", "สวัสดีครับ", "Bonjour tout le monde"]
    let pairs = [("en", "zh"), ("zh", "en"), ("en", "fr"), ("fr", "en"),
                 ("zh", "zh"), ("en", "en"), ("ja", "ko")]
    var allDistinct = true
    var badCase = ""
    for text in texts {
        for (s, t) in pairs {
            let p = r.resolve(text: text, preferredSource: s, preferredTarget: t)
            if p.source == p.target {
                allDistinct = false
                badCase = "\(text.prefix(12)) \(s)/\(t) → \(p.source)/\(p.target)"
            }
        }
    }
    out.append(check(suite: suite, "49 组文本×语言对组合均不自译", allDistinct,
                     detail: badCase))

    // MARK: 生成上限

    out.append(check(suite: suite, "短划词至少 128 tokens",
                     r.suggestedMaxTokens(for: "Hi", base: 128) >= 128))
    out.append(check(suite: suite, "长划词按长度放宽但不超过 512",
                     r.suggestedMaxTokens(for: String(repeating: "译", count: 300), base: 128) == 332,
                     detail: "\(r.suggestedMaxTokens(for: String(repeating: "译", count: 300), base: 128))"))
    out.append(check(suite: suite, "超长划词钳到 512",
                     r.suggestedMaxTokens(for: String(repeating: "译", count: 4000), base: 128) == 512))

    return out
}
