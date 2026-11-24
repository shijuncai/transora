# 阶段报告 P7：图表不翻译 + 段落被上标切碎

> 日期：2026-11-24 · 版本 **0.8.3 build 23** · M3 Pro / 18 GB / macOS 27.0.1 / Swift 6.4.3
> 样本：`Sample/An evaluation study of mycelium based.pdf`（6 页，Elsevier 双栏）
> 触发：用户给了源文件 + 译文，两边都做了标注，指出两类错误——
> ① 图表的 x 轴 / y 轴与图内文字被翻成乱码；② 有几段译文「前后有中文、中间留白」。

---

## 0. 结论先行

| # | 结论 | 证据 |
|---|------|------|
| C1 | **期刊里的图表是矢量绘图，不是位图**。`ILPage.figures` 只收 XObject Image，这 5 张图一张都识别不到，图里的文字被当正文送进模型 | `pdf-structure --page 4` 输出 `figures=0 charts=0`（修前） |
| C2 | 修法是从「笔触密度」反推图区：把每一条 `re`/`m l`/`c` 路径的包围盒聚类，够密、够大就判为图表，再外扩吞进坐标轴标题与图例 | 修后 p3 = 2 个图区、p4 = 3 个图区，图内 16/146 个块全部保持原文 |
| C3 | **上标 `g/cm³` 的「3」把一段话切成三块**，分别翻译再排版 ⇒ 视觉上「中间缺一段」 | 修前 p5 出现 `b5=…The mean` / `b6="3"` / `b7=density of…` 三块；修后并为一段 |
| C4 | **词间空格阈值 0.25em 太严**。这篇正文用 GulliverRM，space 只有 0.19em ⇒ 整段粘成 `Inlookingattheperformance`，模型据此吐出「灯光wassetupat90和」 | `--runs` 实测词距 1.51pt @ 8pt；阈值改为 0.15em |
| C5 | **整页重排（reflow）会把「没参与重排的块」一起驱逐**，所以钉住的图表文字、公式、页眉、上标会被静默删掉 | 修前 p5 页眉与两个「3」在输出里完全不存在（`--runs` 查无） |
| C6 | 公式块被当句子翻译（`Swr = Pmaxima` → 「Swr = 最大值 … 皮米纳」），按「短、带关系符、行少」钉住 | 修后 (1)(2)(3) 保持原样 |
| C7 | 测试 439 → **460 全绿**、release 零警告 | 新增 `pdf-chart` 21 项 |

---

## 1. 用户标注里到底错在哪

译文 PDF 上的高亮标注：

| 位置 | 译文里看到的 | 原文应该是 |
|---|---|---|
| p3 Fig.1 纵轴 | `t 1000.0 你O d 800.0 era u s 600.0 a 我 400.0` | `Measured Output` + 刻度 `1000.0…` |
| p3 Fig.1 图例 | `最大振幅（伏特）630 640 635 625 0` | `Maximum Amplitude (Volts)` |
| p3 公式 (1)(2) | `Swr = 最大值 … 皮米纳 = (Swr +1)` | `Swr = Pmaxima / Pminima`、`Γ = (Swr+1)/(Swr+1)` |
| p4 Fig.4 整图 | `我曾经是 / 拉贝伊维埃伊维阿什贝希 / 哇，超级英雄` | 24 个竖排品种名（`Coating line`、`Uncoated paperboard 1.5 mm` …） |
| p5 正文 | `从各种混合物的表现来看…平均值` ⏎ 空 ⏎ `3` ⏎ `板子的密度被发现为0.340克/厘米` | 一句话被切成三段 |
| p5 正文 | `灯光wassetupat90和` | `lighting was set up at 90 and` |

---

## 2. 根因一：图表是矢量，`figures` 只收位图

`PDFStructureBuilder` 里 `page.figures = content.images`，而 `content.images` 只在 `Do` 碰到
`/Subtype /Image` 时才追加。期刊的折线图/柱状图由几百条 `m l`、`re`、`c` 画成，**一个 image 都没有**，
于是 `figures` 为空，图内文字（刻度、轴标题、图例、竖排品种名）就按普通段落走了 P2 → P3 全流程：
逐块翻译 → 在各自的原始小框里重排 → 叠字、串行、乱码。

### 2.1 修法：从笔触密度反推图区

新增 `HymnCore/PDF/PDFChartDetector.swift`，并在 `PDFTextExtractor` 里顺带收集「每条被描边/填充
路径的包围盒 + 点数」（`PDFPaintedPath`，与表格用的 `PDFPathSegment` 分开——后者只留横竖线，
正好把图表的斜线全滤掉）。

判定流程：

1. 过滤整页底色（面积 > 55% 页）、通栏细线（宽 > 85% 页且高 < 8）；
2. 包围盒按 7pt 外扩后相交即并查集合并成一簇；
3. 一簇满足「独立路径 ≥ 8 条（柱状图每根柱子一条）」**或**「端点总数 ≥ 60（折线图一条曲线几百个点）」，
   且尺寸 ≥ 80×50pt，才算图表；
4. 用已识别的**表格框**排除：与表格重叠超过 45% 的簇是网格，不是图表；
5. 外扩：左 20（竖排轴标题常贴在绘图区外面）、右 12、下 18、上 10。

诊断：`pdf-structure --overlay` 现在用**绿色**画图表区（橙色是位图、红色是块、蓝色是表格），
`--json` 多一个 `charts` 数组，`HYMN_CHART_DEBUG=1` 打印每簇的成员框。

---

## 3. 图内文字怎么钉、钉到什么程度

`PDFTypesetEngine` 新增判定，命中就不参与排版（原字节、原字体、原位置一个不动）：

- ① **整块落在（外扩 12pt 的）图区里** —— 刻度、轴标题、图内标注；
- ② **贴在绘图区侧边的单行短标签**（≤ 48 字、高 ≤ 16pt、不以句号收尾、水平距离 ≤ 40pt）——
  图例常排在右边框外面（真实样本差 13pt）；
- 例外：**图注**（`Fig. 3. …` / `Table 2 …`）仍然翻译，它是给人读的句子。

同时 `PDFRebuildPipeline` 在翻译阶段也用同一个判定跳过推理：p4 那张柱状图的 98 个品种名
以前要跑 98 次推理（结果还被丢掉），现在直接不送。

---

## 4. 根因二：上标碎片把段落劈成三块

`PDFParagraphBuilder.shouldBreak` 里「字号差 > 1.5pt 就断段」是为了分开标题与正文，
但 `g/cm³` 的「3」是 6pt、正文 8pt，于是：

```
… board density. The mean        (2 行，1 块)
3                                (碎片，1 块)
density of the entire set …      (1 块)
3                                (碎片，1 块)
a standard deviation of ±0.066 … (1 块)
```

五块各翻各的，排版后每块都从自己框的顶边开始 ⇒ 「前后有译文、中间空一段」。

修法：新增 `isFragmentLine`（≤ 2 字符、无字母；纯数字还要求字号 < 7.4pt）与 `isAdjacent`
（纵向中心距 ≤ 1.4em、横向有重叠）。命中时不进入段落、也**不打断**段落，而是单独成块（后续按碎片钉住）。
`mergeInterleaved` 也跳过纯碎片块，否则它会把碎片重新并回段落。

---

## 5. 根因三：词间空格按 0.25em 判，把整段粘死

`PDFLineBuilder.makeLine` 原来用 `gap > 0.25 * fontSize` 才补空格。这个阈值是按 Times 的
space = 0.25em 拍的，但这篇正文的 GulliverRM space 只有 **0.19em**（1.51pt @ 8pt），
于是整段变成 `Inlookingattheperformanceofthevariousmixtures`。

模型拿到没有词界的输入，译文就出现「灯光wassetupat90和」这种夹生（它认出了 lighting、set up、
90，但拼不回句子）。阈值改为 `max(0.15em, 0.6pt)`：能分开 0.19em 的正常词距，
又不会把同一单词内字体切换（间距 ≈ 0.2pt）误判成两个词。

---

## 6. 根因四：整页重排把「没参与重排的块」一起删了

`PDFTypesetEngine` 里有一段：

```swift
// 页被整页重排（reflow）时例外：所有块都换了位置，必须全部驱逐重画。
if !pageReport.reflow { …默认全保留、只扣掉要重画的… }
```

`else` 分支没有：`keepRanges` 为空 ⇒ `TextEvictor.evictText(from:)` **删掉整页所有文本算子**，
然后只画 reflow 的计划。以前 reflow 拿到的是**全部块**，所以每个块都进了计划、都能画回来；
这一轮为了不让图内文字被重排，我把钉住的块和页眉页脚从 reflow 输入里剔除了——
于是它们被驱逐、没人画回来，页眉、`g/cm³` 的「3」直接消失。

修法：reflow 页也保留「不参与重排的块」的算子：

```swift
if pageReport.reflow {
    var keepRuns = Set<Int>()
    for block in work.page.blocks where keepsOriginal(block, page: work.page)
        || isRunningHeadOrFoot(block, page: work.page) {
        for line in block.lines { for span in line.spans where span.runIndex >= 0 { keepRuns.insert(span.runIndex) } }
    }
    for index in keepRuns.sorted() { …keepRanges.append(range)… }
} else { …原有增量逻辑… }
```

同时把「页眉页脚」正式定义为**贴页面上下 55pt 的单行短文本**：它们不参与重排
（否则 running head 会被当成正文推进流里，跑到页面中间、压在图上）。

---

## 7. 根因五：公式被当句子翻

`S_wr = P_maxima / P_minima (1)` 这类块里有字母，模型会把变量名当单词：
`Pminima` → 「皮米纳」。判据（`isFormulaBlock`）：

- 必须含 `=` / `≈` / `≤` / `≥`；
- 且「≤ 40 字且块高 ≤ 26pt」（独立公式行），或「符号占比 ≥ 22% 且字母占比 ≤ 55%」（多行推导）。

命中即保持原文。正文里带等号的句子（6 行、100+ 字）不会命中。

---

## 8. 验证（v0.8.3 build 23）

| 项 | 结果 |
|---|---|
| 构建 | `BUILD_OK` 零警告 |
| 测试 | **460/460**（原 439 + 新增 `pdf-chart` 21 项） |
| 发布链路 | 8 步全绿：`VERSION_OK 0.8.3`、字体 SHA、verify READY、真译、划词 `en->zh`、`BUNDLE_MODEL_OK` |
| 产物 | `.app` 487 MB、`dist/LinguaNova-0.8.3.dmg` 461 MB（483,898,076 B）<br>SHA-256 `c5e887ec5a444fc66e82a5eeec999f86238e7527a9d9442ef0ee83c24dbc967d` |
| 真实样本（6 页全量） | `translated=132 kept=396 failed=0`；自检 `glyph-missing=2`（`⇑` 缺字）、`text-overlap=1` |
| 图区识别 | p3 = 2 个、p4 = 3 个；p3 钉 32 块、p4 钉 146 块（含 24 个竖排品种名与 3 组图例） |
| 图内文字 | Fig.1/2/3/4/5 的刻度、轴标题、图例、竖排标签全部**英文原位**，无乱码、无叠字 |
| 图注 | `Fig. 3.` / `Fig. 4.` / `Fig. 5.` 仍翻成中文（设计如此） |
| 段落完整性 | p5「In looking…The mean」+「density…g/cm3 with」并为一段；p4「One of the primary…」不再被 `◦` 切断 |
| 词间空格 | `In looking at the performance of the various mixtures` |
| 公式 | (1)(2)(3) 原样保留（`Swr = Pmaxima / Pminima`、`Γ = (Swr+1)/(Swr+1)`、`α = 1 − Γ²`） |
| 页眉 | `M.G. Pelletier et al. / Industrial Crops and Products 51 (2013) 480–485` 与页码 `484` 在顶部原位 |
| 截图 | `Reports/pdf-v083-p3-charts.png`、`pdf-v083-p4-charts.png`、`pdf-v083-p5-paragraphs.png` |
| 成品 | `Sample/An evaluation study of mycelium based-修复版.pdf`（1,850,787 B） |

---

## 9. 仍然存在的问题（不粉饰）

| 问题 | 说明 |
|---|---|
| 重排页段落间距偏大 | p5 被整页重排（≥2 段连下限字号都放不下），个别段之间会多出 30–50pt 空白；报告里标 `needsReview`。这是 reflow 的已知限制，不是丢字 |
| 孤立的上标数字 | `g/cm³` 的「3」按原字节留在原位，而中文正文已写成「克/厘米」，于是页面上可能看到一个孤立的小「3」。丢字比多一个上标更糟，所以选择保留 |
| `text-overlap=1` | 自检仍报 1 对块矩形相交（与 v0.8.1 同一处），未在本轮修 |
| `⇑` 缺字 2 处 | 思源宋体无此字形，装饰符号，语义无损 |
| 只认矢量图表 | 位图截图里的文字本来就没有文字层；表格按老规矩仍翻译（用户只要求图表不动） |
| 图表识别的边界 | 判据是「笔触密度 + 尺寸」，散点很少的极简示意图（< 8 条路径且 < 60 点）可能漏判；漏判的后果是那张图的文字被翻译，不会丢字 |
| 图注内如果有图例说明 | 图注整段仍会翻译（它是以 `Fig.` 开头的句子）；若图注里混了化学式，仍可能被译坏 |
