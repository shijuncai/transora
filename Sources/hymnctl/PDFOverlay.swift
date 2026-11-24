import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import HymnCore

/// 调试用叠加图：把 IL 的块框画到页面渲染图上。
///
/// 为什么需要它：坐标一旦错位，只看文字内容或日志都看不出来——
/// 提取出来的字全对，位置全错，报告里「召回 100%」依然成立。
/// 叠一张图，框和字对不对齐一眼就看见。
enum PDFOverlay {
    struct Box {
        var rect: PDFRect
        var color: (r: Double, g: Double, b: Double)
        var label: String?
    }

    /// 直接把一张 PDFPageImage 写成 PNG（可选再画框）。
    static func writeImage(_ image: PDFPageImage, to output: String,
                           boxes: [Box] = []) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain: "overlay", code: 1) }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let provider = CGDataProvider(data: Data(image.rgb) as CFData),
           let bitmap = CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: image.width * 3, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) {
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        context.setLineWidth(1.2)
        for box in boxes {
            let x0 = image.pixelX(box.rect.x0), x1 = image.pixelX(box.rect.x1)
            // CGContext 原点在左下：页面下边（page y0）落在 CG 的小 y，
            // 而上边（page y1）落在 CG 的大 y。早先这里把 yTop 当下边用，
            // height 算出来是负数被 max(0.5) 兜住 —— 结果所有框都画成一根细线，
            // 看起来像「IL 坐标整体偏上」，把真问题掩盖了。
            let lower = Double(image.height) - image.pixelY(box.rect.y1)
            let upper = Double(image.height) - image.pixelY(box.rect.y0)
            context.setStrokeColor(red: CGFloat(box.color.r), green: CGFloat(box.color.g),
                                   blue: CGFloat(box.color.b), alpha: 0.95)
            context.stroke(CGRect(x: x0, y: lower, width: max(0.5, x1 - x0),
                                  height: max(0.5, upper - lower)))
        }
        guard let out = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: output) as CFURL,
                UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "overlay", code: 2) }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }

    static func write(
        pdf path: String, page: Int, boxes: [Box], to output: String, dpi: Double = 144
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let image = PDFPageRenderer.render(data: data, index: page - 1,
                                                 options: .init(dpi: dpi)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain: "overlay", code: 1) }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // 一次贴图（不做逐像素 fill：1080p 上是百万次调用，慢到没法用）
        if let provider = CGDataProvider(data: Data(image.rgb) as CFData),
           let bitmap = CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: image.width * 3, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) {
            // CGContext 是 y 向上的坐标系，而 CGImage 的第一行贴在上边，
            // 所以直接 draw 即可正立 —— 再翻一次会得到倒立的图（踩过）。
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        context.setLineWidth(1.2)
        for box in boxes {
            let x0 = image.pixelX(box.rect.x0), x1 = image.pixelX(box.rect.x1)
            // CGContext 原点在左下：页面下边（page y0）落在 CG 的小 y，
            // 而上边（page y1）落在 CG 的大 y。早先这里把 yTop 当下边用，
            // height 算出来是负数被 max(0.5) 兜住 —— 结果所有框都画成一根细线，
            // 看起来像「IL 坐标整体偏上」，把真问题掩盖了。
            let lower = Double(image.height) - image.pixelY(box.rect.y1)
            let upper = Double(image.height) - image.pixelY(box.rect.y0)
            context.setStrokeColor(red: CGFloat(box.color.r), green: CGFloat(box.color.g),
                                   blue: CGFloat(box.color.b), alpha: 0.95)
            context.stroke(CGRect(x: x0, y: lower, width: max(0.5, x1 - x0),
                                  height: max(0.5, upper - lower)))
        }
        guard let out = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: output) as CFURL,
                UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "overlay", code: 2) }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }
}
