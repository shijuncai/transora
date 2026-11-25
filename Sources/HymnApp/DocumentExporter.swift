import AppKit
import Foundation
import UniformTypeIdentifiers
import HymnCore

enum DocumentExportFormat: String, CaseIterable, Sendable {
    case txt
    case docx

    var label: String {
        switch self {
        case .txt: return L("保存为 TXT 格式")
        case .docx: return L("保存为 DOCX 格式")
        }
    }

    var shortLabel: String {
        switch self {
        case .txt: return "TXT"
        case .docx: return "DOCX"
        }
    }

    /// 划词浮窗底部图标的映射已收进 `SelectionActionID.symbol`（底排按钮统一由动作清单驱动）。
    var contentType: UTType {
        UTType(filenameExtension: rawValue) ?? .data
    }
}

enum DocumentExportOutcome {
    case saved(URL)
    case cancelled
    case failed(String)
}

/// App 层保存面板。纯 Swift 生成的 Data 由 `TranslationDocumentWriter` 提供，
/// 不启动外部进程、不联网；用户取消不写任何文件。
@MainActor
enum DocumentExporter {
    static func save(
        _ document: TranslationDocument,
        suggestedName: String,
        format: DocumentExportFormat
    ) -> DocumentExportOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(suggestedName)).\(format.rawValue)"
        panel.allowedContentTypes = [format.contentType]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.message = L("译文只保存在你指定的位置，不会上传。")
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            let data: Data
            switch format {
            case .txt: data = TranslationDocumentWriter.txtData(document)
            case .docx: data = try TranslationDocumentWriter.docxData(document)
            }
            try data.write(to: url, options: .atomic)
            return .saved(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func safeFileName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? L("译澜译文") : String(cleaned.prefix(80))
    }
}
