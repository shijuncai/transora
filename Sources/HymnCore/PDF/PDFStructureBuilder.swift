import Foundation

/// 把「解释 → 行 → 段 → 表」串成一步，产出 IL。
///
/// 这是 P2 的入口：上游是 PDF 字节，下游是「能拿去翻译和重排的结构」。
/// 所有判断都是几何启发式，因此每一项都带 `confidence`，
/// 让 P4 的校验环节知道哪些块需要更仔细地核对。
public enum PDFStructureBuilder {
    public struct Options: Sendable {
        public var extract = PDFTextExtractor.Options()
        public var detectTables = true
        public var table = PDFTableDetector.Options()
        public var paragraph = PDFParagraphBuilder.Options()
        /// 是否识别矢量图表区域（区域内的文字保持原文）
        public var detectCharts = true
        public var chart = PDFChartDetector.Options()
        /// 小于这个尺寸的图片不算插图（多半是分隔线/图标）
        public var minFigureSize = 16.0

        public init() {}
    }

    public static func build(
        document: PDFDocument,
        pageIndices: [Int]? = nil,
        options: Options = Options()
    ) -> ILDocument {
        var out = ILDocument()
        let entries = document.pageEntries()
        let targets = (pageIndices ?? Array(0..<entries.count))
            .filter { $0 >= 0 && $0 < entries.count }

        for index in targets {
            out.pages.append(buildPage(document: document, index: index,
                                       entry: entries[index], options: options))
        }
        return out
    }

    public static func buildPage(
        document: PDFDocument, index: Int,
        entry: (ref: PDFRef, dict: [String: PDFValue]),
        options: Options = Options()
    ) -> ILPage {
        let geometry = PDFStamper.geometry(of: entry.dict)
        let mediaBox = PDFRect(x0: geometry.mediaBox.x0, y0: geometry.mediaBox.y0,
                               x1: geometry.mediaBox.x1, y1: geometry.mediaBox.y1)
        var page = ILPage(index: index, width: mediaBox.width, height: mediaBox.height,
                          rotation: geometry.rotation)

        let content = PDFTextExtractor.extract(
            document: document, pageIndex: index, page: entry.dict, options: options.extract)
        page.warnings.append(contentsOf: content.warnings)
        page.unmappedGlyphs = content.unmappedGlyphs
        page.textRunCount = content.runs.count

        let totalGlyphs = content.runs.reduce(0) { $0 + $1.glyphCount }
        if totalGlyphs > 0 {
            let ratio = Double(content.unmappedGlyphs) / Double(totalGlyphs)
            if ratio > 0.05 {
                page.translatable = false
                page.warnings.append(
                    String(format: "%.1f%% 的字形取不到 unicode（缺 /ToUnicode），该页不可译",
                           ratio * 100))
            }
        }

        // 有文字但一个字形都解不出来 → 驱逐必然丢字。
        //
        // 这里选择「整页保持原样」而不是「只翻译读得懂的段」：驱逐是按页做的，
        // 读不懂的那些段删了就再也画不回来。宁可这一页不译，也不能让它变空白。
        // 真实例子：16:9 幻灯片里的思维导图，标签用一种读不出 CMap 的字体。
        if content.unreadableTextOps > 0 {
            page.translatable = false
            page.warnings.append(
                "\(content.unreadableTextOps) 处文本无法解码（字体/CMap 不可读），该页保持原样以免丢字")
        }

        let lines = PDFLineBuilder.buildLines(from: content.runs)

        // 表格先检测：落在表格里的行不再参与段落归并，否则同一段文字会出现两次
        if options.detectTables {
            page.tables = PDFTableDetector.detect(
                segments: content.segments, runs: content.runs, lines: lines,
                pageBox: mediaBox, options: options.table)
            // 只有横线、没有竖线的表格（期刊数据表常见）：网格法一条都认不出来，
            // 于是每个单元格变成独立段落、各自扩框，最后把整页推进重排。
            // 这里补一遍「横向带 + 列起点对齐」的推断。
            let inferred = PDFRuledTable.detect(
                segments: content.segments, runs: content.runs, pageBox: mediaBox,
                options: options.table, startOrdinal: page.tables.count)
            for table in inferred {
                let clashes = page.tables.contains { existing in
                    existing.box.intersects(table.box)
                }
                if !clashes { page.tables.append(table) }
            }
            page.tables.sort { $0.box.y1 > $1.box.y1 }
        }
        let tableBoxes = page.tables.map(\.box)
        let bodyLines = lines.filter { line in
            let center = PDFPoint((line.box.x0 + line.box.x1) / 2,
                                  (line.box.y0 + line.box.y1) / 2)
            return !tableBoxes.contains {
                center.x >= $0.x0 && center.x <= $0.x1 && center.y >= $0.y0 && center.y <= $0.y1
            }
        }

        page.blocks = PDFParagraphBuilder.buildBlocks(
            lines: bodyLines, pageWidth: mediaBox.width, options: options.paragraph)

        page.figures = content.images
            .filter { $0.bbox.width >= options.minFigureSize && $0.bbox.height >= options.minFigureSize }
            .enumerated()
            .map { offset, image in
                ILFigure(id: "f\(offset)", box: image.bbox,
                         pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
            }

        // 矢量图表：`figures` 只收位图，期刊里的折线/柱状图一个 image 都没有，
        // 必须从「笔触密度」另判一遍，否则图里的文字会被当正文翻掉。
        if options.detectCharts {
            page.charts = PDFChartDetector.detect(
                paths: content.paintedPaths, pageWidth: mediaBox.width,
                pageHeight: mediaBox.height, tables: page.tables, options: options.chart)
        }

        if lines.isEmpty && content.images.isEmpty {
            page.warnings.append("页面没有可提取的文本或图片（可能是空白页或纯矢量图形）")
        }
        return page
    }
}

// MARK: - JSON 输出

/// IL → JSON。
///
/// schema 是照 agentic-doc 的消费习惯定的：每块都有 `type`、`box`、
/// `parent_id`、`confidence`，块里带 `children`（行）。这样下游（排版、校验、
/// 导出逐段对照报告）不必各自猜结构。
///
/// 坐标同时给两份：
/// - `box`：PDF 页面空间（左下原点、y 向上）——工程内部一律用它；
/// - `box_top_down`：左上原点——给人看、给前端/视觉工具用。
/// 只给一份的话，总会有人在某处搞反 y。
public enum ILJSON {
    public struct ExportOptions: Sendable {
        public var includeLines = true
        public var includeSpans = false
        public var pretty = true

        public init() {}
    }

    public static func encode(
        _ document: ILDocument, options: ExportOptions = ExportOptions()
    ) -> Data {
        var root: [String: Any] = [:]
        root["schema"] = "linguanova.il/1"
        root["pages"] = document.pages.map { page -> [String: Any] in
            encodePage(page, options: options)
        }
        if !document.warnings.isEmpty { root["warnings"] = document.warnings }

        // withoutEscapingSlashes：否则 "linguanova.il/1" 会被写成 \/，
        // 文本匹配和人工阅读都别扭
        var encoderOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if options.pretty { encoderOptions.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: root, options: encoderOptions))
            ?? Data("{}".utf8)
    }

    static func encodePage(_ page: ILPage, options: ExportOptions) -> [String: Any] {
        var dict: [String: Any] = [
            "id": "page-\(page.index)",
            "page": page.index + 1,
            "width": round2(page.width),
            "height": round2(page.height),
            "rotation": page.rotation,
            "translatable": page.translatable,
            "text_runs": page.textRunCount,
            "unmapped_glyphs": page.unmappedGlyphs,
            "blocks": page.blocks.map { encodeBlock($0, page: page, options: options) },
            "tables": page.tables.map { encodeTable($0, page: page) },
            "figures": page.figures.map { encodeFigure($0, page: page) },
            "charts": page.charts.map { encodeChart($0, page: page) },
        ]
        if !page.warnings.isEmpty { dict["warnings"] = page.warnings }
        return dict
    }

    static func encodeBlock(_ block: ILBlock, page: ILPage, options: ExportOptions) -> [String: Any] {
        var dict: [String: Any] = [
            "id": "p\(page.index + 1)-\(block.id)",
            "parent_id": "page-\(page.index)",
            "type": block.type.rawValue,
            "box": boxArray(block.box),
            "box_top_down": boxArrayTopDown(block.box, pageHeight: page.height),
            "confidence": round2(block.confidence),
            "font_size": round2(block.fontSize),
            "column": block.column,
            "line_count": block.lineCount,
            "text": block.text,
        ]
        if options.includeLines {
            dict["children"] = block.lines.map { line -> [String: Any] in
                var item: [String: Any] = [
                    "type": "line",
                    "parent_id": "p\(page.index + 1)-\(block.id)",
                    "box": boxArray(line.box),
                    "baseline": round2(line.baseline),
                    "font_size": round2(line.fontSize),
                    "text": line.text,
                ]
                if options.includeSpans {
                    item["spans"] = line.spans.map { span -> [String: Any] in
                        [
                            "text": span.text,
                            "font": span.fontName,
                            "font_size": round2(span.fontSize),
                            "bold": span.isBold,
                            "italic": span.isItalic,
                            "box": boxArray(span.box),
                        ]
                    }
                }
                return item
            }
        }
        return dict
    }

    static func encodeTable(_ table: ILTable, page: ILPage) -> [String: Any] {
        [
            "id": "p\(page.index + 1)-\(table.id)",
            "parent_id": "page-\(page.index)",
            "type": "table",
            "box": boxArray(table.box),
            "box_top_down": boxArrayTopDown(table.box, pageHeight: page.height),
            "confidence": round2(table.confidence),
            "rows": table.rowCount,
            "cols": table.columnCount,
            "cells": table.cells.map { cell in
                [
                    "type": "cell",
                    "row": cell.row,
                    "col": cell.column,
                    "row_span": cell.rowSpan,
                    "col_span": cell.columnSpan,
                    "box": boxArray(cell.box),
                    "text": cell.text,
                ] as [String: Any]
            },
        ]
    }

    static func encodeFigure(_ figure: ILFigure, page: ILPage) -> [String: Any] {
        [
            "id": "p\(page.index + 1)-\(figure.id)",
            "parent_id": "page-\(page.index)",
            "type": "figure",
            "box": boxArray(figure.box),
            "box_top_down": boxArrayTopDown(figure.box, pageHeight: page.height),
            "pixel_width": figure.pixelWidth,
            "pixel_height": figure.pixelHeight,
        ]
    }

    static func encodeChart(_ chart: ILChart, page: ILPage) -> [String: Any] {
        [
            "id": "p\(page.index + 1)-\(chart.id)",
            "parent_id": "page-\(page.index)",
            "type": "chart",
            "box": boxArray(chart.box),
            "box_top_down": boxArrayTopDown(chart.box, pageHeight: page.height),
            "path_count": chart.pathCount,
            "point_count": chart.pointCount,
        ]
    }

    static func boxArray(_ box: PDFRect) -> [Double] {
        [round2(box.x0), round2(box.y0), round2(box.x1), round2(box.y1)]
    }

    static func boxArrayTopDown(_ box: PDFRect, pageHeight: Double) -> [Double] {
        [round2(box.x0), round2(pageHeight - box.y1),
         round2(box.x1), round2(pageHeight - box.y0)]
    }

    static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
