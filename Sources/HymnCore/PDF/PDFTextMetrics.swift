import Foundation

/// 一个「字体面」：嵌入的字体 + 它在页面资源里的名字。
///
/// P3 只区分常规/粗体两面（思源宋体 400 / 700）。
/// 斜体不嵌入配套字重，用 `Tm` 斜切模拟，见 `PDFTypeset.Options.syntheticItalicShear`。
public struct PDFFace {
    public var font: TrueTypeFont
    public var resourceName: String
    public var isBold: Bool

    public init(font: TrueTypeFont, resourceName: String, isBold: Bool) {
        self.font = font
        self.resourceName = resourceName
        self.isBold = isBold
    }
}

/// 文本度量。
///
/// 这里刻意**不用 CoreText**，而是直接用字体的 `hmtx` 前进宽度：
///
///     PDF 阅读器排版 `Tj` 时，逐字位置 = Σ (/W[CID] / 1000 × 字号)
///
/// 而 `/W` 就是子集字体的 `hmtx`。也就是说，用 `hmtx` 测量和阅读器实际绘制
/// 是**同一个数据源**，误差为零；换成 CoreText 反而会引入 hinting/整形差异，
/// 出现「我这里算得下、阅读器里却溢出半行」这种最难查的问题。
///
/// 代价是不做 kerning（PDF 的 `Tj` 本来也不做），所以拉丁文会略宽于
/// 排版软件的输出——偏保守，宁可早换行也不要溢出。
public enum PDFTextMetrics {
    /// 缺字时的估值：按半角宽。真实宽度未知，但**必须给一个数**，
    /// 否则断行会把缺字当零宽，导致整行算得下、画出来超出去。
    static let missingGlyphWidthRatio = 0.5

    public static func advance(
        _ scalar: Unicode.Scalar, font: TrueTypeFont, size: Double
    ) -> Double {
        guard let gid = font.glyphID(for: scalar.value) else {
            return size * missingGlyphWidthRatio
        }
        return Double(font.width1000(gid: gid)) * size / 1000
    }

    public static func width(_ text: String, font: TrueTypeFont, size: Double) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars {
            total += advance(scalar, font: font, size: size)
        }
        return total
    }

    public static func width(_ text: String, face: PDFFace, size: Double) -> Double {
        width(text, font: face.font, size: size)
    }

    /// 逐字符宽度，与 `unicodeScalars` 一一对应。断行时按它累积，避免重复测量。
    public static func advances(
        _ text: String, font: TrueTypeFont, size: Double
    ) -> [(scalar: Unicode.Scalar, width: Double)] {
        text.unicodeScalars.map { ($0, advance($0, font: font, size: size)) }
    }

    /// 字体里没有的字形（按首次出现顺序去重）。这些字画不出来，必须上报。
    public static func missingScalars(_ text: String, font: TrueTypeFont) -> [UInt32] {
        var seen = Set<UInt32>()
        var out: [UInt32] = []
        for scalar in text.unicodeScalars
        where font.glyphID(for: scalar.value) == nil && !seen.contains(scalar.value) {
            seen.insert(scalar.value)
            out.append(scalar.value)
        }
        return out
    }

    /// 行高：字号 × 系数。中文字体的默认行距偏紧，1.4 是「不挤也不散」的起点。
    public static func lineHeight(fontSize: Double, factor: Double) -> Double {
        fontSize * factor
    }

    /// 首行基线相对行顶的下移量。用 `ascent` 而不是固定比例，
    /// 不同字体的 ascent 差得多（思源宋体 ≈ 1.16em），固定比例会顶到上一行。
    public static func firstBaselineOffset(font: TrueTypeFont, fontSize: Double) -> Double {
        let ascentEm = Double(font.ascent) / 1000
        // ascent 常常大于 1em，直接减会让首行贴顶；夹到 [0.75, 0.92] 更接近视觉居中
        let clamped = min(max(ascentEm * 0.8, 0.75), 0.92)
        return fontSize * clamped
    }
}
