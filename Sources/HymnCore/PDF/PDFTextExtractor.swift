import Foundation

/// 内容流解释器：把「算子序列」执行成「页面上的文本位置 + 矢量线段」。
///
/// 与 P0 的 `PDFContentStream.tokenize` 的区别：
///     tokenize 只切分、不执行，用来整页删文字；
///     这里要真的跑一遍图形状态机（CTM、文本矩阵、字体、字距），
///     才能知道每个字落在页面的哪个坐标——这是版式重建的前提。
///
/// 三个容易做错的地方：
/// ① `q/Q` 保存的是**图形状态**，`Tc/Tw/Tz/TL/Tf/Tr/Ts` 属于图形状态，`Tm/Tlm` 不属于
///    （它们归 BT/ET 管），所以 `q/Q` 要存前者、BT 要重置后者；
/// ② 字宽推进是 `(w/1000 · 字号 + 字符间距) · 水平缩放`，`TJ` 里的数字是
///    **千分之一 em 的字距调整**，符号是负的（正数表示后退）；
/// ③ `wordSpacing` 只对**单字节码 32** 生效，Identity-H 的双字节码永远不加。
public enum PDFTextExtractor {
    /// `HYMN_TRACE_TEXT=1` 时把每个文本 run 打到 stderr（排查「文字读不出来」）
    static let traceText = ProcessInfo.processInfo.environment["HYMN_TRACE_TEXT"] != nil
    /// `HYMN_TRACE_OPS=1` 时把每个算子打到 stderr（排查「算子被跳过」）
    static let traceOps = ProcessInfo.processInfo.environment["HYMN_TRACE_OPS"] != nil

    public struct Options: Sendable {
        /// 是否收录 `Tr 3` 这类不可见文本（OCR 文字层就是不可见的，但那是真实的原文）
        public var includeInvisible = true
        /// 递归 Form XObject 的最大深度
        public var maxFormDepth = 8
        /// 是否收集矢量线段（表格网格要用）
        public var collectPaths = true

        public init() {}
    }

    public struct PageContent: Sendable {
        public var pageIndex: Int
        public var runs: [PDFTextRun] = []
        public var segments: [PDFPathSegment] = []
        /// 每条被描边/填充路径的包围盒（含点数和是否填充）。
        ///
        /// `segments` 只为表格网格服务，会把斜线、曲线全部滤掉；图表正好全是斜线和曲线，
        /// 所以另存一份「笔触落在哪」的原始外包框，供 `PDFChartDetector` 判图表区域。
        public var paintedPaths: [PDFPaintedPath] = []
        public var images: [PDFImagePlacement] = []
        public var formCount = 0
        public var inlineImageCount = 0
        /// 字体层面的问题（缺 ToUnicode、缺字宽、Type3 等），逐条去重
        public var warnings: [String] = []
        public var unmappedGlyphs = 0
        /// 有字节但一个字形都解不出来的文本算子数。
        ///
        /// 这类算子最危险：内容流里确实有文字，但字体/CMap 我们读不出来，
        /// 于是既没有 run、也不会被重画——一旦驱逐就是**静默丢字**。
        /// P4 的 R1 在真实文档（幻灯片里的思维导图标签）上就是这样抓到它的。
        public var unreadableTextOps = 0
        /// 各内容流在「按顺序拼接后」的起始字节偏移。
        /// 引擎驱逐时把多个流拼成一个 Data，这里的偏移必须与它一致，
        /// 否则 `sourceRange` 会整体错位（错位就会误删别人的文本）。
        public var streamBases: [Int] = []
    }

    public static func extract(
        document: PDFDocument,
        pageIndex: Int,
        page: [String: PDFValue],
        options: Options = Options()
    ) -> PageContent {
        var content = PageContent(pageIndex: pageIndex)
        let resources = document.resolvedResources(page["Resources"])
        let cache = FontCache(document: document)

        let interpreter = Interpreter(
            document: document, options: options, cache: cache,
            pageIndex: pageIndex, content: &content)
        // 页面内容流可能是数组：PDF 语义上这**不是**「多条独立的流」，
        // 而是把它们用空白连起来当成**一条**逻辑流执行。
        //
        // 这一点在此文档上是致命的：Elsevier 的生成器会把语句切在算子与操作数之间，
        // 例如流 A 以 `[(Centre)...(India)]` 结尾、流 B 以 ` TJ` 开头。
        // 逐流各跑一遍解释器，流 A 末尾累积的数组在流 B 里就没了——
        // 于是整行作者单位**一个字都读不出来**（页面渲染正常，提取文本却缺行）。
        //
        // 拼接规则必须与 `PDFTypesetEngine` 完全一致（不足换行补一个 \n），
        // 这样 `sourceRange`（整页口径的算子字节区间）才能直接用于整页驱逐。
        var merged = Data()
        var base = 0
        for ref in document.contentRefs(of: page) {
            guard let stream = (try? document.resolve(ref))?.streamValue,
                  let decoded = try? PDFFilters.decode(stream.raw, dictionary: stream.dictionary)
            else { continue }
            content.streamBases.append(base)
            merged.append(decoded)
            base += decoded.count
            if let last = decoded.last, last != 0x0A, last != 0x0D {
                merged.append(0x0A)
                base += 1
            }
        }
        if content.streamBases.isEmpty,
           let inline = page["Contents"]?.streamValue,
           let decoded = try? PDFFilters.decode(inline.raw, dictionary: inline.dictionary) {
            merged = decoded
        }
        if !merged.isEmpty {
            interpreter.streamBase = 0
            interpreter.run(data: merged, resources: resources, depth: 0, formStack: [])
        }
        content = interpreter.content
        content.warnings = Array(Set(content.warnings)).sorted()
        return content
    }

    // MARK: - 解释器

    struct GState {
        var ctm: PDFMatrix
        var font: PDFFont?
        var fontSize: Double
        var charSpacing: Double
        var wordSpacing: Double
        var horizontalScale: Double   // 已是倍数（Tz / 100）
        var leading: Double
        var rise: Double
        var renderMode: Int
        var lineWidth: Double

        static var initial: GState {
            GState(ctm: .identity, font: nil, fontSize: 0, charSpacing: 0,
                   wordSpacing: 0, horizontalScale: 1, leading: 0, rise: 0,
                   renderMode: 0, lineWidth: 1)
        }
    }

    final class Interpreter {
        /// 当前内容流在整页拼接口径下的起点
        var streamBase = 0
        /// 当前算子的字节区间（整页口径），供 run 记录来源
        var currentOpRange: Range<Int>?

        let document: PDFDocument
        let options: Options
        let cache: FontCache
        let pageIndex: Int
        var content: PageContent

        var state = GState.initial
        var stack: [GState] = []
        /// 文本矩阵 Tm 与文本行矩阵 Tlm（BT 重置，不属于图形状态）
        var textMatrix = PDFMatrix.identity
        var lineMatrix = PDFMatrix.identity
        var pendingPath: [(start: PDFPoint, end: PDFPoint)] = []
        var currentPoint = PDFPoint.zero
        var subpathStart = PDFPoint.zero

        init(document: PDFDocument, options: Options, cache: FontCache,
             pageIndex: Int, content: inout PageContent) {
            self.document = document
            self.options = options
            self.cache = cache
            self.pageIndex = pageIndex
            self.content = content
        }

        func run(data: Data, resources: [String: PDFValue], depth: Int, formStack: Set<Int>) {
            guard depth <= options.maxFormDepth else {
                content.warnings.append("Form 嵌套超过 \(options.maxFormDepth) 层，已停止递归")
                return
            }
            // 进入新的流就把来源区间清掉：Form 里的 run 不该继承父流的区间
            currentOpRange = nil
            let bytes = [UInt8](data)
            if PDFTextExtractor.traceOps {
                FileHandle.standardError.write(
                    Data("RUN bytes=\(bytes.count) depth=\(depth)\n".utf8))
            }
            var parser = PDFParser(bytes)
            var operands: [PDFValue] = []

            while true {
                parser.skipWhiteAndComments()
                guard parser.index < bytes.count else { break }
                let b = bytes[parser.index]

                // 单字符算子 ' 与 "
                if b == 0x27 || b == 0x22 {
                    let charStart = parser.index
                    parser.index += 1
                    currentOpRange = depth == 0
                        ? (streamBase + charStart)..<(streamBase + parser.index) : nil
                    execute(String(UnicodeScalar(b)), operands: operands,
                            resources: resources, depth: depth, formStack: formStack)
                    operands.removeAll(keepingCapacity: true)
                    continue
                }

                let isOperandStart = b == 0x2F || b == 0x28 || b == 0x3C || b == 0x5B
                    || b == 0x2B || b == 0x2D || b == 0x2E || (b >= 0x30 && b <= 0x39)
                if isOperandStart {
                    do {
                        operands.append(try parser.parseValue(allowReferences: false))
                    } catch {
                        if PDFTextExtractor.traceOps {
                            FileHandle.standardError.write(Data(
                                "PARSE_ERR base=\(streamBase) @\(parser.index) \(error)\n".utf8))
                        }
                        parser.index += 1
                    }
                    continue
                }

                let opStart = parser.index
                while parser.index < bytes.count && PDFParser.isRegular(bytes[parser.index]) {
                    parser.index += 1
                }
                if parser.index == opStart {
                    parser.index += 1
                    continue
                }
                let op = String(decoding: bytes[opStart..<parser.index], as: UTF8.self)
                if PDFTextExtractor.traceOps {
                    FileHandle.standardError.write(
                        Data("OP base=\(streamBase) @\(opStart) \(op) n=\(operands.count)\n".utf8))
                }

                if op == "BI" {
                    // 内联图像：ID 之后是二进制，整体跳过
                    parser.index = PDFContentStream.skipInlineImageData(
                        bytes: bytes, from: parser.index)
                    content.inlineImageCount += 1
                    operands.removeAll(keepingCapacity: true)
                    continue
                }
                if op == "true" || op == "false" || op == "null" {
                    operands.append(op == "null" ? .null : .bool(op == "true"))
                    continue
                }

                // 记录算子自身的字节区间（不含操作数）：驱逐时按这个区间判断「该不该删」。
                // Form XObject 里的算子不记 —— 它们不在整页内容流里，
                // 而且表单是整份深拷贝处理的，逐算子区间没有意义。
                currentOpRange = depth == 0
                    ? (streamBase + opStart)..<(streamBase + parser.index) : nil
                execute(op, operands: operands, resources: resources,
                        depth: depth, formStack: formStack)
                operands.removeAll(keepingCapacity: true)
            }
            flushPath(stroke: false, fill: false)
        }

        // MARK: 算子分发

        func execute(_ op: String, operands: [PDFValue], resources: [String: PDFValue],
                     depth: Int, formStack: Set<Int>) {
            switch op {
            case "q":
                stack.append(state)
            case "Q":
                if let previous = stack.popLast() { state = previous }
            case "cm":
                if let matrix = PDFMatrix(array: operands.suffix(6).map { $0 }) {
                    state.ctm = matrix * state.ctm
                }

            // 文本对象
            case "BT":
                textMatrix = .identity
                lineMatrix = .identity
            case "ET":
                break

            case "Tf":
                if operands.count >= 2, let name = operands[operands.count - 2].nameValue {
                    state.fontSize = operands[operands.count - 1].doubleValue ?? 0
                    state.font = cache.font(named: name, resources: resources)
                    if state.font == nil {
                        content.warnings.append("字体资源缺失 /\(name)")
                    } else if let font = state.font, font.toUnicode == nil {
                        content.warnings.append("字体 \(font.baseFont) 无 /ToUnicode，文本可能取不到 unicode")
                    } else if let font = state.font, !font.hasRealWidths {
                        content.warnings.append("字体 \(font.baseFont) 无字宽表，宽度为估算值")
                    }
                }
            case "Tc":
                state.charSpacing = operands.last?.doubleValue ?? 0
            case "Tw":
                state.wordSpacing = operands.last?.doubleValue ?? 0
            case "Tz":
                state.horizontalScale = (operands.last?.doubleValue ?? 100) / 100
            case "TL":
                state.leading = operands.last?.doubleValue ?? 0
            case "Ts":
                state.rise = operands.last?.doubleValue ?? 0
            case "Tr":
                state.renderMode = operands.last?.intValue ?? 0

            // 文本定位
            case "Td":
                let tx = operands.count >= 2 ? (operands[operands.count - 2].doubleValue ?? 0) : 0
                let ty = operands.count >= 1 ? (operands[operands.count - 1].doubleValue ?? 0) : 0
                lineMatrix = PDFMatrix.translation(tx, ty) * lineMatrix
                textMatrix = lineMatrix
            case "TD":
                let tx = operands.count >= 2 ? (operands[operands.count - 2].doubleValue ?? 0) : 0
                let ty = operands.count >= 1 ? (operands[operands.count - 1].doubleValue ?? 0) : 0
                state.leading = -ty
                lineMatrix = PDFMatrix.translation(tx, ty) * lineMatrix
                textMatrix = lineMatrix
            case "Tm":
                if let matrix = PDFMatrix(array: operands.suffix(6).map { $0 }) {
                    textMatrix = matrix
                    lineMatrix = matrix
                }
            case "T*":
                lineMatrix = PDFMatrix.translation(0, -state.leading) * lineMatrix
                textMatrix = lineMatrix

            // 显示文本
            case "Tj":
                if let string = operands.last, case .string(let data) = string {
                    showText(data)
                }
            case "TJ":
                if let array = operands.last?.arrayValue { showArray(array) }
            case "'":
                lineMatrix = PDFMatrix.translation(0, -state.leading) * lineMatrix
                textMatrix = lineMatrix
                if let string = operands.last, case .string(let data) = string {
                    showText(data)
                }
            case "\"":
                if operands.count >= 3 {
                    state.wordSpacing = operands[operands.count - 3].doubleValue ?? 0
                    state.charSpacing = operands[operands.count - 2].doubleValue ?? 0
                }
                lineMatrix = PDFMatrix.translation(0, -state.leading) * lineMatrix
                textMatrix = lineMatrix
                if let string = operands.last, case .string(let data) = string {
                    showText(data)
                }

            // 路径
            case "w":
                state.lineWidth = operands.last?.doubleValue ?? 1
            case "re":
                if operands.count >= 4 {
                    let x = operands[operands.count - 4].doubleValue ?? 0
                    let y = operands[operands.count - 3].doubleValue ?? 0
                    let w = operands[operands.count - 2].doubleValue ?? 0
                    let h = operands[operands.count - 1].doubleValue ?? 0
                    let p0 = state.ctm.applied(to: PDFPoint(x, y))
                    let p1 = state.ctm.applied(to: PDFPoint(x + w, y + h))
                    // 细长矩形在表格里就是「一条线」（Word 导出常见）
                    let rect = PDFRect(x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y)
                    if options.collectPaths {
                        if rect.width <= 3 && rect.height > 3 {
                            recordSegment(PDFPoint(rect.x0, rect.y0), PDFPoint(rect.x1, rect.y1), rect.width)
                        } else if rect.height <= 3 && rect.width > 3 {
                            recordSegment(PDFPoint(rect.x0, rect.y0), PDFPoint(rect.x1, rect.y1), rect.height)
                        } else if rect.width <= 3 && rect.height <= 3 {
                            // 连字符级别的点，忽略
                        }
                    }
                    // 柱状图的每根柱子就是一个 `re`：宽高都超过 3 的矩形不是表格线，
                    // 但对图表识别是有效笔触，单独记一条。
                    if options.collectPaths && rect.width > 3 && rect.height > 3 {
                        content.paintedPaths.append(
                            PDFPaintedPath(box: rect, points: 4, filled: true))
                    }
                    currentPoint = PDFPoint(x, y)
                    subpathStart = currentPoint
                }
            case "m":
                if operands.count >= 2 {
                    currentPoint = PDFPoint(operands[operands.count - 2].doubleValue ?? 0,
                                            operands[operands.count - 1].doubleValue ?? 0)
                    subpathStart = currentPoint
                }
            case "l":
                if operands.count >= 2 {
                    let next = PDFPoint(operands[operands.count - 2].doubleValue ?? 0,
                                        operands[operands.count - 1].doubleValue ?? 0)
                    pendingPath.append((currentPoint, next))
                    currentPoint = next
                }
            case "c", "v", "y":
                if operands.count >= 2 {
                    let last = PDFPoint(operands[operands.count - 2].doubleValue ?? 0,
                                        operands[operands.count - 1].doubleValue ?? 0)
                    // 曲线按弦近似：表格框线几乎都是直线，曲线出现说明不是网格
                    pendingPath.append((currentPoint, last))
                    currentPoint = last
                }
            case "h":
                pendingPath.append((currentPoint, subpathStart))
                currentPoint = subpathStart

            case "S", "s":
                flushPath(stroke: true, fill: false, closeFirst: op == "s")
            case "f", "F", "f*":
                flushPath(stroke: false, fill: true)
            case "B", "B*", "b", "b*":
                flushPath(stroke: true, fill: true, closeFirst: op.hasPrefix("b"))

            // 外部对象
            case "Do":
                if let name = operands.last?.nameValue {
                    drawXObject(name: name, resources: resources,
                                depth: depth, formStack: formStack)
                }

            // 其余（gs、BDC、EMC、W、W*、ri、d、J、j、M、sh…）不影响文本与网格
            default:
                break
            }
        }

        func recordSegment(_ a: PDFPoint, _ b: PDFPoint, _ thickness: Double) {
            content.segments.append(PDFPathSegment(start: a, end: b, thickness: thickness))
        }

        func flushPath(stroke: Bool, fill: Bool, closeFirst: Bool = false) {
            defer { pendingPath.removeAll(keepingCapacity: true) }
            guard options.collectPaths, stroke || fill else { return }
            // 图表识别：整条路径（不论横竖斜、描边还是填充）的包围盒。
            // 折线图一条曲线就是一个 path，点数很多但只有 1 个框，
            // 所以点数也要一起记，判断时用「点数或路径数」二选一。
            if !pendingPath.isEmpty {
                var points: [PDFPoint] = []
                points.reserveCapacity(pendingPath.count * 2)
                for segment in pendingPath {
                    points.append(state.ctm.applied(to: segment.start))
                    points.append(state.ctm.applied(to: segment.end))
                }
                let bbox = PDFRect(points)
                if bbox.width >= 1 || bbox.height >= 1 {
                    content.paintedPaths.append(PDFPaintedPath(
                        box: bbox, points: pendingPath.count * 2, filled: fill))
                }
            }
            for segment in pendingPath {
                let a = state.ctm.applied(to: segment.start)
                let b = state.ctm.applied(to: segment.end)
                // 只保留近似水平/垂直的线：斜线（图表、装饰）对表格网格没有帮助，
                // 留着只会把「段落里的斜体字下划线」误判成表格边
                let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
                if dy <= 1.0 && dx > 2 {
                    recordSegment(PDFPoint(min(a.x, b.x), (a.y + b.y) / 2),
                                  PDFPoint(max(a.x, b.x), (a.y + b.y) / 2), state.lineWidth)
                } else if dx <= 1.0 && dy > 2 {
                    recordSegment(PDFPoint((a.x + b.x) / 2, min(a.y, b.y)),
                                  PDFPoint((a.x + b.x) / 2, max(a.y, b.y)), state.lineWidth)
                }
            }
        }

        // MARK: 文本

        func showArray(_ array: [PDFValue]) {
            for item in array {
                if case .string(let data) = item {
                    showText(data)
                } else if let adjust = item.doubleValue {
                    // TJ 的数字：千分之一 em 的字距调整，正数表示后退
                    let shift = -adjust / 1000 * state.fontSize * state.horizontalScale
                    textMatrix = PDFMatrix.translation(shift, 0) * textMatrix
                }
            }
        }

        func showText(_ data: Data) {
            guard let font = state.font, state.fontSize != 0 else {
                if !data.isEmpty { content.unreadableTextOps += 1 }
                return
            }
            if state.renderMode == 3 && !options.includeInvisible { return }

            let glyphs = font.glyphs(from: data)
            guard !glyphs.isEmpty else {
                if !data.isEmpty { content.unreadableTextOps += 1 }
                return
            }

            let size = state.fontSize
            let scale = state.horizontalScale
            let ascent = font.ascent * size / 1000
            let descent = font.descent * size / 1000

            var text = ""
            var unmapped = 0
            // 文本空间里的包围盒（随后一次变换到页面空间）
            var minX = Double.infinity
            var maxX = -Double.infinity
            var minY = Double.infinity
            var maxY = -Double.infinity
            var cursor = 0.0

            for glyph in glyphs {
                let glyphWidth = glyph.width / 1000 * size * scale
                if minX.isInfinite { minX = cursor }
                maxX = cursor + glyphWidth
                minY = min(minY, state.rise + descent)
                maxY = max(maxY, state.rise + ascent)

                if let unicode = glyph.unicode {
                    // 有些 /ToUnicode 会把软换行映射成 U+000A 这类控制字符。
                    // 原样带进 IL，排版时就会被当成一个「字形」去画，
                    // 思源宋体当然没有这个字形——报告里会多出一条假缺字。
                    if unicode.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                        text += " "
                    } else {
                        text += unicode
                    }
                } else {
                    unmapped += 1
                    content.unmappedGlyphs += 1
                }

                var advance = glyph.width / 1000 * size
                advance += state.charSpacing
                if glyph.applyWordSpacing { advance += state.wordSpacing }
                cursor += advance * scale
            }
            guard !text.isEmpty || unmapped > 0 else { return }

            let combined = textMatrix * state.ctm
            let corners = [
                combined.applied(to: PDFPoint(minX, minY)),
                combined.applied(to: PDFPoint(maxX, minY)),
                combined.applied(to: PDFPoint(minX, maxY)),
                combined.applied(to: PDFPoint(maxX, maxY)),
            ]
            let bbox = PDFRect(corners)
            let origin = combined.applied(to: PDFPoint(0, 0))
            let end = combined.applied(to: PDFPoint(cursor, 0))
            let advanceLength = cursor * sqrt(abs(combined.a * combined.a + combined.b * combined.b))

            // 推进文本矩阵：下一段 Tj 从当前位置继续
            textMatrix = PDFMatrix.translation(cursor, 0) * textMatrix

            if PDFTextExtractor.traceText {
                FileHandle.standardError.write(
                    Data("TEXT b=\(streamBase) y=\(origin.y) x=\(origin.x) \(font.baseFont) \(text)\n".utf8))
            }
            content.runs.append(PDFTextRun(
                pageIndex: pageIndex,
                text: text,
                fontName: font.baseFont,
                fontSize: size * combined.scaleMagnitude,
                unscaledFontSize: size,
                origin: origin,
                endPoint: end,
                bbox: bbox,
                angle: combined.rotationAngle,
                renderMode: state.renderMode,
                advance: advanceLength,
                glyphCount: glyphs.count,
                unmappedGlyphs: unmapped,
                runIndex: content.runs.count,
                sourceRange: currentOpRange))
        }

        // MARK: XObject

        func drawXObject(name: String, resources: [String: PDFValue],
                         depth: Int, formStack: Set<Int>) {
            let xobjects = resources["XObject"]
            let dict: [String: PDFValue]
            if case .reference(let ref)? = xobjects {
                dict = (try? document.resolve(ref))?.dictionaryValue ?? [:]
            } else {
                dict = xobjects?.dictionaryValue ?? [:]
            }
            guard case .reference(let ref)? = dict[name],
                  let object = (try? document.resolve(ref))?.streamValue else { return }

            let subtype = object.dictionary["Subtype"]?.nameValue ?? ""
            if subtype == "Image" {
                let a = state.ctm.applied(to: PDFPoint(0, 0))
                let b = state.ctm.applied(to: PDFPoint(1, 0))
                let c = state.ctm.applied(to: PDFPoint(0, 1))
                content.images.append(PDFImagePlacement(
                    ref: ref,
                    bbox: PDFRect([a, b, c, PDFPoint(b.x + c.x - a.x, b.y + c.y - a.y)]),
                    pixelWidth: object.dictionary["Width"]?.intValue ?? 0,
                    pixelHeight: object.dictionary["Height"]?.intValue ?? 0))
                return
            }
            guard subtype == "Form" else { return }
            guard !formStack.contains(ref.number) else {
                content.warnings.append("Form \(ref.number) 循环引用，已跳过")
                return
            }

            let matrix = object.dictionary["Matrix"]?.arrayValue.flatMap { PDFMatrix(array: $0) }
                ?? .identity
            let formResources = object.dictionary["Resources"].map {
                document.resolvedResources($0)
            } ?? resources
            let decoded = (try? PDFFilters.decode(object.raw, dictionary: object.dictionary))
            guard let decoded else { return }

            // 保存并恢复：Form 里的 q/Q 必须自平衡，不平衡的坏文件不能污染外层
            let savedState = state
            let savedText = textMatrix
            let savedLine = lineMatrix
            state.ctm = matrix * state.ctm
            content.formCount += 1
            run(data: decoded, resources: formResources, depth: depth + 1,
                formStack: formStack.union([ref.number]))
            state = savedState
            textMatrix = savedText
            lineMatrix = savedLine
        }
    }
}

/// 字体缓存：同一页里 `Tf` 会反复切同一个字体，重复解析既慢又浪费内存。
/// 按字体对象的引用号缓存；内联字体字典按 (baseFont, subtype) 兜底。
public final class FontCache {
    private let document: PDFDocument
    private var byNumber: [Int: PDFFont] = [:]
    private var byKey: [String: PDFFont] = [:]

    public init(document: PDFDocument) {
        self.document = document
    }

    func font(named: String, resources: [String: PDFValue]) -> PDFFont? {
        let fontValue: PDFValue?
        if case .reference(let settingsRef)? = resources["Font"] {
            fontValue = (try? document.resolve(settingsRef))?.dictionaryValue?[named]
        } else {
            fontValue = resources["Font"]?.dictionaryValue?[named]
        }
        guard let fontValue else { return nil }

        if case .reference(let ref) = fontValue {
            if let cached = byNumber[ref.number] { return cached }
            guard let dict = (try? document.resolve(ref))?.dictionaryValue else { return nil }
            let font = PDFFont.load(document: document, dict: dict)
            byNumber[ref.number] = font
            return font
        }
        guard let dict = fontValue.dictionaryValue else { return nil }
        let key = "\(dict["BaseFont"]?.nameValue ?? "?")/\(dict["Subtype"]?.nameValue ?? "?")"
        if let cached = byKey[key] { return cached }
        let font = PDFFont.load(document: document, dict: dict)
        byKey[key] = font
        return font
    }
}

// MARK: - 输出模型

public struct PDFTextRun: Sendable {
    public init(pageIndex: Int, text: String, fontName: String, fontSize: Double,
                unscaledFontSize: Double, origin: PDFPoint, endPoint: PDFPoint,
                bbox: PDFRect, angle: Double, renderMode: Int, advance: Double,
                glyphCount: Int, unmappedGlyphs: Int,
                runIndex: Int = -1, sourceRange: Range<Int>? = nil) {
        self.pageIndex = pageIndex
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.unscaledFontSize = unscaledFontSize
        self.origin = origin
        self.endPoint = endPoint
        self.bbox = bbox
        self.angle = angle
        self.renderMode = renderMode
        self.advance = advance
        self.glyphCount = glyphCount
        self.unmappedGlyphs = unmappedGlyphs
        self.runIndex = runIndex
        self.sourceRange = sourceRange
    }

    public var pageIndex: Int
    public var text: String
    public var fontName: String
    /// 页面上实际看到的字号（已乘 CTM 缩放）
    public var fontSize: Double
    public var unscaledFontSize: Double
    public var origin: PDFPoint
    public var endPoint: PDFPoint
    public var bbox: PDFRect
    public var angle: Double
    public var renderMode: Int
    public var advance: Double
    public var glyphCount: Int
    public var unmappedGlyphs: Int
    /// 在本页 `content.runs` 里的下标（-1 = 合成的 run，不是解析出来的）
    public var runIndex: Int = -1
    /// 产生这个 run 的文本算子在**整页内容流**（多个流拼起来）里的字节区间。
    ///
    /// 只删「要重画的那几段」需要它：没有区间就只能整页驱逐，
    /// 代码块、页码、符号也会被换成宋体重画。见 `TextEvictor.evictText(kin:)`。
    public var sourceRange: Range<Int>? = nil

    public var isInvisible: Bool { renderMode == 3 || renderMode == 7 }
    public var isRotated: Bool { abs(angle) > 0.02 }
}

public struct PDFPathSegment: Sendable {
    public init(start: PDFPoint, end: PDFPoint, thickness: Double) {
        self.start = start
        self.end = end
        self.thickness = thickness
    }

    public var start: PDFPoint
    public var end: PDFPoint
    public var thickness: Double

    public var isHorizontal: Bool { abs(end.y - start.y) <= 1.0 }
    public var isVertical: Bool { abs(end.x - start.x) <= 1.0 }
    public var length: Double { start.distance(to: end) }
    public var bbox: PDFRect { PDFRect([start, end]) }
}

public struct PDFImagePlacement: Sendable {
    public var ref: PDFRef
    public var bbox: PDFRect
    public var pixelWidth: Int
    public var pixelHeight: Int
}

/// 一条被描边/填充的路径的包围盒。
///
/// 只用于「这里是不是图画」的判断：表格要的是横竖线段（`PDFPathSegment`），
/// 图表要的是**所有**笔触——折线、曲线、柱子的填充矩形。
public struct PDFPaintedPath: Sendable {
    public init(box: PDFRect, points: Int, filled: Bool) {
        self.box = box
        self.points = points
        self.filled = filled
    }

    public var box: PDFRect
    /// 该路径包含的端点数（折线图一条曲线可能有几百个点，但只有一个框）
    public var points: Int
    public var filled: Bool
}
