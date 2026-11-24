# HymnTranslate 阶段 A3：并列 MLX Swift 后端完成报告

生成时间：2026-11-21 11:5x (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`
前置阶段：A1 / A2 / A2′ / A2″（见 `Reports/stage-a1-a2-complete.md`）
核心原则：**并列，不替换**。D-1 的 `RealModelBackend` 仍是默认且唯一的生产后端；
MLX 后端必须显式选择。权重格式全程标注 `affine INT4 (NOT LUT4)`。

> ## ✅ 后续更新（2026-11-21，A3-UI）
>
> App 已增加**图形化后端开关**（分段选择器 + 切换状态机），不再只能靠环境变量：
> 双向热切换、在途请求守卫、失败显式回滚、切换后真实译文、主线程零阻塞均实证通过。
> 构建 `rc=0`、测试仍 **131/131**、`.app` 83 MB。**当时**默认后端仍是 D-1（G8 已变更）。
> 见 **`Reports/stage-a3-ui-backend-switch.md`** 与 `Reports/ui-backend-switch-perf.json`。
> 本文第 7 节「仍未交付」中「App UI 的图形化后端选择器」一条已由该阶段交付。

> ## 📌 后续状态更新（G4 / G8）
>
> 本文为 A3 时点快照；**G8 起默认后端已改为 `Hy-MT2-1.8B-1.25Bit.gguf`
> （Sherry STQ1_0 1.3125 bpw 常驻 Metal GEMV）**，D-1 / MLX 仍并列可显式选择，
> 测试基线升至 **164/164**。最新结论见 `Reports/stage-g4-resident-gemv.md`。

---

## 0. 结论

| 阶段 | 结果 |
|---|---|
| A3-1 MLX 侧真实译文 | ✅ 双向译文，与 D-1 语义一致 |
| A3-2 主工程并列 `MLXBackend` | ✅ CLI `--backend mlx`、App `HYMN_BACKEND=mlx` |
| A3-3 测试 / 性能 / 打包 | ✅ **131/131** 通过（原 120 + 新增 11）、`.app` 双模式冒烟通过 |

**官方 MLX Swift 运行时已从源码编译、加载真实 1.8B 权重、产出真实译文，并以并列后端接入现有调度/流式/取消/SQLite/UI 链路。D-1 未被动过。**

---

## 1. 架构设计：加法隔离

```
HymnCore / HymnNative / HymnStore   ← 零改动，零外部依赖（D-1 原生 Metal/MPS）
        ▲
        │ (InferenceBackend 协议)
        ├── RealModelBackend        ← 默认，hymn-native-metal-affine-int4-v1
        └── HymnMLX target (新增)
                └── MLXBackend     ← 并列，mlx-swift-hunyuan-affine-int4-v1
                        ├── HymnTokenizer → MLXLMCommon.Tokenizer 桥接
                        ├── LLMModelFactory.shared.load(from:using:)
                        └── MLXLMCommon.generate(promptTokens:...)
```

- `HymnCore` / `HymnNative` / `HymnStore` 的源码与 `Package.swift` target 声明**一字未改**。
- MLX 依赖全部为**本地 path 依赖**（`research/upstream/mlx-swift-lm`、`mlx-swift-main`），
  构建期不访问网络，符合全程离线要求。
- 独立 `HymnMLX` target 沿用 D-1 既有模式：`@unchecked Sendable` + `NSLock` 持有
  单个 `ModelContext`，由 `RequestScheduler.maxConcurrency == 1` 保证同一时刻只有一个请求
  访问模型；所有推理在 `Task.detached` 中执行。
- 复用 D-1 的 `RealModelBackend.buildPrompt` 与 `HymnTokenizer`，保证两个后端的
  **prompt 文本 / chat template / token ids / 采样参数完全一致**，对照才有意义。

---

## 2. 改动清单

| 文件 | 改动 |
|---|---|
| `Package.swift` | 新增 `HymnMLX` library + 2 个本地 path 依赖；`hymnctl` / `hymntest` / `HymnApp` 增加 `HymnMLX` 依赖。原文件备份于 `research/Package.swift.pre-a3` |
| `Sources/HymnMLX/MLXBackend.swift` | 新增：`MLXBackend`（`InferenceBackend`）、`HymnMLXTokenizer` 桥接、`MLXRuntimeBox` 单实例容器、watchdog 取消、流式增量解码 |
| `Sources/hymnctl/main.swift` | `import HymnMLX`；`translate` 支持 `--backend mlx` / `--mlx`；usage 更新 |
| `Sources/hymntest/MLXBackendTests.swift` | 新增 A3 独立测试套件（11 项） |
| `Sources/hymntest/main.swift` | 注册 `mlx-backend` stage |
| `Sources/HymnApp/AppModel.swift` | `HYMN_BACKEND=mlx` 显式切换并列后端；status 显示当前后端；默认 D-1 不变 |
| `Sources/HymnApp/main.swift` | headless smoke 支持 `HYMN_SMOKE_TRANSLATE=1` 实跑翻译，验证 `.app` 内 metallib 运行时路径 |
| `Scripts/make-app.sh` | 拷贝 `.build/out/Products/Debug/mlx-swift_Cmlx.bundle`（含 `default.metallib`）到 `Contents/Resources/` |
| `research/mlx-generate-probe/` | A3-1 隔离探针 |
| `Reports/mlx-a3-translations.json` | A3-1 译文与性能原始记录 |

---

## 3. A3-1：MLX 侧真实译文

同 prompt、同权重、同采样参数（temp 0.7 / top_p 0.8 / top_k 20 / rep 1.05）：

| 方向 | 输入 | MLX 官方运行时 | D-1 |
|---|---|---|---|
| en→zh | `Hello, nice to meet you.` | `你好，很高兴见到你。` | `您好，很高兴见到您。` |
| zh→en | `机器学习正在改变世界。` | `Machine learning is changing the world.` | `Machine learning is changing the world.`（完全一致） |

en→zh 仅敬称用词差异（「你」vs「您」），语义一致；zh→en 逐字一致。
差异来自两条权重精度路径（MLX affine INT4→**bf16** 反量化 vs D-1/golden 同一份 **fp16** 缓存）
与两套采样实现，属预期。A2″ 已用同一 prompt ids 验证两者 forward 的 **argmax 同为 16883**。

---

## 4. 测试结果：131 / 131

`./Scripts/build.sh` → `BUILD_OK rc=0`（37.97 s）；
`./Scripts/test.sh` → `# pass 131 fail 0 total 131`，`TEST_OK rc=0`。

新增 `mlx-backend` 套件 11 项（TAP 80–90）：

```
ok  后端如实声明执行模型推理        # identifier=mlx-swift-hunyuan-affine-int4-v1
ok  权重格式标注 affine INT4 且绝不冒充 LUT4
ok  MLX 与 D-1 是不同实现（并列而非替换）
ok  产出真实译文（非 fixture、含中文）  # 你好，很高兴见到你。 chunks=6
ok  流式首个 chunk 延迟可测            # TTFT=92.0 ms
ok  中→英反向翻译产出拉丁文本          # Machine learning is changing the world.
ok  生成过程可协作式取消              # CANCELLED
ok  并发请求经单实例调度且并发峰值恒为 1
ok  推理期间主线程 10ms tick 正常     # ticks=120
ok  主线程最大 tick 间隔 < 100ms      # max=12.30 ms avg=10.01 ms
ok  峰值常驻内存可测且在预算内        # peak=1187 MB
```

**一次测试修正（如实记录）**：首轮 130/131，取消用例失败
（`未被取消 chunks=8`）——原因是测试在 300 ms 后发取消，而 MLX 生成仅 182 ms 就已 EOS 结束，
不是后端缺陷。改为长 prompt 拉长 prefill + 30 ms 取消窗口后，真实触发了中途取消，131/131。

---

## 5. 两后端性能对照（同一次测试运行）

数据：`Reports/mlx-backend-perf.json` vs `Reports/real-inference-perf.json`。

| 指标 | MLX 并列后端 | D-1 默认后端 | 说明 |
|---|---|---|---|
| 译文 en→zh | 你好，很高兴见到你。 | 您好，很高兴见到您。 | 语义一致 |
| TTFT | **92.01 ms** | 1113.27 ms | MLX 一次 batched prefill；D-1 逐 token prefill |
| 首次请求总耗时 | 187.33 ms | 1527.60 ms | 单次测量 |
| 取消响应 | 243.85 ms | **12.86 ms** | MLX 同步 `generate` 只能在 `didGenerate` 边界响应 |
| 调度并发峰值 | 1 | 1 | 两者均满足单实例 |
| 主线程 tick 最大间隔 | 12.30 ms | 12.46 ms | 两者均零阻塞 |
| **峰值 RSS** | **1187.2 MB** | **143.3 MB** | D-1 的 3.58 GB fp16 权重由 mmap 零拷贝不计入 RSS；MLX 权重常驻 |

> **口径声明**：以上均为**单次测量、有波动**，非多轮统计均值。
> A3-1 独立探针冷启动时首次 `prompt_ms=4086 ms`（含 MLX kernel 预热），
> 而测试进程在 `mlx-backend` 之前已跑过 `real-backend` 的 Metal 计算、GPU 已热，
> 因此 TTFT 92 ms 不能当作冷启动值。两个口径不可混用。
> MLX 的 `forward_ms=712.7`（A2″，4-token prefill）也不是 token/s 或 TTFT。

**结论**：MLX 在长 prompt prefill 上明显更快（batched prefill），但内存占用高约 8 倍、
取消延迟高约 20 倍；D-1 在内存与取消响应上占优。两者各有取舍，因此**并列而非替换**是合理设计。

---

## 6. App 双模式验证

`./Scripts/make-app.sh` 组装 v0.3.0 + A3（82 MB，含 4.4 MB `default.metallib`）。

```
# 默认 D-1
HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 →
  HYMN_SMOKE_TRANSLATION output=您好，很高兴见到您。 status=完成 · 6 chunks
  HYMN_SMOKE_OK … status=完成 · 6 chunks history=1

# 显式 MLX
HYMN_BACKEND=mlx HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 →
  HYMN_SMOKE_TRANSLATION output=你好，很高兴见到你。 status=完成 · 6 chunks
  HYMN_SMOKE_OK … isLUT4=false
```

不带 `HYMN_SMOKE_TRANSLATE` 时两模式的状态行分别为
`… · 32 层 Metal forward · 全程离线` 与 `… · MLX Swift 运行时〔并列后端〕 · 全程离线`，
**显式标识当前后端，绝不静默切换**。

CLI 同理：
```
hymnctl translate --text "Hello, nice to meet you." --backend mlx
  → 后端: mlx-swift-hunyuan-affine-int4-v1 / 真实模型推理: YES / 你好，很高兴见到你。
hymnctl translate --text "Hello, nice to meet you."
  → 后端: hymn-native-metal-affine-int4-v1 / 您好，很高兴见到您。
```

---

## 7. 边界与未交付

1. **A3 时点**：D-1 是默认且唯一生产后端；MLX 必须靠 `--backend mlx` 或 `HYMN_BACKEND=mlx` 显式选择。
   ⚠️ 后续 G8 已把默认改为 Sherry 1.25bit GGUF，D-1 / MLX 仍并列可显式选择，见本文顶部状态更新块。
   未按 A3 结论替换或关闭 D-1。
2. **LUT4 权重仍不存在，永不冒充**：UI / CLI / SQLite `model_tag` / 所有报告均标
   `affine INT4 (NOT LUT4)`。
3. **MLX 取消是协作式且粒度粗**：同步 `generate` 只在 `didGenerate` 回调边界检查取消标志，
   长 prefill 下延迟可达数百毫秒；如需更细粒度需改用 `AsyncStream` 版 generate API。
4. **内存**：MLX 权重常驻约 1.19 GB，D-1 约 143 MB（mmap 零拷贝）。18 GB 机器均无压力，
   但低内存设备上 MLX 后端成本更高。
5. **仍未做**：BLEU/COMET 系统级翻译质量评测、全部 33 种语言对覆盖、
   MLX 侧 batched prefill / 量化 KV cache 调优、后端选择的重启持久化（`UserDefaults`）。
   ~~App UI 的图形化后端选择器~~ 已于 A3-UI 交付，见
   `Reports/stage-a3-ui-backend-switch.md`。
6. **性能数字均为单次测量**，未做多轮统计；不同进程冷/热状态差异已在第 5 节说明。

---

## 8. 复现

```bash
cd HymnTranslate
./Scripts/verify-xcode.sh                    # RESULT: READY
./Scripts/build.sh                          # BUILD_OK rc=0
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" ./Scripts/test.sh   # 131/131

# CLI 并列后端
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" \
  .build/debug/hymnctl translate --text "Hello, nice to meet you." --backend mlx

# App 双模式
./Scripts/make-app.sh
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" HYMN_HEADLESS_SMOKE=1 \
  HYMN_SMOKE_TRANSLATE=1 dist/HymnTranslate.app/Contents/MacOS/HymnTranslate
HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit" HYMN_BACKEND=mlx \
  HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 \
  dist/HymnTranslate.app/Contents/MacOS/HymnTranslate
```

关键产物：`Reports/mlx-backend-perf.json`、`Reports/real-inference-perf.json`、
`Reports/mlx-a3-translations.json`、`Reports/mlx-a2-forward.json`、
`Reports/test-report.md`、`dist/HymnTranslate.app`。
