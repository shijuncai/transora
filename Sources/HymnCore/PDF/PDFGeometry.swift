import Foundation

/// 二维几何与 PDF 矩阵。
///
/// 约定（PDF 32000-1 §8.3）：矩阵用 `[a b c d e f]` 表示，点按**行向量**变换：
///
///     [x' y' 1] = [x y 1] × | a b 0 |
///                           | c d 0 |
///                           | e f 1 |
///
/// 也就是 `x' = a·x + c·y + e`，`y' = b·x + d·y + f`。
///
/// 乘法顺序极易搞反，所以这里明确约定：**`lhs * rhs` 表示「先 lhs 再 rhs」**。
/// `cm` 算子的语义是「在现有坐标系里再套一层」，因此 `newCTM = M * CTM`；
/// 文本落到页面上是 `device = textPoint × Tm × CTM`。
public struct PDFPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PDFPoint(0, 0)

    public func distance(to other: PDFPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

public struct PDFRect: Sendable, Equatable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = min(x0, x1)
        self.y0 = min(y0, y1)
        self.x1 = max(x0, x1)
        self.y1 = max(y0, y1)
    }

    public init(_ points: [PDFPoint]) {
        guard let first = points.first else {
            self.init(x0: 0, y0: 0, x1: 0, y1: 0)
            return
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        self.init(x0: minX, y0: minY, x1: maxX, y1: maxY)
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var midY: Double { (y0 + y1) / 2 }
    public var area: Double { max(0, width) * max(0, height) }

    public func union(_ other: PDFRect) -> PDFRect {
        PDFRect(x0: min(x0, other.x0), y0: min(y0, other.y0),
                x1: max(x1, other.x1), y1: max(y1, other.y1))
    }

    public func intersects(_ other: PDFRect) -> Bool {
        x0 < other.x1 && other.x0 < x1 && y0 < other.y1 && other.y0 < y1
    }

    /// 四周各向外扩 `pad`（负值即内缩）。
    public func expanded(by pad: Double) -> PDFRect {
        expanded(x: pad, y: pad)
    }

    /// 按轴分别外扩。
    public func expanded(x: Double, y: Double) -> PDFRect {
        PDFRect(x0: x0 - x, y0: y0 - y, x1: x1 + x, y1: y1 + y)
    }

    public func intersectionArea(_ other: PDFRect) -> Double {
        let w = min(x1, other.x1) - max(x0, other.x0)
        let h = min(y1, other.y1) - max(y0, other.y0)
        return max(0, w) * max(0, h)
    }

    /// 并集面积算出的 IoU，用于判断两个框是否「其实是同一块」。
    public func iou(_ other: PDFRect) -> Double {
        let inter = intersectionArea(other)
        guard inter > 0 else { return 0 }
        let merged = area + other.area - inter
        return merged > 0 ? inter / merged : 0
    }

    /// 纵向重叠比例（相对较矮的那个）。
    public func verticalOverlap(_ other: PDFRect) -> Double {
        let h = min(y1, other.y1) - max(y0, other.y0)
        guard h > 0 else { return 0 }
        let smaller = min(height, other.height)
        return smaller > 0 ? h / smaller : 0
    }
}

public struct PDFMatrix: Sendable, Equatable {
    public var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    public init(_ a: Double, _ b: Double, _ c: Double,
                _ d: Double, _ e: Double, _ f: Double) {
        self.a = a; self.b = b; self.c = c
        self.d = d; self.e = e; self.f = f
    }

    public static let identity = PDFMatrix(1, 0, 0, 1, 0, 0)

    public static func translation(_ tx: Double, _ ty: Double) -> PDFMatrix {
        PDFMatrix(1, 0, 0, 1, tx, ty)
    }

    public func applied(to p: PDFPoint) -> PDFPoint {
        PDFPoint(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }

    /// 只旋转/缩放，不平移——用于把「方向」从文本空间带到页面空间。
    public func appliedToVector(_ p: PDFPoint) -> PDFPoint {
        PDFPoint(a * p.x + c * p.y, b * p.x + d * p.y)
    }

    /// `lhs * rhs` = 先 lhs 再 rhs。
    public static func * (lhs: PDFMatrix, rhs: PDFMatrix) -> PDFMatrix {
        PDFMatrix(
            lhs.a * rhs.a + lhs.b * rhs.c,
            lhs.a * rhs.b + lhs.b * rhs.d,
            lhs.c * rhs.a + lhs.d * rhs.c,
            lhs.c * rhs.b + lhs.d * rhs.d,
            lhs.e * rhs.a + lhs.f * rhs.c + rhs.e,
            lhs.e * rhs.b + lhs.f * rhs.d + rhs.f)
    }

    /// 从 PDF 数组 `[a b c d e f]` 构造；不够 6 个数就返回 nil（脏数据常见）。
    public init?(array: [PDFValue]) {
        let values = array.compactMap(\.doubleValue)
        guard values.count == 6 else { return nil }
        self.init(values[0], values[1], values[2], values[3], values[4], values[5])
    }

    /// 文本渲染方向与水平轴的夹角（弧度），用于识别旋转文字。
    public var rotationAngle: Double {
        atan2(b, a)
    }

    /// 方向的统一缩放因子（用于估算「这个字号在页面上实际多大」）。
    public var scaleMagnitude: Double {
        let sx = (a * a + b * b).squareRoot()
        let sy = (c * c + d * d).squareRoot()
        return (sx + sy) / 2
    }
}
