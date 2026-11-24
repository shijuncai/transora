import SwiftUI
import AppKit
import HymnCore

/// 统一视觉令牌。全部使用系统语义色，自动适配浅色/深色模式，
/// 不写死任何深色面板或亮色文字。
enum AppPalette {
    static var card: Color { Color(nsColor: .controlBackgroundColor) }
    static var editor: Color { Color(nsColor: .textBackgroundColor) }
    static var sidebar: Color { Color(nsColor: .windowBackgroundColor) }
    static var border: Color { Color(nsColor: .separatorColor) }
    static var bar: Color { Color(nsColor: .windowBackgroundColor) }

    static let accentGradient = LinearGradient(
        colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    static var subtleFill: Color { Color.accentColor.opacity(0.11) }
    static var softShadow: Color { Color.black.opacity(0.055) }
    static var hairline: Color { Color(nsColor: .separatorColor).opacity(0.45) }
}

struct SectionCard<Content: View>: View {
    let title: String?
    let icon: String?
    let content: Content

    init(title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title {
                HStack(spacing: 9) {
                    if let icon { SmallIconBadge(systemName: icon) }
                    Text(title).font(.subheadline.weight(.semibold))
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(AppPalette.hairline, lineWidth: 1))
        .shadow(color: AppPalette.softShadow, radius: 8, y: 2)
    }
}

/// 卡片标题前的渐变描边小图标，统一各页面的视觉节奏。
struct SmallIconBadge: View {
    let systemName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(AppPalette.subtleFill)
            Image(systemName: systemName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 25, height: 25)
    }
}

struct Badge: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 1))
    }
}

/// 翻译页语言栏的共享尺寸：下拉菜单与左右切换按钮必须严格等高。
enum LanguageBarMetrics {
    static let controlHeight: CGFloat = 30
}

/// 主界面各页工具栏控件的统一高度。
/// 之前 PDF / 历史 / 术语库 / 设置 用的是默认尺寸（22–26 pt），切页时高度会跳。
enum ControlMetrics {
    static let height: CGFloat = LanguageBarMetrics.controlHeight
}

extension View {
    /// 下拉菜单 / 按钮 / 搜索框统一成「翻译」页的高度。
    ///
    /// 只靠 `controlSize(.large)` 不够：不同控件族的自然高度仍差 2–4 pt，
    /// 所以再钉一个固定 frame，保证同一行里的下拉、按钮、输入框严格齐平。
    func unifiedControlHeight(_ height: CGFloat = ControlMetrics.height) -> some View {
        controlSize(.large).frame(height: height)
    }
}

struct LanguagePicker: View {
    let label: String
    @Binding var selection: String

    var body: some View {
        // 标签与下拉菜单同一行；两者使用相同的 controlSize，确保与中间的
        // 语言切换按钮高度完全一致（此前切换按钮用 .large、下拉用默认尺寸）。
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("", selection: $selection) {
                // 产品收敛：主界面只列 14 种常用语言；完整 36 种映射仍在
                // LanguageCatalog.all 中供 CLI 评测与历史记录显示使用。
                ForEach(LanguageCatalog.featured, id: \.code) { entry in
                    Text("\(entry.chineseName) (\(entry.code))").tag(entry.code)
                }
            }
            .labelsHidden()
            .controlSize(.large)
            .frame(width: 176, height: LanguageBarMetrics.controlHeight)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// 原文 / 译文面板。译文只读，避免用户误改后误以为是模型输出。
struct TextPanel: View {
    let title: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    var editable: Bool = true
    var trailing: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SmallIconBadge(systemName: icon)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(text.count) 字符")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.045), in: Capsule())
                if let trailing { trailing }
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppPalette.editor)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(AppPalette.border.opacity(0.4), lineWidth: 1))
                if editable {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                } else {
                    ScrollView {
                        Text(text.isEmpty ? placeholder : text)
                            .font(.body)
                            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                }
                if editable && text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(AppPalette.hairline, lineWidth: 1))
        .shadow(color: AppPalette.softShadow, radius: 8, y: 2)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("重新检测", action: retry)
                .buttonStyle(.bordered)
                .unifiedControlHeight()
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppPalette.subtleFill)
                    .frame(width: 66, height: 66)
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func languageDisplayName(_ code: String) -> String {
    LanguageCatalog.name(for: code)
}

/// 用 App 的真实图标（`Contents/Resources/TransOra.icns`）作为品牌标，
/// 保证 Dock / Finder 与界面内是同一个 logo。图标缺失时回退到渐变符号。
struct AppIconMark: View {
    let size: CGFloat

    /// 直接读 bundle 里的 icns，而不用 `NSApp.applicationIconImage`：
    /// macOS 26 上后者返回的是**系统合成过的**图标（会给透明图标自动垫一层浅色底板），
    /// 界面里要的正是原始的透明 TO 标记，垫了底板就等于白底又回来了。
    /// 裸跑 `.build/debug` 时 bundle 里没有 icns，退回渐变占位符。
    static let brandImage: NSImage? = Bundle.main
        .url(forResource: "TransOra", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let icon = Self.brandImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24)
                    .fill(AppPalette.accentGradient)
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: size * 0.44, weight: .semibold))
                            .foregroundStyle(.white))
                    .frame(width: size, height: size)
            }
        }
    }
}

/// 关于窗口内容（v0.7.5）。用自定义 NSWindow 承载，层级由 AppDelegate.showAbout
/// 显式控制，替代会落到其它窗口下面的系统标准关于面板。
struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            AppIconMark(size: 48)
                .shadow(color: .black.opacity(0.18), radius: 7, y: 3)

            Text(AppBrand.displayName).font(.title2.weight(.semibold))
            Text(AppBrand.englishName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("版本 \(AppBrand.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 2)

            Text(AppBrand.privacy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Apple Silicon 本机离线推理 · 无需联网")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 340, height: 252)
        .background(AppPalette.bar)
    }
}
