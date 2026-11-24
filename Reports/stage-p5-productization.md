# 阶段报告 P5：产品化

> 日期：2026-11-23 · 版本 0.8.0 (build 19) · M3 Pro / 18 GB / macOS 27.0.1 / Swift 6.4.3
> 目标：把 P0–P4 的「能跑通」变成「能交付」——**渲染判据修对、只动该动的字节、去掉旧字节、
> 逐段可对照、App 里点得下去**。

---

## 0. 结论先行

| # | 结论 | 证据 |
|---|------|------|
| C1 | **P4 那条「IL 坐标偏 80pt」的结论是错的**。根因是渲染器不缩放 + 叠加图画错，IL 本身一直是准的 | 修好后同一页 R1 结构丢失 `3393 → 0`；IL 框 / PDFKit 框 / 渲染墨迹三者 1px 内吻合 |
| C2 | **不译的东西一个字节都不动**：全篇没有译文时，输出与原文件**逐字节相同**（`+0` 字节） | `pdf-typeset` 输出 `+0`；`cmp` 通过 |
| C3 | **未译区域逐像素相同**：抽样 20 页掩膜覆盖率 `0.000`，R1 差异 `0`，R2/R3/R4/R7 全 `0` | `p5-evidence.json → untouchedPages` |
| C4 | 洗版能真的删掉旧字节，且图片不变：14.54 MB → 增量 16.87 MB → **洗版 15.94 MB** | `pdf-verify`：533 张图字节逐一相同，`VERIFY_PASS` |
| C5 | 真实模型端到端跑通（App 进程内）：169 页英文书，8 段译，**未译页逐像素相同** | `HYMN_PDF_REBUILD` 冒烟 + `pdf-diff` |
| C6 | 测试 413 → **426 全绿**、release 零警告 | `hymntest` |

---

## 1. 先修尺子：渲染器根本没有缩放

### 1.1 现象与真因

P4 的收尾把幻灯片页（`960×540`）的 R1 失败记成了「P2 的 CTM 追踪有缺陷，IL 框偏高 80pt」。
P5 复查时用 PDFKit 的 `selection.bounds` 做几何 oracle，发现 **IL 与 PDFKit 完全一致**：

```
IL 标题框       (29.6, 465.6) - (495.7, 521.1)
PDFKit 选择框   (29.7, 465.6) - (495.7, 521.1)
渲染墨迹行带    y 472 … 514
```

继续追，发现三件事叠在一起：

1. **`CGPDFPage.getDrawingTransform(..., preserveAspectRatio:)` 在 macOS 27 上不缩放。**
   传 1920×1080 的目标矩形，返回的是 `a=1, tx=480, ty=270` —— 页面被 **1:1 画在画布正中**。
   而 `pixelX/pixelY` 一路按 `dpi/72 = 2` 换算。后果：位图尺寸对、内容位置全错一倍，
   掩膜、坐标探针、裁剪图全部错位。`preserveAspectRatio` 传 `true` 还是 `false` 结果一样。
2. **`pdf-structure --overlay` 把框画成了细线。** CG 原点在左下，代码把 `yTop` 当底边用，
   `height` 算成负数被 `max(0.5, …)` 兜住 —— 于是所有框都退化成一根横线，
   看起来就像「框整体偏上」。
3. **我的两个临时诊断工具抄了同一个坏掉的 API**，于是「独立印证」了错误结论。

修法：自己构变换，不再依赖那个 API。

```swift
// shift(-MediaBox 原点) → rotate(/Rotate) → scale(dpi/72)
let transform = shift.concatenating(spin).concatenating(zoom)
context.concatenate(transform)
context.drawPDFPage(page)
```

`/Rotate 90/180/270` 也一并按公式处理（`(x,y) → (v, w-u)` 之类），不再靠「旋转页跳过检查」兜着。

**教训写进代码注释**：像素级判据有两个输入——渲染和 IL，其中渲染器是我们自己写的，
几何对不上时应当先怀疑尺子。

### 1.2 新增的断言（P4 漏掉的那条）

P4 有 `render-size-a4`（断言位图 1190×1684）——画布尺寸对，内容错位一倍，它照样通过。
P5 改成**画一个已知矩形再把墨迹位置读回来**：

| 用例 | 断言 | 实测 |
|---|---|---|
| `render-content-scale` | 矩形 `(100,100)-(300,200)` 渲染后墨迹落在同处（±2pt） | `(100.0,100.0)-(300.0,200.0)` |
| `render-scale-invariant` | 72dpi 与 144dpi 的页面坐标一致 | 两者 `x0 = 100.0` |

---

## 2. 只动该动的字节：选择性驱逐

### 2.1 从「整页驱逐」到「按区间驱逐」

P3/P4 的写法是：删掉整页所有 `Tj/TJ/'/"`，再把**要保留的原文也重画一遍**。
后果是每一页都换字体、每一页都重排——代码块从等宽字体变成 14pt 宋体，行宽全变、缩进对不上；
没有译文的段落也被重画，白白引入差异。

现在给每个 `PDFTextRun` 记两样东西：

- `sourceRange`：产生它的那个算子在**整页内容流**（多流拼接后）里的字节区间；
- `runIndex`：它在 `content.runs` 里的下标，并通过 `ILSpan.runIndex` 一路带到块/行/span。

驱逐器换成「保留区间」语义：`evictText(from:keeping:)`，区间重叠就整段留下。

### 2.2 默认全保留，再扣掉要重画的

第一次实现是「挑出要保留的」（按块 → span → run）。实测在 409 页书的第 337 页上，
**51 个块里 24 个文本算子被静默删掉** —— 那些是没进任何 span 的 run（行首空格、
被行归并丢掉的重叠字），代码块的缩进因此整段消失。

所以反过来写：

```
keep ← 全部 run
keep −= 要重画的块的 span 里的 run
keep −= 要重画的单元格里的 run（按中心点归属）
reflow 页例外：keep ← ∅（所有块都换位置了）
```

再加一条兜底：一个 `TJ` 数组里的多个 run 共用同一个算子区间，若这区间里有要重画的 run，
保留就留不住 —— 此时把同区间的其它 run 按原坐标重画一份，宁可多画不丢字。

### 2.3 没改动的页连一个字节都不写

```
if evicted.removedRuns == 0 && plans.isEmpty && cellPlans.isEmpty &&
   fixedRuns.isEmpty && notes.isEmpty { 保持原样，continue }
```

全篇都没有需要改动的页时，直接返回**原文件字节**（`report.unchangedDocument = true`）。

| 场景 | 输入 | 输出 | 结果 |
|---|---|---|---|
| 409 页中文书，无译文 | 14,543,658 B | 14,543,658 B | `+0`，`cmp` 逐字节相同 |
| 同一份书，伪译文全译 | 14,543,658 B | 16,873,010 B | 见 §4 |

### 2.4 掩膜只覆盖「真的被驱逐的文本」

P4 的掩膜把整页所有 run 的框都遮住了 —— 等于自己放水。现在 `layout.removedText`
只包含被驱逐的 run 与被重画的块：

| 指标（409 页书抽 20 页，恒等） | P4 | P5 |
|---|---|---|
| 掩膜覆盖率 | 0.374 | **0.000** |
| R1 掩膜外差异 | 0 | 0（但掩膜为空，含义强得多） |
| 结构丢失 | 0 | 0 |

换句话说：**没译的页，整页逐像素不变**，这句话现在是被证明的，不是被掩膜掩盖的。

---

## 3. 洗版（scrub）：把旧字节真的删掉

增量写入只追加，好处是「没改的对象物理不可能变」，代价是被替换的原文仍然留在文件里
——xref 不再引用它，常规工具读不出来，`strings` 和取证工具照样能看到。对翻译工具这是隐私问题。

`PDFScrub.rewrite(document:overrides:)`：从 `/Root`、`/Info` 做可达性遍历，只写活对象，
流的 `raw` 字节原样搬运（只重算 `/Length`、重排字典键），再写传统 xref 与 trailer。

| 指标 | 数值 |
|---|---|
| 输入 | 14,543,658 B |
| 增量输出 | 16,873,010 B（+2,329,352） |
| 洗版输出 | 15,943,586 B（+1,399,928） |
| 洗版相对增量 | **−929,424 B（−5.5%）** |
| 页数 | 409 → 409 |
| 图片对象 | 533 张，**原始字节逐一相同** |
| 洗版前后渲染 | 抽样 1/3/100/200/409 页，0 像素差异 |
| `pdf-verify` | `VERIFY_PASS` |

---

## 4. 逐段对照报告

单语同版式的成品里**原文已经不存在**：用户校对时没法左右对照，出了错也分不清是译错还是排错。
`PDFComparisonReport` 把原文补回来，并逐段标注处理结果：

- 每页一个可折叠区，三列：原文 / 译文 / 处理（`已译` `保留原文` `未改动` `有溢出` `缺字`）；
- 处理列带块 id 与具体说明（「缩至 6.8pt」「3 行挪到页脚注」）；
- 单文件 HTML、内联样式、可直接打印；同时可导出 `linguanova.compare/1` 的 JSON 给流水线。

CLI：

```bash
hymnctl pdf-report in.pdf out.html --translations map.json --pdf out.pdf --json out.json
```

App 里则是「版式重建」模式跑完后的一等入口（见 §5）。

---

## 5. UI 接入：PDF 页的第二种模式

`PDF 长文本翻译` 页现在是两个模式共用一个「选择 PDF」：

| 模式 | 产物 | 适用 |
|---|---|---|
| 纯译文（TXT / DOCX） | 只保留文字 | 需要二次编辑 |
| **版式重建（PDF）** | 译文写回原位置、逐段对照报告 | 需要「看起来还是原来那份文件」 |

流水线 `PDFRebuildPipeline`：

```
解析版式 → 逐段翻译（串行，段边界可取消）→ 写回版式 → R1–R7 自检（长文档抽样）→ 生成报告
```

要点：

- **重活全在后台**：结构解析、排版、两次 144 dpi 渲染都跑在 `Task.detached`，
  主线程只消费进度事件（`AsyncStream`），每段刷一次。
- **取消**：`PDFRebuildCancelFlag`（带锁的布尔），段边界生效；已完成的段落**不写盘**，
  避免产出半成品。
- **长文档自检抽样**：>80 页时步长取 `页数/40`，既覆盖全篇又不让自检比排版还慢。
- **输出位置**：源文件旁边 `名字-译文.pdf` / `名字-对照报告.html`；不可写则退到「文稿」。
- **字体随包**：`make-app.sh` 把两份 TTF 与 `OFL.txt` 放进 `Contents/Resources/Fonts/`（28 MB），
  `PDFRebuildPipeline.fontURLs()` 依次找包内 → `HYMN_FONT_DIR` → 工作目录。

headless 冒烟（真实模型、真实 App 进程）：

```bash
HYMN_HEADLESS_SMOKE=1 HYMN_SHERRY_MODEL_DIR=Models/Hy-MT2-1.8B-1.25Bit-GGUF \
HYMN_PDF_REBUILD_PATH=sample.pdf HYMN_PDF_REBUILD_BLOCKS=8 \
  dist/LinguaNova.app/Contents/MacOS/HymnTranslate
```

```
HYMN_PDF_REBUILD pages=169 translated=8 kept=2080 failed=0 pdf_bytes=15044273
                 passed=true codes=[] font=LinguaNovaSong-Regular.ttf
HYMN_SMOKE_OK ready=true real=true
```

同一份文件逐页比对：**第 4 页往后 0 像素差异**（没有任何译文落到那些页），
第 3 页标题页译文（`The Python Workbook` → `Python工作簿`）落在原位置，横线（矢量）未动。

> 说明：本次会话没有完成「App 窗口截图」的验证——启动时系统弹出了「访问文稿文件夹」的
> 授权框，而本会话没有自动化权限去点它。窗口本身被创建过（窗口列表里出现过
> `智译星 LinguaNova — 本机 AI 翻译` 1080×748），代码路径由冒烟验证；**UI 的视觉验收仍需人工看一眼**。

---

## 6. 实测（release，M3 Pro）

### 6.1 恒等（没有译文）

| 指标 | 409 页书抽 20 页 |
|---|---|
| 输出 vs 输入 | **逐字节相同（+0 B）** |
| R1 掩膜外差异 | 0（掩膜覆盖率 0.000） |
| R2 / R3 / R4 / R7 | 0 / 0 / 0 / 0 |
| 版面 SSIM | 均值 0.9997，最低 0.9989 |
| 排版 | 2.70 s / 409 页（6.6 ms/页） |
| 分析 | 51.5 ms/页（两次 144 dpi 渲染） |

### 6.2 伪译文闭环（40 页，每段凭空加 11 字，比原文长 ~30%）

| 轮次 | 检查页 | 错误 | 修复指令 |
|---|---:|---:|---:|
| 0 | 40 | 25 | 24 |
| 1 | 11 | 7 | 7 |
| 2 | 3 | 7（修不动，转人工） | 0 |

终态：R1 72 像素（40 页合计，均在译文行末新增字形边缘）、R2 4 处、R3 **0**、R4 **0**、
R5 3 处（真放不下）。**8 页修好**（5/10/26/27/31/36/37/39），3 页转人工（17/33/34）。总耗时 4.16 s。

### 6.3 洗版

见 §3 表格。

---

## 7. 已知边界

| 限制 | 影响 | 归属 |
|---|---|---|
| 洗版后文件不再与原文件逐字节对齐 | 流字节不变，但对象顺序重排；想逐字节比对要用增量输出 | 设计取舍 |
| 洗版体积可能略大于原文件 | 原文件用对象流压缩，洗版写成传统对象（本例 +1.40 MB，但比增量小 0.93 MB） | 后续可加对象流 |
| 扫描件 | 没有文字层就不翻译 | 不做 OCR（本地 OCR 是另一条线） |
| 合并单元格 / 无线表格 / 竖排 | P2 遗留 | 未做 |
| `/Rotate` 页 | 渲染已按公式旋转，但像素级检查仍跳过（`pixelX/pixelY` 只对 0° 成立） | 未做 |
| 中译中 | 源语言与文档语言不一致时，模型会照翻 | 未做语言检测提示 |
| App 窗口视觉验收 | 本次会话被系统授权框挡住 | 人工确认 |

---

## 8. 代码量

| 文件 | 行数 | 作用 |
|---|---:|---|
| `HymnCore/PDF/PDFScrub.swift` | 162 | 可达性遍历 + 重写（洗版） |
| `HymnCore/PDF/PDFComparisonReport.swift` | 278 | 逐段对照 HTML/JSON + 文字系统判断 |
| `HymnApp/PDFRebuildPipeline.swift` | 194 | 结构 → 翻译 → 写回 → 自检 流水线 |
| `HymnApp/AppModel+PDFRebuild.swift` | 315 | 进度/取消/落盘/headless 冒烟 |
| `HymnApp/PDFTranslationView.swift` | 312 | 两模式 UI（重写） |
| `hymntest/PDFP5Tests.swift` | 258 | 13 项新用例 |
| 合计 | **1,519** | `HymnCore/PDF` 累计 11,417 行 |

改动集中在 `PDFTextExtractor`（来源区间）、`PDFLayout`（`ILSpan.runIndex`）、
`PDFTypesetEngine`（选择性驱逐、无改动页跳过）、`PDFPageImage`（渲染变换）、
`PDFContentStream`（保留区间驱逐）、`PDFSimilarityAnalyzer`（R3 整页底图）。

测试 **413 → 426 全绿、release 零警告**。
