# H 阶段：G4 之后的优化、评测、持久化与格式排除

> ## ⚠️ 本文是 2026-11-21 14:0x 的历史方案快照，状态已过期
>
> 下文第 0/3/4 节中「H1 方案已给，未实施」「COMET 明确未交付」「不是 1260 全方向」
> 「Sampler 请求级可复现未修复」均为**当时**结论。当晚这四项已全部实施完成：
> - H1：batched prefill（logits 逐位相等、1.60×）+ int8 KV cache（省 31.0 MiB，默认关闭）；
>   fused dequant-GEMM 仍按原口径不重复计功。
> - COMET：真实 `Unbabel/wmt22-comet-da` 打分 **system_score 0.7809**（256 条 / 64 方向，最终批次；
>   流式修复前为 0.7345，修复后 +0.0464）。
> - 1260 全方向：36×35 全覆盖，1260/1260 真实推理，64 有参考 + 1196 仅冒烟。
> - Sampler：每请求按 seed 重建，请求级可复现，端到端实证通过。
>
> **最新数据、口径与验证证据一律以 `Reports/model-migration-plan.md` 第 12 节为准**；
> 本文保留原貌仅作方案与历史对照，不改写历史结论。

建立时间：2026-11-21 14:0x (GMT+8)
前置：`Reports/stage-g4-resident-gemv.md`（默认后端 = `Hy-MT2-1.8B-1.25Bit.gguf` 常驻 GEMV，测试 164/164）
计划表/进度表：`Reports/model-migration-plan.md` 第 8 / 9 节

---

## 0. 结论摘要

用户列出四项后续范围，其中第 4 项**明确排除**。本轮按「不兼容先给适配方案、不编造、模块独立实现/测试」逐项处理：

| 项 | 状态 | 本轮实际交付 |
|---|---|---|
| H1 量化 KV cache / batched prefill / fused dequant-GEMM | **方案已给，未实施** | 现状字节级实证 + 三层适配方案 + 验收标准；`fused dequant-GEMM` 口径已澄清（现有 GEMV 已是融合实现） |
| H2 BLEU/COMET + 全部语言对覆盖 | **部分完成** | 36 语言目录 + UI 全量选择器；公开权威平行语料 + `hymnctl evaluate` + BLEU/chrF 离线打分；**COMET 明确未交付，不伪造分数** |
| H3 UserDefaults + 像素级 UI 自动化 | **持久化完成；自动化工具已备、验证待授权** | 持久化契约 + 双进程重启冒烟通过；`ui-backend-click.swift`（AXFrame + CGEvent + RGBA 像素差）编译 rc=0、阻塞路径实测通过；但 TCC 权限未授权，**像素级自动化未跑通、不宣称通过** |
| H4 v2 GGUF（type=40） | **明确排除（决议 100%）** | 排除理由与权威来源缺口写入计划表，不解析、不猜测 |

**推理计算核心零改动**：`HymnNative/MetalOps`、`HymnSTQ/SherryGEMV`、`SherryResidentModel`、
`SherryBackend`、`Sampler` 本轮未修改一行。`RealModelBackend` 只把 `languageName`
改为委托 `LanguageCatalog`（提示词层，未触碰 forward / 采样 / 权重），
另新增 `HymnCore` 两个纯逻辑类型、UI 选择器、CLI `evaluate` 命令与离线评测脚本。

---

## 1. 硬约束（全部 H 项适用）

- `STQ1_0` 全程标注 `1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4)`；1.3125 bpw 只描述 224 个线性层。
- 运行时全程 Swift / Metal / SQLite 原生；**Python 只用于离线 golden 与离线算分**，永不作运行时后端。
- 未经验证不得编造算子；格式不兼容先给具体适配方案，不静默降级。
- 推理不阻塞主线程；单模型实例、并发峰值 1；性能数字必须标注口径（单次 / 独立进程 / 非 TTFT）。

---

## 2. H3-a：UserDefaults 后端选择持久化（已完成）

### 2.1 新增契约

`Sources/HymnCore/Backend/BackendPreference.swift`：

| 规则 | 行为 |
|---|---|
| 优先级 | `HYMN_BACKEND` 环境变量 > 用户上次**成功切换**的偏好 > 默认 `sherry` |
| 非法值 | 一律回退默认，绝不把未知字符串交给后端工厂 |
| 写入时机 | **只有切换成功才写**；失败/显式回滚分支不写，避免把不可用后端记成下次启动默认 |
| 测试隔离 | `HYMN_PREF_SUITE` 注入独立 `UserDefaults(suiteName:)`，测试与冒烟不污染真实偏好 |

抽到 `HymnCore` 而非 App target，是为了让 `hymntest` 能独立测试优先级与回退，不依赖 SwiftUI 视图树。

### 2.2 实证

- `backend-preference` 套件 **14 项全绿**；全套 **189/189**（164 + 11 + 14）。
- 双进程重启冒烟（隔离 suite）：
  - 进程 1 `HYMN_BACKEND=native` → 图形开关切到 `mlx`：`success=true switchMs=1255`
  - 进程 2 全新进程、不设环境变量：`status=就绪：MLX Swift …`、`backend=mlx` → **偏好生效**
  - 进程 3 `HYMN_BACKEND=sherry`：`backend=sherry` → **环境变量优先级生效**

---

## 3. H1：量化 KV cache / batched prefill / fused dequant-GEMM（方案，未实施）

### 3.1 现状字节级实证（来自 `SherryResidentModel` / `MetalOps`）

| 项 | 值 |
|---|---|
| KV cache 精度 | **fp16**（`act()` 分配的 `MTLBuffer`） |
| `maxSeq` | 1024 |
| `kvDim` | `kvHeads 4 × headDim 128 = 512` |
| 每层每 k/v | `1024 × 512 × 2 B = 1,048,576 B` |
| 32 层 × k/v | **67,108,864 B = 64 MiB** |
| 常驻 GGUF 权重 | 461,860,800 B = 440.5 MiB |
| 独立进程峰值 RSS（Sherry） | 963.8 MiB（`ru_maxrss` 含 461 MB 常驻 buffer） |

如实说明：KV cache 只占常驻权重的约 14%、峰值 RSS 的约 6.6%。
**即使 int8 量化把 KV 减半，也只省约 31.5 MiB，不会把 963.8 MiB 变成「低内存」** —— 不夸大收益。

### 3.2 H1-a：量化 KV cache 适配方案

1. 新增两个 MSL kernel（放在 `HymnSTQ` 内，不改 `HymnNative/MetalOps`，避免污染 D-1）：
   - `kv_write_int8`：把 fp16 的 k/v 按 **per-token per-KV-head** 求 `scale = max(|x|)/127`，量化为 int8 写入 cache，scale 存 fp16；
   - `attention_decode_int8`：GQA decode 时按同一 scale 反量化，softmax / 加权求和精度不变。
2. buffer 改为 `int8 k/v cache` + `fp16 scale`（额外约 `1024 × 4 × 2 B × 32 × 2 = 524,288 B`）。
3. **独立 Python golden**：从现有 `Golden/sherry-forward-manifest.json` 的 32 层参考出发，加入 int8 量化/反量化，比对 logits corr、top-20、argmax、layer32 hidden。
4. 验收：corr ≥ 0.9999、top-20 20/20、argmax 28036 不变、en→zh / zh→en 译文不变；TTFT / token·s⁻¹ / 峰值 RSS 三后端对照。

风险：int8 会引入量化噪声，GQA attention 对 key 精度敏感；若 golden 不达标，如实回退 fp16，不放宽阈值。

### 3.3 H1-b：batched prefill

当前生成循环是**逐 token GEMV**，长 prompt 的 TTFT 随长度线性增长（en→zh TTFT 888.72 ms）。
方案是实现 `stq1_0_gemm` 多 token tile kernel（先 4 / 8 token 微批），把 prefill 阶段的 225 次/token GEMV 合批。
这属于新算子，必须配独立 golden 与逐层数值对照，不能只测「译文还对」。

### 3.4 H1-c：fused dequant-GEMM 口径澄清

**现有 `stq1_0_gemv` 在 kernel 内直接解 42 B/256 block 并立即乘加，已经是「解码即乘加」的融合实现**，
`q6_k_gemv` 同理。因此：
- 不能把「新增 fused dequant-GEMM」当成已交付的独立优化来宣称；
- 真正未做的是 **多 token GEMM**（H1-b），与向量版 GEMV 是不同路径；
- 报告与进度表按此口径记录，避免重复计功。

---

## 4. H2：BLEU/COMET 与全部语言对覆盖

### 4.1 语言覆盖基础设施（已完成）

模型卡 `tencent/Hy-MT2-1.8B/raw/main/README.md` 实证声明 **36 种语言**。此前缺口：

| 之前 | 现在 |
|---|---|
| `languageName` 只映射 10 个代码，其余把裸代码（如 `th`）写进中文 prompt | `LanguageCatalog` 登记全部 36 种中文名 + 短标签 + 别名；未知代码原样返回、不臆造 |
| UI Picker 只有 `en/zh/ja` 3 项 | 两个 Picker 均为 36 项 |

`language-catalog` 套件 11 项全绿，含「旧 8 个已验证语言名逐字不变」回归，确保 en→zh / zh→en 译文不被改动。

### 4.2 权威平行语料实证

| 候选 | 结果 |
|---|---|
| `facebook/flores`（FLORES-200） | **403 `GatedRepo`**，匿名无法下载 → 未使用 |
| `openlanguagedata/flores_plus` | **403 gated** → 未使用 |
| `Muennighoff/flores200` | 公开，但只有加载脚本，不含数据 |
| **`Helsinki-NLP/opus-100` test split** | **公开、HTTP 206、`PAR1` 头** → 采用 |

`Scripts/fetch-eval-data.py` 下载 32 个以 en 为枢轴的语言对 test parquet，
每个 parquet 2000 行，按字符长度过滤短句（避免 `maxTokens` 截断污染分数），
每个语言对取 4 条平行句并**拆成双向**，共 `32 × 2 × 4 = 256` 条带真实参考译文的样本；
另加 3 条无参考冒烟样本 → **259 条**。每个 parquet 的 SHA256 固化在 `Eval/opus100-manifest.json`。
**参考译文一字未改**，不存在自造参考译文。

### 4.3 BLEU / chrF（离线打分）

- 运行时侧：`hymnctl evaluate --input <jsonl> --out <jsonl> --tokens 64`，**一次 prepare、循环翻译**，
  产出带参考译文的 JSONL；Swift 侧不调用 Python。
- 离线侧：`Scripts/score-translation-eval.py` 用 `sacrebleu 2.6.0` 的 `corpus_bleu` / `corpus_chrf`；
  对无空格 / 非拉丁文字目标另给**字符级 BLEU**，避免 13a 分词系统性低估。
- 结果见 `Reports/translation-quality.json`（本轮全量跑完后补入第 7 节）。

### 4.4 COMET —— 明确未交付，不伪造分数

本机依赖实测：`torch` / `transformers` / `sentencepiece` / `sacrebleu` 中前三者**全部缺失**（仅装了 `pyarrow` 与 `sacrebleu`）。
COMET 是神经评测指标，需要下载评测模型 `Unbabel/wmt22-comet-da`
（HF API 实测 `checkpoints/model.ckpt` = **2,323.6 MB**，仓库 LFS 合计约 **2.32 GB**）+ PyTorch 运行时。
本轮**不产出任何 COMET 分数**，也不把 BLEU/chrF 换个名字当 COMET。

授权后的可执行方案（评测工具链，不进 App 运行时）：

```bash
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple torch unbabel-comet sentencepiece
# 首次需下载 wmt22-comet-da 评测模型；之后全程离线打分
comet-score -s Eval/opus100-samples.jsonl -t Reports/translation-hypotheses.jsonl -r <src> --model Unbabel/wmt22-comet-da
```

### 4.5 「全部语言对覆盖」的如实口径

- 模型卡 36 语言：UI / prompt **全覆盖**。
- 有权威参考译文：**32 种非 en 语言 × 2 方向 = 64 个方向**。
- 无平行语料的 `tl` / `bo` / `mn`：只做「译文非空且不等于源文」冒烟，**不计入任何 BLEU**。
- **不是 36×35 = 1260 个全语言对**；未覆盖方向不声称做过质量评测。该口径写入 manifest 与 JSON 的 `caveats`。

---

## 5. H3-b：像素级 UI 自动化 —— 工具已实现，验证待 TCC 授权

### 5.1 权限实测（2026-11-21 14:50 复检，仍全部未授权）

`Scripts/ui-automation-preflight.py` 只读实测（`Reports/ui-automation-preflight.json`）：

```
accessibility_trusted      = false
screen_capture_allowed     = false
screencapture              = "could not create image from display" (rc=1, 0 bytes)
System Events AppleEvent   = timed out (-1712)
pixel_ui_automation_ready  = false
```

当前执行环境**既不能投递 CGEvent 真实点击，也不能截取屏幕像素**。
按项目规则，**不把「视图树实例化」或「调用同一 `switchBackend` 入口的 headless smoke」冒充成像素级点击**。

### 5.2 本轮已把工具做实（不空等授权）

新增 `Scripts/ui-backend-click.swift` + 一键入口 `Scripts/ui-automation.sh`：

| 环节 | 实现 |
|---|---|
| 控件定位 | 通过 `AXUIElementCreateApplication` 遍历窗口 AX 树，按「MLX Swift / D-1 原生 Metal / Sherry 1.25bit」标题找到 segmented Picker 的 segment，读 `AXPosition` + `AXSize` 得到**真实 AXFrame**，不靠猜像素坐标 |
| 真实点击 | `CGEvent` 的 `leftMouseDown` / `leftMouseUp` 投递到 `.cghidEventTap`，**不是**调 SwiftUI Binding 或 `switchBackend` |
| 像素比对 | 点击前后用系统 `screencapture -x -t png` 取全屏，ImageIO 解码成 RGBA，对控件区域按 Retina 缩放后逐字节统计差异像素数（阈值 24/通道） |
| 权限守卫 | 权限不足时先输出 `UI_CLICK_BLOCKED` 并退出 2，**不产生任何鼠标事件**、不启动 App |
| 结果落盘 | `Reports/ui-automation-click.json`（AXFrame、点击坐标、像素区域、变化像素数、前后 PNG 路径） |

`CGDisplayCreateImage` 在 macOS 15+ 已废弃（要求 ScreenCaptureKit），因此改用系统 `screencapture`，
不引入新框架。工具用 `swiftc -framework Cocoa -framework ApplicationServices` 独立编译，
**编译 rc=0**；当前权限下运行 `./Scripts/ui-automation.sh mlx` 得到
`rc=2 / UI_CLICK_BLOCKED / no_click_emitted=true`，阻塞路径实测正确。

### 5.3 仍未交付的部分（如实标注）

**工具已实现并编译通过，但没有在授权环境里跑通，因此像素级 UI 自动化仍未「通过」**：
AX 树能否暴露 SwiftUI segmented Picker 的 `AXRadioButton`、Retina 坐标换算是否准确、
点击后状态栏是否真的切换，都必须在授权后实测才能确认。报告不得写「已通过」。

### 5.4 授权后一键验证（需用户操作一次）

1. 系统设置 → 隐私与安全性 → **辅助功能**：勾选当前终端 / WorkBuddy；
2. 系统设置 → 隐私与安全性 → **屏幕录制**：同样勾选；
3. 重开终端使 TCC 生效，执行：

```bash
cd /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate
python3 Scripts/ui-automation-preflight.py     # 期望 UI_AUTOMATION_READY
./Scripts/ui-automation.sh mlx                 # 或 native / sherry
```

期望输出 `UI_CLICK_OK` 且 `Reports/ui-automation-click.json` 中 `changed_pixels > 0`、
`before_png` / `after_png` 两张截图可见控件重绘。若 AX 树未暴露该控件，工具会明确报
`BLOCKED` 并给出原因，不会伪造成功。

---

## 6. H4：v2 GGUF（type=40）—— 明确排除

| 事实 | 证据 |
|---|---|
| v1 是 `type=42 = STQ1_0` | GGUF 头部 224 个线性层实测 1.3125 bpw，与 PR #22836「42 B/256」逐字节吻合 |
| v2 是 `type=40`，模型卡标 `1.25bit-new` | v1/v2 头部对比：offset 完全相同但 ggml type 不同 |
| `type=40` 无权威定义 | llama.cpp PR #22836 与当前 mainline 的类型表均无对应 block 布局 / 码本；新枚举插入的是 NVFP4=40 / Q1_0=41 / Q2_0=42，STQ1_0 已挪到 43 |
| 第三方参考仅覆盖 v1 | `kuotient/Hy-MT2-1.8B-1.25Bit-MLX` 的 `sherry_model.py` 只实现 STQ1_0 |

按硬规则「未经验证不得编造算子、不兼容先给适配方案」，**不解析、不猜测、不把 type=40 当成 STQ1_0 解码**。
若将来出现权威定义，需重新立项并配独立 golden，不在本阶段范围。

---

## 7. 本轮产物清单与复现

新增文件：

```
Sources/HymnCore/Backend/BackendPreference.swift
Sources/HymnCore/Compatibility/LanguageCatalog.swift
Sources/hymntest/BackendPreferenceTests.swift
Sources/hymntest/LanguageCatalogTests.swift
Scripts/fetch-eval-data.py
Scripts/score-translation-eval.py
Scripts/ui-automation-preflight.py
Scripts/ui-backend-click.swift      (H3-b 真实点击 + 像素比对，独立 swiftc 编译)
Scripts/ui-automation.sh           (H3-b 一键入口)
Eval/opus100-samples.jsonl          (259 行)
Eval/opus100-manifest.json          (32 个 parquet 的 SHA256)
Eval/parquet/*.parquet              (离线语料缓存)
Reports/translation-hypotheses.jsonl
Reports/translation-quality.json
Reports/translation-quality-before-prompt-fix.json
Reports/translation-quality-comparison.json
Reports/ui-automation-preflight.json
Reports/ui-automation-click.json
Reports/stage-h-roadmap.md          (本文件)
```

修改：`Sources/HymnApp/{AppModel,RootView}.swift`、`Sources/HymnCore/Backend/RealModelBackend.swift`、
`Sources/hymnctl/main.swift`（新增 `evaluate` 子命令）、`Sources/hymntest/main.swift`、
`Reports/model-migration-plan.md`（第 8/9 节 H 计划表与进度表）。

复现：

```bash
./Scripts/build.sh
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
HYMN_SHERRY_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-1.25Bit-GGUF" ./Scripts/test.sh
python3 Scripts/fetch-eval-data.py
.build/debug/hymnctl evaluate --input Eval/opus100-samples.jsonl \
    --out Reports/translation-hypotheses.jsonl --tokens 64
python3 Scripts/score-translation-eval.py
python3 Scripts/ui-automation-preflight.py     # 需 TCC 授权才返回 READY
./Scripts/ui-automation.sh mlx                 # 授权后执行真实点击 + 像素比对
```

---

## 8. 规则遵守声明

- 未把 `STQ1_0` / `Q6_K` 冒充 LUT4、affine INT4 或任何未经验证的算子；
- v2 `type=40` 明确排除，没有猜测格式；COMET 没有伪造分数；像素级 UI 自动化没有冒充通过；
- Python 只用于**离线语料抽取与离线算分**，运行时推理仍是 Swift/Metal 原生；
- 全部新逻辑都有独立测试套件；性能与质量数字标注口径，不混用 TTFT / token·s⁻¹ / 单次测量；
- 默认后端仍是 `Hy-MT2-1.8B-1.25Bit.gguf`，D-1 / MLX 仍并列可显式选择。

---

## 9. H2 系统级评测结果、发现的真实缺陷与修复

### 9.1 修复前：全量 259 条真实译文

`hymnctl evaluate` 一次 prepare、循环翻译 **259/259 成功、0 失败**（8m50s，单次测量）。
`sacrebleu` 对其中 256 条带参考译文的样本打分：

| 指标 | 值 |
|---|---|
| 有参考方向 | **64**（32 个 en 枢轴语言对 × 双向） |
| 总体 BLEU(13a) | **22.04**（BP 0.956，hyp/ref 长度 2285/2388） |
| 总体 chrF2 | **38.87** |
| 方向 BLEU 中位数 | 13.71；`=0` 的方向 **6 个**，`<10` 的方向 **30 个** |
| 最高 / 最低 | `en→id` 73.46 / `en→es` 等 0.0 |
| 无参考冒烟 | 3/3 译文非空、均不等于源文 |

数据归档：`Reports/translation-quality-before-prompt-fix.json`、
`Reports/translation-hypotheses-before-prompt-fix.jsonl`。

### 9.2 评测暴露的真实缺陷（比分数更重要）

对 `en→X`（X 非中日韩）的 116 条样本统计，**28 条直接输出中文**，
集中在 `es / gu / he / km / mr / te / ur` 七个目标语言；`en→tl` 冒烟同样输出中文。
例：`The home planet is running out.` → `地球正在耗尽资源。`（应为西班牙语）。

三后端对照（同一 prompt、`--to es`）：

| 后端 | en→es 输出 |
|---|---|
| Sherry 1.25bit（默认） | `地球正在耗尽资源。` ❌ 中文 |
| D-1 affine INT4 | `La planeta natal se está agotando.` ✅ |
| MLX Swift | `La planeta natal se está agotando.` ✅ |

`zh→en` 三后端均正确，说明不是全局性退化。
结论：**1.25bit 量化让指令遵循对语言名措辞更敏感**，不是模型完全丧失多语言能力，
也不是 `LanguageCatalog` 漏映射。

### 9.3 根因定位与修复

措辞实证（Sherry，同一句、`--to` 直接传语言名字符串）：

| 目标 | 「XX文」 | 「XX语」 |
|---|---|---|
| es | `地球正在耗尽资源。` | `El planeta hogar se está agotando.` |
| he | `家园星球正在耗尽。` | `כוכב הלכת הבית נגמר.` |
| mr | `地球正在耗尽资源。` | 天城文输出（含重复字符） |
| te | `家园星球即将耗尽。` | 泰卢固文输出（含重复字符） |
| ur | `家园星球即将耗尽。` | `گھر کا سیارہ ختم ہو رہا ہے۔` |
| gu / km | 中文 | 古吉拉特文 / 高棉文输出（含重复字符） |

**7/7 个语言改「XX语」后均正确输出目标语言**；D-1 / MLX 对两种措辞都正常。

修复：`LanguageCatalog` 只把这 7 个有实证问题的名称改为「XX语」（含 `iw` 别名），
其余语言名（尤其决定已验证译文的「简体中文」「英文」「日文」）**逐字不变**，避免扩大风险。
新增 2 项断言后全套测试 **191/191**（原 189 + 2）。
修复后全量 259 条评测已重跑，对照数据见 `Reports/translation-quality.json` 与第 9.5 节。

### 9.4 仍未定位的遗留缺陷（如实标注）

低资源语言（`bo` / `mn` / `gu` / `km` / `te` / `mr`）的部分译文含**重复字符与 U+FFFD 替换字符**，
例如 `en→bo` 输出 `འཕཕྲཕྲུལ…`、`en→mn` 含替换字符。
原因尚未定位：可能是 1.25bit 量化模型的生成退化，也可能是流式增量解码在多字节边界的处理。
**不声称已修复**，列为 H2 的后续排查项；需要与离线完整 decode 对照后才能下结论。

### 9.5 修复前后对照（同一 259 样本、同后端、同 `maxTokens=64`）

| 指标 | 修复前 | 修复后 | 变化 |
|---|---|---|---|
| 总体 BLEU(13a) | 22.04 | **23.20** | +1.16 |
| 总体 chrF2 | 38.87 | **41.19** | +2.32 |
| **`en→X` 输出中文** | **28 / 116** | **1 / 116** | **−27 条** |
| BLEU=0 的方向 | 6 | **3** | −3 |
| `en→es` | 0.00 | **55.28** | +55.28 |
| `en→he` | 0.00 | **42.24** | +42.24 |
| `en→ur` | 0.00 | 10.22 | +10.22 |

`Reports/translation-quality-comparison.json` 保存逐方向 delta：20 个方向改善、25 个方向回退。
**但回退主要出现在 prompt 完全未变的 `X→en` 方向**（如 `zh→en` −3.65、`id→en` −4.44、
`km→en` −12.25），说明两次全量之间存在与措辞无关的波动，见 9.7 节。
因此**不能把总体 +1.16 全部归因于措辞修复**；可靠证据是「中文误出 28→1」与
7 个目标语言方向的直接跃升。

### 9.6 评测方法学发现：采样器状态跨请求延续（未修复，如实标注）

`Sampler` 用固定种子 `0x9E3779B97F4A7C15` 且持有**可变的 `state`**，
`SherryGenerator` 在整个生命周期里复用同一个 `Sampler` 实例，不在每次 `generate` 开头重置。
所以每条样本消耗的随机数会延续到下一条：只要某条译文长度变化，后续所有请求的采样轨迹都会改变。
这正是 `X→en`（prompt 未变）仍出现 BLEU 波动的原因，也意味着**当前评测不是请求级可复现的**。

适配方案（会改变已验证译文，需用户确认后再动推理核心）：
1. 在 `generate` 开头用 `sampling.seed` 重建 `Sampler`，使每个请求独立且可复现；
2. 或评测时每条样本单独 `prepare`（259 次冷加载，代价高）；
3. 或用 greedy decoding（`temperature=0`）评测，消除采样随机性。

本轮**未修改生成行为**，保持「推理计算核心零改动」；该问题列为 H2 的后续方法学修复项，
不作为「评测已完全可复现」的宣称。

### 9.7 其余已定位但未实施的边缘

- `tl`（菲律宾文）冒烟同样输出中文；实测 `--to 菲律宾语` 能正确输出他加禄语
  `Ang machine learning ay nagbabago sa mundo.`。因 `tl` 无权威参考译文、
  且为避免改动后与已归档的全量评测数据不一致，本轮未纳入修复，属**一行改名**的后续项。
- `bo` / `mn` 冒烟输出含重复字符与替换字符（见 9.4），同样未修复。

### 9.8 对「默认后端 = 1.25bit GGUF」决策的影响

用户明确要求默认后端为 `Hy-MT2-1.8B-1.25Bit.gguf`，本轮**未擅自改回**。
但系统级评测证明它在多语言指令遵循上弱于 D-1 / MLX，措辞修复只是缓解、不是根治。
可选适配方案（需用户决策，不静默切换）：
1. 保持现状，UI 明示「低资源语言/部分方向建议切换 D-1 或 MLX」；
2. 按语言对路由：默认 Sherry 处理 zh/en/ja 等强方向，其余自动走 D-1 / MLX（会引入多实例，需重审「单模型实例」约束）；
3. 把默认后端改回 D-1，Sherry 降为并列可选（与用户上一条指令相反，必须显式确认）。
