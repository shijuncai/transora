import Foundation

/// 中间语言（IL）：页面 → 块 → 行 → 片段。
///
/// 借鉴 agentic-doc 的**输出契约**（`type` / `box` / `confidence` / `parent_id` / `children`），
/// 但不接它的运行时（那是云端 API，与「全程离线」冲突）。
/// 这里借的是「下游怎么消费结构化文档」这件事——schema 稳定了，
/// 后续的排版、校验、导出都不必互相猜。
///
/// 坐标一律是 **PDF 页面空间**（左下原点、y 向上、单位 pt），不做任何 y 翻转。
/// 只有在导出给人看的 JSON 时，才额外给一个 `box_top_down`，
/// 因为绝大多数前端/视觉工具用左上原点。
public struct ILDocument: Sendable {
    public var pages: [ILPage] = []
    public var warnings: [String] = []
}

public struct ILPage: Sendable {
    public init(index: Int, width: Double, height: Double, rotation: Int = 0) {
        self.index = index
        self.width = width
        self.height = height
        self.rotation = rotation
    }

    public var index: Int
    public var width: Double
    public var height: Double
    public var rotation: Int
    public var blocks: [ILBlock] = []
    public var tables: [ILTable] = []
    public var figures: [ILFigure] = []
    /// 矢量图表区域（柱状图/折线图等）。区域内的文字一律保持原文，不翻译。
    public var charts: [ILChart] = []
    public var warnings: [String] = []
    /// 页面是否可翻译：拿不到 unicode 的页会被标记，避免输出「看起来很完整但全是乱码」的结果
    public var translatable: Bool = true
    public var unmappedGlyphs: Int = 0
    public var textRunCount: Int = 0
}

public struct ILSpan: Sendable {
    public init(text: String, fontName: String, fontSize: Double,
                isBold: Bool, isItalic: Bool, box: PDFRect, runIndex: Int = -1) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.box = box
        self.runIndex = runIndex
    }

    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    public var box: PDFRect
    /// 这个 span 来自哪个 `PDFTextRun`（-1 = 合成）
    public var runIndex: Int = -1
}

public struct ILLine: Sendable {
    public init(text: String, box: PDFRect, baseline: Double, fontSize: Double,
                spans: [ILSpan], angle: Double) {
        self.text = text
        self.box = box
        self.baseline = baseline
        self.fontSize = fontSize
        self.spans = spans
        self.angle = angle
    }

    public var text: String
    public var box: PDFRect
    public var baseline: Double
    public var fontSize: Double
    public var spans: [ILSpan]
    public var angle: Double

    public var x0: Double { box.x0 }
    public var x1: Double { box.x1 }
}

public struct ILBlock: Sendable {
    public enum Kind: String, Sendable {
        case paragraph
        case heading
        case caption
        case listItem = "list_item"
        case formula
    }

    public init(id: String, type: Kind, box: PDFRect, lines: [ILLine],
                fontSize: Double, text: String, confidence: Double, column: Int) {
        self.id = id
        self.type = type
        self.box = box
        self.lines = lines
        self.fontSize = fontSize
        self.text = text
        self.confidence = confidence
        self.column = column
    }

    public var id: String
    public var type: Kind
    public var box: PDFRect
    public var lines: [ILLine]
    public var fontSize: Double
    public var text: String
    /// 0…1。启发式的自评：低置信的块在 P4 会被优先人工复核
    public var confidence: Double
    public var column: Int

    public var lineCount: Int { lines.count }
}

public struct ILCell: Sendable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public var box: PDFRect
    public var text: String
}

public struct ILTable: Sendable {
    public init(id: String, box: PDFRect, rowCount: Int, columnCount: Int,
                cells: [ILCell], confidence: Double) {
        self.id = id
        self.box = box
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
        self.confidence = confidence
    }

    public var id: String
    public var box: PDFRect
    public var rowCount: Int
    public var columnCount: Int
    public var cells: [ILCell]
    public var confidence: Double
}

public struct ILFigure: Sendable {
    public var id: String
    public var box: PDFRect
    public var pixelWidth: Int
    public var pixelHeight: Int
}

// MARK: - 行归并

/// 把字形 run 合并成「行」，再把行合并成「块」。
///
/// 这一步的输入是几百个零散的 run（PDF 里一句话常被拆成 5–10 段，
/// 因为字体切换、字距微调、上标下标都会断开它），输出是能拿去翻译的段落。
/// 判据只有几何：基线、字号、行距、水平重叠。
public enum PDFLineBuilder {
    /// 中文/日文/韩文与全角标点：这些字符之间**不加空格**
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
             0x20000...0x2FA1F, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// 两段文本拼接时要不要补空格。
    /// PDF 里的词间空格经常是「位置跳开」而不是「真有个空格字符」，
    /// 不补就会出现 `PAXLOVIDthe` 这种粘连。
    public static func needsSpace(between left: String, and right: String) -> Bool {
        guard let l = left.unicodeScalars.last, let r = right.unicodeScalars.first else { return false }
        if l == " " || r == " " { return false }
        if isCJK(l) || isCJK(r) { return false }
        return true
    }

    /// 字体名里判断粗体。子集字体名形如 `ABCDEF+MicrosoftYaHei-Bold`，
    /// 去掉前缀后仍保留 `-Bold`，所以直接查子串即可。
    public static func looksBold(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("bold") || lower.contains("black")
            || lower.contains("heavy") || lower.contains("semibold")
    }

    public static func looksItalic(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("italic") || lower.contains("oblique")
    }

    public static func buildLines(from runs: [PDFTextRun]) -> [ILLine] {
        // 注意：**不能**把「取不到 unicode 的 run」过滤掉。
        // 它们没有文字，但**占版面宽度**（典型：Symbol 字体里的 `×`、上标的 `3`）。
        // 早期把它们丢掉，直接后果是同一行被撕成三块——
        // 「30 cm」/「× 30 cm ×」/「1 cm」各自成块、各自送去翻译，
        // 译文的语序就变成「尺寸为30厘米的样品 × 30厘米 × 放置了1厘米」。
        let usable = runs.filter { $0.advance > 0.01 }
        guard !usable.isEmpty else { return [] }

        // 先在 run 层按空白缝切成区域，再在区域内部建行。
        //
        // 顺序不能反：行建好之后，栏缝两侧的文字已经被并成一条「假行」，
        // 而分栏判据恰恰是「没有任何一行跨过这条缝」——假行把缝堵死，分栏必然失效。
        // 详见 `PDFRegionCutter` 的注释。
        var lines: [ILLine] = []
        let regions = PDFRegionCutter.regions(usable)
        for region in regions {
            let built = makeLines(from: region)
            // 碎片并回本行要**在区域内部**做：跨区域的并合正是「作者+标题」
            // 「地址+正文」黏在一起的直接原因（角标把缝挤到 12 pt，落在 1 em 判据内）。
            lines += mergeInlineFragments(built.sorted { $0.baseline > $1.baseline })
        }
        return lines.sorted { $0.baseline > $1.baseline }
    }

    /// 在一个「已经是单栏」的区域里把同一基线的 run 归并成行。
    static func makeLines(from runs: [PDFTextRun]) -> [ILLine] {
        // 先按「从上到下、从左到右」排序，再由近及远地归并
        let sorted = runs.sorted {
            if abs($0.origin.y - $1.origin.y) > 0.5 { return $0.origin.y > $1.origin.y }
            return $0.origin.x < $1.origin.x
        }

        var groups: [[PDFTextRun]] = []
        var baselines: [Double] = []

        for run in sorted {
            let tolerance = max(1.5, 0.32 * run.fontSize)
            var bestIndex: Int?
            var bestDelta = Double.infinity
            // 只回看最近几行：PDF 的 run 大致按内容顺序输出，全局搜索没必要
            for index in stride(from: groups.count - 1, through: max(0, groups.count - 6), by: -1) {
                let delta = abs(baselines[index] - run.origin.y)
                if delta <= tolerance && delta < bestDelta {
                    bestDelta = delta
                    bestIndex = index
                }
            }
            if let index = bestIndex {
                groups[index].append(run)
                // 基线取加权平均，避免个别上标把整行的基线拽歪
                let count = Double(groups[index].count)
                baselines[index] = (baselines[index] * (count - 1) + run.origin.y) / count
            } else {
                groups.append([run])
                baselines.append(run.origin.y)
            }
        }

        var lines: [ILLine] = []
        // 同一基线上的 run 不能无条件合并：表格里四个表头常常共用一个基线，
        // 合并后会变成「药品类类内药物对浓度的影临床评论」这样一条横贯整页的假行，
        // 后面的单元格归属就全错了。所以按水平间隙再切一刀。
        for group in groups {
            let ordered = group.sorted { $0.origin.x < $1.origin.x }
            var segment: [PDFTextRun] = []
            var segmentEnd = -Double.infinity

            func flushSegment() {
                defer { segment = [] }
                guard let line = makeLine(from: segment) else { return }
                lines.append(line)
            }

            for run in ordered {
                let gap = run.bbox.x0 - segmentEnd
                // 阈值取 1.6em 且不低于 12pt：正常词间距（含分散对齐）
                // 都在 1em 以内，而两栏之间的空隙通常 ≥ 1.5em。
                // 早期用 2.5em 会把「左栏末尾 + 右栏开头」并成一条假行。
                let threshold = max(1.6 * max(run.fontSize, segment.last?.fontSize ?? run.fontSize), 12)
                if !segment.isEmpty && gap > threshold {
                    flushSegment()
                }
                segment.append(run)
                segmentEnd = max(segmentEnd, run.bbox.x1)
            }
            flushSegment()
        }
        // 复原从上到下的顺序。碎片并回（`mergeInlineFragments`）由调用方按区域做。
        return lines.sorted { $0.baseline > $1.baseline }
    }

    /// 把「同一视觉行里被基线容差切开」的碎片并回一行。
    ///
    /// 上标（作者的 a/b、单位里的 ³）基线比正文高 4~6pt，`0.32em` 的容差必然把它
    /// 判成另一行。若不管，它们会变成独立块：原文留在原位、译文按新行重排，
    /// 于是「C. Prajith^a」的 a 跑到离名字很远的地方。
    /// 判据要求**竖直方向明显重叠**（上下标与正文重合度极高），
    /// 表格里并排的单元格（同一基线、只水平相邻）不满足，不会被误合。
    static func mergeInlineFragments(_ lines: [ILLine]) -> [ILLine] {
        var result = lines
        var index = 0
        while index < result.count {
            var merged = false
            var other = index + 1
            while other < result.count {
                let a = result[index], b = result[other]
                let fontSize = max(a.fontSize, b.fontSize)
                let baselineGap = abs(a.baseline - b.baseline)
                let overlap = a.box.verticalOverlap(b.box)   // 已经是「重叠 / 较小高度」
                let gap = max(a.box.x0, b.box.x0) - min(a.box.x1, b.box.x1)
                // 只合并**水平方向前后相邻**的碎片（上下标、断开的标记）。
                // 两个横向重叠的碎片说明要么是同一段的两行、要么是真交错，
                // 一律不合并——按 span 硬拼会把行内空格全部吃掉。
                let adjacent = gap <= 1.0 * fontSize && gap >= -1.0
                let stacked = overlap >= 0.3
                // 只有**碎片**（上标、角标、项目符号、断开的标点）才并回本行。
                // 两侧都是整句时一律不并：`PDFRegionCutter` 已经按栏缝切过区域，
                // 万一缝被极窄的栏距或角标糊住、两边仍在同一区域里，
                // 这条兜底也不会把「作者 + 标题」拼成一句。
                let fragment = Self.isShortFragment(a) || Self.isShortFragment(b)
                guard baselineGap <= 1.2 * fontSize, adjacent, stacked, fragment else {
                    other += 1
                    continue
                }
                // 用两行的 `text` 拼，**不要**用 spans 重拼：
                // `makeLine` 补的词间空格只存在于 `text` 里，不在任何 span 上，
                // 按 span 重拼会让「Department of Mechanical Engineering」变成
                // 「DepartmentofMechanicalEngineering」。
                let ordered = (a.spans + b.spans).sorted { $0.box.x0 < $1.box.x0 }
                let box = a.box.union(b.box)
                let dominant = a.fontSize >= b.fontSize ? a : b
                let left = a.box.x0 <= b.box.x0 ? a : b
                let right = a.box.x0 <= b.box.x0 ? b : a
                let sameLineGap = right.box.x0 - left.box.x1
                let needsSeparator = sameLineGap > 0.35 * fontSize
                    && PDFLineBuilder.needsSpace(between: left.text, and: right.text)
                let mergedText = (left.text + (needsSeparator ? " " : "") + right.text)
                    .trimmingCharacters(in: .whitespaces)
                let countA = Double(a.spans.count)
                let countB = Double(b.spans.count)
                let weight = max(1, countA + countB)
                let baseline: Double = (a.baseline * countA + b.baseline * countB) / weight
                result[index] = ILLine(
                    text: mergedText, box: box, baseline: baseline,
                    fontSize: dominant.fontSize, spans: ordered, angle: dominant.angle)
                result.remove(at: other)
                merged = true
                break
            }
            if !merged { index += 1 }
        }
        return result
    }

    /// 碎片行：去掉空白后不超过 4 个字符。
    ///
    /// 上标（`1`、`a`、`3`）、角标（`*`）、项目符号（`◦`）、被字体切换拆开的标点
    /// 都落在这个范围内；而「一行完整的正文」不会。
    static func isShortFragment(_ line: ILLine) -> Bool {
        line.text.filter { !$0.isWhitespace }.count <= 4
    }

    static func makeLine(from ordered: [PDFTextRun]) -> ILLine? {
        guard !ordered.isEmpty else { return nil }
        var text = ""
        var spans: [ILSpan] = []
        var box: PDFRect?
        var previousEndX: Double?

        for run in ordered {
            // 词间空格阈值：0.25em 是按 Times 的 space 宽度拍的，但很多期刊正文字体
            // 的 space 只有 0.19em（真实样本 GulliverRM 就是 1.51pt @ 8pt），
            // 用 0.25em 判会把整段粘成 `Inlookingattheperformance`，
            // 模型拿到没有词界的句子，译文就会出现「灯光wassetupat90和」这种夹生。
            // 0.15em（不少于 0.6pt）能分开正常的词距，又不会把同一单词内的
            // 字体切换（间距≈0）误判成两个词。
            let spaceThreshold = max(0.15 * run.fontSize, 0.6)
            if let previousEndX, run.bbox.x0 - previousEndX > spaceThreshold,
               needsSpace(between: text, and: run.text) {
                text += " "
            }
            text += run.text
            previousEndX = run.bbox.x1
            box = box.map { $0.union(run.bbox) } ?? run.bbox
            spans.append(ILSpan(
                text: run.text,
                fontName: run.fontName,
                fontSize: run.fontSize,
                isBold: looksBold(run.fontName),
                isItalic: looksItalic(run.fontName),
                box: run.bbox,
                runIndex: run.runIndex))
        }
        guard let box, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let dominant = ordered.max { $0.glyphCount < $1.glyphCount } ?? ordered[0]
        return ILLine(
            text: text.trimmingCharacters(in: .whitespaces),
            box: box,
            baseline: ordered.map(\.origin.y).reduce(0, +) / Double(ordered.count),
            fontSize: dominant.fontSize,
            spans: spans,
            angle: dominant.angle)
    }
}

// MARK: - 段落归并

public enum PDFParagraphBuilder {
    public struct Options: Sendable {
        /// 行距超过这个倍数（相对字号）就断段
        public var lineGapFactor = 1.75
        /// 首行缩进超过这个倍数（相对字号）算新段
        public var indentFactor = 1.2
        /// 字号差超过这么多 pt 就断段（标题 vs 正文）
        public var fontSizeTolerance = 1.5
        /// 判定「多栏」时，栏间最小空白（pt）
        public var columnGutter = 14.0

        public init() {}
    }

    public static func buildBlocks(
        lines: [ILLine], pageWidth: Double, options: Options = Options()
    ) -> [ILBlock] {
        guard !lines.isEmpty else { return [] }
        let columns = detectColumns(lines: lines, pageWidth: pageWidth, gutter: options.columnGutter)
        var blocks: [ILBlock] = []
        var index = 0

        for (columnIndex, columnLines) in columns.enumerated() {
            var current: [ILLine] = []
            var previous: ILLine?

            func flush() {
                guard !current.isEmpty else { return }
                let text = joinLines(current)
                let fontSize = dominantFontSize(current)
                let box = current.dropFirst().reduce(current[0].box) { $0.union($1.box) }
                let kind: ILBlock.Kind
                if current.count == 1 && fontSize > medianFontSize(lines) * 1.18 {
                    kind = .heading
                } else if isHeadingLike(current) {
                    kind = .heading
                } else {
                    kind = .paragraph
                }
                blocks.append(ILBlock(
                    id: "p\(columnIndex)-b\(index)", type: kind, box: box,
                    lines: current, fontSize: fontSize, text: text,
                    confidence: confidence(for: current, kind: kind),
                    column: columnIndex))
                index += 1
                current = []
            }

            for line in columnLines {
                if isFragmentLine(line), let previous, isAdjacent(line, to: previous) {
                    // 上标（`g/cm` + `3`）和项目符号（`◦`）这类碎片：
                    // 自己没有任何可翻译内容，却会把一句话劈成三段。
                    // 真实样本里「The mean density of the entire set … 0.340 g/cm3」
                    // 被切成「…The mean」「3」「density of the entire set…」三块分别翻译，
                    // 排版后就成了「前后有译文、中间空一段」的观感。
                    // 这里让碎片单独成块（后面按碎片钉住、原字节不动），
                    // 但**不打断**当前段落，让它继续接下一行。
                    blocks.append(ILBlock(
                        id: "p\(columnIndex)-b\(index)", type: .paragraph, box: line.box,
                        lines: [line], fontSize: line.fontSize, text: line.text,
                        confidence: 1, column: columnIndex))
                    index += 1
                    continue
                }
                if let previous {
                    if shouldBreak(previous: previous, current: line, options: options) {
                        flush()
                    }
                }
                current.append(line)
                previous = line
            }
            flush()
        }
        // 顺序不能按 `midY` 全局重排：双栏页面上左右两栏的行处在同一纵向区间，
        // 按 y 排会变成「左一行、右一行」交错，译文顺序随之全乱。
        // `detectColumns` 返回的组序**本身**就是阅读顺序，保持即可。
        return mergeInterleaved(blocks)
    }

    /// 合并「行区间交错」的块。
    ///
    /// 缩进/字号启发式偶尔会把一段拆成两块，行序变成 495 → 479 → 464：
    /// 一个块的框跨过了另一个块的行。这种结构直接交给排版必然叠字——
    /// 排第一个块时会把它的几行铺满整个框，正好压住中间那个块。
    ///
    /// 判据很克制：**A 有行在 B 之上、也有行在 B 之下**，且横向重叠。
    /// 左右并排的两栏不满足（它们的行处在同一纵向区间），所以不会被误合。
    public static func mergeInterleaved(_ blocks: [ILBlock]) -> [ILBlock] {
        var result = blocks
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j != i {
                    let a = result[i]
                    let b = result[j]
                    // 纯碎片块（上标数字、项目符号）不参与合块：
                    // 它们被故意留在段落之外，合并回来又会让段落含上标、排版时丢字。
                    guard !isFragmentBlock(a), !isFragmentBlock(b) else { continue }
                    guard min(a.box.x1, b.box.x1) - max(a.box.x0, b.box.x0) > 0 else { continue }
                    let above = a.lines.contains { $0.baseline > b.box.y1 + 0.5 }
                    let below = a.lines.contains { $0.baseline < b.box.y0 - 0.5 }
                    guard above, below else { continue }

                    let lines = (a.lines + b.lines).sorted { $0.baseline > $1.baseline }
                    guard let first = lines.first else { continue }
                    let box = lines.dropFirst().reduce(first.box) { $0.union($1.box) }
                    result[i] = ILBlock(
                        id: a.id, type: a.type, box: box, lines: lines,
                        fontSize: a.fontSize, text: joinLines(lines),
                        confidence: min(a.confidence, b.confidence), column: a.column)
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }

    /// 碎片行：自己不含实义字符，只是上标数字或项目符号。
    ///
    /// 判据比 `PDFTypesetEngine.isPinned` 更严一点：这里要决定「是否让它打断段落」，
    /// 误判的代价是把一个真段落黏在一起，所以只认 1–2 个字符、且没有字母的行。
    public static func isFragmentLine(_ line: ILLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2 else { return false }
        guard !text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
        else { return false }
        let digitsOnly = text.unicodeScalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0) || $0 == "." || $0 == ","
        }
        // 纯数字碎片只在上标字号下才认：正文里 8pt 的「3」很可能是列表序号，
        // 把它当碎片会白白挡住段落之间的断句。
        if digitsOnly { return line.fontSize < 7.4 }
        return true
    }

    /// 碎片是否「夹在这一行里」：纵向紧邻且横向落在前一行范围内。
    /// 页脚页码、表头编号离正文远，不会命中。
    static func isAdjacent(_ line: ILLine, to previous: ILLine) -> Bool {
        let fontSize = max(previous.fontSize, line.fontSize)
        guard fontSize > 0 else { return false }
        let centerGap = abs(line.box.midY - previous.box.midY)
        guard centerGap <= 1.4 * fontSize else { return false }
        let overlap = min(line.box.x1, previous.box.x1) - max(line.box.x0, previous.box.x0)
        return overlap > 0
    }

    static func isFragmentBlock(_ block: ILBlock) -> Bool {
        block.lines.count == 1 && isFragmentLine(block.lines[0])
    }

    static func shouldBreak(previous: ILLine, current: ILLine, options: Options) -> Bool {
        let fontSize = max(previous.fontSize, current.fontSize)
        guard fontSize > 0 else { return true }

        // 1. 行距过大 → 断
        let gap = previous.box.y0 - current.box.y1
        if gap > options.lineGapFactor * fontSize { return true }
        if gap < -fontSize { return true }   // 重叠过多，说明不是同一栏

        // 2. 字号突变 → 断（标题/图注）
        if abs(previous.fontSize - current.fontSize) > options.fontSizeTolerance { return true }

        // 3. 首行缩进 → 断
        if current.x0 - previous.x0 > options.indentFactor * fontSize { return true }
        if previous.x0 - current.x0 > 2.0 * fontSize { return true }

        // 4. 字体突变（正文里出现粗体强调不算断段，但整行换字体通常意味着换元素）
        if let prevSpan = previous.spans.last, let currSpan = current.spans.first,
           prevSpan.fontName != currSpan.fontName,
           prevSpan.isBold != currSpan.isBold {
            return true
        }

        // 5. 水平方向几乎不重叠 → 不是同一段
        if previous.box.verticalOverlap(current.box) == 0 && previous.box.x1 < current.box.x0 {
            return true
        }

        // 6. 上一行明显短（结尾）且当前行是满行 → 可能是新段（软判据，只在差距很大时触发）
        let width = max(previous.box.width, current.box.width)
        if width > 0, previous.box.width < width * 0.55, current.box.width > width * 0.9 {
            return true
        }
        // 7. 当前行的**行首**是一个比本行正文更小的上标（单位行的 a/b、脚注标记）
        //    ⇒ 每行各自是一条独立条目，不能并成一段。
        //    不这么做，作者单位的两行会被当成一段重排成「…机械工程系 印度…研究中心」，
        //    第二行只剩一个「心」字。
        if let first = current.spans.first, first.fontSize < current.fontSize * 0.8 {
            return true
        }
        return false
    }

    static func joinLines(_ lines: [ILLine]) -> String {
        var out = ""
        for line in lines {
            if out.isEmpty {
                out = line.text
                continue
            }
            // 中文换行不需要空格；西文需要一个
            if PDFLineBuilder.needsSpace(between: out, and: line.text) {
                out += " "
            }
            out += line.text
        }
        return out
    }

    static func dominantFontSize(_ lines: [ILLine]) -> Double {
        var weight: [Double: Int] = [:]
        for line in lines {
            let key = (line.fontSize * 10).rounded() / 10
            weight[key, default: 0] += line.text.count
        }
        return weight.max { $0.value < $1.value }?.key ?? lines.first?.fontSize ?? 0
    }

    static func medianFontSize(_ lines: [ILLine]) -> Double {
        guard !lines.isEmpty else { return 0 }
        let values = lines.map(\.fontSize).sorted()
        return values[values.count / 2]
    }

    static func isHeadingLike(_ lines: [ILLine]) -> Bool {
        guard lines.count <= 2 else { return false }
        let text = lines.map(\.text).joined()
        if text.count > 40 { return false }
        // 标题常以编号或「第 X 章」开头
        if text.range(of: #"^(\d+(\.\d+)*|第[一二三四五六七八九十百]+[章节篇部]|Chapter\s+\d+|Section\s+\d+)"#,
                      options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func confidence(for lines: [ILLine], kind: ILBlock.Kind) -> Double {
        var value = 1.0
        if lines.count == 1 { value -= 0.1 }
        if kind == .heading { value -= 0.05 }
        let sizes = Set(lines.map { ($0.fontSize * 10).rounded() })
        if sizes.count > 1 { value -= 0.05 }
        return max(0.3, value)
    }

    /// 栏检测 + 阅读顺序：递归 XY 切分。
    ///
    /// 旧的「按行首 x 聚类」在这种版面（期刊首页）上会整页塌成单栏：
    /// 页眉、标题、作者、ARTICLE INFO、摘要、双栏正文的行首各不相同，
    /// 能聚出五六个簇，只有两三个凑够 3 行，其余簇过不了「纵向明显并排」的门禁，
    /// 于是 `return singleColumn`。判成单栏之后 `shouldBreak` 只能靠行距猜断段，
    /// 双栏文字按 y 交错排列 ⇒ **段落被切成一行一块**，译文顺序全乱、
    /// 还会和没被驱逐干净的原文叠在一起。
    ///
    /// XY 切分不去猜「栏起点」，而是找**没有任何一行跨过的竖缝**：
    /// 找到就切开、两侧各自递归；竖缝找不到（有横跨整幅的行）再找
    /// **没有任何一行占据的横向空白**。切不动的那一片就是叶子（= 一栏 / 一个独立区域）。
    /// 叶子按递归顺序输出，天然等于阅读顺序。
    ///
    /// 竖缝优先：双栏正文里常有「横跨两栏的章节分隔」，若先按水平空白切，
    /// 左栏会被切成上下两半，阅读顺序变成「左上、右上、左下、右下」。
    public static func detectColumns(
        lines: [ILLine], pageWidth: Double, gutter: Double
    ) -> [[ILLine]] {
        guard !lines.isEmpty else { return [] }
        _ = pageWidth
        var leaves: [[ILLine]] = []
        splitByWhitespace(lines.sorted { $0.baseline > $1.baseline },
                          gutter: gutter, depth: 0, into: &leaves)
        return leaves.filter { !$0.isEmpty }
    }

    static func splitByWhitespace(
        _ group: [ILLine], gutter: Double, depth: Int, into leaves: inout [[ILLine]]
    ) {
        if group.count <= 1 || depth >= 16 {
            leaves.append(group)
            return
        }
        if let (above, left, right, below) = verticalSplit(group, gutter: gutter) {
            splitByWhitespace(above, gutter: gutter, depth: depth + 1, into: &leaves)
            splitByWhitespace(left, gutter: gutter, depth: depth + 1, into: &leaves)
            splitByWhitespace(right, gutter: gutter, depth: depth + 1, into: &leaves)
            splitByWhitespace(below, gutter: gutter, depth: depth + 1, into: &leaves)
            return
        }
        if let (top, bottom) = horizontalSplit(group) {
            splitByWhitespace(top, gutter: gutter, depth: depth + 1, into: &leaves)
            splitByWhitespace(bottom, gutter: gutter, depth: depth + 1, into: &leaves)
            return
        }
        leaves.append(group)
    }

    /// 最宽的一条竖缝。要求两侧各至少 2 行、且纵向明显「并排」（重叠 ≥ 一半）。
    /// 后一条是防止把「页眉一行 + 正文若干行」当成两栏。
    ///
    /// 横跨栏缝的零散行（页码、页眉、通栏标题）**不参与构图**：
    /// 只要它们全都落在两栏的上方或下方，就单独成组按上下顺序输出。
    /// 不做这个例外的话，一个居中的页码就能让整页的双栏识别全部失败——
    /// 这正是本项目 409 页样书上「段落被切成一行一块」的直接原因。
    static func verticalSplit(
        _ group: [ILLine], gutter: Double
    ) -> ([ILLine], [ILLine], [ILLine], [ILLine])? {
        let intervals = group.map { ($0.box.x0, $0.box.x1) }.sorted { $0.0 < $1.0 }
        // 用「覆盖率」找竖缝，而不是「区间并集的空档」：
        // 页码、页眉这类**只有一行**横跨栏缝的情况，会把并集直接连成一片，
        // 于是整页再也找不到缝。覆盖率 ≤ 1 的 x 区间照样是缝，
        // 只是那边那一行要当成 stray 单独安置。
        var points: [Double] = []
        for (x0, x1) in intervals {
            points.append(x0)
            points.append(x1)
        }
        let xs = Set(points).sorted()
        guard xs.count >= 2 else { return nil }
        var gaps: [(start: Double, end: Double)] = []
        var runStart: Double?
        for i in 0..<(xs.count - 1) {
            let mid = (xs[i] + xs[i + 1]) / 2
            var coverage = 0
            for (x0, x1) in intervals where x0 <= mid && mid <= x1 { coverage += 1 }
            if coverage <= 1 {
                if runStart == nil { runStart = xs[i] }
            } else if let start = runStart {
                gaps.append((start, xs[i]))
                runStart = nil
            }
        }
        if let start = runStart { gaps.append((start, xs[xs.count - 1])) }
        let minWidth = max(6, gutter * 0.4)
        gaps = gaps.filter { $0.end - $0.start >= minWidth }
        guard !gaps.isEmpty else { return nil }
        for gap in gaps.sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
            let cut = (gap.start + gap.end) / 2
            let left = group.filter { $0.box.x1 <= cut + 0.01 }
            let right = group.filter { $0.box.x0 >= cut - 0.01 }
            let straddling = group.filter { $0.box.x0 < cut - 0.01 && $0.box.x1 > cut + 0.01 }
            guard left.count >= 2, right.count >= 2,
                  left.count + right.count + straddling.count == group.count else { continue }
            let la = (left.map(\.box.y0).min() ?? 0, left.map(\.box.y1).max() ?? 0)
            let ra = (right.map(\.box.y0).min() ?? 0, right.map(\.box.y1).max() ?? 0)
            let overlap = min(la.1, ra.1) - max(la.0, ra.0)
            let span = min(la.1 - la.0, ra.1 - ra.0)
            guard span > 0, overlap / span >= 0.5 else { continue }

            let bandTop = max(la.1, ra.1)
            let bandBottom = min(la.0, ra.0)
            let above = straddling.filter { $0.box.midY >= bandTop - 1 }
            let below = straddling.filter { $0.box.midY <= bandBottom + 1 }
            // 夹在两栏中间的通栏行没有明确的归属栏，放弃这次切分交给水平切分处理
            guard above.count + below.count == straddling.count else { continue }
            func ordered(_ lines: [ILLine]) -> [ILLine] { lines.sorted { $0.baseline > $1.baseline } }
            return (ordered(above), ordered(left), ordered(right), ordered(below))
        }
        return nil
    }

    /// 最宽的一条横向空白带，门槛与「行距中位数」挂钩：段落之间的空行要能切开，
    /// 正文的行间距切不开。
    ///
    /// 同样用**覆盖率**判定：只接受「整幅宽度上都没有行」的带子。
    /// 若按「相邻两行的间距」去切，双栏页面上左栏的段落空档会正好切在右栏的句子中间，
    /// 阅读顺序随之变成左右交错。
    static func horizontalSplit(_ group: [ILLine]) -> ([ILLine], [ILLine])? {
        guard group.count >= 4 else { return nil }
        let ordered = group.sorted { $0.box.midY > $1.box.midY }
        var points: [Double] = []
        for line in ordered {
            points.append(line.box.y0)
            points.append(line.box.y1)
        }
        let ys = Set(points).sorted()
        guard ys.count >= 2 else { return nil }
        var leadings: [Double] = []
        for i in 0..<(ordered.count - 1) {
            leadings.append(ordered[i].box.y0 - ordered[i + 1].box.y1)
        }
        let median = leadings.sorted()[leadings.count / 2]
        let threshold = max(12, median * 2.2)

        var bands: [(start: Double, end: Double)] = []
        var runStart: Double?
        for i in 0..<(ys.count - 1) {
            let mid = (ys[i] + ys[i + 1]) / 2
            var covered = false
            for line in ordered where line.box.y0 <= mid && mid <= line.box.y1 {
                covered = true
                break
            }
            if !covered {
                if runStart == nil { runStart = ys[i] }
            } else if let start = runStart {
                bands.append((start, ys[i]))
                runStart = nil
            }
        }
        if let start = runStart { bands.append((start, ys[ys.count - 1])) }
        guard let band = bands.filter({ $0.end - $0.start >= threshold })
            .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
        else { return nil }
        let cut = (band.start + band.end) / 2
        let top = ordered.filter { $0.box.midY > cut }
        let bottom = ordered.filter { $0.box.midY <= cut }
        guard top.count >= 1, bottom.count >= 1,
              top.count + bottom.count == ordered.count else { return nil }
        return (top, bottom)
    }
}
