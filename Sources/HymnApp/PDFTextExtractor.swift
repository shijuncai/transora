import Foundation
import PDFKit
import HymnCore

struct PDFExtractionResult {
    let fileName: String
    let pageCount: Int
    let pages: [PDFPageContent]
    let characterCount: Int
}

enum PDFExtractionFailure: LocalizedError {
    case unreadable
    case noTextLayer

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取这个 PDF，或文件已损坏。"
        case .noTextLayer:
            return "这个 PDF 没有可提取的文字层（可能是扫描件）。本版本不做 OCR，无法翻译图片中的文字。"
        }
    }
}

/// 用系统 PDFKit 提取逐页文字。不联网、不调用外部进程、不做 OCR。
enum PDFTextExtractor {
    static func extract(url: URL) throws -> PDFExtractionResult {
        guard let document = PDFDocument(url: url) else {
            throw PDFExtractionFailure.unreadable
        }
        var pages: [PDFPageContent] = []
        pages.reserveCapacity(document.pageCount)
        var characters = 0
        for index in 0..<document.pageCount {
            let raw = document.page(at: index)?.string ?? ""
            let normalized = TextChunker.normalize(raw)
            characters += normalized.count
            pages.append(PDFPageContent(pageNumber: index + 1, text: raw))
        }
        guard characters > 0 else { throw PDFExtractionFailure.noTextLayer }
        return PDFExtractionResult(
            fileName: url.lastPathComponent,
            pageCount: document.pageCount,
            pages: pages,
            characterCount: characters)
    }
}
