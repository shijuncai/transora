import Foundation

/// 「驱逐 + 插字」的最小闭环：删掉原文字，画上我们的字。
///
/// P1 的验收就靠这一步：如果它成立，说明「接管文本」这条链路是通的，
/// 后面的段落排版才有意义；如果不成立，2 万行的排版层全是白写。
///
/// 顺序固定：先驱逐、再插入。反过来会让新画的字被当成原文删掉。
public enum PDFStamper {
    public struct PageGeometry {
        public var mediaBox: (x0: Double, y0: Double, x1: Double, y1: Double)
        public var rotation: Int

        public var width: Double { mediaBox.x1 - mediaBox.x0 }
        public var height: Double { mediaBox.y1 - mediaBox.y0 }
    }

    public struct Outcome {
        public var output: Data
        public var pageNumber: Int
        public var origin: (x: Double, y: Double)
        public var fontSize: Double
        public var removedRuns: Int
        public var formStreams: Int
        public var embeddedFontName: String
        public var subsetName: String
        public var subsetGlyphs: Int
        public var subsetBytes: Int
        public var missingScalars: [UInt32]
        public var cidCount: Int
        public var newObjectCount: Int
    }

    public static func geometry(of page: [String: PDFValue]) -> PageGeometry {
        let box = page["MediaBox"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        let media: (Double, Double, Double, Double)
        if box.count == 4 {
            media = (box[0], box[1], box[2], box[3])
        } else {
            media = (0, 0, 595, 842)   // A4，缺 MediaBox 时按 A4 处理
        }
        return PageGeometry(
            mediaBox: (min(media.0, media.2), min(media.1, media.3),
                       max(media.0, media.2), max(media.1, media.3)),
            rotation: page["Rotate"]?.intValue ?? 0)
    }

    /// 选一个不与现用字体冲突的资源名。
    public static func resourceName(document: PDFDocument, page: [String: PDFValue]) -> String {
        let resources = document.resolvedResources(page["Resources"])
        var existing = Set<String>()
        if case .reference(let r)? = resources["Font"] {
            existing = Set(((try? document.resolve(r))?.dictionaryValue ?? [:]).keys)
        } else if let inline = resources["Font"] {
            existing = Set((inline.dictionaryValue ?? [:]).keys)
        }
        var index = 1
        while existing.contains("LNF\(index)") { index += 1 }
        return "LNF\(index)"
    }

    /// - Parameters:
    ///   - evictForms: 是否连 Form XObject 里的文字一起删（默认是）。传 false 可保留
    ///                 表单域/页眉里的文字，用于「只替换正文」的场景。
    public static func stamp(
        document: PDFDocument,
        pageIndex: Int,
        text: String,
        font: TrueTypeFont,
        fontSize: Double = 14,
        origin: (x: Double, y: Double)? = nil,
        evictForms: Bool = true
    ) throws -> Outcome {
        let entries = document.pageEntries()
        guard pageIndex >= 0 && pageIndex < entries.count else {
            throw PDFIncrementalWriter.Failure.empty
        }
        let entry = entries[pageIndex]
        let geo = geometry(of: entry.dict)

        // 1. 拼出整页原内容（多段 /Contents 是同一逻辑流的分段，拼接语义等价）
        var original = Data()
        for ref in document.contentRefs(of: entry.dict) {
            guard let stream = (try? document.resolve(ref))?.streamValue,
                  let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
            else { continue }
            original.append(decoded)
            if let last = decoded.last, last != 0x0A && last != 0x0D {
                original.append(0x0A)
            }
        }

        // 2. 驱逐页面自身内容流里的文本
        let evicted = TextEvictor.evictText(from: original)

        // 3. Form 里的文字：默认也删（否则旧文字还在，只是被盖住）。
        //    只处理一页时必须判断 form 是否被别的页共用——共用就克隆，否则就地改。
        var extraObjects: [(ref: PDFRef, value: PDFValue)] = []
        var formRemoved = 0
        var formStreams = 0
        var allocator = PDFObjectAllocator(startingAt: document.nextFreeObjectNumber)
        var rewrittenResources: [String: PDFValue]?
        var processed = Set<Int>()

        if evictForms {
            let usage = PDFFormGraph.usageByPage(document: document)
            let outcome = PDFFormEviction.run(
                document: document, page: entry.dict,
                usage: usage, targetPages: [pageIndex],
                allocator: allocator, processed: &processed)
            extraObjects.append(contentsOf: outcome.objects)
            allocator = PDFObjectAllocator(startingAt: outcome.nextObjectNumber)
            formRemoved = outcome.removedRuns
            formStreams = outcome.formCount
            rewrittenResources = outcome.newResources
        } else {
            formStreams = PDFFormGraph.reachableForms(
                document: document,
                resources: document.resolvedResources(entry.dict["Resources"])).count
        }

        // 4. 嵌字体并编码文本
        let name = resourceName(document: document, page: entry.dict)
        let embedded = try PDFFontEmbedder.embed(
            font: font, text: text, resourceName: name,
            firstObjectNumber: allocator.next)
        allocator = PDFObjectAllocator(startingAt: firstObjectNumberAfter(embedded))

        // 5. 组装新内容流：q <原内容> Q <新文字>
        var body = PDFTextStamp.wrap(original: evicted.data)
        let target = origin ?? (x: geo.mediaBox.x0 + 72,
                                y: geo.mediaBox.y1 - 72 - fontSize)
        body.append(PDFTextStamp.drawLine(
            resourceName: name,
            encodedText: embedded.encodedText,
            at: target,
            style: .init(fontSize: fontSize, colorComponents: [0, 0, 0], horizontalScale: 1)))

        // 6. 重写页面（内容流 + 资源 + 字体）。单内容流的页就地改，避免留孤儿正文。
        var page = entry.dict
        if let rewritten = rewrittenResources { page["Resources"] = .dictionary(rewritten) }
        let reusable = PDFPageRewriter.singleContentStream(
            document: document, page: entry.dict, newContent: body)?.ref
        let plan = PDFPageRewriter.replaceContent(
            document: document, pageRef: entry.ref, pageDict: page,
            newContent: body, fonts: [(name, embedded.type0Ref)],
            reuseContentRef: reusable, allocator: &allocator)

        let objects = embedded.objects + extraObjects + plan.objects
        let output = try PDFIncrementalWriter.append(
            original: document.data, document: document, objects: objects)

        return Outcome(
            output: output,
            pageNumber: pageIndex + 1,
            origin: target,
            fontSize: fontSize,
            removedRuns: evicted.removedRuns + formRemoved,
            formStreams: formStreams,
            embeddedFontName: embedded.subsetName,
            subsetName: embedded.subsetName,
            subsetGlyphs: embedded.subsetGlyphCount,
            subsetBytes: embedded.subsetBytes,
            missingScalars: embedded.missingScalars,
            cidCount: embedded.encodedText.count / 2,
            newObjectCount: objects.count)
    }

    /// 嵌入器固定分配 5 个连续对象号，取最后一个 +1 即下一个可用号。
    static func firstObjectNumberAfter(_ embedded: PDFFontEmbedder.Embedded) -> Int {
        (embedded.objects.map(\.ref.number).max() ?? 0) + 1
    }
}
