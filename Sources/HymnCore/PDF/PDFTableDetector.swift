import Foundation

/// 表格检测：只用矢量线段，不依赖任何视觉模型。
///
/// 为什么必须自研：`VNRecognizeTextRequest` 只给「行/词」的文本框，**不给表格结构**。
/// 云端方案能给，但与本项目「全程离线」冲突。所以表格只能从 PDF 自己的绘制指令里恢复：
/// 表格边框在 PDF 里就是一组水平/垂直线段（Word 导出常常是细长填充矩形）。
///
/// 算法（五步，全部可解释）：
/// 1. **吸附**：坐标抖动 1–2pt 很常见，先按容差把线段聚类成「规则线」；
/// 2. **归一**：水平线按 y 聚类、垂直线按 x 聚类，重叠区间合并；
/// 3. **求交**：线段相交才构成网格；只保留至少有两个交点的线（排除下划线、装饰线）；
/// 4. **连通**：交图里连通的线属于同一张表；
/// 5. **验格**：统计每个格子有多少条边，覆盖率太低就否掉——否则一个装饰性方框
///    会被当成 1×1 表格，这是这类算法最典型的误报。
public enum PDFTableDetector {
    public struct Options: Sendable {
        /// 坐标吸附容差（pt）
        public var snap = 2.0
        /// 最少行/列数（1×1 只是方框，不是表格）
        public var minRows = 2
        public var minCols = 2
        /// 有文字的格子占比低于该值就否决（纯色块、装饰框的典型特征是整片空白）
        public var minCoverage = 0.15
        /// 表格面积不能超过页面的这个比例（否则多半是页面边框）
        public var maxPageAreaRatio = 0.92

        public init() {}
    }

    struct Rule {
        var isHorizontal: Bool
        /// 水平线是 y，垂直线是 x
        var position: Double
        var start: Double
        var end: Double
        var intersections = 0

        var length: Double { end - start }
    }

    /// - Parameter runs: 单元格文字按**字形 run** 归属，而不是按合并后的行。
    ///   原因很实际：相邻两列的文本在 PDF 里可能是紧挨着的（列边界就是文字起点），
    ///   按「行」归属会把右边一列的字并进左边一格。
    public static func detect(
        segments: [PDFPathSegment],
        runs: [PDFTextRun],
        lines: [ILLine],
        pageBox: PDFRect,
        options: Options = Options()
    ) -> [ILTable] {
        let horizontals = segments.filter { $0.isHorizontal && $0.length >= 6 }
            .map { Rule(isHorizontal: true, position: ($0.start.y + $0.end.y) / 2,
                        start: min($0.start.x, $0.end.x), end: max($0.start.x, $0.end.x)) }
        let verticals = segments.filter { $0.isVertical && $0.length >= 6 }
            .map { Rule(isHorizontal: false, position: ($0.start.x + $0.end.x) / 2,
                        start: min($0.start.y, $0.end.y), end: max($0.start.y, $0.end.y)) }
        // 门槛放到「各至少 1 条」：无外框的表格常常只有 1 条内横线 + 若干竖线，
        // 行数由第一列文字补足（见 inferRows）。行/列下限在 makeTable 里再卡。
        guard !horizontals.isEmpty, !verticals.isEmpty else { return [] }

        let hs = cluster(horizontals, tolerance: options.snap)
        let vs = cluster(verticals, tolerance: options.snap)

        // 求交
        var hRules = hs
        var vRules = vs
        var adjacency: [Int: Set<Int>] = [:]   // 0..<h.count 是水平，h.count... 是垂直
        for (hi, h) in hRules.enumerated() {
            for (vi, v) in vRules.enumerated() {
                if v.position >= h.start - options.snap && v.position <= h.end + options.snap
                    && h.position >= v.start - options.snap && h.position <= v.end + options.snap {
                    hRules[hi].intersections += 1
                    vRules[vi].intersections += 1
                    let vIndex = hRules.count + vi
                    adjacency[hi, default: []].insert(vIndex)
                    adjacency[vIndex, default: []].insert(hi)
                }
            }
        }

        // 连通分量
        var visited = Set<Int>()
        var tables: [ILTable] = []
        let totalNodes = hRules.count + vRules.count

        for start in 0..<totalNodes where !visited.contains(start) {
            var component: [Int] = []
            var stack = [start]
            while let node = stack.popLast() {
                guard visited.insert(node).inserted else { continue }
                component.append(node)
                for neighbour in adjacency[node] ?? [] where !visited.contains(neighbour) {
                    stack.append(neighbour)
                }
            }
            let hIndices = component.filter { $0 < hRules.count }
            let vIndices = component.filter { $0 >= hRules.count }.map { $0 - hRules.count }
            // 只需 1 条横线 + 1 条竖线就有资格成为候选：
            // 列边界可以由横线的起止端点补出来，行边界可以由首列文字推出来
            guard !hIndices.isEmpty, !vIndices.isEmpty else { continue }

            if let table = makeTable(hIndices: hIndices, vIndices: vIndices,
                                     hRules: hRules, vRules: vRules,
                                     lines: lines, runs: runs,
                                     pageBox: pageBox, options: options,
                                     ordinal: tables.count) {
                tables.append(table)
            }
        }
        return tables.sorted { $0.box.y1 > $1.box.y1 }
    }

    /// 按位置聚类，并且**只在区间真的相邻时才合并**。
    ///
    /// 只按位置合并会把「同一 x、中间断开的竖线」（比如表格的竖线 + 页脚的一条竖线）
    /// 并成一条跨越整页的线，于是整页被认定成一张表，行边界全乱。
    static func cluster(_ rules: [Rule], tolerance: Double) -> [Rule] {
        guard !rules.isEmpty else { return [] }
        let sorted = rules.sorted { $0.position < $1.position }
        var byPosition: [[Rule]] = []

        for rule in sorted {
            if let last = byPosition.last, let first = last.first,
               abs(first.position - rule.position) <= tolerance {
                byPosition[byPosition.count - 1].append(rule)
            } else {
                byPosition.append([rule])
            }
        }

        var out: [Rule] = []
        for group in byPosition {
            let ordered = group.sorted { $0.start < $1.start }
            var current = ordered[0]
            for rule in ordered.dropFirst() {
                // 区间相邻（间隙 ≤ 2pt）才并成一条
                if rule.start <= current.end + tolerance * 2 {
                    current.end = max(current.end, rule.end)
                    current.start = min(current.start, rule.start)
                } else {
                    out.append(current)
                    current = rule
                }
            }
            out.append(current)
        }
        return out
    }

    static func makeTable(
        hIndices: [Int], vIndices: [Int],
        hRules: [Rule], vRules: [Rule],
        lines: [ILLine], runs: [PDFTextRun],
        pageBox: PDFRect, options: Options, ordinal: Int
    ) -> ILTable? {
        // 筛掉「不贯穿表格」的杂线（下划线、装饰线）。
        // 判据用**跨度占比**而不是交点个数：稀疏表格（只有 1 条内横线）里
        // 每根竖线也只有 1 个交点，按交点筛会把整张表筛没。
        let rawH = hIndices.map { hRules[$0] }
        let rawV = vIndices.map { vRules[$0] }
        guard !rawH.isEmpty, !rawV.isEmpty else { return nil }

        let spanX = (rawH.map(\.end).max() ?? 0) - (rawH.map(\.start).min() ?? 0)
        let spanY = (rawV.map(\.end).max() ?? 0) - (rawV.map(\.start).min() ?? 0)
        let hs = rawH.filter { spanX <= 0 || $0.length >= spanX * 0.4 }
        let vs = rawV.filter { spanY <= 0 || $0.length >= spanY * 0.4 }
        guard !hs.isEmpty, !vs.isEmpty else { return nil }

        // 表格的水平范围由**横线**决定，垂直范围由**竖线**决定。
        // 这一步不能省：很多表格只画内部竖线（外框靠底色块或根本不画），
        // 只用竖线的 x 定范围会把最左边一列整列切掉——
        // 表现是「表格识别出来了，但左边一列的文字漏进了正文」。
        let xMin = hs.map(\.start).min() ?? pageBox.x0
        let xMax = hs.map(\.end).max() ?? pageBox.x1
        let yMin = vs.map(\.start).min() ?? pageBox.y0
        let yMax = vs.map(\.end).max() ?? pageBox.y1

        let xs = dedupe(([xMin] + vs.map(\.position) + [xMax]).sorted(), tolerance: options.snap)
        // 行边界从下往上排（PDF 的 y 向上），所以这里降序
        let ruleYs = dedupe(([yMax] + hs.map(\.position) + [yMin]).sorted(by: >),
                            tolerance: options.snap)
        guard xs.count >= 2, ruleYs.count >= 2 else { return nil }

        let box = PDFRect(x0: xs.first!, y0: ruleYs.last!, x1: xs.last!, y1: ruleYs.first!)
        guard box.area > 0, box.area < pageBox.area * options.maxPageAreaRatio else { return nil }

        // 区域内的文字行
        let innerLines = lines.filter { line in
            let cx = (line.box.x0 + line.box.x1) / 2
            let cy = (line.box.y0 + line.box.y1) / 2
            return cx >= box.x0 - 2 && cx <= box.x1 + 2 && cy >= box.y0 - 2 && cy <= box.y1 + 2
        }
        guard !innerLines.isEmpty else { return nil }

        // 行边界：横线够多就用横线；否则用**第一列的文字行**推。
        // 「靠首列文字定行」是必要的：大量表格只有外框和竖线，
        // 行与行之间没有任何横线，只靠横线会得到 1 行 4 列这种荒唐结果。
        let rowBounds: [Double]
        if ruleYs.count - 1 >= 3 {
            rowBounds = ruleYs
        } else if let inferred = inferRows(lines: innerLines, region: box, xs: xs,
                                           snap: options.snap), inferred.count >= 2 {
            rowBounds = inferred
        } else {
            rowBounds = ruleYs
        }

        let rowCount = rowBounds.count - 1
        let columnCount = xs.count - 1
        guard rowCount >= options.minRows, columnCount >= options.minCols else { return nil }

        var cells: [ILCell] = []
        var filled = 0
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let cellBox = PDFRect(x0: xs[column], y0: rowBounds[row + 1],
                                      x1: xs[column + 1], y1: rowBounds[row])
                let text = text(in: cellBox, from: runs, lines: innerLines)
                if !text.isEmpty { filled += 1 }
                cells.append(ILCell(row: row, column: column, rowSpan: 1, columnSpan: 1,
                                    box: cellBox, text: text))
            }
        }
        guard filled > 0 else { return nil }
        let fillRatio = Double(filled) / Double(rowCount * columnCount)
        guard fillRatio >= options.minCoverage else { return nil }

        var confidence = 0.45 + 0.35 * min(1.0, fillRatio * 1.6)
        if rowCount >= 3 && columnCount >= 2 { confidence += 0.1 }
        if ruleYs.count - 1 == rowCount { confidence += 0.05 }   // 行边界来自真实横线，最可信
        return ILTable(
            id: "t\(ordinal)", box: box,
            rowCount: rowCount, columnCount: columnCount,
            cells: cells, confidence: min(0.99, confidence))
    }

    /// 用第一列的文字行推断行边界。
    ///
    /// 判据：第一列的每一行文字开启一个新表格行；行边界取相邻两行文字的
    /// 垂直中线。这样即使单元格里的文字换行了（多行内容），也不会被拆成多行表格。
    static func inferRows(
        lines: [ILLine], region: PDFRect, xs: [Double], snap: Double
    ) -> [Double]? {
        guard xs.count >= 2 else { return nil }
        let firstColumnLeft = xs[0]
        let firstColumnRight = xs[1]
        let anchors = lines.filter { line in
            let cx = (line.box.x0 + line.box.x1) / 2
            return cx >= firstColumnLeft - snap && cx < firstColumnRight + snap
        }.sorted { $0.baseline > $1.baseline }
        guard anchors.count >= 2 else { return nil }

        var bounds: [Double] = [region.y1]
        for index in 1..<anchors.count {
            let prev = anchors[index - 1]
            let current = anchors[index]
            let gap = prev.box.y0 - current.box.y1
            // 只在「换行」处切分：间隔太小说明是同一格里的折行
            if gap > -0.5 {
                bounds.append((prev.box.y0 + current.box.y1) / 2)
            }
        }
        bounds.append(region.y0)
        // 去掉过窄的行（< 4pt），它们多半是误切
        var cleaned: [Double] = [bounds[0]]
        for bound in bounds.dropFirst() {
            if cleaned.last! - bound >= 4 { cleaned.append(bound) }
        }
        if cleaned.last! > region.y0 + 4 { cleaned.append(region.y0) }
        return cleaned.count >= 3 ? cleaned : nil
    }

    /// 按行归属（run 缺失时的回落路径）。
    static func text(in box: PDFRect, from lines: [ILLine]) -> String {
        let inside = lines.filter { line in
            let cx = (line.box.x0 + line.box.x1) / 2
            let cy = (line.box.y0 + line.box.y1) / 2
            return cx >= box.x0 - 0.5 && cx <= box.x1 + 0.5
                && cy >= box.y0 - 0.5 && cy <= box.y1 + 0.5
        }.sorted { $0.baseline > $1.baseline }
        var out = ""
        for line in inside {
            if !out.isEmpty, PDFLineBuilder.needsSpace(between: out, and: line.text) { out += " " }
            out += line.text
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func dedupe(_ values: [Double], tolerance: Double) -> [Double] {
        var out: [Double] = []
        for value in values {
            if let last = out.last, abs(last - value) <= tolerance { continue }
            out.append(value)
        }
        return out
    }

    /// 单元格文字：按 run 归属，再在格内重新拼行。
    /// 这样既不会把邻列的字吸进来，也能保留格内折行的阅读顺序。
    ///
    /// 没有 run 时退回按行归属（测试与外部调用常常只有行）。
    static func text(in box: PDFRect, from runs: [PDFTextRun], lines: [ILLine] = []) -> String {
        if runs.isEmpty {
            return text(in: box, from: lines)
        }
        let inside = runs.filter { run in
            let cx = (run.bbox.x0 + run.bbox.x1) / 2
            let cy = (run.bbox.y0 + run.bbox.y1) / 2
            return cx >= box.x0 - 0.5 && cx <= box.x1 + 0.5
                && cy >= box.y0 - 0.5 && cy <= box.y1 + 0.5
                && !run.text.trimmingCharacters(in: .whitespaces).isEmpty
        }.sorted {
            if abs($0.origin.y - $1.origin.y) > 0.5 { return $0.origin.y > $1.origin.y }
            return $0.origin.x < $1.origin.x
        }
        guard !inside.isEmpty else { return "" }

        var out = ""
        var previous: PDFTextRun?
        for run in inside {
            if let previous {
                let sameLine = abs(previous.origin.y - run.origin.y) <= 0.5 * run.fontSize
                if !sameLine {
                    // 格内折行：中文不补空格，否则译文里会出现「对浓度的影 响」这种空档
                    if PDFLineBuilder.needsSpace(between: out, and: run.text) { out += " " }
                } else if run.bbox.x0 - previous.bbox.x1 > 0.25 * run.fontSize,
                          PDFLineBuilder.needsSpace(between: out, and: run.text) {
                    out += " "
                }
            }
            out += run.text
            previous = run
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
