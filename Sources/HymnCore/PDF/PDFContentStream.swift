import Foundation

/// 内容流分词：把操作符序列切成「操作数段 + 算子」，并记录每个 token 的字节区间。
///
/// 记录区间而不是重建字符串，是为了让「文本驱逐」能做到**字节级保留**：
/// 除了被删掉的那几个显示算子，其余字节一个都不动（含原有空白、注释、
/// 数字写法、内联图像数据）。
public enum PDFContentStream {
    public struct Token: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case operand, op }
        public var kind: Kind
        public var start: Int
        public var end: Int
        /// 算子名（kind == .op 时有效）。内联图像记为 "BI"。
        public var op: String?

        public init(kind: Kind, start: Int, end: Int, op: String? = nil) {
            self.kind = kind
            self.start = start
            self.end = end
            self.op = op
        }
    }

    /// 会实际画出字形的算子。删除这四个就等于「把这段文字从页面上抹掉」，
    /// 同时旧文本不再存在于文件里（不可复制、不可检索）。
    public static let textShowingOperators: Set<String> = ["Tj", "TJ", "'", "\""]

    public static func tokenize(_ data: Data) -> [Token] {
        let bytes = [UInt8](data)
        var tokens: [Token] = []
        var parser = PDFParser(bytes)
        var guardCount = 0

        while true {
            parser.skipWhiteAndComments()
            guard parser.index < bytes.count else { break }
            guardCount += 1
            if guardCount > 5_000_000 { break } // 防御：异常输入不至于死循环

            let start = parser.index
            let b = bytes[start]

            // 括号类单字符算子
            if b == 0x27 || b == 0x22 {
                parser.index += 1
                tokens.append(Token(kind: .op, start: start, end: parser.index,
                                    op: String(UnicodeScalar(b))))
                continue
            }

            // 操作数：名称 / 字符串 / 数组 / 字典 / 数字
            let isOperandStart = b == 0x2F || b == 0x28 || b == 0x3C || b == 0x5B
                || b == 0x2B || b == 0x2D || b == 0x2E || (b >= 0x30 && b <= 0x39)
            if isOperandStart {
                do {
                    _ = try parser.parseValue()
                    tokens.append(Token(kind: .operand, start: start, end: parser.index))
                } catch {
                    // 解析不动就按单字节跳过，保证不会卡死
                    parser.index = start + 1
                }
                continue
            }

            // 算子
            let opStart = parser.index
            while parser.index < bytes.count && PDFParser.isRegular(bytes[parser.index]) {
                parser.index += 1
            }
            if parser.index == opStart {
                parser.index += 1 // 无法识别的分隔符，跳过
                continue
            }
            let op = String(decoding: bytes[opStart..<parser.index], as: UTF8.self)

            switch op {
            case "true", "false", "null":
                tokens.append(Token(kind: .operand, start: opStart, end: parser.index))
            case "BI":
                // 内联图像：ID 之后是二进制，必须整体跳过直到 EI
                let afterID = skipInlineImageData(bytes: bytes, from: parser.index)
                parser.index = afterID
                tokens.append(Token(kind: .op, start: opStart, end: afterID, op: "BI"))
            default:
                tokens.append(Token(kind: .op, start: opStart, end: parser.index, op: op))
            }
        }
        return tokens
    }

    /// 从 BI 之后找 ID，再从 ID 之后找独立的 EI。找不到就退到流末尾。
    static func skipInlineImageData(bytes: [UInt8], from start: Int) -> Int {
        var i = start
        // 找 ID
        while i + 1 < bytes.count {
            if bytes[i] == 0x49, bytes[i + 1] == 0x44,
               i == start || PDFParser.isWhite(bytes[i - 1]) {
                i += 2
                if i < bytes.count, PDFParser.isWhite(bytes[i]) { i += 1 }
                break
            }
            i += 1
        }
        // 找 EI（前一个字节必须是空白）
        while i + 1 < bytes.count {
            if bytes[i] == 0x45, bytes[i + 1] == 0x49,
               i > 0, PDFParser.isWhite(bytes[i - 1]),
               i + 2 >= bytes.count || !PDFParser.isRegular(bytes[i + 2]) {
                return i + 2
            }
            i += 1
        }
        return bytes.count
    }

    // MARK: - 分析

    public struct Analysis: Sendable {
        public var operatorCounts: [String: Int] = [:]
        public var textShowingCount = 0
        public var inlineImageCount = 0
        public var textBlockCount = 0

        public init() {}

        public var topOperators: [(String, Int)] {
            operatorCounts.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
        }
    }

    public static func analyze(_ data: Data) -> Analysis {
        var a = Analysis()
        for token in tokenize(data) {
            guard token.kind == .op, let op = token.op else { continue }
            a.operatorCounts[op, default: 0] += 1
            if textShowingOperators.contains(op) { a.textShowingCount += 1 }
            if op == "BI" { a.inlineImageCount += 1 }
            if op == "BT" { a.textBlockCount += 1 }
        }
        return a
    }
}

// MARK: - 文本驱逐

public enum TextEvictor {
    public struct Result: Sendable {
        public var data: Data
        public var removedRuns: Int
        public var bytesRemoved: Int
        public var changed: Bool { removedRuns > 0 }
    }

    /// 删除所有文本显示算子及其操作数，其余字节原样保留。
    ///
    /// 保留的东西包括：`q Q cm gs re f S Do BI...EI BDC EMC Tr Tz TL Tc Tw Ts`……
    /// 也就是说图片、矢量、表格线、透明度、图案全部不动，因此「非文本区域
    /// 像素差 = 0」不是靠对齐做出来的，而是**结构上不可能变**。
    public static func evictText(from data: Data) -> Result {
        evictText(from: data, keeping: [])
    }

    /// 只删「不在 `keeping` 里」的文本显示算子。
    ///
    /// 这是保真度的关键：代码块、页码、符号、没有译文的段落，**原字节一个都不动**，
    /// 于是它们连字体都不会换——不是「对齐得好」，是根本没碰过。
    /// 早先整页驱逐再按原坐标重画，代码块会被 14pt 宋体替换，行宽全变、和缩进对不上。
    ///
    /// - Parameter keeping: 需要保留的算子字节区间（整页拼接口径，升序或乱序均可）
    public static func evictText(from data: Data, keeping ranges: [Range<Int>]) -> Result {
        let tokens = PDFContentStream.tokenize(data)
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)

        // 区间排序 + 二分式游标：每页几千个算子、几百个保留区间，线性扫也够快，
        // 但排序后可以用一个游标推进，避免 O(n·m)
        let keep = ranges.sorted { $0.lowerBound < $1.lowerBound }

        var cursor = 0      // 已复制到的位置
        var runStart = 0    // 当前操作数段的起点（上一个算子的结尾）
        var removedRuns = 0
        var removedBytes = 0
        var keepCursor = 0

        for token in tokens {
            guard token.kind == .op else { continue }
            let op = token.op ?? ""
            if PDFContentStream.textShowingOperators.contains(op) {
                while keepCursor < keep.count && keep[keepCursor].upperBound <= runStart {
                    keepCursor += 1
                }
                let overlapped = keepCursor < keep.count
                    && keep[keepCursor].lowerBound < token.end
                if overlapped {
                    // 这一段原样留下
                    runStart = token.end
                    continue
                }
                // 删掉「操作数段 + 算子」整段
                if runStart >= cursor {
                    out.append(contentsOf: bytes[cursor..<runStart])
                }
                removedBytes += token.end - runStart
                removedRuns += 1
                cursor = token.end
            }
            runStart = token.end
        }
        if cursor < bytes.count {
            out.append(contentsOf: bytes[cursor..<bytes.count])
        }
        return Result(data: Data(out), removedRuns: removedRuns, bytesRemoved: removedBytes)
    }

    /// 只删指定文本块的行内算子——留给 P3 的「按段落驱逐」用。
    /// 目前按整页驱逐，因为 P0/P1 还没有段落归属。
    public static func evictText(inRange range: Range<Int>, from data: Data) -> Result {
        let tokens = PDFContentStream.tokenize(data)
        let bytes = [UInt8](data)
        var out = [UInt8]()
        var cursor = 0
        var runStart = 0
        var removedRuns = 0
        var removedBytes = 0

        for token in tokens {
            guard token.kind == .op else { continue }
            let op = token.op ?? ""
            let inside = token.start >= range.lowerBound && token.end <= range.upperBound
            if inside && PDFContentStream.textShowingOperators.contains(op) {
                if runStart >= cursor { out.append(contentsOf: bytes[cursor..<runStart]) }
                removedBytes += token.end - runStart
                removedRuns += 1
                cursor = token.end
            }
            runStart = token.end
        }
        if cursor < bytes.count { out.append(contentsOf: bytes[cursor..<bytes.count]) }
        return Result(data: Data(out), removedRuns: removedRuns, bytesRemoved: removedBytes)
    }
}
