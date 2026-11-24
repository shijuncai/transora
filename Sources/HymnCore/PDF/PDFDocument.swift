import Foundation

/// PDF 文档（只读）。
///
/// 职责边界：把文件结构（xref / 对象 / 对象流 / 流编码）摊平成可查询的模型。
/// 不解释内容流语义，不碰字体与坐标——那些在 Content / Structure 层。
///
/// 解析策略：xref 全表先建，对象按需解析并缓存。300 页文档不会一次性把
/// 所有对象解压进内存，这一点对 P5 的内存预算很关键。
public final class PDFDocument {
    public enum Failure: Error, CustomStringConvertible {
        case notPDF
        case noStartXRef
        case badXRef(Int)
        case encrypted
        case missingObject(PDFRef)
        case objectStreamBroken(Int)

        public var description: String {
            switch self {
            case .notPDF: return "不是 PDF（缺少 %PDF- 头）"
            case .noStartXRef: return "找不到 startxref"
            case .badXRef(let off): return "xref 解析失败 @\(off)"
            case .encrypted: return "文档已加密，本版本不处理"
            case .missingObject(let r): return "对象不存在 \(r)"
            case .objectStreamBroken(let n): return "对象流损坏 \(n)"
            }
        }
    }

    enum Entry {
        case free
        case uncompressed(offset: Int, generation: Int)
        case compressed(streamObject: Int, index: Int)
    }

    public let data: Data
    let bytes: [UInt8]
    public private(set) var version: String = "1.4"
    public private(set) var trailer: [String: PDFValue] = [:]
    public private(set) var startXRef: Int = 0
    public private(set) var isEncrypted = false
    /// 本次解析走过的 xref 段（偏移 + 类型），用于「页数为 0」这类问题的定位。
    public private(set) var xrefSections: [(offset: Int, kind: String)] = []

    var entries: [Int: Entry] = [:]
    var objectCache: [PDFRef: PDFValue] = [:]
    var objStmCache: [Int: [(number: Int, offset: Int)]] = [:]
    var objStmDataCache: [Int: Data] = [:]
    var resolving: Set<PDFRef> = []

    public init(data: Data) throws {
        self.data = data
        self.bytes = [UInt8](data)
        try parseHeader()
        try parseXRefChain()
        if trailer["Encrypt"] != nil { isEncrypted = true }
    }

    public convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    // MARK: - 头部

    func parseHeader() throws {
        let limit = min(bytes.count, 1024)
        var found: Int?
        var i = 0
        while i + 5 <= limit {
            if bytes[i] == 0x25, bytes[i + 1] == 0x50, bytes[i + 2] == 0x44,
               bytes[i + 3] == 0x46, bytes[i + 4] == 0x2D {
                found = i
                break
            }
            i += 1
        }
        guard let header = found else { throw Failure.notPDF }
        var end = header + 5
        var v = ""
        while end < bytes.count && end < header + 12 {
            let b = bytes[end]
            if (b >= 0x30 && b <= 0x39) || b == 0x2E {
                v.append(Character(UnicodeScalar(b)))
                end += 1
            } else {
                break
            }
        }
        if !v.isEmpty { version = v }
    }

    // MARK: - xref

    func parseXRefChain() throws {
        guard let offset = findStartXRef() else { throw Failure.noStartXRef }
        startXRef = offset
        var pending: [Int] = [offset]
        var visited = Set<Int>()
        var firstTrailer: [String: PDFValue]?

        while let next = pending.popLast() {
            if visited.contains(next) { continue }
            visited.insert(next)
            guard next >= 0 && next < bytes.count else { throw Failure.badXRef(next) }

            var parser = PDFParser(bytes, index: next)
            parser.skipWhiteAndComments()
            let sectionTrailer: [String: PDFValue]

            if parser.index + 4 <= bytes.count,
               String(decoding: bytes[parser.index..<parser.index + 4], as: UTF8.self) == "xref" {
                parser.index += 4
                sectionTrailer = try parseClassicXRefTable(&parser)
                xrefSections.append((next, "table"))
            } else {
                sectionTrailer = try parseXRefStream(at: next)
                xrefSections.append((next, "stream"))
            }

            if firstTrailer == nil { firstTrailer = sectionTrailer }
            if let prev = sectionTrailer["Prev"]?.intValue {
                pending.append(prev)
            }
            // 混合引用文件：/XRefStm 指向补充的 xref 流
            if let xrefStm = sectionTrailer["XRefStm"]?.intValue, !visited.contains(xrefStm) {
                let saved = trailer
                _ = try? parseXRefStream(at: xrefStm)
                trailer = saved
                visited.insert(xrefStm)
            }
        }
        if let t = firstTrailer { trailer = t }
        if trailer["Encrypt"] != nil { isEncrypted = true }
    }

    func findStartXRef() -> Int? {
        let needle = Array("startxref".utf8)
        guard bytes.count > needle.count else { return nil }
        var i = bytes.count - needle.count
        while i >= 0 {
            var match = true
            for k in 0..<needle.count where bytes[i + k] != needle[k] {
                match = false
                break
            }
            if match {
                var p = PDFParser(bytes, index: i + needle.count)
                p.skipWhiteAndComments()
                if let v = try? p.parseNumber(), case .int(let offset) = v {
                    return offset
                }
            }
            i -= 1
        }
        return nil
    }

    func parseClassicXRefTable(_ parser: inout PDFParser) throws -> [String: PDFValue] {
        while true {
            parser.skipWhiteAndComments()
            if parser.index + 7 <= bytes.count,
               String(decoding: bytes[parser.index..<parser.index + 7], as: UTF8.self) == "trailer" {
                parser.index += 7
                guard let dict = try parser.parseValue().dictionaryValue else {
                    throw Failure.badXRef(parser.index)
                }
                return dict
            }
            guard let startValue = try? parser.parseNumber(), case .int(let start) = startValue else {
                // 有些文件 xref 后直接跟 trailer 且中间有异常字节，容错退出
                return [:]
            }
            guard let countValue = try? parser.parseNumber(), case .int(let count) = countValue else {
                return [:]
            }
            for i in 0..<max(0, count) {
                parser.skipWhiteAndComments()
                guard let offValue = try? parser.parseNumber(), case .int(let offset) = offValue else {
                    return [:]
                }
                parser.skipWhiteAndComments()
                guard let genValue = try? parser.parseNumber(), case .int(let generation) = genValue else {
                    return [:]
                }
                parser.skipWhiteAndComments()
                guard parser.index < bytes.count else { return [:] }
                let kind = bytes[parser.index]
                parser.index += 1
                let number = start + i
                if entries[number] != nil { continue } // 新段落优先，不被旧段落覆盖
                if kind == 0x6E { // 'n'
                    entries[number] = .uncompressed(offset: offset, generation: generation)
                } else {
                    entries[number] = .free
                }
            }
        }
    }

    func parseXRefStream(at offset: Int) throws -> [String: PDFValue] {
        guard let (_, value) = try? parseIndirectObject(at: offset),
              let stream = value.streamValue else {
            throw Failure.badXRef(offset)
        }
        let dict = stream.dictionary
        guard let widths = dict["W"]?.arrayValue?.compactMap(\.intValue), widths.count >= 3 else {
            throw Failure.badXRef(offset)
        }
        let size = dict["Size"]?.intValue ?? 0
        let index: [Int]
        if let raw = dict["Index"]?.arrayValue?.compactMap(\.intValue), raw.count >= 2 {
            index = raw
        } else {
            index = [0, size]
        }
        let body = try PDFFilters.decode(stream.raw, dictionary: dict)
        let rowLength = widths[0] + widths[1] + widths[2]
        guard rowLength > 0 else { throw Failure.badXRef(offset) }

        let decoded = [UInt8](body)
        var rowOffset = 0
        var p = 0
        while p + 1 < index.count {
            let start = index[p]
            let count = index[p + 1]
            p += 2
            for i in 0..<max(0, count) {
                guard rowOffset + rowLength <= decoded.count else { break }
                var cursor = rowOffset
                func field(_ width: Int) -> Int {
                    guard width > 0 else { return 1 }
                    var v = 0
                    for _ in 0..<width {
                        v = (v << 8) | Int(decoded[cursor])
                        cursor += 1
                    }
                    return v
                }
                let type = field(widths[0])
                let second = field(widths[1])
                let third = field(widths[2])
                rowOffset += rowLength

                let number = start + i
                if entries[number] != nil { continue }
                switch type {
                case 0: entries[number] = .free
                case 1: entries[number] = .uncompressed(offset: second, generation: third)
                case 2: entries[number] = .compressed(streamObject: second, index: third)
                default: entries[number] = .free
                }
            }
        }
        return dict
    }

    // MARK: - 对象解析

    /// 返回 (解析后的引用, 值)。用于 xref 流这类「知道偏移但还不知道对象号」的场合。
    public func parseIndirectObject(at offset: Int, resolveLength: Bool = false) throws -> (PDFRef, PDFValue) {
        var parser = PDFParser(bytes, index: offset)
        parser.skipWhiteAndComments()
        guard let numValue = try? parser.parseNumber(), case .int(let number) = numValue else {
            throw Failure.badXRef(offset)
        }
        parser.skipWhiteAndComments()
        guard let genValue = try? parser.parseNumber(), case .int(let generation) = genValue else {
            throw Failure.badXRef(offset)
        }
        parser.skipWhiteAndComments()
        guard let kw = parser.parseKeyword(), kw == "obj" else {
            throw Failure.badXRef(offset)
        }
        let ref = PDFRef(number, generation)
        let resolver: ((PDFRef) -> Int?)? = resolveLength ? { [weak self] r in
            guard let self else { return nil }
            return (try? self.resolve(r))?.intValue
        } : nil
        let value = try parser.parseValue(resolveLength: resolver)
        return (ref, value)
    }

    public func resolve(_ ref: PDFRef) throws -> PDFValue {
        if let cached = objectCache[ref] { return cached }
        if resolving.contains(ref) { return .null } // 循环引用保护
        resolving.insert(ref)
        defer { resolving.remove(ref) }

        guard let entry = entries[ref.number] else { return .null }
        let value: PDFValue
        switch entry {
        case .free:
            value = .null
        case .uncompressed(let offset, _):
            let (_, v) = try parseIndirectObject(at: offset, resolveLength: true)
            value = v
        case .compressed(let streamObject, let index):
            value = try resolveFromObjectStream(streamObject: streamObject, index: index, number: ref.number)
        }
        objectCache[ref] = value
        return value
    }

    /// 有些 PDF 的 /Length 是间接引用，需要文档级解析，单独暴露给 Parser 用。
    public func resolveLength(_ ref: PDFRef) -> Int? {
        (try? resolve(ref))?.intValue
    }

    func resolveFromObjectStream(streamObject: Int, index: Int, number: Int) throws -> PDFValue {
        if let cached = objectCache[PDFRef(number, 0)] { return cached }
        guard let stream = (try? resolve(PDFRef(streamObject, 0)))?.streamValue else {
            throw Failure.objectStreamBroken(streamObject)
        }
        let decoded: Data
        if let cached = objStmDataCache[streamObject] {
            decoded = cached
        } else {
            decoded = try PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
            objStmDataCache[streamObject] = decoded
        }
        let first = stream.dictionary["First"]?.intValue ?? 0
        let count = stream.dictionary["N"]?.intValue ?? 0

        var pairs: [(number: Int, offset: Int)] = []
        var p = PDFParser(decoded)
        for _ in 0..<max(0, count) {
            guard let n = try? p.parseNumber(), case .int(let objNum) = n,
                  let o = try? p.parseNumber(), case .int(let objOff) = o else { break }
            pairs.append((objNum, objOff))
        }
        objStmCache[streamObject] = pairs

        var target: Int?
        if index < pairs.count && pairs[index].number == number {
            target = pairs[index].offset
        } else {
            target = pairs.first { $0.number == number }?.offset
        }
        guard let rel = target, first + rel >= 0, first + rel < decoded.count else {
            throw Failure.objectStreamBroken(streamObject)
        }
        var body = PDFParser(decoded, index: first + rel)
        return try body.parseValue()
    }

    // MARK: - 便捷访问

    public var catalog: [String: PDFValue] {
        guard case .reference(let r)? = trailer["Root"] else { return [:] }
        return (try? resolve(r))?.dictionaryValue ?? [:]
    }

    public var catalogRef: PDFRef? {
        if case .reference(let r)? = trailer["Root"] { return r }
        return nil
    }

    public var pageCount: Int { pages().count }

    /// xref 条目数（含被 /Prev 链合并进来的旧表）。
    public var xrefEntryCount: Int { entries.count }

    /// 当前已解析并缓存的对象数（诊断用，不参与逻辑）。
    public var cachedObjectCount: Int { objectCache.count }

    /// 所有非空闲对象号（升序）。用于逐对象比对。
    public var objectNumbers: [Int] {
        entries.compactMap { number, entry in
            if case .free = entry { return nil }
            return number
        }.sorted()
    }

    /// xref 条目的文字描述（诊断用）。
    public func xrefEntryDescription(_ number: Int) -> String {
        guard let entry = entries[number] else { return "无条目" }
        switch entry {
        case .free: return "free"
        case .uncompressed(let offset, let generation): return "uncompressed @\(offset) gen=\(generation)"
        case .compressed(let streamObject, let index): return "objstm \(streamObject) idx=\(index)"
        }
    }

    /// 对象在文件中的原始字节片段（诊断用，只取前 N 字节）。
    public func rawSlice(at offset: Int, length: Int = 120) -> String {
        guard offset >= 0, offset < bytes.count else { return "<越界>" }
        let end = min(bytes.count, offset + length)
        return String(decoding: bytes[offset..<end], as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// 该对象号是否在 xref 里有非空闲条目。
    public func xrefHasObject(_ number: Int) -> Bool {
        guard let entry = entries[number] else { return false }
        if case .free = entry { return false }
        return true
    }

    /// 下一个可用的对象号。新对象只能往后排，不能复用（旧定义仍被 /Prev 引用）。
    public var nextFreeObjectNumber: Int {
        let byEntries = (objectNumbers.last ?? 0) + 1
        let bySize = trailer["Size"]?.intValue ?? 0
        return max(byEntries, bySize, 1)
    }

    /// 按阅读顺序（页面树先序遍历）返回页面字典。
    public func pages() -> [[String: PDFValue]] {
        pageEntries().map(\.dict)
    }

    /// 同 `pages()`，但带上页面对象号——写回时必须知道改哪个对象。
    public func pageEntries() -> [(ref: PDFRef, dict: [String: PDFValue])] {
        var result: [(ref: PDFRef, dict: [String: PDFValue])] = []
        var visited = Set<PDFRef>()

        func walk(_ ref: PDFRef, inherited: [String: PDFValue]) {
            if visited.contains(ref) { return }
            visited.insert(ref)
            guard let dict = (try? resolve(ref))?.dictionaryValue else { return }
            var merged = inherited
            for key in ["Resources", "MediaBox", "CropBox", "Rotate"] {
                if let v = dict[key] { merged[key] = v }
            }
            let type = dict["Type"]?.nameValue
            if type == "Pages" || dict["Kids"] != nil {
                for kid in dict["Kids"]?.arrayValue ?? [] {
                    if case .reference(let kidRef) = kid {
                        walk(kidRef, inherited: merged)
                    }
                }
            } else {
                var page = dict
                for key in ["Resources", "MediaBox", "CropBox", "Rotate"] where page[key] == nil {
                    if let v = merged[key] { page[key] = v }
                }
                result.append((ref, page))
            }
        }

        // 从 Catalog 的 /Pages 开始遍历；直接对 Catalog 调用会把目录页当成内容页
        if case .reference(let pagesRoot)? = catalog["Pages"] {
            walk(pagesRoot, inherited: [:])
        } else if let root = catalogRef {
            walk(root, inherited: [:])
        }
        return result
    }

    /// 页面的内容流引用列表（/Contents 可以是单流或流数组）。
    public func contentRefs(of page: [String: PDFValue]) -> [PDFRef] {
        guard let contents = page["Contents"] else { return [] }
        switch contents {
        case .reference(let r):
            // 可能是数组对象
            if let arr = (try? resolve(r))?.arrayValue {
                return arr.compactMap { v -> PDFRef? in
                    if case .reference(let rr) = v { return rr }
                    return nil
                }
            }
            return [r]
        case .array(let items):
            return items.compactMap { v -> PDFRef? in
                if case .reference(let rr) = v { return rr }
                return nil
            }
        default:
            return []
        }
    }

    /// 取内容流的解码后字节；若内容流直接内联在页面字典里则返回其字节。
    public func contentData(of page: [String: PDFValue]) throws -> [Data] {
        var out: [Data] = []
        for ref in contentRefs(of: page) {
            guard let stream = (try? resolve(ref))?.streamValue else { continue }
            out.append(try PDFFilters.decode(stream.raw, dictionary: stream.dictionary))
        }
        if out.isEmpty, let direct = page["Contents"]?.streamValue {
            out.append(try PDFFilters.decode(direct.raw, dictionary: direct.dictionary))
        }
        return out
    }

    /// 该页资源里所有 Form XObject。
    public func formXObjectRefs(of page: [String: PDFValue]) -> [PDFRef] {
        xObjects(in: resolvedResources(page["Resources"]))
            .filter { $0.subtype == "Form" }
            .map(\.ref)
    }

    /// /Resources 可能是引用也可能是内联字典，统一取其字典。
    public func resolvedResources(_ value: PDFValue?) -> [String: PDFValue] {
        guard let value else { return [:] }
        if case .reference(let r) = value {
            return (try? resolve(r))?.dictionaryValue ?? [:]
        }
        return value.dictionaryValue ?? [:]
    }

    public struct XObjectInfo: Sendable {
        public var name: String
        public var ref: PDFRef
        public var subtype: String
        public var dict: [String: PDFValue]
    }

    /// 资源 /XObject 里的全部外部对象（含 Image / Form / PS）。
    public func xObjects(in resources: [String: PDFValue]) -> [XObjectInfo] {
        let xobjectValue: PDFValue
        if case .reference(let r)? = resources["XObject"] {
            xobjectValue = (try? resolve(r)) ?? .null
        } else if let inline = resources["XObject"] {
            xobjectValue = inline
        } else {
            return []
        }
        guard let dict = xobjectValue.dictionaryValue else { return [] }
        var out: [XObjectInfo] = []
        for (name, value) in dict {
            guard case .reference(let r) = value else { continue }
            guard let sub = (try? resolve(r))?.dictionaryValue else { continue }
            out.append(XObjectInfo(name: name, ref: r,
                                   subtype: sub["Subtype"]?.nameValue ?? "?",
                                   dict: sub))
        }
        return out.sorted { $0.name < $1.name }
    }
}
