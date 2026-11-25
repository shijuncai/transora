import Foundation
import HymnCore

/// 「版式重建」流水线：PDF → 结构 → 逐段翻译 → 写回原版式 → 自检 → 对照报告。
///
/// 与现有「PDF 长文本翻译」的区别：那条链路把文字抽出来变成 TXT/DOCX，
/// 版式、图片、表格全部丢失；这条链路**把译文写回原页面**，
/// 图片与矢量一个字节都不动（见 `PDFVerifyLoop` 的 R1）。
///
/// 三条约束：
///   ① 全程本机推理，不联网；
///   ② 逐段串行（单实例调度），主线程只在每段结束时更新一次进度；
///   ③ 任何一段失败都不静默丢弃——该段回落原文，并在报告里标出来。
struct PDFRebuildPipeline {
    struct Progress: Sendable {
        var stage: String
        var done: Int
        var total: Int
        var detail: String = ""

        var fraction: Double {
            total > 0 ? min(1, Double(done) / Double(total)) : 0
        }
    }

    struct Outcome: Sendable {
        var pdf: Data
        var reportHTML: String
        var typeset: PDFTypesetEngine.Report
        var analysis: PDFSimilarityAnalyzer.Result?
        var translatedBlocks: Int
        var keptBlocks: Int
        var failedBlocks: Int
    }

    enum Failure: LocalizedError {
        case fontMissing
        case emptyDocument
        case cancelled

        var errorDescription: String? {
            switch self {
            case .fontMissing: return L("找不到内置字体（LinguaNovaSong），无法写回版式")
            case .emptyDocument: return L("这份 PDF 没有可提取的文字（可能是扫描件）")
            case .cancelled: return L("已取消")
            }
        }
    }

    /// 翻译一段的回调：由调用方决定用哪个后端、是否流式。
    typealias Translator = @Sendable (InferenceRequest) async -> String

    /// 字体定位：包内 Resources/Fonts → 环境变量 → 工作目录。
    /// 不放进 `Bundle.module`（HymnCore 没声明资源），也不打包进 CLI。
    static func fontURLs() -> (regular: URL, bold: URL?)? {
        var roots: [URL] = []
        if let resource = Bundle.main.resourceURL {
            roots.append(resource.appendingPathComponent("Fonts"))
        }
        if let custom = ProcessInfo.processInfo.environment["HYMN_FONT_DIR"], !custom.isEmpty {
            roots.append(URL(fileURLWithPath: custom))
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Fonts"))
        let names = ("LinguaNovaSong-Regular.ttf", "LinguaNovaSong-Bold.ttf")
        for root in roots {
            let regular = root.appendingPathComponent(names.0)
            guard FileManager.default.fileExists(atPath: regular.path) else { continue }
            let bold = root.appendingPathComponent(names.1)
            let hasBold = FileManager.default.fileExists(atPath: bold.path)
            return (regular, hasBold ? bold : nil)
        }
        return nil
    }

    static func run(
        data: Data,
        languages: LanguagePair,
        translate: @escaping Translator,
        isCancelled: @escaping @Sendable () -> Bool,
        maxBlocks: Int = 0,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Outcome {
        // 1. 结构
        progress(Progress(stage: L("解析版式"), done: 0, total: 1, detail: L("读取页面与文字位置")))
        let document = try PDFDocument(data: data)
        if document.isEncrypted {
            throw PDFScrub.Failure.encrypted
        }
        let structure = PDFStructureBuilder.build(document: document)
        let translatable = structure.pages.reduce(0) { $0 + $1.blocks.count }
        guard translatable > 0 else { throw Failure.emptyDocument }

        // 2. 逐段翻译（串行，单实例调度）
        var map = PDFPlaceholder.TranslationMap()
        var done = 0
        var failed = 0
        outer: for page in structure.pages {
            for block in page.blocks {
                if isCancelled() { throw Failure.cancelled }
                if maxBlocks > 0 && done >= maxBlocks { break outer }
                let source = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                defer { done += 1 }
                guard source.count >= 2 else { continue }
                // 图表里的文字、公式、代码块：排版阶段本来就保持原字节，
                // 这里直接跳过推理。真实期刊样本里一张柱状图有 98 个品种名标签，
                // 全送进模型只是白跑 98 次推理。
                guard !PDFTypesetEngine.keepsOriginal(block, page: page) else { continue }
                // 纯符号/纯数字的碎片不值得跑一次推理
                guard PDFScript.hasTranslatableCharacters(source) else { continue }

                // 一段一次推理。取消在段边界生效——块内中断会让后端状态不一致，
                // 而且用户看到的进度本来就是「第几段」。
                //
                // 超长段落先按句子切：1.25bit 1.8B 的 KV 窗口只有 2048，
                // 提示词 + 生成量放不下的部分会被截断（旧版是直接抛错、整段回落英文）。
                let pieces = PDFSentenceSplitter.chunks(source, limit: 900)
                // 中文/日文/韩文拼接不加分隔符，其它语种必须补空格，否则会粘成一个词
                let joiner = ["zh", "ja", "ko"].contains(languages.target.lowercased())
                    ? "" : " "
                var translated = ""
                for piece in pieces {
                    if isCancelled() { throw Failure.cancelled }
                    let request = InferenceRequest(
                        text: piece, languages: languages,
                        maxTokens: max(160, min(1024, piece.count * 3)))
                    let result = await translate(request)
                    if !translated.isEmpty { translated += joiner }
                    translated += result
                }
                if isCancelled() { throw Failure.cancelled }
                let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty || cleaned.hasPrefix(L("［本段翻译失败")) {
                    failed += 1
                } else {
                    map.entries["p\(page.index + 1)-\(block.id)"] = cleaned
                }
                progress(Progress(
                    stage: L("翻译"), done: done, total: translatable,
                    detail: L("第 %d 页 · %@", page.index + 1, block.id)))
            }
        }

        if isCancelled() { throw Failure.cancelled }

        // 3. 字体
        guard let fonts = fontURLs(), let regular = try? TrueTypeFont(url: fonts.regular) else {
            throw Failure.fontMissing
        }
        let bold = fonts.bold.flatMap { try? TrueTypeFont(url: $0) }

        // 4. 排版 + 自检（图片/矢量必须一个像素都不动）
        progress(Progress(stage: L("写回版式"), done: 0, total: 1, detail: L("驱逐译文对应的原文并重排")))
        var request = PDFTypesetEngine.Request()
        request.translations = map
        request.scrub = true
        var options = PDFVerifyLoop.Options()
        options.maxRounds = 1
        options.analysis.dpi = 144
        // 长文档按步长抽样：既覆盖全篇，又不让「自检」比排版本身还慢
        let pageCount = document.pageCount
        options.analysis.pageStride = pageCount > 80 ? max(2, pageCount / 40) : 1

        let loop = try PDFVerifyLoop.run(
            document: document,
            faces: PDFTypesetEngine.FaceSet(regular: regular, bold: bold),
            request: request, options: options)

        if isCancelled() { throw Failure.cancelled }

        // 5. 对照报告
        progress(Progress(stage: L("生成报告"), done: 0, total: 1, detail: L("逐段对照原文与译文")))
        let ordered = loop.layouts.keys.sorted().compactMap { loop.layouts[$0] }
        let sections = PDFComparisonReport.sections(
            layouts: ordered, report: loop.report)
        var reportOptions = PDFComparisonReport.Options()
        reportOptions.expandPages = false
        let html = PDFComparisonReport.html(
            sections: sections, report: loop.report, options: reportOptions)

        let translatedCount = loop.report.pages.reduce(0) { $0 + $1.translated }
        let keptCount = loop.report.pages.reduce(0) { $0 + $1.keptOriginal }
        return Outcome(
            pdf: loop.output, reportHTML: html, typeset: loop.report,
            analysis: loop.analysis, translatedBlocks: translatedCount,
            keptBlocks: keptCount, failedBlocks: failed)
    }

}

extension PDFRebuildPipeline {
    /// 消费后端的分片流，拼成一段完整译文；`isCancelled` 为真时立刻停下。
    static func consume(
        _ request: InferenceRequest,
        engine: TranslationEngine,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> String {
        var output = ""
        do {
            for try await piece in await engine.stream(request) {
                if isCancelled() { break }
                if !piece.isFinal { output += piece.text }
            }
        } catch {
            if output.isEmpty {
                return L("［本段翻译失败：%@］", error.localizedDescription)
            }
        }
        return output
    }
}
