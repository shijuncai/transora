import Foundation

/// 对象号分配器。增量写入只在文件尾部追加，所以新对象号从 /Size 往后取。
public struct PDFObjectAllocator {
    public private(set) var next: Int

    public init(startingAt next: Int) {
        self.next = max(1, next)
    }

    public mutating func allocate() -> PDFRef {
        defer { next += 1 }
        return PDFRef(next, 0)
    }
}

/// Form XObject 的递归遍历与深拷贝。
///
/// 为什么必须处理 Form：
///     InDesign / Word / CAD 导出的 PDF 会把整页图文放进一个 Form XObject，
///     页面的 /Contents 里只有一个 `Do`。P0 只在页面内容流里删文本算子，
///     这类文件会「一个字都没删掉」却不报错——这是静默失败，比崩溃更糟。
///
/// 为什么共享 form 必须深拷贝：
///     一个 Form 可能被多页共用（模板、页眉、公司 logo）。如果就地改它，
///     改了第 3 页就等于同时改了第 7 页。P3 给每页画不同译文时这会立刻炸。
///     所以只要「本次只处理部分页」且该 form 还被别的页用着，就必须先复制成
///     新对象，再把目标页的资源指向新对象，原对象一个字节都不动。
public enum PDFFormGraph {
    public struct Node: Sendable {
        public var ref: PDFRef
        public var dict: [String: PDFValue]
        public var depth: Int
    }

    /// 从给定资源出发，递归枚举所有 Form XObject（去重、限深、防环）。
    public static func reachableForms(
        document: PDFDocument,
        resources: [String: PDFValue],
        maxDepth: Int = 8
    ) -> [Node] {
        var out: [Node] = []
        var visited = Set<Int>()
        var stack: [(resources: [String: PDFValue], depth: Int)] = [(resources, 0)]

        while let item = stack.popLast() {
            guard item.depth <= maxDepth else { continue }
            for xobject in document.xObjects(in: item.resources) where xobject.subtype == "Form" {
                guard visited.insert(xobject.ref.number).inserted else { continue }
                out.append(Node(ref: xobject.ref, dict: xobject.dict, depth: item.depth))
                // Form 可以有自己的 /Resources；没有就沿用调用方的（PDF 规范允许继承）
                let child = xobject.dict["Resources"].map { document.resolvedResources($0) }
                    ?? item.resources
                stack.append((child, item.depth + 1))
            }
        }
        return out
    }

    /// 每个 Form 被多少页引用（用于判断是否共享）。
    public static func usageByPage(document: PDFDocument) -> [Int: Set<Int>] {
        var usage: [Int: Set<Int>] = [:]
        for (index, entry) in document.pageEntries().enumerated() {
            let resources = document.resolvedResources(entry.dict["Resources"])
            for node in reachableForms(document: document, resources: resources) {
                usage[node.ref.number, default: []].insert(index)
            }
        }
        return usage
    }

    /// 把 Form 引用整理解析后的显示名，仅用于报告。
    public static func describe(_ nodes: [Node]) -> String {
        nodes.map { "\($0.ref.number)" }.joined(separator: ",")
    }
}

/// 把 Form XObject 深拷贝成新对象（可同时驱逐其中的文本）。
///
/// 拷贝是**递归**的：父 form 的资源里若还有 form，也要一起复制并改指向，
/// 否则父 form 仍然引用原来的子 form，改一页串多页的问题只解决了一半。
public struct PDFFormCloner {
    public private(set) var objects: [(ref: PDFRef, value: PDFValue)] = []
    public private(set) var removedRuns = 0
    public private(set) var clonedForms = 0
    public private(set) var decodeFailures = 0

    private let document: PDFDocument
    private var allocator: PDFObjectAllocator
    private var cloneMap: [Int: PDFRef] = [:]

    public init(document: PDFDocument, allocator: PDFObjectAllocator) {
        self.document = document
        self.allocator = allocator
    }

    public var nextObjectNumber: Int { allocator.next }

    public mutating func clone(_ ref: PDFRef, evictText: Bool) -> PDFRef? {
        if let existing = cloneMap[ref.number] { return existing }
        guard let stream = (try? document.resolve(ref))?.streamValue else { return nil }

        // 先占号再递归：子 form 反向引用父 form 时不会无限递归
        let newRef = allocator.allocate()
        cloneMap[ref.number] = newRef

        let decoded: Data
        do {
            decoded = try PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
        } catch {
            decodeFailures += 1
            return nil
        }

        var body = decoded
        if evictText {
            let result = TextEvictor.evictText(from: decoded)
            body = result.data
            removedRuns += result.removedRuns
        }

        var dict = stream.dictionary
        // 资源里若有子 form，一并复制并改指向
        if let resourcesValue = dict["Resources"] {
            let resolved = document.resolvedResources(resourcesValue)
            if let newResources = cloneResources(resolved) {
                dict["Resources"] = newResources
            }
        }

        let compressed = PDFFilters.deflate(body)
        let useCompressed = compressed.count < body.count
        let payload = useCompressed ? compressed : body
        dict.removeValue(forKey: "DecodeParms")
        if useCompressed {
            dict["Filter"] = .name("FlateDecode")
        } else {
            dict.removeValue(forKey: "Filter")
        }
        dict["Length"] = .int(payload.count)

        objects.append((newRef, .stream(PDFStream(dictionary: dict, raw: payload))))
        clonedForms += 1
        return newRef
    }

    /// 复制资源字典：只改 /XObject 里 Form 的指向，Image 等其他对象保持原引用
    /// （图片不动是硬要求，复制图片会白白撑大文件）。
    ///
    /// /XObject 既可能是引用，也可能是内联字典，两种都要处理——
    /// 早期的实现只认引用，于是「内联资源」的文件会静默跳过整页的 form。
    private mutating func cloneResources(
        _ resources: [String: PDFValue]
    ) -> PDFValue? {
        guard let xobjects = resolvedXObjects(resources) else { return nil }

        var changed = false
        var newXObjects: [String: PDFValue] = [:]
        for (name, value) in xobjects {
            guard case .reference(let childRef) = value else {
                newXObjects[name] = value
                continue
            }
            let isForm = (try? document.resolve(childRef))?
                .dictionaryValue?["Subtype"]?.nameValue == "Form"
            if isForm, let cloned = clone(childRef, evictText: true) {
                newXObjects[name] = .reference(cloned)
                changed = true
            } else {
                newXObjects[name] = value
            }
        }
        guard changed else { return nil }

        var newResources = resources
        let resourcesRef = allocator.allocate()
        newResources["XObject"] = .dictionary(newXObjects)
        objects.append((resourcesRef, .dictionary(newResources)))
        return .reference(resourcesRef)
    }

    /// 把页面资源里被复制的 form 换成新引用。
    /// 返回 nil 表示本页没有跨页共享的 form，无需改写页面字典。
    public mutating func rewritePageResources(
        _ pageDict: [String: PDFValue],
        evictText: Bool
    ) -> [String: PDFValue]? {
        var resources = document.resolvedResources(pageDict["Resources"])
        guard let xobjects = resolvedXObjects(resources) else { return nil }

        var changed = false
        var newXObjects: [String: PDFValue] = [:]
        for (name, value) in xobjects {
            guard case .reference(let childRef) = value else {
                newXObjects[name] = value
                continue
            }
            let isForm = (try? document.resolve(childRef))?
                .dictionaryValue?["Subtype"]?.nameValue == "Form"
            if isForm, let cloned = clone(childRef, evictText: evictText) {
                newXObjects[name] = .reference(cloned)
                changed = true
            } else {
                newXObjects[name] = value
            }
        }
        guard changed else { return nil }

        resources["XObject"] = .dictionary(newXObjects)
        return resources
    }

    /// 取 /XObject 字典，兼容「引用」与「内联」两种写法。
    private func resolvedXObjects(_ resources: [String: PDFValue]) -> [String: PDFValue]? {
        guard let value = resources["XObject"] else { return nil }
        if case .reference(let r) = value {
            return (try? document.resolve(r))?.dictionaryValue
        }
        return value.dictionaryValue
    }
}

// MARK: - 驱逐一页的 Form（含「共享才克隆」判断）

/// 「一页里的 Form 要不要克隆」这件判断只该有一份实现。
///
/// 规则很直接：
/// - 全篇处理（usage == nil）：所有页都改，就地改即可，不留副本；
/// - 只处理部分页：form 若还被非目标页引用，必须克隆；
///   只属于目标页的 form 仍然就地改，避免白白复制几十万字节。
public enum PDFFormEviction {
    public struct Outcome {
        public var objects: [(ref: PDFRef, value: PDFValue)] = []
        public var removedRuns = 0
        public var skipped = 0
        public var cloned = 0
        public var formCount = 0
        /// 克隆路径下需要写回页面字典的新资源；就地改时为 nil
        public var newResources: [String: PDFValue]?
        public var nextObjectNumber: Int
    }

    public static func run(
        document: PDFDocument,
        page: [String: PDFValue],
        usage: [Int: Set<Int>]?,
        targetPages: Set<Int>,
        allocator: PDFObjectAllocator,
        processed: inout Set<Int>
    ) -> Outcome {
        var outcome = Outcome(nextObjectNumber: allocator.next)
        let resources = document.resolvedResources(page["Resources"])
        let nodes = PDFFormGraph.reachableForms(document: document, resources: resources)
        outcome.formCount = nodes.count
        guard !nodes.isEmpty else { return outcome }

        let needsClone = nodes.contains { node in
            guard let pages = usage?[node.ref.number], pages.count > 1 else { return false }
            return !pages.isSubset(of: targetPages)
        }

        if needsClone {
            var cloner = PDFFormCloner(document: document, allocator: allocator)
            if let newResources = cloner.rewritePageResources(page, evictText: true) {
                outcome.objects = cloner.objects
                outcome.nextObjectNumber = cloner.nextObjectNumber
                outcome.cloned = cloner.clonedForms
                outcome.removedRuns = cloner.removedRuns
                outcome.skipped = cloner.decodeFailures
                outcome.newResources = newResources
            } else {
                // 资源结构异常导致复制失败：跳过并明确报告，不冒险就地改共享对象
                outcome.skipped = nodes.count
            }
            return outcome
        }

        for node in nodes {
            guard processed.insert(node.ref.number).inserted else { continue }
            guard let stream = (try? document.resolve(node.ref))?.streamValue else { continue }
            let decoded: Data
            do {
                decoded = try PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
            } catch {
                outcome.skipped += 1
                continue
            }
            let result = TextEvictor.evictText(from: decoded)
            outcome.removedRuns += result.removedRuns
            guard result.changed,
                  let replaced = PDFEvictor.replaceStream(stream, with: result.data)
            else { continue }
            outcome.objects.append((node.ref, replaced))
        }
        return outcome
    }
}
