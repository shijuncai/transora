import Foundation

/// 占位符协议。
///
/// 为什么需要它：译文里的行内对象（公式、链接、脚注标记、图片占位）不能由模型自由改写。
/// 做法是翻译前把行内对象替换成 `{{n}}`，翻译后校验 `{{n}}` 一个不少、一个不多、顺序不变，
/// 再由排版层把原对象放回去。
///
/// 为什么不是 `\uFFFC`（U+FFFC）或 `[[n]]`：
///     - U+FFFC 在很多模型的分词器里会被直接吃掉，之后无从校验；
///     - `[[n]]` 与 Markdown 链接语法冲突，模型容易自作聪明补成 `[n](url)`；
///     - `{{n}}` 是多数翻译模型见过的模板语法，被保留的概率最高，且边界清晰。
///
/// 容错：模型常输出全角括号 `｛｛1｝｝`、或加空格 `{{ 1 }}`。
/// 校验前统一归一化，避免把「格式差异」误报成「占位符丢失」。
public enum PDFPlaceholder {
    public struct Report: Equatable {
        public var missing: [Int] = []
        public var extra: [Int] = []
        public var duplicated: [Int] = []
        public var orderChanged = false
        public var balanced = true

        public var isClean: Bool {
            missing.isEmpty && extra.isEmpty && duplicated.isEmpty
                && !orderChanged && balanced
        }

        public var summary: String {
            if isClean { return "占位符完整" }
            var parts: [String] = []
            if !missing.isEmpty { parts.append("缺 \(missing.map { "{{\($0)}}" }.joined())") }
            if !extra.isEmpty { parts.append("多 \(extra.map { "{{\($0)}}" }.joined())") }
            if !duplicated.isEmpty { parts.append("重复 \(duplicated.map { "{{\($0)}}" }.joined())") }
            if orderChanged { parts.append("顺序变了") }
            if !balanced { parts.append("括号不配对") }
            return parts.joined(separator: "，")
        }
    }

    /// 正则只编译一次。
    ///
    /// 这个函数在每个块上会被调用 4 次（原文一次、译文一次、校验两次），
    /// 661 页 / 9382 块就是 7.5 万次 `NSRegularExpression` 编译——实测占了排版
    /// 总耗时的 60%（18.1s → 7.5s）。`NSRegularExpression` 是不可变对象，
    /// Apple 文档明确它线程安全，因此用 `nonisolated(unsafe)` 缓存。
    private static let innerSpaceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\{\\{\\s*([0-9]+)\\s*\\}\\}")
    private static let tokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\{\\{([0-9]+)\\}\\}")

    /// 把全角大括号与内部空格归一化为 `{{n}}`。
    public static func normalize(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "｛", with: "{")
        out = out.replacingOccurrences(of: "｝", with: "}")
        // `{{ 12 }}` → `{{12}}`：只动「纯数字 + 空格」的形态，不碰其它花括号
        guard let regex = innerSpaceRegex else {
            return out
        }
        let range = NSRange(out.startIndex..., in: out)
        let matches = regex.matches(in: out, range: range).reversed()
        for match in matches {
            guard let full = Range(match.range, in: out),
                  let numberRange = Range(match.range(at: 1), in: out) else { continue }
            out.replaceSubrange(full, with: "{{\(out[numberRange])}}")
        }
        return out
    }

    /// 提取占位符编号（按出现顺序，含重复）。
    public static func tokens(in text: String) -> [Int] {
        let normalized = normalize(text)
        guard let regex = tokenRegex else { return [] }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return regex.matches(in: normalized, range: range).compactMap { match in
            Range(match.range(at: 1), in: normalized).flatMap { Int(normalized[$0]) }
        }
    }

    /// 校验译文是否保持原文的占位符集合与顺序。
    public static func verify(source: String, translation: String) -> Report {
        var report = Report()
        let expected = tokens(in: source)
        let actual = tokens(in: translation)

        report.balanced = bracesBalanced(translation)
        let expectedSet = Set(expected)
        let actualSet = Set(actual)
        report.missing = expectedSet.subtracting(actualSet).sorted()
        report.extra = actualSet.subtracting(expectedSet).sorted()

        var counts: [Int: Int] = [:]
        for token in actual { counts[token, default: 0] += 1 }
        report.duplicated = counts.filter { $0.value > 1 && expectedSet.contains($0.key) }
            .keys.sorted()

        // 顺序：只在集合一致时比较，否则「顺序变了」是缺失/多余带来的噪声
        if report.missing.isEmpty && report.extra.isEmpty && report.duplicated.isEmpty {
            report.orderChanged = expected != actual
        }
        return report
    }

    /// 去掉占位符，用于度量与「纯文本预览」。
    public static func strip(_ text: String) -> String {
        normalize(text).replacingOccurrences(
            of: "\\{\\{[0-9]+\\}\\}", with: "", options: .regularExpression)
    }

    static func bracesBalanced(_ text: String) -> Bool {
        var depth = 0
        for character in normalize(text) {
            if character == "{" {
                depth += 1
                if depth > 2 { return false }
            } else if character == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    // MARK: - 翻译映射

    /// 译文映射：`blockID → 译文`。
    ///
    /// 表格单元格用 `表id:行:列` 作键（如 `t0:2:1`），与 `ILCell` 一一对应。
    /// 支持两种 JSON 形态，避免上游为了喂数据改结构：
    ///     { "p0-b0": "……", "t0:0:0": "……" }
    ///     { "pages": [ { "page": 1, "blocks": { "p0-b0": "……" } } ] }
    public struct TranslationMap {
        public var entries: [String: String]
        /// 仅用于报告：哪些键是当前文档里不存在的
        public var unknownKeys: [String] = []

        public init(entries: [String: String] = [:]) {
            self.entries = entries
        }

        public subscript(key: String) -> String? { entries[key] }

        public static func load(from url: URL) throws -> TranslationMap {
            let data = try Data(contentsOf: url)
            return try decode(data)
        }

        public static func decode(_ data: Data) throws -> TranslationMap {
            let object = try JSONSerialization.jsonObject(with: data)
            var map = TranslationMap()
            if let flat = object as? [String: Any] {
                if let pages = flat["pages"] as? [[String: Any]] {
                    for page in pages {
                        guard let blocks = page["blocks"] as? [String: Any] else { continue }
                        for (key, value) in blocks {
                            if let text = value as? String { map.entries[key] = text }
                        }
                        // 表格单元格可写成 { "tables": { "t0": { "0:0": "…" } } }
                        if let tables = page["tables"] as? [String: Any] {
                            for (tableID, value) in tables {
                                guard let cells = value as? [String: Any] else { continue }
                                for (cellKey, cellValue) in cells {
                                    if let text = cellValue as? String {
                                        map.entries["\(tableID):\(cellKey)"] = text
                                    }
                                }
                            }
                        }
                    }
                } else {
                    for (key, value) in flat {
                        if let text = value as? String { map.entries[key] = text }
                    }
                }
            }
            return map
        }
    }
}
