import AppKit
import Foundation

// TransOra 的 App 图标兜底实现（不依赖任何图片素材，纯代码绘制）。
// 只在 Assets/logo-source.png 缺失时使用：渐变圆角底 + 白色「TO」字。
// 正式图标由 Scripts/make-icon-from-image.swift 从品牌图生成。

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "./HymnTranslate.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let top = NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.98, alpha: 1)
let bottom = NSColor(calibratedRed: 0.58, green: 0.27, blue: 0.93, alpha: 1)

for (name, px) in entries {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    let inset = s * 0.07
    let plate = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
        xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [top, bottom])?.draw(in: plate, angle: -45)

    // 「TO」二字标，对应品牌图里的渐变 Monogram。
    let font = NSFont(name: "HelveticaNeue-Bold", size: s * 0.42)
        ?? NSFont.systemFont(ofSize: s * 0.42, weight: .bold)
    let text = NSAttributedString(
        string: "TO",
        attributes: [.font: font,
                     .foregroundColor: NSColor.white,
                     .kern: -s * 0.02])
    let textSize = text.size()
    text.draw(at: NSPoint(x: (s - textSize.width) / 2,
                          y: (s - textSize.height) / 2 - s * 0.01))
    NSGraphicsContext.restoreGraphicsState()

    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
print("ICONSET_OK \(outDir)")
