import Foundation
import CoreGraphics

/// 页面光栅化：把 PDF 页渲染成 RGB 位图，供相似度分析用。
///
/// 为什么用 CoreGraphics 而不是 PDFKit：
///     ① `CGPDFDocument` 只有一个入口、行为稳定，PDFKit 会做「智能」重建
///        （重排段落、补空白页），拿它当比对基准等于拿一个会改写内容的阅读器当尺子；
///     ② 这里是**同一段代码渲染原页与新页**，抗锯齿策略完全一致，
///        差异只可能来自 PDF 内容本身，不会来自渲染器偏好；
///     ③ 不引 AppKit，CLI 里也能跑。
///
/// 坐标系：位图第 0 行是**页面顶部**（与所有看图工具一致），换算见 `pixelX/pixelY`。
public struct PDFPageImage: Sendable {
    public var width: Int
    public var height: Int
    public var dpi: Double
    /// 页面 MediaBox（pt，左下原点）
    public var pageBox: PDFRect
    public var rotation: Int
    /// RGB888，行优先，无行尾填充
    public var rgb: [UInt8]

    public var scale: Double { dpi / 72.0 }

    public var pixelCount: Int { width * height }
    public var isEmpty: Bool { width <= 0 || height <= 0 || rgb.count < pixelCount * 3 }

    public func pixelX(_ x: Double) -> Double { (x - pageBox.x0) * scale }
    /// 页面 y（向上）→ 位图行号（向下）
    public func pixelY(_ y: Double) -> Double { (pageBox.y1 - y) * scale }
    public func pageX(_ px: Double) -> Double { px / scale + pageBox.x0 }
    public func pageY(_ py: Double) -> Double { pageBox.y1 - py / scale }

    /// 亮度（Rec.601）。SSIM 只看结构，用亮度足够。
    public func gray() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixelCount)
        guard !isEmpty else { return out }
        rgb.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = 0, d = 0
                for _ in 0..<pixelCount {
                    let r = Int(src[s]), g = Int(src[s + 1]), b = Int(src[s + 2])
                    dst[d] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
                    s += 3; d += 1
                }
            }
        }
        return out
    }

    /// 非白像素数（阈值 250：低于它就算「有墨」）
    public func inkPixelCount(threshold: Int = 250) -> Int {
        guard !isEmpty else { return 0 }
        var count = 0
        rgb.withUnsafeBufferPointer { src in
            var s = 0
            for _ in 0..<pixelCount {
                if Int(src[s]) < threshold || Int(src[s + 1]) < threshold || Int(src[s + 2]) < threshold {
                    count += 1
                }
                s += 3
            }
        }
        return count
    }

    /// 有墨区域的页面坐标包围盒；整页空白返回 nil。
    public func inkBounds(threshold: Int = 250) -> PDFRect? {
        guard !isEmpty else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        rgb.withUnsafeBufferPointer { src in
            for y in 0..<height {
                var s = y * width * 3
                for x in 0..<width {
                    if Int(src[s]) < threshold || Int(src[s + 1]) < threshold || Int(src[s + 2]) < threshold {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                    s += 3
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return PDFRect(x0: pageX(Double(minX)), y0: pageY(Double(maxY + 1)),
                       x1: pageX(Double(maxX + 1)), y1: pageY(Double(minY)))
    }
}

public enum PDFPageRenderer {
    public struct Options: Sendable {
        /// 144 dpi = 2× pt。R1 要求能分辨 0.5pt 的线，低于 120dpi 会把细线糊掉。
        public var dpi = 144.0
        /// 渲染前铺白的灰度（PDF 允许无背景，铺白让两张图可比）
        public var background = 1.0
        public var antialias = true

        public init(dpi: Double = 144.0, background: Double = 1.0, antialias: Bool = true) {
            self.dpi = dpi
            self.background = background
            self.antialias = antialias
        }
    }

    public static func open(_ data: Data) -> CGPDFDocument? {
        guard !data.isEmpty, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    /// 页面空间 → 位图设备空间的变换（`dpi/72` 缩放 + `/Rotate` + MediaBox 原点归零）。
    ///
    /// **不能用 `CGPDFPage.getDrawingTransform`**：它在 macOS 27 上对 `rect` 不做缩放，
    /// 只把 MediaBox 按 1:1 居中放进去（实测 1920×1080 目标 → `a=1, tx=480, ty=270`，
    /// `preserveAspectRatio` 传 true/false 结果一样）。后果非常隐蔽：
    /// 144 dpi 的图看起来「有内容、能比对」，但页面只占画布正中 960×540，
    /// 而 `pixelX/pixelY` 按 `scale=2` 换算 ⇒ 掩膜、裁剪、坐标探针全部错位一倍。
    /// P4 的整批像素指标都是在这个错标定下算的，P5 修正后重跑。
    static func pageTransform(media: CGRect, rotation: Int, scale: Double)
        -> CGAffineTransform {
        // 先把 MediaBox 左上角挪到原点
        let shift = CGAffineTransform(translationX: -media.minX, y: -media.minY)
        // 再按 /Rotate 旋转到「阅读方向」（y 向上、原点左下）
        let spin: CGAffineTransform
        let w = media.width, h = media.height
        switch rotation {
        case 90:  spin = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: spin = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: spin = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default:  spin = .identity
        }
        let zoom = CGAffineTransform(scaleX: scale, y: scale)
        return shift.concatenating(spin).concatenating(zoom)
    }

    public static func pageCount(_ data: Data) -> Int {
        open(data)?.numberOfPages ?? 0
    }

    /// 渲染第 `index` 页（**0 基**，与项目其它地方一致）。
    public static func render(
        document: CGPDFDocument, index: Int, options: Options = Options()
    ) -> PDFPageImage? {
        guard index >= 0, index < document.numberOfPages,
              let page = document.page(at: index + 1) else { return nil }

        let media = page.getBoxRect(.mediaBox)
        let rotation = (Int(page.rotationAngle) % 360 + 360) % 360
        let swapped = rotation == 90 || rotation == 270
        let logicalWidth = Double(media.width)
        let logicalHeight = Double(media.height)

        let scale = options.dpi / 72.0
        let pixelWidth = max(1, Int((logicalWidth * scale).rounded()))
        let pixelHeight = max(1, Int((logicalHeight * scale).rounded()))
        // 旋转页的位图宽高互换；此时坐标系不再是「页面 x/y」，分析环节会跳过像素检查
        let width = swapped ? pixelHeight : pixelWidth
        let height = swapped ? pixelWidth : pixelHeight

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        // CGContext 不支持 24bpp RGB（返回 nil），必须先画到 32bpp（跳过 alpha）再抽 RGB。
        // 这是个纯实现细节：外部的 PDFPageImage 依旧是紧密排列的 RGB888。
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        let painted: Bool = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.setFillColor(gray: CGFloat(options.background), alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setShouldAntialias(options.antialias)
            context.setAllowsAntialiasing(options.antialias)
            context.interpolationQuality = .high
            context.concatenate(pageTransform(
                media: media, rotation: rotation, scale: scale))
            context.drawPDFPage(page)
            return true
        }
        guard painted else { return nil }

        rgba.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                var s = 0, d = 0
                for _ in 0..<(width * height) {
                    dst[d] = src[s]
                    dst[d + 1] = src[s + 1]
                    dst[d + 2] = src[s + 2]
                    s += 4; d += 3
                }
            }
        }

        return PDFPageImage(
            width: width, height: height, dpi: options.dpi,
            pageBox: PDFRect(x0: Double(media.minX), y0: Double(media.minY),
                             x1: Double(media.maxX), y1: Double(media.maxY)),
            rotation: rotation, rgb: rgb)
    }

    public static func render(
        data: Data, index: Int, options: Options = Options()
    ) -> PDFPageImage? {
        guard let document = open(data) else { return nil }
        return render(document: document, index: index, options: options)
    }

    /// 一次打开、多页渲染。调用方负责限制页数，避免一次吃掉几 GB。
    public static func render(
        data: Data, indices: [Int], options: Options = Options()
    ) -> [Int: PDFPageImage] {
        guard let document = open(data) else { return [:] }
        var out: [Int: PDFPageImage] = [:]
        out.reserveCapacity(indices.count)
        for index in indices {
            if let image = render(document: document, index: index, options: options) {
                out[index] = image
            }
        }
        return out
    }
}
