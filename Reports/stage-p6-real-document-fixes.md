# 阶段报告 P6：真实文档驱动的 PDF 翻译修复

> 日期：2026-11-23/24 · 版本 **0.8.1 build 21** · M3 Pro / 18 GB / macOS 27.0.1 / Swift 6.4.3
> 样本：`Sample/Development of a novel mycelium bio-composite.pdf`（7 页，Elsevier 双栏期刊）
> 触发：「源文件是这个，译文是刚翻出来的，请对比两个文件、针对性修 PDF 翻译功能」

---

## 0. 结论先行

| # | 结论 | 证据 |
|---|------|------|
| C1 | **一页 8 条内容流不是「8 条独立的流」**。生成器把数组留在流 A 末尾、`TJ` 放到流 B 开头，逐流各跑一遍解释器 ⇒ 整行作者单位一个字都读不出来 | 修前 `--runs` 无 y=541.42 的任何 run；修后 40 个 run 齐全 |
| C2 | **分栏检测在期刊首页整页塌成单栏**，段落被切成一行一块、左右栏按 y 交错 | 修前 p1/p5/p6 = 72/105/121 块，其中 66/95/112 是单行块，`column` 全 0 |
| C3 | **长段落撞 KV 窗口后整段回落英文**。531 字符的段落必抛 `SEQUENCE_TOO_LONG` | 修前首轮 180 段译 / 169 段留原文；修后 174/153，且 `failed=0` |
| C4 | **取不到 unicode 的 run 不能丢**：它们没有文字但占宽度，丢了会把一行撕成三块分别送翻译，语序随之错乱 | 「30 cm × 30 cm × 1 cm」修前拆成 3 块、译文变成「30厘米的样品 × 30厘米 × 放置了1厘米」 |
| C5 | **无线表的一列会被当成段落**，数字重排后叠在一起（`0.305/0.126/0.351/0.854` → `0..3531 0.854`） | 新增「表格纵列」钉子规则，三张表的数字与原文逐字节相同 |
| C6 | **替换字体按原推进宽度横向压缩**，否则宋体宽 5~10% 会把词间空隙吃掉（`ExpandedPolystyrene`） | `Tz = clamp(原推进宽度 / 新宽度, 0.8, 1.0)` |
| C7 | 测试 426 → **439 全绿**、release 零警告 | 新增 `pdf-p6` 13 项 |

---

## 1. 怎么对比

1. **逐页渲染**：源文件与译文各渲 7 页（110 dpi），人工逐页看版式；
2. **块框叠加**：`pdf-structure --overlay` 把 IL 块框画回页面上，直接看「一段一框」还是「一行一框」；
3. **run 级诊断**（本次新增）：`pdf-structure --runs` 打印每个 run 的坐标/字体/字号/推进宽度，
   `--dump-content` 导出整页合并后的内容流，`HYMN_TRACE_OPS=1` 打开算子级追踪。

首轮结论就一句话：**版面看起来「翻了一半英文」，但根因不在翻译模型，全在结构提取与排版。**

---

## 2. 根因一：一页多条内容流必须拼成一条逻辑流

Elsevier 的生成器把一页切成 8 条 `FlateDecode` 流，并且**把语句切在操作数与算子之间**：

```
流 434（节选末尾）:  ... (b) Tj  /F3 1 Tf
流 435（开头）:      \n TJ\n/F4 1 Tf ...          ← 数组在上一段的末尾
```

旧实现 `for ref in contentRefs { interpreter.run(data: decoded) }` 逐流跑，
`operands` 是 `run()` 的局部变量，跨流归零 —— 那个 `TJ` 拿到空操作数，什么都不画。

**后果**：`b Centre for Sustainable Manufacturing and Renewable Energy …` 整行消失。
页面渲染完全正常（PDF 阅读器按规范把流当一条拼起来），只有我们的提取缺行。

修法：先按 `PDFTypesetEngine` 的同一规则（不足换行补 `\n`）拼成一条 `Data` 再跑一次，
`streamBase` 归零，`sourceRange` 自然变成「整页口径的绝对偏移」——写入侧驱逐用的也是这套偏移。

```swift
var merged = Data()
for ref in document.contentRefs(of: page) { … merged.append(decoded) … }
interpreter.streamBase = 0
interpreter.run(data: merged, resources: resources, depth: 0, formStack: [])
```

> **教训**：`/Contents` 是数组时，「逐流各跑一遍」在 99% 的文档上碰巧等价，
> 剩下 1% 会精确地把一行字藏起来。规范怎么写就怎么实现。

---

## 3. 根因二：行首 x 聚类的分栏检测整页塌掉

### 3.1 症状

第 1/5/6 页的块数 72/105/121，其中 66/95/112 是**单行块**，且 `column` 全为 0。
渲染出来的译文：一段一行、左右栏互相穿插、「从 Table 3 the, the thermal conductivity…」这种
中英在同一行交替出现的画面。

### 3.2 真因

旧算法按「行首 x」聚簇，要求 ① 每簇 ≥3 行 ② 相邻簇纵向明显重叠，否则 `return singleColumn`。

期刊首页的行首 x 有：页眉 219、标题 38、作者 38、单位 38、ARTICLE INFO 38、摘要 202、
正文左栏 38、正文右栏 307、页码 290。聚类后得到 5~6 个簇，其中只有 2~3 个凑够 3 行；
而摘要那一簇（x≈202，纵向 328–508）与左栏（纵向 49–553）的重叠率只有 31%，
过不了 50% 的门禁 ⇒ **整页判单栏**。判成单栏之后，`shouldBreak` 只能靠行距猜断段，
双栏的行按 y 排序后变成「左一行、右一行」交替，于是每行一个块。

### 3.3 修法：递归 XY 切分

不再猜「栏起点」，而是找**没有任何一行跨过的竖缝**；找不到再找**整幅宽度上都没有行的横向空白带**。
切不动的那一片就是叶子（= 一栏 / 一个独立区域），叶子按递归顺序输出，天然等于阅读顺序。

三个关键细节，缺一个就会退回到旧行为：

1. **竖缝用「覆盖率 ≤ 1」而不是「区间并集有空档」**。
   居中页码（x 290–305）横跨栏缝，并集直接被连成一片，整页再也找不到缝 —— 这是第一个版本失败的原因。
   覆盖率允许「只有一行跨着」，把它当 stray 安置在两栏的上方或下方即可。
2. **横缝也要求整幅无行**。若按「相邻两行间距」去切，左栏的段落空档会正好切在右栏句子中间。
3. **`buildBlocks` 不许再按 `midY` 全局重排**。左右两栏的行处在同一纵向区间，按 y 排就是交错。

```swift
if let (above, left, right, below) = verticalSplit(group, gutter: gutter) { … }
if let (top, bottom) = horizontalSplit(group) { … }     // 只接受整幅空白带
leaves.append(group)                                     // 叶子
```

修后第 2 页：10 个段落块、顺序「左栏读到底 → 右栏」，与源文件一致。

---

## 4. 根因三：长段落撞 KV 窗口 ⇒ 整段回落英文

`SherryGenerator.generate` 里原本是硬门禁：

```swift
guard promptIDs.count + maxTokens <= model.maxSeq else { throw SEQUENCE_TOO_LONG }
```

而 `PDFRebuildPipeline` 给的 `maxTokens = max(160, min(1024, source.count * 3))`：
一段 531 字符的正文，提示词约 330 token，330 + 1024 > 1024 ⇒ 直接抛错 ⇒
`map` 里没有这一段的译文 ⇒ 排版回落到「保留原文」。**这就是「一页翻了一半」的直接原因。**

三处一起改：

| 位置 | 改动 | 理由 |
|------|------|------|
| `SherryBackend.prepare` | `maxSequenceLength` 1024 → **2048** | KV 从 4 MB 到 8 MB、threadgroup 从 8 KB 到 16 KB（上限 32 KB），代价可接受 |
| `SherryGenerator.generate` | 硬门禁 → **按剩余窗口截断**，并置 `metrics.hitTokenLimit` | 调用方给的是「希望生成多少」，不是「确定放得下多少」；硬抛只会让整段回退 |
| `PDFRebuildPipeline` | 超长段落**按句切分**（`PDFSentenceSplitter`，跳过 `Fig./Eq./et al.` 缩写） | 1500 字符以上的段落仍可能溢出；切分后每段都稳稳放得下 |

> 截断仍然可能发生，所以 `hitTokenLimit` 如实上报，而不是把半截译文当完整译文。

---

## 5. 根因四：空文本 run 把一行撕成三块

源文件「Samples of dimension 30 cm × 30 cm × 1 cm」里的 `×` 用的是子集字体 `AdvP4C4E74`，
它的 `/ToUnicode` 把该字形映射成 **U+0020**（空格）—— 渲染是 `×`，提取是空格。
旧代码 `runs.filter { !$0.text.isEmpty }` 直接丢掉这类 run。

丢掉的不只是字符，还有**它占的宽度**：`segmentEnd` 不推进 ⇒ 与下一个 run 之间凭空多出 12pt 间隙
⇒ 超过 1.6em 的切分阈值 ⇒ 同一行被切成三段，各自送去翻译。

修法两条：

1. 除文字以外的 run 保留在几何计算里（`usable = runs.filter { $0.advance > 0.01 }`），
   只丢它的文字；
2. 顺带修另一个同类问题：**上标**。作者的 `a`/`b` 基线比正文高 5pt、字号 4.25，
   `0.32em` 的基线容差必然把它判成独立行 ⇒ 独立块 ⇒ 中文重排后上标留在原位、和名字脱开。
   新增 `mergeInlineFragments`：基线差 ≤1.2em 且竖直重叠 ≥30% 且水平间距 ≤1em 就并回本行
   （表格里并排的单元格间距远大于 1em，不会被误合）。
   落在长行**内部**的上标（作者名中间的 a/b）不合并——判据要求两段水平前后相邻；
   它们作为单字符块钉在原位、原字形重画，位置不丢，只是不参与重排。

---

## 6. 根因五：无线表的一列被当成段落，数字叠字

`PDFTableDetector` 只认有框线的表。Table 2/4/6 靠空白对齐（无线表），
它的一列被行归并成**一个普通段落块**：表头 2 行 + 4 个数值。
送去翻译再按段落重排，数字被当正文连排：

```
修前： 0.305  0.126          ← 两行数值压成一行
       0..3531 0.854         ← 「0.351」和「0.854」重叠
修后： 0.305 / 0.126 / 0.351 / 0.854   ← 与源文件逐字节相同
```

新增钉子规则 `isTabularStrip`：≥3 行、每行 ≤32 字符、数字字符数 ≥ 字母数的行占一半以上。
命中就**原地不动**（原文留在内容流里，一个字节不改）。逻辑和代码块一致：
**数字排错比不翻译糟得多。**

---

## 7. 根因六：原坐标重画时，宋体更宽，词间空隙被吃掉

`drawRuns` 按自然宽度画，思源宋体比原字体宽 5~10%，右边界顶进下一个词：

```
源：  Expanded(347.36–377.07)  Polystyrene(379.22–414.59)   间隙 2.15pt
旧：  Expanded(347.36–378.87)  Polystyrene(379.22–416.26)   间隙 0.35pt  ← 看起来粘连
新：  Tz 把每个 run 压回原推进宽度，间隙仍是 2.15pt
```

```swift
let target = max(1, run.advance)
let horizontalScale = min(1, max(0.8, target / max(width, 0.01)))
```

只收不放，下限 0.8（收得更狠就不像话了）。

---

## 8. 实测

| 指标 | 修前 | 修后 |
|------|------|------|
| 已译 / 保留原文（7 页全量） | 180 / 169 | **179 / 159** |
| 翻译失败段数 | 0 | 0 |
| 第 1 页块数 / 单行块 | 72 / 66 | 31 / 21 |
| 第 2 页块数 / 单行块 | 14 / 3（但分组错乱） | 16 / 5 |
| 第 5 页块数 / 单行块 | 105 / 95 | 62 / 44（含表头单元格） |
| 第 6 页块数 / 单行块 | 121 / 112 | 67 / 56（含表头单元格） |
| 无译文时输出 | 逐字节相同 | 逐字节相同（`cmp` 通过） |
| 自检 findings | `glyph-missing=3`（含 1 处假缺字 U+000A） | `glyph-missing=2`（仅 ⇑，思源宋体无此字形） |
| 测试 | 426 | **439 全绿**、零警告 |

逐页人工确认（110 dpi）：第 1–7 页**没有英文正文残留、没有中英同行交替、没有叠字**；
图片与图表 100% 保留（`pdf-verify` 12 张图字节逐一相同）；作者单位 b 行回来了；
表格数字与原文一致；表头 `Sample` / `Table 2` 这类窄框单元格现在会被翻译。
产物：`Sample/…-译文-修复版.pdf` 与 `Sample/…-对照报告.html`。

---

## 9. 仍然存在的问题（不粉饰）

| 问题 | 说明 | 建议 |
|------|------|------|
| 参考文献被翻译 | 第 7 页 22 条参考文献全部译成中文，期刊名被意译（`阿拉伯科学工程杂志`），作者名保留拉丁 | 是否「参考文献保持原文」是产品决策；若要，加一条 `isReferenceEntry` 钉子规则即可 |
| `ARTICLE INFO` → `第1条` | 模型对版式小标题的误译 | 需要术语表命中（`GlossaryMatcher` 已有，但 PDF 链路没接） |
| 无线表未被识别成表格 | 数字安全了（钉子），但表头仍是英文 | 需要 `PDFTableDetector` 支持无框线表的列推断 |
| `⇑`(U+21D1) 缺字 2 处 | 思源宋体无此字形，报告标 `glyph-missing` | 装饰符号，语义无损；可在子集化时降级替换 |
| 「3. 结果与讨论 3.1. 声阻抗测试」并成一个块 | 两个小标题行距过近，`shouldBreak` 未断 | 字号/加粗一致时难以区分，属可接受 |

---

## 10. 改动清单

**HymnCore/PDF**
- `PDFTextExtractor.swift`：多内容流拼接后单次 `run()`；控制字符不当作字形；`HYMN_TRACE_TEXT/OPS` 调试钩子
- `PDFLayout.swift`：`detectColumns` 改为递归 XY 切分（覆盖率找缝 + stray 安置）；`buildBlocks` 不再按 `midY` 重排；`buildLines` 保留空文本 run；新增 `mergeInlineFragments`
- `PDFSentenceSplitter.swift`（新）：按句切分，缩写保护
- `PDFTypesetEngine.swift`：`isTabularStrip` 钉子规则 + 统计字段 `pinnedTabular`；`isPinned` 不再把「窄框但是真文字」的表头单元格当碎片；`drawRuns` 按原推进宽度横向压缩
- `PDFTypesetter.swift`：排版前把译文里的换行/制表折叠成空格（否则会被当成字形，报假缺字）
- `PDFTableDetector.swift`：格内词距阈值 0.6em → 0.25em（与 `makeLine` 一致）

**HymnSTQ**
- `SherryBackend.swift`：`maxSequenceLength` 2048；按剩余窗口收敛 `maxTokens`
- `SherryGenerator.swift`：`SEQUENCE_TOO_LONG` → 截断 + `hitTokenLimit`
- `SherrySampling.swift`：`GenerationMetrics.hitTokenLimit`

**HymnApp**
- `PDFRebuildPipeline.swift`：超长段落按句切分后再译（非 CJK 目标语用空格连接）

**hymnctl**
- `PDFCommands.swift`：`pdf-structure --runs / --dump-content` 诊断输出

**测试**
- `PDFP6Tests.swift`（新，13 项）：跨流数组 + `TJ`、单流基线、双栏 + 跨缝页码、单栏不误切、
  上标并回本行 / 行内上标保持独立、空文本 run 保住整行、表格单元格不误合、
  句子切分三条、控制字符折叠

## 交付与安装（0.8.1 build 21）

打包链路是 `Scripts/make-app.sh`，**它拷的是 `.build/debug/HymnTranslate`**，不是 release。
所以只跑 `swift build -c release` 不足以更新用户实际打开的 App。

本次重新交付：
```
swift build --disable-sandbox          # debug，8274768 B，零警告
./Scripts/make-app.sh                  # FONTS_EMBEDDED 28M + MODEL_EMBEDDED 450M → dist 487 MB
rm -rf /Applications/LinguaNova.app && cp -cR dist/LinguaNova.app /Applications/
```
校验：`CFBundleShortVersionString=0.8.1` / `CFBundleVersion=21`；
`nm | swift-demangle` 在 `/Applications` 的二进制里能找到 `isTabularStrip`、`mergeInlineFragments`、
`PDFSentenceSplitter.chunks`、`pinnedTabular`；ad-hoc 签名有效；启动正常。

⚠️ ad-hoc 重签会让 TCC 的辅助功能授权失效，划词翻译需在系统设置里重新勾选一次。

### 版本号漂移（build 21 修）

`AppBrand.version` 原来是硬编码 `"0.7.12"`，与打包脚本的 `CFBundleShortVersionString` 各自为政，
于是出现「包是 0.8.1、设置页关于卡片还显示 0.7.12」。修法两层：

1. 运行时**以 Info.plist 为唯一来源**（`Bundle.main.object(forInfoDictionaryKey:)`），
   只有裸可执行文件（`.build/debug/HymnTranslate`）才回退到 `AppBrand.fallbackVersion`；
2. `make-release.sh` 新增 **2b/8 版本一致性** 步骤，校验 `AppBrand.fallbackVersion`、
   `make-app.sh VERSION`、本脚本 `VERSION` 三者相等，不等直接 `exit 10` 中断发布。

实测：`/Applications` 二进制中 `0.7.12` 出现 0 次、`0.8.1` 出现 1 次；设置页关于卡片显示「版本 0.8.1」。

### 完整发布链路（`Scripts/make-release.sh`，8 步全过，59s）

| 步骤 | 结果 |
|---|---|
| 1 构建 | BUILD_OK（debug，零警告） |
| 2 全量测试 | `# pass 439  fail 0` |
| 3 图标 | ICON_OK |
| 4 组装 .app | 487 MB（模型 450M + 字体 28M） |
| 4b 字体校验 | 两个 TTF SHA-256 与锁定值一致，OFL.txt 在位 |
| 5 运行时自检 | `ready=True`，`gguf=461860800 B`，`tensors=354`，offline=True，STQ1_0 1.3125 bpw |
| 6 真机冒烟 | 真实推理 `你好，很高兴见到你。`；划词链路 `en->zh` 与主窗口译文一致；主线程 tick max 22.86 ms |
| 7 合一包校验 | 用 `-hymn.modelDirectory /nonexistent-model-dir` 强制走内置模型，仍能真实推理 |
| 8 DMG | `dist/LinguaNova-0.8.1.dmg`，483,871,938 B（461 MB） |

DMG SHA-256：`aafc3f9ffc1241cda37b1989ab41cddc5e742f0c9a99b8c8fefc53c1c0061607`
挂载校验：卷内 `.app` 版本 0.8.1，二进制含 `isTabularStrip` / `mergeInlineFragments` / `PDFSentenceSplitter`。

