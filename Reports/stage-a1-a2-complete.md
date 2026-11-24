# HymnTranslate 阶段 A1 / A2：MLX Swift 源码编译完成报告

生成时间：2026-11-21 11:12 (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`
路线：**方案 A（安装完整 Xcode，源码编译 MLX Swift）**
口径声明：本报告证明「官方 MLX Swift 运行时在本机编译通过并在 GPU 上执行最小计算」、
「`mlx-swift-lm` 的 `hunyuan_v1_dense` 已编译注册」，以及（新增第 9 节）
「MLX 已加载真实 1.8B 权重并跑通 32 层 forward，与 D-1 golden 的 argmax 一致」。
**仍未产出译文、仍未接入主工程**。D-1 的 `RealModelBackend` 仍是默认推理后端，
主工程 `Package.swift` / `Sources/` / `dist/` 零改动。

> ## 📌 后续状态更新（G4 / G8）
>
> 本文为 A1/A2 时点快照；**G8 起默认后端已改为 `Hy-MT2-1.8B-1.25Bit.gguf`
> （Sherry STQ1_0 常驻 GEMV）**，D-1 / MLX 仍并列可显式选择。
> 最新结论见 `Reports/stage-g4-resident-gemv.md` 与 `Reports/model-migration-plan.md`。

---

## 0. 结论

| 阶段 | 结果 |
|---|---|
| A1 源码编译 MLX Swift | **成功**：`BUILD_OK rc=0`，`MLX_SWIFT_PROBE_OK device=gpu` |
| A2 源码编译 mlx-swift-lm | **成功**：`MLX_LM_PROBE_OK hunyuan_v1_dense_registered=true` |
| 回归 | A1 `rc=0`、主工程 `BUILD_OK rc=0`、测试 **120/120** |

关键结论：**此前「MLX Swift 运行时不可达」的阻塞已彻底解除**。现在本机有一份从源码编译、
含官方 C++ / Metal / Swift 全栈的 MLX 运行时，且能驱动 Apple M3 Pro 的 GPU。

---

## 1. 环境（用户侧两步完成后）

```
Xcode 27.2 (27B52)
developer dir: /Applications/Xcode.app/Contents/Developer
metal / metallib / metal-ar:
  /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.2.47.0.../Metal.xctoolchain/usr/bin/
swift: Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
SDK: MacOSX27.2.sdk
./Scripts/verify-xcode.sh → RESULT: READY (rc=0)
```

Metal Toolchain 通过 cryptex 挂载；`XcodeDefault.xctoolchain/usr/bin/metal` 只是 stub，
真正编译器来自下载的组件。

---

## 2. 一处必须纠正的旧判断

`stage-d2-probe.md` 第 1 节曾写「`Source/Cmlx/mlx` / `mlx-c` 空目录只是 submodule 占位，
不影响编译」——**这是错的**。当时 CommandLineTools 探针在 `CompileMetalFile` 阶段就中止，
C++ 尚未真正走到 `mlx-conditional/*.cpp`，因此没暴露问题。装上 Metal 编译器后全量编译，
立即出现：

```
mlx-conditional/jaccl_conditional.cpp:11: fatal error: '../mlx/mlx/distributed/jaccl/jaccl.cpp' file not found
mlx-conditional/jit_compiler_conditional.cpp:11: fatal error: '../mlx/mlx/backend/cpu/jit_compiler.cpp' file not found
```

`mlx-generated/` 里只是 **MSL kernel 的 C++ 源码字符串**（`R"preamble(...)"`），
MLX 的 array / ops / backend 核心实现确实在 submodule 中。已按官方 `.gitmodules` 与
GitHub API 查到的精确 commit 补齐，不是 hack：

| submodule | commit | 文件数 |
|---|---|---|
| `Source/Cmlx/mlx` | `36969c094354086e15d2a327a9c50feb20b9cf11` | 982 |
| `Source/Cmlx/mlx-c` | `a26f2d584a14ec619ae8db9a09be03becd47598a` | 136 |

补齐后 4 个关键文件全部到位：`mlx/backend/cpu/compiled.cpp`、`jit_compiler.cpp`、
`mlx/distributed/jaccl/jaccl.cpp`、`no_jaccl.cpp`。

---

## 3. A1 构建结果（MLX Swift 全栈源码）

`./Scripts/build-mlx-swift.sh` → `BUILD_OK rc=0`，日志 `Reports/mlx-swift-build.log`。

| 项 | 值 |
|---|---|
| 首次全量编译耗时 | 41.21 s |
| 编译 error | **0**（warning 342，均为上游代码自身） |
| C++ `.o` 产物 | 293 |
| Metal `.air` 产物 | **14**（与 14 个 `.metal` 一一对应） |
| Swift `.swiftmodule` | 31 |
| 自动生成 `default.metallib` | `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`，**4.4 MB** |

> 重要副产物：**方案 A 会自行编译并打包 `default.metallib`**，
> 因此先前方案 C 想从 release `Cmlx.xcframework` 手动提取的文件根本不需要。
> 这也印证改选 A 是正确决定。

**GPU 运行时探针**（`research/mlx-swift-probe/Sources/MLXSwiftProbe/main.swift`）：

```
MLX_SWIFT_PROBE_OK device=gpu matmul_softmax=[0.0320586, 0.08714432, 0.2368828, 0.6439142]
```

数值核对：`matmul([[1,2],[3,4]], I)` 得到 `[1,2,3,4]`，
`softmax([1,2,3,4])` 解析值为 `[0.0320586, 0.0871443, 0.2368828, 0.6439143]` —— 逐项吻合。
这证明 Metal kernel 与 `default.metallib` **真的被加载执行**，不是仅「编译通过」。

---

## 4. A2 构建结果（mlx-swift-lm + hunyuan_v1_dense）

`research/mlx-lm-probe/`（独立于 A1 探针）→ `Build complete!`，`A2_BUILD_RC=0`，
error 0。运行：

```
MLX_LM_PROBE_OK hunyuan_v1_dense_registered=true
```

上游源码事实复核：
- `Libraries/MLXLLM/LLMModelFactory.swift:120`：
  `"hunyuan_v1_dense": create(HunyuanConfiguration.self, HunyuanModel.init)`
- `Libraries/MLXLLM/Models/Hunyuan.swift:67-73`：`applyRotaryPosition` **先于** `queryNorm/keysNorm`
  → **post-RoPE QK-Norm**，与 D-1 的 `HymnModel` 实现语义一致。

### 4.1 依赖本地化（网络 git 通道间歇 502）

`git clone` 对 `mlx-swift-lm` / `swift-syntax` / `swift-numerics` 先后报
`HTTP2 framing layer` / `CONNECT tunnel failed 502`，而 **codeload zip 通道稳定 200**。
因此把全部外部依赖改为本地 path 依赖，A1/A2 后续构建不再需要网络：

| 依赖 | 来源 | 落地路径 | 改动 |
|---|---|---|---|
| `mlx-swift-lm` | codeload main.zip（908 entries / 818 files） | `research/upstream/mlx-swift-lm` | `Package.swift`：远程 `mlx-swift 0.33.0` → `path: ../../../mlx-swift-main`；24 处 `package: "mlx-swift"` → `"mlx-swift-main"`（path 依赖包名取目录名） |
| `swift-syntax` | codeload tag `603.0.0`（1026 entries） | `research/upstream/swift-syntax` | `Package.swift`：远程 → `path: ../swift-syntax`；版本仍在原 `602.0.0 ..< 604.0.0` 范围内 |
| `swift-numerics` | codeload tag `1.1.1`（87 entries） | `research/upstream/swift-numerics` | `mlx-swift-main/Package.swift` 第 378 行：远程 → `path: ../research/upstream/swift-numerics`；目录名不变，故 `Numerics` product 引用无需改 |

A2 探针自身一次 Swift 6 严格并发修正：`ModelTypeRegistry` 是 actor，
`contains(_:)` 必须在 `async main` 中 `await` —— 已修正，非上游缺陷。

---

## 5. 回归验证（依赖本地化之后重跑）

| 项 | 命令 | 结果 |
|---|---|---|
| A1 全量重编译 | `./Scripts/build-mlx-swift.sh` | `rc=0`，`MLX_SWIFT_PROBE_OK device=gpu` 数值不变 |
| D-1 主工程构建 | `./Scripts/build.sh` | `BUILD_OK rc=0`，`Build complete! (17.08 sec)` |
| D-1 全量测试 | `./Scripts/test.sh` | `# pass 120 fail 0 total 120`，`TEST_OK rc=0` |
| CLI 真译 / App smoke | 见 `stage-d1-complete.md` | 未在 A1/A2 改动范围内，未重跑 |

主工程 `Package.swift`、`Sources/`、`dist/` 时间戳与内容均未变化；
A1/A2 的一切改动都在 `mlx-swift-main/`（用户提供的副本）与 `research/` 隔离目录内。

---

## 6. 性能数据口径

本阶段**没有模型推理性能数据**。已有的量化数据只属于构建与最小算子验证：

- A1 首次全量编译 41.21 s，A2 增量编译 4.17 s，主工程回归 17.08 s；
- 产物：293 个 C++ `.o`、14 个 Metal `.air`、31 个 Swift module、`default.metallib` 4.4 MB；
- GPU 探针只做一次 2×2 `matmul` + `softmax`，用于验证 kernel 加载，**不是 token/s 或 TTFT**。

真实模型推理性能仍以 `Reports/forward-perf.json` / `real-inference-perf.json` 的 D-1 口径为准
（三次区间 25.94–28.9 tokens/s、TTFT 1086–1122 ms）。两套口径互不混用。

---

## 7. 明确未交付 / 下一步

1. ~~**A2 剩余部分**：尚未用 MLX 加载权重并跑 forward。~~
   **已于 2026-11-21 11:2x 完成，见第 9 节**：MLX 加载
   `model.safetensors` 成功（`HunyuanModel` / 804 张量），并用与 D-1 相同的
   prompt ids 跑通 forward，与 fp32 golden 的 argmax 一致。
2. ~~**A3 尚未开始**~~ → **已于 2026-11-21 11:5x 完成，见 `Reports/stage-a3-complete.md`**：
   新增并列 `MLXBackend` 并接入调度/流式/取消/SQLite/UI，测试 **131/131**，
   两后端译文与性能对照完成。**当时** D-1 仍是默认后端（G8 已变更）。
3. **LUT4 权重仍不存在，永不冒充**：UI / CLI / 元数据 / SQLite 按后端如实标注
   `affine INT4 (NOT LUT4)` 或 `Sherry STQ1_0 (NOT LUT4)`。
4. **A1/A2 时点**：D-1 是唯一的生产后端；A1/A2 全部在隔离探针中，不影响交付 App。
   ⚠️ **G8 起默认已改为 Sherry 1.25bit GGUF 常驻 GEMV**，见本文顶部状态更新块。
5. 其它未交付项沿用 `stage-d1-complete.md` 第 7 节：batched prefill / fused dequant-matmul
   优化、BLEU/COMET 系统级翻译质量评测。

### 建议的下一检查点

| 步骤 | 目标 | 验收 |
|---|---|---|
| A2′ | 用 `ModelFactory` / `ModelContainer` 加载本地 1.8B checkpoint | 804 张量成功加载，配置解析出 32L/2048/GQA 4KV |
| A2″ | MLX 侧跑一次真实 forward / 短生成 | 与 D-1 的 logits（corr 0.999998）与译文逐项对照 |
| A3 | 新增并列 `MLXBackend` | 同 prompt / 同权重 / 同采样参数下译文一致；`performsRealModelInference` 如实声明；主线程零阻塞；单实例调度并发峰值 1 |

> A3 完成并通过交叉验证之前，不替换、不关闭 D-1 后端。

---

## 8. 复现

```bash
cd HymnTranslate
./Scripts/verify-xcode.sh                 # RESULT: READY
./Scripts/build-mlx-swift.sh              # A1 → MLX_SWIFT_PROBE_OK device=gpu
cd research/mlx-lm-probe && swift build --disable-sandbox && .build/debug/MLXLMProbe
                                          # A2 → MLX_LM_PROBE_OK hunyuan_v1_dense_registered=true
cd ../.. && ./Scripts/build.sh && ./Scripts/test.sh   # 主工程 120/120
```

关键日志：`Reports/mlx-swift-build.log`、`Reports/mlx-swift-probe-run.log`、
`/tmp/hymn_a2_final.log`（A2 构建）、本报告。

---

## 9. A2′ / A2″：加载真实权重并做 forward 交叉验证（2026-11-21 11:2x）

独立探针 `research/mlx-load-probe/`，只依赖研究副本，不碰主工程。
构建 `swift build --disable-sandbox` → `rc=0`（44.32 s 首次 / 1.29 s 增量），error 0。

### 9.1 为什么注入自定义 TokenizerLoader

上游 README 里的 `#huggingFaceTokenizerLoader()` 宏展开引用 `Tokenizers.AutoTokenizer`，
但当前 main 依赖图中**没有 `Tokenizers` 模块**（文档是旧版，依赖已剥离）。
因此按官方 `TokenizerLoader` 协议（`TokenizerLoader.swift:4`）注入一个 stub，
直接调用 `LLMModelFactory.shared.load(from:using:)`（`ModelFactory.swift:240`）。
权重加载本身不需要分词；stub 仅用于满足依赖注入，**不参与任何数值计算，也不用于生成**。

### 9.2 A2′ 权重加载结果

```
MLX_LOAD_OK load_ms=155.9 model_type=HunyuanModel
configuration_id=directory(.../Models/Hy-MT2-1.8B-4bit/)
MLX_PARAMS tensors=804 elements=279975552
```

**804 个张量与 D-1 用 `SafeTensorsFile` 读到的 804 个张量完全一致**，
`model_type=HunyuanModel` 说明 `hunyuan_v1_dense` 注册表生效。
首次冷加载 694.5 ms，页缓存命中后 155.9 ms（均为单次测量）。

### 9.3 A2″ forward 交叉验证

用 `Golden/forward-manifest.json` 里与 D-1 / Python numpy 参考**完全相同**的
prompt ids `[120000, 120006, 28036, 120007]`，调用官方
`LanguageModel.callAsFunction(_ inputs: MLXArray, cache:)`（`LanguageModel.swift:451`）
一次 batched prefill，取最后一个位置的 logits，与 `Golden/forward-logits.f32`
（120,818 个 fp32）逐元素比对：

```
MLX_FORWARD_OK vocab=120818 forward_ms=712.7
MLX_VS_GOLDEN corr=0.999806175 maxAbs=0.261308 meanAbs=0.037642
MLX_VS_GOLDEN top20_overlap=19/20 argmax_mlx=16883 argmax_golden=16883
```

| 指标 | MLX 官方 forward | D-1 自实现 forward（对照） |
|---|---|---|
| 与 fp32 golden 相关系数 | 0.999806 | 0.999998 |
| maxAbs / meanAbs | 0.2613 / 0.0376 | 0.0234 / 0.0038 |
| top-20 交集 | 19/20 | 20/20 |
| **argmax** | **16883** | **16883（一致）** |

**差异来源可解释，不是错误**：D-1 的 golden 与 D-1 运行时读的是同一份
`weights.fp16.bin`（逐位相同的 fp16 权重），所以差异只来自 GPU fp16 计算；
而 MLX 官方走原始 affine INT4 → **bf16** 反量化路径，权重位模式本来就不同
（本项目早前已实测 MLX `mx.dequantize` 输出落在 bf16 网格，且存在 1 个 fp16
次正规下溢例外）。两条精度路径不同，逐元素误差更大完全在预期内。

**关键结论**：两个独立实现的 32 层 forward 在同一 prompt 上给出**同一个 argmax**
和几乎相同的 top-20，互证了 D-1 的 post-RoPE QK-Norm / dynamic-NTK RoPE /
GQA / tied lm_head 等算子语义正确。

### 9.4 本阶段仍未做的事（如实标注）

- **没有产出译文**：本探针用 stub tokenizer，只做 prefill forward，未做自回归生成、
  未走 chat template、未接调度/流式/取消。
- **没有新增 `MLXBackend`**：A3 尚未开始，D-1 仍是唯一生产后端。
- `forward_ms=712.7` 是 4-token batched prefill 的单次测量，**不是 token/s 或 TTFT**，
  不能与 `Reports/forward-perf.json`（D-1 稳态 25.94–28.9 tokens/s）直接比较。
- 权重格式仍全程标注 `affine INT4 (NOT LUT4)`；MLX 侧同样不冒充 LUT4。

### 9.5 主工程回归（A2′/A2″ 后重跑）

| 项 | 结果 |
|---|---|
| `./Scripts/build.sh` | `BUILD_OK rc=0`（2.80 s） |
| `./Scripts/test.sh` | `# pass 120 fail 0 total 120`，`TEST_OK rc=0` |
| `hymnctl translate --text "Hello, nice to meet you."` | `您好，很高兴见到您。`，`tokens=6 elapsed=1526.84ms`，`真实模型推理: YES` |

主工程零改动；MLX 侧成果全部在 `research/` 隔离目录内，D-1 真实译文不受影响。

### 9.6 复现

```bash
cd HymnTranslate/research/mlx-load-probe
swift build --disable-sandbox
HYMN_ROOT="$PWD/../.." .build/debug/MLXLoadProbe
# 期望：MLX_LOAD_OK / MLX_PARAMS tensors=804 /
#       MLX_FORWARD_OK / argmax_mlx=16883 argmax_golden=16883
```

结构化结果：`Reports/mlx-a2-forward.json`。
构建/运行原始日志：`/tmp/hymn_a2p_build2.log`、`/tmp/hymn_a2p_run2.log`。
