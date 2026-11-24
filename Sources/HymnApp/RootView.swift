import SwiftUI
import AppKit

/// 单窗口主界面：左侧导航 + 右侧内容 + 底部状态栏。
/// 状态统一由 @MainActor AppModel 的 @Published 属性驱动，不使用任何 attached macro。
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
                .background(AppPalette.sidebar)
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch model.selectedSection {
                    case .translate: TranslateView()
                    case .pdf:       PDFTranslationView()
                    case .history:   HistoryView()
                    case .glossary:  GlossaryView()
                    case .settings:  SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .background(AppPalette.bar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                brandMark
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppBrand.displayName).font(.title3.weight(.semibold))
                    // 中文名 + 英文名两行；版本号不在这里显示。
                    Text(AppBrand.englishName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().padding(.horizontal, 14)

            Text("工作区")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 6)

            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        model.selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .frame(width: 18)
                                .foregroundStyle(model.selectedSection == section
                                                 ? Color.accentColor : .secondary)
                            Text(section.title).font(.body)
                            Spacer(minLength: 4)
                            if model.selectedSection == section {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        // 激活态是整块圆角矩形，不再是左侧小竖条 + 文字变色。
                        .background(
                            model.selectedSection == section
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(model.selectedSection == section
                                        ? Color.accentColor.opacity(0.32)
                                        : Color.clear, lineWidth: 1))
                        .foregroundStyle(model.selectedSection == section
                                         ? Color.accentColor : Color.primary)
                        // 关键：把整个圆角矩形（含 padding 与 Spacer 撑开的透明区域）
                        // 声明为点击热区，否则 .buttonStyle(.plain) 只响应文字/图标像素，
                        // 用户点到按钮空白处不会切换页面。
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(sidebarShortcut(section), modifiers: .command)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    AppIconMark(size: 20)
                    Text("划词即译，长PDF翻译").font(.caption.weight(.medium))
                }
                Text("选中文字，译文随手可得")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("文本只留在这台 Mac")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(AppPalette.border.opacity(0.4), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private var brandMark: some View {
        AppIconMark(size: 52)
            .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
    }

    private func sidebarShortcut(_ section: AppSection) -> KeyEquivalent {
        switch section {
        case .translate: return "1"
        case .pdf:       return "2"
        case .history:   return "3"
        case .glossary:  return "4"
        case .settings:  return "5"
        }
    }

    /// 精简状态栏：不再展示「已就绪 / 离线」徽标，只保留操作反馈与耗时。
    private var statusBar: some View {
        HStack(spacing: 9) {
            AppIconMark(size: 18)
            Text(model.status.isEmpty ? AppBrand.englishName : model.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let ms = model.lastDurationMs {
                Label(String(format: "上次 %.1f 秒", Double(ms) / 1000),
                      systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(AppPalette.bar)
    }
}
