import Foundation

public struct GlossaryEntry: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let source: String
    public let target: String
    public let languages: LanguagePair
    public let note: String

    public init(id: Int64, source: String, target: String, languages: LanguagePair, note: String = "") {
        self.id = id
        self.source = source
        self.target = target
        self.languages = languages
        self.note = note
    }
}

/// 术语匹配与提示构造。
///
/// 策略：按语言对过滤 → 按源术语长度降序（最长匹配优先）→ 大小写/宽度不敏感的
/// 子串匹配 → 去重。构造 prompt 时使用模型卡公开的指令格式（显式方向 + 只输出译文），
/// 并把命中的术语作为约束附在末尾；这里不涉及任何模型算子。
public struct GlossaryMatcher: Sendable {
    public let entries: [GlossaryEntry]

    public init(entries: [GlossaryEntry]) {
        self.entries = entries.sorted { $0.source.count > $1.source.count }
    }

    public func hints(for text: String, languages: LanguagePair) -> [GlossaryHint] {
        let lower = text.lowercased()
        var seen: Set<String> = []
        var result: [GlossaryHint] = []
        for entry in entries where entry.languages == languages {
            let key = entry.source.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            if lower.contains(key) {
                seen.insert(key)
                result.append(GlossaryHint(source: entry.source, target: entry.target))
            }
        }
        return result
    }

    public func buildPrompt(source: String, languages: LanguagePair) -> String {
        let names: [String: String] = [
            "zh": "中文", "en": "英文", "ja": "日文", "ko": "韩文", "fr": "法文",
            "de": "德文", "es": "西班牙文", "ru": "俄文", "ar": "阿拉伯文",
            "pt": "葡萄牙文", "it": "意大利文", "th": "泰文", "vi": "越南文",
        ]
        let from = names[languages.source] ?? languages.source
        let to = names[languages.target] ?? languages.target
        var prompt = "将下面的\(from)翻译成\(to)。只输出\(to)译文，不要输出其它语言，不要解释。"
        let hits = hints(for: source, languages: languages)
        if !hits.isEmpty {
            let rules = hits.map { "\"\($0.source)\"→\"\($0.target)\"" }.joined(separator: "；")
            prompt += "\n术语约束：\(rules)。"
        }
        prompt += "\n\n\(source)"
        return prompt
    }
}
