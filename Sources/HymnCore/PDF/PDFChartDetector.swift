import Foundation

// MARK: - 图表（chart）区域识别
//
// 目标很具体：**图表里的文字一律不翻**。
//
// 起因是真实期刊样本上的一批事故：柱状图 x 轴的 24 个竖排品种名、
// 折线图的纵轴标题「Measured Output」、图例「A-weighted Road Noise」被当成正文段落送进模型，
// 逐条翻成「我曾经是」「哇，超级英雄」这类东西，再按新行重排，压在柱子和刻度上。
// 这类文字**没有任何可翻译价值**（品种名、单位、符号），翻错只会毁版面。
//
// 为什么不能直接复用 `page.figures`：那里只有**位图**（XObject Image）。
// 期刊里的图表绝大多数是矢量绘图（折线 + 填充矩形），一个 image 都没有，
// 所以 `figures` 是空的，识别不到。
//
// 判定用的是「笔触密度」：把页面上所有路径的包围盒聚成一簇，
// 一簇里如果既有足够多的独立路径（柱状图）或足够多的折线点（曲线图），
// 又占着像样的面积，就认为是图表；再按坐标轴标题的习惯外扩一点，把轴标题、图例吞进来。
//
// 刻意保守：宁可漏判（那张图的文字被翻译），也不要错判成图表——
// 错判的后果是把正文整段留在英文，用户会立刻发现。

public struct ILChart: Sendable {
    public init(id: String, box: PDFRect, pathCount: Int, pointCount: Int) {
        self.id = id
        self.box = box
        self.pathCount = pathCount
        self.pointCount = pointCount
    }

    public var id: String
    /// 图表区域（已外扩，含坐标轴标题与图例）
    public var box: PDFRect
    /// 区域内的路径数（诊断用）
    public var pathCount: Int
    /// 区域内路径端点数（诊断用）
    public var pointCount: Int
}

public enum PDFChartDetector {
    public struct Options: Sendable {
        /// 两条路径相距多近算「同一张图里的」（pt）
        public var joinGap = 14.0
        /// 一条路径的包围盒大到这个比例就是整页背景/版心底色，排除
        public var maxPathAreaRatio = 0.55
        /// 最少独立路径数（柱状图：每根柱子一条）
        public var minPathCount = 8
        /// 或最少端点数（折线图：一条曲线就有几百个点）
        public var minPointCount = 60
        /// 簇的最小尺寸
        public var minWidth = 80.0
        public var minHeight = 50.0
        /// 外扩：左侧留给纵轴标题，下方留给横轴标题
        public var expandLeft = 20.0
        public var expandRight = 12.0
        public var expandBottom = 18.0
        public var expandTop = 10.0
        /// 与已识别表格重叠超过这个比例就当成表格网格，不算图表
        public var tableOverlapRatio = 0.45

        public init() {}
    }

    public static func detect(
        paths: [PDFPaintedPath],
        pageWidth: Double,
        pageHeight: Double,
        tables: [ILTable],
        options: Options = Options()
    ) -> [ILChart] {
        let pageArea = max(1, pageWidth * pageHeight)
        // 1. 过滤：整页底色、通栏细线（版心线/页眉线）不参与聚类
        let usable = paths.filter { path in
            let box = path.box
            guard box.area > 2 else { return false }
            if box.area > options.maxPathAreaRatio * pageArea { return false }
            if box.width > 0.85 * pageWidth && box.height < 8 { return false }
            if box.height > 0.85 * pageHeight && box.width < 8 { return false }
            return true
        }
        guard !usable.isEmpty else { return [] }

        // 2. 并查集聚类：包围盒按 `joinGap` 外扩后相交即同簇
        var parent = Array(0..<usable.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        let padded = usable.map { $0.box.expanded(by: options.joinGap / 2) }
        for i in 0..<usable.count {
            for j in (i + 1)..<usable.count where padded[i].intersects(padded[j]) {
                union(i, j)
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in usable.indices { groups[find(i), default: []].append(i) }

        // 3. 逐簇判定
        var charts: [ILChart] = []
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            var box = usable[members[0]].box
            var points = 0
            for m in members {
                box = box.union(usable[m].box)
                points += usable[m].points
            }
            guard box.width >= options.minWidth, box.height >= options.minHeight else { continue }
            guard members.count >= options.minPathCount || points >= options.minPointCount else { continue }
            // 表格网格：横竖线成簇，形状和图表很像，用已识别的表格框排除
            let covered = tables.reduce(0.0) { $0 + $1.box.intersectionArea(box) }
            if covered > options.tableOverlapRatio * max(1, box.area) { continue }

            if ProcessInfo.processInfo.environment["HYMN_CHART_DEBUG"] == "1" {
                FileHandle.standardError.write(Data(
                    "chart cluster box=\(box) paths=\(members.count) points=\(points)\n".utf8))
                for m in members.sorted(by: { usable[$0].box.y1 > usable[$1].box.y1 }).prefix(6) {
                    FileHandle.standardError.write(Data("   member \(usable[m].box) pts=\(usable[m].points) filled=\(usable[m].filled)\n".utf8))
                }
            }
            let region = PDFRect(
                x0: max(0, box.x0 - options.expandLeft),
                y0: max(0, box.y0 - options.expandBottom),
                x1: min(pageWidth, box.x1 + options.expandRight),
                y1: min(pageHeight, box.y1 + options.expandTop))
            charts.append(ILChart(
                id: "c\(charts.count)", box: region,
                pathCount: members.count, pointCount: points))
        }
        // 4. 去掉「被另一个大区域完全盖住」的重复检测
        var kept: [ILChart] = []
        for chart in charts.sorted(by: { $0.box.area > $1.box.area }) {
            let covered = kept.contains { $0.box.intersectionArea(chart.box) > 0.8 * chart.box.area }
            if !covered { kept.append(chart) }
        }
        return kept.sorted { $0.box.y1 > $1.box.y1 }
    }
}
