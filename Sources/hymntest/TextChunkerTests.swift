import Foundation
import HymnCore

/// PDF 长文本分块逻辑的独立测试（不依赖 PDFKit / 真实文件）。
func textChunkerSuite() -> [TestResult] {
    let suite = "text-chunker"
    var out: [TestResult] = []

    let pages = [
        PDFPageContent(pageNumber: 1, text: "第一段文字。\n第二段文字。"),
        PDFPageContent(pageNumber: 2, text: "   \n  "),
        PDFPageContent(pageNumber: 3, text: String(repeating: "甲乙丙丁", count: 200)),
        PDFPageContent(pageNumber: 4, text: "最后一段。"),
    ]
    let chunks = TextChunker.chunks(pages: pages, maxChars: 200)

    out.append(check(suite: suite, "空白页被跳过，页码仍精确保留",
                     chunks.allSatisfy { $0.pageStart == $0.pageEnd }
                        && !chunks.contains { $0.pageStart == 2 }
                        && Set(chunks.map(\.pageStart)) == Set([1, 3, 4]),
                     detail: "chunks=\(chunks.count) pages=\(Set(chunks.map(\.pageStart)).sorted())"))

    out.append(check(suite: suite, "超长段落按上限硬切且不丢字符",
                     {
                         let page3 = chunks.filter { $0.pageStart == 3 }
                         let joined = page3.map(\.text).joined()
                         return page3.count >= 3
                            && page3.allSatisfy { $0.text.count <= 200 }
                            && joined.count == 800
                     }(),
                     detail: "第 3 页块数=\(chunks.filter { $0.pageStart == 3 }.count)"))

    out.append(check(suite: suite, "块序号连续且不与页码混淆",
                     chunks.enumerated().allSatisfy { $0.element.id == $0.offset }))

    out.append(check(suite: suite, "短页按原有换行边界保留段落",
                     {
                         let first = chunks.first { $0.pageStart == 1 }
                         return first?.text.contains("\n") == true
                            && first?.text.contains("第一段文字。") == true
                     }()))

    out.append(check(suite: suite, "同输入结果确定性一致",
                     TextChunker.chunks(pages: pages, maxChars: 200) == chunks))

    out.append(check(suite: suite, "归一化剔除控制字符并压缩连续空行",
                     {
                         let n = TextChunker.normalize("A\u{01}B\n\n\n\nC  \n")
                         return n == "A B\n\nC" || (n.contains("AB") && !n.contains("\n\n\n"))
                     }(),
                     detail: TextChunker.normalize("A\u{01}B\n\n\n\nC  \n")
                        .replacingOccurrences(of: "\n", with: "\\n")))

    out.append(check(suite: suite, "全空输入不产生任何块",
                     TextChunker.chunks(pages: [
                        PDFPageContent(pageNumber: 1, text: ""),
                        PDFPageContent(pageNumber: 2, text: "\n \n"),
                     ]).isEmpty))

    out.append(check(suite: suite, "几百页规模仍保持线性且每块不超限",
                     {
                         let many = (1...320).map {
                             PDFPageContent(pageNumber: $0,
                                            text: String(repeating: "翻译测试 ", count: 60))
                         }
                         let result = TextChunker.chunks(pages: many, maxChars: 600)
                         return result.count >= 320
                            && result.allSatisfy { $0.text.count <= 600 }
                            && result.last?.pageEnd == 320
                     }(),
                     detail: "320 页规模"))

    return out
}
