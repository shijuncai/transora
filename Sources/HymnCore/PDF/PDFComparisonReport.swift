import Foundation

/// 逐段对照报告：把「原文 / 译文 / 这一段的处理结果」排成一份可以直接给人看的 HTML。
///
/// 为什么单语同版式也需要它：PDF 里只剩译文，**原文在成品里已经不存在了**。
/// 用户校对时没法「左右对照」，出了错也无从判断是译错还是排错。
/// 这份报告补上原文，并逐段标注发生了什么：缩到了几号字、扩了框、
/// 挪进了页脚注、还是因为放不下而回落成原文。
///
/// 输出是单文件 HTML（内联样式、无外链），可以直接双击打开、也可以打印归档。
public enum PDFComparisonReport {
    public struct Options: Sendable {
        public var title = "逐段对照报告"
        public var documentName = ""
        /// 每页是否默认展开
        public var expandPages = false
        /// 最多渲染多少页（0 = 全部）
        public var maxPages = 0

        public init() {}
    }

    /// 一段（块 / 单元格 / 注）的对照记录。
    public struct Entry: Sendable {
        public var id: String
        public var kind: String
        public var source: String
        public var output: String
        public var status: String
        public var detail: String
        public var fontSize: Double
        public var sourceFontSize: Double

        public init(id: String, kind: String, source: String, output: String,
                    status: String, detail: String, fontSize: Double, sourceFontSize: Double) {
            self.id = id
            self.kind = kind
            self.source = source
            self.output = output
            self.status = status
            self.detail = detail
            self.fontSize = fontSize
            self.sourceFontSize = sourceFontSize
        }
    }

    public struct PageSection: Sendable {
        public var page: Int
        public var entries: [Entry]

        public init(page: Int, entries: [Entry]) {
            self.page = page
            self.entries = entries
        }
    }

    // MARK: - 数据整理

    public static func sections(
        layouts: [PDFPageLayout], report: PDFTypesetEngine.Report
    ) -> [PageSection] {
        let pageReports = Dictionary(uniqueKeysWithValues: report.pages.map { ($0.page, $0) })
        return layouts.map { layout in
            let pageNo = layout.page + 1
            let pageReport = pageReports[pageNo]
            var entries: [Entry] = []
            for item in layout.items {
                // 孤立 run 是「没归进任何段落」的碎片，逐段对照里没有意义
                if item.kind == .orphan { continue }
                let kind: String
                switch item.kind {
                case .block: kind = "段落"
                case .cell: kind = "单元格"
                case .note: kind = "注释"
                case .pinned: kind = "钉子块"
                case .kept: kind = "原文"
                case .orphan: kind = "碎片"
                }
                var status = "已译"
                var detail = ""
                if item.kind == .kept {
                    status = "保留原文"
                    detail = "没有译文，或译文未通过占位符校验"
                } else if item.kind == .pinned {
                    status = "未改动"
                    detail = "代码 / 目录点线 / 表格邻接 / 碎片：原字节保留，一个像素没动"
                } else if !item.overflow.isEmpty {
                    status = "有溢出"
                    detail = "\(item.overflow.count) 行挪到页脚注"
                }
                if !item.missingScalars.isEmpty {
                    status = "缺字"
                    let hex = item.missingScalars.prefix(6)
                        .map { String(format: "U+%04X", $0) }.joined(separator: " ")
                    detail = "字体画不出：\(hex)"
                }
                if item.tier == "shrink" || item.tier == "compressed" { detail = detail.isEmpty ? "压行距/缩字后放下" : detail }
                entries.append(Entry(
                    id: item.id, kind: kind, source: item.source, output: item.drawn,
                    status: status, detail: detail,
                    fontSize: item.fontSize, sourceFontSize: item.fontSize))
            }
            _ = pageReport
            return PageSection(page: pageNo, entries: entries)
        }
    }

    // MARK: - HTML

    public static func html(
        sections: [PageSection], report: PDFTypesetEngine.Report,
        options: Options = Options()
    ) -> String {
        let shown = options.maxPages > 0 ? Array(sections.prefix(options.maxPages)) : sections
        let translated = report.pages.reduce(0) { $0 + $1.translated }
        let kept = report.pages.reduce(0) { $0 + $1.keptOriginal }
        let review = report.needsReviewPages.count

        var out = ""
        out += """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(options.title))</title>
        <style>
        :root { color-scheme: light; }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 32px 28px 64px; background: #f6f7f9; color: #1c1f23;
               font: 14px/1.7 -apple-system, "PingFang SC", "Noto Sans SC", sans-serif; }
        .wrap { max-width: 1080px; margin: 0 auto; }
        h1 { font-size: 22px; margin: 0 0 6px; letter-spacing: .2px; }
        .sub { color: #6b7280; font-size: 13px; margin-bottom: 22px; }
        .stats { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 24px; }
        .stat { background: #fff; border: 1px solid #e5e7eb; border-radius: 10px;
                padding: 10px 14px; min-width: 104px; }
        .stat b { display: block; font-size: 19px; line-height: 1.3; }
        .stat span { color: #6b7280; font-size: 12px; }
        details { background: #fff; border: 1px solid #e5e7eb; border-radius: 12px;
                  margin-bottom: 12px; overflow: hidden; }
        details > summary { cursor: pointer; padding: 11px 16px; font-weight: 600;
                  background: #fbfbfc; border-bottom: 1px solid #eef0f3; font-size: 13.5px; }
        details > summary::marker { color: #9ca3af; }
        table { width: 100%; border-collapse: collapse; }
        th, td { text-align: left; vertical-align: top; padding: 10px 14px;
                 border-bottom: 1px solid #f1f2f4; font-size: 13px; }
        th { color: #6b7280; font-weight: 500; background: #fff; font-size: 12px; }
        tr:last-child td { border-bottom: none; }
        td.src { width: 42%; color: #374151; }
        td.out { width: 42%; }
        td.meta { width: 16%; white-space: nowrap; }
        .tag { display: inline-block; padding: 1px 7px; border-radius: 999px;
               font-size: 11.5px; line-height: 1.7; }
        .t-ok { background: #e8f5ec; color: #1d7a3c; }
        .t-warn { background: #fff5e6; color: #9a5b00; }
        .t-keep { background: #eef1f6; color: #4b5563; }
        .t-bad { background: #fdecec; color: #b42318; }
        .note { color: #8a9099; font-size: 12px; margin-top: 3px; }
        .foot { color: #9ca3af; font-size: 12px; margin-top: 28px; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
        @media print { body { background: #fff; padding: 0; } details { break-inside: avoid; } }
        </style></head><body><div class="wrap">
        <h1>\(escape(options.title))</h1>
        <div class="sub">\(escape(options.documentName))</div>
        <div class="stats">
          <div class="stat"><b>\(report.pages.count)</b><span>页</span></div>
          <div class="stat"><b>\(translated)</b><span>已译段落</span></div>
          <div class="stat"><b>\(kept)</b><span>保留原文</span></div>
          <div class="stat"><b>\(review)</b><span>需复核页</span></div>
          <div class="stat"><b>\(report.inputBytes / 1024)</b><span>输入 KB</span></div>
          <div class="stat"><b>\(report.outputBytes / 1024)</b><span>输出 KB</span></div>
        </div>

        """
        for section in shown {
            let open = options.expandPages ? " open" : ""
            out += "<details\(open)><summary>第 \(section.page) 页 · \(section.entries.count) 段</summary>\n"
            out += "<table><thead><tr><th>原文</th><th>译文</th><th>处理</th></tr></thead><tbody>\n"
            for entry in section.entries {
                let (cls, text) = badge(entry)
                let detail = entry.detail.isEmpty ? "" : "<div class=\"note\">\(escape(entry.detail))</div>"
                out += """
                <tr><td class="src">\(escape(entry.source))</td>\
                <td class="out">\(escape(entry.output))</td>\
                <td class="meta"><span class="tag \(cls)">\(escape(text))</span>\
                <div class="note">\(escape(entry.kind)) · <code>\(escape(entry.id))</code></div>\(detail)</td></tr>

                """
            }
            out += "</tbody></table></details>\n"
        }
        if shown.count < sections.count {
            out += "<div class=\"foot\">另有 \(sections.count - shown.count) 页未渲染（`maxPages` 限制）。</div>\n"
        }
        out += "<div class=\"foot\">由译澜生成 · 单语同版式 · 原文仅存在于本报告中</div>\n"
        out += "</div></body></html>\n"
        return out
    }

    static func badge(_ entry: Entry) -> (String, String) {
        switch entry.status {
        case "已译": return ("t-ok", "已译")
        case "保留原文": return ("t-keep", "保留原文")
        case "未改动": return ("t-keep", "未改动")
        case "有溢出": return ("t-warn", "有溢出")
        case "缺字": return ("t-bad", "缺字")
        default: return ("t-keep", entry.status)
        }
    }

    /// JSON 版本：给自动化流水线用，字段与 HTML 一一对应。
    public static func json(sections: [PageSection]) throws -> Data {
        struct Payload: Encodable {
            var schema = "linguanova.compare/1"
            var pages: [Page]
            struct Page: Encodable {
                var page: Int
                var blocks: [Block]
            }
            struct Block: Encodable {
                var id: String
                var kind: String
                var source: String
                var output: String
                var status: String
                var detail: String
            }
        }
        let payload = Payload(pages: sections.map { section in
            Payload.Page(page: section.page, blocks: section.entries.map {
                Payload.Block(id: $0.id, kind: $0.kind, source: $0.source,
                              output: $0.output, status: $0.status, detail: $0.detail)
            })
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "<br>"
            default: out.append(character)
            }
        }
        return out
    }
}


/// 文字所属书写系统的最小判断。
///
/// `CharacterSet` 没有「汉字」这一项（`letters` 会把假名、谚文也算进去，
/// 但拿它来判「这段值不值得送模型」又太宽），所以显式划区间。
public enum PDFScript {
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// 这段文字里有没有「值得翻译」的字符（字母或 CJK）。
    public static func hasTranslatableCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) || isCJK(scalar)
        }
    }
}
