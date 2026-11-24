import Foundation

/// 排版：把一段译文放进一个框。
///
/// 投放顺序（**不要改**，改了就是可读性问题）：
///     ① 原字号 + 原框：能放下就放下，这是绝大多数段落的实际路径；
///     ② 压行距：1.4 → 1.25 → 1.1。行距比字号「便宜」——压缩行距只是变紧，
///        缩小字号是直接变难读。BabelDOC 的做法是先缩字号，这里反过来；
///     ③ 缩字号：按 0.05 步进（≤0.6 后 0.1），下限由调用方给（页面基准 × 0.8，且不低于 6pt）；
///     ④ 扩框：先向右（同栏空白），再向下（到下一个障碍或页边距）；
///     ⑤ 出口：短溢（≤2 行）inline，长溢 page-note，整页多段触发 page-reflow。
///
/// 「每页字号必须统一」这件事不在本类型里决定：这里只返回「这一段用了多大字号」，
/// 由 `PDFTypesetEngine` 汇总后统一取页面档位，否则同页会出现 6pt 与 8pt 混排的花脸。
public enum PDFTypeset {
    public enum Tier: String {
        case fit          // 原样放下
        case shrink       // 压行距 / 缩字号
        case expand       // 扩框
        case overflowShort
        case overflowLong
        case skipped      // 没有译文或空文本
    }

    public enum Align {
        case left
        case center
        case right
    }

    public struct Options {
        public var minFontSize = 6.0
        public var lineHeightFactors: [Double] = [1.4, 1.25, 1.1]
        public var maxRightExpandRatio = 0.45   // 最多向右扩 45% 框宽
        public var maxDownExpandRatio = 1.2     // 最多向下扩 1.2 倍框高
        public var align: Align = .left
        /// 首行缩进（中文段落两个字符宽）。默认 0：原文多数没有缩进，硬加会错位
        public var firstLineIndent = 0.0
        public var breaker = PDFLineBreaker.Options()

        public init() {}
    }

    /// 可用的排版空间。`rightLimit` / `downLimit` 由页面栅格算出（栏右边界、下一个障碍上沿、页边距）。
    public struct Space {
        public var box: PDFRect
        public var rightLimit: Double
        public var downLimit: Double

        public init(box: PDFRect, rightLimit: Double, downLimit: Double) {
            self.box = box
            self.rightLimit = rightLimit
            self.downLimit = downLimit
        }
    }

    public struct Line {
        public var text: String
        /// 基线起点
        public var origin: PDFPoint
        public var width: Double
        public var overfull: Bool
    }

    public struct Plan {
        public var blockID: String
        public var tier: Tier = .skipped
        public var box: PDFRect
        public var fontSize: Double
        public var lineHeight: Double
        public var scale: Double = 1
        public var lines: [Line] = []
        public var overflow: [String] = []
        public var warnings: [String] = []
        /// 因为字体缺字而画不出来的字符
        public var missingScalars: [UInt32] = []
        /// 这一次真正打算排的文字（换行归一 + 缺字替身之后的版本）。
        ///
        /// 自检的「截断」判据拿它当基准，而不是调用方给的原始译文：
        /// 原始译文里的 `H₂O` 会被换成 `H2O`（字体没有 U+2082），
        /// 若仍拿原文比对，就会把「换了写法」误报成「少画了字」。
        public var content: String = ""

        public var isEmpty: Bool { lines.isEmpty && overflow.isEmpty }
    }

    /// 页面基准字号：取该页所有行字号的 25 分位。
    ///
    /// 用 P25 而不是中位数：一页里标题、图注、脚注会把中位数拉高，
    /// 而正文（最小的那一批）才是可读性的基准。
    public static func pageBaselineFontSize(lines: [ILLine]) -> Double {
        let sizes = lines.map(\.fontSize).filter { $0 > 0 }.sorted()
        guard !sizes.isEmpty else { return 0 }
        let index = max(0, min(sizes.count - 1, Int(Double(sizes.count) * 0.25)))
        return sizes[index]
    }

    /// 同一视觉栏的右边界。
    ///
    /// 判据是「左沿相近（±24pt）且不是横贯整页的块」：
    ///     - 用「横向重叠比例」会把页脚那种通栏块算进来，于是左栏的右边界被拉到整页宽，
    ///       左栏文字就会压到右栏上（实测就是这样翻车的）；
    ///     - 用「左沿相近」能稳定区分左右栏，因为同栏的正文左边界几乎一致。
    public static func columnRightEdge(
        for block: ILBlock, in blocks: [ILBlock], limit: Double
    ) -> Double {
        var right = block.box.x1
        for other in blocks where other.id != block.id {
            guard abs(other.box.x0 - block.box.x0) <= 24 else { continue }
            guard other.box.width <= (limit - block.box.x0) * 0.85 else { continue }
            right = max(right, other.box.x1)
        }
        return min(right, limit)
    }

    /// 可读下限：`max(6pt, 页面基准 × 0.8)`。低于这个就不再缩，改走扩框/出口。
    public static func fontSizeFloor(baseline: Double) -> Double {
        guard baseline > 0 else { return 6 }
        return max(6, baseline * 0.8)
    }

    public static func plan(
        text: String,
        blockID: String = "",
        face: PDFFace,
        baseFontSize: Double,
        space: Space,
        floorSize: Double,
        options: Options = Options()
    ) -> Plan {
        var plan = Plan(blockID: blockID, box: space.box,
                        fontSize: max(1, baseFontSize), lineHeight: 0)
        // 译文里可能带换行/制表（模型输出、跨句拼接）。控制字符不是字形，
        // 原样交给字体只会得到一条「字体画不出 U+000A」的假缺陷，并且打乱断行。
        var content = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            plan.tier = .skipped
            return plan
        }
        let base = max(1, baseFontSize)
        let floor = max(1, min(floorSize, base))
        // 字体画不出的上下标换成 ASCII 替身：`H₂O` → `H2O`。
        // 不换的话这个字会被直接丢掉，化学式印成 "H O"。
        let absent = PDFTextMetrics.missingScalars(content, font: face.font)
        if !absent.isEmpty { content = PDFGlyphFallback.apply(content, missing: absent) }
        plan.content = content
        plan.missingScalars = PDFTextMetrics.missingScalars(content, font: face.font)

        // ① 原框 + 原字号（含压行距）
        if let fit = fit(content, face: face, size: base,
                         width: space.box.width, height: space.box.height, options: options) {
            plan.tier = .fit
            apply(fit, face: face, base: base, box: space.box, options: options, to: &plan)
            return plan
        }

        // ② 缩字号
        var scale = 1.0
        while scale > 0.1 {
            scale -= scale > 0.6 + 1e-9 ? 0.05 : 0.1
            if base * scale < floor - 1e-9 { break }
            // 夹到下限：0.05 步进的累减会让 6.0 变成 5.9999999999999964，
            // 虽然只差 3e-15，但「不低于 6pt」是承诺，不能靠误差糊过去
            let size = max(floor, base * scale)
            if let fit = fit(content, face: face, size: size,
                             width: space.box.width, height: space.box.height, options: options) {
                plan.tier = .shrink
                apply(fit, face: face, base: base, box: space.box, options: options, to: &plan)
                return plan
            }
        }

        // ③ 扩框：先向右
        var expanded = space.box
        var didExpand = false
        let maxWidth = min(space.rightLimit - space.box.x0,
                           space.box.width * (1 + options.maxRightExpandRatio))
        if maxWidth > space.box.width + 0.5 {
            expanded.x1 = space.box.x0 + maxWidth
            didExpand = true
            if let fit = fit(content, face: face, size: base,
                             width: expanded.width, height: expanded.height, options: options) {
                plan.tier = .expand
                apply(fit, face: face, base: base, box: expanded, options: options, to: &plan)
                return plan
            }
            if let fit = shrinkToFit(content, face: face, base: base, floor: floor,
                                     width: expanded.width, height: expanded.height,
                                     options: options) {
                plan.tier = .expand
                apply(fit, face: face, base: base, box: expanded, options: options, to: &plan)
                return plan
            }
        }

        // ③b 再向下
        let maxHeight = min(space.box.y1 - space.downLimit,
                            space.box.height * (1 + options.maxDownExpandRatio))
        if maxHeight > expanded.height + 0.5 {
            expanded.y0 = expanded.y1 - maxHeight
            didExpand = true
            if let fit = fit(content, face: face, size: base,
                             width: expanded.width, height: expanded.height, options: options) {
                plan.tier = .expand
                apply(fit, face: face, base: base, box: expanded, options: options, to: &plan)
                return plan
            }
            if let fit = shrinkToFit(content, face: face, base: base, floor: floor,
                                     width: expanded.width, height: expanded.height,
                                     options: options) {
                plan.tier = .expand
                apply(fit, face: face, base: base, box: expanded, options: options, to: &plan)
                return plan
            }
        }

        // ④ 下限字号硬放，溢出的交出口
        let size = max(floor, base * 0.4)
        let factor = options.lineHeightFactors.last ?? 1.1
        let lineHeight = size * factor
        let broken = PDFLineBreaker.breakLines(
            text: content, font: face.font, size: size,
            maxWidth: expanded.width, options: options.breaker)
        let capacity = max(1, Int((expanded.height + 0.01) / lineHeight))
        let kept = Array(broken.prefix(capacity))
        let overflow = Array(broken.dropFirst(capacity)).map(\.text)

        plan.box = expanded
        plan.fontSize = size
        plan.scale = size / base
        plan.lineHeight = lineHeight
        plan.lines = positionLines(kept, face: face, size: size, lineHeight: lineHeight,
                                   box: expanded, options: options)
        plan.overflow = overflow
        plan.tier = overflow.isEmpty ? (didExpand ? .expand : .shrink)
            : (overflow.count <= 2 ? .overflowShort : .overflowLong)
        if broken.contains(where: \.overfull) {
            plan.warnings.append("有 \(broken.filter(\.overfull).count) 行超出框宽（禁则或长单词）")
        }
        return plan
    }

    // MARK: - 内部

    struct Fit {
        var lines: [PDFLineBreaker.Line]
        var size: Double
        var factor: Double
    }

    /// 依次尝试各档行距，能放下就返回。
    static func fit(
        _ text: String, face: PDFFace, size: Double, width: Double, height: Double,
        options: Options
    ) -> Fit? {
        for factor in options.lineHeightFactors {
            let lineHeight = size * factor
            let lines = PDFLineBreaker.breakLines(
                text: text, font: face.font, size: size,
                maxWidth: width, options: options.breaker)
            guard Double(lines.count) * lineHeight <= height + 0.01 else { continue }
            return Fit(lines: lines, size: size, factor: factor)
        }
        return nil
    }

    static func shrinkToFit(
        _ text: String, face: PDFFace, base: Double, floor: Double,
        width: Double, height: Double, options: Options
    ) -> Fit? {
        var scale = 1.0
        while scale > 0.1 {
            scale -= scale > 0.6 + 1e-9 ? 0.05 : 0.1
            if base * scale < floor - 1e-9 { break }
            let size = max(floor, base * scale)
            if let fit = fit(text, face: face, size: size,
                             width: width, height: height, options: options) {
                return fit
            }
        }
        return nil
    }

    static func apply(
        _ fit: Fit, face: PDFFace, base: Double, box: PDFRect,
        options: Options, to plan: inout Plan
    ) {
        plan.box = box
        plan.fontSize = fit.size
        plan.lineHeight = fit.size * fit.factor
        plan.scale = base > 0 ? fit.size / base : 1
        plan.lines = positionLines(fit.lines, face: face, size: fit.size,
                                   lineHeight: plan.lineHeight, box: box, options: options)
    }

    static func positionLines(
        _ broken: [PDFLineBreaker.Line], face: PDFFace, size: Double, lineHeight: Double,
        box: PDFRect, options: Options
    ) -> [Line] {
        var out: [Line] = []
        let baselineOffset = PDFTextMetrics.firstBaselineOffset(font: face.font, fontSize: size)
        for (index, line) in broken.enumerated() {
            var x = box.x0
            switch options.align {
            case .left: x = box.x0
            case .center: x = box.x0 + max(0, (box.width - line.width) / 2)
            case .right: x = box.x0 + max(0, box.width - line.width)
            }
            if index == 0 { x += options.firstLineIndent }
            let baseline = box.y1 - baselineOffset - Double(index) * lineHeight
            out.append(Line(text: line.text, origin: PDFPoint(x, baseline),
                            width: line.width, overfull: line.overfull))
        }
        return out
    }
}
