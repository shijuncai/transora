import SwiftUI
import AppKit
import HymnCore

// MARK: - 历史记录

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    private var selectedCount: Int { model.selectedHistoryIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "历史记录", subtitle: "所有翻译仅保存在本机，不会上传",
                       icon: "clock.arrow.circlepath")

            HStack(spacing: 10) {
                TextField("搜索原文或译文", text: $model.historySearch)
                    .textFieldStyle(.roundedBorder)
                    .unifiedControlHeight()
                    .onChange(of: model.historySearch) { _, _ in model.refreshData() }
                    .frame(maxWidth: 320)
                Button {
                    model.refreshData()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .unifiedControlHeight()
                Spacer()
                Text("\(model.history.count) 条").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    model.clearAllData()
                } label: {
                    Label("清空全部", systemImage: "trash")
                }
                .unifiedControlHeight()
                .disabled(model.history.isEmpty)
            }

            // 单条 / 多条合并导出工具条
            HStack(spacing: 10) {
                Text("已选 \(selectedCount) 条").font(.caption).foregroundStyle(.secondary)
                Button("全选") {
                    model.selectedHistoryIDs = Set(model.history.map(\.id))
                }
                .unifiedControlHeight()
                .disabled(model.history.isEmpty)
                Button("取消选择") { model.selectedHistoryIDs = [] }
                    .unifiedControlHeight()
                    .disabled(selectedCount == 0)
                Divider().frame(height: 16)
                ForEach(DocumentExportFormat.allCases, id: \.rawValue) { format in
                    Button {
                        model.exportSelectedHistory(format)
                    } label: {
                        Label("导出所选为 \(format.shortLabel)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .unifiedControlHeight()
                    .disabled(selectedCount == 0)
                }
                Spacer()
                Text("按住 ⌘ 或 ⇧ 可多选").font(.caption2).foregroundStyle(.tertiary)
            }

            if model.history.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: model.historySearch.isEmpty ? "还没有翻译记录" : "没有匹配的记录",
                    subtitle: model.historySearch.isEmpty ? "完成一次翻译后会自动出现在这里" : "换个关键词试试")
            } else {
                List(selection: $model.selectedHistoryIDs) {
                    ForEach(model.history) { record in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.sourceText)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(record.targetText.isEmpty ? "（无译文）" : record.targetText)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text("\(languageDisplayName(record.sourceLang)) → \(languageDisplayName(record.targetLang))"
                                     + String(format: " · 用时 %.1f 秒", Double(record.durationMs) / 1000))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            if record.cancelled {
                                Badge(text: "已取消", tint: .orange)
                            }
                            Menu {
                                ForEach(DocumentExportFormat.allCases, id: \.rawValue) { format in
                                    Button(format.label) {
                                        model.exportHistoryRecords([record], format: format)
                                    }
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .help("导出这条记录")
                            Button {
                                model.loadFromHistory(record)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("载入到翻译页")
                            Button {
                                model.deleteHistory(record)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除这条记录")
                        }
                        .padding(.vertical, 5)
                        .tag(record.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.bar)
    }
}

// MARK: - 术语库

struct GlossaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "术语库", subtitle: "为当前语言对指定固定译法，翻译时自动遵循",
                       icon: "text.book.closed")

            SectionCard(title: "添加术语", icon: "plus.circle") {
                HStack(spacing: 10) {
                    TextField("源术语", text: $model.newTermSource)
                        .textFieldStyle(.roundedBorder)
                        .unifiedControlHeight()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("目标译法", text: $model.newTermTarget)
                        .textFieldStyle(.roundedBorder)
                        .unifiedControlHeight()
                        .onSubmit { model.addTerm(source: model.newTermSource, target: model.newTermTarget) }
                    Button("添加") {
                        model.addTerm(source: model.newTermSource, target: model.newTermTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .unifiedControlHeight()
                    .disabled(model.newTermSource.isEmpty || model.newTermTarget.isEmpty)
                }
                Text("当前语言对：\(languageDisplayName(model.sourceLang)) → \(languageDisplayName(model.targetLang))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.terms.isEmpty {
                EmptyStateView(icon: "text.book.closed",
                               title: "该语言对暂无术语",
                               subtitle: "添加后，翻译会优先遵循这些译法")
            } else {
                List {
                    ForEach(model.terms) { term in
                        HStack {
                            Text(term.source).font(.body)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(term.target).font(.body)
                            Spacer()
                            Button {
                                model.deleteTerm(term)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.bar)
    }
}

// MARK: - 设置 / 关于

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "设置", subtitle: "偏好设置与本地数据管理",
                           icon: "gearshape")

                SectionCard(title: "关于", icon: "info.circle") {
                    HStack(alignment: .top, spacing: 14) {
                        AppIconMark(size: 52)
                            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppBrand.fullName).font(.headline)
                            Text("版本 \(AppBrand.version) · \(AppBrand.tagline)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("支持 14 种常用语言 · 划词即译 · PDF 长文翻译")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Divider()
                    Label(AppBrand.privacy, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SectionCard(title: "初始设置", icon: "folder") {
                    Text("首次使用需要指定本机模型文件夹，之后即可开始翻译。")
                        .font(.callout)
                    HStack(spacing: 8) {
                        Button {
                            model.chooseModelDirectory()
                        } label: {
                            Label("选择模型文件夹…", systemImage: "folder")
                        }
                        Button {
                            Task { await model.retryPreparation() }
                        } label: {
                            Label("重新检测", systemImage: "arrow.clockwise")
                        }
                        .unifiedControlHeight()
                        .disabled(model.isPreparing || model.isRunning)
                        Spacer()
                        Text("选择后自动检测")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                SectionCard(title: "翻译偏好", icon: "slider.horizontal.3") {
                    HStack {
                        Text("译文长度").frame(width: 90, alignment: .leading)
                        Picker("", selection: $model.lengthOption) {
                            ForEach(TranslationLength.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .unifiedControlHeight()
                        .frame(width: 140)
                        .onChange(of: model.lengthOption) { _, _ in model.savePreferences() }
                        Spacer()
                    }
                    Text("文本较长时可以选择「较长」或「超长」，翻译耗时会相应增加。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("划词翻译").frame(width: 90, alignment: .leading)
                            // 只在 API 报告未授权时出现；不再由启动/划词失败自动弹系统框。
                            Text(model.selectionAccessibilityTrusted
                                 ? "在任意应用中选中文字即可弹出译文，可在菜单栏图标中开关。"
                                 : "若已在系统设置授权仍无反应，请完全退出后重新打开 App；也可点右侧复查。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if !model.selectionAccessibilityTrusted {
                                Button {
                                    model.requestAccessibility()
                                } label: {
                                    Label("复查授权状态", systemImage: "hand.raised")
                                }
                                .unifiedControlHeight()
                            }
                        }
                        // 划词失败时才给出原因；正常出结果不显示任何常驻状态。
                        if model.selectionDiagnosis == .axDisabled {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("辅助功能权限尚未对当前 App 生效。请在系统设置里移除列表里的旧条目，只保留下面这个路径，然后完全退出重开。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 8) {
                                Button("打开辅助功能设置") { model.openAccessibilitySettings() }
                                    .unifiedControlHeight()
                                Text(Bundle.main.bundlePath)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        } else if model.selectionDiagnosis == .axEmpty {
                            Text("当前应用没有向系统暴露选区，已自动尝试模拟复制；若仍无译文，请检查辅助功能授权。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 96)
                        }
                    }
                }

                SectionCard(title: "划词面板按钮", icon: "square.grid.2x2") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("选中文字弹出的译文面板，底部这一排按钮可按需增减，最多 \(SelectionActionPreferences.maxCount) 个、至少保留 1 个。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("\(model.selectionActions.count)/\(SelectionActionPreferences.maxCount)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(model.selectionActions.canAddMore
                                             ? Color.secondary : Color.orange)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        Button("恢复默认") { model.resetSelectionActions() }
                            .unifiedControlHeight()
                            .disabled(model.selectionActions.isDefault)
                    }

                    footerPreview

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机操作")
                            .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                        ForEach(SelectionActionID.localActions) { selectionActionRow($0) }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("网页操作")
                                .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                            Text("会把译文发送到对应网站")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(SelectionActionID.onlineActions) { selectionActionRow($0) }
                        Label("这几个按钮只在默认浏览器里打开网页，翻译本身仍在本机完成；不想外发就不勾选。",
                              systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                SectionCard(title: "本地数据", icon: "externaldrive") {
                    Text("历史记录与术语库保存在这台 Mac 上，可随时清空。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("历史 \(model.history.count) 条 · 当前语言对术语 \(model.terms.count) 条")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            model.clearAllData()
                        } label: {
                            Label("清空本地数据", systemImage: "trash")
                        }
                        .unifiedControlHeight()
                        .disabled(model.history.isEmpty && model.terms.isEmpty)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.bar)
    }

    /// 底排预览：与浮窗同为纯图标小格，用户一眼能看到当前选中组合的样子。
    private var footerPreview: some View {
        HStack(spacing: 3) {
            ForEach(model.selectionActions.ordered) { id in
                Image(systemName: id.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 27, height: 23)
                    .background(AppPalette.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                    .help(id.title)
            }
            if model.selectionActions.canAddMore {
                Text("还可添加 \(SelectionActionPreferences.maxCount - model.selectionActions.count) 个")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            } else {
                Text("已满")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一个动作的开关行。已选满 7 个时，未选中的行禁用并给出「已达上限」。
    private func selectionActionRow(_ id: SelectionActionID) -> some View {
        let isOn = model.selectionActions.contains(id)
        let blocked = !isOn && !model.selectionActions.canAddMore
        return HStack(spacing: 10) {
            Image(systemName: id.symbol)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.title).font(.callout)
                Text(id.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if blocked {
                Text("已达上限")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Toggle("", isOn: Binding(
                get: { model.selectionActions.contains(id) },
                set: { _ in model.toggleSelectionAction(id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(blocked)
                .accessibilityLabel(id.title)
        }
        .padding(.vertical, 2)
        .opacity(blocked ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    /// 右侧附加内容（翻译页用它放 ⌘↵ 快捷键提示），其余页面留空。
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppPalette.accentGradient)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: .purple.opacity(0.20), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 23, weight: .bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}
