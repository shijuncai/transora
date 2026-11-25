import Foundation
import AppKit
import HymnCore

/// PDF 页面的两种处理方式。
enum PDFWorkMode: String, CaseIterable, Identifiable {
    /// 抽出文字译成 TXT/DOCX（版式会丢）
    case text
    /// 译文写回原页面，图片/表格/矢量保持原样
    case layout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return L("纯译文（TXT / DOCX）")
        case .layout: return L("版式重建（PDF）")
        }
    }

    var subtitle: String {
        switch self {
        case .text: return L("只保留文字，便于二次编辑")
        case .layout: return L("译文写回原位置，图片与表格不动")
        }
    }
}

/// 取消标记：跨线程读写，用锁而不是 actor，避免每次取值得跨 actor 跳一次。
final class PDFRebuildCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}

/// 版式重建的界面状态。
struct PDFRebuildStatus: Sendable {
    var isRunning = false
    var stage = ""
    var detail = ""
    var done = 0
    var total = 0
    var error: String?
    var finished = false
    var outputPDF = ""
    var reportHTML = ""
    var translatedBlocks = 0
    var keptBlocks = 0
    var failedBlocks = 0
    var passed = true
    var needsReviewPages = 0
    var elapsedSeconds = 0.0

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
}

@MainActor
extension AppModel {
    /// 开始「版式重建」。翻译逐段串行，主线程只在每段结束时刷一次进度。
    func startRebuildPDF() {
        guard !pdfRebuild.isRunning else { return }
        guard let url = currentPDFURL() else {
            var status = pdfRebuild
            status.error = L("请先选择一份 PDF")
            pdfRebuild = status
            return
        }
        guard isRealInference else {
            var status = pdfRebuild
            status.error = "模型未就绪，请在设置中选择模型目录"
            pdfRebuild = status
            return
        }
        guard PDFRebuildPipeline.fontURLs() != nil else {
            var status = pdfRebuild
            status.error = L("缺少内置字体（LinguaNovaSong-Regular.ttf）")
            pdfRebuild = status
            return
        }

        let flag = PDFRebuildCancelFlag()
        pdfRebuildFlag = flag
        pdfRebuild = PDFRebuildStatus(isRunning: true, stage: L("准备中"),
                                      detail: L("读取文件"), done: 0, total: 0)
        status = L("正在重建 PDF 版式")
        Task { @MainActor in await self.runRebuild(url: url, flag: flag) }
    }

    func cancelRebuildPDF() {
        guard pdfRebuild.isRunning else { return }
        pdfRebuildFlag?.cancel()
        var status = pdfRebuild
        status.stage = L("正在取消")
        status.detail = L("当前段落结束后停止")
        pdfRebuild = status
    }

    func openRebuildPDF() {
        let path = pdfRebuild.outputPDF
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openRebuildReport() {
        let path = pdfRebuild.reportHTML
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealRebuildOutput() {
        let path = pdfRebuild.outputPDF
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - 主流程

    private func runRebuild(url: URL, flag: PDFRebuildCancelFlag) async {
        let started = Date()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            finishRebuild(error: L("读取文件失败：%@", error.localizedDescription))
            return
        }

        let languages = LanguagePair(source: sourceLang, target: targetLang)
        let engineRef = engine
        let progressStore = PDFRebuildProgressStore()

        let (progressStream, progressTx) = AsyncStream<PDFRebuildPipeline.Progress>.makeStream()
        let (resultStream, resultTx) =
            AsyncStream<Result<PDFRebuildPipeline.Outcome, Error>>.makeStream()

        // 重活全部放进后台：结构解析、排版、两次 144dpi 渲染都不该占用主线程
        Task.detached(priority: .userInitiated) {
            do {
                let outcome = try await PDFRebuildPipeline.run(
                    data: data,
                    languages: languages,
                    translate: { request in
                        await PDFRebuildPipeline.consume(
                            request, engine: engineRef,
                            isCancelled: { flag.isCancelled })
                    },
                    isCancelled: { flag.isCancelled },
                    progress: { progress in progressTx.yield(progress) })
                resultTx.yield(.success(outcome))
            } catch {
                resultTx.yield(.failure(error))
            }
            progressTx.finish()
            resultTx.finish()
        }

        let progressTask = Task { @MainActor in
            for await progress in progressStream {
                var status = self.pdfRebuild
                status.stage = progress.stage
                status.detail = progress.detail
                status.done = progress.done
                status.total = progress.total
                self.pdfRebuild = status
                progressStore.latest = progress
            }
        }

        var outcome: PDFRebuildPipeline.Outcome?
        var failure: Error?
        for await result in resultStream {
            switch result {
            case .success(let value): outcome = value
            case .failure(let error): failure = error
            }
        }
        await progressTask.value
        pdfRebuildFlag = nil

        if flag.isCancelled {
            finishRebuild(error: L("已取消（已完成的部分没有写盘）"))
            return
        }
        if let failure {
            finishRebuild(error: failure.localizedDescription)
            return
        }
        guard let outcome else {
            finishRebuild(error: L("没有产出结果"))
            return
        }
        saveRebuild(outcome: outcome, source: url,
                    elapsed: Date().timeIntervalSince(started))
    }

    private func saveRebuild(
        outcome: PDFRebuildPipeline.Outcome, source: URL, elapsed: TimeInterval
    ) {
        let base = source.deletingPathExtension().lastPathComponent
        let directory = Self.rebuildOutputDirectory(preferred: source.deletingLastPathComponent())
        let pdfURL = directory.appendingPathComponent("\(base)-\(L("译文")).pdf")
        let htmlURL = directory.appendingPathComponent("\(base)-\(L("对照报告")).html")
        do {
            try outcome.pdf.write(to: pdfURL)
            try outcome.reportHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
        } catch {
            finishRebuild(error: L("写文件失败：%@", error.localizedDescription))
            return
        }

        var status = pdfRebuild
        status.isRunning = false
        status.finished = true
        status.stage = L("完成")
        status.error = nil
        status.done = status.total
        status.outputPDF = pdfURL.path
        status.reportHTML = htmlURL.path
        status.translatedBlocks = outcome.translatedBlocks
        status.keptBlocks = outcome.keptBlocks
        status.failedBlocks = outcome.failedBlocks
        status.needsReviewPages = outcome.typeset.needsReviewPages.count
        status.passed = (outcome.analysis?.passed ?? true)
        status.elapsedSeconds = elapsed
        status.detail = String(
            format: L("%d 页 · 已译 %d 段 · 保留原文 %d 段 · %.1f 秒"),
            outcome.typeset.pages.count, outcome.translatedBlocks,
            outcome.keptBlocks, elapsed)
        pdfRebuild = status

        self.status = L("版式重建完成")
        refreshData()
    }

    private func finishRebuild(error: String) {
        var status = pdfRebuild
        status.isRunning = false
        status.finished = false
        status.stage = L("未完成")
        status.error = error
        pdfRebuild = status
        self.status = L("版式重建未完成")
    }

    private func currentPDFURL() -> URL? { pdfURL }

    /// 输出目录：优先源文件旁边；不可写就退到「文稿」。
    nonisolated static func rebuildOutputDirectory(preferred: URL) -> URL {
        let manager = FileManager.default
        if manager.isWritableFile(atPath: preferred.path) { return preferred }
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents ?? preferred
    }
}

/// 只用一次的进度快照，避免为「上一次进度」再开一个 @Published。
final class PDFRebuildProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PDFRebuildPipeline.Progress?
    var latest: PDFRebuildPipeline.Progress? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - headless 冒烟

extension AppModel {
    /// 冒烟专用：跑同一套流水线，只翻前 `maxBlocks` 段，结果写到 `/tmp`。
    /// 用于在真实 App 进程里验证「字体找得到、后端能调、排版与自检跑得通」。
    func smokeRebuildPDF(url: URL, maxBlocks: Int) async -> String {
        guard let data = try? Data(contentsOf: url) else { return "READ_FAILED" }
        guard let fonts = PDFRebuildPipeline.fontURLs() else { return "FONT_MISSING" }
        let languages = LanguagePair(source: sourceLang, target: targetLang)
        let engineRef = engine
        do {
            let outcome = try await PDFRebuildPipeline.run(
                data: data, languages: languages,
                translate: { await PDFRebuildPipeline.consume($0, engine: engineRef,
                                                              isCancelled: { false }) },
                isCancelled: { false },
                maxBlocks: maxBlocks,
                progress: { _ in })
            let pdfURL = URL(fileURLWithPath: "/tmp/smoke-rebuild.pdf")
            let htmlURL = URL(fileURLWithPath: "/tmp/smoke-rebuild.html")
            try outcome.pdf.write(to: pdfURL)
            try outcome.reportHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
            var codes: [String: Int] = [:]
            var details: [String] = []
            for page in outcome.analysis?.pages ?? [] {
                for finding in page.findings where finding.severity == .error {
                    codes[finding.code, default: 0] += 1
                    // 只给计数没法定位，把前若干条连页码/块号一起打出来
                    if details.count < 12 {
                        details.append("p\(page.page + 1):\(finding.blockID ?? "?"):\(finding.code)")
                    }
                }
            }
            let codeText = codes.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return "pages=\(outcome.typeset.pages.count) "
                + "translated=\(outcome.translatedBlocks) kept=\(outcome.keptBlocks) "
                + "failed=\(outcome.failedBlocks) pdf_bytes=\(outcome.pdf.count) "
                + "passed=\(outcome.analysis?.passed ?? true) codes=[\(codeText)] "
                + "font=\((fonts.regular.lastPathComponent))"
                + (details.isEmpty ? "" : " findings=[" + details.joined(separator: ",") + "]")
        } catch {
            return "ERROR:\(error.localizedDescription)"
        }
    }
}
