import Foundation

/// 增量更新写入器。
///
/// 只追加，不改原字节：新对象写在文件尾部，再写一份新的 xref（`/Prev` 指回旧 xref）。
/// 好处是「没被改的对象在物理上不可能变」——这让图片/矢量的保真成为结构性保证，
/// 而不是靠实现小心。
///
/// 代价要说清楚：旧文本的字节仍物理存在于文件中（xref 不再引用它，常规提取工具
/// 拿不到，但取证级扫描可以）。所以对外要提供 `scrub` 选项（后续阶段）。
public enum PDFIncrementalWriter {
    public enum Failure: Error, CustomStringConvertible {
        case encrypted
        case empty

        public var description: String {
            switch self {
            case .encrypted: return "文档已加密，拒绝写入"
            case .empty: return "没有需要写入的对象"
            }
        }
    }

    /// - Parameters:
    ///   - objects: 需要覆盖的对象（同对象号的新版本）。
    public static func append(
        original: Data,
        document: PDFDocument,
        objects: [(ref: PDFRef, value: PDFValue)]
    ) throws -> Data {
        if document.isEncrypted { throw Failure.encrypted }
        guard !objects.isEmpty else { throw Failure.empty }

        var out = original
        if let last = out.last, last != 0x0A && last != 0x0D {
            out.append(0x0A)
        }

        // 同一对象号重复出现时以最后一次为准
        var dedup: [Int: (PDFRef, PDFValue)] = [:]
        for item in objects { dedup[item.ref.number] = item }
        let ordered = dedup.values.sorted { $0.0.number < $1.0.number }

        var offsets: [(number: Int, offset: Int, generation: Int)] = []
        for item in ordered {
            offsets.append((item.0.number, out.count, item.0.generation))
            out.append(contentsOf: Array("\(item.0.number) \(item.0.generation) obj\n".utf8))
            out.append(PDFSerialize.value(item.1))
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        // 原文件用交叉引用流（PDF 1.5+，常见于带对象流的文件）时，
        // 新版也写交叉引用流：实测「经典表 + /Prev 指向 xref 流」会让
        // CoreGraphics 报 "failed to find start of cross-reference section"。
        let originalUsesStream = document.xrefSections.first?.kind == "stream"
        if originalUsesStream {
            return appendXRefStream(
                into: out, offsets: offsets, document: document)
        }
        return appendClassicTable(into: out, offsets: offsets, document: document)
    }

    // MARK: 经典 xref 表

    static func appendClassicTable(
        into out: Data,
        offsets: [(number: Int, offset: Int, generation: Int)],
        document: PDFDocument
    ) -> Data {
        var out = out
        let xrefOffset = out.count
        out.append(contentsOf: Array("xref\n".utf8))
        var index = 0
        while index < offsets.count {
            let start = offsets[index].number
            var end = index
            while end + 1 < offsets.count && offsets[end + 1].number == offsets[end].number + 1 {
                end += 1
            }
            let count = end - index + 1
            out.append(contentsOf: Array("\(start) \(count)\n".utf8))
            for i in index...end {
                out.append(contentsOf: Array(
                    String(format: "%010d %05d n \n", offsets[i].offset, offsets[i].generation).utf8))
            }
            index = end + 1
        }

        let maxNumber = offsets.map(\.number).max() ?? 0
        let size = max(document.trailer["Size"]?.intValue ?? 0, maxNumber + 1)
        var trailer: [String: PDFValue] = ["Size": .int(size), "Prev": .int(document.startXRef)]
        if let root = document.trailer["Root"] { trailer["Root"] = root }
        if let info = document.trailer["Info"] { trailer["Info"] = info }
        if let id = document.trailer["ID"] { trailer["ID"] = id }

        out.append(contentsOf: Array("trailer\n".utf8))
        out.append(PDFSerialize.value(.dictionary(trailer)))
        out.append(contentsOf: Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    // MARK: 交叉引用流

    static func appendXRefStream(
        into out: Data,
        offsets: [(number: Int, offset: Int, generation: Int)],
        document: PDFDocument
    ) -> Data {
        var out = out
        let baseSize = document.trailer["Size"]?.intValue ?? 0
        let maxChanged = offsets.map(\.number).max() ?? 0
        // 新对象号不能与已有对象冲突
        let xrefObjectNumber = max(baseSize, maxChanged + 1)
        let xrefOffset = out.count

        var rows = offsets.map { (number: $0.number, offset: $0.offset, generation: $0.generation) }
        rows.append((xrefObjectNumber, xrefOffset, 0))
        rows.sort { $0.number < $1.number }

        // /Index：连续对象号合成一段
        var indexPairs: [Int] = []
        var index = 0
        while index < rows.count {
            let start = rows[index].number
            var end = index
            while end + 1 < rows.count && rows[end + 1].number == rows[end].number + 1 {
                end += 1
            }
            indexPairs.append(start)
            indexPairs.append(end - index + 1)
            index = end + 1
        }

        // /W = [1 4 2]：类型 1 字节、偏移 4 字节、代次 2 字节
        var table = Data()
        for row in rows {
            table.append(1)
            let offset = UInt32(truncatingIfNeeded: row.offset)
            table.append(UInt8((offset >> 24) & 0xFF))
            table.append(UInt8((offset >> 16) & 0xFF))
            table.append(UInt8((offset >> 8) & 0xFF))
            table.append(UInt8(offset & 0xFF))
            table.append(UInt8((row.generation >> 8) & 0xFF))
            table.append(UInt8(row.generation & 0xFF))
        }

        let compressed = PDFFilters.deflate(table)
        let useFilter = compressed.count < table.count
        let payload = useFilter ? compressed : table

        var dict: [String: PDFValue] = [
            "Type": .name("XRef"),
            "Size": .int(xrefObjectNumber + 1),
            "W": .array([.int(1), .int(4), .int(2)]),
            "Index": .array(indexPairs.map { .int($0) }),
            "Prev": .int(document.startXRef),
            "Length": .int(payload.count),
        ]
        if useFilter { dict["Filter"] = .name("FlateDecode") }
        if let root = document.trailer["Root"] { dict["Root"] = root }
        if let info = document.trailer["Info"] { dict["Info"] = info }
        if let id = document.trailer["ID"] { dict["ID"] = id }

        out.append(contentsOf: Array("\(xrefObjectNumber) 0 obj\n".utf8))
        out.append(PDFSerialize.value(.stream(PDFStream(dictionary: dict, raw: payload))))
        out.append(contentsOf: Array("\nendobj\n".utf8))
        out.append(contentsOf: Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }
}

// MARK: - 整篇驱逐

/// 把「解析 → 驱逐 → 写回」串成一步，给 CLI 和后续管线复用。
///
/// P1 起会递归进入 Form XObject：InDesign / Word / CAD 导出的文件常把整页
/// 图文塞进一个 Form，页面 /Contents 里只有一个 `Do`。只在页面内容流里删文本
/// 会「一个字都没删掉」却不报错——静默失败比崩溃更危险。
public enum PDFEvictor {
    public struct PageReport: Sendable {
        public var pageNumber: Int
        /// 页面自身的内容流数量
        public var streams: Int
        /// 递归进入的 Form XObject 数量
        public var formStreams: Int
        public var removedRuns: Int
        public var bytesBefore: Int
        public var bytesAfter: Int
        public var formsSkipped: Int
        public var sharedFormsCloned: Int
        public var note: String
    }

    public struct Report: Sendable {
        public var inputBytes: Int
        public var outputBytes: Int
        public var pages: [PageReport]
        public var changedObjects: Int
        /// 全篇有多少个 Form 被多页共享（>1 页引用）
        public var sharedForms: Int
        /// 因「只处理部分页」而被深拷贝的 Form 数量
        public var clonedForms: Int

        public var totalRemovedRuns: Int { pages.reduce(0) { $0 + $1.removedRuns } }
        public var totalFormStreams: Int { pages.reduce(0) { $0 + $1.formStreams } }
        public var totalFormsSkipped: Int { pages.reduce(0) { $0 + $1.formsSkipped } }
    }

    /// - Parameter pageIndices: 0-based 页序号；nil 表示全篇。
    public static func evictText(
        document: PDFDocument,
        pageIndices: [Int]? = nil
    ) throws -> (output: Data, report: Report) {
        let entries = document.pageEntries()
        let isFullDocument = pageIndices == nil
        let targets = (pageIndices ?? Array(0..<entries.count))
            .filter { $0 >= 0 && $0 < entries.count }

        // 部分页模式才需要判断「form 是否被非目标页共用」，全篇模式无需付出这个扫描成本
        let usage = isFullDocument ? [:] : PDFFormGraph.usageByPage(document: document)
        let targetSet = Set(targets)
        let sharedFormCount = usage.values.filter { $0.count > 1 }.count

        var allocator = PDFObjectAllocator(startingAt: document.nextFreeObjectNumber)
        var objects: [(ref: PDFRef, value: PDFValue)] = []
        var reports: [PageReport] = []
        var processedForms = Set<Int>()
        var clonedFormTotal = 0

        for index in targets {
            let entry = entries[index]
            var pageReport = PageReport(
                pageNumber: index + 1, streams: 0, formStreams: 0, removedRuns: 0,
                bytesBefore: 0, bytesAfter: 0, formsSkipped: 0,
                sharedFormsCloned: 0, note: "")

            // 1. 页面自身的内容流
            let refs = document.contentRefs(of: entry.dict)
            if refs.isEmpty {
                if entry.dict["Contents"] == nil {
                    pageReport.note = "无内容流"
                } else {
                    pageReport.note = "内容流内联在页面字典里，本版只报告不改写"
                }
            }
            for ref in refs {
                guard let stream = (try? document.resolve(ref))?.streamValue else { continue }
                let decoded: Data
                do {
                    decoded = try PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
                } catch {
                    pageReport.note = "流解码失败：\(error)"
                    continue
                }
                let result = TextEvictor.evictText(from: decoded)
                pageReport.streams += 1
                pageReport.bytesBefore += decoded.count
                pageReport.bytesAfter += result.data.count
                pageReport.removedRuns += result.removedRuns
                guard result.changed else { continue }
                if let rewritten = replaceStream(stream, with: result.data) {
                    objects.append((ref, rewritten))
                }
            }

            // 2. Form XObject（递归；共享且非目标页使用时深拷贝）
            let formOutcome = PDFFormEviction.run(
                document: document, page: entry.dict,
                usage: isFullDocument ? nil : usage,
                targetPages: targetSet,
                allocator: allocator,
                processed: &processedForms)
            pageReport.formStreams = formOutcome.formCount
            objects.append(contentsOf: formOutcome.objects)
            allocator = PDFObjectAllocator(startingAt: formOutcome.nextObjectNumber)
            clonedFormTotal += formOutcome.cloned
            pageReport.sharedFormsCloned = formOutcome.cloned
            pageReport.removedRuns += formOutcome.removedRuns
            pageReport.formsSkipped += formOutcome.skipped
            if let newResources = formOutcome.newResources {
                var page = entry.dict
                page["Resources"] = .dictionary(newResources)
                objects.append((entry.ref, .dictionary(page)))
            } else if formOutcome.skipped > 0 {
                pageReport.note = appendNote(pageReport.note, "共享 Form 无法深拷贝，已跳过")
            }

            if pageReport.removedRuns == 0 && pageReport.formStreams > 0 && pageReport.note.isEmpty {
                pageReport.note = "Form 内无文本算子（可能整页为矢量或图像）"
            }
            reports.append(pageReport)
        }

        let output: Data
        if objects.isEmpty {
            // 没有可驱逐的文本不是错误：CAD/宣传页常把文字全部转成曲线，或整页就是图片
            output = document.data
        } else {
            output = try PDFIncrementalWriter.append(
                original: document.data, document: document, objects: objects)
        }
        let report = Report(
            inputBytes: document.data.count,
            outputBytes: output.count,
            pages: reports,
            changedObjects: objects.count,
            sharedForms: sharedFormCount,
            clonedForms: clonedFormTotal)
        return (output, report)
    }

    /// 用新内容替换流：优先重新压缩，压不下来就写未压缩。
    /// 驱逐后文本变少，压缩率通常更好，但不要为了「看起来规范」把文件撑大。
    static func replaceStream(_ stream: PDFStream, with body: Data) -> PDFValue? {
        var dict = stream.dictionary
        dict.removeValue(forKey: "DecodeParms")
        let compressed = PDFFilters.deflate(body)
        let useCompressed = compressed.count < body.count
        let payload = useCompressed ? compressed : body
        if useCompressed {
            dict["Filter"] = .name("FlateDecode")
        } else {
            dict.removeValue(forKey: "Filter")
        }
        dict["Length"] = .int(payload.count)
        return .stream(PDFStream(dictionary: dict, raw: payload))
    }

    static func appendNote(_ base: String, _ extra: String) -> String {
        base.isEmpty ? extra : base + "；" + extra
    }
}
