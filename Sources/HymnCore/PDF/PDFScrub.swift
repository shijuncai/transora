import Foundation

/// 「洗版」：把增量更新过的 PDF 重写成一份干净文件。
///
/// 为什么必须有它：增量写入只追加、不改原字节，这是「图片/矢量结构性不可能变」的
/// 保证来源，但代价是**被替换掉的原文仍然物理留在文件里**——xref 不再引用它，
/// 常规工具读不出来，用 `strings` 或取证工具却照样能看到。
/// 对一个翻译工具来说这是隐私问题，不是体积问题。
///
/// 做法：从 `/Root`、`/Info` 出发做可达性遍历，只写活对象，再写新的 xref 与 trailer。
/// 流的 `raw` 字节原样拷贝（只重算 `/Length`、重排字典键），所以
/// 「图片 SHA-256 不变」这条性质在洗版后依然成立——可以继续用 R1 复核。
///
/// 已知边界：不保留表单签名（`/Sig`）、不重排页面对象（不做 linearize）、
/// 不重建对象流（新文件是传统对象，体积略大但兼容性最好）。
public enum PDFScrub {
    public struct Result: Sendable {
        public var data: Data
        public var liveObjects: Int
        public var droppedObjects: Int
        public var unresolvedObjects: Int
        public var beforeBytes: Int
        public var afterBytes: Int

        public var savedBytes: Int { beforeBytes - afterBytes }
    }

    public enum Failure: Error, CustomStringConvertible {
        case encrypted
        case noCatalog
        case noRoot

        public var description: String {
            switch self {
            case .encrypted: return "文档已加密，拒绝洗版"
            case .noCatalog: return "找不到 /Root 指向的 Catalog"
            case .noRoot: return "trailer 里没有 /Root"
            }
        }
    }

    /// - Parameter overrides: 本次改写过的对象（对象号 → 新值）。
    ///   它们在原文件里已被增量更新覆盖，洗版时必须写新值。
    public static func rewrite(
        document: PDFDocument,
        overrides: [(ref: PDFRef, value: PDFValue)] = []
    ) throws -> Result {
        if document.isEncrypted { throw Failure.encrypted }
        guard case .reference(let rootRef)? = document.trailer["Root"] else {
            throw Failure.noRoot
        }

        var overrideByNumber: [Int: PDFValue] = [:]
        var generationByNumber: [Int: Int] = [rootRef.number: rootRef.generation]
        for item in overrides {
            overrideByNumber[item.ref.number] = item.value
            generationByNumber[item.ref.number] = item.ref.generation
        }

        // 1. 可达性遍历。种子是 trailer 的 Root / Info + 本次覆盖的对象
        //    （覆盖对象可能引用新加的对象，必须从它们出发）。
        var live: [Int: PDFValue] = [:]
        var queue: [PDFRef] = [rootRef]
        if case .reference(let info)? = document.trailer["Info"] {
            queue.append(info)
            generationByNumber[info.number] = info.generation
        }
        for item in overrides { queue.append(item.ref) }

        var seen = Set<Int>()
        var unresolved = 0
        while let ref = queue.popLast() {
            guard !seen.contains(ref.number) else { continue }
            seen.insert(ref.number)

            let value: PDFValue
            if let override = overrideByNumber[ref.number] {
                value = override
            } else if let resolved = try? document.resolve(ref) {
                value = resolved
            } else {
                unresolved += 1
                continue
            }
            live[ref.number] = value
            generationByNumber[ref.number] = ref.generation
            value.collectReferences(into: &queue)
        }

        // 2. 写出：header + 对象 + 经典 xref + trailer
        var out = Data()
        out.append(contentsOf: Array("%PDF-1.7\n".utf8))
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        var offsets: [(number: Int, offset: Int, generation: Int)] = []
        offsets.reserveCapacity(live.count)
        for number in live.keys.sorted() {
            guard let value = live[number] else { continue }
            let generation = generationByNumber[number] ?? 0
            offsets.append((number, out.count, generation))
            out.append(contentsOf: Array("\(number) \(generation) obj\n".utf8))
            out.append(PDFSerialize.value(value))
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        // 3. xref：`0 1` 的空条目 + 按连续区段分组的对象
        let xrefOffset = out.count
        out.append(contentsOf: Array("xref\n".utf8))
        out.append(contentsOf: Array("0 1\n0000000000 65535 f \n".utf8))
        var index = 0
        while index < offsets.count {
            let start = offsets[index].number
            var end = index
            while end + 1 < offsets.count && offsets[end + 1].number == offsets[end].number + 1 {
                end += 1
            }
            out.append(contentsOf: Array("\(start) \(end - index + 1)\n".utf8))
            for i in index...end {
                out.append(contentsOf: Array(
                    String(format: "%010d %05d n \n", offsets[i].offset, offsets[i].generation).utf8))
            }
            index = end + 1
        }

        let maxNumber = offsets.map(\.number).max() ?? 0
        var trailer: [String: PDFValue] = [
            "Size": .int(max(maxNumber + 1, rootRef.number + 1)),
            "Root": .reference(rootRef),
        ]
        if let info = document.trailer["Info"] { trailer["Info"] = info }
        if let id = document.trailer["ID"] { trailer["ID"] = id }
        out.append(contentsOf: Array("trailer\n".utf8))
        out.append(PDFSerialize.value(.dictionary(trailer)))
        out.append(contentsOf: Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))

        return Result(
            data: out,
            liveObjects: live.count,
            droppedObjects: max(0, document.xrefEntryCount - live.count),
            unresolvedObjects: unresolved,
            beforeBytes: document.data.count,
            afterBytes: out.count)
    }
}

extension PDFValue {
    /// 递归收集间接引用（可达性遍历用）。
    func collectReferences(into queue: inout [PDFRef]) {
        switch self {
        case .reference(let ref):
            queue.append(ref)
        case .array(let items):
            for item in items { item.collectReferences(into: &queue) }
        case .dictionary(let dict):
            for (_, item) in dict { item.collectReferences(into: &queue) }
        case .stream(let stream):
            for (_, item) in stream.dictionary { item.collectReferences(into: &queue) }
        default:
            break
        }
    }
}
