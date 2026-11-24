import Foundation

/// P4 闭环：排版 → 渲染 → 七项分析 → 段落级修复 → 再排版 → 再分析（≤2 轮）。
///
/// 三件事必须一起做，缺一条这个闭环就没有意义：
///     ① **可证伪**：R1 用掩膜外逐像素差证明「图片和矢量没被碰过」，
///        而不是「我看着差不多」；
///     ② **可收敛**：修复指令单调收敛（只缩不涨、只收不放），最多两轮；
///     ③ **可审计**：每轮留下 `RepairTrace`，最后一页一页告诉你
///        「这页修了什么、修好了没有、没修好的原因」。
///
/// 关于「只重写受影响页」：
/// 实现是**重新跑一遍排版**，但只对失败页下发了不同的指令，其余页的参数一字不改；
/// 又因为字体子集在首轮就把「译文 + 原文」全部收进去了，子集与 CID 映射跨轮稳定，
/// 所以未受影响页的内容流**逐字节相同**。这一点不靠嘴说——每轮用
/// `contentHash` 对账，不一致就记进 `RoundRecord.churnedPages` 并重查。
public enum PDFVerifyLoop {

    public struct Options: Sendable {
        /// 修复轮数上限。2 轮之后还不过，就交付 + 列清单（绝不静默降级）
        public var maxRounds = 2
        public var analysis = PDFSimilarityAnalyzer.Options()
        /// 只校验这些页（0 基）。nil = 全部
        public var verifyPages: [Int]?

        public init() {}
    }

    public struct RoundRecord: Sendable, Encodable {
        public var round = 0
        public var checkedPages = 0
        public var passed = false
        public var errorCount = 0
        public var errorPages: [Int] = []
        /// 相对上一轮内容流有变化的页（0 基）
        public var churnedPages: [Int] = []
        /// 上一轮通过、这一轮内容流却变了的页 —— 正常情况下必须为空
        public var unexpectedPages: [Int] = []
        public var typesetMS = 0.0
        public var analysisMS = 0.0
        public var actions: [PDFRepair.Action] = []
        public var manual: [PDFRepair.Action] = []
    }

    public struct Outcome: Sendable {
        public var output: Data
        public var report: PDFTypesetEngine.Report
        public var analysis: PDFSimilarityAnalyzer.Result
        public var rounds: [RoundRecord]
        public var repairs: PDFRepair.Set
        public var layouts: [Int: PDFPageLayout]
        /// 修过并且修好的页（1 基）
        public var repairedPages: [Int] = []
        /// 两轮之后仍未通过的页（1 基）
        public var unresolvedPages: [Int] = []
        public var needsReviewPages: [Int] = []
        /// 修不动、必须人工看的发现（缺字 / 占位符 / 像素差）
        public var manualActions: [PDFRepair.Action] = []
    }

    public static func run(
        document: PDFDocument,
        faces: PDFTypesetEngine.FaceSet,
        pageIndices: [Int]? = nil,
        request: PDFTypesetEngine.Request = PDFTypesetEngine.Request(),
        options: Options = Options()
    ) throws -> Outcome {
        var request = request
        let cache = PDFRenderingCache()
        var mergedPages: [Int: PDFSimilarityAnalyzer.PageResult] = [:]
        var previousLayouts: [Int: PDFPageLayout] = [:]
        var records: [RoundRecord] = []
        var allActions: [PDFRepair.Action] = []
        var allManual: [PDFRepair.Action] = []
        var recheck: [Int]? = options.verifyPages
        var firstFailureSet = Set<Int>()

        var output = Data()
        var report = PDFTypesetEngine.Report()
        var layouts: [Int: PDFPageLayout] = [:]
        var analysis = PDFSimilarityAnalyzer.Result()

        for round in 0...max(0, options.maxRounds) {
            var record = RoundRecord(round: round)

            let typesetStart = Date()
            let detailed = try PDFTypesetEngine.runDetailed(
                document: document, faces: faces, pageIndices: pageIndices, request: request)
            record.typesetMS = round2(Date().timeIntervalSince(typesetStart) * 1000)
            output = detailed.output
            report = detailed.report
            layouts = Dictionary(uniqueKeysWithValues: detailed.layouts.map { ($0.page, $0) })

            // 对账：哪些页的内容流变了
            if !previousLayouts.isEmpty {
                for (index, layout) in layouts {
                    let previous = previousLayouts[index]
                    if previous?.contentHash != layout.contentHash {
                        record.churnedPages.append(index)
                    }
                }
                record.churnedPages.sort()
                // 上一轮已经通过的页如果内容流变了，说明修复产生了副作用，必须重查
                let churned = Set(record.churnedPages)
                let passedBefore = Set(mergedPages.filter { $0.value.passed }.map { $0.key })
                record.unexpectedPages = churned.intersection(passedBefore).sorted()
            }

            // 复查范围：首轮按用户指定，之后 = 上轮失败页 ∪ 意外变动的页
            var pagesToCheck = recheck
            if round > 0 {
                let failed = Set(mergedPages.filter { !$0.value.passed }.map { $0.key })
                let union = failed.union(record.unexpectedPages.map { $0 })
                var list = Array(union).sorted()
                if let explicit = options.verifyPages {
                    list = list.filter { explicit.contains($0) }
                }
                pagesToCheck = list
            }

            if pagesToCheck?.isEmpty == true {
                record.passed = true
                records.append(record)
                break
            }

            let analysisStart = Date()
            analysis = PDFSimilarityAnalyzer.analyze(
                original: document.data, output: output, layouts: layouts,
                pages: pagesToCheck, options: options.analysis, cache: cache)
            record.analysisMS = round2(Date().timeIntervalSince(analysisStart) * 1000)

            for page in analysis.pages {
                mergedPages[page.page - 1] = page
            }
            record.checkedPages = analysis.pages.count
            record.errorPages = analysis.failedPages
            record.errorCount = analysis.errorCount
            record.passed = analysis.passed

            // 合并后的全局结论
            var merged = PDFSimilarityAnalyzer.Result()
            merged.pages = mergedPages.keys.sorted().compactMap { mergedPages[$0] }
            merged.failedPages = merged.pages.filter { !$0.passed }.map(\.page)
            merged.skippedPages = merged.pages.filter(\.skipped).map(\.page)
            merged.errorCount = merged.pages.reduce(0) { $0 + $1.errors }
            merged.warningCount = merged.pages.reduce(0) { $0 + $1.warnings }
            merged.fatal = analysis.fatal
            merged.durationMS = round2(records.reduce(0) { $0 + $1.analysisMS } + record.analysisMS)

            if !analysis.fatal.isEmpty {
                record.passed = false
                record.errorCount = max(record.errorCount, 1)
                records.append(record)
                break
            }
            if merged.pages.filter({ !$0.skipped }).allSatisfy(\.passed) {
                record.passed = true
                records.append(record)
                analysis = merged
                break
            }

            // 还有错：推导修复指令
            if round >= options.maxRounds { records.append(record); analysis = merged; break }
            let derived = PDFRepair.derive(from: merged, layouts: layouts, round: round + 1)
            if derived.repairs.isEmpty {
                record.manual = derived.manual
                allManual += derived.manual
                records.append(record)
                analysis = merged
                break
            }
            record.actions = derived.actions
            record.manual = derived.manual
            allActions += derived.actions
            allManual += derived.manual
            request.repairs.merge(derived.repairs)
            firstFailureSet.formUnion(analysis.failedPages)
            previousLayouts = layouts
            records.append(record)
            analysis = merged
            recheck = analysis.failedPages.map { $0 - 1 }
        }

        var outcome = Outcome(
            output: output, report: report, analysis: analysis, rounds: records,
            repairs: request.repairs, layouts: layouts)
        outcome.unresolvedPages = analysis.pages.filter { !$0.passed }.map(\.page)
        outcome.repairedPages = firstFailureSet.subtracting(Set(outcome.unresolvedPages)).sorted()
        outcome.needsReviewPages = Array(Set(
            report.needsReviewPages + outcome.unresolvedPages)).sorted()
        outcome.manualActions = allManual
        return outcome
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
