import Foundation
import HymnSTQ

private func goldenDirectory() -> URL {
    if let d = ProcessInfo.processInfo.environment["HYMN_GOLDEN_DIR"] {
        return URL(fileURLWithPath: d)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Golden")
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TokenizerFailure(code: "GOLDEN_JSON", message: url.path)
    }
    return obj
}

/// D1-β：原生 BPE / ByteLevel / chat_template 与官方 HF tokenizers golden 逐项对齐。
public func tokenizerSuite() throws -> [TestResult] {
    let suite = "tokenizer"
    var out: [TestResult] = []

    guard let dirPath = SherryRuntimeProbe.status().modelDirectory else {
        return [check(suite: suite, "模型目录可用", false,
                      detail: "设置 HYMN_SHERRY_MODEL_DIR 指向含 tokenizer.json 的 GGUF 目录")]
    }
    let modelDir = URL(fileURLWithPath: dirPath, isDirectory: true)

    let t0 = DispatchTime.now().uptimeNanoseconds
    let tokenizer: HymnTokenizer
    do {
        tokenizer = try HymnTokenizer(modelDirectory: modelDir)
    } catch {
        return [check(suite: suite, "原生分词器初始化", false, detail: "\(error)")]
    }
    let initMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

    out.append(check(suite: suite, "原生分词器从 tokenizer.json 初始化成功",
                     tokenizer.vocabularySize == 120_818,
                     detail: String(format: "vocabSize=%d init=%.1f ms", tokenizer.vocabularySize, initMs)))
    out.append(check(suite: suite, "特殊 token id 与 checkpoint 一致",
                     tokenizer.bosID == 120_000 && tokenizer.eosID == 120_020
                        && tokenizer.userID == 120_006 && tokenizer.assistantID == 120_007,
                     detail: "bos=\(tokenizer.bosID) eos=\(tokenizer.eosID) user=\(tokenizer.userID) asst=\(tokenizer.assistantID)"))

    // ---- BPE golden（31 个覆盖数字/CJK/空白/多语言/特殊 token 的样本） ----
    let goldenURL = goldenDirectory().appendingPathComponent("tokenizer-golden-v2.json")
    guard let golden = try? readJSON(goldenURL),
          let samples = golden["samples"] as? [[String: Any]] else {
        out.append(check(suite: suite, "BPE golden 可读", false, detail: goldenURL.path))
        return out
    }

    var mismatches: [String] = []
    var roundtripMismatches: [String] = []
    var totalIDs = 0
    for s in samples {
        guard let text = s["text"] as? String,
              let expected = s["ids"] as? [Int],
              let expectedRoundtrip = s["roundtrip"] as? String else { continue }
        do {
            let got = try tokenizer.encode(text)
            totalIDs += expected.count
            if got != expected {
                mismatches.append("\(text.debugDescription): got=\(got) want=\(expected)")
            }
            let decoded = tokenizer.decode(expected)
            if decoded != expectedRoundtrip {
                roundtripMismatches.append("\(text.debugDescription): got=\(decoded.debugDescription) want=\(expectedRoundtrip.debugDescription)")
            }
        } catch {
            mismatches.append("\(text.debugDescription): THREW \(error)")
        }
    }
    out.append(check(suite: suite, "分词器输出与官方 HF tokenizers 逐项一致",
                     mismatches.isEmpty && samples.count == 31,
                     detail: "samples=\(samples.count) mismatch=\(mismatches.count)"
                        + (mismatches.isEmpty ? "" : " 首例: " + mismatches[0])))
    out.append(check(suite: suite, "decode 与官方 ByteLevel decoder 逐项一致",
                     roundtripMismatches.isEmpty,
                     detail: "mismatch=\(roundtripMismatches.count)"
                        + (roundtripMismatches.isEmpty ? "" : " 首例: " + roundtripMismatches[0])))

    // ---- chat_template golden ----
    let chatURL = goldenDirectory().appendingPathComponent("chat-template-golden.json")
    guard let chatGolden = try? readJSON(chatURL),
          let cases = chatGolden["cases"] as? [[String: Any]] else {
        out.append(check(suite: suite, "chat_template golden 可读", false, detail: chatURL.path))
        return out
    }
    var renderMismatches: [String] = []
    var chatIDMismatches: [String] = []
    for c in cases {
        guard let args = c["args"] as? [String: Any],
              let msgs = args["messages"] as? [[String: String]],
              let addGen = args["add_generation_prompt"] as? Bool,
              let expectedRendered = c["rendered"] as? String,
              let expectedIDs = c["ids"] as? [Int] else { continue }
        let messages = msgs.compactMap { d -> ChatMessage? in
            guard let r = d["role"], let t = d["content"] else { return nil }
            return ChatMessage(role: r, content: t)
        }
        do {
            let rendered = try tokenizer.renderChat(messages: messages, addGenerationPrompt: addGen)
            if rendered != expectedRendered { renderMismatches.append("case \(cases.firstIndex(where: { ($0["args"] as? [String: Any])?["messages"] as? [[String: String]] == msgs }) ?? -1): \(rendered.debugDescription) != \(expectedRendered.debugDescription)") }
            let ids = try tokenizer.encode(rendered)
            if ids != expectedIDs { chatIDMismatches.append("got=\(ids) want=\(expectedIDs)") }
        } catch {
            renderMismatches.append("THREW \(error)")
        }
    }
    out.append(check(suite: suite, "chat_template 渲染与 jinja2 官方输出逐字符一致",
                     renderMismatches.isEmpty && cases.count == 5,
                     detail: "cases=\(cases.count) mismatch=\(renderMismatches.count)"
                        + (renderMismatches.isEmpty ? "" : " 首例: " + renderMismatches[0])))
    out.append(check(suite: suite, "聊天提示词 token id 与官方一致（含 system / 多轮 / 占位符）",
                     chatIDMismatches.isEmpty,
                     detail: "mismatch=\(chatIDMismatches.count)"
                        + (chatIDMismatches.isEmpty ? "" : " 首例: " + chatIDMismatches[0])))

    // ---- 性能（真实 Swift 编码吞吐，非模型推理） ----
    let benchTexts = samples.compactMap { $0["text"] as? String }
    let repeats = 20
    let b0 = DispatchTime.now().uptimeNanoseconds
    var encodedCount = 0
    for _ in 0..<repeats {
        for text in benchTexts { encodedCount += (try? tokenizer.encode(text).count) ?? 0 }
    }
    let benchMs = Double(DispatchTime.now().uptimeNanoseconds - b0) / 1e6
    let tokensPerSec = benchMs > 0 ? Double(encodedCount) / (benchMs / 1000.0) : 0
    out.append(check(suite: suite, "分词器可用且吞吐可测",
                     encodedCount > 0 && tokensPerSec > 0,
                     detail: String(format: "%.0f tokens/s (%d tokens, %.1f ms, %d repeats)",
                                    tokensPerSec, encodedCount, benchMs, repeats)))

    // 落盘独立性能数据
    if let dir = ProcessInfo.processInfo.environment["HYMN_REPORT_DIR"] {
        let json = """
        {
          "module": "HymnSTQ.HymnTokenizer",
          "scope": "tokenizer encode/decode benchmark, NOT model inference",
          "vocab_size": \(tokenizer.vocabularySize),
          "golden_samples": \(samples.count),
          "golden_total_ids": \(totalIDs),
          "id_mismatches": \(mismatches.count),
          "decode_mismatches": \(roundtripMismatches.count),
          "chat_template_cases": \(cases.count),
          "render_mismatches": \(renderMismatches.count),
          "chat_id_mismatches": \(chatIDMismatches.count),
          "init_ms": \(String(format: "%.3f", initMs)),
          "encode_tokens_per_sec": \(String(format: "%.1f", tokensPerSec)),
          "bench_tokens": \(encodedCount),
          "bench_ms": \(String(format: "%.3f", benchMs))
        }
        """
        try? json.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tokenizer-perf.json"),
                        atomically: true, encoding: .utf8)
    }
    return out
}
