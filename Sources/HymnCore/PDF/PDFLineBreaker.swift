import Foundation

/// 断行：贪心 + 中文禁则。
///
/// 为什么不用 CoreText 的 `CTTypesetterSuggestLineBreak`：
///     ① 它按自己的整形结果切行，而我们按 `/W` 绘制，两边的宽度会差一点点；
///     ② 它不认中文禁则，会出现「行首是。」这种明显外行的结果；
///     ③ 它不告诉我们「为了守禁则而超宽了多少」，而这一点必须能上报。
///
/// 规则（按优先级）：
///     ① 保留显式换行；
///     ② 空格处可断，行首行尾的空格丢掉；
///     ③ 中文可在任意两字之间断，但守「行首禁则 / 行尾禁则」；
///     ④ 拉丁词内不断（宁可整词换行），除非单词本身比整行还宽；
///     ⑤ 数字与紧随的 `%`、`℃` 等不断开。
public enum PDFLineBreaker {
    public struct Options {
        /// 关闭禁则只用于对照实验，正常必须开
        public var kinsoku = true
        /// 单词比整行还宽时，允许硬切（否则会无限循环）
        public var allowHardSplit = true

        public init() {}
    }

    public struct Line {
        public var text: String
        public var width: Double
        /// 为了守禁则或硬切单词，这一行比可用宽度更宽
        public var overfull: Bool
        /// 由显式换行符结束
        public var hardBreak: Bool
    }

    public static func breakLines(
        text: String,
        font: TrueTypeFont,
        size: Double,
        maxWidth: Double,
        options: Options = Options()
    ) -> [Line] {
        let characters = Array(text)
        guard !characters.isEmpty, size > 0, maxWidth > 0 else {
            return [Line(text: text, width: 0, overfull: false, hardBreak: true)]
        }

        // 逐字符宽度与累积宽度：断行回扫时需要 O(1) 取区间宽度
        var widths = [Double](repeating: 0, count: characters.count)
        var cumulative = [Double](repeating: 0, count: characters.count + 1)
        for (i, character) in characters.enumerated() {
            var w = 0.0
            for scalar in character.unicodeScalars {
                w += PDFTextMetrics.advance(scalar, font: font, size: size)
            }
            widths[i] = w
            cumulative[i + 1] = cumulative[i] + w
        }

        var lines: [Line] = []
        var start = 0

        func emit(_ range: Range<Int>, hardBreak: Bool) {
            var lower = range.lowerBound
            var upper = range.upperBound
            // 行首尾空格不参与排版，但仍算宽度（PDF 里本来也没有行首空格）
            while lower < upper, characters[lower].isWhitespace,
                  characters[lower] != "\n" { lower += 1 }
            while upper > lower, characters[upper - 1].isWhitespace,
                  characters[upper - 1] != "\n" { upper -= 1 }
            let text = String(characters[lower..<upper])
            let width = cumulative[upper] - cumulative[lower]
            lines.append(Line(text: text, width: width,
                              overfull: width > maxWidth + 0.01, hardBreak: hardBreak))
        }

        while start < characters.count {
            // 显式换行优先：直接切
            if let newline = characters[start...].firstIndex(of: "\n") {
                if cumulative[newline] - cumulative[start] <= maxWidth {
                    emit(start..<newline, hardBreak: true)
                    start = newline + 1
                    continue
                }
                // 换行前的内容本身也放不下，走常规断行（不吞掉换行）
            }

            if cumulative[characters.count] - cumulative[start] <= maxWidth {
                emit(start..<characters.count, hardBreak: true)
                break
            }

            // 贪心：先算出**真正放得下的最大字符数**，再回扫合法断点。
            // 早期版本的边界算错了一位（把「溢出后的位置」当断点），
            // 结果每行都多塞一个字，整页右边缘被撑出去。
            var fitEnd = start + 1
            while fitEnd < characters.count,
                  cumulative[fitEnd + 1] - cumulative[start] <= maxWidth + 0.01 {
                fitEnd += 1
            }

            var breakPoint = fitEnd
            var chosen = -1
            var candidate = fitEnd
            while candidate > start + 1 {
                let legal = candidate >= characters.count
                    || canBreak(between: characters[candidate - 1], and: characters[candidate])
                if legal {
                    chosen = candidate
                    break
                }
                candidate -= 1
            }

            if chosen < 0 {
                // 没有任何合法断点：单词（或单个超宽字符）比整行还宽
                if fitEnd >= characters.count {
                    breakPoint = characters.count
                } else if options.allowHardSplit {
                    breakPoint = fitEnd
                } else {
                    emit(start..<characters.count, hardBreak: true)
                    break
                }
            } else {
                breakPoint = chosen
            }

            if options.kinsoku {
                breakPoint = adjustForKinsoku(
                    characters: characters, proposed: breakPoint, start: start)
            }

            emit(start..<min(breakPoint, characters.count), hardBreak: false)
            start = min(breakPoint, characters.count)
        }

        // 空文本也要给一行，否则调用方没法区分「没有内容」和「排版失败」
        return lines.isEmpty ? [Line(text: "", width: 0, overfull: false, hardBreak: true)] : lines
    }

    /// 禁则修正。
    ///
    /// - 行首是禁则字符（。，」）等）：把它拉回上一行，代价是那一行略宽；
    /// - 行尾是禁则字符（「（《）等）：把它推到下一行，代价是上一行略短；
    /// - 最多挪 2 个字符，避免「一整串标点」把行拉得离谱。
    static func adjustForKinsoku(
        characters: [Character], proposed: Int, start: Int
    ) -> Int {
        var point = proposed
        guard point >= start + 2 else { return point }

        // 行首禁则：往后吞，直到行首字符可以出现
        var pulled = 0
        while point < characters.count, pulled < 2,
              isProhibitedAtLineStart(characters[point]) {
            point += 1
            pulled += 1
        }
        if pulled > 0 { return point }

        // 行尾禁则：往前退，把它留给下一行
        var pushed = 0
        while point > start + 2, pushed < 2,
              isProhibitedAtLineEnd(characters[point - 1]) {
            point -= 1
            pushed += 1
        }
        return point
    }

    /// 两个字符之间能否断开。
    static func canBreak(between previous: Character, and next: Character) -> Bool {
        // 空格处总能断
        if next.isWhitespace || previous.isWhitespace { return true }

        // 行首禁则：不能把「。」放到行首
        if isProhibitedAtLineStart(next) { return false }
        // 行尾禁则：不能把「（」留在行尾
        if isProhibitedAtLineEnd(previous) { return false }

        // 数字与单位、百分号绑定
        if previous.isNumber, next.isNumber { return false }
        if previous.isNumber, isUnitMark(next) { return false }

        // 连字符/斜杠后可以断（英文复合词、路径）
        if previous == "-" || previous == "–" || previous == "/" { return true }
        if isLatinLetter(previous) && next == "-" { return true }

        // 中文（含全角标点）可以在字间断
        if isCJK(previous) || isCJK(next) { return true }

        // 拉丁词内不断
        if isLatinLetter(previous) && isLatinLetter(next) { return false }

        return true
    }

    // MARK: - 字符分类

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x2EFF).contains(scalar)      // 部首
            || (0x3000...0x303F).contains(scalar)      // 中文标点
            || (0x3040...0x30FF).contains(scalar)      // 假名
            || (0x3400...0x4DBF).contains(scalar)      // 扩展 A
            || (0x4E00...0x9FFF).contains(scalar)      // 基本区
            || (0xF900...0xFAFF).contains(scalar)      // 兼容汉字
            || (0xFF00...0xFFEF).contains(scalar)      // 全角
            || scalar >= 0x20000
    }

    static func isLatinLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        if (0x41...0x5A).contains(scalar) || (0x61...0x7A).contains(scalar) { return true }
        if (0xC0...0x24F).contains(scalar) { return true }        // 带变音的拉丁
        if (0x370...0x3FF).contains(scalar) { return true }        // 希腊
        if (0x400...0x4FF).contains(scalar) { return true }        // 西里尔
        return false
    }

    static func isUnitMark(_ character: Character) -> Bool {
        "％%℃°‰′″".contains(character)
    }

    /// 不能出现在行首的字符。
    static let prohibitedAtLineStart: Set<Character> = [
        "。", "，", "、", "；", "：", "？", "！", "）", "〕", "］", "｝", "〉", "》",
        "」", "』", "】", "”", "’", "·", "…", "‥", "ー", "々", "〜", "～", "‰",
        "℃", "°", "′", "″", "%", "％",
        ",", ".", ";", ":", "?", "!", ")", "]", "}", "'", "\"",
    ]

    static func isProhibitedAtLineStart(_ character: Character) -> Bool {
        prohibitedAtLineStart.contains(character)
    }

    /// 不能留在行尾的字符。
    static let prohibitedAtLineEnd: Set<Character> = [
        "（", "〔", "［", "｛", "〈", "《", "「", "『", "【", "“", "‘",
        "(", "[", "{", "¥", "￥", "$", "€", "£",
    ]

    static func isProhibitedAtLineEnd(_ character: Character) -> Bool {
        prohibitedAtLineEnd.contains(character)
    }
}
