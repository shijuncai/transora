# G4 / G8 阶段报告：1.25bit GGUF 常驻 GEMV 与默认后端切换

生成时间：2026-11-21 13:3x (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`
前置：`stage-g1-sherry-backend.md`（G1 链路打通）、`model-migration-plan.md`（G0–G8 计划/进度表）
关联数据：`sherry-resident-golden.json`、`sherry-resident-perf.json`、`test-report.md`

> ## ✅ 结论
>
> 用户要求「继续做 G4 常驻 GEMV，把 1.25bit 真正跑成 1.31 bpw；默认后端替换成
> `Hy-MT2-1.8B-1.25Bit.gguf`」两项**均已完成并实证**：
> - 默认后端现在是 **Sherry STQ1_0 1.25bit GGUF 常驻 GEMV**；
> - 224 个线性层以 **42 B/256 = 1.3125 bpw 常驻**，GGUF 原始 `461,860,800 B`
>   一次性拷入 `MTLBuffer`，运行时**不再生成/读取 3.58 GB `weights.fp16.bin`**；
> - 构建 `BUILD_OK rc=0`、测试 **164/164**、CLI 与 App 默认均产出真实译文；
> - D-1（affine INT4 NOT LUT4）与 MLX 仍并列，可显式选择；STQ1_0 永不冒充 LUT4 / affine INT4。

---

## 1. 口径声明（最重要）

| 概念 | 本阶段实际情况 |
|---|---|
| 权重格式 | **Sherry STQ1_0 1.3125 bpw 常驻 GEMV**（NOT LUT4、NOT affine INT4、NOT fp16 展开缓存） |
| 线性层常驻密度 | 224 个 STQ1_0 线性层，42 B / 256 权重 = **1.3125 bpw** |
| 常驻 buffer | GGUF 原始 **461,860,800 B**（440.5 MiB）拷入一个 `MTLBuffer`；Q6_K embedding 保持 210 B/256 |
| 非量化元数据 | 129 个 F32 norm → `282,624 B` fp16 小 buffer；KV cache / 激活仍为 fp16 |
| `weights.fp16.bin` | **仅离线 golden 生成与历史对照保留**，运行时零依赖；已从 `SherryBackend.prepare()` 移除检查 |
| 整文件 ≠ 1.31 bpw | 461,860,800 B 含 Q6_K embedding、F32 norm、metadata、对齐；**1.3125 bpw 只描述 224 个线性层** |
| Python | 仅 `Scripts/gen-sherry-golden.py` 离线生成 Golden；**运行时全程 Swift / Metal** |

与 G1 的「GGUF → 3,582,160,896 B fp16 展开缓存 → MPS GEMM」相比，权重 buffer 缩小约 **7.76×**。
但 D-1 的 3.58 GB 走 mmap 零拷贝不计入 RSS，所以**不能说 Sherry 的 RSS 低于 D-1**（见第 6 节）。

---

## 2. 实现结构（加法隔离，未改 HymnCore / HymnNative 推理语义）

| 模块 | 职责 |
|---|---|
| `Sources/HymnSTQ/SherryGEMV.swift` | 3 个 MSL kernel：`stq1_0_gemv`、`q6_k_embed_row`、`q6_k_gemv`；权重按 block 原地解码即乘加 |
| `Sources/HymnSTQ/SherryResidentModel.swift` | 354 张量按 GGUF offset 映射；461,860,800 B 常驻 `MTLBuffer`；32 层 forward；每 token **225 次常驻 GEMV** |
| `Sources/HymnSTQ/SherryGenerator.swift` | 复用 `Sampler` / `SamplingConfig` / `GenerationMetrics`，语义与 D-1 完全一致 |
| `Sources/HymnSTQ/SherryBackend.swift` | 改接常驻模型；`performsRealModelInference=true`；`HYMN_SHERRY_MODEL_DIR` **严格优先**，无效目录不静默回退 |
| `Scripts/gen-sherry-golden.py` | 独立 Python：从 GGUF 原始字节生成 GEMV / embedding / 32 层 forward golden |
| `Sources/hymntest/SherryResidentTests.swift` | 10 项：常驻字节、无缓存 prepare、GEMV/embedding/forward 对齐、主线程、算子计数 |
| `Sources/hymntest/SherryBackendTests.swift` | 11 项：端到端译文、单实例、取消、主线程、性能落盘 |

算子来源（**未自行编造**）：
- llama.cpp PR #22836 `stq1_0_codebook[32]` / `dequantize_row_stq1_0`；
- `ggml-quants.c` `dequantize_row_q6_K` + `ggml-common.h` `block_q6_K`；
- 权威源码副本固化在 `research/upstream/stq1_0-reference/`。
- 非线性算子（RMSNorm / RoPE / post-RoPE QK-Norm / GQA / SiLU / residual）继续复用
  D-1 已与 fp32 golden 对齐的 `MetalOps`，未重写语义。

`HymnNative/HymnModel.swift` 与 `HymnGenerator.swift` 仅补了两个 `public init`
（`ForwardMetrics` / `GenerationMetrics` 的 memberwise init 原为 internal），无语义改动。

---

## 3. 独立 golden 与数值对齐

`Scripts/gen-sherry-golden.py` 生成两类 golden，均不进运行时：

1. **GEMV / embedding golden**：Python 直接从 GGUF 原始字节按权威公式解码，
   对 4 个张量的前若干行做 `W_fp16 · x_fp16`，与 Metal kernel 输出比对；
   另解码 `token_embd.weight` 第 120000 行与 `q6_k_embed_row` 比对。
2. **32 层 forward golden**：用同一份反量化权重的 fp16 展开缓存跑 fp32 参考 forward，
   验证常驻模型把各层组装后的 logits / hidden。prompt ids 与 D-1 相同：
   `[120000, 120006, 28036, 120007]`。

| 指标 | 结果 |
|---|---|
| GEMV 样本 | 4 组 / 80 个元素，`maxAbs = 7.6293945e-06`，`minCorr = 0.9999999996` |
| Q6_K embedding 行 | 2048 元素，`maxAbs = 0.0` |
| 32 层 logits | `corr = 0.99999946`，`maxAbs = 0.01266`，top-20 **20/20** |
| argmax | **28036**（与 Sherry fp32 golden 一致；与 4bit 的 16883 不同是权重不同，属预期） |
| layer32 hidden | `corr = 0.99999959`，`maxAbs = 0.0084` |
| 每 token 算子数 | 225 次常驻 GEMV + 258 个 Metal 非线性/逐元素 kernel |
| 单 token GPU 时间 | `38.03 ms`（`sherry-resident-golden.json` 内一次测量，非稳态均值） |

前向权重来自 1.25bit GGUF，所以新的 fp32 golden argmax 是 28036；
A2″ 的 16883 是 4bit affine INT4 权重下的结果，两者**不可混用**。

---

## 4. G8：默认后端切换

| 位置 | 变更 |
|---|---|
| CLI `hymnctl translate` | 不带 `--backend` 时默认 `SherryBackend()`；`--backend native|mlx|sherry` 显式选择 |
| CLI `modelTag` | 改为 `backend.identifier` 动态写入，不再硬编码 4bit 后端标识 |
| App `AppModel` | `BackendChoice` 默认 `.sherry`；`HYMN_BACKEND=native|mlx|sherry` 仅作启动覆盖 |
| UI | 状态栏、输出标签、权重格式、后端说明、窗口标题全部动态跟随实际后端 |
| `make-app.sh` | 新增 `Hy-MT2-1.8B-1.25Bit-GGUF` Application Support 软链；`.app` 升 v0.4.0，约 84 MB |
| `Package.swift` | 注释更新为「默认 Sherry 常驻 GEMV，D-1/MLX 并列」 |
| `sherry-cache` CLI | 保留但标注「仅离线 golden 用」，运行时不再需要 |

**一处实证修正**：初版 `locateSherryModelDirectory()` 在 `HYMN_SHERRY_MODEL_DIR`
指向无效目录时会继续回退到工程目录，导致故障注入时「切换 Sherry」仍成功。
已改为**环境变量严格优先**；重跑故障注入得到 `success=false`、显式回滚 D-1、回滚后仍真译。

---

## 5. 构建、测试与冒烟

| 项 | 结果 |
|---|---|
| `./Scripts/build.sh` | `BUILD_OK rc=0`（0 error） |
| `./Scripts/test.sh` | `TEST_OK rc=0`，**164/164**（G1 的 154 + `sherry-resident` 10 项） |
| CLI 默认 | `hymn-stq1_0-gguf-v1` → `你好，很高兴见到你。` |
| CLI `--backend native` | `hymn-native-metal-affine-int4-v1` → `您好，很高兴见到您。` |
| App 默认 headless smoke | `backend=sherry identifier=hymn-stq1_0-gguf-v1`，真译通过 |
| App `HYMN_BACKEND=native` | 真译 `您好，很高兴见到您。` |
| 图形开关 Sherry→MLX | `success=true switchMs=964`，tick max `28.09 ms` / avg `10.15 ms` |
| 图形开关 Sherry→native | `success=true switchMs=2730`，tick max `27.59 ms` / avg `10.10 ms` |
| 在途请求守卫 | `unchanged=true switches=0`，提示先取消 |
| 故障注入（Sherry 目录缺 GGUF） | `success=false`，回滚 D-1，回滚后仍真译 |
| `.app` | v0.4.0，84 MB，含 `mlx-swift_Cmlx.bundle` 与 GGUF 软链 |

套件顺序调整：`sherry-resident` 放在 `real-backend` / `mlx-backend` **之后**，
避免 461 MB 常驻 buffer 抬高 `ru_maxrss` 历史峰值、污染既有后端的内存断言。

---

## 6. 性能数据（单次测量，口径不混用）

`Reports/sherry-resident-perf.json`（测试进程内，端到端后端链路）：

| 指标 | 值 |
|---|---|
| `prepare_ms` | 715.9（含 Metal kernel 预热） |
| en→zh | `你好，很高兴见到你。`，6 chunks，TTFT `888.72 ms`，wall `1143.86 ms` |
| zh→en | `Machine learning is changing the world.`，7 chunks，TTFT `728.81 ms`，wall `1026.11 ms` |
| 取消响应 | `42.03 ms` |
| 主线程 10 ms tick | max `11.79 ms`，avg `9.99 ms`（<100 ms 判据） |
| 调度并发峰值 | 1 |
| `peak_rss_mb` | `2606.8` ⚠️ **进程历史峰值**，含此前 MLX 套件约 1.2 GB 峰值，**不是 Sherry 独占** |

`approx_tokens_per_second` 是 `chunks / wall` 的粗略端到端值（5.25 / 6.82），
**不是纯 decode token/s**；TTFT 是端到端首个 chunk 墙钟，不是 GPU 时间。

**独立进程峰值 RSS**（`/usr/bin/time -l`，各自只跑一个后端，cold start）：

| 后端 | maximum RSS | 备注 |
|---|---|---|
| Sherry 常驻 GEMV（默认） | `1,010,581,504 B` = **963.8 MiB** | 含 461,860,800 B 常驻 GPU buffer + Metal/Foundation 运行时 |
| D-1 native | `113,737,728 B` = **108.5 MiB** | 3.58 GB fp16 权重 mmap 零拷贝，不计入 RSS |
| MLX | `1,122,156,544 B` = **1070.2 MiB** | bf16 权重常驻 |

结论：Sherry 的**权重 buffer** 比 3.58 GB fp16 展开缓存小约 7.76×，进程峰值也低于 MLX；
但 RSS 仍高于 D-1，因为 D-1 走零拷贝 mmap。**1.25bit 的优势是权重常驻体积与离线文件体积，
不是「RSS 低于 D-1」**，这一点如实标注，不夸大。

`sherry-backend-perf.json` / `real-inference-perf.json` / `mlx-backend-perf.json`
是各后端测试进程内的历史数据；本轮测试进程三后端叠加，`peak_rss_mb` 不可横向比较，
横向比较请用上表独立进程测量。

---

## 7. 计划表 / 进度表与文档同步

- `Reports/model-migration-plan.md`：顶部状态改为 **G0–G8 全部完成**；
  新增第 4.2 节记录常驻 GEMV 落地；进度表 G4/G5/G6/G7/G8 全部 100%；
  当前生产基线改为「测试 164/164，默认 Sherry 1.25bit GGUF，`.app` 84 MB」。
- `Reports/stage-summary.md`：顶部状态块重写为 G4/G8 完成，旧 D-1 / G1 状态块标注为历史。
- `stage-g1-sherry-backend.md` / `stage-a3-complete.md` / `stage-a3-ui-backend-switch.md` /
  `stage-a1-a2-complete.md` / `stage-d2-probe.md`：均加「后续状态更新」块，
  明确旧「默认 D-1」是时点快照，G8 后已变更。
- 项目记忆 `MEMORY.md` 与当日日志同步（G4/G8 完成、默认后端、常驻字节、口径）。

---

## 8. 仍未交付（如实列出）

- LUT4 权重：官方不存在，**永不冒充**；
- 量化 KV cache / batched prefill / fused dequant-GEMM 优化；
- BLEU/COMET 系统级翻译质量评测、全部语言对覆盖；
- 后端选择的 `UserDefaults` 重启持久化、真实鼠标点击的像素级 UI 自动化；
- v2 GGUF（`type=40`）格式解析（明确排除，无权威参考）。

---

## 9. 复现

```bash
cd /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate
python3 Scripts/gen-sherry-golden.py        # 离线独立 golden，仅首次需要
./Scripts/build.sh                          # BUILD_OK rc=0
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
HYMN_SHERRY_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-1.25Bit-GGUF" \
  ./Scripts/test.sh                         # 164/164
.build/debug/hymnctl translate --text "Hello, nice to meet you." --tokens 40
./Scripts/make-app.sh
HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 \
  dist/HymnTranslate.app/Contents/MacOS/HymnTranslate
```
