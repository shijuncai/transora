import SwiftUI
import AppKit
import HymnCore

/// 划词后弹出的轻量译文面板内容。
///
/// 尺寸完全由 `SelectionPopupState.layout` 驱动（由 `SelectionPopupSizer` 按划词量计算），
/// 视图内所有固定高度都取自同一套常量，保证 SwiftUI 内容与 NSPanel contentSize 严格一致。
struct SelectionPopupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: SelectionPopupState
    let onClose: () -> Void
    let onOpenMain: () -> Void

    private var layout: SelectionPopupLayout { state.layout }

    /// 悬停 2 秒后显示的按钮名称（自定义气泡，不用 `.help`——
    /// 系统 tooltip 要等约 3 秒且在这个非激活面板里不一定出现）。
    @State private var hoverIndex: Int?
    @State private var hoverTitle: String?
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(SelectionPopupSizer.stackSpacing)) {
            HStack(spacing: 7) {
                // 使用 App 自身的 LN 图标，与 Dock / 主窗口保持一致。
                AppIconMark(size: 18)
                Text(AppBrand.displayName).font(.subheadline.bold())
                // 显示本次划词实际使用的语言对：自动解析后用户能直接看到「中 → 英」，
                // 不会再困惑于「为什么译文和原文一样」。存入备忘录/提醒事项的短暂提示
                // 复用同一位置，避免额外占用浮窗高度。
                if let notice = model.selectionNotice {
                    Text(notice)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                } else if !model.selectionSource.isEmpty {
                    Text("\(LanguageNames.shortLabel(for: model.selectionSourceLang)) → "
                         + LanguageNames.shortLabel(for: model.selectionTargetLang))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Spacer(minLength: 2)
                if model.isSelectionTranslating {
                    ProgressView().controlSize(.small)
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .frame(height: CGFloat(SelectionPopupSizer.headerHeight))

            Text(model.selectionSource)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(layout.sourceLineLimit)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(height: CGFloat(layout.sourceHeight), alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: CGFloat(SelectionPopupSizer.dividerHeight))

            ScrollView {
                if let error = model.selectionError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.selectionTranslation.isEmpty {
                    Text(model.isSelectionTranslating ? L("正在翻译…") : "")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.selectionTranslation)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(height: CGFloat(layout.translationHeight))

            // 一行最多 7 个等宽图标按钮：内容是「设置 → 划词面板按钮」里选中的动作，
            // 出厂为 复制 / 存 TXT / 存 DOCX / 备忘录 / 提醒事项 / 朗读 / 主窗口。
            // 始终按 7 格定宽布局：少于 7 个时整排居中，单元格宽度不变，
            // 不会把两个按钮拉成两块巨大的热区。悬停 2 秒显示名称。
            HStack(spacing: Self.footerSpacing) {
                ForEach(Array(footerButtons.enumerated()), id: \.offset) { index, item in
                    footerIcon(item, index: index)
                }
            }
            .frame(maxWidth: .infinity)
            .controlSize(.small)
            .frame(height: CGFloat(SelectionPopupSizer.footerHeight))
        }
        .padding(CGFloat(SelectionPopupSizer.horizontalPadding))
        .frame(width: CGFloat(layout.width), height: CGFloat(layout.height), alignment: .topLeading)
        .background(AppPalette.card)
        // 悬停气泡画在按钮行正上方，横向跟随被悬停的单元格并夹在浮窗内。
        .overlay(alignment: .bottomLeading) {
            if let title = hoverTitle, let index = hoverIndex {
                hoverBubble(title)
                    .offset(x: hoverBubbleX(index: index, title: title),
                            y: -(CGFloat(SelectionPopupSizer.verticalPadding)
                                 + CGFloat(SelectionPopupSizer.footerHeight) + 6))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 底排按钮定义

    private struct FooterButton {
        let title: String
        let symbol: String
        let enabled: Bool
        let tint: Color
        let action: () -> Void
    }

    private static let footerSpacing: CGFloat = 2

    /// 底排恒按 7 格定宽：按钮数量变化时单元格宽度不变，整排居中。
    private var footerCellWidth: CGFloat {
        let content = CGFloat(layout.width) - CGFloat(SelectionPopupSizer.horizontalPadding) * 2
        let slots = CGFloat(SelectionActionPreferences.maxCount)
        return max(1, (content - Self.footerSpacing * (slots - 1)) / slots)
    }

    /// 底排内容由偏好驱动（顺序 = `SelectionActionID` 声明顺序）。
    private var footerButtons: [FooterButton] {
        model.selectionActions.ordered.compactMap(footerButton(for:))
    }

    private func footerButton(for id: SelectionActionID) -> FooterButton? {
        let hasTranslation = !model.selectionTranslation.isEmpty
        let hasSource = !model.selectionSource.isEmpty
        // 存文件与「回主窗口」只依赖原文；其余动作都要有译文才有意义。
        let enabled: Bool
        switch id {
        case .saveTxt, .saveDocx: enabled = hasSource
        case .openMain:           enabled = true
        default:                  enabled = hasTranslation
        }

        switch id {
        case .copyTranslation:
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) {
                model.copySelectionTranslation()
            }
        case .saveTxt:
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) {
                model.exportSelection(.txt)
            }
        case .saveDocx:
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) {
                model.exportSelection(.docx)
            }
        case .saveNotes:
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) {
                model.saveSelectionToNotes()
            }
        case .saveReminders:
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) {
                model.saveSelectionToReminders()
            }
        case .speak:
            // 朗读中换成三波浪图标（不用 speaker.slash，容易被读成「已静音」）。
            return FooterButton(
                title: model.isSelectionSpeaking ? L("停止朗读") : L(id.title),
                symbol: model.isSelectionSpeaking ? "speaker.wave.3.fill" : id.symbol,
                enabled: enabled,
                tint: model.isSelectionSpeaking ? Color.accentColor : Color.primary) {
                    model.noteSelectionSpeechTapped()
                    model.toggleSelectionSpeech()
                }
        case .openMain:
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) { onOpenMain() }
        default:
            // 网页动作：先交给默认浏览器（译文进查询串），再收起浮窗，
            // 否则这个非激活面板会一直盖在浏览器上面。
            return FooterButton(title: L(id.title), symbol: id.symbol,
                                enabled: enabled, tint: .primary) {
                model.openSelectionWebAction(id)
                onClose()
            }
        }
    }

    /// 底部按钮的统一形态：定宽单元格 + 纯图标，点击热区覆盖整格。
    private func footerIcon(_ item: FooterButton, index: Int) -> some View {
        Button(action: item.action) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(item.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(width: footerCellWidth)
        .buttonStyle(.borderless)
        .disabled(!item.enabled)
        .accessibilityLabel(item.title)
        .onHover { inside in
            updateHover(index: index, title: item.title, inside: inside)
        }
    }

    // MARK: - 悬停提示

    /// 进入单元格后等 2 秒再显示名称；移出或换格立即取消。
    private func updateHover(index: Int, title: String, inside: Bool) {
        guard inside else {
            if hoverIndex == index {
                hoverTask?.cancel()
                hoverIndex = nil
                hoverTitle = nil
            }
            return
        }
        guard hoverIndex != index || hoverTitle == nil else { return }
        hoverTask?.cancel()
        hoverIndex = index
        hoverTitle = nil
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, hoverIndex == index else { return }
            withAnimation(.easeOut(duration: 0.12)) { hoverTitle = title }
        }
    }

    private func hoverBubble(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.97)))
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.28), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
    }

    /// 气泡左边缘：先对齐单元格中心，再夹进浮窗内。
    private func hoverBubbleX(index: Int, title: String) -> CGFloat {
        let padding = CGFloat(SelectionPopupSizer.horizontalPadding)
        let count = CGFloat(max(1, footerButtons.count))
        let content = CGFloat(layout.width) - padding * 2
        let cell = footerCellWidth
        // 定宽单元格 + 整排居中：先算这一排的起始 x，再算第 index 格的中心。
        let rowWidth = cell * count + Self.footerSpacing * (count - 1)
        let start = padding + max(0, (content - rowWidth) / 2)
        let center = start + CGFloat(index) * (cell + Self.footerSpacing) + cell / 2
        // 估算宽度用于夹取：caption2 的中文单字约 11 pt，左右内边距 14。
        let estimated = min(160, 14 + CGFloat(title.count) * 11.5)
        let maxX = CGFloat(layout.width) - estimated - 3
        return min(max(center - estimated / 2, 3), max(3, maxX))
    }
}
