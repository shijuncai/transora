import Foundation

// MARK: - 划词浮窗自适应尺寸（纯计算，不依赖 AppKit，便于独立测试）
//
// 设计目标：窗口尺寸随「划词量 + 译文量」变化：
//   - 短句 → 窄而矮，减少遮挡；
//   - 长段落 → 变宽变高，减少折行与滚动；
//   - 超长内容 → 宽高都钳到屏幕安全上限，改为窗内滚动，不覆盖整块屏幕。
// 所有几何常量与 SelectionPopupView 严格一一对应，保证 SwiftUI 内容尺寸与
// NSPanel contentSize 恒等，不会出现裁切或留白错位。

public struct SelectionPopupLayout: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let sourceHeight: Double
    public let translationHeight: Double
    public let sourceLineLimit: Int
    public let estimatedSourceLines: Int
    public let estimatedTranslationLines: Int
    public let scrolls: Bool
    public let tier: String

    public init(
        width: Double, height: Double, sourceHeight: Double, translationHeight: Double,
        sourceLineLimit: Int, estimatedSourceLines: Int, estimatedTranslationLines: Int,
        scrolls: Bool, tier: String
    ) {
        self.width = width
        self.height = height
        self.sourceHeight = sourceHeight
        self.translationHeight = translationHeight
        self.sourceLineLimit = sourceLineLimit
        self.estimatedSourceLines = estimatedSourceLines
        self.estimatedTranslationLines = estimatedTranslationLines
        self.scrolls = scrolls
        self.tier = tier
    }
}

public struct SelectionPopupContent: Equatable, Sendable {
    public let source: String
    public let translation: String
    public let error: String?
    public let loading: Bool

    public init(source: String, translation: String = "", error: String? = nil, loading: Bool = false) {
        self.source = source
        self.translation = translation
        self.error = error
        self.loading = loading
    }
}

public enum SelectionPopupSizer {
    // MARK: 与 SelectionPopupView 共用的固定几何常量（改动需两边同步）
    public static let horizontalPadding: Double = 14
    public static let verticalPadding: Double = 14
    public static let headerHeight: Double = 24
    public static let footerHeight: Double = 28   // 单行最多 7 个等宽图标按钮（内容由设置页配置）
    public static let dividerHeight: Double = 1
    public static let stackSpacing: Double = 10
    public static let stackSpacingCount: Double = 4      // VStack 5 个子项 → 4 个间隔
    public static let sourceLineHeight: Double = 16       // .caption ≈ 12pt
    public static let translationLineHeight: Double = 19  // .callout ≈ 13pt

    /// 除原文区、译文区之外的固定高度：上下 padding + 头部 + 分隔线 + 底部按钮 + 间距。
    public static let baseHeight: Double =
        verticalPadding * 2 + headerHeight + footerHeight + dividerHeight
        + stackSpacing * stackSpacingCount   // = 121

    // 尺寸边界
    public static let minWidth: Double = 300
    public static let maxWidth: Double = 520
    public static let minHeight: Double = 182
    public static let maxHeightCap: Double = 640
    public static let screenHeightRatio: Double = 0.62
    public static let screenEdgeInset: Double = 32

    // 字体平均单位宽度（估算折行用；含 15% 折行余量，宁可略高不多裁）
    private static let captionUnitWidth: Double = 5.8
    private static let calloutUnitWidth: Double = 6.0
    private static let wrapSafety: Double = 1.10

    /// 依据划词原文、当前译文与屏幕可见区域计算浮窗布局。
    /// - Parameters:
    ///   - content: 当前浮窗内容（译文可能仍在流式增长）
    ///   - screenHeight: 屏幕可见高度（pt）
    ///   - screenWidth: 屏幕可见宽度（pt）
    public static func make(
        content: SelectionPopupContent,
        screenHeight: Double = 900,
        screenWidth: Double = 1440
    ) -> SelectionPopupLayout {
        let shownText: String
        if let error = content.error, !error.isEmpty {
            shownText = error
        } else if content.translation.isEmpty {
            shownText = content.loading ? "正在翻译…" : ""
        } else {
            shownText = content.translation
        }

        let sourceUnits = weightedUnits(content.source)
        let translationUnits = weightedUnits(shownText)
        // 宽度主要由划词量决定，同时兼顾很长的译文，避免窄窗里堆出十几行。
        let driver = max(sourceUnits, translationUnits * 0.85)

        let tierWidth: Double
        let tier: String
        let sourceLineLimit: Int
        switch driver {
        case ..<70:
            tierWidth = 320; tier = "compact"; sourceLineLimit = 2
        case ..<190:
            tierWidth = 380; tier = "standard"; sourceLineLimit = 3
        case ..<430:
            tierWidth = 440; tier = "wide"; sourceLineLimit = 5
        default:
            tierWidth = 520; tier = "max"; sourceLineLimit = 6
        }
        let width = min(tierWidth, max(minWidth, screenWidth - screenEdgeInset))
        let available = max(120, width - horizontalPadding * 2)

        let sourceLines = estimateLines(
            content.source, availableWidth: available, unitWidth: captionUnitWidth)
        let translationLines = estimateLines(
            shownText, availableWidth: available, unitWidth: calloutUnitWidth)

        let maxHeight = min(maxHeightCap, max(minHeight + 40, screenHeight * screenHeightRatio))
        let minTranslationHeight = Double(2) * translationLineHeight + 6

        // 屏幕较矮时先收紧原文行数，保证译文区至少有两行可用。
        let affordableSourceLines = max(1, Int(floor(
            (maxHeight - baseHeight - minTranslationHeight) / sourceLineHeight)))
        let effectiveLineLimit = min(sourceLineLimit, affordableSourceLines)
        let clampedSourceLines = min(max(1, sourceLines), effectiveLineLimit)
        let sourceHeight = Double(clampedSourceLines) * sourceLineHeight

        // 译文区可用高度由屏幕上限反推；内容超出时固定到上限并启用滚动。
        let maxTranslationHeight = max(minTranslationHeight,
                                       maxHeight - baseHeight - sourceHeight)
        let wantedTranslationHeight =
            Double(max(translationLines, 2)) * translationLineHeight + 6
        let scrolls = wantedTranslationHeight > maxTranslationHeight
        let translationHeight = min(wantedTranslationHeight, maxTranslationHeight)

        var height = baseHeight + sourceHeight + translationHeight
        var finalTranslationHeight = translationHeight
        if height < minHeight {
            finalTranslationHeight += minHeight - height
            height = minHeight
        }

        // 不变量：SwiftUI 内容与 NSPanel contentSize 严格一致。
        // 浮点取整误差在这里统一收敛，避免视图上下各差 1pt。
        finalTranslationHeight = height - baseHeight - sourceHeight

        return SelectionPopupLayout(
            width: width,
            height: height,
            sourceHeight: sourceHeight,
            translationHeight: finalTranslationHeight,
            sourceLineLimit: effectiveLineLimit,
            estimatedSourceLines: sourceLines,
            estimatedTranslationLines: translationLines,
            scrolls: scrolls,
            tier: tier)
    }

    // MARK: - 文本度量（公开以便测试）

    /// 单个 Unicode scalar 的近似宽度单位：全角/复杂脚本 2，窄字符 0.55，组合标记 0。
    public static func scalarUnit(_ scalar: Unicode.Scalar) -> Double {
        let v = scalar.value
        if v == 0x0A { return 12 }                       // 换行：额外推动宽度分档
        if (0x0300...0x036F).contains(v) || (0x1AB0...0x1AFF).contains(v)
            || (0xFE00...0xFE0F).contains(v) { return 0 } // 组合标记 / variation selector
        // CJK、假名、谚文、全角、emoji、扩展汉字
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE10...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F000...0x1FAFF).contains(v)
            || (0x20000...0x3FFFD).contains(v) { return 2 }
        // 天城文、藏文、缅文、高棉文等复杂脚本：比拉丁宽但不及汉字
        if (0x0900...0x097F).contains(v) || (0x0980...0x09FF).contains(v)
            || (0x0A00...0x0A7F).contains(v) || (0x0F00...0x0FFF).contains(v)
            || (0x1000...0x109F).contains(v) || (0x1780...0x17FF).contains(v)
            || (0x0B80...0x0BFF).contains(v) || (0x0C00...0x0C7F).contains(v) { return 1.5 }
        // 窄拉丁字母与标点
        switch v {
        case 0x20, 0x69, 0x6C, 0x6A, 0x74, 0x66, 0x72, 0x49, 0x4C, 0x4A,
             0x2E, 0x2C, 0x3B, 0x3A, 0x27, 0x21, 0x7C, 0x60, 0x5B, 0x5D:
            return 0.55
        default:
            return 1
        }
    }

    public static func weightedUnits(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + scalarUnit($1) }
    }

    /// 估算给定宽度下的折行数；显式换行按段落独立计算。
    public static func estimateLines(
        _ text: String, availableWidth: Double, unitWidth: Double
    ) -> Int {
        guard !text.isEmpty else { return 1 }
        let perLine = max(8, availableWidth / unitWidth)
        var lines = 0
        for para in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let units = weightedUnits(String(para))
            lines += max(1, Int(ceil(units / perLine * wrapSafety)))
        }
        return max(1, lines)
    }
}
