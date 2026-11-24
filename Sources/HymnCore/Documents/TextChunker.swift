import Foundation

// MARK: - PDF 等长文本的分块（纯逻辑，无 PDFKit 依赖，便于测试）

public struct PDFPageContent: Sendable, Equatable {
    /// 1-based 页码。
    public let pageNumber: Int
    public let text: String

    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}

public struct TextChunk: Sendable, Equatable, Identifiable {
    public let id: Int
    /// 1-based 页码范围（当前实现不跨页合并，起止相同）。
    public let pageStart: Int
    public let pageEnd: Int
    public let text: String

    public init(id: Int, pageStart: Int, pageEnd: Int, text: String) {
        self.id = id
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.text = text
    }
}

public enum TextChunker {
    /// 把逐页文本切成适合单次推理的块。
    ///
    /// - 不跨页合并，保证每块页码精确、失败可定位；
    /// - 优先按原有换行边界保留段落，尽量不在词中切断；
    /// - 单个超长段落按 `maxChars` 硬切，避免一次请求塞进整页；
    /// - 空白页跳过，确定性（同输入同输出）。
    public static func chunks(pages: [PDFPageContent], maxChars: Int = 600) -> [TextChunk] {
        let limit = max(80, maxChars)
        var result: [TextChunk] = []
        for page in pages {
            let text = normalize(page.text)
            guard !text.isEmpty else { continue }
            var segments: [String] = []
            var buffer = ""
            let paragraphs = text.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            for paragraph in paragraphs {
                if paragraph.count > limit {
                    if !buffer.isEmpty {
                        segments.append(buffer)
                        buffer = ""
                    }
                    var rest = paragraph[...]
                    while rest.count > limit {
                        let cut = rest.index(rest.startIndex, offsetBy: limit)
                        segments.append(String(rest[..<cut]))
                        rest = rest[cut...]
                    }
                    buffer = String(rest)
                    continue
                }
                if !buffer.isEmpty && buffer.count + paragraph.count + 1 > limit {
                    segments.append(buffer)
                    buffer = ""
                }
                buffer += buffer.isEmpty ? paragraph : "\n" + paragraph
            }
            if !buffer.isEmpty { segments.append(buffer) }

            for segment in segments {
                result.append(TextChunk(
                    id: result.count,
                    pageStart: page.pageNumber,
                    pageEnd: page.pageNumber,
                    text: segment))
            }
        }
        return result
    }

    /// 去掉页眉式连续空行与控制字符，保留原有段落换行。
    public static func normalize(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                String(line.unicodeScalars.filter { scalar in
                    let v = scalar.value
                    return v == 0x09 || v == 0x0A || v >= 0x20
                })
                .trimmingCharacters(in: .whitespaces)
            }
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
