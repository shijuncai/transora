import Foundation

/// 「只有横线」的表格识别。
///
/// `PDFTableDetector` 要求**至少一条竖线**才肯认表：它的网格必须靠横竖线求交得到。
/// 但期刊里的数据表经常是「两条通栏横线 + 一堆对齐的小字」，一根竖线都不画
/// （真实样本 `Materials and Design` 的 Table 2 就是这样）。
///
/// 这种表不被认出来时后果很严重，而且不是「少翻一张表」这么简单：
///
/// 1. 每个单元格变成**独立段落块**，各自套用「段落」的重排规则（可压行距、可缩字、
///    可向右/向下扩框）。中式译文比英文长，这些 6.4 pt 的小格子于是全都溢出；
/// 2. 溢出块 ≥ 2 个就触发**整页重排**，正文被推进表格区域里乱流；
/// 3. 重排挤不下的段落被丢弃 —— 真实样本里直接吞掉了一整段（831 字）。
///
/// 所以这里补一条「横向带 + 列起点对齐」的推断路径：横线定上下边界，
/// 列的起点由**同一行里相邻 run 的间隙**推出来（左对齐列在所有行里起点一致），
/// 行边界由**基线**聚类得到（一格一行，上标并进所在行）。
///
/// 刻意保守：只在「小字、多列、无跨列长行」时才认，宁可漏判也不要把正文段落
/// 当成表格钉住（钉住的代价是那一段从此不翻译）。
public enum PDFRuledTable {

    public static func detect(
        segments: [PDFPathSegment],
        runs: [PDFTextRun],
        pageBox: PDFRect,
        options: PDFTableDetector.Options = PDFTableDetector.Options(),
        startOrdinal: Int = 0
    ) -> [ILTable] {
        let horizontals = segments
            .filter { $0.isHorizontal && $0.length >= 60 }
            .map { (y: ($0.start.y + $0.end.y) / 2,
                    x0: min($0.start.x, $0.end.x),
                    x1: max($0.start.x, $0.end.x)) }
        guard horizontals.count >= 2 else { return [] }
        let rules = merge(horizontals, tolerance: options.snap)

        // 候选带：任意两条横线之间。**先试高的**——一张表的上边界在表头之上、
        // 下边界在最后一行之下；先试矮的会把表头切在表格外面（表头就变回段落块）。
        var bands: [PDFRect] = []
        for upper in rules {
            for lower in rules where lower.y < upper.y {
                let gap = upper.y - lower.y
                guard gap >= 16, gap <= 420 else { continue }
                let x0 = max(upper.x0, lower.x0)
                let x1 = min(upper.x1, lower.x1)
                let overlap = x1 - x0
                let shorter = min(upper.x1 - upper.x0, lower.x1 - lower.x0)
                guard overlap >= 100, overlap >= shorter * 0.75 else { continue }
                let band = PDFRect(x0: x0, y0: lower.y, x1: x1, y1: upper.y)
                guard band.width * band.height
                    <= pageBox.width * pageBox.height * 0.6 else { continue }
                bands.append(band)
            }
        }

        var tables: [ILTable] = []
        for band in bands.sorted(by: { $0.height > $1.height }) {
            guard !tables.contains(where: { $0.box.intersects(band) }) else { continue }
            if let table = makeTable(band: band, runs: runs, options: options,
                                     ordinal: startOrdinal + tables.count) {
                tables.append(table)
            }
        }
        return tables.sorted { $0.box.y1 > $1.box.y1 }
    }

    // MARK: - 组装

    static func makeTable(
        band: PDFRect, runs: [PDFTextRun], options: PDFTableDetector.Options, ordinal: Int
    ) -> ILTable? {
        let inside = runs.filter { run in
            guard abs(run.angle) < 0.05 else { return false }
            guard run.fontSize <= 12, run.fontSize > 0.5 else { return false }
            let cx = (run.bbox.x0 + run.bbox.x1) / 2
            let cy = (run.bbox.y0 + run.bbox.y1) / 2
            return cx >= band.x0 - 1 && cx <= band.x1 + 1
                && cy >= band.y0 - 1 && cy <= band.y1 + 1
                && !run.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard inside.count >= 12 else { return nil }

        // 行：按基线聚类。容差取 0.5 个字高——上标（`CH2` 的 `2`、`g/cm3` 的 `3`）
        // 比正文基线高 2–3 pt，容差太小会把每个上标都当成单独一行，
        // 于是「列起点」的支持度被稀释，右侧几列会整列丢掉。
        var rowsOfRuns: [[PDFTextRun]] = []
        for run in inside.sorted(by: { $0.origin.y > $1.origin.y }) {
            if var last = rowsOfRuns.last, let anchor = last.first,
               abs(anchor.origin.y - run.origin.y)
                   <= max(2.0, 0.5 * max(anchor.fontSize, run.fontSize)) {
                last.append(run)
                rowsOfRuns[rowsOfRuns.count - 1] = last
            } else {
                rowsOfRuns.append([run])
            }
        }
        guard rowsOfRuns.count >= 5 else { return nil }

        // 上标/下标（`CH2` 的 2、`PO2` 的 2）有时落得比 0.5 个字高更远，会单独成行。
        // 这种「只有一个 1–2 字碎片」的行并回纵向最近的那一行，否则表格里会多出
        // 一行只有「2」的空行，行高也被切碎。
        rowsOfRuns = mergeFragmentRows(rowsOfRuns)

        // 列：同一行里「右侧 run 的起点」就是右侧列的列首。左对齐的列在所有行里
        // 起点一致，聚类后支持度足够高的才认。
        var starts: [Double] = []
        for row in rowsOfRuns {
            let ordered = row.sorted { $0.bbox.x0 < $1.bbox.x0 }
            for (left, right) in zip(ordered, ordered.dropFirst()) {
                // 5 pt：6.4 pt 字号下词间空格不到 2.5 pt，不会把一个格子拆成两列；
                // 而表格的列距至少 8 pt。
                guard right.bbox.x0 - left.bbox.x1 >= 5 else { continue }
                starts.append(right.bbox.x0)
            }
        }
        let needed = max(3, rowsOfRuns.count / 5)
        var bounds: [Double] = [band.x0]
        for cluster in support(starts, tolerance: 2.0) where cluster.count >= needed {
            if cluster.center - bounds.last! >= 8, band.x1 - cluster.center >= 8 {
                bounds.append(cluster.center)
            }
        }
        bounds.append(band.x1)
        guard bounds.count >= 4 else { return nil }   // 至少 3 列

        // 每列必须真的是「一列」：不能有 run 跨过列边界。
        // 正文段落夹在两条横线之间时，每一行都横贯整幅 —— 这一条能把它挡掉。
        var crossings = 0
        for row in rowsOfRuns {
            for run in row {
                for bound in bounds.dropFirst().dropLast()
                where run.bbox.x0 < bound - 1.5 && run.bbox.x1 > bound + 1.5 {
                    crossings += 1
                }
            }
        }
        guard Double(crossings) <= Double(inside.count) * 0.08 else { return nil }

        // 行边界：第一条基线上方取带顶，最后一条下方取带底，中间取相邻基线中点。
        let baselines = rowsOfRuns.map { row in row.map(\.origin.y).max() ?? 0 }
        var rowBounds: [Double] = [band.y1]
        for index in 1..<baselines.count {
            rowBounds.append((baselines[index - 1] + baselines[index]) / 2)
        }
        rowBounds.append(band.y0)

        var cells: [ILCell] = []
        var filled = 0
        var fillRatios: [Double] = []
        var sentences = 0
        for row in 0..<rowsOfRuns.count {
            for column in 0..<(bounds.count - 1) {
                let box = PDFRect(x0: bounds[column], y0: rowBounds[row + 1],
                                  x1: bounds[column + 1], y1: rowBounds[row])
                let text = PDFTableDetector.text(in: box, from: inside)
                if !text.isEmpty {
                    filled += 1
                    // 格子里文字的横向占位：数据表的格子填不满（数字只占两三成），
                    // 而正文的每一行几乎顶满栏宽 —— 这是「表格 vs 三栏文字」的分水岭。
                    let insideRuns = inside.filter { run in
                        let cx = (run.bbox.x0 + run.bbox.x1) / 2
                        let cy = (run.bbox.y0 + run.bbox.y1) / 2
                        return cx >= box.x0 && cx <= box.x1 && cy >= box.y0 && cy <= box.y1
                    }
                    if let x0 = insideRuns.map(\.bbox.x0).min(),
                       let x1 = insideRuns.map(\.bbox.x1).max(), box.width > 1 {
                        fillRatios.append((x1 - x0) / box.width)
                    }
                    if text.hasSuffix(".") { sentences += 1 }
                }
                cells.append(ILCell(row: row, column: column, rowSpan: 1, columnSpan: 1,
                                    box: box, text: text))
            }
        }

        // 整句的格子太多、或者格子里的字总是顶满格宽 —— 这是被横线夹住的正文。
        guard Double(sentences) <= Double(filled) * 0.2 else { return nil }
        let medianFill = fillRatios.sorted().dropFirst(fillRatios.count / 2).first ?? 0
        guard medianFill <= 0.85 else { return nil }

        let rowCount = rowsOfRuns.count
        let columnCount = bounds.count - 1
        guard rowCount >= options.minRows, columnCount >= options.minCols else { return nil }
        let fillRatio = Double(filled) / Double(rowCount * columnCount)
        guard fillRatio >= options.minCoverage else { return nil }
        // 至少六成的行有 3 个以上非空格子，才像「数据表」而不是「对齐的两三段文字」
        let denseRows = (0..<rowCount).filter { row in
            cells.filter { $0.row == row && !$0.text.isEmpty }.count >= 3
        }.count
        guard Double(denseRows) >= Double(rowCount) * 0.6 else { return nil }

        return ILTable(id: "r\(ordinal)", box: band, rowCount: rowCount,
                       columnCount: columnCount, cells: cells,
                       confidence: min(0.9, 0.5 + 0.4 * min(1, fillRatio * 1.4)))
    }

    // MARK: - 小工具

    /// 把「只有一个 1–2 字符碎片」的行并进纵向最近的行。
    static func mergeFragmentRows(_ rows: [[PDFTextRun]]) -> [[PDFTextRun]] {
        var out: [[PDFTextRun]] = []
        for row in rows {
            let text = row.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let isFragment = row.count == 1 && text.count <= 2
            guard isFragment, !out.isEmpty else { out.append(row); continue }
            guard let y = row.first?.origin.y else { out.append(row); continue }
            // 找纵向最近的已收行（行序已是从上到下）
            var bestIndex = out.count - 1
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, candidate) in out.enumerated() {
                guard let anchor = candidate.first?.origin.y else { continue }
                let distance = abs(anchor - y)
                if distance < bestDistance { bestDistance = distance; bestIndex = index }
            }
            guard bestDistance <= 8 else { out.append(row); continue }
            out[bestIndex].append(contentsOf: row)
        }
        return out
    }

    struct Cluster {
        var center: Double
        var count: Int
    }

    /// 把同一 y 上被切成几笔画出的横线并成一条。
    static func merge(
        _ rules: [(y: Double, x0: Double, x1: Double)], tolerance: Double
    ) -> [(y: Double, x0: Double, x1: Double)] {
        var out: [(y: Double, x0: Double, x1: Double)] = []
        for rule in rules.sorted(by: { $0.y < $1.y }) {
            if var last = out.last, abs(last.y - rule.y) <= tolerance,
               rule.x0 <= last.x1 + 3 {
                last.x1 = max(last.x1, rule.x1)
                last.x0 = min(last.x0, rule.x0)
                out[out.count - 1] = last
                continue
            }
            out.append(rule)
        }
        return out
    }

    static func support(_ values: [Double], tolerance: Double) -> [Cluster] {
        guard let first = values.min() else { return [] }
        var clusters: [Cluster] = [Cluster(center: first, count: 1)]
        var sum = first
        var count = 1
        for value in values.sorted().dropFirst() {
            if abs(sum / Double(count) - value) <= tolerance {
                sum += value
                count += 1
                clusters[clusters.count - 1] = Cluster(center: sum / Double(count), count: count)
            } else {
                clusters.append(Cluster(center: value, count: 1))
                sum = value
                count = 1
            }
        }
        return clusters
    }
}
