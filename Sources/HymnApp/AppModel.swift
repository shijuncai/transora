import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import HymnCore
import HymnStore
import HymnSTQ

/// 主界面的功能区。PDF 排在历史记录之上（⌘2），顺序与侧栏、视图菜单一致。
enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case translate
    case pdf
    case history
    case glossary
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .translate: return "翻译"
        case .history:   return "历史记录"
        case .glossary:  return "术语库"
        case .settings:  return "设置"
        case .pdf:       return "PDF 翻译"
        }
    }
    var icon: String {
        switch self {
        case .translate: return "character.bubble.zh"
        case .history:   return "clock.arrow.circlepath"
        case .glossary:  return "text.book.closed"
        case .settings:  return "gearshape"
        case .pdf:       return "doc.richtext"
        }
    }
}

/// 用户可见的译文长度档位（内部映射到 maxTokens，界面不暴露技术单位）。
enum TranslationLength: Int, CaseIterable, Identifiable, Sendable {
    case short = 64
    case standard = 128
    case long = 256
    case extraLong = 512

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .short:     return "较短"
        case .standard:  return "标准"
        case .long:      return "较长"
        case .extraLong: return "超长"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: - 运行时状态（内部使用；界面不再常驻展示状态徽标）

    @Published var runtimeStatus: SherryRuntimeStatus
    @Published var isPreparing: Bool = true
    @Published var isRealInference: Bool = false
    @Published var status: String = "正在准备…"
    @Published var errorMessage: String?
    private var activeBackendIdentifier: String = "未初始化"

    // MARK: - 主窗口翻译

    @Published var inputText: String = "Hello, nice to meet you."
    @Published var outputText: String = ""
    @Published var sourceLang: String
    @Published var targetLang: String
    @Published var lengthOption: TranslationLength
    @Published var isRunning: Bool = false
    @Published var lastDurationMs: Int64?

    var maxTokens: Int { lengthOption.rawValue }

    // MARK: - 划词翻译

    @Published var selectionSource: String = ""
    @Published var selectionTranslation: String = ""
    @Published var isSelectionTranslating: Bool = false
    @Published var selectionError: String?
    /// 本次划词**实际**使用的语言对（自动解析，浮窗展示与历史记录都用它）。
    @Published var selectionSourceLang: String = "en"
    @Published var selectionTargetLang: String = "zh"
    /// 辅助功能授权状态：划词捕获依赖它，未授权时界面要明确提示而非静默失效。
    @Published var selectionAccessibilityTrusted: Bool = false
    /// 最近一次划词捕获的诊断（设置页据此给出可操作指引，不主动弹窗）。
    @Published var selectionDiagnosis: SelectionCapture.Diagnosis = .none
    /// 是否正在朗读译文（浮窗扬声器按钮据此切换图标）。
    @Published private(set) var isSelectionSpeaking: Bool = false
    /// 浮窗内的短暂提示（「已存入备忘录」等），2 秒后自动消失。
    @Published private(set) var selectionNotice: String?
    /// 划词浮窗底排按钮的选择（设置页可增删，最多 7 个、至少 1 个）。
    @Published private(set) var selectionActions: SelectionActionPreferences
    private var noticeTask: Task<Void, Never>?
    /// 用于丢弃过期的「提醒事项」请求（连点多次只认最后一次）。
    private var reminderRequestID: UUID?
    private var speechSynthesizer: AVSpeechSynthesizer?
    private var speechWatch: Task<Void, Never>?
    private var selectionGeneration: Int = 0

    // MARK: - 导航与数据

    @Published var selectedSection: AppSection = .translate
    @Published var historySearch: String = ""
    @Published var history: [HistoryRecord] = []
    @Published var terms: [GlossaryEntry] = []
    @Published var newTermSource: String = ""
    @Published var newTermTarget: String = ""
    /// 历史记录多选（不用 @State 宏，统一由 @MainActor ObservableObject 持有）。
    @Published var selectedHistoryIDs: Set<Int64> = []

    // MARK: - PDF 长文本翻译

    @Published var pdfFileName: String = ""
    @Published var pdfPageCount: Int = 0
    @Published var pdfCharacterCount: Int = 0
    @Published var pdfChunkTotal: Int = 0
    @Published var pdfChunkDone: Int = 0
    @Published var pdfIsTranslating: Bool = false
    @Published var pdfStatus: String = ""
    @Published var pdfPreviewText: String = ""
    @Published var pdfErrorMessage: String?

    // 版式重建（P5）：把译文写回原页面，图片/矢量不动
    @Published var pdfWorkMode: PDFWorkMode = .text
    @Published var pdfRebuild = PDFRebuildStatus()
    var pdfRebuildFlag: PDFRebuildCancelFlag?
    var pdfURL: URL?

    private var pdfChunks: [TextChunk] = []
    private var pdfTranslations: [String] = []
    private var pdfCancelled = false
    private var pdfCurrentRequestID: UUID?

    var engine: TranslationEngine
    private let store: SQLiteStore
    private var currentRequestID: UUID?

    private enum PrefKey {
        static let source = "hymn.ui.sourceLang"
        static let target = "hymn.ui.targetLang"
        static let maxTokens = "hymn.ui.maxTokens"
        static let modelDirectory = "hymn.modelDirectory"
        /// 划词浮窗底排按钮（逗号分隔短码，如 `copy,txt,docx,notes,reminders,speak,main`）。
        static let selectionActions = "hymn.selection.actions"
    }

    init() {
        runtimeStatus = SherryRuntimeProbe.status()
        engine = TranslationEngine(backend: SherryBackend())
        let defaults = UserDefaults.standard
        // UI 只提供 14 种常用语言；底层 36 种映射仍保留给 CLI 评测与历史显示。
        // 旧偏好若落在收敛掉的语言上，回退到默认语言，不静默保留不可选项。
        let codes = Set(LanguageCatalog.featuredCodes)
        let savedSource = defaults.string(forKey: PrefKey.source) ?? "en"
        let savedTarget = defaults.string(forKey: PrefKey.target) ?? "zh"
        sourceLang = codes.contains(savedSource) ? savedSource : "en"
        targetLang = codes.contains(savedTarget) ? savedTarget : "zh"
        let savedTokens = defaults.integer(forKey: PrefKey.maxTokens)
        lengthOption = TranslationLength(rawValue: savedTokens) ?? .standard
        // 划词浮窗底排按钮：从未配置过时用出厂 7 个；旧版本遗留的未知短码会被忽略。
        selectionActions = SelectionActionPreferences(
            rawValue: defaults.string(forKey: PrefKey.selectionActions))

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HymnTranslate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaultPath = dir.appendingPathComponent("hymn.db").path
        // 冒烟/自动化可指向临时库，避免把测试记录写进用户的真实历史。
        let override = ProcessInfo.processInfo.environment["HYMN_DB_PATH"] ?? ""
        let path = override.isEmpty ? defaultPath : override
        do {
            store = try SQLiteStore(path: path)
        } catch {
            store = try! SQLiteStore(path: ":memory:")
            status = "本地数据暂不可用，已切换为临时存储"
        }
        selectionAccessibilityTrusted = SelectionCapture.accessibilityTrusted
    }

    /// 启动时只加载一次唯一后端。资源缺失时显式切换到测试替身并给出可操作的修复指引。
    func bootstrap() async {
        isPreparing = true
        let probe = SherryRuntimeProbe.status()
        runtimeStatus = probe

        guard probe.ready else {
            await activateFixture(reason: "未找到本地模型。请在「设置 → 选择模型目录」里指向下载好的模型文件夹，"
                + "然后点「重新检测」。当前处于演示模式，输出不是译文。")
            isPreparing = false
            refreshData()
            return
        }

        do {
            try await engine.prepare()
            isRealInference = await engine.isRealInference()
            activeBackendIdentifier = await engine.backendIdentifier()
            errorMessage = nil
            // 就绪是常态，不再常驻显示「已就绪」；只在异常时给出可操作提示。
            status = isRealInference ? "" : "模型未就绪"
        } catch {
            await activateFixture(reason: "模型加载失败，请在「设置」里重新选择模型目录并重试。\(error)")
        }
        isPreparing = false
        refreshData()
    }

    func retryPreparation() async {
        await engine.shutdown()
        engine = TranslationEngine(backend: SherryBackend())
        isRealInference = false
        activeBackendIdentifier = "未初始化"
        await bootstrap()
    }

    private func activateFixture(reason: String) async {
        await engine.shutdown()
        let fixture = TranslationEngine(
            backend: FixtureBackend(tokenCount: 24, tokenDelayNanos: 1_200_000))
        try? await fixture.prepare()
        engine = fixture
        isRealInference = false
        activeBackendIdentifier = await fixture.backendIdentifier()
        status = "模型未就绪"
        errorMessage = reason
    }

    /// 分发版首次启动：让用户指向自己下载的模型目录。
    func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "请选择下载好的模型文件夹（选择后即可开始使用）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: PrefKey.modelDirectory)
        Task { await retryPreparation() }
    }

    // MARK: - 主窗口翻译

    func translate() async {
        guard !isRunning, !isPreparing else { return }
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "请先输入要翻译的文本"
            return
        }
        guard isRealInference else {
            status = "模型未就绪，请在设置中选择模型目录"
            return
        }
        isRunning = true
        outputText = ""
        lastDurationMs = nil
        status = "翻译中…"
        savePreferences()

        let languages = LanguagePair(source: sourceLang, target: targetLang)
        let matcher = GlossaryMatcher(entries: terms)
        let req = InferenceRequest(
            text: inputText, languages: languages, maxTokens: maxTokens,
            glossaryHints: matcher.hints(for: inputText, languages: languages))
        currentRequestID = req.id
        let start = DispatchTime.now().uptimeNanoseconds
        var assembled = ""
        var cancelled = false
        do {
            for try await chunk in await engine.stream(req) {
                if chunk.isFinal { continue }
                assembled += chunk.text
                outputText = assembled
            }
        } catch let failure as HymnFailure where failure.code == "CANCELLED" {
            cancelled = true
        } catch {
            errorMessage = "翻译失败，请稍后重试。\(error)"
        }
        let elapsedMs = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        lastDurationMs = elapsedMs
        status = cancelled ? "已取消" : "翻译完成"
        isRunning = false
        currentRequestID = nil

        let record = HistoryRecord(
            requestID: req.id.uuidString, sourceLang: sourceLang, targetLang: targetLang,
            sourceText: inputText, targetText: assembled,
            durationMs: elapsedMs, tokenCount: 0, cancelled: cancelled,
            modelTag: isRealInference
                ? "\(activeBackendIdentifier) (REAL INFERENCE, STQ1_0, NOT LUT4)"
                : "\(activeBackendIdentifier) (TEST DOUBLE, 非模型推理)")
        Task.detached(priority: .utility) { [store] in
            _ = try? store.insertHistory(record)
        }
        refreshData()
    }

    func cancelCurrent() async {
        guard let id = currentRequestID else { return }
        await engine.cancel(id: id)
    }

    func swapLanguages() {
        let oldSource = sourceLang, oldInput = inputText
        sourceLang = targetLang
        targetLang = oldSource
        if !outputText.isEmpty {
            inputText = outputText
            outputText = oldInput
        }
        savePreferences()
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        status = "译文已复制"
    }

    func clearTexts() {
        inputText = ""
        outputText = ""
        status = "已清空"
    }

    // MARK: - 划词翻译

    /// 划词后的独立翻译链路：不覆盖主窗口输入/输出，用 generation 丢弃过期结果。
    ///
    /// 语言对按选区书写系统自动解析：主窗口设 `en→zh` 时划到中文，
    /// 过去会要求模型「翻译成简体中文」而原样照抄；现在改为 `zh→en`。
    func translateSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 新一次划词优先：上一段译文的朗读立即停止，旧提示也一并清掉。
        stopSelectionSpeech()
        selectionNotice = nil
        noticeTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionSource = trimmed
        selectionTranslation = ""
        selectionError = nil
        isSelectionTranslating = true
        refreshAccessibilityStatus()

        let pair = SelectionLanguageResolver.resolve(
            text: trimmed, preferredSource: sourceLang, preferredTarget: targetLang)
        selectionSourceLang = pair.source
        selectionTargetLang = pair.target

        guard isRealInference else {
            selectionError = "模型未就绪，请在设置中选择模型目录"
            isSelectionTranslating = false
            return
        }
        let languages = LanguagePair(source: pair.source, target: pair.target)
        let budget = SelectionLanguageResolver.suggestedMaxTokens(
            for: trimmed, base: maxTokens)
        let req = InferenceRequest(text: trimmed, languages: languages, maxTokens: budget)
        Task { @MainActor in
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                for try await chunk in await engine.stream(req) {
                    if generation != selectionGeneration { return }
                    if !chunk.isFinal { selectionTranslation += chunk.text }
                }
            } catch {
                if generation == selectionGeneration { selectionError = "翻译失败，请重试" }
            }
            guard generation == selectionGeneration else { return }
            isSelectionTranslating = false
            let elapsedMs = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let record = HistoryRecord(
                requestID: req.id.uuidString, sourceLang: pair.source, targetLang: pair.target,
                sourceText: trimmed, targetText: selectionTranslation,
                durationMs: elapsedMs, tokenCount: 0, cancelled: false,
                modelTag: "\(activeBackendIdentifier) (SELECTION, STQ1_0, NOT LUT4)")
            Task.detached(priority: .utility) { [store] in
                _ = try? store.insertHistory(record)
            }
            refreshData()
        }
    }

    /// 实时刷新辅助功能授权状态（用户可能在系统设置里刚授权，无需重启 App）。
    func refreshAccessibilityStatus() {
        selectionAccessibilityTrusted = SelectionCapture.accessibilityTrusted
        selectionDiagnosis = SelectionCapture.lastDiagnosis
    }

    /// 打开系统「隐私与安全性 → 辅助功能」面板（用户主动点击，不自动弹框）。
    func openAccessibilitySettings() {
        SelectionCapture.openAccessibilitySettings()
    }

    /// 弹出系统授权引导；用户授权后再次划词即生效。
    func requestAccessibility() {
        SelectionCapture.promptAccessibility()
        refreshAccessibilityStatus()
    }

    func copySelectionTranslation() {
        guard !selectionTranslation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectionTranslation, forType: .string)
    }

    // MARK: - 划词浮窗底部按钮（设置页可增删）

    /// 打开 / 关闭底排的一个动作。上限 7 个、下限 1 个，越界时只给一句状态提示，
    /// 不改动偏好（避免出现「点了没反应、下次启动又变回来」的错觉）。
    func toggleSelectionAction(_ id: SelectionActionID) {
        let next = selectionActions.toggled(id)
        guard next != selectionActions else {
            if selectionActions.contains(id) {
                status = "划词面板至少保留 \(SelectionActionPreferences.minCount) 个按钮"
            } else {
                status = "划词面板最多 \(SelectionActionPreferences.maxCount) 个按钮"
            }
            return
        }
        selectionActions = next
        UserDefaults.standard.set(next.serialized, forKey: PrefKey.selectionActions)
        status = next.contains(id) ? "已加入「\(id.title)」" : "已移除「\(id.title)」"
    }

    func resetSelectionActions() {
        let factory = SelectionActionPreferences(
            ordered: SelectionActionPreferences.defaultOrder)
        selectionActions = factory
        UserDefaults.standard.set(factory.serialized, forKey: PrefKey.selectionActions)
        status = "划词面板按钮已恢复默认"
    }

    /// 网页动作（Bing / Google / 微博 / 淘宝）：把译文放进查询串，用默认浏览器打开。
    ///
    /// 这四个动作会把译文带出本机，属于用户主动点击才发生的行为；
    /// 翻译本身仍然全程离线。返回是否真的打开了浏览器。
    @discardableResult
    func openSelectionWebAction(_ id: SelectionActionID) -> Bool {
        guard let url = id.webURL(for: selectionTranslation) else {
            status = "还没有可搜索的译文"
            return false
        }
        // 微博分享页在未登录的浏览器里会先跳到登录页，`title` 参数可能随之丢失。
        // 顺手把译文放进剪贴板：登录后直接粘贴即可（是用户主动点「发送微博」，不算抢剪贴板）。
        if id == .shareWeibo {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectionTranslation, forType: .string)
        }
        actionDebug("web action \(id.rawValue) chars=\(url.absoluteString.count)")
        let opened = NSWorkspace.shared.open(url)
        if opened {
            status = id == .shareWeibo ? "已复制译文并打开微博" : "已在浏览器打开「\(id.title)」"
        } else {
            status = "无法打开默认浏览器"
        }
        return opened
    }

    // MARK: - 存入系统 App（备忘录 / 提醒事项）

    /// 新建一条备忘录：标题取译文首行，正文含原文与译文。
    /// 走「写临时文件 → 备忘录导入」的方式，不需要「自动化」授权。
    func saveSelectionToNotes() {
        guard !selectionTranslation.isEmpty else { return }
        let pair = "\(languageDisplayName(selectionSourceLang)) → "
            + "\(languageDisplayName(selectionTargetLang))"
        let title = SelectionShareFormat.title(from: selectionTranslation, limit: 40)
        let body = SelectionShareFormat.plainBody(
            source: selectionSource, translation: selectionTranslation, pair: pair)
        SystemAppBridge.addNote(title: title, body: body) { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    self.actionDebug("notes failed \(failure)")
                    self.showSelectionNotice("备忘录导入失败")
                } else {
                    self.actionDebug("notes saved title=\(title)")
                    self.showSelectionNotice("已存入备忘录")
                }
            }
        }
    }

    /// 新建一条提醒事项：名称取译文首行，备注含原文与译文。
    /// 走 EventKit（标准「提醒事项」隐私授权），与「自动化」无关。
    func saveSelectionToReminders() {
        guard !selectionTranslation.isEmpty else { return }
        let pair = "\(languageDisplayName(selectionSourceLang)) → "
            + "\(languageDisplayName(selectionTargetLang))"
        let title = SelectionShareFormat.title(from: selectionTranslation, limit: 100)
        let body = SelectionShareFormat.plainBody(
            source: selectionSource, translation: selectionTranslation, pair: pair)
        reminderRequestID = UUID()
        let requestID = reminderRequestID
        Task { @MainActor in
            // 兜底：授权框没能弹出来时 `requestFullAccessToReminders` 会一直挂着，
            // 不能让用户点了没反应，12 秒后给一句可操作的提示。
            let watchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, self.reminderRequestID == requestID else { return }
                self.actionDebug("reminder timeout")
                self.showSelectionNotice("提醒事项需授权")
            }
            defer { watchdog.cancel() }
            do {
                try await SystemAppBridge.addReminder(title: title, body: body)
                guard self.reminderRequestID == requestID else { return }
                showSelectionNotice("已加入提醒事项")
                actionDebug("reminder saved title=\(title)")
            } catch {
                guard self.reminderRequestID == requestID else { return }
                actionDebug("reminder failed \(error)")
                showSelectionNotice(Self.noticeText(for: error, app: "提醒事项"))
            }
        }
    }

    /// 失败提示要短到能塞进语言标签那个胶囊里，同时保留可操作信息。
    private static func noticeText(for error: Error, app: String) -> String {
        if let bridge = error as? SystemAppBridge.BridgeError, bridge.isNotAuthorized {
            return "需授权「\(app)」"
        }
        return "\(app) 存入失败"
    }

    private func showSelectionNotice(_ text: String) {
        selectionNotice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self.selectionNotice = nil
        }
    }

    // MARK: - 译文朗读（AVSpeechSynthesizer，系统语音、离线）

    /// 朗读划词译文；正在朗读时再次点击即停止。
    func toggleSelectionSpeech() {
        let text = selectionTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSelectionSpeaking {
            stopSelectionSpeech()
            return
        }
        stopSelectionSpeech()

        let synthesizer = self.speechSynthesizer ?? {
            let made = AVSpeechSynthesizer()
            self.speechSynthesizer = made
            return made
        }()
        let utterance = AVSpeechUtterance(string: text)
        // 用译文的目标语言选音色，而不是原文语言：读的是译文。
        utterance.voice = Self.speechVoice(for: selectionTargetLang)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
        isSelectionSpeaking = true
        speechDebug("speech start lang=\(selectionTargetLang) "
                    + "voice=\(utterance.voice?.identifier ?? "system-default") "
                    + "chars=\(text.count)")
        watchSpeechCompletion()
    }

    func stopSelectionSpeech() {
        speechWatch?.cancel()
        speechWatch = nil
        // stopSpeaking 会触发 didCancel；这里只关心状态复位，不依赖回调。
        speechSynthesizer?.stopSpeaking(at: .immediate)
        isSelectionSpeaking = false
    }

    /// 轮询合成器状态以复位「正在朗读」图标。
    ///
    /// 不用 `AVSpeechSynthesizerDelegate`：`stopSpeaking` 的 `didCancel` 是异步的，
    /// 与紧接着的下一次 `speak` 存在竞态，会让图标在刚开始朗读时就被复位。
    private func watchSpeechCompletion() {
        speechWatch?.cancel()
        speechWatch = Task { @MainActor [weak self] in
            var started = false
            var idleTicks = 0
            while true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                guard let self, let synthesizer = self.speechSynthesizer else { return }
                if synthesizer.isSpeaking {
                    if !started {
                        self.speechDebug("speech speaking")
                    }
                    started = true
                    idleTicks = 0
                    continue
                }
                idleTicks += 1
                // 已开始 → 播完了；未开始 → 给 3 秒启动宽限，避免开头瞬间误判。
                if started || idleTicks > 15 {
                    self.speechDebug(started ? "speech finished" : "speech never started")
                    self.isSelectionSpeaking = false
                    return
                }
            }
        }
    }

    /// 目标语言 → 系统语音。找不到精确音色时按语言前缀兜底（如 zh-TW 代替 zh-CN）。
    private static func speechVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {        let bcp47: [String: String] = [
            "zh": "zh-CN", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR",
            "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "pt": "pt-PT",
            "ru": "ru-RU", "it": "it-IT", "ar": "ar-SA", "th": "th-TH",
            "vi": "vi-VN", "id": "id-ID",
        ]
        let code = languageCode.lowercased()
        if let exact = AVSpeechSynthesisVoice(language: bcp47[code] ?? code) {
            return exact
        }
        let prefix = String(code.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.language.lowercased().hasPrefix(prefix)
        }
    }

    /// 朗读诊断（默认关闭，`HYMN_SELECTION_DEBUG=1` 时输出）。
    private func speechDebug(_ message: String) {
        guard ProcessInfo.processInfo.environment["HYMN_SELECTION_DEBUG"] == "1" else { return }
        print("[speech] \(message)")
        fflush(stdout)
    }

    /// 诊断：区分「用户点了扬声器」与「其它路径要求朗读」。
    func noteSelectionSpeechTapped() {
        speechDebug("button tapped")
    }

    /// 存入备忘录 / 提醒事项的诊断（`HYMN_SELECTION_DEBUG=1` 时输出）。
    private func actionDebug(_ message: String) {
        guard ProcessInfo.processInfo.environment["HYMN_SELECTION_DEBUG"] == "1" else { return }
        print("[action] \(message)")
        fflush(stdout)
    }

    func openSelectionInMain() {
        guard !selectionSource.isEmpty else { return }
        inputText = selectionSource
        outputText = selectionTranslation
        selectedSection = .translate
    }

    // MARK: - 数据

    func loadFromHistory(_ record: HistoryRecord) {
        inputText = record.sourceText
        outputText = record.targetText
        sourceLang = record.sourceLang
        targetLang = record.targetLang
        selectedSection = .translate
        savePreferences()
        status = "已从历史记录载入"
    }

    func deleteHistory(_ record: HistoryRecord) {
        try? store.deleteHistory(id: record.id)
        refreshData()
    }

    func deleteTerm(_ term: GlossaryEntry) {
        try? store.deleteTerm(id: term.id)
        refreshData()
    }

    func addTerm(source: String, target: String) {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        _ = try? store.upsertTerm(source: s, target: t,
                                  languages: LanguagePair(source: sourceLang, target: targetLang))
        newTermSource = ""
        newTermTarget = ""
        refreshData()
    }

    func clearAllData() {
        try? store.clearAll()
        refreshData()
        status = "本地数据已清空"
    }

    func refreshData() {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        history = (try? store.fetchHistory(limit: 200, search: query.isEmpty ? nil : query)) ?? []
        terms = (try? store.fetchTerms(languages: LanguagePair(source: sourceLang, target: targetLang))) ?? []
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(sourceLang, forKey: PrefKey.source)
        defaults.set(targetLang, forKey: PrefKey.target)
        defaults.set(lengthOption.rawValue, forKey: PrefKey.maxTokens)
    }

    // MARK: - 导出（划词 / 历史 / PDF 共用同一套文档写出）

    private func handleExport(_ outcome: DocumentExportOutcome) {
        switch outcome {
        case .saved(let url): status = "已保存：\(url.lastPathComponent)"
        case .cancelled: break
        case .failed(let message): status = "保存失败：\(message)"
        }
    }

    func exportSelection(_ format: DocumentExportFormat) {
        guard !selectionSource.isEmpty else {
            status = "还没有可保存的划词内容"
            return
        }
        let document = TranslationDocument(
            title: "划词译文",
            subtitle: "\(AppBrand.fullName) · \(languageDisplayName(sourceLang)) → \(languageDisplayName(targetLang))",
            items: [.init(heading: "划词内容",
                          source: selectionSource,
                          translation: selectionTranslation.isEmpty
                              ? "（译文尚未生成）" : selectionTranslation)])
        handleExport(DocumentExporter.save(
            document, suggestedName: "划词译文", format: format))
    }

    /// 单条与多条合并走同一路径：1 条即单条导出，多条按顺序合并成一个文件。
    func exportHistoryRecords(_ records: [HistoryRecord], format: DocumentExportFormat) {
        guard !records.isEmpty else { return }
        let items = records.enumerated().map { index, record in
            TranslationDocument.Item(
                heading: "第 \(index + 1) 条 · \(languageDisplayName(record.sourceLang))"
                    + " → \(languageDisplayName(record.targetLang))",
                source: record.sourceText,
                translation: record.targetText.isEmpty ? "（无译文）" : record.targetText,
                note: "记录 #\(record.id) · "
                    + Date(timeIntervalSince1970: Double(record.createdAt) / 1000)
                        .formatted(date: .abbreviated, time: .shortened))
        }
        let document = TranslationDocument(
            title: records.count == 1 ? "翻译记录" : "翻译记录（\(records.count) 条合并）",
            subtitle: "\(AppBrand.fullName) · 本机导出 · 不上传",
            items: items)
        let name = records.count == 1 ? "翻译记录" : "翻译记录-\(records.count)条"
        handleExport(DocumentExporter.save(document, suggestedName: name, format: format))
    }

    func exportSelectedHistory(_ format: DocumentExportFormat) {
        let chosen = history.filter { selectedHistoryIDs.contains($0.id) }
        exportHistoryRecords(chosen, format: format)
    }

    // MARK: - PDF 长文本翻译

    func choosePDF() {
        guard !pdfIsTranslating else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要翻译的 PDF（支持几百页，按页分块串行翻译）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pdfURL = url
        do {
            let result = try PDFTextExtractor.extract(url: url)
            pdfFileName = result.fileName
            pdfPageCount = result.pageCount
            pdfCharacterCount = result.characterCount
            pdfChunks = TextChunker.chunks(pages: result.pages, maxChars: 600)
            pdfTranslations = []
            pdfChunkTotal = pdfChunks.count
            pdfChunkDone = 0
            pdfPreviewText = ""
            pdfErrorMessage = nil
            pdfStatus = "已载入 \(result.pageCount) 页 / \(result.characterCount) 字，"
                + "分为 \(pdfChunks.count) 段；长文档耗时较长，可随时取消。"
        } catch {
            pdfErrorMessage = error.localizedDescription
            pdfStatus = "无法读取 PDF"
            pdfChunks = []
            pdfChunkTotal = 0
            pdfChunkDone = 0
        }
    }

    func startPDFTranslation() {
        guard !pdfIsTranslating, !pdfChunks.isEmpty else { return }
        guard isRealInference else {
            pdfErrorMessage = "模型未就绪，请在设置中选择模型目录"
            return
        }
        pdfCancelled = false
        pdfIsTranslating = true
        pdfTranslations = Array(repeating: "", count: pdfChunks.count)
        pdfChunkDone = 0
        pdfPreviewText = ""
        pdfErrorMessage = nil
        pdfStatus = "正在翻译…"
        Task { @MainActor in await self.runPDFTranslation() }
    }

    /// 串行逐块翻译：单实例调度不并发，主线程只在每块结束后更新一次进度。
    private func runPDFTranslation() async {
        let chunks = pdfChunks
        let languages = LanguagePair(source: sourceLang, target: targetLang)
        let start = DispatchTime.now().uptimeNanoseconds
        for (index, chunk) in chunks.enumerated() {
            if pdfCancelled { break }
            let req = InferenceRequest(
                text: chunk.text, languages: languages, maxTokens: 512)
            pdfCurrentRequestID = req.id
            var translated = ""
            do {
                for try await piece in await engine.stream(req) {
                    if pdfCancelled { break }
                    if !piece.isFinal { translated += piece.text }
                }
            } catch {
                translated = "［本段翻译失败：\(error)］"
            }
            if pdfCancelled { break }
            pdfTranslations[index] = translated
            pdfChunkDone = index + 1
            pdfPreviewText = makePDFPreview()
            pdfStatus = "已完成 \(index + 1) / \(chunks.count) 段"
        }
        pdfCurrentRequestID = nil
        pdfIsTranslating = false
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        if pdfCancelled {
            pdfStatus = "已在第 \(pdfChunkDone) / \(chunks.count) 段取消"
            status = "PDF 翻译已取消"
        } else {
            pdfStatus = String(format: "翻译完成 · %d 段 · 用时 %.1f 分钟",
                               chunks.count, Double(elapsed) / 60_000)
            status = "PDF 翻译完成"
            recordPDFToHistory(elapsedMs: elapsed)
        }
    }

    func cancelPDFTranslation() {
        guard pdfIsTranslating else { return }
        pdfCancelled = true
        let id = pdfCurrentRequestID
        pdfStatus = "正在取消…"
        if let id {
            Task { @MainActor in await engine.cancel(id: id) }
        }
    }

    private func recordPDFToHistory(elapsedMs: Int64) {
        let record = HistoryRecord(
            sourceLang: sourceLang, targetLang: targetLang,
            sourceText: "[PDF] \(pdfFileName)（\(pdfPageCount) 页 / \(pdfChunkTotal) 段）",
            targetText: makePDFPreview(),
            durationMs: elapsedMs, tokenCount: 0, cancelled: false,
            modelTag: "\(activeBackendIdentifier) (PDF, STQ1_0, NOT LUT4)")
        Task.detached(priority: .utility) { [store] in
            _ = try? store.insertHistory(record)
        }
        refreshData()
    }

    /// 预览只保留最近若干段并限制长度，避免几百页译文反复触发大字符串重绘。
    private func makePDFPreview() -> String {
        var parts: [String] = []
        let start = max(0, pdfChunkDone - 4)
        for index in start..<min(pdfChunkDone, pdfTranslations.count) {
            let chunk = pdfChunks[index]
            let text = pdfTranslations[index]
            if text.isEmpty { continue }
            parts.append("【第 \(chunk.pageStart) 页 · 第 \(index + 1) 段】\n\(text)")
        }
        let joined = parts.joined(separator: "\n\n")
        return String(joined.suffix(6_000))
    }

    private func makePDFDocument() -> TranslationDocument {
        var items: [TranslationDocument.Item] = []
        for (index, chunk) in pdfChunks.enumerated() {
            let translated = index < pdfTranslations.count ? pdfTranslations[index] : ""
            guard !translated.isEmpty else { continue }
            items.append(.init(
                heading: "第 \(chunk.pageStart) 页 · 第 \(index + 1) 段",
                source: chunk.text,
                translation: translated,
                note: "\(languageDisplayName(sourceLang)) → \(languageDisplayName(targetLang))"))
        }
        return TranslationDocument(
            title: "\(pdfFileName) · 译文",
            subtitle: "\(AppBrand.fullName) · 本机翻译 · 共 \(pdfPageCount) 页 / \(pdfChunkTotal) 段",
            items: items)
    }

    func exportPDFTranslation(_ format: DocumentExportFormat) {
        let document = makePDFDocument()
        guard !document.items.isEmpty else {
            status = "还没有可导出的 PDF 译文"
            return
        }
        let base = (pdfFileName as NSString).deletingPathExtension
        handleExport(DocumentExporter.save(
            document, suggestedName: "\(base)-译文", format: format))
    }

    /// headless 冒烟专用：走同一条「PDFKit 提取 → 分块 → 真实推理 → DOCX 写出」链路，
    /// 只跑前 `limit` 段，不改动 UI 状态，也不打开任何面板。
    func smokeTranslatePDF(url: URL, limit: Int) async -> String {
        guard let extracted = try? PDFTextExtractor.extract(url: url) else {
            return "PDF_EXTRACT_FAILED"
        }
        let chunks = TextChunker.chunks(pages: extracted.pages, maxChars: 600)
        guard !chunks.isEmpty else { return "PDF_NO_CHUNKS" }
        let languages = LanguagePair(source: sourceLang, target: targetLang)
        var outputs: [String] = []
        for chunk in chunks.prefix(max(1, limit)) {
            let req = InferenceRequest(
                text: chunk.text, languages: languages, maxTokens: 128)
            var text = ""
            do {
                for try await piece in await engine.stream(req) {
                    if !piece.isFinal { text += piece.text }
                }
            } catch {
                text = "ERROR:\(error)"
            }
            outputs.append(text)
        }
        let document = TranslationDocument(
            title: "PDF smoke",
            items: [.init(heading: "第 1 页",
                          source: chunks[0].text,
                          translation: outputs.first ?? "")])
        let docxBytes = (try? TranslationDocumentWriter.docxData(document))?.count ?? 0
        let txtBytes = TranslationDocumentWriter.txtData(document).count
        return "pages=\(extracted.pageCount) chars=\(extracted.characterCount) "
            + "chunks=\(chunks.count) ran=\(outputs.count) "
            + "first=\(outputs.first?.prefix(30).replacingOccurrences(of: "\n", with: " ") ?? "") "
            + "docx_bytes=\(docxBytes) txt_bytes=\(txtBytes)"
    }
}
