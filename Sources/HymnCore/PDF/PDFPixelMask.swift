import Foundation

/// 文本掩膜：把「会变的区域」从比对里剔掉。
///
/// R1 的命题是「非文本区域一个像素都不该变」。要证这句话，必须先把
/// **文本区域**准确地划出来——原文那一块没了、译文那一块新画上去，
/// 这两块本来就该不同。
///
/// 掩膜取三者的并集（再向外膨胀 `dilatePoints`）：
///     ① 原页所有文本 run 的墨迹框（`PDFTextRun.bbox`）；
///     ② 新页所有绘制项的墨迹行框（含页脚注释、单元格、孤立 run）；
///     ③ 原页 IL 块/表格/单元格框（兜底，防止某个 run 的 bbox 偏小）。
///
/// 膨胀是必须的：字形抗锯齿的边缘会溢出 bbox 半个像素以上，
/// 不膨胀就会出现「掩膜边界上一圈零星差异」，把真实问题淹掉。
public struct PDFPixelMask: Sendable {
    public var width: Int
    public var height: Int
    /// 0 = 参与比对，1 = 忽略
    public var bits: [UInt8]
    public var coveredPixels: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.bits = [UInt8](repeating: 0, count: max(0, width * height))
        self.coveredPixels = 0
    }

    public var totalPixels: Int { width * height }
    public var ratio: Double { totalPixels > 0 ? Double(coveredPixels) / Double(totalPixels) : 0 }

    @inline(__always)
    public func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bits[y * width + x] != 0
    }

    /// 页面坐标 → 掩膜栅格化。矩形按像素外扩（floor/ceil），不做半像素插值：
    /// 宁可多忽略一圈，也不要漏掉一条边。
    public static func build(
        image: PDFPageImage, rects: [PDFRect], dilatePoints: Double = 1.5
    ) -> PDFPixelMask {
        var mask = PDFPixelMask(width: image.width, height: image.height)
        guard !image.isEmpty else { return mask }
        let scale = image.scale
        let pad = max(0, dilatePoints) * scale
        let box = image.pageBox

        for rect in rects where rect.width > 0 || rect.height > 0 {
            let x0 = Int(((rect.x0 - box.x0) * scale - pad).rounded(.down))
            let x1 = Int(((rect.x1 - box.x0) * scale + pad).rounded(.up))
            let yTop = Int(((box.y1 - rect.y1) * scale - pad).rounded(.down))
            let yBottom = Int(((box.y1 - rect.y0) * scale + pad).rounded(.up))
            let startX = max(0, min(mask.width - 1, x0))
            let endX = max(0, min(mask.width - 1, x1))
            let startY = max(0, min(mask.height - 1, yTop))
            let endY = max(0, min(mask.height - 1, yBottom))
            guard endX >= startX, endY >= startY else { continue }
            let span = endX - startX + 1
            let rowWidth = mask.width
            var added = 0
            mask.bits.withUnsafeMutableBufferPointer { dst in
                for y in startY...endY {
                    let base = y * rowWidth + startX
                    for i in 0..<span where dst[base + i] == 0 {
                        dst[base + i] = 1
                        added += 1
                    }
                }
            }
            mask.coveredPixels += added
        }
        return mask
    }
}
