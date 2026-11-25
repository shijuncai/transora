import SwiftUI
import AppKit
import HymnCore

/// 主界面的 PDF 页。
///
/// 两种模式，共用「选择 PDF」这一步：
///   · 纯译文：逐页提取 → 分块串行翻译 → 导出 TXT/DOCX（版式会丢，便于二次编辑）
///   · 版式重建：译文写回原页面（图片、表格、矢量一个字节不动），并产出逐段对照报告
struct PDFTranslationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    title: L("PDF 长文本翻译"),
                    subtitle: L("支持几百页 PDF · 全部在本机完成 · 可随时取消"),
                    icon: "doc.richtext")

                if let message = model.pdfErrorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L("重新选择")) { model.choosePDF() }
                            .unifiedControlHeight()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 8))
                }

                fileCard
                modeCard

                if model.pdfWorkMode == .text {
                    textModeCards
                } else {
                    layoutModeCards
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("PDF 只在本机解析，文字不会上传；导出的文件由你指定保存位置。"))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if model.pdfWorkMode == .layout {
                        Text(L("版式重建会逐段重新排版：放不下的译文先压行距、再缩字、再扩框，最后才挪到页脚注；代码块、目录、页码这类片段保持原字节不动。"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.bar)
    }

    // MARK: - 选择文件

    private var fileCard: some View {
        SectionCard(title: L("1. 选择 PDF"), icon: "folder") {
            HStack(spacing: 12) {
                Button {
                    model.choosePDF()
                } label: {
                    Label(L("选择 PDF…"), systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .unifiedControlHeight()
                .disabled(model.pdfIsTranslating || model.pdfRebuild.isRunning)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.pdfFileName.isEmpty ? L("尚未选择文件") : model.pdfFileName)
                        .font(.callout)
                        .lineLimit(1)
                    Text(fileSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L("按页分块 · 随时可取消"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var fileSummary: String {
        if model.pdfPageCount == 0 {
            return L("支持带文字层的 PDF；扫描件请先做 OCR")
        }
        if model.pdfWorkMode == .layout {
            return L("%d 页 · 将逐段写回原版式", model.pdfPageCount)
        }
        return L("%d 页 · %d 字 · 分为 %d 段", model.pdfPageCount, model.pdfCharacterCount, model.pdfChunkTotal)
    }

    // MARK: - 模式

    private var modeCard: some View {
        SectionCard(title: L("2. 输出形式"), icon: "square.on.square") {
            Picker(L("输出形式"), selection: $model.pdfWorkMode) {
                ForEach(PDFWorkMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .unifiedControlHeight()
            .disabled(model.pdfIsTranslating || model.pdfRebuild.isRunning)
            Text(model.pdfWorkMode.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 纯译文模式

    private var textModeCards: some View {
        Group {
            SectionCard(title: L("3. 翻译进度"), icon: "arrow.right.circle") {
                HStack(spacing: 12) {
                    Text("\(languageDisplayName(model.sourceLang)) → \(languageDisplayName(model.targetLang))")
                        .font(.callout)
                    Spacer()
                    Button {
                        model.startPDFTranslation()
                    } label: {
                        Label(L("开始翻译"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .unifiedControlHeight()
                    .disabled(model.pdfIsTranslating || model.pdfChunkTotal == 0
                              || !model.isRealInference)
                    Button {
                        model.cancelPDFTranslation()
                    } label: {
                        Label(L("取消"), systemImage: "stop.circle")
                    }
                    .unifiedControlHeight()
                    .disabled(!model.pdfIsTranslating)
                }
                if model.pdfChunkTotal > 0 {
                    ProgressView(value: Double(model.pdfChunkDone),
                                 total: Double(model.pdfChunkTotal))
                    Text(model.pdfStatus.isEmpty ? L("准备就绪") : model.pdfStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("长文档按页分块逐段翻译，几百页可能需要较长时间；可以中途取消，已完成的段落仍可导出。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            SectionCard(title: L("4. 译文预览与导出"), icon: "square.and.arrow.down") {
                HStack(spacing: 10) {
                    ForEach(DocumentExportFormat.allCases, id: \.rawValue) { format in
                        Button {
                            model.exportPDFTranslation(format)
                        } label: {
                            Label(L("保存为 %@ 格式", format.shortLabel),
                                  systemImage: "square.and.arrow.down")
                        }
                        .unifiedControlHeight()
                        .disabled(model.pdfChunkDone == 0)
                    }
                    Spacer()
                    if model.pdfChunkDone > 0 {
                        Text(L("已完成 %d / %d 段", model.pdfChunkDone, model.pdfChunkTotal))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppPalette.editor)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(AppPalette.border.opacity(0.35), lineWidth: 1))
                    if model.pdfPreviewText.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.accentColor.opacity(0.6))
                            Text(L("译文会在这里显示最近几段"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(L("完整译文请导出 TXT 或 DOCX"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(model.pdfPreviewText)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: - 版式重建模式

    private var layoutModeCards: some View {
        Group {
            SectionCard(title: L("3. 重建版式"), icon: "wand.and.stars") {
                let status = model.pdfRebuild
                HStack(spacing: 12) {
                    Text("\(languageDisplayName(model.sourceLang)) → \(languageDisplayName(model.targetLang))")
                        .font(.callout)
                    Spacer()
                    Button {
                        model.startRebuildPDF()
                    } label: {
                        Label(L("开始重建"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .unifiedControlHeight()
                    .disabled(status.isRunning || model.pdfPageCount == 0
                              || !model.isRealInference)
                    Button {
                        model.cancelRebuildPDF()
                    } label: {
                        Label(L("取消"), systemImage: "stop.circle")
                    }
                    .unifiedControlHeight()
                    .disabled(!status.isRunning)
                }

                if status.isRunning || status.finished || status.error != nil {
                    ProgressView(value: status.fraction)
                    HStack(spacing: 8) {
                        Text(status.stage.isEmpty ? L("准备就绪") : status.stage)
                            .font(.caption).foregroundStyle(.secondary)
                        if status.total > 0 && status.isRunning {
                            Text("\(status.done) / \(status.total)")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        Spacer()
                        if !status.detail.isEmpty {
                            Text(status.detail)
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                if let error = status.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.pdfRebuild.finished {
                SectionCard(title: L("4. 结果"), icon: "checkmark.seal") {
                    let status = model.pdfRebuild
                    HStack(spacing: 10) {
                        Button {
                            model.openRebuildPDF()
                        } label: {
                            Label(L("打开译文 PDF"), systemImage: "doc.text")
                        }
                        .buttonStyle(.borderedProminent)
                        .unifiedControlHeight()
                        Button {
                            model.openRebuildReport()
                        } label: {
                            Label(L("逐段对照报告"), systemImage: "list.bullet.rectangle")
                        }
                        .unifiedControlHeight()
                        Button {
                            model.revealRebuildOutput()
                        } label: {
                            Label(L("在访达中显示"), systemImage: "folder")
                        }
                        .unifiedControlHeight()
                        Spacer()
                    }
                    HStack(spacing: 18) {
                        metric(L("已译"), "\(status.translatedBlocks)", "text.alignleft")
                        metric(L("保留原文"), "\(status.keptBlocks)", "lock.doc")
                        metric(L("自检"), status.passed ? L("通过") : L("有复核项"),
                               status.passed ? "checkmark.shield" : "exclamationmark.shield")
                        if status.needsReviewPages > 0 {
                            metric(L("需复核"), L("%d 页", status.needsReviewPages), "eye")
                        }
                        Spacer()
                    }
                    Text(L("图片、表格、矢量按原字节保留；自检会把译文与原页逐像素比对，非文本区有任何改动都会列进对照报告。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.callout).monospacedDigit()
                Text(title).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
