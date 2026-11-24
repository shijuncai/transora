import Foundation

/// 段落级修复指令。
///
/// 为什么不是「重排整页」：第 2 轮重排会把第 1 轮已经排好的段落重新洗一遍，
/// 一个本来 fit 的段可能因为邻居变了字号而再次溢出，形成「越修越坏」的循环。
/// 所以修复只针对**出问题的块**下发指令，其余块沿用原参数。
///
/// 四类指令，按代价从低到高：
///     `.shrink`      只对这一块放宽字号下限（最低 5pt），并允许再向下扩一点；
///     `.avoidSide`   禁止向右/向下扩（压图压表时，扩框只会更糟）；
///     `.revert`      回落原文（原文当初就在这个框里，它一定放得下）；
///     `.reflowPage`  整页重排（阅读顺序错、多处溢出，块级修不动）。
///
/// 指令是**单调**的：同一块多轮只会越来越保守，不会反复横跳。
public enum PDFRepair {

    public struct BlockRepair: Sendable, Encodable {
        /// 放宽后的字号下限（引擎里取 min(页面下限, 这个值)）
        public var minFontSize: Double?
        /// 向右可扩倍数（<1 表示收紧）
        public var rightExpand = 1.0
        /// 向下可扩倍数
        public var downExpand = 1.0
        /// 回落原文（不翻译）
        public var revertToSource = false
        public var note = ""

        public init() {}

        public init(minFontSize: Double? = nil, rightExpand: Double = 1,
                    downExpand: Double = 1, revertToSource: Bool = false, note: String = "") {
            self.minFontSize = minFontSize
            self.rightExpand = rightExpand
            self.downExpand = downExpand
            self.revertToSource = revertToSource
            self.note = note
        }

        /// 合并两次指令：取更保守的一方
        public func merged(with other: BlockRepair) -> BlockRepair {
            var out = self
            if let mine = minFontSize, let theirs = other.minFontSize {
                out.minFontSize = min(mine, theirs)
            } else if let theirs = other.minFontSize {
                out.minFontSize = theirs
            }
            out.rightExpand = min(rightExpand, other.rightExpand)
            out.downExpand = min(downExpand, other.downExpand)
            out.revertToSource = revertToSource || other.revertToSource
            if !other.note.isEmpty { out.note = other.note }
            return out
        }
    }

    public struct PageRepair: Sendable {
        public var forceReflow = false
        public var blocks: [String: BlockRepair] = [:]
        public var notes: [String] = []

        public init() {}

        public var isEmpty: Bool { !forceReflow && blocks.isEmpty }

        public func merged(with other: PageRepair) -> PageRepair {
            var out = self
            out.forceReflow = forceReflow || other.forceReflow
            out.notes += other.notes
            for (id, repair) in other.blocks {
                out.blocks[id] = out.blocks[id]?.merged(with: repair) ?? repair
            }
            return out
        }
    }

    public struct Set: Sendable {
        /// key = 0 基页号
        public var pages: [Int: PageRepair] = [:]

        public init() {}

        public var isEmpty: Bool { pages.values.allSatisfy(\.isEmpty) }

        public func page(_ index: Int) -> PageRepair? { pages[index] }

        public func block(page index: Int, id: String) -> BlockRepair? {
            pages[index]?.blocks[id]
        }

        public mutating func merge(_ other: Set) {
            for (index, repair) in other.pages {
                pages[index] = pages[index]?.merged(with: repair) ?? repair
            }
        }

        public var pagesWithRepairs: [Int] { pages.keys.sorted() }
    }

    public struct Action: Sendable, Encodable {
        public var round: Int
        public var page: Int           // 1 基
        public var blockID: String?
        public var action: String
        public var detail: String
        public var metricBefore: Double
        public var limit: Double
    }

    /// 从分析结果推导下一轮指令。
    ///
    /// 只对 `severity == .error` 且标了 `repairable` 的发现下指令：
    /// 缺字、占位符、像素差这三类不是排版能修的，硬修只会掩盖问题。
    public static func derive(
        from result: PDFSimilarityAnalyzer.Result,
        layouts: [Int: PDFPageLayout],
        round: Int
    ) -> (repairs: Set, actions: [Action], manual: [Action]) {
        var repairs = Set()
        var actions: [Action] = []
        var manual: [Action] = []

        for page in result.pages where !page.passed {
            let index = page.page - 1
            let layout = layouts[index]
            var pageRepair = PageRepair()

            for finding in page.findings where finding.severity == .error {
                guard finding.repairable else {
                    manual.append(Action(
                        round: round, page: page.page, blockID: finding.blockID,
                        action: "manual-review", detail: finding.detail,
                        metricBefore: finding.metric, limit: finding.limit))
                    continue
                }
                switch finding.check {
                case PDFSimilarityAnalyzer.Check.r2.rawValue,
                     PDFSimilarityAnalyzer.Check.r3.rawValue:
                    guard let blockID = finding.blockID,
                          let item = layout?.items.first(where: { $0.id == blockID })
                    else {
                        pageRepair.forceReflow = true
                        pageRepair.notes.append("R2/R3 定位不到块，整页重排")
                        actions.append(Action(
                            round: round, page: page.page, blockID: finding.blockID,
                            action: "reflow-page", detail: "定位不到具体块，整页重排",
                            metricBefore: finding.metric, limit: finding.limit))
                        continue
                    }
                    let avoidSide = finding.code == "text-over-figure" || finding.code == "text-over-table"
                    var block = BlockRepair()
                    // 已经缩到 5pt 还溢出/压住，只能回落原文：
                    // 再小就不是「排版紧」而是「看不清」
                    if item.fontSize <= 5.6 {
                        block.revertToSource = true
                        block.note = "已到 5.6pt 仍有 \(finding.check) 问题，回落原文"
                    } else {
                        block.minFontSize = max(5.0, (item.fontSize * 0.9 * 100).rounded() / 100)
                        block.downExpand = avoidSide ? 1.0 : 1.15
                        block.rightExpand = avoidSide ? 1.0 : 1.0
                        block.note = "缩至 \(String(format: "%.1f", block.minFontSize!))pt"
                    }
                    pageRepair.blocks[blockID] = pageRepair.blocks[blockID]?.merged(with: block) ?? block
                    actions.append(Action(
                        round: round, page: page.page, blockID: blockID,
                        action: block.revertToSource ? "revert-to-source" : "shrink",
                        detail: "\(finding.code)：\(block.note)",
                        metricBefore: finding.metric, limit: finding.limit))

                case PDFSimilarityAnalyzer.Check.r5.rawValue,
                     PDFSimilarityAnalyzer.Check.r7.rawValue:
                    if !pageRepair.forceReflow {
                        pageRepair.forceReflow = true
                        pageRepair.notes.append("\(finding.code) 触发整页重排")
                        actions.append(Action(
                            round: round, page: page.page, blockID: finding.blockID,
                            action: "reflow-page", detail: finding.code,
                            metricBefore: finding.metric, limit: finding.limit))
                    }

                default:
                    manual.append(Action(
                        round: round, page: page.page, blockID: finding.blockID,
                        action: "manual-review", detail: "\(finding.code)：\(finding.detail)",
                        metricBefore: finding.metric, limit: finding.limit))
                }
            }

            if !pageRepair.isEmpty { repairs.pages[index] = pageRepair }
        }
        return (repairs, actions, manual)
    }
}
