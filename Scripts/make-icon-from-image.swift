import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 从一张方形品牌图生成 macOS iconset（TransOra 的「白色圆角卡 + 渐变 TO」）。
//
// 旧版脚本对「蓝底白字」图做四角洪泛填充，把白背景挖成透明；新品牌图是
// **白卡放在白底上**，卡片本身也是白的，洪泛填充会连卡片一起吃掉，所以改成
// 按边缘台阶定位卡片：
//   1. 沿若干扫描线找亮度突变（卡片边缘与背景阴影之间约 15 级台阶），
//      背景自身的柔和渐变每像素只有 1 级左右，不会被误判；
//   2. 取中位数得到卡片的四个边，拼成正方形；
//   3. 按原图圆角比例（22.37%）做圆角遮罩，卡片外全部透明；
//   4. 内容占 1024 画布 92%、居中，导出 10 个尺寸。
// 用法：make-icon-from-image <源图> <输出 .iconset 目录>

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-icon-from-image <source.png> <out.iconset>")
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2])

guard let image = NSImage(contentsOf: inputURL),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("ICON_FAIL cannot load \(inputURL.path)")
    exit(3)
}

let width = source.width
let height = source.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let scanContext = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("ICON_FAIL cannot create scan context")
    exit(4)
}
scanContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

func luminance(_ x: Int, _ y: Int) -> Int {
    let i = (y * width + x) * 4
    return (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
}

// 单条扫描线会被卡片上的标记、圆角弧线带偏，所以先做「平均亮度剖面」：
// 取中间带的均值，卡片内部是一片均匀的 253~254，卡片外侧是阴影谷（236~249），
// 再往外又回到 255。按「从边缘向内找到谷底，再往回爬到平台」定位卡片边。
func profile(horizontal: Bool) -> [Double] {
    let lo = horizontal ? height * 35 / 100 : width * 35 / 100
    let hi = horizontal ? height * 65 / 100 : width * 65 / 100
    let count = horizontal ? width : height
    var result = [Double](repeating: 0, count: count)
    for index in 0..<count {
        var sum = 0.0
        for other in lo..<hi {
            sum += Double(horizontal ? luminance(index, other) : luminance(other, index))
        }
        result[index] = sum / Double(hi - lo)
    }
    return result
}

/// 从图像边缘向里找阴影谷底，再找到亮度回升到平台（卡片内部）的第一点。
func plateEdge(_ values: [Double], reversed: Bool) -> Int? {
    let count = values.count
    let band = max(4, count / 8)           // 只在最外 12.5% 里找谷：再往里就会撞上卡片上的标记
    func value(_ i: Int) -> Double { reversed ? values[count - 1 - i] : values[i] }
    var valleyIndex = 1
    var valleyValue = value(1)
    for i in 1..<band where value(i) < valleyValue {
        valleyValue = value(i)
        valleyIndex = i
    }
    var index = valleyIndex
    while index < count / 2 {
        if value(index) >= valleyValue + 2.5 {
            // 回升到平台后取第一次越过阈值的点，往回退 1 像素贴住卡片边。
            let raw = reversed ? count - 1 - index : index
            return max(0, min(count - 1, reversed ? raw + 1 : raw - 1))
        }
        index += 1
    }
    return nil
}

let columnProfile = profile(horizontal: true)   // 每一列的平均亮度 → 左右边
let rowProfile = profile(horizontal: false)     // 每一行的平均亮度 → 上下边
let dbgL = plateEdge(columnProfile, reversed: false)
let dbgR = plateEdge(columnProfile, reversed: true)
let dbgT = plateEdge(rowProfile, reversed: false)
let dbgB = plateEdge(rowProfile, reversed: true)
guard let left = dbgL, let right = dbgR, let top = dbgT, let bottom = dbgB,
      right - left > width / 2, bottom - top > height / 2 else {
    print("ICON_FAIL plate edges not found l=\(String(describing: dbgL)) r=\(String(describing: dbgR)) "
          + "t=\(String(describing: dbgT)) b=\(String(describing: dbgB))")
    exit(5)
}

// 卡片不一定严格正方形（这张素材是 1033×1008），按实测四边裁剪，
// 缩放到画布时保持长宽比，不做拉伸。
let plateWidth = right - left + 1
let plateHeight = bottom - top + 1
let cropX = left
let cropY = top

// 缓冲区行序与 CGImage.cropping 的坐标都是**从上往下**（第 0 行是图像顶部），
// 这里用亮度剖面量出的 top 就是裁剪矩形的 y 原点。
// 踩过的坑：早先按「上下文左下原点」又翻了一次 y，结果裁切框整体上移几十像素，
// 把 TO 的圆底和 T 的斜笔同时切出一道平口。
let cropRect = CGRect(x: cropX, y: cropY, width: plateWidth, height: plateHeight)
guard let cropped = scanContext.makeImage()?.cropping(to: cropRect) else {
    print("ICON_FAIL crop failed")
    exit(6)
}

// 扣白底：品牌图本身是「白卡 + 渐变 TO」，这里只保留 TO 标记，白色卡片与
// 它下面的投影全部变成透明。判据用「饱和度 + 亮度」两级：
//   · 中性灰/白（saturation ≤ 14）一律透明 —— 卡片、卡片外投影都是中性灰；
//   · 彩色像素按亮度淡出 —— 只有紧贴标记的抗锯齿过渡带（白与蓝的混合）会半透明；
//   · 半透明像素按「原本压在白色上」反推前景色 F = (C - 255(1-a)) / a，
//     否则边缘会留一圈发白的毛边（直接保留 RGB 就会这样）。
let cropWidth = plateWidth
let cropHeight = plateHeight
var buffer = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
guard let maskContext = CGContext(
    data: &buffer, width: cropWidth, height: cropHeight, bitsPerComponent: 8,
    bytesPerRow: cropWidth * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("ICON_FAIL cannot create mask context")
    exit(10)
}
maskContext.draw(cropped, in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))

var alpha = [Double](repeating: 0, count: cropWidth * cropHeight)
for index in 0..<(cropWidth * cropHeight) {
    let i = index * 4
    let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
    let saturation = max(r, max(g, b)) - min(r, min(g, b))
    guard saturation > 14 else { continue }             // 中性灰/白 → 完全透明
    let luminance = (r * 299 + g * 587 + b * 114) / 1000
    let value = 1.0 - Double(luminance - 232) / 18.0     // 232 以下全不透明
    alpha[index] = min(1, max(0, value))
}

// 3×3 均值羽化一次：源图缩放后边缘本来就有抗锯齿，这一步只是把二值跳变抹平成 1px 过渡。
var feathered = alpha
for y in 0..<cropHeight {
    for x in 0..<cropWidth {
        var sum = 0.0, count = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < cropWidth, ny >= 0, ny < cropHeight else { continue }
                sum += alpha[ny * cropWidth + nx]
                count += 1
            }
        }
        feathered[y * cropWidth + x] = sum / count
    }
}

for index in 0..<(cropWidth * cropHeight) {
    let i = index * 4
    let a = feathered[index]
    if a <= 0.004 {
        buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0; buffer[i + 3] = 0
        continue
    }
    // 预乘 alpha 的结果恰好是「原色减去被白底稀释掉的部分」。
    let keep = 255.0 * (1 - a)
    func channel(_ value: UInt8) -> UInt8 {
        UInt8(min(255, max(0, Double(value) - keep)))
    }
    buffer[i] = channel(buffer[i])
    buffer[i + 1] = channel(buffer[i + 1])
    buffer[i + 2] = channel(buffer[i + 2])
    buffer[i + 3] = UInt8(min(255, max(0, a * 255)))
}

guard let mark = maskContext.makeImage() else {
    print("ICON_FAIL cannot make transparent mark")
    exit(11)
}

// 按不透明像素重新取包围盒（扣底后内容比白卡小），再居中投放。
var markMinX = cropWidth, markMaxX = -1, markMinY = cropHeight, markMaxY = -1
for y in 0..<cropHeight {
    for x in 0..<cropWidth where feathered[y * cropWidth + x] > 0.03 {
        if x < markMinX { markMinX = x }
        if x > markMaxX { markMaxX = x }
        if y < markMinY { markMinY = y }
        if y > markMaxY { markMaxY = y }
    }
}
guard markMaxX > markMinX, markMaxY > markMinY else {
    print("ICON_FAIL no opaque mark found")
    exit(12)
}
let markWidth = markMaxX - markMinX + 1
let markHeight = markMaxY - markMinY + 1
guard let trimmed = mark.cropping(to: CGRect(
    x: markMinX, y: markMinY, width: markWidth, height: markHeight)) else {
    print("ICON_FAIL mark crop failed")
    exit(13)
}

let canvas = 1024
let contentFraction = 0.94
let contentSize = Double(canvas) * contentFraction
let scale = contentSize / Double(max(markWidth, markHeight))
let drawWidth = Double(markWidth) * scale
let drawHeight = Double(markHeight) * scale
let contentRect = CGRect(x: (Double(canvas) - drawWidth) / 2,
                         y: (Double(canvas) - drawHeight) / 2,
                         width: drawWidth, height: drawHeight)

guard let masterContext = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
    bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("ICON_FAIL cannot create canvas")
    exit(8)
}
masterContext.interpolationQuality = .high
masterContext.draw(trimmed, in: contentRect)

guard let master = masterContext.makeImage() else {
    print("ICON_FAIL cannot make master image")
    exit(9)
}

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in sizes {
    guard let context = CGContext(
        data: nil, width: entry.pixels, height: entry.pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: entry.pixels, height: entry.pixels))
    guard let scaled = context.makeImage() else { continue }
    let url = outputDir.appendingPathComponent(entry.name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, scaled, nil)
    CGImageDestinationFinalize(dest)
}

print("ICON_SOURCE_OK plate=\(plateWidth)x\(plateHeight) mark=\(markWidth)x\(markHeight) "
      + "canvas=\(canvas) content=\(Int(contentSize)) transparent=true")
