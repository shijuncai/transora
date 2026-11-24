import Foundation
import HymnCore

/// 页内重排（`page-reflow`）的顺序与兜底。
///
/// 这一组全部来自 `Sample/mycelia strains and sustainable growth.pdf` 的参考文献页：
/// 第 9 页整页重排后，`[37]` 因为译文变长被顶到 y=599，而它的续行仍按原顶边
/// 停在 y=628 —— 后一段跑到了前一段**上面**，R7 报「p0-b18 应在 p0-b16 之前」，
/// 复制粘贴出来是倒的句子。另一处是排不下的块被直接丢弃（静默删字）。
func pdfReflowSuite() -> [TestResult] {
    let suite = "pdf-reflow"
    var out: [TestResult] = []

    guard let fontURL = p3FontURL("LinguaNovaSong-Regular.ttf"),
          let font = try? TrueTypeFont(url: fontURL) else {
        out.append(check(suite: suite, "font-available", false,
                         detail: "找不到 Resources/Fonts/LinguaNovaSong-Regular.ttf"))
        return out
    }
    let face = PDFFace(font: font, resourceName: "LNR1", isBold: false)

    func block(_ id: String, _ text: String, x0: Double, x1: Double,
               y1: Double, lines: Int) -> ILBlock {
        var items: [ILLine] = []
        for index in 0..<lines {
            let top = y1 - Double(index) * 9
            items.append(ILLine(
                text: text, box: PDFRect(x0: x0, y0: top - 9, x1: x1, y1: top),
                baseline: top - 7, fontSize: 8, spans: [], angle: 0))
        }
        return ILBlock(id: id, type: .paragraph,
                       box: PDFRect(x0: x0, y0: y1 - Double(lines) * 9, x1: x1, y1: y1),
                       lines: items, fontSize: 8, text: text,
                       confidence: 1, column: 0)
    }

    // 同一栏两块：前一块译文很长、被顶下去，后一块必须跟着往下，不能倒序
    let long = String(repeating: "很长的译文内容，用来把这一块顶到下面去。", count: 14)
    let first = block("b1", "first", x0: 42, x1: 293, y1: 700, lines: 1)
    let second = block("b2", "second", x0: 42, x1: 293, y1: 630, lines: 1)
    let flow = PDFPageReflow.flow(
        blocks: [first, second], texts: ["b1": long, "b2": "第二段的译文"],
        region: PDFRect(x0: 36, y0: 36, x1: 561, y1: 760),
        obstacles: [], face: { _ in face }, floorSize: 6,
        options: PDFTypeset.Options())
    let firstPlan = flow.plans.first { $0.blockID == "b1" }
    let secondPlan = flow.plans.first { $0.blockID == "b2" }
    // `plan.box` 是可用空间（一直伸到区域底），真实落版高度要看行数 × 行距
    let firstBottom = firstPlan.map {
        $0.box.y1 - Double($0.lines.count) * $0.lineHeight
    } ?? -1
    out.append(check(suite: suite, "前一段被顶下去后，后一段也在它下面",
                     firstPlan != nil && secondPlan != nil
                        && secondPlan!.box.y1 <= firstBottom + 0.01,
                     detail: "b1 正文底边=\(round(firstBottom)) "
                        + "b2 顶边=\(secondPlan.map { round($0.box.y1) } ?? -1)"))

    // 排不下的块要被点名（调用方据此保留原字节），而不是悄悄消失
    let crowded = (0..<40).map { index in
        block("c\(index)", "第 \(index) 段", x0: 42, x1: 293,
              y1: 740 - Double(index) * 18, lines: 2)
    }
    let tall = block("tall", "排不下的长段", x0: 42, x1: 293, y1: 120, lines: 20)
    let overflowFlow = PDFPageReflow.flow(
        blocks: crowded + [tall], texts: [:],
        region: PDFRect(x0: 36, y0: 700, x1: 561, y1: 760),
        obstacles: [], face: { _ in face }, floorSize: 6,
        options: PDFTypeset.Options())
    out.append(check(suite: suite, "排不下的块进 unplaced 名单",
                     !overflowFlow.unplaced.isEmpty,
                     detail: "unplaced=\(overflowFlow.unplaced.count) "
                        + "placed=\(overflowFlow.plans.count)"))

    // 微小的障碍物（上标、项目符号）不该把整段顶下去
    let withDot = PDFPageReflow.flow(
        blocks: [block("d1", "dot", x0: 42, x1: 293, y1: 700, lines: 2)],
        texts: ["d1": "带项目符号的一段文字"],
        region: PDFRect(x0: 36, y0: 36, x1: 561, y1: 760),
        obstacles: [PDFRect(x0: 40, y0: 694, x1: 44, y1: 698)],
        face: { _ in face }, floorSize: 6, options: PDFTypeset.Options())
    out.append(check(suite: suite, "4×4pt 的碎片不把段落顶下去",
                     (withDot.plans.first?.box.y1 ?? 0) > 699,
                     detail: "y1=\(withDot.plans.first.map { round($0.box.y1) } ?? -1)"))

    return out
}
