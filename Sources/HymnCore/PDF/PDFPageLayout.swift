import Foundation

/// 排版诊断：把「引擎实际画了什么」如实交出来，供 P4 的七项检查定位。
///
/// 为什么不让分析器自己从 IL 推：
///     报告里说的「放不下」「缩到 6pt」「落进页脚注」都是引擎内部的决策，
///     外部按 IL 重算只能得到近似值，一旦两边算法漂移，就会出现
///     「引擎认为放下了、分析器认为溢出」的扯皮。诊断数据是**同一份真相**。
///
/// 所有矩形都是页面坐标（pt，左下原点）。`lines` 是每一行的墨迹框，
/// 不是行距框——检测遮挡和溢出用的是墨迹。
public struct PDFPageLayout: Sendable {
    public enum Kind: String, Sendable, Encodable {
        case block
        case note
        case cell
        case orphan
        case pinned
        /// 原文一字节没动（没有译文、或被判定不该译）
        case kept
    }

    public struct Item: Sendable {
        public var id: String
        public var kind: Kind
        /// 分配到的框（扩框之后）
        public var box: PDFRect
        /// 每行墨迹框
        public var lines: [PDFRect]
        /// 打算画的文字
        public var intent: String
        /// 实际落版的文字（行拼接，去行尾空白）
        public var drawn: String
        /// 原文（占位符核对、回退原文时用）
        public var source: String
        public var fontSize: Double
        public var overflow: [String]
        public var missingScalars: [UInt32]
        public var tier: String

        public init(id: String, kind: Kind, box: PDFRect, lines: [PDFRect],
                    intent: String, drawn: String, source: String,
                    fontSize: Double, overflow: [String] = [],
                    missingScalars: [UInt32] = [], tier: String = "") {
            self.id = id
            self.kind = kind
            self.box = box
            self.lines = lines
            self.intent = intent
            self.drawn = drawn
            self.source = source
            self.fontSize = fontSize
            self.overflow = overflow
            self.missingScalars = missingScalars
            self.tier = tier
        }

        /// 行墨迹的并集
        public var inkBox: PDFRect {
            guard var union = lines.first else { return box }
            for line in lines.dropFirst() { union = union.union(line) }
            return union
        }
    }

    public var page: Int            // 0 基
    public var mediaBox: PDFRect
    public var rotation: Int
    public var items: [Item] = []
    public var figures: [PDFRect] = []
    public var tables: [PDFRect] = []
    /// 被驱逐的原文墨迹（掩膜的来源之一）
    public var removedText: [PDFRect] = []
    /// 我们新加的非文本墨迹（页脚注释分隔线之类）。这些必须进掩膜，
    /// 否则 R1 会把「我们主动画的线」当成「图片被改了」。
    public var addedInk: [PDFRect] = []
    public var skipped = false
    /// 本页内容流的 FNV-1a 64（十六进制）。修复回路用它证明「未受影响页没变」。
    public var contentHash = ""
    public var notes = ""

    public init(page: Int, mediaBox: PDFRect, rotation: Int = 0) {
        self.page = page
        self.mediaBox = mediaBox
        self.rotation = rotation
    }

    /// 掩膜矩形：被驱逐的原文 + 新画的文字 + 新画的非文本墨迹
    ///
    /// **保留原字节的块（`.kept` / `.pinned`）故意不进掩膜**：它们的字形必须一个像素都不变，
    /// 不遮住才查得出来。这也是「选择性驱逐」能自证的地方——
    /// 代码块、页码、符号如果被误改，R1 立刻报掩膜外差异。
    ///
    /// 新画的文字按字号的 12% 再外扩一圈：这里的行框是**排版框**（与 R2 同一套模型，
    /// 上边界 `clamp(ascent×0.8, 0.75, 0.92)em`），而宋体的全角括号、带声调的拉丁字母、
    /// 下伸部实际墨迹会探出去一点。不外扩的话，R1 会把「我们自己写的字」报成「非文本区被改」。
    public var maskRects: [PDFRect] {
        var rects = removedText
        for item in items where item.kind != .kept && item.kind != .pinned {
            // 横向放宽一个 em：译文行末的字常比原框右沿多出一点（外文换行点不同），
            // 这是排版自由度内的正常现象，不该算「非文本区被改」。
            let padY = max(0.8, item.fontSize * 0.12)
            let padX = max(1.0, item.fontSize * 0.9)
            rects.append(item.box.expanded(x: padX, y: padY))
            rects.append(contentsOf: item.lines.map { $0.expanded(x: padX, y: padY) })
        }
        rects.append(contentsOf: addedInk)
        return rects
    }

    public var blockItems: [Item] { items.filter { $0.kind == .block } }
}

/// 内容哈希：FNV-1a 64。
///
/// 不用 CryptoKit 有两个理由：① 这里只做「两次是否逐字节相同」的判断，
/// 不需要抗碰撞强度；② 引入 CryptoKit 会给 HymnCore 增加一个系统框架依赖，
/// 而这个模块目前只有 Foundation + CoreGraphics。
public enum FNV1a {
    public static func hash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(format: "%016llx", hash)
    }

    public static func hash(_ bytes: [UInt8]) -> String {
        hash(Data(bytes))
    }
}
