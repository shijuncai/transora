import Foundation

/// TrueType（glyf 轮廓）字体读取与子集化。
///
/// 为什么只支持 glyf 不支持 CFF：
///     思源宋体官方只发 CFF 轮廓的 OTF 和可变字体 TTF。CFF 子集器要处理
///     INDEX / CharStrings / FDArray / FDSelect / subrs 闭包，约 2000 行且
///     一个 subr 处理错就整段字形错乱；glyf 子集器只要重建 loca/glyf/hmtx，
///     约 1000 行且错误立刻可见。所以离线把 VF 实例化成静态 TTF（见
///     Scripts/make-fonts.py），运行时只读 glyf。
///
/// 子集化的作用：
///     PDF 内嵌整份 14.85 MB 字体不现实。只保留实际画到的字形，
///     一份 300 页文档约 3000 个唯一字 → 约 1 MB。
///
/// 两个必须小心的点：
///     ① 复合字形（composite）引用其他字形的 GID。子集化会重新编号 GID，
///        所以复合字形的组件编号必须同步改写，否则字形会错位成别的字。
///     ② hmtx 的 lsb 不能随手写 0。部分光栅器依赖它做 hinting，写 0 会让
///        字形整体偏移。必须按原值搬运。
public struct TrueTypeFont {
    public enum Failure: Error, CustomStringConvertible {
        case notSFNT
        case cffOutline
        case missingTable(String)
        case badTable(String)

        public var description: String {
            switch self {
            case .notSFNT: return "不是 sfnt 字体（缺少 0x00010000 或 OTTO 版本号）"
            case .cffOutline: return "这是 CFF 轮廓字体，本实现只支持 glyf（PDF 侧走 CIDFontType2）"
            case .missingTable(let t): return "缺少必需表 \(t)"
            case .badTable(let t): return "表 \(t) 结构异常"
            }
        }
    }

    public let data: Data
    let bytes: [UInt8]
    /// 表标签 → (offset, length)
    let tables: [String: (offset: Int, length: Int)]

    public let unitsPerEm: Int
    public let numGlyphs: Int
    let indexToLocFormat: Int
    public let boundingBox: (xMin: Int, yMin: Int, xMax: Int, yMax: Int)
    public let ascent: Int
    public let descent: Int
    public let capHeight: Int
    public let italicAngle: Double
    public let postScriptName: String
    public let familyName: String
    public let weightClass: Int
    /// unicode 码位 → GID
    public let cmap: [UInt32: Int]

    let loca: [Int]
    let advanceWidths: [Int]
    let leftSideBearings: [Int]

    // MARK: - 解析

    public init(data: Data) throws {
        self.data = data
        self.bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw Failure.notSFNT }

        let version = Be.u32(bytes, 0)
        guard version == 0x0001_0000 || version == 0x7472_7565 else {
            if version == 0x4F54_544F { throw Failure.cffOutline }   // 'OTTO'
            throw Failure.notSFNT
        }
        let numTables = Int(Be.u16(bytes, 4))
        guard bytes.count >= 12 + numTables * 16 else { throw Failure.badTable("dir") }

        var map: [String: (offset: Int, length: Int)] = [:]
        for i in 0..<numTables {
            let base = 12 + i * 16
            let tag = String(decoding: bytes[base..<base + 4], as: UTF8.self)
            let offset = Int(Be.u32(bytes, base + 8))
            let length = Int(Be.u32(bytes, base + 12))
            guard offset >= 0, length >= 0, offset + length <= bytes.count else {
                throw Failure.badTable(tag)
            }
            map[tag] = (offset, length)
        }
        self.tables = map

        for required in ["head", "maxp", "hhea", "hmtx", "loca", "glyf", "cmap"] {
            if map[required] == nil {
                if required == "glyf", map["CFF "] != nil { throw Failure.cffOutline }
                throw Failure.missingTable(required)
            }
        }

        let head = map["head"]!.offset
        unitsPerEm = Int(Be.u16(bytes, head + 18))
        boundingBox = (
            Int(Be.i16(bytes, head + 36)), Int(Be.i16(bytes, head + 38)),
            Int(Be.i16(bytes, head + 40)), Int(Be.i16(bytes, head + 42))
        )
        indexToLocFormat = Int(Be.i16(bytes, head + 50))
        guard unitsPerEm > 0 else { throw Failure.badTable("head") }

        let maxp = map["maxp"]!.offset
        numGlyphs = Int(Be.u16(bytes, maxp + 4))
        guard numGlyphs > 0 else { throw Failure.badTable("maxp") }

        let hhea = map["hhea"]!.offset
        ascent = Int(Be.i16(bytes, hhea + 4))
        descent = Int(Be.i16(bytes, hhea + 6))
        let numberOfHMetrics = max(1, min(Int(Be.u16(bytes, hhea + 34)), numGlyphs))

        // hmtx：前 N 个字形是 (advance, lsb)，其后只有 lsb
        let hmtxRange = map["hmtx"]!
        var widths: [Int] = []
        var bearings: [Int] = []
        widths.reserveCapacity(numGlyphs)
        bearings.reserveCapacity(numGlyphs)
        for i in 0..<numGlyphs {
            if i < numberOfHMetrics {
                let offset = hmtxRange.offset + i * 4
                guard offset + 3 < hmtxRange.offset + hmtxRange.length else {
                    throw Failure.badTable("hmtx")
                }
                widths.append(Int(Be.u16(bytes, offset)))
                bearings.append(Int(Be.i16(bytes, offset + 2)))
            } else {
                let offset = hmtxRange.offset + numberOfHMetrics * 4 + (i - numberOfHMetrics) * 2
                guard offset + 1 < hmtxRange.offset + hmtxRange.length else {
                    throw Failure.badTable("hmtx")
                }
                widths.append(widths[numberOfHMetrics - 1])
                bearings.append(Int(Be.i16(bytes, offset)))
            }
        }
        advanceWidths = widths
        leftSideBearings = bearings

        // loca：short 格式存的是「实际偏移 / 2」
        let locaRange = map["loca"]!
        var offsets: [Int] = []
        offsets.reserveCapacity(numGlyphs + 1)
        if indexToLocFormat == 0 {
            guard locaRange.length >= (numGlyphs + 1) * 2 else { throw Failure.badTable("loca") }
            for i in 0...numGlyphs {
                offsets.append(Int(Be.u16(bytes, locaRange.offset + i * 2)) * 2)
            }
        } else {
            guard locaRange.length >= (numGlyphs + 1) * 4 else { throw Failure.badTable("loca") }
            for i in 0...numGlyphs {
                offsets.append(Int(Be.u32(bytes, locaRange.offset + i * 4)))
            }
        }
        for i in 1...numGlyphs where offsets[i] < offsets[i - 1] {
            throw Failure.badTable("loca")
        }
        loca = offsets

        cmap = try Self.parseCMap(bytes: bytes, table: map["cmap"]!)
        postScriptName = Self.readNameUTF16(bytes, map["name"], id: 6) ?? "Embedded"
        familyName = Self.readNameUTF16(bytes, map["name"], id: 1) ?? postScriptName

        if let os2 = map["OS/2"] {
            weightClass = Int(Be.u16(bytes, os2.offset + 4))
            let os2Version = Int(Be.u16(bytes, os2.offset))
            capHeight = os2Version >= 2 && os2.length >= 90
                ? Int(Be.i16(bytes, os2.offset + 88))
                : abs(ascent) * 7 / 10
        } else {
            weightClass = 400
            capHeight = abs(ascent) * 7 / 10
        }

        if let post = map["post"], post.length >= 8 {
            italicAngle = Double(Be.i32(bytes, post.offset + 4)) / 65536.0
        } else {
            italicAngle = 0
        }
    }

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    static func parseCMap(bytes: [UInt8], table: (offset: Int, length: Int)) throws -> [UInt32: Int] {
        let base = table.offset
        let count = Int(Be.u16(bytes, base + 2))
        var best: (score: Int, offset: Int)?
        for i in 0..<count {
            let rec = base + 4 + i * 8
            let platform = Int(Be.u16(bytes, rec))
            let encoding = Int(Be.u16(bytes, rec + 2))
            let offset = Int(Be.u32(bytes, rec + 4))
            let score: Int
            switch (platform, encoding) {
            case (3, 10): score = 5          // Windows / UCS-4：优先，覆盖全部平面
            case (0, 4), (0, 6): score = 4
            case (3, 1): score = 3           // Windows / BMP
            case (0, 3): score = 2
            default: score = 0
            }
            if score > 0 && (best == nil || score > best!.score) {
                best = (score, base + offset)
            }
        }
        guard let chosen = best else { throw Failure.badTable("cmap") }
        let sub = chosen.offset
        guard sub + 2 <= bytes.count else { throw Failure.badTable("cmap") }
        let format = Int(Be.u16(bytes, sub))

        var map: [UInt32: Int] = [:]
        switch format {
        case 4:
            let segCount = Int(Be.u16(bytes, sub + 6)) / 2
            let endBase = sub + 14
            let startBase = endBase + segCount * 2 + 2
            let deltaBase = startBase + segCount * 2
            let rangeBase = deltaBase + segCount * 2
            guard rangeBase + segCount * 2 <= bytes.count else { throw Failure.badTable("cmap4") }
            for i in 0..<segCount {
                let end = Int(Be.u16(bytes, endBase + i * 2))
                let start = Int(Be.u16(bytes, startBase + i * 2))
                let delta = Int(Be.i16(bytes, deltaBase + i * 2))
                let rangeOffset = Int(Be.u16(bytes, rangeBase + i * 2))
                if start > end { continue }
                for cp in start...end {
                    if cp == 0xFFFF { continue }
                    var gid: Int
                    if rangeOffset == 0 {
                        gid = (cp &+ delta) & 0xFFFF
                    } else {
                        let address = rangeBase + i * 2 + rangeOffset + (cp - start) * 2
                        guard address + 2 <= bytes.count else { continue }
                        let raw = Int(Be.u16(bytes, address))
                        gid = raw == 0 ? 0 : (raw &+ delta) & 0xFFFF
                    }
                    if gid != 0 { map[UInt32(cp)] = gid }
                }
            }
        case 12:
            let groups = Int(Be.u32(bytes, sub + 12))
            var p = sub + 16
            for _ in 0..<max(0, groups) {
                guard p + 12 <= bytes.count else { break }
                let start = Be.u32(bytes, p)
                let end = Be.u32(bytes, p + 4)
                let startGID = Int(Be.u32(bytes, p + 8))
                p += 12
                if end < start || end - start > 0x2_0000 { continue }   // 防御伪字体
                for cp in start...end { map[cp] = startGID + Int(cp - start) }
            }
        case 6:
            let first = Int(Be.u16(bytes, sub + 6))
            let entries = Int(Be.u16(bytes, sub + 8))
            for i in 0..<entries {
                let p = sub + 10 + i * 2
                guard p + 2 <= bytes.count else { break }
                let gid = Int(Be.u16(bytes, p))
                if gid != 0 { map[UInt32(first + i)] = gid }
            }
        default:
            throw Failure.badTable("cmap format \(format)")
        }
        return map
    }

    /// name 表按 UTF-16BE 取字符串。不能当 UTF-8 解——中文家族名会变成乱码。
    static func readNameUTF16(_ bytes: [UInt8], _ table: (offset: Int, length: Int)?, id: Int) -> String? {
        guard let table else { return nil }
        let base = table.offset
        guard base + 6 <= bytes.count else { return nil }
        let count = Int(Be.u16(bytes, base + 2))
        let storage = base + Int(Be.u16(bytes, base + 4))
        for i in 0..<count {
            let rec = base + 6 + i * 12
            guard rec + 12 <= bytes.count else { break }
            let platform = Int(Be.u16(bytes, rec))
            guard Int(Be.u16(bytes, rec + 6)) == id else { continue }
            let length = Int(Be.u16(bytes, rec + 8))
            let offset = Int(Be.u16(bytes, rec + 10))
            let start = storage + offset
            guard start + length <= bytes.count else { continue }
            if platform == 3 || platform == 0 {
                var units: [UInt16] = []
                var p = start
                while p + 1 < start + length {
                    units.append(Be.u16(bytes, p))
                    p += 2
                }
                return String(decoding: units, as: UTF16.self)
            }
            return String(decoding: bytes[start..<start + length], as: UTF8.self)
        }
        return nil
    }

    // MARK: - 查询

    public func glyphID(for scalar: UInt32) -> Int? { cmap[scalar] }

    /// 千分单位字宽（PDF 的 /W 用它）。
    public func width1000(gid: Int) -> Int {
        guard gid >= 0 && gid < advanceWidths.count else { return 0 }
        return Int((Double(advanceWidths[gid]) * 1000.0 / Double(unitsPerEm)).rounded())
    }

    public func glyphData(gid: Int) -> Data {
        guard gid >= 0 && gid < numGlyphs else { return Data() }
        let start = loca[gid]
        let end = loca[gid + 1]
        guard end > start else { return Data() }
        let base = tables["glyf"]!.offset
        guard base + end <= bytes.count else { return Data() }
        return Data(bytes[base + start..<base + end])
    }

    /// 复合字形直接引用的组件 GID（非复合返回空）。
    public func components(of gid: Int) -> [Int] {
        let glyph = [UInt8](glyphData(gid: gid))
        guard glyph.count >= 10, Be.i16(glyph, 0) < 0 else { return [] }
        var out: [Int] = []
        var p = 10
        var guardCount = 0
        while p + 4 <= glyph.count && guardCount < 64 {
            guardCount += 1
            let flags = Int(Be.u16(glyph, p))
            out.append(Int(Be.u16(glyph, p + 2)))
            p += 4
            p += (flags & 0x0001) != 0 ? 4 : 2
            if (flags & 0x0008) != 0 { p += 2 }
            else if (flags & 0x0040) != 0 { p += 4 }
            else if (flags & 0x0080) != 0 { p += 8 }
            if (flags & 0x0020) == 0 { break }
        }
        return out
    }

    // MARK: - 子集化

    public struct Subset {
        /// 子集字体字节（可直接作为 /FontFile2 的流内容）
        public var data: Data
        /// 旧 GID → 新 GID
        public var glyphMap: [Int: Int]
        /// 新 GID 的字宽（千分单位），下标即新 GID
        public var widths1000: [Int]
        public var glyphCount: Int
    }

    public func subset(glyphs requested: Set<Int>) throws -> Subset {
        var keep: Set<Int> = [0]
        var queue = Array(requested.filter { $0 > 0 && $0 < numGlyphs })
        keep.formUnion(queue)
        // 复合字形的组件必须递归到不动点
        var scanned = Set<Int>()
        while let gid = queue.popLast() {
            if scanned.contains(gid) { continue }
            scanned.insert(gid)
            for component in components(of: gid) where component > 0 && component < numGlyphs {
                if keep.insert(component).inserted { queue.append(component) }
            }
        }

        // 新编号：0 → 0，其余按旧 GID 升序（保证确定性，便于 golden 比对）
        let ordered = keep.sorted()
        var glyphMap: [Int: Int] = [:]
        for (newGID, oldGID) in ordered.enumerated() { glyphMap[oldGID] = newGID }
        let count = ordered.count

        var newGlyf = Data()
        var newLoca: [Int] = [0]
        var widths: [Int] = []
        var bearings: [Int] = []
        for oldGID in ordered {
            widths.append(width1000(gid: oldGID))
            bearings.append(leftSideBearings[oldGID])
            var body = [UInt8](glyphData(gid: oldGID))
            if body.count >= 10 && Be.i16(body, 0) < 0 {
                body = Self.remapComposite(body, map: glyphMap)
            }
            // 4 字节对齐：长格式 loca 允许任意偏移，但对齐后老阅读器更稳
            while body.count % 4 != 0 { body.append(0) }
            newGlyf.append(contentsOf: body)
            newLoca.append(newGlyf.count)
        }

        // 子集内实际用到的码位（原 cmap 反查）
        var usedCodepoints: [(UInt32, UInt16)] = []
        for (codepoint, oldGID) in cmap {
            if let newGID = glyphMap[oldGID], newGID <= 0xFFFF {
                usedCodepoints.append((codepoint, UInt16(newGID)))
            }
        }
        usedCodepoints.sort { $0.0 < $1.0 }

        var records: [(tag: String, data: Data)] = []
        records.append(("head", buildHead()))
        records.append(("hhea", buildHhea(numberOfHMetrics: count)))

        var hmtx = Data()
        for i in 0..<count {
            hmtx.append(contentsOf: Be.bytes16(UInt16(clamping: advanceWidths[ordered[i]])))
            hmtx.append(contentsOf: Be.bytes16(UInt16(bitPattern: Int16(clamping: bearings[i]))))
        }
        records.append(("hmtx", hmtx))
        records.append(("maxp", buildMaxp(numGlyphs: count)))
        records.append(("loca", {
            var d = Data()
            for offset in newLoca { d.append(contentsOf: Be.bytes32(UInt32(offset))) }
            return d
        }()))
        records.append(("glyf", newGlyf))
        records.append(("cmap", Self.buildCMap(usedCodepoints)))
        records.append(("post", buildPost()))
        if let name = buildName() { records.append(("name", name)) }
        if let os2 = buildOS2(usedCodepoints) { records.append(("OS/2", os2)) }

        return Subset(data: Self.assemble(records), glyphMap: glyphMap,
                      widths1000: widths, glyphCount: count)
    }

    /// 复合字形重编号：只改 glyphIndex 字段，flags/变换矩阵原样保留。
    ///
    /// 这一步是子集化的隐性雷区：漏改会导致字形显示成别的字，而且只在
    /// 含复合字形的字符上暴露，肉眼查不出来。公开出来是为了能单独测。
    public static func remapComposite(_ body: [UInt8], map: [Int: Int]) -> [UInt8] {
        var body = body
        var p = 10
        var guardCount = 0
        while p + 4 <= body.count && guardCount < 64 {
            guardCount += 1
            let flags = Int(Be.u16(body, p))
            let oldComponent = Int(Be.u16(body, p + 2))
            if let newComponent = map[oldComponent], newComponent <= 0xFFFF {
                body[p + 2] = UInt8((newComponent >> 8) & 0xFF)
                body[p + 3] = UInt8(newComponent & 0xFF)
            }
            p += 4
            p += (flags & 0x0001) != 0 ? 4 : 2
            if (flags & 0x0008) != 0 { p += 2 }
            else if (flags & 0x0040) != 0 { p += 4 }
            else if (flags & 0x0080) != 0 { p += 8 }
            if (flags & 0x0020) == 0 { break }
        }
        return body
    }

    func tableSlice(_ tag: String) -> Data? {
        guard let range = tables[tag] else { return nil }
        return Data(bytes[range.offset..<range.offset + range.length])
    }

    func buildHead() -> Data {
        var d = [UInt8](tableSlice("head") ?? Data(repeating: 0, count: 54))
        while d.count < 54 { d.append(0) }
        d.write32(at: 8, 0)     // checkSumAdjustment 由 assemble 统一回填
        d.write16(at: 50, 1)    // indexToLocFormat = long（简化实现，且不受 128KB 限制）
        d.write16(at: 52, 0)    // glyphDataFormat
        return Data(d)
    }

    func buildHhea(numberOfHMetrics: Int) -> Data {
        var d = [UInt8](tableSlice("hhea") ?? Data(repeating: 0, count: 36))
        while d.count < 36 { d.append(0) }
        d.write16(at: 34, UInt16(numberOfHMetrics))
        return Data(d)
    }

    func buildMaxp(numGlyphs: Int) -> Data {
        var d = [UInt8](tableSlice("maxp") ?? Data(repeating: 0, count: 32))
        while d.count < 32 { d.append(0) }
        // maxPoints/maxContours 等保持原值：它们是「上界」，子集只会更小，声明偏大合法
        d.write16(at: 4, UInt16(numGlyphs))
        return Data(d)
    }

    /// post 降级到 format 3.0：没有字形名，32 字节，最省体积。
    func buildPost() -> Data {
        var d = Data()
        d.append(contentsOf: Be.bytes32(0x0003_0000))
        d.append(contentsOf: Be.bytes32(UInt32(bitPattern: Int32(italicAngle * 65536))))
        d.append(contentsOf: Be.bytes16(UInt16(bitPattern: Int16(-100))))   // underlinePosition
        d.append(contentsOf: Be.bytes16(100))                               // underlineThickness
        d.append(contentsOf: Be.bytes32(0))                                 // isFixedPitch
        for _ in 0..<4 { d.append(contentsOf: Be.bytes32(0)) }
        return d
    }

    func buildName() -> Data? {
        guard let table = tables["name"] else { return nil }
        let base = table.offset
        let count = Int(Be.u16(bytes, base + 2))
        let storage = base + Int(Be.u16(bytes, base + 4))
        // 版权(0)、许可(13/14) 必须保留 —— OFL 要求声明随字体走
        let keepIDs: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 13, 14]
        var records: [(platform: Int, encoding: Int, language: Int, id: Int, data: Data)] = []
        for i in 0..<count {
            let rec = base + 6 + i * 12
            guard rec + 12 <= bytes.count else { break }
            let platform = Int(Be.u16(bytes, rec))
            let nameID = Int(Be.u16(bytes, rec + 6))
            guard keepIDs.contains(nameID) else { continue }
            let length = Int(Be.u16(bytes, rec + 8))
            let offset = Int(Be.u16(bytes, rec + 10))
            let start = storage + offset
            guard start + length <= bytes.count else { continue }
            records.append((platform, Int(Be.u16(bytes, rec + 2)), Int(Be.u16(bytes, rec + 4)),
                            nameID, Data(bytes[start..<start + length])))
        }
        guard !records.isEmpty else { return nil }

        var d = Data()
        d.append(contentsOf: Be.bytes16(0))
        d.append(contentsOf: Be.bytes16(UInt16(records.count)))
        d.append(contentsOf: Be.bytes16(UInt16(6 + records.count * 12)))
        var storageData = Data()
        for r in records {
            d.append(contentsOf: Be.bytes16(UInt16(r.platform)))
            d.append(contentsOf: Be.bytes16(UInt16(r.encoding)))
            d.append(contentsOf: Be.bytes16(UInt16(r.language)))
            d.append(contentsOf: Be.bytes16(UInt16(r.id)))
            d.append(contentsOf: Be.bytes16(UInt16(r.data.count)))
            d.append(contentsOf: Be.bytes16(UInt16(storageData.count)))
            storageData.append(r.data)
        }
        d.append(storageData)
        return d
    }

    func buildOS2(_ used: [(UInt32, UInt16)]) -> Data? {
        guard let slice = tableSlice("OS/2") else { return nil }
        var d = [UInt8](slice)
        if d.count >= 68 {
            let first = used.first?.0 ?? 0x20
            let last = used.last?.0 ?? 0xFFFF
            d.write16(at: 64, UInt16(clamping: first))
            d.write16(at: 66, UInt16(clamping: min(last, 0xFFFF)))
        }
        return Data(d)
    }

    /// 只保留实际用到的码位；format 4（BMP）与 format 12（全平面）双写。
    /// PDF 的 Identity-H 不查 cmap，但外部工具（fc-query、字体校验器）会查。
    static func buildCMap(_ entries: [(UInt32, UInt16)]) -> Data {
        let bmp = entries.filter { $0.0 <= 0xFFFF }
        let sub4 = cmapFormat4(bmp)
        let sub12 = cmapFormat12(entries)

        var d = Data()
        d.append(contentsOf: Be.bytes16(0))          // version
        d.append(contentsOf: Be.bytes16(2))          // numTables
        d.append(contentsOf: Be.bytes16(3))          // platform Windows
        d.append(contentsOf: Be.bytes16(1))          // encoding BMP
        d.append(contentsOf: Be.bytes32(4 + 8 * 2))
        d.append(contentsOf: Be.bytes16(3))
        d.append(contentsOf: Be.bytes16(10))         // encoding UCS-4
        d.append(contentsOf: Be.bytes32(UInt32(4 + 8 * 2 + sub4.count)))
        d.append(sub4)
        d.append(sub12)
        return d
    }

    static func cmapFormat4(_ entries: [(UInt32, UInt16)]) -> Data {
        // 码位和 GID 同时连续才合并成一段：idDelta 段映射要求「GID − 码位」为常数，
        // 只合并连续段才不会把缺失的码位指到别的字形上。
        // delta 存 0…65535 的无符号值，**不要用 Int16 相加**：
        // idDelta 是模 65536 的加法，Int16 一加就会在边界（码位 0xFFxx）溢出崩溃。
        var segments: [(start: Int, end: Int, delta: Int)] = []
        for (codepoint, gid) in entries {
            let cp = Int(codepoint)
            if var last = segments.last, last.end + 1 == cp,
               (last.delta + last.end + 1) & 0xFFFF == Int(gid) {
                last.end = cp
                segments[segments.count - 1] = last
            } else {
                segments.append((cp, cp, (Int(gid) - cp) & 0xFFFF))
            }
        }
        segments.append((0xFFFF, 0xFFFF, 1))   // 规范要求的结尾段

        let segCount = segments.count
        var d = Data()
        d.append(contentsOf: Be.bytes16(4))
        d.append(contentsOf: Be.bytes16(UInt16(16 + segCount * 8)))
        d.append(contentsOf: Be.bytes16(0))              // language
        d.append(contentsOf: Be.bytes16(UInt16(segCount * 2)))
        var pow2 = 1
        var log2 = 0
        while pow2 * 2 <= segCount { pow2 *= 2; log2 += 1 }
        d.append(contentsOf: Be.bytes16(UInt16(pow2 * 2)))                 // searchRange
        d.append(contentsOf: Be.bytes16(UInt16(log2)))                     // entrySelector
        d.append(contentsOf: Be.bytes16(UInt16(segCount * 2 - pow2 * 2)))  // rangeShift
        for s in segments { d.append(contentsOf: Be.bytes16(UInt16(s.end))) }
        d.append(contentsOf: Be.bytes16(0))              // reservedPad
        for s in segments { d.append(contentsOf: Be.bytes16(UInt16(s.start))) }
        for s in segments { d.append(contentsOf: Be.bytes16(UInt16(s.delta & 0xFFFF))) }
        for _ in segments { d.append(contentsOf: Be.bytes16(0)) }
        return d
    }

    static func cmapFormat12(_ entries: [(UInt32, UInt16)]) -> Data {
        var groups: [(start: UInt32, end: UInt32, startGID: UInt32)] = []
        for (codepoint, gid) in entries {
            if var last = groups.last, last.end + 1 == codepoint,
               last.startGID + (last.end - last.start) + 1 == UInt32(gid) {
                last.end = codepoint
                groups[groups.count - 1] = last
            } else {
                groups.append((codepoint, codepoint, UInt32(gid)))
            }
        }
        var d = Data()
        d.append(contentsOf: Be.bytes16(12))
        d.append(contentsOf: Be.bytes16(0))
        d.append(contentsOf: Be.bytes32(UInt32(16 + groups.count * 12)))
        d.append(contentsOf: Be.bytes32(0))
        d.append(contentsOf: Be.bytes32(UInt32(groups.count)))
        for g in groups {
            d.append(contentsOf: Be.bytes32(g.start))
            d.append(contentsOf: Be.bytes32(g.end))
            d.append(contentsOf: Be.bytes32(g.startGID))
        }
        return d
    }

    /// 组装 sfnt：表目录 + 4 字节对齐的表体 + checkSumAdjustment 回填。
    static func assemble(_ records: [(tag: String, data: Data)]) -> Data {
        let sorted = records.sorted { $0.tag < $1.tag }
        let count = sorted.count
        var out = Data()
        out.append(contentsOf: Be.bytes32(0x0001_0000))
        out.append(contentsOf: Be.bytes16(UInt16(count)))
        var pow2 = 1
        var log2 = 0
        while pow2 * 2 <= count { pow2 *= 2; log2 += 1 }
        out.append(contentsOf: Be.bytes16(UInt16(pow2 * 16)))
        out.append(contentsOf: Be.bytes16(UInt16(log2)))
        out.append(contentsOf: Be.bytes16(UInt16(count * 16 - pow2 * 16)))

        let bodyStart = 12 + count * 16
        var body = Data()
        var headOffset = -1
        for record in sorted {
            let offset = bodyStart + body.count
            var payload = record.data
            if record.tag == "head" { headOffset = offset }
            out.append(contentsOf: Array(record.tag.utf8))
            out.append(contentsOf: Be.bytes32(checksum(payload)))
            out.append(contentsOf: Be.bytes32(UInt32(offset)))
            out.append(contentsOf: Be.bytes32(UInt32(payload.count)))
            let padding = (4 - payload.count % 4) % 4
            if padding > 0 { payload.append(contentsOf: [UInt8](repeating: 0, count: padding)) }
            body.append(payload)
        }
        out.append(body)

        // head 目录里的校验和必须按 adjustment=0 计算（规范要求），
        // 之后再把 adjustment 写进 head 表体。
        if headOffset >= 0 {
            var bytes = [UInt8](out)
            bytes.write32(at: headOffset + 8, 0)
            let sum = checksum(Data(bytes))
            bytes.write32(at: headOffset + 8, 0xB1B0_AFBA &- sum)
            return Data(bytes)
        }
        return out
    }

    static func checksum(_ data: Data) -> UInt32 {
        let bytes = [UInt8](data)
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let b0 = UInt32(bytes[i])
            let b1 = i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0
            let b2 = i + 2 < bytes.count ? UInt32(bytes[i + 2]) : 0
            let b3 = i + 3 < bytes.count ? UInt32(bytes[i + 3]) : 0
            sum = sum &+ (b0 << 24 | b1 << 16 | b2 << 8 | b3)
            i += 4
        }
        return sum
    }
}

// MARK: - 大端读写

enum Be {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        guard o >= 0, o + 1 < b.count else { return 0 }
        return UInt16(b[o]) << 8 | UInt16(b[o + 1])
    }

    static func i16(_ b: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: u16(b, o)) }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 3 < b.count else { return 0 }
        return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16
             | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    static func i32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32(b, o)) }

    static func bytes16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func bytes32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}

extension Array where Element == UInt8 {
    mutating func write16(at offset: Int, _ value: UInt16) {
        guard offset >= 0, offset + 1 < count else { return }
        self[offset] = UInt8((value >> 8) & 0xFF)
        self[offset + 1] = UInt8(value & 0xFF)
    }

    mutating func write32(at offset: Int, _ value: UInt32) {
        guard offset >= 0, offset + 3 < count else { return }
        self[offset] = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}
