import Foundation

/// 页内重排（`page-reflow`）：最后一道出口。
///
/// 触发条件是「同页有 ≥2 段连下限字号都放不下」。这时让文字**沿纵向顺延**：
/// 每个块保留原来的 x 位置与宽度，只把「放不下而多出来的高度」往下推。
///
/// 两条经验教训（第一版都踩了）：
///     ① **不能用 `ILBlock.column` 做分组**。它只是 P2 分栏时的组序号，
///        跨栏的长行会被分到独立组，导致两个组占同一片横向区域，排出来互相压；
///        正确做法是按 x 区间聚类得到视觉栏，并且**排布时用矩形碰撞**而不是「每栏一个光标」。
///     ② **不能把整页压成单栏**。项目符号、页眉这些孤立 run 留在原位，
///        正文一旦重排到别处，满页就浮着「•」。保横向、只动纵向才能保住版式线索。
///
/// 与 BabelDOC 的「整页重建」仍有本质区别：它丢弃原页、从 IL 重画一切；
/// 这里图片/表格/矢量仍由原始算子绘制，位置分毫不动。
///
/// 已知限制（如实）：
///     - 块只能下移，不能上提（上提会与页眉/图注打架）；
///     - 一页排不下时溢出进报告，不自动开新页（开新页要改页树，属 P5）；
///     - 表格内部不参与重排，仍各自就地排；
///     - 孤立 run（项目符号、页眉）不跟随块移动。
public enum PDFPageReflow {
    public struct Outcome {
        public var plans: [PDFTypeset.Plan] = []
        /// 排不下、被丢弃的行数（进报告并触发 needsReview）
        public var overflowLines = 0
        public var movedBlocks = 0
        public var unplacedBlocks = 0
        /// 排不下、最后留在原位的块 id。它们由调用方按「保持原字节」处理，
        /// 因此必须点名，而不是只数个数——只数个数就没法保证不丢字。
        public var unplaced: [String] = []
        /// 译文放不下、回落成原文的块数（比静默删字好，但要如实计数）
        public var revertedBlocks = 0
    }

    public static func flow(
        blocks: [ILBlock],
        texts: [String: String],
        region: PDFRect,
        obstacles: [PDFRect],
        face: (ILBlock) -> PDFFace,
        floorSize: Double,
        options: PDFTypeset.Options = PDFTypeset.Options(),
        gap: Double = 4
    ) -> Outcome {
        var outcome = Outcome()
        guard !blocks.isEmpty else { return outcome }

        // 微小障碍物（上标数字、项目符号、孤立标点）不参与碰撞：
        // 它们是钉在原位的几个点，把整段顶下去只会留出一条莫名其妙的空白带
        // （真实样本：`g/cm³` 的上标把下一段推低了 90pt）。
        let solids = obstacles.filter { $0.height > 10 || $0.width > 40 }

        var placedRects: [PDFRect] = []

        for block in readingOrder(blocks) {
            let text = texts[block.id] ?? block.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // 同一栏里「已经放过的块」构成一个天花板：本块必须排在它们**下面**。
            //
            // 少了这一步，顺序就会倒：前一段因为译文变长被顶到很低的位置，
            // 后一段仍按自己的原顶边放，于是后一段跑到了前一段上面。
            // 真实样本（参考文献页）：[37] 被顶到 y=599，[37] 的续行留在 y=628，
            // R7 直接报「p0-b18 应在 p0-b16 之前」——复制粘贴出来的句子是倒的。
            let columnCursor = placedRects
                .filter {
                    let overlap = min($0.x1, block.box.x1) - max($0.x0, block.box.x0)
                    return overlap > min($0.width, block.box.width) * 0.3
                }
                .map(\.y0)
                .min()
            var top = min(block.box.y1, region.y1)
            if let cursor = columnCursor {
                top = min(top, cursor - gap)
            }
            var placed = false
            var attempts = 0

            while !placed && attempts < 24 {
                attempts += 1
                let available = top - region.y0
                guard available > max(8, block.fontSize) else { break }

                // 允许用到整栏宽度：短标题（"授权使用"）的原始框很窄，
                // 译长了以后如果仍锁原宽，会变成一行一两个字，很难看。
                let columnRight = PDFTypeset.columnRightEdge(
                    for: block, in: blocks, limit: region.x1)
                let box = PDFRect(x0: block.box.x0, y0: region.y0,
                                  x1: max(block.box.x1, columnRight), y1: top)
                var plan = PDFTypeset.plan(
                    text: text, blockID: block.id, face: face(block),
                    baseFontSize: max(1, block.fontSize),
                    space: PDFTypeset.Space(box: box, rightLimit: box.x1,
                                            downLimit: region.y0),
                    floorSize: floorSize, options: options)
                guard !plan.lines.isEmpty else { break }

                let needed = Double(plan.lines.count) * plan.lineHeight
                let occupied = PDFRect(x0: plan.box.x0, y0: top - needed,
                                       x1: plan.box.x1, y1: top)

                // 与障碍物或已放置块冲突 → 整体下移到冲突物下方
                let colliders = (solids + placedRects).filter { $0.intersects(occupied) }
                if let lowest = colliders.max(by: { $0.y0 < $1.y0 }) {
                    let nextTop = lowest.y0 - gap
                    if nextTop < top - 0.5 {
                        top = nextTop
                        continue
                    }
                }

                if plan.tier == .overflowShort || plan.tier == .overflowLong {
                    // 放不下时**先把这一段回落成原文**，而不是把溢出的行丢掉。
                    // 原文当初就排在这个框里，一定放得下；丢掉溢出行等于静默删字
                    // （真实样本 10 页里丢了 3 段，自检报 `text-truncated`）。
                    let source = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !source.isEmpty, source != text {
                        let fallback = PDFTypeset.plan(
                            text: source, blockID: block.id, face: face(block),
                            baseFontSize: max(1, block.fontSize),
                            space: PDFTypeset.Space(box: box, rightLimit: box.x1,
                                                    downLimit: region.y0),
                            floorSize: floorSize, options: options)
                        if !fallback.lines.isEmpty && fallback.overflow.isEmpty {
                            plan = fallback
                            outcome.revertedBlocks += 1
                        }
                    }
                    if !plan.overflow.isEmpty {
                        outcome.overflowLines += plan.overflow.count
                        plan.overflow = []
                    }
                }
                if abs(top - block.box.y1) > 0.5 { outcome.movedBlocks += 1 }
                outcome.plans.append(plan)
                placedRects.append(occupied)
                placed = true
            }
            if !placed {
                outcome.unplacedBlocks += 1
                outcome.unplaced.append(block.id)
            }
        }
        return outcome
    }

    /// 阅读顺序：先按视觉栏（x 区间聚类）从左到右，栏内自上而下。
    ///
    /// 不用 `block.column`：跨栏长行会被分成独立组，组序号与空间顺序对不上。
    /// 聚类判据是「横向重叠超过较窄者的一半」，比「x0 相近」稳——
    /// 项目符号段落的首行缩进会让 x0 差出 20pt，但横向区间仍然重叠。
    public static func readingOrder(_ blocks: [ILBlock]) -> [ILBlock] {
        var clusters: [[ILBlock]] = []
        for block in blocks.sorted(by: { $0.box.x0 < $1.box.x0 }) {
            var assigned = false
            for index in clusters.indices {
                guard var range = clusters[index].first?.box else { continue }
                for item in clusters[index].dropFirst() { range = range.union(item.box) }
                let overlap = min(range.x1, block.box.x1) - max(range.x0, block.box.x0)
                let narrower = min(range.width, block.box.width)
                if narrower > 0, overlap / narrower > 0.5 {
                    clusters[index].append(block)
                    assigned = true
                    break
                }
            }
            if !assigned { clusters.append([block]) }
        }
        return clusters
            .sorted { lhs, rhs in
                (lhs.map(\.box.x0).min() ?? 0) < (rhs.map(\.box.x0).min() ?? 0)
            }
            .flatMap { $0.sorted { $0.box.y1 > $1.box.y1 } }
    }
}
