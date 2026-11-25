import Foundation
import HymnCore

/// 界面语言。
///
/// 产品只有中文和英文两套界面；`system` 表示跟随系统首选语言，
/// 系统首选不是中文时落到英文。翻译语言（36 种）与界面语言是两回事，
/// 不要混用 `LanguageCatalog` 的 code。
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese
    case english

    public var id: String { rawValue }

    /// 设置页下拉里显示的名字：永远用该语言自己的写法，切换界面语言后仍认得出。
    public var nativeName: String {
        switch self {
        case .system:  return L("跟随系统")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// 实际生效的界面语言（`system` 解析后的结果）。
public enum ResolvedLanguage: String, Sendable {
    case chinese
    case english
}

/// 语言代码 → 英文名。界面语言为英文时，语言下拉与历史记录都用这套名字；
/// 中文界面仍以 `LanguageCatalog.chineseName` 为准（那是模型训练用的措辞）。
enum LanguageNames {
    static let english: [String: String] = [
        "zh": "Chinese", "en": "English", "fr": "French", "pt": "Portuguese",
        "es": "Spanish", "ja": "Japanese", "tr": "Turkish", "ru": "Russian",
        "ar": "Arabic", "ko": "Korean", "th": "Thai", "it": "Italian",
        "de": "German", "vi": "Vietnamese", "ms": "Malay", "id": "Indonesian",
        "tl": "Filipino", "hi": "Hindi", "pl": "Polish", "cs": "Czech",
        "nl": "Dutch", "km": "Khmer", "my": "Burmese", "fa": "Persian",
        "gu": "Gujarati", "ur": "Urdu", "te": "Telugu", "mr": "Marathi",
        "he": "Hebrew", "bn": "Bengali", "ta": "Tamil", "uk": "Ukrainian",
        "bo": "Tibetan", "kk": "Kazakh", "mn": "Mongolian", "ug": "Uyghur",
    ]

    /// 语言对胶囊里的短标签：中文界面沿用单字（中/英），英文界面用大写代码。
    static func shortLabel(for code: String) -> String {
        if L10n.current == .english { return code.uppercased() }
        return LanguageCatalog.shortLabel(for: code)
    }
}

/// 全量英文文案。key 就是中文原文，value 是英文译文。
///
/// 用中文原文当 key 有两个好处：改动文案时漏译会直接回退成中文（不会显示成
/// `settings.title` 这种键名），以及看代码时一眼能对上界面。带 `%@`/`%d` 的是
/// `String(format:)` 模板，参数顺序必须与调用点一致。
/// `Scripts/check-localization.sh` 会校验代码里出现的每个 key 都有译文。
enum LocalizationTable {
    static let english: [String: String] = [
        // MARK: 通用
        "跟随系统": "Follow system",
        "本机 AI 翻译": "On-device AI translation",
        "所有翻译在本机完成，文本不会离开这台 Mac。": "All translation happens on this Mac. Your text never leaves it.",
        "Apple Silicon 本机离线推理 · 无需联网": "On-device inference on Apple Silicon · no network needed",
        "版本 %@": "Version %@",
        "版本 %@ · %@": "Version %@ · %@",
        "%d 字符": "%d characters",
        "%d 条": "%d items",
        "%d 页": "%d pages",
        "上次 %.1f 秒": "Last %.1f s",
        "上次用时 %.1f 秒": "Last run %.1f s",
        " · 用时 %.1f 秒": " · %.1f s",
        "完成": "Done",
        "取消": "Cancel",
        "选择": "Choose",
        "添加": "Add",
        "刷新": "Refresh",
        "通过": "Passed",

        // MARK: 侧栏与页头
        "工作区": "Workspace",
        "翻译": "Translate",
        "PDF 翻译": "PDF",
        "历史记录": "History",
        "术语库": "Glossary",
        "设置": "Settings",
        "设置…": "Settings…",
        "关于": "About",
        "关于%@": "About %@",
        "打开%@": "Open %@",
        "退出%@": "Quit %@",
        "编辑": "Edit",
        "视图": "View",
        "撤销": "Undo",
        "重做": "Redo",
        "剪切": "Cut",
        "复制": "Copy",
        "粘贴": "Paste",
        "全选": "Select All",
        "划词即译，长PDF翻译": "Select to translate, long PDFs",
        "选中文字，译文随手可得": "Select text, get the translation",
        "文本只留在这台 Mac": "Text never leaves this Mac",
        "偏好设置与本地数据管理": "Preferences and local data",
        "支持 14 种常用语言 · 划词即译 · PDF 长文翻译": "14 common languages · select to translate · long PDFs",
        "重新选择": "Choose again",
        "界面": "Interface",
        "界面语言": "Interface language",
        "切到 English 后菜单、设置与提示都用英文；翻译语言对不受影响。": "Switching to English changes menus, settings and messages; translation languages are unaffected.",

        // MARK: 翻译页
        "原文": "Source",
        "译文": "Translation",
        "源语言": "From",
        "目标语言": "To",
        "支持 14 种常用语言 · 长文与划词都能译": "14 common languages · long text and selection",
        "输入或粘贴要翻译的文本…": "Type or paste text to translate…",
        "正在生成译文…": "Generating…",
        "译文将在这里逐字出现": "The translation appears here as it streams",
        "请先完成初始设置": "Finish setup first",
        "翻译中…": "Translating…",
        "开始翻译": "Translate",
        "↵ 开始翻译": "↵ Translate",
        "交换语言": "Swap languages",
        "交换语言（并把译文放回输入框）": "Swap languages (and move the translation into the input)",
        "取消当前翻译": "Cancel translation",
        "复制译文": "Copy translation",
        "清空输入与译文": "Clear input and translation",
        "重新检测模型": "Re-check model",
        "划词翻译 开/关": "Toggle selection translation",
        "重新检测": "Re-check",
        "选择后自动检测": "Checked automatically",
        "准备就绪": "Ready",
        "正在准备…": "Preparing…",
        "未初始化": "Not initialised",
        "模型未就绪": "Model not ready",
        "模型未就绪，请在设置中选择模型目录": "Model not ready. Choose a model folder in Settings.",
        "请先输入要翻译的文本": "Enter some text first",
        "译文已复制": "Translation copied",
        "已清空": "Cleared",
        "翻译完成": "Translation finished",
        "已取消": "Cancelled",
        "翻译失败，请重试": "Translation failed, try again",
        "翻译失败，请稍后重试。%@": "Translation failed. Try again later. %@",
        "本地数据暂不可用，已切换为临时存储": "Local storage unavailable; using temporary storage",
        "本地数据已清空": "Local data cleared",
        "已从历史记录载入": "Loaded from history",
        "载入到翻译页": "Load into Translate",
        "未找到本地模型。请在「设置 → 选择模型目录」里指向下载好的模型文件夹，然后点「重新检测」。当前处于演示模式，输出不是译文。": "No model found. Point Settings → Choose model folder at the downloaded folder, then click Re-check. Demo mode is active; output is not a real translation.",
        "模型加载失败，请在「设置」里重新选择模型目录并重试。%@": "Model failed to load. Choose the model folder again in Settings and retry. %@",
        "选择模型文件夹…": "Choose model folder…",
        "请选择下载好的模型文件夹（选择后即可开始使用）": "Choose the downloaded model folder to get started",
        "首次使用需要指定本机模型文件夹，之后即可开始翻译。": "Point the app at a local model folder once, then you can translate.",

        // MARK: 译文长度
        "较短": "Short",
        "标准": "Standard",
        "较长": "Long",
        "超长": "Longest",
        "译文长度": "Length",
        "文本较长时可以选择「较长」或「超长」，翻译耗时会相应增加。": "For long text pick Long or Longest; it takes proportionally longer.",
        "翻译偏好": "Translation",
        "初始设置": "Getting started",

        // MARK: 历史记录
        "所有翻译仅保存在本机，不会上传": "Everything stays on this Mac; nothing is uploaded",
        "搜索原文或译文": "Search source or translation",
        "导出所选为 %@": "Export %@",
        "按住 ⌘ 或 ⇧ 可多选": "Hold ⌘ or ⇧ to select several",
        "已选 %d 条": "%d selected",
        "（无译文）": "(no translation)",
        "导出这条记录": "Export this entry",
        "删除这条记录": "Delete this entry",
        "完整译文请导出 TXT 或 DOCX": "Export TXT or DOCX for the full translation",
        "还没有翻译记录": "No translations yet",
        "没有匹配的记录": "No matching entries",
        "完成一次翻译后会自动出现在这里": "Finished translations show up here automatically",
        "换个关键词试试": "Try another keyword",
        "还没有可搜索的译文": "No translations to search yet",
        "译文会在这里显示最近几段": "Recent passages appear here",
        "取消选择": "Clear selection",
        "清空全部": "Clear all",
        "清空本地数据": "Clear local data",
        "本地数据": "Local data",
        "历史记录与术语库保存在这台 Mac 上，可随时清空。": "History and glossary live on this Mac and can be cleared at any time.",
        "历史 %d 条 · 当前语言对术语 %d 条": "%d history entries · %d terms for this language pair",
        "在访达中显示": "Show in Finder",

        // MARK: 术语库
        "为当前语言对指定固定译法，翻译时自动遵循": "Pin translations for the current language pair; they are applied automatically",
        "添加术语": "Add term",
        "源术语": "Source term",
        "目标译法": "Target term",
        "当前语言对：%@ → %@": "Current pair: %@ → %@",
        "该语言对暂无术语": "No terms for this pair yet",
        "添加后，翻译会优先遵循这些译法": "Once added, translations follow them",

        // MARK: 划词
        "划词翻译": "Selection translation",
        "划词翻译：开启": "Selection translation: on",
        "划词翻译：关闭": "Selection translation: off",
        "划词输出语言": "Selection output language",
        "自动判断": "Automatic",
        "自动判断：选中英文译成中文、选中中文译成英文；指定语言后，划词固定译成该语言。": "Automatic: English becomes Chinese and Chinese becomes English. Pick a language to always translate into it.",
        "在任意应用中选中文字即可弹出译文，可在菜单栏图标中开关。": "Select text in any app to see the translation; toggle it from the menu bar icon.",
        "若已在系统设置授权仍无反应，请完全退出后重新打开 App；也可点右侧复查。": "If it still does nothing after granting permission, quit the app completely and reopen it, or re-check on the right.",
        "复查授权状态": "Re-check permission",
        "打开辅助功能设置": "Open Accessibility settings",
        "辅助功能权限尚未对当前 App 生效。请在系统设置里移除列表里的旧条目，只保留下面这个路径，然后完全退出重开。": "Accessibility permission is not active for this app. Remove the old entry from System Settings, keep only the path below, then quit and reopen.",
        "当前应用没有向系统暴露选区，已自动尝试模拟复制；若仍无译文，请检查辅助功能授权。": "This app does not expose its selection. Simulated copy was tried; if nothing appears, check the Accessibility permission.",
        "正在翻译…": "Translating…",
        "停止朗读": "Stop speaking",
        "划词译文": "Selection translation",
        "划词内容": "Selected text",
        "（译文尚未生成）": "(translation not ready)",
        "已存入备忘录": "Saved to Notes",
        "备忘录导入失败": "Could not import into Notes",
        "已加入提醒事项": "Added to Reminders",
        "提醒事项需授权": "Reminders needs permission",
        "提醒事项": "Reminders",
        "没有可用的提醒列表": "No reminder list available",
        "系统里找不到备忘录 App": "Notes app not found",
        "记录 #%@ · ": "Entry #%@ · ",
        "第 %d 条 · %@": "Entry %d · %@",
        "翻译记录": "Translation",
        "翻译记录（%d 条合并）": "Translation (%d entries)",
        "翻译记录-%d条": "translation-%d-entries",
        "%@ · 本机导出 · 不上传": "%@ · exported on this Mac · never uploaded",
        "译澜译文": "TransOra Translation",
        "译文只保存在你指定的位置，不会上传。": "The file stays where you put it; nothing is uploaded.",
        "已保存：%@": "Saved: %@",
        "保存失败：%@": "Save failed: %@",
        "保存为 TXT 格式": "Save as TXT",
        "保存为 DOCX 格式": "Save as DOCX",
        "保存为 %@ 格式": "Save as %@",
        "还没有可保存的划词内容": "Nothing selected to save yet",

        // MARK: 划词面板按钮
        "划词面板按钮": "Selection panel buttons",
        "选中文字弹出的译文面板，底部这一排按钮可按需增减，最多 %d 个、至少保留 1 个。": "Choose which buttons appear in the selection panel: up to %d, at least 1.",
        "恢复默认": "Reset to default",
        "划词面板按钮已恢复默认": "Selection panel buttons reset to default",
        "划词面板最多 %d 个按钮": "The selection panel holds at most %d buttons",
        "划词面板至少保留 %d 个按钮": "The selection panel needs at least %d buttons",
        "已加入「%@」": "Added %@",
        "已移除「%@」": "Removed %@",
        "已满": "Full",
        "已达上限": "Limit reached",
        "还可添加 %d 个": "%d more available",
        "本机操作": "On-device actions",
        "网页操作": "Web actions",
        "会把译文发送到对应网站": "Sends the translation to that website",
        "这几个按钮只在默认浏览器里打开网页，翻译本身仍在本机完成；不想外发就不勾选。": "These buttons only open a web page in your browser; the translation itself still happens on this Mac. Leave them off if you prefer not to send anything out.",
        "已复制译文并打开微博": "Translation copied, Weibo opened",
        "已在浏览器打开「%@」": "Opened %@ in your browser",
        "无法打开默认浏览器": "Could not open the default browser",
        "需授权「%@」": "Needs access to %@",
        "%@ 存入失败": "Could not save to %@",
        "需要授权访问「%@」": "Access to %@ is required",
        "%@ 返回错误：%@": "%@ returned an error: %@",

        // MARK: 划词动作（SelectionActionCatalog 的标题与说明）
        "存为 TXT": "Save as TXT",
        "存为 DOCX": "Save as DOCX",
        "存入备忘录": "Save to Notes",
        "加入提醒事项": "Add to Reminders",
        "朗读译文": "Speak",
        "在主窗口打开": "Open in window",
        "译文 Bing 搜索": "Search Bing",
        "译文 Google 搜索": "Search Google",
        "译文发送微博": "Share to Weibo",
        "译文淘宝搜索": "Search Taobao",
        "把译文复制到剪贴板": "Copy the translation to the clipboard",
        "保存为纯文本文件": "Save as a plain text file",
        "保存为 Word 文档": "Save as a Word document",
        "导入到「备忘录」": "Import into Notes",
        "加入「提醒事项」": "Add to Reminders",
        "用系统语音朗读译文": "Speak the translation with the system voice",
        "在译澜主窗口继续处理": "Continue in the TransOra window",
        "在默认浏览器搜索译文": "Search the translation in your browser",
        "打开微博分享页发送译文，译文同时复制到剪贴板": "Open Weibo with the translation and also copy it to the clipboard",
        "在淘宝搜索译文": "Search the translation on Taobao",

        // MARK: PDF 翻译（纯文本）
        "PDF 长文本翻译": "Long PDF translation",
        "支持几百页 PDF · 全部在本机完成 · 可随时取消": "Hundreds of pages · all on this Mac · cancellable",
        "1. 选择 PDF": "1. Choose a PDF",
        "尚未选择文件": "No file selected",
        "选择 PDF…": "Choose PDF…",
        "支持带文字层的 PDF；扫描件请先做 OCR": "Needs a text layer; run OCR first for scans",
        "2. 输出形式": "2. Output",
        "输出形式": "Output",
        "3. 翻译进度": "3. Progress",
        "4. 译文预览与导出": "4. Preview and export",
        "按页分块 · 随时可取消": "Chunked by page · cancellable",
        "选择要翻译的 PDF（支持几百页，按页分块串行翻译）": "Choose a PDF to translate (hundreds of pages, chunked serially)",
        "长文档按页分块逐段翻译，几百页可能需要较长时间；可以中途取消，已完成的段落仍可导出。": "Long documents are translated page by page; hundreds of pages take a while. You can cancel anytime and still export what finished.",
        "PDF 只在本机解析，文字不会上传；导出的文件由你指定保存位置。": "The PDF is parsed on this Mac and nothing is uploaded; you choose where exported files go.",
        "无法读取这个 PDF，或文件已损坏。": "This PDF cannot be read or is damaged.",
        "这个 PDF 没有可提取的文字层（可能是扫描件）。本版本不做 OCR，无法翻译图片中的文字。": "This PDF has no text layer (it may be a scan). This build does not do OCR, so text inside images cannot be translated.",
        "无法读取 PDF": "Could not read the PDF",
        "已载入 %d 页 / %d 字，分为 %d 段；长文档耗时较长，可随时取消。": "Loaded %d pages / %d characters in %d chunks; long documents take a while and can be cancelled anytime.",
        "%d 页 · %d 字 · 分为 %d 段": "%d pages · %d characters · %d chunks",
        "已完成 %d / %d 段": "%d of %d chunks done",
        "已在第 %d / %d 段取消": "Cancelled at chunk %d of %d",
        "翻译完成 · %d 段 · 用时 %.1f 分钟": "Finished · %d chunks · %.1f min",
        "PDF 翻译完成": "PDF translation finished",
        "PDF 翻译已取消": "PDF translation cancelled",
        "正在取消…": "Cancelling…",
        "还没有可导出的 PDF 译文": "No PDF translation to export yet",
        "第 %d 页 · 第 %d 段": "Page %d · chunk %d",
        "第 1 页": "Page 1",
        "【第 %d 页 · 第 %d 段】\n%@": "[Page %d · chunk %d]\n%@",
        "%@ · 译文": "%@ · Translation",
        "%@-译文": "%@-translation",
        "%@ · 本机翻译 · 共 %d 页 / %d 段": "%@ · translated on this Mac · %d pages / %d chunks",

        // MARK: PDF 版式重建
        "3. 重建版式": "3. Rebuild layout",
        "4. 结果": "4. Results",
        "版式重建（PDF）": "Rebuild layout (PDF)",
        "纯译文（TXT / DOCX）": "Text only (TXT / DOCX)",
        "只保留文字，便于二次编辑": "Text only, easy to edit later",
        "译文写回原位置，图片与表格不动": "Translation goes back in place; images and tables untouched",
        "开始重建": "Start rebuild",
        "打开译文 PDF": "Open translated PDF",
        "逐段对照报告": "Comparison report",
        "对照报告": "comparison report",
        "版式重建会逐段重新排版：放不下的译文先压行距、再缩字、再扩框，最后才挪到页脚注；代码块、目录、页码这类片段保持原字节不动。": "Rebuilding re-typesets block by block: a translation that does not fit first tightens leading, then shrinks type, then widens the box, and only then moves to a footnote; code blocks, contents lists and page numbers keep their original bytes.",
        "准备中": "Preparing",
        "读取文件": "Reading file",
        "读取页面与文字位置": "Reading pages and text positions",
        "解析版式": "Parsing layout",
        "写回版式": "Writing back layout",
        "驱逐译文对应的原文并重排": "Evicting translated source and reflowing",
        "生成报告": "Generating report",
        "逐段对照原文与译文": "Comparing source and translation block by block",
        "正在重建 PDF 版式": "Rebuilding PDF layout",
        "正在取消": "Cancelling",
        "当前段落结束后停止": "Stops after the current block",
        "版式重建完成": "Layout rebuild finished",
        "版式重建未完成": "Layout rebuild incomplete",
        "未完成": "Incomplete",
        "已译": "Translated",
        "保留原文": "Kept as-is",
        "自检": "Self-check",
        "有复核项": "Needs review",
        "需复核": "To review",
        "第 %d 页 · %@": "Page %d · %@",
        "读取文件失败：%@": "Could not read the file: %@",
        "写文件失败：%@": "Could not write file: %@",
        "没有产出结果": "No output produced",
        "已取消（已完成的部分没有写盘）": "Cancelled (finished parts were not written)",
        "缺少内置字体（LinguaNovaSong-Regular.ttf）": "Bundled font missing (LinguaNovaSong-Regular.ttf)",
        "找不到内置字体（LinguaNovaSong），无法写回版式": "Bundled font (LinguaNovaSong) missing; cannot write the layout back",
        "这份 PDF 没有可提取的文字（可能是扫描件）": "This PDF has no extractable text (it may be a scan)",
        "［本段翻译失败": "[Translation failed",
        "［本段翻译失败：%@］": "[Translation failed: %@]",
        "图片、表格、矢量按原字节保留；自检会把译文与原页逐像素比对，非文本区有任何改动都会列进对照报告。": "Images, tables and vectors are kept byte-for-byte; the self-check compares the new page against the original pixel by pixel and lists any change outside text areas.",
        "%d 页 · 将逐段写回原版式": "%d pages · layout will be rebuilt chunk by chunk",
        "%d 页 · 已译 %d 段 · 保留原文 %d 段 · %.1f 秒": "%d pages · %d blocks translated · %d kept as-is · %.1f s",
        "请先选择一份 PDF": "Choose a PDF first",
    ]
}

/// 运行时语言状态。
///
/// 用 `nonisolated(unsafe)` 而不是 `@MainActor`：`L()` 会被视图、AppModel、
/// AppKit 菜单三处调用，其中菜单构建发生在非 SwiftUI 的同步路径上，
/// 加隔离会逼出一堆 `MainActor.assumeIsolated`。写入只发生在设置页切换那一刻，
/// 读取是无状态查表，实际不存在竞争。
enum L10n {
    nonisolated(unsafe) static var current: ResolvedLanguage = .chinese

    static func resolve(_ language: InterfaceLanguage) -> ResolvedLanguage {
        switch language {
        case .chinese: return .chinese
        case .english: return .english
        case .system:  return systemDefault
        }
    }

    /// 跟随系统：首选语言是中文（含 zh-Hans / zh-Hant / zh-HK）就用中文，其余一律英文。
    static var systemDefault: ResolvedLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }

    static func text(_ key: String) -> String {
        guard current == .english else { return key }
        return LocalizationTable.english[key] ?? key
    }
}

/// 取界面文案。`key` 传中文原文；有 `%@`/`%d` 占位时按 `String(format:)` 填充。
///
/// 例：`L("版本 %@", AppBrand.version)`、`L("历史 %d 条", count)`。
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = L10n.text(key)
    guard !args.isEmpty else { return template }
    return String(format: template, arguments: args)
}
