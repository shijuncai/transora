# HymnTranslate 阶段 D-1：纯 Metal 原生推理完成报告

生成时间：2026-11-21 (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`

---

## 0. 结论

**用户指定的 D-1 路线已完成：软件现在执行真实模型推理并产出真实译文。**

```
$ hymnctl translate --text "Hello, nice to meet you." --from en --to zh
后端: hymn-native-metal-affine-int4-v1
权重格式: affine INT4 (NOT LUT4)
真实模型推理: YES
您好，很高兴见到您。
```

- `performsRealModelInference = true`（`RealModelBackend`），不再是测试替身。
- `dist/HymnTranslate.app` v0.3.0 冒烟状态：`就绪：affine INT4 真实模型 · 32 层 Metal forward · 全程离线`。
- 权重格式永远标注 **affine INT4 (NOT LUT4)**，未把普通 INT4 冒充 LUT4，未编造 LUT 算子。
- 全程原生 Swift 6 + Metal / MPS，**没有降级为 Python 推理**；Python 仅用于离线生成 golden。
- **MLX Swift 运行时依赖仍然不可达，但已不再是阻塞**：完整 forward 由本工程自己的 Metal 算子 + Apple 官方 MPS 实现。

---

## 1. 路线与环境突破

| 约束（阶段 D 报告） | D-1 实测结论 |
|---|---|
| 无完整 Xcode、无 `metal`/`metallib` 编译器 | Metal.framework `makeLibrary(source:)` 运行时 JIT 编译 MSL 可用，本工程 7 个 kernel 全部由它编译 |
| 无法用 MLX Swift | 发现 **CommandLineTools SDK 自带 `MetalPerformanceShaders.framework`**（含 `MPSMatrixMultiplication.h`）；Swift `import MetalPerformanceShaders` 直接可用，fp16 转置 GEMM 实测正确 |
| `mlx-swift` C++ 仓库 / release CDN 不可达 | 不再需要；矩阵乘法改用 MPS，逐元素/归约算子自写 MSL |

算子语义来源（非臆造）：
- `research/upstream/mlx-swift-lm/Libraries/MLXLLM/Models/Hunyuan.swift`
- `research/upstream/mlx-swift-lm/Libraries/MLXLMCommon/RoPEUtils.swift`（`DynamicNTKAlphaRoPE`）
- 官方 `mlx 0.32.4` / HF `tokenizers 0.23.3` / `jinja2 3.1.6` 生成的离线 golden

---

## 2. 分阶段交付（每阶段独立实现 + 独立测试 + 性能）

### D1-α 算力基础

`MPSMatrixMultiplication(fp16, transposeRight=true)` 实测：
`A[1,4] × W[3,4]ᵀ → [1,2,7]`，与期望零误差。确认权重可按 `[out, in]` row-major 直接被 GEMM 引用，无需转置拷贝。

### D1-β 原生 BPE 分词器（`Sources/HymnNative/HymnTokenizer.swift`）

- 从 `tokenizer.json` 直接读取 3 条 Split 正则（数字 1–3 位隔离 / CJK 连续串隔离 / GPT-2 正则），实现 ByteLevel 字节↔Unicode 映射、greedy BPE（119,758 merges）、818 个 added token 最长匹配。
- `chat_template.jinja` 等价渲染：占位符不硬编码 Unicode，改由 `added_tokens` 的 id 反查。
- golden：`Golden/tokenizer-golden-v2.json`（31 样本，中/英/日/韩/阿/俄、数字、空白、特殊 token）+ `Golden/chat-template-golden.json`（5 用例）。
- 结果：**encode / decode / chat template 渲染 / 提示词 token id 全部零误差**；初始化 562.6–617.9 ms，编码吞吐 **32,310–34,201 tokens/s**（三次完整运行区间，见第 6 节；`Reports/tokenizer-perf.json`）。

### D1-γ fp16 权重缓存（`Sources/HymnNative/WeightCache.swift`）

- 一次性把 225 组 affine INT4 + 129 个 BF16 norm 权重解压为 **3,582,160,896 B** 页对齐 mmap 文件（354 张量）。
- 数据区可被 `MTLBuffer(bytesNoCopy:)` **零拷贝**包装；MPS 通过 `MPSMatrix(buffer:offset:)` 直接引用，运行时不必复制 3.58 GB。
- 与官方 `mlx.dequantize` golden：**110,720 元素零误差**；唯一例外是 `query_layernorm.weight[57] = 1.8643e-31`，小于 fp16 最小次正规 5.96e-8，下溢为 0 —— 已作为「fp16 次正规下溢例外」显式统计，不静默放宽容差。
- MPS GEMM 从零拷贝 buffer 真实读取权重：`cpu=0.101746 gpu=0.101746 rel=0.0000%`。
- 构建耗时 228.2 s（Debug 一次性），mmap 打开 1.49–3.17 ms（`Reports/cache-perf.json`）。

### D1-δ Metal 算子层（`Sources/HymnNative/MetalOps.swift`）

7 个 MSL kernel：`rms_norm_multi` / `rope_apply` / `kv_write` / `attention_decode` / `silu_mul` / `residual_add` / `embed_lookup`。

| 算子 | 对齐结果（最大绝对误差） |
|---|---|
| RMSNorm(2048) | 0.00217 |
| RoPE Q(16 heads, pos=3) | 0.00096 |
| RoPE K(4 heads, pos=3) | 0.00095 |
| post-RoPE QK-Norm | 0.00271 / 0.00252 |
| SiLU(gate)×up (6144) | 0.00092 |
| GQA decode attention (16Q/4KV, seq=7) | 0.00095 |
| 残差 / embedding 查表 | 0.00012 / 0 |

误差量级 = fp16 输出量化，公式本身正确。RoPE 静态基频 `10000×1000^(128/126) = 11,158,839.93` 与上游一致；手工 half-split 公式与 `mx.fast.rope` 最大差 `2.98e-7`。

### D1-ε 32 层完整 forward（`Sources/HymnNative/HymnModel.swift`）

严格按 `Hunyuan.swift` 组装：**RoPE 之后再 QK-Norm**（与 Qwen3 相反）、GQA 16Q/4KV、KV cache、SiLU MLP、tied `lm_head`。每 token 225 次 MPS GEMM + 258 次 compute kernel，全部在单个 command buffer 内按序编码、一次提交。

与 `Scripts/gen-forward-golden.py` 生成的 fp32 参考 golden（读同一 fp16 缓存、逐层 numpy 精确计算）对齐：

| 指标 | 结果 |
|---|---|
| logits 相关系数 | **0.999998** |
| logits 最大 / 平均绝对差 | 0.02339 / 0.003809 |
| 120,818 个 logits 中 `|Δ|<0.1` | **120,818 / 120,818** |
| argmax | 16883（与参考一致） |
| top-20 交集 | **20 / 20** |
| 第 32 层 hidden state | maxAbs 0.00213，corr 0.9999979 |

### D1-ζ 采样、生成循环与后端接入

- `Sources/HymnNative/HymnGenerator.swift`：`repetition penalty → temperature → top-k → top-p → softmax`，参数取 `generation_config.json`（temp 0.7 / top_p 0.8 / top_k 20 / rep 1.05 / eos 120020），xorshift64 可复现。
- `Sources/HymnCore/Backend/RealModelBackend.swift`：接入既有 `RequestScheduler`（maxConcurrency=1）、`CancellationRegistry` + `Task` 双通道取消、流式增量解码、SQLite 历史。
- `RealModelBackend.prepare()` 把 MPS kernel 预热前置，TTFT 从 **2844.9 ms 降至 1086–1122 ms**（三次完整运行区间，见第 6 节）。
- CLI `translate` 默认真实后端（`--fixture` 才用替身）；App 默认真实后端，prepare 失败时**显式**降级并提示，绝不静默。

---

## 3. 真实译文

| 输入 | 输出 | chunks |
|---|---|---|
| `Hello, nice to meet you.` (en→zh) | **您好，很高兴见到您。** | 6 |
| `机器学习正在改变世界。` (zh→en) | **Machine learning is changing the world.** | 7 |
| `Machine learning is transforming the world.` (en→zh) | **机器学习正在改变世界。** | 5 |

输出中不含 `[fixture]` 占位符。第三例为 CLI 独立复现（1,389 ms）。

---

## 4. 构建结果

```
swift build --disable-sandbox    → rc = 0，6 targets
产物：HymnCore / HymnNative / HymnStore / hymnctl / hymntest / HymnTranslate
```

Swift 6 严格并发修正（本轮）：`NSLock` 不能直接出现在 async 上下文（改为同步辅助函数）、`await` 不能写进 `||` 的 autoclosure、`Int.log2` 不可用、`%d` 格式化 3.58 GB 造成 Int32 显示溢出、`MPSMatrix` offset 需 16 对齐。链接器缺少 Developer 路径的 warning 属 CommandLineTools 环境固有，可忽略。

App：`Scripts/make-app.sh` 组装 v0.3.0，无窗口冒烟
`HYMN_SMOKE_OK verdictLines=17 isLUT4=false status=就绪：affine INT4 真实模型 · 32 层 Metal forward · 全程离线`。

**最终复核轮（口径修订时重跑）**：`./Scripts/build.sh` → `BUILD_OK rc=0`（增量 0.32 s），
`./Scripts/test.sh` → `TEST_OK rc=0`（`# pass 120 fail 0 total 120`），
`hymnctl translate --text "Hello, nice to meet you."` → 真实译文 `您好，很高兴见到您。`、
`tokens=6 elapsed=1491.98ms`、声明 `真实模型推理: YES`；
`.app` headless smoke 再次输出 `HYMN_SMOKE_OK … isLUT4=false`。

---

## 5. 测试报告

`Reports/test-report.md` / `Reports/test-run.log`：**120 / 120 通过，0 失败**。

| suite | 项数 | 内容 |
|---|---|---|
| compatibility / native-weights | 31 | 权重格式契约、Metal/CPU/官方 MLX 反量化对齐 |
| tokenizer | 7 | BPE / ByteLevel / chat template golden |
| weight-cache | 8 | fp16 缓存布局、逐张量 golden、零拷贝 GPU |
| metal-ops | 13 | 7 算子 + RoPE 基频 + detached 执行 |
| forward | 10 | 32 层 logits / hidden / top-k / 采样器 / 真实吞吐 |
| real-backend | 10 | 真实译文、TTFT、取消、单实例、主线程、内存 |
| scheduler / engine / store / glossary / thread-isolation / performance | 41 | 既有链路（仍用替身，明确标注） |

---

## 6. 性能数据（真实模型推理，非替身口径）

> **口径修订说明**：本节初稿引用的是**单次运行**的测量值。随后又完整复现了两轮
> `Scripts/build.sh` + `Scripts/test.sh`（均 rc=0、120/120）。GPU 频率与系统负载会让
> MPS 窄矩阵 GEMM 出现 10% 量级波动，因此**下表「权威值」取最后一次完整复现落盘的 JSON**，
> 并同时给出三次实测区间，避免把单次测量当作稳定基准。所有数值均为真实模型推理口径。

`Reports/forward-perf.json`（最终一轮，32 层单 token 稳态）：

| 指标 | 权威值 | 三次实测区间 |
|---|---|---|
| 每 token GEMM 数 | 225 | 固定 |
| 首次 forward（MPS kernel 预热） | 1920.29 ms（已前置到 prepare） | 1843–1920 ms |
| 稳态 GPU 时间 | **33.11 ms/token** | 29.48–33.11 ms |
| 稳态墙钟 | 38.54 ms/token ≈ **25.94 tokens/s** | 34.66–38.54 ms ≈ 25.94–28.9 tokens/s |
| 是否占用主线程 | 否 | 3/3 轮均为否 |

`Reports/real-inference-perf.json`（最终一轮，端到端）：

| 指标 | 权威值 | 三次实测区间 |
|---|---|---|
| TTFT（含 prompt prefill，warmup 已前置） | **1118.70 ms** | 1086.2–1122.0 ms |
| 首次请求总耗时 | 1536.43 ms | 1488–1536 ms |
| 取消响应 | CANCELLED，`engine.cancel` 8.35 ms | 8.35–42.55 ms |
| 调度并发峰值 | 1 | 3/3 轮均为 1 |
| 主线程 10 ms ticker | 120 次，最大间隔 **12.47 ms**，平均 10.01 ms | 最大间隔 11.80–12.47 ms |
| 进程峰值常驻内存 | **106.3 MB**（3.58 GB 权重由 mmap 零拷贝，不计入 RSS） | 104–113.4 MB |

数值精度不受运行波动影响（golden 固定）：logits corr **0.999998013** / maxAbs 0.023392 /
meanAbs 0.003809 / top-20 **20/20** / argmax 16883；第 32 层 hidden maxAbs 0.002134 /
corr 0.99999788。

其它口径：`tokenizer-perf.json` 32,310–34,201 tokens/s（分词）、`cache-perf.json`
（fp16 缓存打开 1.49–3.17 ms）、`native-perf.json`（权重反量化）、`perf.json`
（调度替身链路）——这四项均**不是模型推理性能**。**各口径互不混用。**

---

## 7. 明确边界与未交付项

1. **LUT4 仍未交付，且永不冒充**：目标 LUT4 权重不存在；现有 `mlx-community/Hy-MT2-1.8B-4bit` 是 `mode=affine, bits=4, group_size=64`。UI / CLI / 元数据 / SQLite `model_tag` 全部标注 `affine INT4 (NOT LUT4)`；`CompatibilityGuard` 与 `WeightContract` 双重拒绝把 INT4 当 LUT4 加载。
2. **MLX Swift 运行时仍未接入**（本机 C++ 仓库与 release CDN 不可达），但已不构成功能阻塞：D-1 走 MPS + 自写 Metal 算子，与上游 `Hunyuan.swift` 语义一致。
3. **精度边界**：权重以 fp16 常驻（非 fp32/BF16 原值），单张量 BF16 极小值下溢为 0；32 层累积后 logits 平均绝对差 0.0038。对翻译输出无可见影响，但不是逐比特等价。
4. **性能边界**：prefill 采用逐 token 前向（未做 batched prefill），长 prompt 的 TTFT 随长度线性增长；25.94–28.9 tokens/s 为 MPS 窄矩阵 GEMM 的三次实测区间，未做 fused dequant-matmul 或量化 GEMM 优化；性能数字是单次测量值，非多轮统计均值。
5. **翻译质量**：仅做样例级验证，未做 BLEU/COMET 等系统评测；未覆盖全部 33 种语言对与术语库强制生效的质量评估。

---

## 8. 关键文件

| 文件 | 作用 |
|---|---|
| `Sources/HymnNative/HymnTokenizer.swift` | 原生 BPE / ByteLevel / chat template |
| `Sources/HymnNative/WeightCache.swift` | fp16 权重缓存 + 零拷贝 MTLBuffer |
| `Sources/HymnNative/MetalOps.swift` | 模型超参 + 7 个 MSL kernel + MPS GEMM 封装 |
| `Sources/HymnNative/HymnModel.swift` | 32 层完整 forward |
| `Sources/HymnNative/HymnGenerator.swift` | 采样器 + 自回归生成循环 |
| `Sources/HymnCore/Backend/RealModelBackend.swift` | 真实推理后端（接入调度/流式/取消） |
| `Scripts/gen-forward-golden.py` | fp32 参考 forward golden（离线校准） |
| `Scripts/fetch-model.sh` / `make-app.sh` | 权重首次下载 / .app 组装 |
| `Golden/` | 官方 MLX / tokenizers / jinja2 校准数据 |
| `Models/Hy-MT2-1.8B-4bit/weights.fp16.bin` | 3.58 GB fp16 mmap 缓存 |

---

## 9. 复现

```bash
cd HymnTranslate
swift build --disable-sandbox
./Scripts/test.sh                        # 120/120
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
  .build/debug/hymnctl cache             # 缓存已存在则直接打开
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
  .build/debug/hymnctl forward           # 32 层 forward / top-10 logits
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
  .build/debug/hymnctl translate --text "Hello, nice to meet you." --tokens 40
./Scripts/make-app.sh                    # dist/HymnTranslate.app v0.3.0
```

> Python 的 `mlx` / `tokenizers` / `jinja2` / `numpy` 只用于生成 `Golden/` 校准数据，
> **不在交付软件的运行路径中**；运行时完全离线，模型首次下载除外。
