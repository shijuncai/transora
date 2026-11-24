# HymnTranslate 阶段 D：affine INT4 过渡版交付报告

生成时间：2026-11-21 00:10 (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`

> ## ✅ 后续状态（2026-11-21）：第 10 节的 D-1 已执行完毕
>
> 用户后续选择 **D-1**；第 10 节列的两条路径中，D-1 已全部完成：
> 原生 BPE → fp16 权重缓存（3.58 GB 零拷贝）→ 7 个 Metal 算子 →
> **32 层完整 forward** → 采样/生成循环 → `RealModelBackend` 接入既有调度与 UI。
> 关键突破是发现 CommandLineTools SDK 自带 `MetalPerformanceShaders.framework`，
> 因此**无需完整 Xcode、无需 MLX Swift 运行时**即可完成 fp16 GEMM。
> 现在有真实译文、120/120 测试、真实 TTFT/token·s⁻¹/内存数据。
> **本报告「尚未执行完整 forward、不产生译文」的口径已过期**，最新以
> **`Reports/stage-d1-complete.md`** 为准。D-2 仍未执行，也不再是必需路径。

> **口径声明**：本轮新增的性能数据来自**真实 1 GB `model.safetensors` 的字节级解析与 Metal 反量化**，
> 并与官方 MLX 数值逐元素对齐；但**尚未执行完整模型 forward，不产生译文**。
> 原文 `stage-summary.md` 里的调度/流式/取消/SQLite 数据仍是测试替身口径，两者不可混用。
> 用户已选择路线 D（过渡），因此本工程**永远标注 affine INT4，绝不标注 LUT4**。
> Python 的 `mlx` / `tokenizers` 仅作为离线 golden 校准工具，**不是交付软件的运行时依赖**，
> 也没有把任何推理路径降级为 Python。

---

## 0. 用户决策与边界

| 项 | 内容 |
|---|---|
| 用户指令 | 「过渡」= 上一轮给出的路线 D |
| 采用 | 真实 `mlx-community/Hy-MT2-1.8B-4bit` 的 affine INT4 权重 |
| 硬性禁止 | 把 INT4 标成 LUT4；编造算子；静默降级为 Python 推理 |
| 结论 | 权重层、算子层已真实落地并验证；**完整生成循环仍未接入** |

---

## 1. 环境复核（与阶段 0 结论的差异）

| 项 | 阶段 0 实测 | 本轮复核 |
|---|---|---|
| `github.com` | CONNECT 502 | **200**，`git ls-remote` 成功返回 `00afc1d` |
| `raw.githubusercontent.com` | 502 | 000；但 `ghproxy.net` 代理 **200**，可拉单文件 |
| `codeload.github.com` | 未测 | 301/200，但极慢（~19 KB/s） |
| `hf-mirror.com` | 200 | 200，且支持 **HTTP 206 Range 分段** |
| PyPI / 清华镜像 | 200 | 200（清华 ~1.8 MB/s） |
| 完整 Xcode | 无 | **仍无** |
| `metal` / `metallib` / `metal-ar` | 未检查 | **确认全盘不存在**（CommandLineTools 不含 Metal 编译器） |
| `mlx-swift` C++ 运行时 | 依赖源不可达 | **仍不可达**（见下） |

### 已解除的阻塞：架构注册

上一轮报告把「`hunyuan_v1_dense` 在 `mlx-swift-lm` 未内置」列为 BLOCKER 2。本轮**实证推翻**：

- 上游 `ml-explore/mlx-swift-lm` main 分支已含
  `Libraries/MLXLLM/Models/Hunyuan.swift`（9,962 B）与
  `Tests/MLXLMTests/HunyuanTests.swift`（7,195 B），源码已完整 clone 到
  `research/upstream/mlx-swift-lm`。
- `Libraries/MLXLLM/LLMModelFactory.swift:120` 明确注册：
  `"hunyuan_v1_dense": create(HunyuanConfiguration.self, HunyuanModel.init)`。
- `Hunyuan.swift` 里 **QK-Norm 在 `applyRotaryPosition` 之后**、`DynamicNTKAlphaRoPE`、
  `useQkNorm` 默认 `true` —— 与阶段 0 对模型结构的判定完全一致。
- 真实 `config.json` 字段与 `HunyuanConfiguration.CodingKeys` 逐项吻合：
  `vocab_size=120818`、`head_dim=128`、`use_qk_norm=true`、`tie_word_embeddings=true`、
  `attention_bias=false`、`rope_scaling.alpha=1000`。

### 仍存在的阻塞：MLX Swift 运行时依赖

| 尝试 | 实测结果 |
|---|---|
| `swift build` 依赖 `mlx-swift-lm` + `mlx-swift 0.33.0` | SwiftPM 卡在 `[1/28244] Fetching mlx-swift-lm`，7 分钟无进展 |
| `git clone --depth 1 mlx-swift-lm` | ✅ 成功（15 MB），`Hunyuan.swift` 落地 |
| `git clone --depth 1 --branch 0.33.0 mlx-swift`（含 vendored C++ MLX） | 停滞在 ~2 MB，9 分钟未完成 |
| 经 `ghproxy.net` 代理克隆 | 3 分钟仍停在 1.1 MB |
| GitHub release `Cmlx.xcframework.zip`（228 MB）直连 | 90 秒 0 字节 |
| 经 `ghproxy.net` 代理 release（支持 206） | 单连接 ~8.7 KB/s；20 段并行仍 ~20 KB/s → 228 MB 不可行 |

**结论**：MLX Swift / MLXLLM 仍无法在本机构建运行；且即使拿到源码，
`Package.swift` 里 `METAL_PATH "default.metallib"` 需要的 Metal 编译器也不存在。

### 新发现：不依赖 MLX Swift 的原生 GPU 路径可行

`Metal.framework` 的 `makeLibrary(source:)` 在**运行时**编译 MSL，不需要 `metal` CLI。
本轮实证：Apple M3 Pro 上运行时编译 `affine_int4_dequant` 成功（15.92 ms），
GPU 计算正常，且未占用主线程。这绕开了上述所有环境限制。

---

## 2. 真实权重落地（`Scripts/fetch-model.sh`）

单连接太慢，改用 12 段并行 HTTP 206 Range 下载，耗时 **11 m 31 s**，全部补齐并校验。

| 文件 | 大小 / SHA-256 |
|---|---|
| `model.safetensors` | 1,007,776,125 B · `a9cecbc77050b86b2fa3df3a8941d34ed3585cdbcce07bd64b3da289d50537c6` |
| `config.json` | 1,688 B · `63180daf56cf2ca15223b358eae0bcb5252b7fd4bfa2b2882b36e82f4c410da8` |
| `tokenizer.json` | 9,527,287 B · `b475bbef1b0b2fd57dcb865332b546475bd1ede2deb3bb91bafd0c047a8a530a` |
| `chat_template.jinja` | 654 B · `b7491ec0e9c869dfce20f2176758099bf248d979dd05530ede99deb21698acee` |

其余：`model.safetensors.index.json`、`tokenizer_config.json`、
`generation_config.json`、`mlx_manifest.json`、官方仓库的 `special_tokens_map.json`。
校验和写入 `Models/Hy-MT2-1.8B-4bit/SHA256SUMS.txt`。

### 字节级张量契约（不是推测）

```
metadata       : {"format": "mlx"}      header = 90,229 B
tensors        : 804                   U32 = 225, BF16 = 579
codebook 张量  : 0 (lut/codebook/centroid/lookup/cluster)
layers         : 32
layout 自检    : PASS（shape×dtype 字节数 == data_offsets 区间长度，无重叠、无越界）
q_proj.weight  : U32  [2048, 256]   → 2048×8 = 2048 个 4-bit 码值/行
q_proj.scales  : BF16 [2048, 32]    → 2048/64 = 32 groups/行
q_proj.biases  : BF16 [2048, 32]
quantization   : {mode: "affine", bits: 4, group_size: 64}
```

**判定：affine INT4（等间距码本），不是 LUT4。** `hymnctl weights` 会原样打印这份结论。

---

## 3. 新增原生模块 `HymnNative`（零外部依赖）

| 文件 | 职责 |
|---|---|
| `SafeTensors.swift` | mmap 只读、header 解析、804 张量布局自检、`withBytes` 零拷贝访问 |
| `AffineINT4.swift` | 布局契约、BF16→Float、CPU 参考反量化、可证伪的量化分析 |
| `MetalDequantizer.swift` | 运行时 MSL JIT 编译 + GPU 反量化（不需要 metal CLI） |
| `WeightContract.swift` | 对**真实落盘文件**做格式核验，推导 `isLUT4 = false` |

### 官方 MLX golden 与一个必须记录的数值发现

用 `mlx 0.32.4` 的 `mx.dequantize(w, scales, biases, group_size=64, bits=4, mode="affine", dtype=float32)`
生成 `Golden/qproj-rows0-31.f32`（32×2048 = 65,536 个 float32）与 `Golden/manifest.json`。

| 阶段 | 与官方 golden 的 maxAbsDiff |
|---|---|
| 初版 `Float(q) * scale + bias`（纯 float32） | **1.22e-4**（65,536 个元素里部分差一个 BF16 网格步） |
| 定位原因 | MLX 输出落在 **BF16 网格**：精确值 `-741/65536` 被舍入为 `-740/65536` |
| 加入 `roundToBF16`（RN-even）后 | **0.0（65,536 / 65,536 全等）** |

`bf16_rn` 不是「编造的算子」，而是对官方实现数值行为的实测复现，
CPU 参考与 Metal kernel 同步采用同一算法，三方逐元素一致。

另用 HF `tokenizers 0.23.3` 生成 `Golden/tokenizer-golden.json`
（4 组中英/特殊 token 样本 + chat_template 原文），供后续原生 tokenizer 逐 token 对齐；
**当前尚未实现 Swift 原生 tokenizer**。

---

## 4. 构建结果

```
swift build --disable-sandbox     → rc = 0, Build complete!
targets: HymnCore / HymnNative / HymnStore / hymnctl / hymntest / HymnApp (6)
全部 .swiftLanguageMode(.v6)；外部 SwiftPM 依赖 = 0
warnings: 仅 CommandLineTools 缺 Developer/{usr/lib,Library/Frameworks} 的链接器搜索路径
完整日志: Reports/build.log, Reports/build-d1.log
```

本轮编译修正记录：① `QuantizationAnalysis` 成员初始化器跨模块不可见 → 加 `public init`；
② 三件套 shape 断言误查 computed property `inFeatures` → 改为核对 stored 字段具体值；
③ CPU/GPU 对齐断言阈值误写 `>100_000`（实际 16×2048=32,768）→ 改为精确值。

---

## 5. 测试报告：`72 / 72 通过，0 失败`（原 57 + 新增 15）

`HYMN_REPORT_DIR=<Reports> .build/debug/hymntest` → rc = 0。
新增 `native-weights` 套件 15 项全部通过：

| 断言 | 实测 |
|---|---|
| 真实模型目录可定位 | `Models/Hy-MT2-1.8B-4bit` |
| safetensors 布局自洽 | problems = 0，header 90,229 B |
| affine INT4 且绝不标 LUT4 | mode=affine, bits=4, group=64, codebook=0 |
| 张量数 / dtype | 804（U32 225 / BF16 579） |
| 层数 / 文件大小 | 32 层 / 1,007,776,125 B |
| Metal 运行时编译 MSL | Apple M3 Pro，maxThreads=1024，15.92 ms |
| 三件套 shape 契约 | out=2048, packed=256, groups=32, group=64 |
| 4-bit 码值覆盖 | 0..15 全部出现，直方图见 `test-report.md` |
| zero-point 残差 | 0.3915（验证 q 为无符号码值，bias ≈ -8·scale） |
| 权重分布 | mean=-0.000105, std=0.015358, min=-0.0928, max=0.1099 |
| **Metal GPU vs CPU 参考** | 32,768 元素，**maxAbsDiff = 0** |
| **CPU 参考 vs 官方 MLX golden** | 65,536 元素，**maxAbsDiff = 0** |
| GPU 反量化线程 | `pthread_main_np() = false`，未占用主线程 |
| 报告产物 | `native-perf.json` / `weight-verdict.txt` 均已生成 |

逐条结果：`Reports/test-report.md`；TAP 原始输出：`Reports/test-run.log`。

---

## 6. 性能数据（`Reports/native-perf.json`）

| 指标 | 数值 | 口径 |
|---|---|---|
| MSL 运行时编译 | 15.92 ms | 冷启动，重复运行波动 15.9–430.5 ms |
| CPU 反量化 16 行（32,768 元素） | 4.26 ms | Swift Debug `-Onone`，单线程 |
| Metal 反量化 16 行 | 7.53 ms | **含 3 个 MTLBuffer 创建、命令提交与 `waitUntilCompleted` 同步** |
| Metal 等效吞吐 | 4.35 M elements/s | 小规模下 GPU 慢于 CPU，如实记录，不做美化 |
| golden 对齐 | 65,536 元素 / 0 误差 | 官方 MLX 校验，非性能基准 |
| 张量数 / 权重体积 | 804 / 1,007,776,125 B | 真实文件 |

> ⚠️ 这些数字是**权重反量化**的吞吐，**不是模型 token/s、TTFT 或峰值内存**。
> 原 `Reports/perf.json` 的 37,846 req/s、1.46 ms 首 token 等仍是调度/替身口径。

---

## 7. CLI 与 App（过渡版标注）

| 命令 | 结果 |
|---|---|
| `hymnctl weights` | 打印真实契约 9 行 + 前 8 个真实权重 `[-0.0112915, 0.0075378, …]` + GPU/CPU 0 误差 |
| `hymnctl verify` | 仍返回 `LUT4 可加载: NO`，保留阶段 0 的防冒充判定 |
| `hymnctl translate / batch / cancel` | 仍为测试替身，输出明确带 `[fixture]` 前缀 |
| `Scripts/make-app.sh` | v0.2.0；写入 Application Support 符号链接指向真实权重（不复制 1 GB）；Golden 与 verdict 进 Resources |
| 无窗口冒烟 | `HYMN_SMOKE_OK verdictLines=17 isLUT4=false status=过渡版 D：真实权重已落盘 · 原生算子层已验证 · 完整 forward 尚未接入`，rc=0 |

UI 变更：标题改「affine INT4 过渡版」；头部显示 `affine INT4 (NOT LUT4)`、
`真实模型推理：未接入`、`真实权重：已落盘并校验`；历史 `modelTag` 显式带 `TEST DOUBLE`。

---

## 8. 需求对照（本轮变化）

| # | 需求 | 阶段 0 | 阶段 D |
|---|---|---|---|
| 2 | MLX Swift + Metal 原生推理 | ⛔ 未接入 | 🟡 Metal 原生 GPU 算子已实证；MLX Swift 运行时仍不可达 |
| 3 | 内置 HY-MT2 1.8B | ⛔ 权重未获取 | ✅ 真实 1 GB 权重 + 分词器 + chat template 已落盘并校验 |
| 4 | LUT4 + 兼容性验证 | ✅ 判定 NO | ✅ 维持 NO；过渡版明确改用 affine INT4 |
| 5 | 不得冒充 LUT4 | ✅ | ✅ 新增 `WeightContract` 对真实文件二次核验，`isLUT4=false` |
| 9 | 全程离线 | ✅ | ✅ 运行时零网络；Python 校准工具不进运行时 |
| 10 | 不阻塞主线程 | ✅ | ✅ Metal 反量化实测在非主线程 |

---

## 9. 明确未交付

1. **完整模型 forward / 真实译文 / 真实 token·s⁻¹、TTFT、峰值内存**（最重要）
2. Swift 原生 tokenizer（golden 已备好，尚未实现）
3. MLX Swift / MLXLLM 运行时接入（受环境阻塞）
4. LUT4 权重与 LUT dequant kernel（D 路线不宣称实现；如需严格 LUT4 请另选路线 A）

`InferenceBackend.performsRealModelInference` 仍为 `false`，没有任何后端声称会翻译。

---

## 10. 下一步：两条**原生**路径（均不降级 Python）

### D-1（推荐）在已验证的 Metal 算子上补完整 forward

1. 用 `Golden/tokenizer-golden.json` 对齐原生 BPE（ByteLevel + Split pre-tokenizer 序列），
   逐 token id 校验；按 `chat_template.jinja` 等价渲染 prompt（无 system prompt）。
2. 权重：按需把 INT4 解压为 fp16（1.8B×2B ≈ 3.6 GB，18 GB 内存可容纳），
   或写 fused dequant-matmul kernel 降低显存。
3. 32 层计算图：RMSNorm → Q/K/V linear → RoPE（DynamicNTK-alpha,
   effective base = `10000×1000^(128/126) = 11,158,839.93`）→
   **post-RoPE QK-Norm（最易错点，与 Qwen3 相反）** → GQA attention + KV cache →
   SiLU MLP → tied lm_head。
4. 采样：`temp 0.7 / top_p 0.8 / top_k 20 / repetition_penalty 1.05`（来自 generation_config.json）。
5. 逐层与 Python MLX golden 对齐后再接入 `InferenceBackend`
   （`performsRealModelInference=true`）、现有 `RequestScheduler` 与 UI。
6. 交付真实 TTFT / token·s⁻¹ / 峰值内存 / 翻译质量评测，替换替身口径。

### D-2 补齐环境后直接接上游 MLXLLM

1. 安装完整 Xcode（提供 `metal`/`metallib` 编译器与 SwiftUIMacros 插件）。
2. 打通 `mlx-swift` C++ 仓库或 release xcframework 源（当前本机不可达）。
3. 用已 clone 的 `mlx-swift-lm`（含 `Hunyuan.swift` 与架构注册）加载本地权重目录。
4. 接入现有调度层；UI 继续保持 `affine INT4 (NOT LUT4)` 标注。

> 两条路径里 Python 都只用于生成 golden/校验数值，**绝不作为软件运行时的推理后端**。
