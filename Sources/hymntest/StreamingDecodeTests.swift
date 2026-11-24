import Foundation
import HymnSTQ

// 1260 全方向评测暴露的流式译文字符级损坏：实证「旧逻辑有 bug / 新逻辑修复」。
// 不改模型、不改权重、不改采样，只验证字符串增量解码层。

public func streamingDecodeSuite() throws -> [TestResult] {
    let suite = "streaming-decode"
    var out: [TestResult] = []

    // ---- 场景 1：跨 token 边界的多字节字符（尾部 U+FFFD 残留） ----
    // decode 前缀序列： "A" + 半个中文 → "A\u{FFFD}"，补齐 → "A中"，再加 → "A中B"
    let steps1 = ["A\u{FFFD}", "A\u{4E2D}", "A\u{4E2D}B"]
    func legacyStream(_ steps: [String]) -> String {
        var acc = "", last = ""
        for s in steps {
            acc += StreamingTextDecoder.legacyDelta(from: last, to: s)
            last = s
        }
        return acc
    }
    func newStream(_ steps: [String]) -> String {
        var d = StreamingTextDecoder()
        var acc = ""
        for s in steps { acc += d.delta(fullDecoded: s) }
        acc += d.finish(fullDecoded: steps.last ?? "")
        return acc
    }
    let legacy1 = legacyStream(steps1)
    let fixed1 = newStream(steps1)
    out.append(check(suite: suite, "旧 grapheme 前缀差会残留 U+FFFD（bug 复现）",
                     legacy1.contains("\u{FFFD}"), detail: "legacy=\(legacy1.debugDescription)"))
    out.append(check(suite: suite, "新 scalar 增量无 U+FFFD 残留且文本完整",
                     fixed1 == "A\u{4E2D}B" && !fixed1.contains("\u{FFFD}"),
                     detail: "fixed=\(fixed1.debugDescription)"))

    // ---- 场景 2：组合字符形成 grapheme cluster（相邻字符重复） ----
    // "क" → "क्"（U+0915 + U+094D virama）：Swift Character 会合并，旧逻辑整段重发。
    let steps2 = ["\u{0915}", "\u{0915}\u{094D}", "\u{0915}\u{094D}\u{092E}"]
    let legacy2 = legacyStream(steps2)
    let fixed2 = newStream(steps2)
    out.append(check(suite: suite, "旧 grapheme 前缀差在天城文组合字符上重复输出（bug 复现）",
                     legacy2 != "\u{0915}\u{094D}\u{092E}",
                     detail: "legacy=\(legacy2.debugDescription) expected=\("\u{0915}\u{094D}\u{092E}".debugDescription)"))
    out.append(check(suite: suite, "新 scalar 增量完整还原组合字符且不重复",
                     fixed2 == "\u{0915}\u{094D}\u{092E}",
                     detail: "fixed=\(fixed2.debugDescription)"))

    // ---- 场景 3：真实 tokenizer 逐 token 解码（强证据，需 tokenizer.json） ----
    guard let dirPath = SherryRuntimeProbe.status().modelDirectory else {
        out.append(check(suite: suite, "真实 tokenizer 逐 token 对照", false,
                         detail: "SKIP: 无模型目录"))
        return out
    }
    let tok = try HymnTokenizer(modelDirectory: URL(fileURLWithPath: dirPath, isDirectory: true))
    // 覆盖多种复杂脚本：高棉文、天城文、藏文、缅甸文、中文
    let probes = [
        "ខ្ញុំសូមពន្យល់ពីការបោះឆ្នោតរបស់យើង",
        "हम मतदान की व्याख्या करना चाहते हैं",
        "ང་ཚོས་རང་གི་འོས་བསྡུ་འགྲེལ་བཤད་བྱེད་དགོས།",
        "ကျွန်တော်တို့ မဲပေးမှုကို ရှင်းပြချင်ပါတယ်",
        "我们想解释一下我们的投票。",
    ]
    var legacyBad = 0, fixedBad = 0, detail = ""
    for text in probes {
        let ids = try tok.encode(text)
        var prefixSteps: [String] = []
        for i in 1...max(1, ids.count) {
            prefixSteps.append(tok.decode(Array(ids.prefix(i))))
        }
        let full = tok.decode(ids)
        let expected = full.replacingOccurrences(of: "\u{FFFD}", with: "")
        let l = legacyStream(prefixSteps)
        let f = newStream(prefixSteps)
        if l.contains("\u{FFFD}") || l != expected { legacyBad += 1 }
        if f != expected { fixedBad += 1 }
        if detail.isEmpty {
            detail = "tokens=\(ids.count) legacy=\(l.debugDescription.prefix(70)) "
                + "fixed=\(f.debugDescription.prefix(70))"
        }
    }
    out.append(check(suite: suite, "真实 tokenizer：旧逻辑在复杂脚本上确实损坏译文",
                     legacyBad > 0, detail: "bad=\(legacyBad)/\(probes.count) \(detail)"))
    out.append(check(suite: suite, "真实 tokenizer：新逻辑逐 token 拼接与一次性 decode 完全一致",
                     fixedBad == 0,
                     detail: "bad=\(fixedBad)/\(probes.count) \(detail)"))
    return out
}
