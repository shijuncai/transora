import Foundation

/// 像素级相似度：掩膜外差异、模糊后的版面 SSIM。
///
/// 两件事要分清：
///     - **掩膜外像素差**（R1）是**硬指标**。只要不落在文本掩膜里，图片、矢量、
///       底色、页面框就必须逐像素相同。这里按「逐像素最大通道差」统计，
///       不做任何平均——平均会把一小块明显的错位摊薄成 0.3/255 的「可接受误差」。
///     - **版面 SSIM**（R6）是**软指标**。单语同版式下文字内容整体换了，
///       原始 SSIM 必然掉到 0.5 以下，拿它当门禁只会天天报警。
///       所以 R6 用的是**先模糊再比**：模糊半径按行高量级取，比的是
///       「墨迹分布」——标题还在原来那一行、两栏还在两栏、图还在图的框里。
public enum PDFSimilarity {

    public struct Region: Sendable, Encodable {
        public var x0: Double
        public var y0: Double
        public var x1: Double
        public var y1: Double
        public var pixels: Int
    }

    public struct DiffResult: Sendable {
        /// 两张图尺寸/DPI 不一致时为 false，此时其它字段无意义
        public var comparable = true
        public var comparedPixels = 0
        public var diffPixels = 0
        /// 掩膜外所有像素的最大通道差（0…255）
        public var maxDelta = 0
        public var meanDelta = 0.0
        public var ratio = 0.0
        public var regions: [Region] = []
    }

    public struct SSIMResult: Sendable, Encodable {
        public var mean = 0.0
        public var min = 0.0
        /// 局部 SSIM < 0.6 的窗口占比：整体均值会被大片空白拉高，这个比例更能暴露局部塌陷
        public var weakRatio = 0.0
        public var samples = 0
    }

    // MARK: - 掩膜外逐像素差

    public static func diff(
        _ a: PDFPageImage, _ b: PDFPageImage,
        mask: PDFPixelMask?, tolerance: Int = 2, regionTile: Int = 32
    ) -> DiffResult {
        var result = DiffResult()
        guard a.width == b.width, a.height == b.height, !a.isEmpty, !b.isEmpty else {
            result.comparable = false
            result.maxDelta = 255
            result.ratio = 1
            return result
        }
        let width = a.width, height = a.height
        let tile = max(8, regionTile)
        let tilesX = (width + tile - 1) / tile
        let tilesY = (height + tile - 1) / tile
        var tileHits = [Int](repeating: 0, count: tilesX * tilesY)
        var compared = 0, differing = 0, maxDelta = 0
        var sumDelta = 0

        a.rgb.withUnsafeBufferPointer { pa in
            b.rgb.withUnsafeBufferPointer { pb in
                let maskBits = mask?.bits ?? []
                let useMask = mask.map { $0.width == width && $0.height == height } ?? false
                for y in 0..<height {
                    let rowStart = y * width
                    var s = rowStart * 3
                    let tileRow = (y / tile) * tilesX
                    for x in 0..<width {
                        if useMask && maskBits[rowStart + x] != 0 {
                            s += 3
                            continue
                        }
                        let dr = abs(Int(pa[s]) - Int(pb[s]))
                        let dg = abs(Int(pa[s + 1]) - Int(pb[s + 1]))
                        let db = abs(Int(pa[s + 2]) - Int(pb[s + 2]))
                        let delta = max(dr, max(dg, db))
                        compared += 1
                        if delta > 0 {
                            sumDelta += delta
                            if delta > maxDelta { maxDelta = delta }
                            if delta > tolerance {
                                differing += 1
                                tileHits[tileRow + x / tile] += 1
                            }
                        }
                        s += 3
                    }
                }
            }
        }

        result.comparedPixels = compared
        result.diffPixels = differing
        result.maxDelta = maxDelta
        result.meanDelta = compared > 0 ? Double(sumDelta) / Double(compared) : 0
        result.ratio = compared > 0 ? Double(differing) / Double(compared) : 0
        result.regions = mergeTiles(
            tileHits, tilesX: tilesX, tilesY: tilesY, tile: tile,
            image: a, limit: 5)
        return result
    }

    /// 把有差异的瓦片按四邻域并成矩形区域，按差异像素数排序取前 `limit` 个。
    /// 纯报告用途：给人一个「去哪一页的哪个位置看」的坐标。
    static func mergeTiles(
        _ hits: [Int], tilesX: Int, tilesY: Int, tile: Int,
        image: PDFPageImage, limit: Int
    ) -> [Region] {
        var visited = [Bool](repeating: false, count: hits.count)
        var regions: [Region] = []
        for start in 0..<hits.count where hits[start] > 0 && !visited[start] {
            var stack = [start]
            visited[start] = true
            var minTX = start % tilesX, maxTX = minTX
            var minTY = start / tilesX, maxTY = minTY
            var pixels = 0
            while let index = stack.popLast() {
                pixels += hits[index]
                let tx = index % tilesX, ty = index / tilesX
                minTX = min(minTX, tx); maxTX = max(maxTX, tx)
                minTY = min(minTY, ty); maxTY = max(maxTY, ty)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = tx + dx, ny = ty + dy
                    guard nx >= 0, ny >= 0, nx < tilesX, ny < tilesY else { continue }
                    let n = ny * tilesX + nx
                    if hits[n] > 0 && !visited[n] {
                        visited[n] = true
                        stack.append(n)
                    }
                }
            }
            let px0 = Double(minTX * tile), px1 = Double(min(maxTX + 1, tilesX) * tile)
            let py0 = Double(minTY * tile), py1 = Double(min(maxTY + 1, tilesY) * tile)
            regions.append(Region(
                x0: round(image.pageX(px0) * 10) / 10,
                y0: round(image.pageY(py1) * 10) / 10,
                x1: round(image.pageX(px1) * 10) / 10,
                y1: round(image.pageY(py0) * 10) / 10,
                pixels: pixels))
        }
        regions.sort { $0.pixels > $1.pixels }
        return Array(regions.prefix(limit))
    }

    // MARK: - SSIM

    public static func ssim(
        _ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
        window: Int = 11, sigma: Double = 1.5, stride: Int = 4
    ) -> SSIMResult {
        let empty = SSIMResult()
        guard width > window, height > window, a.count == width * height,
              b.count == width * height else { return empty }
        let radius = window / 2
        let kernel = gaussianKernel(window: window, sigma: sigma)

        var fa = [Float](repeating: 0, count: a.count)
        var fb = [Float](repeating: 0, count: b.count)
        var faa = [Float](repeating: 0, count: a.count)
        var fbb = [Float](repeating: 0, count: a.count)
        var fab = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            let x = Float(a[i]), y = Float(b[i])
            fa[i] = x; fb[i] = y
            faa[i] = x * x; fbb[i] = y * y; fab[i] = x * y
        }
        let ma = blur(fa, width: width, height: height, kernel: kernel, radius: radius)
        let mb = blur(fb, width: width, height: height, kernel: kernel, radius: radius)
        let maa = blur(faa, width: width, height: height, kernel: kernel, radius: radius)
        let mbb = blur(fbb, width: width, height: height, kernel: kernel, radius: radius)
        let mab = blur(fab, width: width, height: height, kernel: kernel, radius: radius)
        return compareMoments(ma, mb, maa, mbb, mab,
                              width: width, height: height, radius: radius, stride: stride)
    }

    /// 2×2 均值降采样。
    ///
    /// SSIM 不需要 144dpi 的分辨率：窗口本身就有 8–17 像素，先降采样等于用
    /// 4 倍少的像素算同一件事，耗时降到 1/4，结论不变（实测均值差 < 0.002）。
    static func decimate(
        _ gray: [UInt8], width: Int, height: Int, factor: Int = 2
    ) -> (data: [Float], width: Int, height: Int) {
        guard factor > 1, width > factor, height > factor else {
            var out = [Float](repeating: 0, count: gray.count)
            for i in 0..<gray.count { out[i] = Float(gray[i]) }
            return (out, width, height)
        }
        let w = width / factor, h = height / factor
        var out = [Float](repeating: 0, count: w * h)
        let area = Float(factor * factor)
        out.withUnsafeMutableBufferPointer { dst in
            gray.withUnsafeBufferPointer { src in
                for y in 0..<h {
                    for x in 0..<w {
                        var sum: Float = 0
                        for dy in 0..<factor {
                            let row = (y * factor + dy) * width + x * factor
                            for dx in 0..<factor { sum += Float(src[row + dx]) }
                        }
                        dst[y * w + x] = sum / area
                    }
                }
            }
        }
        return (out, w, h)
    }

    /// 未模糊的原始 SSIM（盒子窗 8×8）。只作报告参考：
    /// 单语同版式下字形整体换了，这个值必然低，不能当门禁。
    public static func rawSSIM(_ a: PDFPageImage, _ b: PDFPageImage, stride: Int = 4) -> SSIMResult {
        guard a.width == b.width, a.height == b.height, !a.isEmpty, !b.isEmpty else {
            return SSIMResult()
        }
        let ga = decimate(a.gray(), width: a.width, height: a.height)
        let gb = decimate(b.gray(), width: b.width, height: b.height)
        return ssimMoments(ga.data, gb.data, width: ga.width, height: ga.height,
                           window: 8, stride: stride)
    }

    /// 版面 SSIM：先按像素半径模糊（抹掉字形，留下墨迹分布），再算 SSIM。
    ///
    /// 这一条走**盒子窗**而不是高斯窗：全页 2M 像素 × 5 张矩量图，高斯卷积要 2 亿次乘加，
    /// 661 页就是分钟级；盒子模糊是滑窗 O(n)，两种窗对「墨迹分布」的结论没有区别。
    /// 需要高斯窗的精确值用 `ssim(_:_:...)`（测试里用它钉公式）。
    public static func layoutSSIM(
        _ a: PDFPageImage, _ b: PDFPageImage, blurRadius: Int = 6,
        window: Int = 17, stride: Int = 4
    ) -> SSIMResult {
        guard a.width == b.width, a.height == b.height, !a.isEmpty, !b.isEmpty else {
            return SSIMResult()
        }
        let ga = decimate(a.gray(), width: a.width, height: a.height)
        let gb = decimate(b.gray(), width: b.width, height: b.height)
        // 降采样 2× 后，blurRadius 也要折半才等价（6pt@144dpi ≈ 3@72dpi）
        let scaledBlur = max(1, blurRadius / 2)
        let ba = boxBlur(ga.data, width: ga.width, height: ga.height, radius: scaledBlur)
        let bb = boxBlur(gb.data, width: ga.width, height: ga.height, radius: scaledBlur)
        return ssimMoments(ba, bb, width: ga.width, height: ga.height,
                           window: max(7, window / 2), stride: stride)
    }

    /// 用盒子窗算 SSIM 的五个矩量，再套标准公式。
    public static func ssimMoments(
        _ a: [Float], _ b: [Float], width: Int, height: Int,
        window: Int = 17, stride: Int = 4
    ) -> SSIMResult {
        let result = SSIMResult()
        guard width > window, height > window, a.count == width * height,
              b.count == width * height else { return result }
        let radius = window / 2
        var aa = [Float](repeating: 0, count: a.count)
        var bb = [Float](repeating: 0, count: b.count)
        var ab = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            aa[i] = a[i] * a[i]
            bb[i] = b[i] * b[i]
            ab[i] = a[i] * b[i]
        }
        let ma = boxBlur(a, width: width, height: height, radius: radius)
        let mb = boxBlur(b, width: width, height: height, radius: radius)
        let maa = boxBlur(aa, width: width, height: height, radius: radius)
        let mbb = boxBlur(bb, width: width, height: height, radius: radius)
        let mab = boxBlur(ab, width: width, height: height, radius: radius)
        return compareMoments(ma, mb, maa, mbb, mab,
                              width: width, height: height,
                              radius: radius, stride: stride)
    }

    /// 标准 SSIM 公式（C1/C2 取 0.01/0.03 动态范围）。
    static func compareMoments(
        _ ma: [Float], _ mb: [Float], _ maa: [Float], _ mbb: [Float], _ mab: [Float],
        width: Int, height: Int, radius: Int, stride: Int
    ) -> SSIMResult {
        var result = SSIMResult()
        let c1 = (0.01 * 255.0) * (0.01 * 255.0)
        let c2 = (0.03 * 255.0) * (0.03 * 255.0)
        var sum = 0.0, minimum = 1.0, weak = 0, samples = 0
        var y = radius
        while y < height - radius {
            var x = radius
            while x < width - radius {
                let i = y * width + x
                let muA = Double(ma[i]), muB = Double(mb[i])
                let varA = max(0, Double(maa[i]) - muA * muA)
                let varB = max(0, Double(mbb[i]) - muB * muB)
                let cov = Double(mab[i]) - muA * muB
                let numerator = (2 * muA * muB + c1) * (2 * cov + c2)
                let denominator = (muA * muA + muB * muB + c1) * (varA + varB + c2)
                let value = denominator > 0 ? numerator / denominator : 1
                sum += value
                samples += 1
                if value < minimum { minimum = value }
                if value < 0.6 { weak += 1 }
                x += stride
            }
            y += stride
        }
        result.samples = samples
        guard samples > 0 else { return result }
        result.mean = sum / Double(samples)
        result.min = minimum
        result.weakRatio = Double(weak) / Double(samples)
        return result
    }

    // MARK: - 卷积核

    public static func gaussianKernel(window: Int, sigma: Double) -> [Float] {
        let radius = window / 2
        var kernel = [Float](repeating: 0, count: window)
        var total = 0.0
        for i in 0..<window {
            let d = Double(i - radius)
            let v = exp(-(d * d) / (2 * sigma * sigma))
            kernel[i] = Float(v)
            total += v
        }
        for i in 0..<window { kernel[i] /= Float(total) }
        return kernel
    }

    /// 可分离高斯：先横后纵。边界按夹取（clamp）处理，不留黑边。
    static func blur(
        _ src: [Float], width: Int, height: Int, kernel: [Float], radius: Int
    ) -> [Float] {
        var horizontal = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            horizontal.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var sum: Float = 0
                        for k in -radius...radius {
                            var sx = x + k
                            if sx < 0 { sx = 0 }
                            if sx >= width { sx = width - 1 }
                            sum += s[row + sx] * kernel[k + radius]
                        }
                        dst[row + x] = sum
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        horizontal.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        var sum: Float = 0
                        for k in -radius...radius {
                            var sy = y + k
                            if sy < 0 { sy = 0 }
                            if sy >= height { sy = height - 1 }
                            sum += s[sy * width + x] * kernel[k + radius]
                        }
                        dst[y * width + x] = sum
                    }
                }
            }
        }
        return out
    }

    /// 盒子模糊（滑窗求和，O(n)）。用于 R6 的「抹掉字形」。
    public static func boxBlur(
        _ src: [Float], width: Int, height: Int, radius: Int
    ) -> [Float] {
        guard radius > 0, width > 0, height > 0 else { return src }
        var horizontal = [Float](repeating: 0, count: src.count)
        let window = Float(radius * 2 + 1)
        src.withUnsafeBufferPointer { s in
            horizontal.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for x in -radius...radius {
                        let sx = min(max(x, 0), width - 1)
                        sum += s[row + sx]
                    }
                    for x in 0..<width {
                        dst[row + x] = sum / window
                        let out = min(max(x - radius, 0), width - 1)
                        let inn = min(max(x + radius + 1, 0), width - 1)
                        sum += s[row + inn] - s[row + out]
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        horizontal.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { dst in
                for x in 0..<width {
                    var sum: Float = 0
                    for y in -radius...radius {
                        let sy = min(max(y, 0), height - 1)
                        sum += s[sy * width + x]
                    }
                    for y in 0..<height {
                        dst[y * width + x] = sum / window
                        let o = min(max(y - radius, 0), height - 1)
                        let i = min(max(y + radius + 1, 0), height - 1)
                        sum += s[i * width + x] - s[o * width + x]
                    }
                }
            }
        }
        return out
    }
}
