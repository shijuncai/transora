# G1 阶段报告：Sherry STQ1_0 1.25bit GGUF 并列后端

生成时间：2026-11-21 13:0x (GMT+8)
计划/进度表：`Reports/model-migration-plan.md`（本轮已同步）
前置：`stage-a3-ui-backend-switch.md`（三选一开关本轮由两选一扩展）

> ## 📌 历史阶段报告（已被 G4 取代，保留作决策轨迹）
>
> 本阶段 G1 完成「GGUF 解码 → 3.58 GB fp16 展开缓存 → 复用 D-1 的 32 层
> Metal/MPS forward」的**链路打通**：`BUILD_OK rc=0`、测试 **154/154**、
> CLI 与 `.app` 双向真实译文均通过；当时默认后端仍是 D-1。
>
> ⚠️ 当时的关键口径：源文件 440 MB，但运行时权重展开为 3.58 GB fp16 缓存，
> **不是 1.31 bpw 常驻推理**。该捷径在 **G4 已被常驻 Metal GEMV 取代**：
> `461,860,800 B` GGUF 常驻 `MTLBuffer`、运行时不再需要 `weights.fp16.bin`，
> **默认后端也已改为 `Hy-MT2-1.8B-1.25Bit.gguf`**（G8），测试基线升至 **164/164**。
> 最新结论与完整证据见 **`Reports/stage-g4-resident-gemv.md`**；
> 本文以下数字与「默认后端 D-1」表述均为 G1 时点快照，不代表当前状态。

---

## 1. 版本决策与下载校验

| 项 | 结果 |
|---|---|
| 选定文件 | `Hy-MT2-1.8B-1.25Bit.gguf`（**v1**），461,860,800 B |
| SHA256 | `cc497fe8f033b52b3b8b00a7669e9661435432f9d4cd43f7ed24400c01507a93` — 与 HF LFS API (`?blobs=true`) **完全一致** |
| 下载 | hf-mirror 206 全量，59 s / 8.0 MB/s |

**为什么选 v1 而不是 v2**：两个文件同为 461,860,800 B，但头部实证显示
v1 线性层 `type=42`（`STQ1_0`，224 个，1.3125 bpw），v2 线性层 `type=40`
且 `general.finetune=1.25bit-new`，是**另一种无权威参考的量化格式**。
v1 与 llama.cpp PR #22836 早期枚举、第三方 `kuotient/Hy-MT2-1.8B-1.25Bit-MLX`
parity 参考（sha256 同源）一致，风险最低。

**枚举编号的重要发现**：PR #22836 当前 mainline 已把 `STQ1_0` 从 42 挪到 43
（新插入 NVFP4=40 / Q1_0=41 / Q2_0=42）。该 GGUF 生成于 PR 早期，
**42 就是 STQ1_0**。按当前枚举误读会全盘解码错误，已写入 `GGUFFile.swift` 注释。

## 2. 权威算子定义（未自行编造）

固化在 `research/upstream/stq1_0-reference/`：

- `pr22836.patch` — PR #22836 全部 17 个文件的 diff，含
  `block_stq1_0`（`qs[32] + sign[8] + fp16 d = 42 B / 256 权重`）、
  `stq1_0_codebook[32]`、`dequantize_row_stq1_0` 的 **stride-16 位置映射**
  `y[(g/16)*64 + (g%16) + p*16]`；
- `ggml-common.h` / `q6k-dequant.c` — `block_q6_K`（`ql[128]+qh[64]+scales[16]+d = 210 B`）
  与 `dequantize_row_q6_K`；
- `research/upstream/sherry-ref/sherry_model.py` — 第三方 MLX 移植，其
  `_CODEBOOK` 32 项与 PR **逐项一致**、`_perms()` 位置映射一致（仅作离线参考）。

本地头部实测 **223/224 个 type=42 张量全部为 1.3125 bpw**，与 42 B/256 结构吻合。

## 3. 新增模块（加法隔离）

| 文件 | 作用 |
|---|---|
| `Sources/HymnSTQ/GGUFFile.swift` | GGUF v3 mmap 读取器：metadata / 354 张量 / data 区对齐 / `withBytes(for:)` |
| `Sources/HymnSTQ/QuantizedBlocks.swift` | `STQ1_0` / `Q6_K` / `GGUF_F32` CPU 参考解码 + fp16 位转换 |
| `Sources/HymnSTQ/SherryCacheBuilder.swift` | GGUF → 与 D-1 `WeightCache` 同构的 fp16 缓存；354 个 llama.cpp 张量名 → HF 名映射 |
| `Sources/HymnSTQ/SherryBackend.swift` | 并列第三后端，复用 `RealModelBackend.buildPrompt` + `HymnModel` 32 层 forward |
| `Scripts/gen-gguf-golden.py` | **独立 Python 实现**生成离线 golden（不引用 Swift 代码） |
| `Sources/hymntest/GGUFTests.swift` | `gguf-reader` 12 项 |
| `Sources/hymntest/SherryBackendTests.swift` | `sherry-backend` 11 项 |
| `Sources/hymnctl/main.swift` | `hymnctl sherry-cache --rebuild`、`--backend sherry` |
| `Sources/HymnApp/*` | 图形开关由两选一扩为**三选一**；权重格式标注随后端动态变化 |

`HymnCore` / `HymnNative` / `HymnStore` / `HymnMLX` **零改动**。

## 4. 构建与测试

| 项 | 结果 |
|---|---|
| `./Scripts/build.sh` | `BUILD_OK rc=0`，0 error |
| `./Scripts/test.sh` | `TEST_OK rc=0`，**# pass 154 fail 0 total 154**（原 143 + `sherry-backend` 11） |
| `gguf-reader` 12 项 | 全绿；STQ1_0 **5120 元素**、Q6_K **1024 元素**与独立 Python/PR 参考 **逐元素零误差**（maxAbs=0.0） |
| `sherry-backend` 11 项 | 全绿；缓存 354 张量 / 3,582,160,896 B、HF 名映射完整、真实译文、并发峰值 1、取消 43.2 ms、主线程 tick max **12.09 ms**（<100 ms） |
| 缓存构建 | `SHERRY_CACHE_OK tensors=354 (stq=224 q6=1 f32=129) bytes=3582160896 elapsed=136423.8 ms` |

缓存字节数与 D-1 的 fp16 缓存**完全相同**，互证参数量与张量映射无遗漏。

## 5. 真实译文对照（同 prompt / 同采样参数）

| 后端 | en→zh | zh→en |
|---|---|---|
| **Sherry STQ1_0 GGUF**（本轮） | **你好，很高兴见到你。** | **Machine learning is changing the world.** |
| MLX Swift（A3） | 你好，很高兴见到你。 | Machine learning is changing the world. |
| D-1 affine INT4 | 您好，很高兴见到您。 | Machine learning is changing the world. |

敬称差异来自量化权重网格不同（QAT 1.25bit vs affine INT4 bf16）；
`zh→en` 三后端逐字一致。CLI 耗时 Sherry 1190.56 ms / 1061.94 ms（单次，含预热后首请求）。

## 6. App 图形开关（三选一）

`HYMN_SMOKE_*` headless 冒烟全部通过：

| 场景 | 结果 |
|---|---|
| `HYMN_BACKEND=sherry` 直接启动 + 真译 | `backend=sherry` → `你好，很高兴见到你。` |
| 图形开关 D-1 → Sherry + 真译 | `success=true switchMs=2478 ticks=248 maxTickMs=29.84 avgTickMs=10.09` |
| 默认 D-1 回归 | `backend=native` → `您好，很高兴见到您。` |

`.app` 83 MB。切换到 Sherry 时右上角权重格式标签自动变为
`Sherry STQ1_0 1.3125 bpw (NOT LUT4, NOT affine INT4)`；
切回 D-1/MLX 恢复 `affine INT4 (bits=4, group=64, NOT LUT4)`。
右侧「权重契约」区标题已注明是 **4bit 基线对照**，避免与当前后端混淆。

## 7. 口径与未交付

**必须如实说明的取舍**：
- 当前实现把 STQ1_0/Q6_K 解码后**展开成 3.58 GB fp16 mmap 缓存**，
  复用 D-1 已验证的 MPS GEMM；**没有实现 1.31 bpw 常驻 Metal GEMV**，
  因此尚未兑现 1.25bit 模型的内存/速度优势。GGUF 源文件 440 MB 只是磁盘占用。
- 所有耗时均为**单次测量**；缓存构建 136.4 s 是一次性离线准备，不是推理性能。
- `sherry-backend-perf.json` 里的 prepare/取消/tick 是后端链路数据，不是 TTFT/token·s⁻¹。

**后续状态（G4 / G8 已由 `stage-g4-resident-gemv.md` 闭环）**：
1. ✅ 常驻 STQ1_0 Metal GEMV 已实现（461,860,800 B 常驻，不再展开 3.58 GB fp16）；
   ⚠️ 量化 KV cache 仍未做；
2. ✅ **G8 默认后端已改为 `Hy-MT2-1.8B-1.25Bit.gguf`**；D-1 / MLX 仍并列；
3. 切换后重启持久化、`UserDefaults`；
4. BLEU/COMET 系统级评测、全部语言对覆盖；
5. v2 GGUF（`type=40`）格式解析（本轮明确排除）；
6. LUT4 权重（官方不存在，永不冒充）。

## 8. 复现

```bash
cd /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate
python3 Scripts/gen-gguf-golden.py                 # 独立 golden
./Scripts/build.sh                                # BUILD_OK rc=0
./Scripts/test.sh                                 # 154/154
.build/debug/hymnctl sherry-cache --rebuild      # 一次性生成 3.58 GB 缓存
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
  .build/debug/hymnctl translate --text "Hello, nice to meet you." \
    --from en --to zh --tokens 40 --backend sherry

# App 三选一
HYMN_SHERRY_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-1.25Bit-GGUF" \
HYMN_BACKEND=sherry HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 \
  dist/HymnTranslate.app/Contents/MacOS/HymnTranslate
```

数据：`Reports/gguf-perf.json`、`Reports/sherry-backend-perf.json`、
`Golden/gguf-golden-manifest.json` + 5 个 `gguf-*.f32`。
