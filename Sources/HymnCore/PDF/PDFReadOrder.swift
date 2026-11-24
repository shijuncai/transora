import Foundation

/// R7：阅读顺序。
///
/// 这里检查的是**输出**的顺序，而不是「看起来对不对」：
/// 排版是按 IL 顺序依次投放的，如果两个段的投放顺序和它们的视觉顺序相反，
/// 屏幕阅读器与「复制粘贴」拿到就是错乱的句子——图片和表格都对了，
/// 但读起来是倒的，这在无障碍与可检索性上是硬伤。
///
/// 判据（刻意保守，避免把正常版式报成问题）：
///     ① 先按左沿聚类分栏（容差 24pt，与 P3 的 `columnRightEdge` 同一口径）；
///     ② 期望顺序 = 先栏后行（同栏内自上而下）；
///     ③ 只有「栏内上下颠倒且横向确实重叠」才算逆序。
///        横向不重叠的两个块（左右并排的小图注）不算——它们本来就可以任意序。
public enum PDFReadOrder {
    public struct Item: Sendable {
        public var id: String
        public var box: PDFRect
        public init(id: String, box: PDFRect) {
            self.id = id
            self.box = box
        }
    }

    public struct Result: Sendable, Encodable {
        public var columns = 0
        /// 逆序对数量
        public var inversions = 0
        /// 举例（最多 5 条）："b3 应在 b1 之前"
        public var samples: [String] = []
        public var ordered: [String] = []
    }

    public static func check(
        items: [Item], columnTolerance: Double = 24, verticalSlack: Double = 2
    ) -> Result {
        var result = Result()
        guard items.count > 1 else {
            result.columns = items.isEmpty ? 0 : 1
            result.ordered = items.map(\.id)
            return result
        }

        // ① 按左沿聚类
        let sortedByX = items.sorted { $0.box.x0 < $1.box.x0 }
        var columnOf: [String: Int] = [:]
        var current = 0
        var anchor = sortedByX[0].box.x0
        for item in sortedByX {
            if item.box.x0 - anchor > columnTolerance {
                current += 1
                anchor = item.box.x0
            }
            columnOf[item.id] = current
        }
        result.columns = current + 1

        // ② 期望顺序
        let expected = items.sorted { lhs, rhs in
            let lc = columnOf[lhs.id] ?? 0, rc = columnOf[rhs.id] ?? 0
            if lc != rc { return lc < rc }
            if abs(lhs.box.y1 - rhs.box.y1) > verticalSlack { return lhs.box.y1 > rhs.box.y1 }
            return lhs.box.x0 < rhs.box.x0
        }
        let expectedIndex = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($1.id, $0) })
        result.ordered = expected.map(\.id)

        // ③ 逆序对：只看「同栏 + 横向重叠」的块对
        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                let a = items[i], b = items[j]
                guard (columnOf[a.id] ?? 0) == (columnOf[b.id] ?? 0) else { continue }
                let overlap = min(a.box.x1, b.box.x1) - max(a.box.x0, b.box.x0)
                guard overlap > min(a.box.width, b.box.width) * 0.3 else { continue }
                let ai = expectedIndex[a.id] ?? 0, bi = expectedIndex[b.id] ?? 0
                if ai > bi {
                    result.inversions += 1
                    if result.samples.count < 5 {
                        result.samples.append("\(b.id) 应在 \(a.id) 之前")
                    }
                }
            }
        }
        return result
    }
}
