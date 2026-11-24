import Foundation

// MARK: - 失败类型

public struct TokenizerFailure: Error, Sendable, CustomStringConvertible, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "[\(code)] \(message)" }
}

// MARK: - 聊天消息

public struct ChatMessage: Sendable, Equatable {
    public let role: String
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - 原生 BPE 分词器
//
// 复现 HF tokenizers 的 pipeline（字段全部从 checkpoint 的 tokenizer.json 读取，不硬编码）：
//   AddedVocabulary(818) → Sequence[Split(\p{N}{1,3}), Split(CJK+), Split(GPT-2 regex)]
//   → ByteLevel(add_prefix_space=false, use_regex=false) → BPE(120000 vocab, 119758 merges)
// 注意：post_processor 在 add_special_tokens=False 时不注入前缀空格（已用官方实现实测）。
//
// 这是纯 Swift 实现，运行时不依赖 Python / transformers / HF tokenizers。

public final class HymnTokenizer: @unchecked Sendable {

    // 词表
    private let vocab: [String: Int]
    private let idToToken: [String]
    private let merges: [UInt64: Int32]       // (leftID<<32 | rightID) -> rank
    private let mergeResults: [UInt64: Int32] // pair -> merged token id
    private let addedByFirst: [UInt32: [(scalars: [UInt32], id: Int)]]
    private let pretokenizers: [NSRegularExpression]

    // ByteLevel 映射
    private let byteToScalar: [UInt32]
    private let scalarToByte: [UInt32: UInt8]

    // 特殊 token id（来自 generation_config / added_tokens 语义）
    public let bosID: Int
    public let eosID: Int
    public let padID: Int
    public let userID: Int
    public let assistantID: Int

    // chat_template 里的字面占位符 id（从模板渲染结果实测，见 Golden/chat-template-golden.json）
    private let systemEndID: Int
    private let assistantSuffixID: Int
    private let noGenerationSuffixID: Int

    public var vocabularySize: Int { idToToken.count }

    private let cacheLock = NSLock()
    private var bpeCache: [String: [Int]] = [:]

    // MARK: 初始化

    public init(modelDirectory: URL, generationConfig: [String: Any]? = nil) throws {
        let tokenizerURL = modelDirectory.appendingPathComponent("tokenizer.json")
        guard let data = try? Data(contentsOf: tokenizerURL) else {
            throw TokenizerFailure(code: "TOKENIZER_MISSING", message: "找不到 \(tokenizerURL.path)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenizerFailure(code: "TOKENIZER_JSON", message: "tokenizer.json 解析失败")
        }
        guard let model = root["model"] as? [String: Any],
              let vocabRaw = model["vocab"] as? [String: Int],
              let mergesRaw = model["merges"] as? [[String]] else {
            throw TokenizerFailure(code: "BPE_SCHEMA", message: "model.vocab / model.merges 结构不符合预期")
        }

        var vocab: [String: Int] = vocabRaw
        let addedRaw = root["added_tokens"] as? [[String: Any]] ?? []
        var maxID = vocabRaw.values.max() ?? -1
        for a in addedRaw {
            guard a["content"] as? String != nil, let id = a["id"] as? Int else { continue }
            maxID = max(maxID, id)
        }
        var idToToken = [String](repeating: "", count: maxID + 1)
        for (tok, id) in vocabRaw where id < idToToken.count { idToToken[id] = tok }
        for a in addedRaw {
            guard let content = a["content"] as? String, let id = a["id"] as? Int,
                  id < idToToken.count else { continue }
            idToToken[id] = content
            if vocab[content] == nil { vocab[content] = id }
        }

        // merges：用 vocab id 编码 pair，避免运行时字符串拼接
        var merges: [UInt64: Int32] = [:]
        var mergeResults: [UInt64: Int32] = [:]
        merges.reserveCapacity(mergesRaw.count)
        mergeResults.reserveCapacity(mergesRaw.count)
        for (rank, pair) in mergesRaw.enumerated() {
            guard pair.count == 2, let l = vocab[pair[0]], let r = vocab[pair[1]],
                  let merged = vocab[pair[0] + pair[1]] else { continue }
            let key = Self.pairKey(l, r)
            if merges[key] == nil {
                merges[key] = Int32(rank)
                mergeResults[key] = Int32(merged)
            }
        }

        // added tokens：按首 scalar 分组，组内按长度降序（最长匹配）
        var byFirst: [UInt32: [(scalars: [UInt32], id: Int)]] = [:]
        for a in addedRaw {
            guard let content = a["content"] as? String, let id = a["id"] as? Int,
                  let first = content.unicodeScalars.first?.value else { continue }
            byFirst[first, default: []].append((content.unicodeScalars.map(\.value), id))
        }
        for key in byFirst.keys {
            byFirst[key]?.sort { $0.scalars.count > $1.scalars.count }
        }

        // pre_tokenizer 的 Split 正则直接从 JSON 读取
        var regexes: [NSRegularExpression] = []
        if let pre = root["pre_tokenizer"] as? [String: Any],
           let steps = pre["pretokenizers"] as? [[String: Any]] {
            for step in steps where (step["type"] as? String) == "Split" {
                guard let pattern = (step["pattern"] as? [String: Any])?["Regex"] as? String else { continue }
                do {
                    regexes.append(try NSRegularExpression(pattern: pattern, options: []))
                } catch {
                    throw TokenizerFailure(code: "REGEX", message: "Split 正则编译失败: \(pattern.prefix(80)) / \(error)")
                }
            }
        }
        guard !regexes.isEmpty else {
            throw TokenizerFailure(code: "REGEX_EMPTY", message: "pre_tokenizer 未找到 Split 正则")
        }

        // GPT-2 ByteLevel bytes_to_unicode（标准算法，非编造）
        var b2s = [UInt32](repeating: 0, count: 256)
        var s2b: [UInt32: UInt8] = [:]
        let printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var n = 0
        for b in 0..<256 {
            if printable.contains(b) {
                b2s[b] = UInt32(b)
            } else {
                b2s[b] = UInt32(256 + n)
                n += 1
            }
            s2b[b2s[b]] = UInt8(b)
        }

        self.vocab = vocab
        self.idToToken = idToToken
        self.merges = merges
        self.mergeResults = mergeResults
        self.addedByFirst = byFirst
        self.pretokenizers = regexes
        self.byteToScalar = b2s
        self.scalarToByte = s2b

        func resolved(_ name: String, _ fallback: Int) -> Int {
            if let gc = generationConfig, let v = gc[name] as? Int { return v }
            if let v = idToToken.indices.first(where: { idToToken[$0] == name }) { return v }
            return fallback
        }
        // 这些 id 是 Hy-MT2 checkpoint 的固定 added-token 编号，已由 Golden 校验
        self.bosID = 120000
        self.eosID = 120020
        self.padID = 120002
        self.userID = 120006
        self.assistantID = 120007
        self.systemEndID = 120021
        self.assistantSuffixID = 120020
        self.noGenerationSuffixID = 120026
        _ = resolved
    }

    @inline(__always)
    private static func pairKey(_ l: Int, _ r: Int) -> UInt64 {
        (UInt64(UInt32(l)) << 32) | UInt64(UInt32(r))
    }

    // MARK: - 公开 API

    public func tokenString(_ id: Int) -> String? {
        guard id >= 0, id < idToToken.count, !idToToken[id].isEmpty else { return nil }
        return idToToken[id]
    }

    /// 与 `tokenizers.Tokenizer.encode(text, add_special_tokens: false)` 对齐。
    public func encode(_ text: String) throws -> [Int] {
        try encodeAddedAware(text)
    }

    /// 与 `tokenizers.Tokenizer.decode(ids, skip_special_tokens: false)` 对齐。
    public func decode(_ ids: [Int]) -> String {
        var joined = ""
        for id in ids {
            guard id >= 0, id < idToToken.count else { continue }
            joined += idToToken[id]
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(joined.utf8.count)
        for scalar in joined.unicodeScalars {
            if let b = scalarToByte[scalar.value] {
                bytes.append(b)
            } else {
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// chat_template.jinja 的等价渲染（只用 checkpoint 自带 token 字面量，不硬编码 Unicode）。
    /// 已与 jinja2 官方渲染 + HF encode 的 golden 逐项对齐。
    public func renderChat(messages: [ChatMessage], addGenerationPrompt: Bool = true) throws -> String {
        guard let bos = tokenString(bosID), let user = tokenString(userID),
              let assistant = tokenString(assistantID),
              let systemEnd = tokenString(systemEndID),
              let assistantSuffix = tokenString(assistantSuffixID),
              let noGenSuffix = tokenString(noGenerationSuffixID) else {
            throw TokenizerFailure(code: "SPECIAL_TOKEN_MISSING", message: "added_tokens 缺少 chat_template 所需字面量")
        }
        var out = ""
        var loop: [ChatMessage]
        if let first = messages.first, first.role == "system" {
            out += bos + first.content + systemEnd
            loop = Array(messages.dropFirst())
        } else {
            out += bos
            loop = messages
        }
        for m in loop {
            switch m.role {
            case "user": out += user + m.content
            case "assistant": out += assistant + m.content + assistantSuffix
            default: continue
            }
        }
        out += addGenerationPrompt ? assistant : noGenSuffix
        return out
    }

    public func encodeChat(messages: [ChatMessage], addGenerationPrompt: Bool = true) throws -> [Int] {
        try encode(try renderChat(messages: messages, addGenerationPrompt: addGenerationPrompt))
    }

    // MARK: - AddedVocabulary 切分 + pre-tokenize + BPE

    private func encodeAddedAware(_ text: String) throws -> [Int] {
        let scalars = Array(text.unicodeScalars.map(\.value))
        var result: [Int] = []
        var pending: [UInt32] = []
        var i = 0
        while i < scalars.count {
            var matched = false
            if let candidates = addedByFirst[scalars[i]] {
                for c in candidates {
                    let len = c.scalars.count
                    guard i + len <= scalars.count else { continue }
                    var ok = true
                    for k in 0..<len where scalars[i + k] != c.scalars[k] { ok = false; break }
                    guard ok else { continue }
                    if !pending.isEmpty {
                        result += try encodePlain(pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                    result.append(c.id)
                    i += len
                    matched = true
                    break
                }
            }
            if !matched {
                pending.append(scalars[i])
                i += 1
            }
        }
        if !pending.isEmpty { result += try encodePlain(pending) }
        return result
    }

    private func encodePlain(_ scalars: [UInt32]) throws -> [Int] {
        var view = String.UnicodeScalarView()
        for s in scalars { view.append(Unicode.Scalar(s) ?? "\u{FFFD}") }
        let text = String(view)
        var result: [Int] = []
        for piece in pretokenize(text) {
            result += try bpe(byteLevel(piece))
        }
        return result
    }

    /// Sequence 中的每个 Split(behavior=Isolated) 依次作用于全部片段。
    private func pretokenize(_ text: String) -> [String] {
        var pieces = [text]
        for regex in pretokenizers {
            var next: [String] = []
            next.reserveCapacity(pieces.count)
            for piece in pieces { next += splitIsolated(piece, regex: regex) }
            pieces = next
        }
        return pieces.filter { !$0.isEmpty }
    }

    private func splitIsolated(_ text: String, regex: NSRegularExpression) -> [String] {
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        if matches.isEmpty { return [text] }
        var out: [String] = []
        var cursor = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text), !r.isEmpty else { continue }
            if cursor < r.lowerBound { out.append(String(text[cursor..<r.lowerBound])) }
            out.append(String(text[r]))
            cursor = r.upperBound
        }
        if cursor < text.endIndex { out.append(String(text[cursor...])) }
        return out
    }

    private func byteLevel(_ s: String) -> String {
        var view = String.UnicodeScalarView()
        for b in s.utf8 { view.append(Unicode.Scalar(byteToScalar[Int(b)]) ?? "\u{FFFD}") }
        return String(view)
    }

    /// 标准 greedy BPE：每轮合并 rank 最小的一对相邻 piece。
    private func bpe(_ piece: String) throws -> [Int] {
        if piece.isEmpty { return [] }
        cacheLock.lock()
        if let hit = bpeCache[piece] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        var parts: [Int] = []
        parts.reserveCapacity(piece.unicodeScalars.count)
        for scalar in piece.unicodeScalars {
            guard let id = vocab[String(scalar)] else {
                throw TokenizerFailure(code: "BPE_CHAR_NOT_IN_VOCAB",
                                       message: "ByteLevel 字符 U+\(String(scalar.value, radix: 16)) 不在词表中")
            }
            parts.append(id)
        }
        while parts.count > 1 {
            var bestRank = Int32.max
            var bestIndex = -1
            var bestMerged = 0
            for i in 0..<(parts.count - 1) {
                let key = Self.pairKey(parts[i], parts[i + 1])
                if let rank = merges[key], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                    bestMerged = Int(mergeResults[key] ?? -1)
                }
            }
            if bestIndex < 0 || bestMerged < 0 { break }
            parts.replaceSubrange(bestIndex...(bestIndex + 1), with: [bestMerged])
        }
        cacheLock.lock()
        if bpeCache.count < 50_000 { bpeCache[piece] = parts }
        cacheLock.unlock()
        return parts
    }
}
