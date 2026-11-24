import Foundation

/// 把一页的文本 run 先按「空白缝」切成独立区域，再在区域内建行。
///
/// 为什么必须在 run 层切，而不是等行建好再分栏：
///
/// 1. **栏缝可能只有一个字距宽**。真实样本（GulliverRM 10 pt 双栏正文）栏间只有
///    14 pt ≈ 1.4 em，而行内空格的判定阈值必须放到 1.6 em 才不至于把正常词距切断，
///    于是「左栏末尾 + 右栏开头」被并成一条假行。
/// 2. **角标会让缝更窄**。作者行末尾的上标 `1` 正好落在栏缝里，
///    把「作者 + 标题」「地址 + 正文」的间距压到 12 pt（角标自身只有 8.4 pt 见方）。
/// 3. 一旦并成假行，后面的 XY 切分**再也找不到这条缝**——判据是「没有任何一行跨过它」，
///    而假行正好跨过了。整页的双栏识别随之失效，段落被左右交错地拼成一段，
///    译文就成了「前半句左栏、后半句右栏」的夹生句。
///
/// 判据刻意保守：一条竖缝要成立，两侧各要有 **两条以上基线**。
/// 只有一条基线时（表格的一行、目录的一行）不做切分——那是行内的宽空格，
/// 交给 `PDFLineBuilder` 原有的字距判定处理。
public enum PDFRegionCutter {
    public struct Options {
        /// 竖缝最小宽度（pt）。页边距比它宽得多，但那边没有文字，会被「两侧至少 3 个 run」挡掉。
        public var minGutter = 6.0
        /// 横缝最小高度（pt）。正文行距之间的空隙一般只有 2–4 pt。
        public var minBand = 12.0
        /// 两侧纵向重叠比例（相对较窄的一侧），低于它说明不是并排的两栏
        public var minOverlap = 0.5
        /// 每侧至少要有的 run 数
        public var minRunsPerSide = 3
        /// 每侧至少要有的基线数（= 行数）
        public var minBaselinesPerSide = 2
        public var maxDepth = 12

        public init() {}
    }

    public static func regions(
        _ runs: [PDFTextRun], options: Options = Options()
    ) -> [[PDFTextRun]] {
        guard runs.count > options.minRunsPerSide else {
            return runs.isEmpty ? [] : [sorted(runs)]
        }
        var out: [[PDFTextRun]] = []
        split(runs, options: options, depth: 0, into: &out)
        return out.filter { !$0.isEmpty }
    }

    // MARK: - 递归

    private static func split(
        _ group: [PDFTextRun], options: Options, depth: Int, into out: inout [[PDFTextRun]]
    ) {
        if group.count <= options.minRunsPerSide || depth >= options.maxDepth {
            out.append(sorted(group))
            return
        }
        // 竖缝优先：双栏页面上常有「横跨两栏的章节分隔」，
        // 若先按水平空白切，左栏会被切成上下两半，阅读顺序变成「左上、右上、左下、右下」。
        if let pieces = verticalSplit(group, options: options) {
            for piece in pieces {
                split(piece, options: options, depth: depth + 1, into: &out)
            }
            return
        }
        if let pieces = horizontalSplit(group, options: options) {
            for piece in pieces {
                split(piece, options: options, depth: depth + 1, into: &out)
            }
            return
        }
        out.append(sorted(group))
    }

    private static func sorted(_ group: [PDFTextRun]) -> [PDFTextRun] {
        group.sorted {
            if abs($0.origin.y - $1.origin.y) > 0.5 { return $0.origin.y > $1.origin.y }
            return $0.origin.x < $1.origin.x
        }
    }

    // MARK: - 竖切（分栏）

    /// 最宽的一条竖缝，返回「上方通栏 / 左 / 右 / 下方通栏」四组，按阅读顺序排列。
    ///
    /// 横跨栏缝的零散 run（页眉、页码、通栏标题）不参与构图：
    /// 只要它们全都落在两栏的上方或下方，就单独成组按上下顺序输出。
    private static func verticalSplit(
        _ group: [PDFTextRun], options: Options
    ) -> [[PDFTextRun]]? {
        let strips = freeVerticalStrips(group, maxCoverage: 1, minWidth: options.minGutter)
        guard !strips.isEmpty else { return nil }

        // 由宽到窄试：最宽的缝最像栏缝
        for strip in strips.sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
            let cut = (strip.start + strip.end) / 2
            var left: [PDFTextRun] = []
            var right: [PDFTextRun] = []
            var straddling: [PDFTextRun] = []
            for run in group {
                if run.bbox.x1 <= cut + 0.01 { left.append(run) }
                else if run.bbox.x0 >= cut - 0.01 { right.append(run) }
                else { straddling.append(run) }
            }
            guard left.count >= options.minRunsPerSide,
                  right.count >= options.minRunsPerSide,
                  left.count + right.count + straddling.count == group.count,
                  baselineCount(left) >= options.minBaselinesPerSide,
                  baselineCount(right) >= options.minBaselinesPerSide else { continue }

            let la = (left.map(\.bbox.y0).min() ?? 0, left.map(\.bbox.y1).max() ?? 0)
            let ra = (right.map(\.bbox.y0).min() ?? 0, right.map(\.bbox.y1).max() ?? 0)
            let overlap = min(la.1, ra.1) - max(la.0, ra.0)
            let span = min(la.1 - la.0, ra.1 - ra.0)
            guard span > 0, overlap / span >= options.minOverlap else { continue }

            let bandTop = max(la.1, ra.1)
            let bandBottom = min(la.0, ra.0)
            let above = straddling.filter { $0.bbox.midY >= bandTop - 1 }
            let below = straddling.filter { $0.bbox.midY <= bandBottom + 1 }
            // 夹在两栏中间的通栏 run 归属不明，放弃这条缝（交给水平切分）
            guard above.count + below.count == straddling.count else { continue }

            return [above, left, right, below].filter { !$0.isEmpty }.map(sorted)
        }
        return nil
    }

    // MARK: - 横切（分区带）

    /// 最宽的一条「整幅都没有文字」的横带，切成上下两组。
    private static func horizontalSplit(
        _ group: [PDFTextRun], options: Options
    ) -> [[PDFTextRun]]? {
        let strips = freeHorizontalStrips(group, minHeight: options.minBand)
        guard let strip = strips.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
        else { return nil }
        let cut = (strip.start + strip.end) / 2
        let top = group.filter { $0.bbox.midY > cut }
        let bottom = group.filter { $0.bbox.midY <= cut }
        guard !top.isEmpty, !bottom.isEmpty,
              top.count + bottom.count == group.count else { return nil }
        return [top, bottom].map(sorted)
    }

    // MARK: - 扫描线

    public struct Strip {
        public var start: Double
        public var end: Double
    }

    /// 覆盖数 ≤ `maxCoverage` 的竖条。
    ///
    /// 用扫描线而不是「对每个候选中点数一遍」：一页的 run 常有上千个，
    /// 逐个中点遍历会退化成 O(n²)（409 页样书上单页就要几十毫秒）。
    public static func freeVerticalStrips(
        _ group: [PDFTextRun], maxCoverage: Int, minWidth: Double
    ) -> [Strip] {
        var events: [(x: Double, delta: Int)] = []
        events.reserveCapacity(group.count * 2)
        for run in group {
            events.append((run.bbox.x0, 1))
            events.append((run.bbox.x1, -1))
        }
        guard events.count >= 2 else { return [] }
        events.sort { $0.x == $1.x ? $0.delta < $1.delta : $0.x < $1.x }

        var strips: [Strip] = []
        var active = 0
        var start: Double?
        var index = 0
        while index < events.count {
            let x = events[index].x
            // 先在同一 x 上把事件全部结掉，`active` 才是 (x, 下一个 x) 这一段的覆盖数
            while index < events.count && events[index].x == x {
                active += events[index].delta
                index += 1
            }
            if active <= maxCoverage {
                // 进入（或继续留在）空白带：**不要**在每个端点处断开，
                // 否则一条 14 pt 的栏缝会被 run 端点切成几段 3 pt 的碎片全部丢掉。
                if start == nil { start = x }
            } else if let begin = start {
                if x - begin >= minWidth {
                    strips.append(Strip(start: begin, end: x))
                }
                start = nil
            }
        }
        return strips
    }

    /// 整幅宽度上都没有 run 的横带。
    public static func freeHorizontalStrips(
        _ group: [PDFTextRun], minHeight: Double
    ) -> [Strip] {
        let ordered = group.sorted { $0.bbox.midY > $1.bbox.midY }
        var events: [(y: Double, delta: Int)] = []
        events.reserveCapacity(ordered.count * 2)
        for run in ordered {
            events.append((run.bbox.y0, 1))
            events.append((run.bbox.y1, -1))
        }
        guard events.count >= 2 else { return [] }
        events.sort { $0.y == $1.y ? $0.delta < $1.delta : $0.y < $1.y }

        var strips: [Strip] = []
        var active = 0
        var start: Double?
        var index = 0
        while index < events.count {
            let y = events[index].y
            while index < events.count && events[index].y == y {
                active += events[index].delta
                index += 1
            }
            if active == 0 {
                if start == nil { start = y }
            } else if let begin = start {
                if y - begin >= minHeight {
                    strips.append(Strip(start: begin, end: y))
                }
                start = nil
            }
        }
        return strips
    }

    /// 不同基线的条数（≈ 行数）。基线差在 1 pt 以内算同一行。
    public static func baselineCount(_ runs: [PDFTextRun]) -> Int {
        var count = 0
        var last = -Double.infinity
        for y in runs.map(\.origin.y).sorted() where y - last > 1.0 {
            count += 1
            last = y
        }
        return count
    }
}
