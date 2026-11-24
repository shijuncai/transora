import Foundation
import HymnCore

/// 唯一后端的提示词构造（此前位于已退役的 `RealModelBackend.buildPrompt`）。
///
/// 语言名统一走 `LanguageCatalog`（模型卡实证 36 种语言），不把裸语言代码
/// 塞进中文提示词；chat template 由 `HymnTokenizer.encodeChat` 硬编码渲染，
/// 运行时不读取任何 .jinja 文件。
public enum SherryPromptBuilder {
    public static func buildPrompt(_ request: InferenceRequest, tokenizer: HymnTokenizer) throws -> [Int] {
        var content = "将以下文本翻译为\(LanguageCatalog.name(for: request.languages.target))，只输出译文：\n"
            + request.text
        if !request.glossaryHints.isEmpty {
            content += "\n术语表（必须遵守）：\n"
            content += request.glossaryHints.map { "\($0.source) → \($0.target)" }
                .joined(separator: "\n")
        }
        return try tokenizer.encodeChat(
            messages: [ChatMessage(role: "user", content: content)],
            addGenerationPrompt: true)
    }
}
