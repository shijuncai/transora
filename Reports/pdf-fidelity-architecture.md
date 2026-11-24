# PDF 高保真翻译架构：BabelDOC 思想 + 自研布局引擎 + 视觉结构定位 + Similarity Analyzer

建立时间：2026-11-22 22:2x (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`
关联：`Reports/model-migration-plan.md`（模型侧权威口径）、现行 PDF 链路
`Sources/HymnApp/PDFTextExtractor.swift` / `Sources/HymnCore/Documents/TextChunker.swift`

> **本文性质：架构设计与可行性论证，不含已实现代码。**
> 文中所有对 BabelDOC / agentic-doc 的描述均来自其仓库文件（依赖清单、IL schema、实现文档），
> 已在第 1 节标注证据来源；对自家代码的判断来自实际读源码。
> 性能数字与阈值**一律标注为待标定**，不编造实测值。

---

## 决策记录（2026-11-22 22:40，已定，不再讨论）

| 项 | 决定 | 对本方案的影响 |
|---|---|---|
| 输出形态 | **单语同版式 PDF** | 删掉「原页 + 译页」交错逻辑；overflow 最后一档由 `dual-page` 改为 `page-reflow`；可核对性靠独立报告，不靠版面 |
| 云端兜底 | **不允许** | 第 8 节 L3 整条否决；扫描件能力上限明确接受 |
| 字体 | **思源宋体**（Source Han Serif / Noto Serif CJK），OFL 1.1 | 上一版的授权阻塞项**解除**：OFL 明确允许嵌入与子集化，且「用字体生成的文档不受 OFL 约束」；代价是包体增大、且无斜体字重 |
| 未变 | 文本驱逐 + 增量写回；矢量优先；Similarity Analyzer 七项 | — |

> 单语同版式带一个副作用要说清楚：**译文 PDF 里没有原文**，用户无法在版面上对照。
> 所以「可核对」这件事改由 **逐段对照报告**（原文 / 译文 / 页码 / bbox / 各项指标 JSON）承担，
> 复用现有 `TranslationDocument` + DOCX 导出即可，不动 PDF 形态。

## 实施进度

| 阶段 | 状态 | 证据 / 报告 |
|---|---|---|
| P0 对象层 + 文本驱逐 + 增量写回 | ✅ **完成**（2026-11-22 23:5x） | `Reports/stage-p0-pdf-object-layer.md`；测试 255 → **302**；真实文件 4 份全部 `VERIFY_PASS` |
| P1 Form 递归 + 字体子集化 + 嵌入 + `pdf-stamp` | ✅ **完成**（2026-11-23 08:5x） | `Reports/stage-p1-forms-and-fonts.md`；测试 302 → **333**；插入的中文在 PDFKit 里逐字可提取、可渲染 |
| P2 IL 构建 + 字符提取 + 段落归并 + 表格网格 | ✅ **完成**（2026-11-23 09:3x） | `Reports/stage-p2-text-and-tables.md`；测试 333 → **356**；字符召回 **0.9993–1.0000**；合成表格 **105/105** |
| P3 排版：度量/禁则/三档投放/出口/占位符 | ✅ **完成**（2026-11-23 21:5x） | `Reports/stage-p3-typesetting.md`；测试 356 → **384**；661 页 4.6 s；图片 401/401 字节相同；fit 占 98.9% |
| P4 Similarity Analyzer 闭环（R1–R7 + 段落级修复） | ✅ **完成**（2026-11-23 23:5x） | `Reports/stage-p4-similarity-analyzer.md`；`Reports/p4-similarity-evidence.json`；测试 384 → **413**；409 页恒等排版抽 20 页：结构丢失 19 页 = 0 px；R2/R3/R7 误报 213/92/858 → 0/2/0 |
| P5 产品化（UI 接入 + 逐段对照报告 + 洗版 + 渲染器修正） | ✅ **完成**（2026-11-23 24:0x，v0.8.0） | `Reports/stage-p5-productization.md`；`Reports/p5-evidence.json`；测试 413 → **426**；无译文时输出与原文件逐字节相同；洗版 16.87 → 15.94 MB |

> P0 已验证的核心结论：661 页 / 401 张图 / 26,905 个对象，驱逐后**只有 661 个内容流对象变化，图片 SHA-256 全部相同**。
> 图片保真不是「对齐出来的」，是**结构性不可能变**。
>
> P1 已验证的核心结论：**「接管文本」这条路走得通**。驱逐原文后用思源宋体子集画中文，
> PDFKit 能把 20 个字逐字提取回来（说明 ToUnicode 正确），渲染出来是清晰的宋体（说明字体程序正确）；
> 同一份文件里 533 张图片字节不变，页面其余部分像素差 = 0。
>
> P2 已验证的核心结论：**「读」这一半通了**。661 页的字符召回 0.9993（对 PDFKit 逐页比字符多重集），
> 合成表格 105/105 结构完全一致，真实表格抽查页码级吻合。
> 读不通的原因几乎都是「编码信息缺失」而不是几何算错——补对 encoding/CMap 规则后召回从 0.866 跳到 0.9997。
>
> P3 已验证的核心结论：**「排」这一环成立，而且不再牺牲可读性**。
> 661 页里 98.9% 的块走「原字号原框」，只有 293 块压行距/缩字、3 块扩框、0 行溢出（模拟译文）。
> 极端膨胀（伪译文，每块凭空多 6 字）时也**没有叠字**：144 处溢出全部进了 inline-note / page-note / page-reflow，
> 并逐页上报。图片依旧 401/401 字节相同。

---

## 0. 结论先行

| # | 结论 | 依据 |
|---|------|------|
| C1 | 「图片/矢量/表格线 100% 复现」**可以做到字节级无损**，前提是**永不重绘**，只做「文本驱逐 + 原位重绘」 | 图片与图形不经我们的编码器，输出里是原始 stream 字节，可用 SHA-256 相等来证明 |
| C2 | 「整页重建」路线**永远做不到完美**，BabelDOC 自己文档已承认transparency/扩展特性支持有限 | `docs/ImplementationDetails/PDFParsing/PDFParsing.md` Limitations 段 |
| C3 | agentic-doc 是 LandingAI 的**云端 REST API 封装**（`VISION_AGENT_API_KEY`，单次≤2 页，页面图上云），与「运行时全程离线、文字不出本机」硬冲突 | 其 README / PyPI 说明；`BATCH_SIZE`、`MAX_WORKERS`、429 重试均为 HTTP 客户端行为 |
| C4 | 所以 agentic-doc 只能借**接口契约**（hierarchical chunk + grounding box + confidence），视觉定位要用 Apple Vision 在本地重建 | Vision `VNRecognizeTextRequest` 离线可跑、给归一化 boundingBox |
| C5 | 真正的护城河不是「复现」，是 **Similarity Analyzer** 的渲染比对闭环——BabelDOC 没有质量闭环，只 `report error` | `Typesetting.md` Algorithm 2 第 5 步 |
| C6 | 不要对外承诺「完美」。给可量化指标：非文本区域像素差、溢出率、缺字率、表格线 IoU | 第 11 节验收表 |
| C7 | **思源宋体用 OFL 1.1，授权问题彻底解决**：允许打包/嵌入/再分发/派生，且「文档不受该许可约束」 | `notofonts/noto-cjk` 的 `Serif/LICENSE` 原文，第 9.1 节 |
| C8 | 但官方只发 **CFF 的 OTF** 和 **可变 TTF**，没有静态 TTF；直接用 OTF 要写 CFF 子集器（~2,000 行且易错） | 第 9.2 节；结论是离线 instance 成静态 TTF，走 glyf 路线 |

一句话架构：

> **用 BabelDOC 的 IL 分层思想当骨架，但把它的「整页重建」换成「文本驱逐 + 原始操作符回放」；
> 用 agentic-doc 的输出契约当结构描述标准，但把它的云端视觉换成「矢量层精确解析 + Vision OCR 兜底」；
> 用一个自研的渲染比对器把「译完就交」变成「译完必验、验不过自动修」。**

---

## 1. 事实核查（先说清楚对方到底是什么）

### 1.1 BabelDOC 真实形态

| 项 | 实测值 | 证据 |
|---|---|---|
| 版本 / 许可 | 0.7.1，**AGPL-3.0** | `pyproject.toml` |
| 语言 | Python + **Rust 核心**（`rust/`、`scripts/generate_il_rust.py`、`maturin` 构建后端） | `pyproject.toml` `[build-system]` |
| 解析 | PyMuPDF（对象层/内容流） | 依赖 `pymupdf>=1.26.7` |
| 版面 | ONNX Runtime 跑 **DocLayout-YOLO** 类模型 | `babeldoc/docvision/doclayout.py` 内 `OnnxModel`、依赖 `onnx`/`onnxruntime` |
| 字体/整形 | **freetype-py + uharfbuzz**（真实字体度量 + HarfBuzz 整形） | 依赖清单 |
| 中间表示 | RELAX NG 定义的 **Document IL**（`il_version_1.rnc`） | 已读取全文，见第 4 节对照 |
| 主链路 | 解析→IL→版面→段落→样式/公式→翻译→排版→字体映射→生成 PDF | `docs/ImplementationDetails/README.md` |
| 质量闭环 | **无**。排版失败只 `Report error if element scaling is less than 0.1` | `Typesetting.md` |

**它最值得抄的三件事**（其余可以不理）：

1. **字符级 IL**：`PDFCharacter` 带 `char_unicode` / `advance` / `scale` / `visual_bbox` / `renderOrder` / `xobjId`。坐标、样式、z 序全部保留，这是后面一切的前提。
2. **`baseOperations` 原样保存**：每页/每个 XObject 都存一段原始操作符字符串。**图片不是被重绘的，是被回放的**——这是它能保住图的真正原因。
3. **排版三算法**（Algorithm 1 原位 / 2 缩字号与行距 / 3 向右扩框），参数具体可抄：行距 1.5→1.4（0.1 步），scale >0.6 时 0.05 步、≤0.6 时 0.1 步，scale <0.7 时把最小行距放宽到 1.1，scale <0.1 报错。

**它明确做不到的（原文 Limitations，我们不要重复踩）**：

- 透明度/复杂 PDF 扩展支持有限、图形模型简化；
- 只处理从左到右，**不支持竖排**；
- 只看单个段落，**没有页面级全局信息，导致同页字号不一致**（`Typesetting.md` 第 4 条）；
- 目录点线对齐无法处理；
- 性能差，自己写「Poor performance, needs optimization」。

### 1.2 agentic-doc 真实形态

| 项 | 事实 | 对我们的含义 |
|---|---|---|
| 归属 | `landing-ai/agentic-doc`，官方已标 **legacy**，迁移到 `landingai-ade` | 拿它当长期依赖有风险 |
| 本质 | 对 LandingAI **Agentic Document Extraction REST API** 的 Python 包装 | 不是本地库，是云客户端 |
| 前置 | 必须 `VISION_AGENT_API_KEY`；单次调用 ≤ 2 页，库内自己拆分+线程池+拼接 | 页面图**必须上云** |
| 输出 | 层级 JSON（`chunks`）+ 每元素精确 `box` + markdown + 可选 grounding 图 | **这个 schema 值得抄** |
| 健壮性 | 408/429/502/503/504 指数退避，`MAX_RETRIES` 默认 100 | 侧面说明它依赖网络稳定性 |
| 能力 | 表格结构、图、图表语义层级（比纯 OCR 强） | 本地等价物拿不到同等语义，需自研表格网格 |

**结论**：把它当「视觉结构提取与定位」的**参考实现和输出标准**，而不是运行时依赖。若要接，只能作为**用户显式开关的云端兜底**（第 8 节），且必须改掉「全离线」的产品话术。

### 1.3 我们现在的 PDF 链路（差距有多大）

| 环节 | 现状 | 差距 |
|---|---|---|
| 提取 | `PDFDocument.page(at:).string`，纯文本 | **坐标、字体、字号、图片、表格全部丢失** |
| 分块 | 按页 600 字符切，靠 `\n` 认段落 | 无段落几何，双栏会串行 |
| 翻译 | 串行逐块调本地 1.8B | 可复用，需加占位符协议 |
| 输出 | TXT / DOCX「原文+译文」对照 | **完全不产出 PDF，无版式** |
| 校验 | 无 | 无任何质量度量 |

也就是说：**目标不是改造现有 PDF 功能，而是从零建一个 PDF 引擎**。现有链路保留为「纯文本快译」快速通道（秒级），新链路做「版式重建」（分钟级），UI 分两个模式，不要混。

---

## 2. 核心设计决策：文本驱逐，而不是整页重建

这是本文最重要的一节，决定了「完美」能不能兑现。

### 2.1 两条路线对比

| | A. 整页重建（BabelDOC 路线） | B. 文本驱逐 + 原位重绘（本方案） |
|---|---|---|
| 做法 | 解析成 IL → 丢弃原页面 → 从 IL 重新生成整页操作符 | **保留原页面内容流的所有非文本操作符**，只把文本显示算子换掉，再追加新文本 |
| 图片 | 重新引用 XObject（通常无损，但依赖映射正确） | **字节不变**，一个 bit 都没碰 |
| 透明度/图案/软蒙版/渐变 | 需逐特性重建，**必然掉点** | 原样保留，**天然正确** |
| 重排能力 | 强（可任意重排） | 弱（译文必须在原段落框内解决） |
| 实现量 | 大（要写完整的图形重建器） | 中（只需内容流级手术） |
| 失败模式 | 静默丢元素（最危险） | 局部不达标，可定位、可回滚 |

### 2.2 B 方案的具体做法（可证明无损）

对每页内容流做**算子级过滤**：

```
原始:  q 1 0 0 1 72 700 cm /F1 11 Tf 0 g BT 72 700 Td (Hello) Tj ET Q
        re f  ... /Im0 Do ...  ← 图片、矢量、表格线全部只读通过
处理后: q 1 0 0 1 72 700 cm /F1 11 Tf 0 g BT 72 700 Td ET Q   ← 只删掉 Tj
        re f  ... /Im0 Do ...                               ← 原字节保留
新追加: BT /F9 11 Tf 1 0 0 1 72 700 Tm <0001 0002 ...> Tj ET  ← 译文（CID 双字节）
```

- **删除的**：`Tj` / `TJ` / `'` / `"` 四个文本显示算子。
- **保留的**：`q Q cm gs g G rg RG k K re f S B W n Do BDC EMC ...` 全部原样、原顺序。
- **结果**：旧文本**真的不存在了**（不可被复制/检索，比「涂白」干净）；图片与图形**字节不变**（可哈希证明）。

### 2.3 必须处理的三个陷阱

| 陷阱 | 现象 | 对策 |
|---|---|---|
| T1 文本在 Form XObject 内部 | InDesign/Word 导出的图文常把整页塞进一个 form，页面上只有一个 `/Fm0 Do` | 递归进 form 改；若同一 form 被多页共享，**必须先深拷贝成新对象号再改**，否则会串页 |
| T2 文本与非文本算子交织在同一 `BT` 块 | 少见但存在（有人在 BT 里改颜色） | 逐算子过滤，不整块删；保留 `Tf/Td/Tr` 残留无副作用 |
| T3 没有 `/ToUnicode` | 拿不到 unicode，字符级 IL 建不起来，不知道该翻什么；但页面**能正常渲染** | 降级到 Tier2：光栅化该页 → Vision OCR 取行框 → 删掉该页全部文本算子 → 按 OCR 行框重绘译文。OCR 也失败则**该页原样保留**（等于这页没翻），报告标 `untranslatable` |

### 2.4 写回方式：增量更新

不改原对象 → 只对「被改过的 content stream」追加一个新版本对象，追加 xref + trailer（`/Prev` 指旧 xref）。好处：

- 其他对象零风险，实现量小一个数量级；
- 未改页面连解析都不用；
- 缺点：旧文本字节仍物理存在于文件中，**取证级工具可恢复**。所以提供 `scrub` 选项：完整重写（丢弃增量历史），代价是文件重组。

> 这条要写进 UI 提示，不能默认替用户决定。

---

## 3. 分层架构（L0–L6）

```
┌─────────────────────────────────────────────────────────────┐
│ L6  Similarity Analyzer   渲染比对 → 修复指令 → 再验证（≤2 轮）│
├─────────────────────────────────────────────────────────────┤
│ L5  Layout Engine         三档投放 + 页面级字号基准 + 禁则     │
├─────────────────────────────────────────────────────────────┤
│ L4  Translator            段落/单元格/图注 + 占位符协议        │
├─────────────────────────────────────────────────────────────┤
│ L3  Structure Extractor   矢量层 → Vision → 版面 → 表格网格    │
├─────────────────────────────────────────────────────────────┤
│ L2  Document IL           对齐 BabelDOC rnc 的 Swift 模型      │
├─────────────────────────────────────────────────────────────┤
│ L1  Content Stream        算子词法/解释器 + 文本驱逐器         │
├─────────────────────────────────────────────────────────────┤
│ L0  PDF Object Layer      对象/交叉引用/流过滤器/字体/写入器    │
└─────────────────────────────────────────────────────────────┘
```

模块落在 `Sources/HymnCore/PDF/`（纯逻辑，可单测，不依赖 AppKit）：

```
HymnCore/PDF/
  Object/      Lexer Parser XRef Filters ObjectStream Document Writer
  Font/        FontDescriptor CMap ToUnicode Widths FontEmbedder GlyphCoverage
  Content/     Operator Interpreter TextEvictor CTM
  IL/          Page Character Paragraph Figure Curve Form Box
  Structure/   VectorExtractor VisionOCR LayoutClassifier TableGrid ReadingOrder
  Layout/      TextMeasurer LineBreaker InPlaceFitter RepairDirectives
  Verify/      Renderer RegionDiff SSIM Analyzer Report
  Pipeline.swift   (actor, 串行调度，复用现有 maxConcurrency=1 约定)
```

依赖：**CoreGraphics / CoreText / Compression(或 libz) / Vision / Accelerate**，全部系统框架，符合「零外部 SwiftPM 依赖」。

---

## 4. IL 数据模型（对齐 BabelDOC 的 rnc，但精简）

只保留我们真正要用的字段。BabelDOC 的 `renderOrder`/`subRenderOrder`/`xobjId` 三件套必须留——否则 z 序会乱，图和字会互相盖。

```swift
struct ILBox: Sendable { var x, y, x2, y2: Double }

struct ILStyle: Sendable {
    var fontID: String          // 资源名，如 "F1"
    var fontSize: Double
    var graphicsState: [UInt8]  // 原始 gs 指令（颜色/描边等），passthrough
}

struct ILCharacter: Sendable {
    var unicode: String
    var box: ILBox              // 字形视觉框
    var advance: Double
    var scale: Double           // Tz/水平缩放
    var xobjId: Int?            // 归属的 form
    var renderOrder: Int        // 原始绘制顺序，决定 z 序
    var style: ILStyle
}

enum ILComponent: Sendable {
    case line(ILBox, [ILCharacter])
    case formula(ILBox, [ILCharacter], xOffset: Double, yOffset: Double)  // 公式：只搬不译
    case sameStyleRun(ILBox, ILStyle, String)                             // 同一样式的一段译文
    case sameStyleChars(ILBox, ILStyle, [ILCharacter])                    // 原文字符透传
}

struct ILParagraph: Sendable {
    var id: Int
    var unicode: String         // 原文全文（占位符已内联）
    var box: ILBox
    var style: ILStyle
    var components: [ILComponent]
    var layoutLabel: String?    // title / text / figure_caption / table_cell ...
    var firstLineIndent: Bool
    var renderOrder: Int
}

enum ILFigureKind: Sendable {
    case image(xrefId: Int, box: ILBox, rawOps: [UInt8])      // 图片：只回放
    case path(box: ILBox, ops: [UInt8], stroke: Bool)         // 矢量/表格线：只回放
    case form(xrefId: Int, box: ILBox, doArgs: [UInt8])       // form：递归处理
}

struct ILPage: Sendable {
    var number: Int
    var mediaBox, cropBox: ILBox
    var baseOps: [UInt8]        // 该页原始操作符（已剔除文本显示算子后的结果也在这里）
    var characters: [ILCharacter]
    var paragraphs: [ILParagraph]
    var figures: [ILFigureKind]
    var fonts: [String: ILFont]
}
```

与 BabelDOC 的差异（有意为之）：

1. **不加 XML 序列化**，直接 Codable→JSON，给 `hymnctl pdf-structure --json` 和测试 golden 用；
2. **`baseOps` 存「已驱逐文本」的版本**，BabelDOC 存原版再重建，我们直接存中间态，省一次重建；
3. **公式不做识别，只做透传**：`formula` 组件携带原字符与偏移，翻译时用占位符跳过。BabelDOC 用正则+字体特征猜公式，误判率高，第一版不做猜测。

---

## 5. 结构提取：三级，矢量优先

这是「替代 agentic-doc」的部分。**能用矢量的地方绝不用视觉**——矢量是精确值，视觉是估计值。

### 5.1 Tier 1：矢量层（精确，覆盖 90% 数字原生 PDF）

直接从内容流算：

- **文本**：字符 + CTM → 设备坐标框，精确到 0.01pt。
- **图片**：`Do` 时 CTM 作用到单位正方形 → 图片框，精确。
- **表格**：分析 `re` / `m l` 路径 → 水平/垂直线段集合 → 建网格。
  - 判定表格：≥3 条水平线且 ≥2 条垂直线，且交点数 ≥6，且线宽/颜色一致。
  - 单元格：相邻线段围成的矩形；检测跨行/跨列（某侧无分隔线）。
  - **无框线表格**：按字符 x 起点做一维聚类（间隙 > 1.5 倍字高视为列边界），列数一致性 > 80% 才认。
- **版面**：不跑模型也能到 80%：字号直方图定正文基准，行宽中位数定栏宽，栏间空白定单/双栏，页眉页脚按「距边 <8% 且每页重复」剔除。

### 5.2 Tier 2：Vision OCR（扫描件/无文字层，离线）

`VNRecognizeTextRequest`：`recognitionLevel = .accurate`，`recognitionLanguages = ["zh-Hans","en-US"]`（按需扩展），`usesLanguageCorrection = false`（翻译场景不要纠错）。

- 拿 `VNRecognizedText.boundingBox`（**归一化、原点左下**）→ 反投影回 PDF 用户空间；
- 字符级框用 `boundingBox(for: Range)`，精度低于矢量层，需 ±2pt 容差；
- 局限：只给行/词框，**不给表格结构、不给语义层级**——所以「表格」必须靠 5.1 的网格算法补，这就是我们和 ADE 的真实差距，必须承认。

### 5.3 Tier 3：版面分类（可选 ML）

BabelDOC 用 DocLayout-YOLO（10 类：title / plain text / abandon / figure / figure_caption / table / table_caption / table_footnote / isolate_formula / formula_caption）。

我们的取舍：

- **P1 不引入模型**，全靠 Tier 1 几何启发式；分类只用于决定「这段能不能动、要不要缩」；
- **P4 再评估**是否转一个 Core ML 版（~20-40 MB，会进包，需要 w8 量化）；
- 判断标准：只有在基准集上「启发式误分类率 > 8%」才值得上模型。**没数据不上模型**。

### 5.4 agentic-doc 契约对齐

我们的 IL 导出一份**同构 JSON**，便于将来与 ADE 输出互换/对拍：

```json
{"type":"table_cell","box":{"x":72.0,"y":540.2,"w":210.4,"h":18.6},
 "confidence":0.97,"parent_id":"tbl-3","children":[],"text":"…"}
```

`confidence` 字段：矢量层给 1.0，Vision 给模型置信度，启发式给 0.6–0.85。**不再用「我猜的」当事实**。

---

## 6. 布局引擎：抄三档，改两处

### 6.1 三档投放（BabelDOC 参数直接用）

```
fit(paragraph, bbox):
  1. 原位：用 CoreText 实测宽度排版，能进 bbox → 完成
  2. 缩行距：1.5 → 1.4（0.1 步）
  3. 缩字号：scale > 0.6 时 0.05 步；≤0.6 时 0.1 步；scale < 0.7 起最小行距放宽到 1.1
  4. 扩框：向右最多到 cropBox 宽 90%，且不与右侧 figure/paragraph 重叠
  5. 仍不行：交给 overflow 出口（三选一）
```

**为什么用 CoreText 而不是自己算**：`CTLineCreateWithAttributedString` 同时给出整形（相当于 HarfBuzz）和 advance（相当于 FreeType），而且**我们最终就是用同一个 CTFont 画出来的**——度量与渲染天然一致，不会出现「算着放得下、画出来溢出」。这一点比 BabelDOC 的 freetype+harfbuzz 组合更省事。

### 6.2 改进点 1：页面级字号基准（修 BabelDOC 的已知缺陷）

先算全页正文字号直方图，取 P25 作为「可读下限」。任何段落缩到低于 `max(6pt, P25 × 0.8)` 就**停止缩字号**，改走扩框或 overflow。

理由：BabelDOC 允许单段缩到 0.1 倍，结果是同页字号五花八门——这是它文档里自己承认的问题，用户一眼就能看出来「这页不对劲」。

### 6.3 改进点 2：扩框不只看右边

原文只向右扩。中文译文变短但**字宽变宽**，常需要向下借一行。所以：

- 先试右扩（同行仍有空白）；
- 再试下扩（首行基线不动，允许末行下探，直到撞到下个段落/图/页脚安全线）；
- 两者都受「不与任何已放置元素 IoU > 0」约束。

### 6.4 断行与禁则

- 中文逐字可断；英文断在空格/连字符；`-` 悬挂允许；
- **行首禁则**：`，。、；：？！）】」』％` 不出现在行首 → 与前一字符绑定；
- **行尾禁则**：`（【「『` 不出现在行尾；
- 中英混排按 UTR #59，中文与拉丁之间加 0.25 em（BabelDOC 用 0.5 字符宽，偏大，实测再定）。

### 6.5 overflow 三个出口（BabelDOC 直接报错，我们给台阶）

| 出口 | 适用 | 做法 | 代价 |
|---|---|---|---|
| `inline-note` | 短溢（≤2 行） | 段落右侧空白处竖线 + 8pt 小字 | 版式轻微改变 |
| `page-note` | 段落级长溢 | 页脚编号脚注带，`⟨1⟩` 锚点 | 需重排页脚，可能连带下页 |
| `page-reflow` | 整页密集（双栏摘要区、目录页、注释密集页） | **锁定图片/表格/矢量位置**，把该页全部段落按阅读顺序流式重排进剩余文字区域 | 该页不再「同版式」，报告标记 `reflowed` |

`page-reflow` 是最后一档，触发条件（满足任一）：

- 单页有 ≥ 2 个段落走到 `page-note`；
- 该页译文估算占位 > 原文占位的 1.25 倍（中文虽短，但字号下限抬高后常溢出）。

它比原来的「多一页」方案好在：**不增页、不把字缩成蚂蚁**。因为输出是单语，整页重排不需要说服用户「这页为什么多了个原版」。
重排时图片与表格**位置完全不动**，只重排文字流向——所以「图不错位」这条性质在 `page-reflow` 下依然成立。

---

## 7. Similarity Analyzer（自研核心）

这是整个方案里唯一「别人没有」的部分，也是把「翻译工具」变成「可信工具」的地方。

### 7.1 七项检查（全部可计算、可定位、可修复）

| ID | 检查 | 算法 | 起始阈值（待标定） | 自动修复 |
|----|------|------|------------------|---------|
| R1 | 非文本区域保真 | 原页/新页各渲染 144dpi → 用 IL 的文本框生成掩膜 → 掩膜外逐像素 diff | maxΔ ≤ 2/255，差异像素比 < 0.02% | 该区域回滚为原 op 回放 |
| R2 | 文本溢出 | 译文 ink bbox vs 分配 box | 溢出 ≤ 0.5pt | 降 scale → 扩框 → 换档 |
| R3 | 遮挡 | 文本 box ∩ figure/table/其他段 | IoU = 0 | 平移/缩小/换档 |
| R4 | 字形缺失 | `CTFontGetGlyphsForCharacters` 逐字查 + 渲染后检测 .notdef 方框 | 缺失 = 0 | 字体回退链 → 该词保留原文 |
| R5 | 内容完整性 | 段落数、占位符一一对应、公式 token 数、数字/专名保留率 | 缺失 = 0 | 重译该段（更严 prompt） |
| R6 | 版面相似度 | 缩略图 SSIM（11×11 高斯窗，8×8 分块）+ 块级位置 IoU | SSIM ≥ 0.92（同语向基线） | 不自动改，标记待复核 |
| R7 | 阅读顺序 | IL `renderOrder` vs 提取序；双栏串行检测 | 逆序对 = 0 | 按列重排段落 |

SSIM 自己实现：灰度化 + 分离式高斯 → 均值/方差/协方差三张图，纯 Swift + Accelerate（`vImageBoxConvolve_Planar8` 近似，或手写分离卷积），不引第三方。

### 7.2 修复回路

```
translate → layout → write → render → analyze
                                    ├─ pass   → 交付
                                    └─ fail   → repairs (段落级指令)
                                                → layout.apply(repairs)   // 只重排受影响段落
                                                → write(page only)        // 只重写受影响页
                                                → analyze                 // 最多 2 轮
                          2 轮仍 fail → 标记 needsReview，交付但列出清单
```

关键约束：

- **修复是段落级的，不是整页重排**——否则第 2 轮会把第 1 轮修好的东西弄坏；
- **每轮留 `RepairTrace`**（哪段、什么指令、改了什么、结果如何），写进报告 JSON；
- **绝不静默降级**：修不好就明说，页面加不可见标记 + 报告里列页码和原因。

### 7.3 性能约束

- **渲染成本已实测**（P1 用 PDFKit + CGContext 量过）：144 dpi 渲染一页 A4 约 **60 ms**。
  300 页 × 2 份 × 2 轮 = 1,200 次渲染 ≈ **72 秒**，可以接受；再加图像比较（逐像素）约 10–20 ms/页；
- 优化：只渲染「本轮有改动的页」；R6 只在缩略图（72dpi）上算；R1 可用区域 checksum 短路（未改区域直接跳过）；
- 内存：`Document` 层 stream **懒解压 + mmap**，不要一次性把 300 页解压进内存（对比：模型常驻已占 461 MB）。

---

## 8. agentic-doc 的接入边界（L3 已否决）

| 级别 | 做法 | 状态 |
|---|---|---|
| **L1 契约借鉴** | 照搬 chunk schema（`type`/`box`/`confidence`/`parent_id`/`children`），IL 导出同构 JSON | ✅ 采用，零成本 |
| **L2 能力本地替代** | 矢量解析 + Vision OCR + 自研表格网格 + 几何启发式 | ✅ 采用，本文主体 |
| **L3 云端兜底** | 调 LandingAI ADE，仅上传 Tier1/2 都失败的页 | ❌ **2026-11-22 否决** |

否决理由（留档，避免以后有人重新提）：

1. 产品承诺是「PDF 只在本机解析，文字不会上传」（`PDFTranslationView.swift` 第 145 行）。开一个上云口子，这句话就变成假话；
2. `agentic-doc` 官方已标 legacy，是长期债；
3. 收益只在扫描件长尾，而那部分用 Vision + 逐段对照报告已经够用。

**代价要认**：扫描件的表格结构还原不了（Vision 只给行框），只能输出「识别文本 + 对照报告」，不承诺版面还原。
这是选了「全离线」必须付的价，不要以后当成 bug 来修。

若将来重启 L3，前置条件是：独立导出功能、不进主流程、逐页确认、默认关、产品话术同步改掉「不上传」——五条缺一不可。

---

## 9. 字体方案：思源宋体（Source Han Serif / Noto Serif CJK）

### 9.1 授权：阻塞解除（SIL OFL 1.1）

来源：`notofonts/noto-cjk` 仓库 `Serif/LICENSE`（2026-11-22 读全文）。三句关键原文：

| 原文 | 含义 |
|---|---|
| "The fonts, including any derivative works, can be **bundled, embedded, redistributed** and/or sold with any software provided that any reserved names are not used by derivative works." | 允许随软件打包、**嵌入**、再分发，也允许衍生作品（子集化、格式转换） |
| "The requirement for fonts to remain under this license **does not apply to any document created using the fonts** or their derivatives." | **用字体生成的 PDF 不受 OFL 传染**——这句话直接解决了上一版最大的法律不确定性 |
| "as long as they are **not sold by themselves**" | 唯一实质限制：不能单独售卖字体文件 |

**RFN 已实核（不是推测）**：拉取 `NotoSerifSC-VF.ttf` 的 `name` 表（offset 14,645,164 / 3,296 B），逐条解析结果：

| nameID | 内容 |
|---|---|
| 0（版权） | `© 2017-2024 Adobe (http://www.adobe.com/).` ← **没有 `with Reserved Font Name` 字样** |
| 7（商标） | `Noto is a trademark of Google Inc.` |
| 13（许可） | OFL 1.1 标准声明 |
| 14 | `http://scripts.sil.org/OFL` |
| 17（字重） | `ExtraLight` ← 见 9.2 的坑 |

**结论**：无 RFN，法律上可以保留原名。但 `Noto` 是 Google 商标，且 OFL 第 4 条禁止用作者名**推广**修改版。
所以工程上建议：instance 出的静态字体**改名为自有名**（如「译星宋 / LinguaNova Song」），`nameID 0/13` 原样保留
Adobe 版权行与 OFL 文本，其余合规项不变。这样商标和 OFL 两头都干净。

> 与普惠体方案的根本差别：普惠体《法律声明》把「拆分、转换」列为需书面授权的禁止行为，
> 而 OFL 是**明确许可**这两件事。所以：
>
> - **原「上线阻塞项」取消**，不再需要发函；
> - 子集化从「有法律风险」变成「标准做法」，输出体积可以降到 1 MB 级；
> - 补上「原文字体多为衬线 → 译文用宋体」的观感落差问题。

### 9.2 格式分叉：OTF/CFF 还是 TTF/glyf（结论：走 TTF）

官方发布物实测（`notofonts/noto-cjk`，`Serif2.003`）：

| 文件 | 体积 | 轮廓 |
|---|---|---|
| `Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf` | **11.09 MB** | CFF（CID-keyed） |
| `Serif/SubsetOTF/SC/NotoSerifSC-Bold.otf` | **11.53 MB** | CFF（CID-keyed） |
| `Serif/Variable/TTF/Subset/NotoSerifSC-VF.ttf` | 23.96 MB | glyf（可变字体） |
| `Serif/Variable/TTF/NotoSerifCJKsc-VF.ttf` | 57.12 MB | glyf（可变，全 CJK） |

**官方没有发静态 TTF**。所以两条路：

| | A. 直接用 OTF | B. 离线转静态 TTF |
|---|---|---|
| PDF 结构 | `CIDFontType0` 后代 + `FontFile3`（`/CIDFontType0C`） | `CIDFontType2` + `FontFile2` + `/CIDToGIDMap /Identity` |
| 子集器 | 要解析 CFF INDEX / CharStrings / `FDArray` / `FDSelect` / charset / subrs 闭包，**~2,000 行且极易出 bug** | 只需重建 `loca`/`glyf`/`hmtx`/`cmap`/`post`/`head`/`maxp`，**~1,000 行** |
| 字宽 | 从 CFF 取 | 从 `hmtx` 取，简单 |
| 前置 | 无需转换 | 需离线用 `fonttools varLib.instancer` 从 VF 生成静态 400/700 |
| 结论 | ❌ 不选 | ✅ **选这个** |

**为什么选 B**：本项目零外部依赖、所有解析器自研，CFF 子集器是整个工程里最容易埋雷的地方（一个 subr 处理错，字形就全乱，而且只在个别字上暴露）。
离线转换是**一次性**的，产出静态 TTF 后用 SHA-256 锁进仓库，运行时不需要 Python——符合「Python 只做离线 golden」的既有规则。

**表结构实测（用于体积推算，非估算）**：`NotoSerifSC-VF.ttf` 共 21 张表，

| 表 | 大小 | 含义 |
|---|---|---|
| `glyf` | 13.71 MB | 轮廓本体（instancing 保留） |
| `gvar` | 9.72 MB | 可变字重增量（**instancing 后丢弃**） |
| `loca` | 0.12 MB | 字形索引 |
| `hmtx` | 0.12 MB | 字宽 |
| `name` | 3.3 KB | 名称/许可 |
| `fvar` | 106 B | 可变轴定义 |
| `post` | 32 B | **已是 format 3**（无字形名），无需再降级 |

→ 静态实例 ≈ 24 − 9.72 ≈ **14.2 MB/字重**（两个 ≈ 28.4 MB）。这解释了为什么 OTF 只有 11 MB：CFF 更紧凑，
但为省这 3 MB 去写一套 CFF 子集器不划算。

> ⚠️ **坑**：这个 VF 的**默认 master 是 ExtraLight（wght=200）**，`nameID 17` 写着 `ExtraLight`。
> 直接 `instantiateVariableFont(font, {})` 会得到 200 字重的「细宋」，正文会明显发虚。
> 必须显式 `{'wght': 400}` / `{'wght': 700}`，并在产出后断言 `OS/2.usWeightClass == 400/700`。

（附注：`otf2ttf` 那条路也能走，但它把三次贝塞尔转二次，字形会有微小偏差；从 VF 直接 instance 更干净，因为 VF 本来就是 glyf。）

### 9.3 字重与斜体

| 项 | 决策 | 说明 |
|---|---|---|
| 正文 | 静态实例 **wght=400**（Regular） | 从 `NotoSerifSC-VF.ttf` instance 得到 |
| 粗体 | 静态实例 **wght=700**（Bold） | 不再需要用 `Tr 2` 合成加粗——这是相对普惠体方案的实质改进（宋体描边加粗会糊掉衬线角） |
| 细体/黑体 | 不生成 | 原文 Light → 映射 400；Heavy → 700 |
| 字重映射 | 400/Book/Regular→400，Medium/SemiBold→400，Bold/Heavy/Black→700 | 按 `/FontDescriptor /StemV` 或字体名判；判不出统一落 400 |
| 斜体 | **全家族无斜体**（仓库无任何 Italic 文件，已核） | 用 `Tm` 水平斜切 **0.21** 模拟，报告标 `synthetic-italic` |
| 竖排 | 不支持 | 与 BabelDOC 同样限制（`Typesetting.md` Limitations 第 1 条） |

> 斜体这件事要提前说清楚：思源宋体是学术排版最常用的字体，但**它没有斜体字重**。
> 论文里的强调、书名、拉丁学名大多是斜体，用斜切模拟在正文小字号下几乎看不出差别，大字号标题会略假。
> 如果以后要真斜体，OFL 允许我们基于 Regular 做一个真正的斜体实例（改 `post` 表 + 骨架倾斜），但那是额外工程，第一版不做。

### 9.4 拉丁沿用原字体（这条比换字体更重要）

不要把所有字符都换成思源宋体。规则不变：

```
对译文里每个字符：
  if 是 CJK / 全角标点 → 用思源宋体
  else if 原字体对该字符有 glyph（查 /Widths + /CIDToGIDMap + /ToUnicode→GID）→ 用原字体、原字号
  else → 回落到思源宋体
```

换字体后这条策略的价值反而更大了，原因很具体：

- 思源宋体的拉丁是 **Source Serif**，和 Times 骨架相近但**更宽、更圆**，混排时一眼能看出「英文换字体了」；
- 而 `2026`、`GDP`、`Transformer`、`et al.` 这些词如果沿用原字体，观感和原文一致，读者不会出戏；
- 中文部分因为字形差异巨大，换字体的观感损失是**不可避免**的，把损失集中在中文一侧是最优解。

### 9.5 缺字处理

思源宋体 SC 子集覆盖常用与次常用汉字，生僻字仍可能缺（异体字、罕见人名地名、部分符号）：

1. 先查 `CTFontGetGlyphsForCharacters`，拿不到 glyph 就判缺字；
2. 该**词**（不是整段）回落为保留原文 + 报告标 `glyph-missing`；
3. **绝不画方框、绝不顶系统字体**（PingFang/Songti 是 Apple 系统字体，嵌入会有授权与跨机缺字双重问题）。

`R4` 盯着这条：语料集缺字率必须为 0。非 0 就换全 CJK 版 VF（57 MB 那个）重新 instance，而不是补丁式加字。

### 9.6 包体与合规动作

| 动作 | 内容 |
|---|---|
| 离线生成 | 一次性：`fonttools varLib.instancer` 从 `NotoSerifSC-VF.ttf` 生成 `wght=400` / `wght=700` 两份静态 TTF，产出放 `Resources/Fonts/` |
| 包体 | **实测 +29.7 MB**（`LinguaNovaSong-Regular.ttf` 14,851,884 B + `-Bold.ttf` 14,850,844 B），455 → 约 485 MB |
| 许可 | 随包放 OFL 1.1 全文 + `nameID 0` 的 Adobe 版权行；「关于」窗口标注「字体：思源宋体 / Source Han Serif（SIL OFL 1.1）」 |
| 打包校验 | `make-release.sh` 增加一步：两个 TTF 存在 + SHA-256 锁定 + LICENSE 存在 + `otool -L` 仍只有系统 dylib |
| 运行时 | `CTFontManagerRegisterFontsForURL` 注册一次；不写系统字体目录、不依赖用户已装字体 |
| 禁止项 | 不单独售卖字体文件；若采用自有命名，需同步改 `nameID 1/4/6/16/17`，不能只改文件名 |

### 9.7 输出体积：子集化现在是默认（**已实测**）

OFL 放开之后，**默认走运行时 glyf 子集化**，不再有「整字体嵌入」这个折中。
下表是 P1 真跑出来的数字（`LinguaNovaSong-Regular.ttf`，14,851,884 字节 / 31,058 字形）：

| 唯一字数 | 子集原始 | Flate 压缩后 | 占原字体 |
|---|---|---|---|
| 100 | 23,124 | **15,837** | 0.11% |
| 500 | 145,884 | **91,690** | 0.62% |
| 1,000 | 361,116 | **226,422** | 1.52% |
| 2,000 | 727,400 | **453,667** | 3.05% |
| 3,000 | 1,156,644 | **725,514** | 4.88% |
| 5,000 | 2,050,444 | **1,270,298** | 8.55% |
| 8,000 | 3,432,196 | **2,109,061** | 14.20% |

结论：**1,000–3,000 唯一字对应 0.23–0.73 MB**，原先「0.6–1.5 MB / 3,000 字」的估算偏保守（真实值约 0.73 MB）。
一本 300 页中文书通常 3,000–4,000 唯一字，**每份 PDF 约 0.7–1.0 MB**，可以接受。

子集器的四个技术要点（P1 已全部落地并有回归测试）：

1. **复合字形递归**：组件 GID 会被重新编号，必须**改写复合字形里的组件编号**，否则拼字错位。
   实测这份字体经 `varLib.instancer` 实例化后**没有复合字形**（组件已被展开），
   所以该分支用合成字节序列单独测（`composite-remap-synthetic`），不依赖字体里恰好有；
2. **`loca` 两制**：输入可能是 short（偏移 /2）或 long；输出一律 long，省掉 128 KB 上限问题；
3. **`post` 表降为 format 3**：丢掉字形名，省体积且不影响渲染（我们不需要按名字取字形）；
4. **`hmtx.lsb` 必须按原值搬运**，不能写 0 —— 部分光栅器依赖它，写 0 会让字形整体偏移。

---

## 10. 落地分期（按你既有节奏：每阶段构建 + 测试 + 数据）

| 阶段 | 内容 | 交付物 | 行数量级（±40%） | 退出条件 |
|---|---|---|---|---|
| **P0 地基** | PDF 对象层：词法/对象/xref(表+流)/ObjStm/过滤器(Flate,ASCIIHex,ASCII85,LZW,RunLength)/写入器；字体（Type1/TrueType/CID/ToUnicode/Widths）；加密检测。**另含一次性字体准备**：`varLib.instancer` 生成 400/700 静态 TTF、改名、锁 SHA-256 | `hymnctl pdf-dump --objects` / `--chars`；`Scripts/make-fonts.sh` + 产物 `Resources/Fonts/` | 5,500 | 基准集 50 份 PDF 全部解析成功；字符坐标与 `pdftotext -bbox` 误差 < 0.5pt；两份字体 `OS/2.usWeightClass` 分别是 400/700 |
| **~~P1 手术~~** ✅ | ~~内容流解释器 + **文本驱逐器** + 增量写回 + **字体嵌入器**（CIDFontType2/Identity-H/Widths）+ **glyf 子集器**（复合字形递归 / `loca` 两制 / `post` format 3）+ 宋体字重映射 + 拉丁沿用原字体~~ | `hymnctl pdf-evict`、`hymnctl pdf-stamp` | ~~4,600~~ **实际 2,290** | **已完成**：插字后同页图片 SHA-256 不变（533/533）；插入的中文 PDFKit 逐字可提取、可渲染；驱逐 + 插字的像素差限制在文字矩形内（0.299%）。详见 `Reports/stage-p1-forms-and-fonts.md`。**未做**：拉丁沿用原字体、宋体字重映射（都依赖 P2 的字宽表） |
| **~~P2 结构~~** ✅ | IL 构建 + 矢量线段提取 + 版面启发式 + 表格网格（Vision 兜底未做，见下） | `hymnctl pdf-structure --json` | ~~4,500~~ **实际 3,240** | **已完成**：字符召回 0.9993–1.0000（对 PDFKit 逐页比字符多重集）；合成表格 105/105 结构完全一致；661 页 1.66 s / 188 MB。**未做**：段落 F1 无标注语料、合并单元格、无线表格、竖排、扫描件 OCR |
| **~~P3 排版~~** ✅ | 度量（hmtx 与 /W 同源）/ 断行禁则 / 三档投放（压行距→缩字→扩框）/ 出口（inline-note → page-note → page-reflow）/ 占位符协议 / 第 3.1 节的钉子策略 | `hymnctl pdf-typeset` | ~~4,200~~ **实际 2,254** | **已完成**：661 页 fit 98.9%、shrink 293 块、expand 3 块、溢出 0 行（模拟译文）；图片 401/401 SHA-256 相同；相交自检 22 对 /16 页（继承 P2 结构异常，已上报） |
| **P4 闭环** | Similarity Analyzer（R1–R7）+ 修复回路 + 逐段对照报告 | `hymnctl pdf-verify` | 3,000 | R1 全通过；自动修复成功率 ≥ 80%（可复发问题） |
| **P5 产品化** | 300 页性能、进度/取消、多栏重排、UI 模式切换 | App 内「版式重建」模式 | 2,500 | 300 页/153 万字：内存峰值 < 1.5 GB，端到端 < 25 min（待实测定标） |

合计 **~2.4 万行 Swift**（不含测试；子集器已并入 P1）。**这是月级工程量，不是一个下午**，必须先说清楚。

> **进度校正（2026-11-23 21:5x）**：P0 + P1 + P2 + P3 实际 **9,674 行**，原估 18,800 行。
> 差额集中在四处：①「视觉得到的东西」（Vision OCR、无线表格）；②合并单元格；
> ③「拉丁沿用原字体」没做（P3 统一用宋体，观感差异可接受，但英文词会略宽）；
> ④P4 的校验闭环当时还没写（2026-11-23 23:5x 已补齐，见 `stage-p4-similarity-analyzer.md`）。
> 到这里**主链已经闭合**：读（P2）→ 排（P3）→ 写（P0/P1），且每一环都有可复核的指标。
> 剩下的 P4 是「证明它好」和「自动修不好看的地方」，P5 才是产品化。

测试策略沿用你的 golden 传统：

```
Eval/pdf/
  corpus/        50 份：学术论文/财报/报纸多栏/扫描件/公式密集/表格密集/中日韩原文
  golden/
    il/*.json        结构 golden（段落数/box/标签）
    render/*.png     非文本区域掩膜图（用于 R1 零差异断言）
    metrics.json     各文档 R1–R7 基线值
```

`hymntest` 里每个模块独立测：`PDFObjectTests` / `CMapTests` / `TextEvictorTests` / `ILTests` / `TableGridTests` / `LineBreakTests` / `FitTests` / `SimilarityTests`。**不允许「跑通一份 PDF 就算过」**——这正是你现在 255 项测试的口径。

---

## 11. 验收：把「完美」翻译成可验证的指标

| 对象 | 承诺 | 验证方式 |
|---|---|---|
| 图片 | **字节不变** | 输出中该 XObject stream 的 SHA-256 == 原件；R1 像素差 = 0 |
| 矢量/表格线 | **字节不变** | 同上（路径算子不经过编码器） |
| 表格结构 | 单元格网格一致 | 单元格数/行列数相等，网格线 IoU = 1.0 |
| 文本 | **版式等价**（不是像素一致） | 无溢出（R2）、无遮挡（R3）、缺字 0（R4）、字号不低于同页 P25 × 0.8（6.2） |
| 字体 | 正确嵌入、不缺字、不撑大文件 | `pdffonts` 显示宋体子集 `emb = yes`；语料集缺字率 = 0；拉丁字符沿用原字体的比例 ≥ 90%；单份 30 页 PDF 字体增量 ≤ 2 MB |
| 输出体积 | 可接受 | 30 页**文本型**文档 ≤ 8 MB（图片按原字节回放，不额外膨胀；扫描件体积随原图，另计） |
| 内容 | 无漏译、无占位符错位 | R5 全通过，段落数守恒 |
| 整页 | 观感可接受 | SSIM ≥ 0.92 + 人工抽检 20 页/文档 |
| 合规 | 字体授权闭环 | 包内有 OFL 全文与版权行；`make-release.sh` 校验通过；未单独售卖字体 |

**不能承诺的**：译文与原文像素级一致（字体不同、语言膨胀不同、断行不同）；衬线原文的衬线感；扫描件表格结构还原（Vision 拿不到）；竖排；加密 PDF（明确拒绝）。
**单语同版式的额外代价**：版面里没有原文可对照，可核对性只能靠逐段对照报告。

---

## 12. 风险清单（按「会翻车程度」排序）

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| 1 | **instance 参数/产物不确定** | VF 默认 master 是 ExtraLight，漏传 `wght` 会得到细宋（正文发虚）；且不同 fonttools 版本产出字节可能不同，golden 会飘 | 显式 `{'wght':400}`/`{'wght':700}` + 断言 `OS/2.usWeightClass`；产物当二进制资产入库锁 SHA-256，构建只校验不重生成 |
| 2 | 包体 ≈ +28.4 MB | 455 MB → 约 483 MB，下载与更新变慢 | 后期可预子集到 GB18030 一二级（OFL 允许）压到 ~5 MB/字重；或按语向拆包 |
| 3 | 宋体无斜体字重 | 论文强调、书名、拉丁学名只能斜切模拟，大字号偏假 | 小字号几乎不可辨；报告标 `synthetic-italic`；后续可基于 OFL 自造真斜体 |
| 4 | 增量更新留下旧文本字节 | 隐私/取证问题 | 提供 `scrub` 完整重写选项 + UI 明示 |
| 5 | Form XObject 共享 | 改一页串多页 | 改前深拷贝对象号，写单测覆盖 |
| 6 | 无 `/ToUnicode` 的 PDF | 不知道该翻什么 | 光栅化 + Vision OCR 取框重建；再失败则该页保留并标 `untranslatable` |
| 7 | 300 页性能与内存 | 卡死主线程 | 全程后台 actor + 分页流式；渲染校验可关闭 |
| 8 | 「完美」话术反噬 | 一份坏 PDF 就打脸 | 对外说「高保真 + 可验证」，每份输出附报告 |
| 9 | 表格无框线聚类误判 | 把正文切成列 | 一致性阈值 + 交叉验证（行高、字号），低置信交给「整体当段落」 |
| 10 | BabelDOC 是 AGPL | **抄代码 = 传染** | 只看思想与参数，代码全部自研；IL 重写为 Swift + JSON，不照搬 `.rnc` |
| 11 | 修改版沿用 `Noto Serif SC` 名称 | `Noto` 是 Google 商标；OFL 第 4 条禁止用作者名推广修改版 | RFN 已实核为「无」，法律上可保留原名；但工程上直接改自有名（如「译星宋」），`nameID 0/13` 原样保留 |

> 第 10 条务必记住：AGPL-3.0 对「衍生作品」定义很宽。只借鉴架构思想（思想不受版权保护），代码全部自研。
> 第 1 条是**最容易在半年后咬人**的一条：字体是二进制资产，不是构建产物，必须锁哈希。
> 授权风险已随换字体消失——**这不是「风险降级」，是「风险归零」**。

---

## 13. 已定 / 未定

**已定（2026-11-22，不再回滚）**：

1. 输出 = 单语同版式 PDF；
2. 不接云端，任何形式的页面外发都不做；
3. 字体 = **思源宋体**（OFL 1.1），静态 400 / 700 两个实例，运行时 glyf 子集化。

**未定（都是小的，可边做边定）**：

1. 是否需要 **600 SemiBold**（章节标题常用）；现在映射到 700 略重，多一个实例约 +14 MB 包体；
2. 是否做「预子集字体」压缩包体（GB18030 一二级，~5 MB/字重，覆盖约 27,000 字）——省 20 MB，极生僻字概率上升；
3. UI 是否暴露「译文统一宋体 / 尽量保留原文字体风格」开关（默认统一宋体，不做也行）。

> 原「给阿里巴巴发函」的阻塞项已随字体更换消失。**现在没有任何法律前置条件了**，可以直接开工 P0。

---

## 14. 与现有工作的关系

- **不影响**现有划词、翻译、历史、术语库、模型推理任何链路；PDF 引擎是 `HymnCore` 下新增的独立子模块；
- 现有 `PDFTextExtractor` + `TextChunker` 保留为「快速模式」（纯文本、秒级、有页码的 TXT/DOCX）；
- 「版式重建」作为新模式并行存在，UI 上明确区分耗时与能力，不要让用户以为原来的按钮变慢了；
- 模型侧无需任何改动：翻译接口就是「段落文本 → 段落文本」，占位符协议在调用层拼装；
- 字体文件放 `Resources/Fonts/`，复用现有 `make-app.sh` 的 Resources 拷贝与 ad-hoc 签名流程，不改构建拓扑。
