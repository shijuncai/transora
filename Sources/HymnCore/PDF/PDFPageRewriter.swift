import Foundation

/// 页面级重写：替换 /Contents、合并字体资源、必要时重指 Form。
///
/// 关于「就地替换还是新建对象」：
///     增量更新本身就会保留旧字节（旧内容流仍在文件里，只是 xref 不再引用），
///     所以两种做法对输出体积没有区别——真正的减法只能靠全量重写（`scrub`，P4）。
///     差别只在对象数量：就地替换不会留下一个孤儿内容流对象。
///     策略因此定为：页面只有一个内容流时就地替换，多个时合并成新对象再指过去。
///
/// 关于内容流的拼接：
///     /Contents 是数组时表示「同一逻辑流的分段」，按顺序拼接语义等价。
///     拼接前给整段套上 `q ... Q`，保证其后绘制时 CTM 回到页面默认值。
public enum PDFPageRewriter {
    public struct Plan {
        public var objects: [(ref: PDFRef, value: PDFValue)]
        public var contentRef: PDFRef
        public var pageRef: PDFRef
        public var nextObjectNumber: Int
        public var replacedInPlace: Bool
    }

    /// 页面只有一个内容流时直接改它，避免留一份孤儿正文。
    /// 返回 nil 表示页面没有可复用的单一内容流。
    public static func singleContentStream(
        document: PDFDocument,
        page: [String: PDFValue],
        newContent: Data
    ) -> (ref: PDFRef, value: PDFValue)? {
        let refs = document.contentRefs(of: page)
        guard refs.count == 1,
              let stream = (try? document.resolve(refs[0]))?.streamValue
        else { return nil }
        guard let replaced = PDFEvictor.replaceStream(stream, with: newContent) else { return nil }
        return (refs[0], replaced)
    }

    /// - Parameters:
    ///   - newContent: 已经拼好的完整页面内容流（调用方负责 q/Q 包裹）
    ///   - fonts: 需要并入页面 /Font 的字体（资源名, 字体对象引用）
    ///   - reuseContentRef: 传 nil 表示新建内容流对象
    public static func replaceContent(
        document: PDFDocument,
        pageRef: PDFRef,
        pageDict: [String: PDFValue],
        newContent: Data,
        fonts: [(name: String, ref: PDFRef)],
        reuseContentRef: PDFRef? = nil,
        allocator: inout PDFObjectAllocator
    ) -> Plan {
        var objects: [(ref: PDFRef, value: PDFValue)] = []

        // 1. 内容流：能就地改就就地改
        let contentRef: PDFRef
        var replacedInPlace = false
        if let reuse = reuseContentRef,
           let stream = (try? document.resolve(reuse))?.streamValue,
           let replaced = PDFEvictor.replaceStream(stream, with: newContent) {
            objects.append((reuse, replaced))
            contentRef = reuse
            replacedInPlace = true
        } else {
            contentRef = allocator.allocate()
            var contentDict: [String: PDFValue] = [:]
            let compressed = PDFFilters.deflate(newContent)
            let useCompressed = compressed.count < newContent.count
            let payload = useCompressed ? compressed : newContent
            if useCompressed { contentDict["Filter"] = .name("FlateDecode") }
            contentDict["Length"] = .int(payload.count)
            objects.append((contentRef, .stream(PDFStream(dictionary: contentDict, raw: payload))))
        }

        // 2. 资源（可能与别的页共用，所以一律新建对象再指过去）
        let resourcesWasReference: Bool
        if case .reference = pageDict["Resources"] { resourcesWasReference = true }
        else { resourcesWasReference = false }
        var resources = document.resolvedResources(pageDict["Resources"])

        // 3. 字体字典：可能是引用，同样不能就地改
        if !fonts.isEmpty {
            var fontDict: [String: PDFValue] = [:]
            var fontWasReference = false
            if case .reference(let r)? = resources["Font"] {
                fontWasReference = true
                fontDict = (try? document.resolve(r))?.dictionaryValue ?? [:]
            } else if let inline = resources["Font"] {
                fontDict = inline.dictionaryValue ?? [:]
            }
            for font in fonts { fontDict[font.name] = .reference(font.ref) }

            if fontWasReference {
                let fontRef = allocator.allocate()
                objects.append((fontRef, .dictionary(fontDict)))
                resources["Font"] = .reference(fontRef)
            } else {
                resources["Font"] = .dictionary(fontDict)
            }
        }

        // 4. 页面字典
        var page = pageDict
        if resourcesWasReference || !fonts.isEmpty {
            let resourcesRef = allocator.allocate()
            objects.append((resourcesRef, .dictionary(resources)))
            page["Resources"] = .reference(resourcesRef)
        }
        if !replacedInPlace {
            page["Contents"] = .reference(contentRef)
        }
        objects.append((pageRef, .dictionary(page)))

        return Plan(objects: objects, contentRef: contentRef,
                    pageRef: pageRef, nextObjectNumber: allocator.next,
                    replacedInPlace: replacedInPlace)
    }

    /// 把一个 Form 也重写成新对象（保留原对象不动），用于需要按页定制内容的场合。
    public static func replaceFormContent(
        document: PDFDocument,
        formRef: PDFRef,
        newContent: Data,
        allocator: inout PDFObjectAllocator
    ) -> (ref: PDFRef, value: PDFValue)? {
        guard let stream = (try? document.resolve(formRef))?.streamValue else { return nil }
        var dict = stream.dictionary
        let compressed = PDFFilters.deflate(newContent)
        let useCompressed = compressed.count < newContent.count
        let payload = useCompressed ? compressed : newContent
        dict.removeValue(forKey: "DecodeParms")
        if useCompressed { dict["Filter"] = .name("FlateDecode") } else { dict.removeValue(forKey: "Filter") }
        dict["Length"] = .int(payload.count)
        let ref = allocator.allocate()
        return (ref, .stream(PDFStream(dictionary: dict, raw: payload)))
    }
}

/// 生成「在页面上画一段文字」的内容流片段。
///
/// 这里只做 P1 需要的最小集：单行、水平书写、指定字号与基线原点。
/// 真正的段落排版（断行、禁则、居中、行距）在 P3。
public enum PDFTextStamp {
    public struct Style: Sendable {
        public var fontSize: Double
        public var colorComponents: [Double]   // RGB，0…1
        public var horizontalScale: Double     // Tz，百分比 /100

        public static let black = Style(fontSize: 12, colorComponents: [0, 0, 0], horizontalScale: 1)
    }

    /// 返回 `q … Q` 包裹的绘制片段。
    /// - Parameter encodedText: 2 字节大端 CID 串（由 PDFFontEmbedder 生成）
    public static func drawLine(
        resourceName: String,
        encodedText: Data,
        at origin: (x: Double, y: Double),
        style: Style
    ) -> Data {
        var out = Data()
        out.append(contentsOf: Array("q\n".utf8))
        let rgb = style.colorComponents.count == 3 ? style.colorComponents : [0, 0, 0]
        out.append(contentsOf: Array(String(format: "%.3f %.3f %.3f rg\n", rgb[0], rgb[1], rgb[2]).utf8))
        out.append(contentsOf: Array("BT\n".utf8))
        out.append(contentsOf: Array("/\(resourceName) \(format(style.fontSize)) Tf\n".utf8))
        out.append(contentsOf: Array("1 0 0 1 \(format(origin.x)) \(format(origin.y)) Tm\n".utf8))
        if style.horizontalScale != 1 {
            out.append(contentsOf: Array("\(format(style.horizontalScale * 100)) Tz\n".utf8))
        }
        out.append(contentsOf: Array("<".utf8))
        let hex = Array("0123456789ABCDEF".utf8)
        for byte in encodedText {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
        out.append(contentsOf: Array("> Tj\nET\nQ\n".utf8))
        return out
    }

    /// 把整段原内容包进 q/Q，保证其后的绘制从页面默认 CTM 开始。
    public static func wrap(original: Data) -> Data {
        var out = Data()
        out.append(contentsOf: Array("q\n".utf8))
        out.append(original)
        if let last = original.last, last != 0x0A && last != 0x0D {
            out.append(0x0A)
        }
        out.append(contentsOf: Array("Q\n".utf8))
        return out
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
