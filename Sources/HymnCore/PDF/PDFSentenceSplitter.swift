import Foundation

/// 把长段落切成「能塞进 KV 窗口」的碎片。
///
/// 为什么需要：1.25bit 1.8B 的窗口是 2048 token，一段 1500 字符的英文正文
/// 光提示词就要 900 token。旧版给 `maxTokens` 硬填 1024，生成器直接抛
/// `SEQUENCE_TOO_LONG`，整段回落原文——一页正文能有一半是英文。
///
/// 切分原则：**只认句末标点**，并跳过 `Fig.` / `Eq.` / `et al.` 这类缩写。
/// 切在缩写后面会把「as shown in Fig. 3」拆成「如图。」+「3 所示」。
public enum PDFSentenceSplitter {
    /// 常见缩写（小写比较）：句点后面不是真句子边界
    static let abbreviations: Set<String> = [
        "fig", "figs", "eq", "eqs", "table", "tables", "ref", "refs",
        "no", "nos", "vol", "pp", "al", "e.g", "i.e", "vs", "cf",
        "dr", "prof", "approx", "ca", "sec", "sect", "ch", "chap",
    ]

    /// 按句子切成不超过 `limit` 个字符的碎片；不超长时原样返回一个元素。
    public static func chunks(_ text: String, limit: Int) -> [String] {
        guard limit > 0, text.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        var tailWord = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1

            let isTerminator = ".!?。！？".contains(character)
            let followedBySpace = index < characters.count && characters[index] == " "
            if !isTerminator || !followedBySpace {
                if !character.isWhitespace { tailWord.append(character) }
                continue
            }
            // 缩写保护：只看句点前最后一个词
            if character == ".", abbreviations.contains(tailWord.lowercased()) {
                tailWord.append(character)
                continue
            }
            if current.count >= limit {
                pieces.append(current)
                current = ""
            }
            tailWord = ""
        }
        if !current.isEmpty { pieces.append(current) }

        // 整段没有句末标点（货号清单、表格串、化学式）：只能按字数硬切
        return pieces.flatMap { piece -> [String] in
            guard piece.count > limit * 3 / 2 else { return [piece] }
            var slices: [String] = []
            var offset = 0
            while offset < piece.count {
                let start = piece.index(piece.startIndex, offsetBy: offset)
                let length = min(limit, piece.count - offset)
                let end = piece.index(start, offsetBy: length)
                slices.append(String(piece[start..<end]))
                offset += length
            }
            return slices
        }
    }
}
