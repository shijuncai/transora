import Foundation

/// 结构级比对：把「字」丢掉，只比「结构」。
///
/// 为什么 R1 不能只靠 IL 掩膜：
///     IL 的框来自文本提取，而真实文档里存在「坐标翻转 `cm`」「非常规字体矩阵」等情况，
///     提取出来的框与渲染出来的墨迹可能整体偏移几十 pt。掩膜一偏，
///     换字体导致的所有字形差异就全落在掩膜外面，R1 变成一台噪声机器——
///     真问题（图被改了）反而淹在里面。
///
/// 这里换一个不依赖 IL 的判据：**连通域尺度**。
///     ① 二值化两张图（墨/白）；
///     ② 去掉面积小于 `minComponentPixels` 的连通域——汉字的笔画、标点、下划线都在这一档；
///     ③ 剩下的就是「结构」：图片、色块、表格线、矢量图形；
///     ④ 两张结构图逐像素比，差异必须为 0。
///
/// 这个判据的语义很清楚：**文字怎么换都行，结构一个像素都不能动**。
/// 它比掩膜法更宽松（小图标消失抓不到），但极稳——不会因为字体或坐标问题误报。
public enum PDFStructuralDiff {
    public struct Result: Sendable {
        public var comparable = true
        /// 只在 A 有结构、B 没有的像素
        public var lostPixels = 0
        /// 只在 B 有结构、A 没有的像素
        public var gainedPixels = 0
        public var maxDelta = 0
        public var regions: [PDFSimilarity.Region] = []
        public var componentsA = 0
        /// A 的结构像素总数（用来算「丢了百分之几」）
        public var structurePixels = 0
        public var componentsB = 0
        /// 被当作「文字」丢掉的小连通域占比
        public var textRatio = 0.0
        public var diffPixels: Int { lostPixels + gainedPixels }
    }

    /// - Parameters:
    ///   - minComponentPixels: 小于它的连通域视为文字。144dpi 下 240 像素 ≈ 10pt×6pt
    ///   - tolerance: 结构图的通道容差（1 就够，结构是实色）
    /// - Parameter ignore: 我们主动新画的非文本墨迹（页脚注释分隔线等），不参与结构比对
    public static func compare(
        _ a: PDFPageImage, _ b: PDFPageImage,
        minComponentPixels: Int = 240, tolerance: Int = 1, regionTile: Int = 32,
        ignore: [PDFRect] = []
    ) -> Result {
        var result = Result()
        guard a.width == b.width, a.height == b.height, !a.isEmpty, !b.isEmpty else {
            result.comparable = false
            result.maxDelta = 255
            result.lostPixels = 1
            return result
        }
        let width = a.width, height = a.height
        let inkA = inkMap(a), inkB = inkMap(b)
        let structA = keepLargeComponents(inkA, width: width, height: height,
                                          minPixels: minComponentPixels)
        let structB = keepLargeComponents(inkB, width: width, height: height,
                                          minPixels: minComponentPixels)
        result.componentsA = structA.components
        result.componentsB = structB.components
        result.structurePixels = structA.pixels
        let ignored = ignore.isEmpty ? nil : PDFPixelMask.build(
            image: a, rects: ignore, dilatePoints: 2)
        let inkCount = inkA.count(where: { $0 })
        result.textRatio = inkCount > 0
            ? 1 - Double(structA.pixels) / Double(inkCount) : 0

        // 双向差异：A 有结构 B 无 → 丢了；反之 → 多了。各向外扩 1 像素容忍抗锯齿边缘。
        let dilatedA = dilate(structA.map, width: width, height: height)
        let dilatedB = dilate(structB.map, width: width, height: height)
        let tilesX = (width + regionTile - 1) / regionTile
        let tilesY = (height + regionTile - 1) / regionTile
        var tileHits = [Int](repeating: 0, count: tilesX * tilesY)
        var lost = 0, gained = 0, maxDelta = 0

        for y in 0..<height {
            let row = y * width
            let tileRow = (y / regionTile) * tilesX
            for x in 0..<width {
                if let ignored, ignored.contains(x: x, y: y) { continue }
                let inA = structA.map[row + x]
                let inB = structB.map[row + x]
                if inA && !dilatedB[row + x] {
                    lost += 1
                    tileHits[tileRow + x / regionTile] += 1
                    maxDelta = max(maxDelta, delta(a, b, row + x, width: width, tolerance: tolerance))
                } else if inB && !dilatedA[row + x] {
                    gained += 1
                    tileHits[tileRow + x / regionTile] += 1
                    maxDelta = max(maxDelta, delta(a, b, row + x, width: width, tolerance: tolerance))
                }
            }
        }
        result.lostPixels = lost
        result.gainedPixels = gained
        result.maxDelta = maxDelta
        result.regions = PDFSimilarity.mergeTiles(
            tileHits, tilesX: tilesX, tilesY: tilesY, tile: regionTile, image: a, limit: 5)
        return result
    }

    static func delta(_ a: PDFPageImage, _ b: PDFPageImage, _ index: Int, width: Int,
                      tolerance: Int) -> Int {
        let i = index * 3
        return max(abs(Int(a.rgb[i]) - Int(b.rgb[i])),
                   max(abs(Int(a.rgb[i + 1]) - Int(b.rgb[i + 1])),
                       abs(Int(a.rgb[i + 2]) - Int(b.rgb[i + 2]))))
    }

    /// 亮度低于 200 算有墨。比掩膜用的 250 更严：抗锯齿的浅灰边不算结构。
    static func inkMap(_ image: PDFPageImage) -> [Bool] {
        var map = [Bool](repeating: false, count: image.width * image.height)
        let gray = image.gray()
        for i in 0..<gray.count { map[i] = gray[i] < 200 }
        return map
    }

    /// 去小连通域：四邻域泛洪，面积 ≥ `minPixels` 的保留。
    static func keepLargeComponents(
        _ ink: [Bool], width: Int, height: Int, minPixels: Int
    ) -> (map: [Bool], pixels: Int, components: Int) {
        var visited = [Bool](repeating: false, count: ink.count)
        var keep = [Bool](repeating: false, count: ink.count)
        var stack: [Int] = []
        var keptPixels = 0, components = 0
        for start in 0..<ink.count where ink[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var members: [Int] = []
            while let index = stack.popLast() {
                members.append(index)
                let x = index % width, y = index / width
                if x > 0 {
                    let n = index - 1
                    if ink[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
                if x + 1 < width {
                    let n = index + 1
                    if ink[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
                if y > 0 {
                    let n = index - width
                    if ink[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
                if y + 1 < height {
                    let n = index + width
                    if ink[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
            }
            if members.count >= minPixels {
                components += 1
                keptPixels += members.count
                for index in members { keep[index] = true }
            }
        }
        return (keep, keptPixels, components)
    }

    /// 3×3 膨胀（分离两步：先横向再纵向，避免 9 次邻域判断）
    static func dilate(_ map: [Bool], width: Int, height: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: map.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where map[row + x] {
                horizontal[row + x] = true
                if x > 0 { horizontal[row + x - 1] = true }
                if x + 1 < width { horizontal[row + x + 1] = true }
            }
        }
        var out = [Bool](repeating: false, count: map.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where horizontal[row + x] {
                out[row + x] = true
                if y > 0 { out[row - width + x] = true }
                if y + 1 < height { out[row + width + x] = true }
            }
        }
        return out
    }
}
