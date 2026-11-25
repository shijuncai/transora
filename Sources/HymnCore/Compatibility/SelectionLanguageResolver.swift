import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// 划词翻译的语言对解析（纯计算，不依赖 AppKit / 推理后端，便于独立测试）。
///
/// 背景：划词请求过去直接复用主窗口语言对。用户在主窗口设 `en → zh` 时，
/// 划到中文文档会被要求「翻译成简体中文」，模型把原文原样抄一遍，
/// 表现为「浮窗有内容但没翻译」。这里依据选区内容自动判定源语言，并选一个
/// **与选区不同**的目标语言，避免自译。
///
/// 两级判定：
/// 1. **书写系统**（日文假名 / 韩文 / 汉字 / 泰文 / 阿拉伯文 / 西里尔文）——确定性规则；
/// 2. **拉丁字母语言**——交给系统 `NLLanguageRecognizer`（离线统计模型）。
///    v0.7.9 之前这里一律回落成「英文」，导致法语/德语/西班牙语等划词都显示
///    「英 → 中」；现在改为真实识别，低置信度时才回落。
public enum SelectionLanguageResolver {
    public struct Pair: Equatable, Sendable {
        public let source: String
        public let target: String
        /// 选区语言是否由书写系统明确判定（拉丁/未知时为 false）。
        public let autoDetected: Bool

        public init(source: String, target: String, autoDetected: Bool) {
            self.source = source
            self.target = target
            self.autoDetected = autoDetected
        }
    }

    /// 拉丁字母书写的语言：彼此无法仅凭 Unicode 可靠区分。
    private static let latinLanguages: Set<String> = [
        "en", "fr", "de", "es", "pt", "it", "vi", "id", "ms", "tl",
        "tr", "nl", "pl", "cs", "fi", "sv", "da", "no", "ro", "hu",
    ]

    /// 判定选区语言；无法判定返回 nil（不臆造语言）。
    ///
    /// 先按书写系统判定（确定性），拉丁字母再交给系统语言识别器。
    public static func detect(_ text: String) -> String? {
        if let script = detectByWritingSystem(text) { return script }
        return detectLatinLanguage(text)
    }

    /// 非拉丁书写系统判定。
    /// - 假名优先于汉字（日文混写汉字仍判为日文）；
    /// - 特征字符需占主导，避免长英文里夹一个汉字被误判。
    private static func detectByWritingSystem(_ text: String) -> String? {
        var kana = 0, hangul = 0, han = 0, thai = 0, arabic = 0, cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                kana += 1
            } else if (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v)
                        || (0x3130...0x318F).contains(v) {
                hangul += 1
            } else if (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
                        || (0xF900...0xFAFF).contains(v) || (0x20000...0x2FA1F).contains(v) {
                han += 1
            } else if (0x0E00...0x0E7F).contains(v) {
                thai += 1
            } else if (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
                        || (0x08A0...0x08FF).contains(v) {
                arabic += 1
            } else if (0x0400...0x052F).contains(v) {
                cyrillic += 1
            } else if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
                        || (0x00C0...0x024F).contains(v) {
                latin += 1
            }
        }

        // 顺序即优先级：日文（假名）早于汉字。
        let candidates: [(String, Int)] = [
            ("ja", kana), ("ko", hangul), ("zh", han),
            ("th", thai), ("ar", arabic), ("ru", cyrillic),
        ]
        let dominant = candidates.map(\.1).max() ?? 0
        guard dominant > 0 else { return nil }
        let latinThreshold = max(1, Int(ceil(Double(latin) * 0.2)))
        for (code, count) in candidates where count >= max(1, dominant / 2)
            && count >= latinThreshold {
            return code
        }
        return nil
    }

    /// 拉丁字母语言的置信度门槛。
    ///
    /// 实测（macOS 内置识别器）：
    /// - 完整句子 `fr/de/es/pt/it/vi/id/en` 置信度 0.95–1.00；
    /// - 短问候 `Bonjour` 0.63、`Hola amigo` 0.98；
    /// - 无信息量的短词 `OK` 0.29、`test` 0.13、`Hello` 0.13。
    ///
    /// 取 0.45：既能让真实句子与常见问候被正确识别，又能把「OK / test / Hello」
    /// 这类噪声挡在门外——它们会回落到主窗口设置，而不是被标成某个随机语言。
    private static let latinConfidenceFloor: Double = 0.45

    /// 拉丁字母语言判定（离线统计模型，不联网）。
    /// 仅接受「拉丁语系 + 语言目录已收录」的结果，避免出现界面无法显示的错误语言。
    private static func detectLatinLanguage(_ text: String) -> String? {
        #if canImport(NaturalLanguage)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 单字符没有可判定的语言信息，直接放弃（避免 "a" 被认成匈牙利语）。
        guard trimmed.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              best.value >= latinConfidenceFloor else { return nil }
        let code = normalizeLanguageCode(best.key.rawValue)
        guard latinLanguages.contains(code), LanguageCatalog.contains(code) else { return nil }
        return code
        #else
        return nil
        #endif
    }

    /// `pt-BR` / `zh-Hans` 之类的 BCP-47 标签归一到项目内部的两字母代码。
    private static func normalizeLanguageCode(_ raw: String) -> String {
        raw.split(separator: "-").first.map { $0.lowercased() } ?? raw.lowercased()
    }

    /// 解析划词请求实际使用的语言对，保证 `target != source`。
    ///
    /// - 选区是中文而主窗口目标也是中文 → 翻成主窗口源语言（通常是英文）；
    /// - 选区是拉丁文字 → 由识别器给出具体语言（法/德/西/葡/意/越/印尼…），
    ///   置信度不足时才回落到「英文」或主窗口源语言；
    /// - 其余情况保留主窗口目标语言。
    /// - Parameter fixedTarget: 用户在设置页指定的「划词输出语言」。非空时优先于
    ///   `preferredTarget`；若它与判定出的源语言相同（会造成自译），退回中文/英文里
    ///   另一个，逻辑与自动模式一致。
    public static func resolve(
        text: String, preferredSource: String, preferredTarget: String,
        fixedTarget: String? = nil
    ) -> Pair {
        let detected = detect(text)
        let source: String
        let autoDetected: Bool

        if let detected {
            source = detected
            autoDetected = true
        } else if latinLanguages.contains(preferredSource.lowercased()) {
            source = preferredSource
            autoDetected = false
        } else {
            // 主窗口源语言是中文等非拉丁文字，但选区全是拉丁字母 → 判为英文。
            source = "en"
            autoDetected = true
        }

        var target = preferredTarget
        if let fixed = fixedTarget, LanguageCatalog.contains(fixed) {
            target = fixed == source ? (source == "zh" ? "en" : "zh") : fixed
            return Pair(source: source, target: target, autoDetected: autoDetected)
        }
        if target == source {
            let options = [preferredSource, preferredTarget, "zh", "en"]
            target = options.first {
                $0 != source && LanguageCatalog.contains($0)
            } ?? (source == "zh" ? "en" : "zh")
        }
        return Pair(source: source, target: target, autoDetected: autoDetected)
    }

    /// 划词译文的生成上限：比主窗口默认值宽，避免长段落被 128 tokens 截断。
    /// 上限 512 是交互时延与完整度的折中（流式逐块显示，不阻塞主线程）。
    public static func suggestedMaxTokens(for text: String, base: Int) -> Int {
        min(512, max(base, text.count + 32))
    }
}
