import SwiftUI
import AppKit
import HymnCore

struct TranslateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let message = model.errorMessage {
                ErrorBanner(message: message) {
                    Task { await model.retryPreparation() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            languageBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            HStack(spacing: 14) {
                TextPanel(
                    title: "原文",
                    icon: "doc.text",
                    placeholder: "输入或粘贴要翻译的文本…",
                    text: $model.inputText,
                    editable: true,
                    trailing: AnyView(
                        Button {
                            model.clearTexts()
                        } label: {
                            Image(systemName: "xmark.circle").imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                        .help("清空输入与译文")
                    ))

                TextPanel(
                    title: "译文",
                    icon: "character.bubble.zh",
                    placeholder: model.isRunning
                        ? "正在生成译文…"
                        : (model.isRealInference ? "译文将在这里逐字出现" : "请先完成初始设置"),
                    text: .constant(model.outputText),
                    editable: false,
                    trailing: AnyView(
                        Button {
                            model.copyOutput()
                        } label: {
                            Image(systemName: "doc.on.doc").imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.outputText.isEmpty)
                        .help("复制译文")
                    ))
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            actionBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.bar)
    }

    /// 页头不再展示「全程离线 / 已就绪」徽标，改为更轻的快捷键提示。
    /// 标题前的图标与其它四页同源（`PageHeader`：38 pt 渐变圆角 + 白色符号），
    /// 不再单独写一套字号，跨页切换时标题基线不会跳。
    private var header: some View {
        PageHeader(
            title: "翻译",
            subtitle: "支持 14 种常用语言 · 长文与划词都能译",
            icon: "character.bubble",
            trailing: AnyView(shortcutHint))
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
    }

    private var shortcutHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "command")
                .font(.caption2)
            Text("↵ 开始翻译")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppPalette.card, in: Capsule())
        .overlay(Capsule().stroke(AppPalette.border.opacity(0.45), lineWidth: 1))
    }

    private var languageBar: some View {
        HStack(alignment: .center, spacing: 12) {
            LanguagePicker(label: "源语言", selection: $model.sourceLang)
            Button {
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
            // 与 LanguagePicker 内的下拉菜单统一 controlSize 与高度，视觉齐平。
            .controlSize(.large)
            .frame(width: 38, height: LanguageBarMetrics.controlHeight)
            .help("交换语言（并把译文放回输入框）")
            .keyboardShortcut("s", modifiers: [.command, .shift])
            LanguagePicker(label: "目标语言", selection: $model.targetLang)
            Spacer()
            if model.isPreparing {
                ProgressView().controlSize(.small)
                Text("正在准备…").font(.caption).foregroundStyle(.secondary)
            } else if let ms = model.lastDurationMs {
                Label(String(format: "上次用时 %.1f 秒", Double(ms) / 1000),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.translate() }
            } label: {
                Label(model.isRunning ? "翻译中…" : "翻译", systemImage: "arrow.right.circle.fill")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .unifiedControlHeight()
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isRunning || model.isPreparing || !model.isRealInference
                      || model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                Task { await model.cancelCurrent() }
            } label: {
                Label("取消", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .unifiedControlHeight()
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(!model.isRunning)

            Button {
                model.copyOutput()
            } label: {
                Label("复制译文", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .unifiedControlHeight()
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.outputText.isEmpty)

            if model.isRunning {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
            Spacer()
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
