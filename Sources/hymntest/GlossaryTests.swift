import Foundation
import HymnCore

func glossarySuite() throws -> [TestResult] {
    let suite = "Glossary"
    var out: [TestResult] = []
    let enzh = LanguagePair(source: "en", target: "zh")
    let zhen = LanguagePair(source: "zh", target: "en")

    let entries = [
        GlossaryEntry(id: 1, source: "Transformer", target: "变换器", languages: enzh),
        GlossaryEntry(id: 2, source: "attention", target: "注意力", languages: enzh),
        GlossaryEntry(id: 3, source: "attention layer", target: "注意力层", languages: enzh),
        GlossaryEntry(id: 4, source: "注意力", target: "attention", languages: zhen),
    ]
    let matcher = GlossaryMatcher(entries: entries)

    let hits = matcher.hints(
        for: "The attention layer of a Transformer uses attention.",
        languages: enzh
    )
    out.append(check(suite: suite, "最长匹配优先：attention layer 排在 attention 前",
                     hits.first?.target == "注意力层",
                     detail: hits.map(\.source).joined(separator: " > ")))
    out.append(check(suite: suite, "大小写不敏感匹配",
                     hits.contains { $0.source == "Transformer" }))
    out.append(check(suite: suite, "语言对过滤：只返回 en->zh",
                     hits.allSatisfy { $0.source != "注意力" },
                     detail: "hits=\(hits.count)"))
    out.append(check(suite: suite, "去重：同一源术语只出现一次",
                     Set(hits.map(\.source)).count == hits.count,
                     detail: "\(hits.map(\.source))"))

    let prompt = matcher.buildPrompt(source: "The attention layer is fast.", languages: enzh)
    out.append(check(suite: suite, "prompt 含显式方向指令",
                     prompt.contains("将下面的英文翻译成中文") && prompt.contains("只输出中文译文")))
    out.append(check(suite: suite, "prompt 注入命中术语约束",
                     prompt.contains("\"attention layer\"→\"注意力层\""),
                     detail: String(prompt.prefix(120))))
    out.append(check(suite: suite, "prompt 以原文结尾",
                     prompt.hasSuffix("The attention layer is fast.")))

    let noHit = matcher.hints(for: "nothing matched here", languages: enzh)
    out.append(check(suite: suite, "无命中时返回空且不附加约束",
                     noHit.isEmpty && !matcher.buildPrompt(source: "nothing", languages: enzh).contains("术语约束")))

    return out
}
