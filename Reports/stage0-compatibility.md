# HymnTranslate 阶段 0 报告：模型结构与 MLX Swift 兼容性分析

> ## ✅ 最新状态（2026-11-21，D-1 完成）
>
> 本文结论中「不启动真实模型推理」仅为 2026-11-20 的历史状态。
> **D-1 已绕过 MLX Swift 依赖阻塞**：改用 Apple 官方 `MetalPerformanceShaders` 做 fp16 GEMM，
> 加自写 Metal 算子，按上游 `Hunyuan.swift` 语义完成 32 层 forward，产出真实译文。
> 仍成立的部分：**LUT4 权重不存在、现有权重是 affine INT4、绝不冒充 LUT4**；
> MLX Swift 运行时依旧未接入（但已非功能阻塞）。
> 最新完整报告：**`Reports/stage-d1-complete.md`**。

生成时间：2026-11-20 23:40 (GMT+8)
结论摘要：**目标 LUT4 权重不存在，MLX / MLX Swift 原生算子不支持 LUT 码本，`hunyuan_v1_dense` 架构在 Swift 侧未注册，且本机 MLX Swift 依赖不可达。因此本阶段不启动真实模型推理，也不把普通 affine INT4 冒充 LUT4。**

> ## ⚠️ 状态更新（2026-11-21，阶段 D 过渡版）
>
> 本文是 **2026-11-20 23:40 的历史快照**，以下结论已被后续实证修订，最新状态以
> `Reports/stage-d-transition.md` 为准：
>
> 1. **BLOCKER「`hunyuan_v1_dense` 在 mlx-swift-lm 未注册」已解除**：上游 main 分支已有
>    `Libraries/MLXLLM/Models/Hunyuan.swift` 与 `HunyuanTests.swift`，
>    `LLMModelFactory.swift:120` 明确注册该架构；Qwen3 式 pre-RoPE QK-Norm 的担心不成立，
>    上游实现同样是 **post-RoPE QK-Norm**。源码已 clone 到 `research/upstream/mlx-swift-lm`。
> 2. **网络结论部分变化**：`github.com` 已恢复 200（`git ls-remote` 成功），`ghproxy.net` 可代理
>    GitHub raw / git；但 `mlx-swift` 的 vendored C++ 大仓库克隆与 release CDN 仍不可达。
> 3. **新增环境事实**：本机完全没有 `metal` / `metallib` 编译器；但 Metal.framework 的
>    `makeLibrary(source:)` 运行时 JIT 编译已实测可用，**不需要 Xcode 的 Metal 编译器**。
> 4. **权重已真实落盘**：`Scripts/fetch-model.sh` 下载完整 1,007,776,125 B
>    `model.safetensors`（SHA-256 见 `Models/Hy-MT2-1.8B-4bit/SHA256SUMS.txt`），
>    804 张量契约、affine INT4 判定、Metal 反量化与官方 MLX golden 零误差对齐均已验证。
> 5. **用户已选择路线 D（过渡）**：工程改为 `affine INT4 (NOT LUT4)` 标注；
>    LUT4 仍然不存在，本文关于「不得冒充 LUT4」的结论继续有效。
> 6. **仍然成立**：未执行完整模型 forward，不产生译文；MLX Swift 运行时未接入。

---

## 0. 证据链与环境

| 项 | 值 |
|---|---|
| 机器 | Apple M3 Pro, arm64, 18 GB 统一内存 |
| 系统 | macOS 27.0.1 (26A434) |
| 工具链 | Swift 6.4 (swiftlang-6.4.0.34.1), swift-tools-version 6.0 |
| Xcode | **仅 CommandLineTools**，无完整 Xcode（`xcodebuild` 不可用，无 SwiftUIMacros 插件） |
| 网络 | `github.com` / `raw.githubusercontent.com` / `huggingface.co` → CONNECT 502 / 000；`hf-mirror.com` / `pypi.org` / 清华镜像 / workbuddy.cn → 200 |
| 本地缓存 | 无 MLX Swift 包、无模型权重、无 Python mlx/mlx_lm |

真实 checkpoint 元数据经 `hf-mirror.com` 从 `mlx-community/Hy-MT2-1.8B-4bit` 取得，原样打包在
`Sources/HymnCore/Resources/model-probe/`：

| 文件 | 字节 | SHA-256 |
|---|---|---|
| `config.json` | 1688 | `63180daf56cf2ca15223b358eae0bcb5252b7fd4bfa2b2882b36e82f4c410da8` |
| `model.safetensors.index.json` | 57380 | `6026955be1656bf6cf7b9ffd56aac91c88287ba13fbab8b9f140655464b9de4b` |

> 交叉验证：官方技术报告（hunyuan.tencent.com/research/100041）说明 Hy-MT2 系列发布 FP16 / 8-bit / 4-bit / 2-bit / 1.25-bit 变体；4-bit 为 PTQ，2-bit 为 AngelSlim QAT + SEQ（码本 {-1.5,-0.5,0.5,1.5}），1.25-bit 为 Sherry 稀疏三值（{-1,0,+1} + 3:4 稀疏）。**官方并未发布名为 LUT4 的权重格式。**

---

## 1. 模型结构事实（读自真实 config.json）

| 字段 | 值 |
|---|---|
| `model_type` | `hunyuan_v1_dense` |
| `architectures` | `HunYuanDenseV1ForCausalLM` |
| 层数 / hidden | 32 / 2048 |
| 注意力 | 16 Q heads / 4 KV heads (GQA) / `head_dim` 128 |
| `intermediate_size` | 6144 |
| 词表 / tied | 120818 / `true` |
| norm / bias | `rms`；`attention_bias=false`；`mlp_bias=false` |
| RoPE | `type=dynamic`, `rope_theta=10000.0`, `alpha=1000.0` |
| **effective base** | `10000 × 1000^(128/126) = 11,158,839.93` |
| 量化声明 | `{"group_size":64,"bits":4,"mode":"affine"}` |

**架构两个必须正确处理的关键点**（否则权重加载或数值对齐必错）：

1. **QK-Norm 在 RoPE 之后**（post-RoPE per-head RMSNorm），与 Qwen3 系相反；
2. **DynamicNTK-alpha RoPE**，base 需按上式预缩放，不能按普通 dynamic-NTK 运行时插值。

---

## 2. 权重格式判定：LUT4 ≠ affine INT4

### 2.1 两种格式的本质差别

| | MLX affine INT4 | LUT4 混合精度（目标） |
|---|---|---|
| 权重存储 | 4-bit 等间距码 `q ∈ [0,15]`，打包进 uint32 | 4-bit **索引**，指向非均匀码本 |
| 还原公式 | `w = q·scale + bias`（16 个等间距 level） | `w = LUT[group][q]`（16 个任意 level，Lloyd-Max / 训练得到） |
| 必需张量 | `weight` / `scales` / `biases` 三元组 | 额外 **码本张量**（`lut_codebook` / `centroids` / `palette` …）+ 索引张量 |
| 混合精度 | 通常全模型统一 4-bit | embed / lm_head 等敏感层保留 6/8/16-bit |
| MLX 原生支持 | ✅ `QuantizedLinear` / `quantized_matmul` | ❌ 需自定义 Metal kernel |

### 2.2 张量级实证（`model.safetensors.index.json`）

```
张量总数        : 804
张量后缀        : weight=354  scales=225  biases=225
LUT/码本张量    : 0            （检索 lut / codebook / centroid / palette / lookup_table / cluster_center …）
total_size      : 1,007,685,888 bytes ≈ 961 MiB
```

225 组 `scales`+`biases` 与 225 个打包 `weight` 一一对应，其余 129 个 `weight` 为未量化张量（norm / embedding 等）。这是**标准的 MLX 分组仿射量化布局，没有任何码本查表结构**。

### 2.3 判定与代码级保证

`CompatibilityVerifier` 的判定结果：

```
判定格式       : MLX affine INT4 (group_size=64, mode=affine) — 普通均匀量化，非 LUT
Swift 架构注册 : 未内置（需自行实现并注册）
LUT4 可加载    : NO
```

工程内 `CompatibilityGuard.requireLUT4(_:)` 会对任何试图以 LUT4 身份加载该 checkpoint 的调用抛错，
并有回归测试 `CompatibilityGuard 拒绝把 INT4 当 LUT4 加载`。同时提供**反证用例**：构造带
`lut_codebook` 张量且 `mode=lut4_mixed` 的假配置时，分类器会正确判为 LUT4 —— 证明判定逻辑不是
硬编码 `false`，而是依据 config 声明 + 码本张量双重证据。

> 依据需求 5，本项目**不会**把这个 4-bit checkpoint 标记成 LUT4，也不会以 LUT4 名义启动推理路径。

---

## 3. 三项架构不兼容（BLOCKER）

### BLOCKER 1 — 目标权重与算子双重缺失
- 公开可获取的 Hy-MT2 MLX 权重全部是 affine INT4（已实证），**没有 LUT4 混合精度权重**；
- MLX / MLX Swift 的 `quantized_matmul` 只支持 `affine` 均匀码本及 `mxfp4` / `mxfp8` / `nvfp4`；
  非均匀码本必须自行写 Metal kernel。社区实践（TurboQuant for mlx-lm）明确写道
  “`mx.quantized_matmul` only supports uniform/affine codebooks”，其 `--mode lut` 依赖
  手写 `mx.fast.metal_kernels` 完成 LUT dequant + matmul。
- 依据需求「不要在未经验证时自行编造模型算子」：在没有真实 LUT4 权重、没有 golden 数值基准的前提下，
  **不实现、不声称实现 LUT4 算子**。

### BLOCKER 2 — `hunyuan_v1_dense` 未在 mlx-swift-lm 注册
- 截至 `mlx-swift-lm` 3.31.x，官方 Swift 端内置架构表不含 `hunyuan_v1_dense`，直接加载报
  `unsupported model type`（该 checkpoint 的模型卡亦明确提示）。
- 第三方已有纯 Swift 移植先例（Mac-MLX PR #87）：实现 post-RoPE QK-Norm + DynamicNTK-alpha，
  报告 1e-4 逐层 parity、514/514 测试通过、真实 checkpoint ~80 tok/s 冒烟。
  **说明此路可行，但需要在本工程内自行实现并注册，不能假设开箱即用。**

### BLOCKER 3 — 本机环境不足以链接 MLX Swift
- `github.com` / `raw.githubusercontent.com` 返回 `CONNECT tunnel failed, response 502`，
  SwiftPM 无法拉取 `mlx-swift` / `mlx-swift-lm`；jsdelivr / ghproxy / gitclone 镜像同样不可达；
- 本地无 SwiftPM 缓存、无 MLX 依赖、无 Python mlx；
- 无完整 Xcode：缺少 `SwiftUIMacros` 插件（已实测），且 mlx-swift 的 Metal shader 由
  Xcode/xcodebuild 构建步骤编译，`swift build` 路径不保证可用。

---

## 4. 具体适配方案（不降级为 Python 推理）

> Python 仅允许作为**离线数值对照 / 权重转换工具**出现，绝不进入 App 的推理链路。
> 以下方案全部在 Swift 6 + MLX Swift + Metal 内落地。

### 方案 A：严格达成 LUT4 目标（推荐，需前置条件）

| 步骤 | 工作内容 | 验收标准 |
|---|---|---|
| A1 权重契约 | 定义并产出 LUT4 safetensors：每层 `lut_codebook` (fp16, [groups,16])、`lut_indices` (uint32 打包 4-bit 索引)、`scales`；混合精度策略：embed_tokens / lm_head 保 6/8-bit，其余 LUT4。来源可基于官方 FP16 权重用校准集离线做 Lloyd-Max 码本量化（一次性，不进 App） | `CompatibilityVerifier` 判定 `isLUT4=true`；码本张量数 > 0；`CompatibilityGuard.requireLUT4` 通过 |
| A2 算子实现 | 先用 MLX 基础算子写 `gather(codebook, indices)` 反量化 **golden reference**；再用 `MLXFast.metalKernel` 写 fused `LUT dequant + QMV/QMM` Metal kernel，替换 `QuantizedLinear` | 单层输出 vs golden：fp32 相对误差 < 1e-4，bf16 < 2e-2；覆盖 group_size 64、非 2 的幂 shape、transpose 两种布局 |
| A3 架构注册 | 见方案 B | 逐层 logits 与官方实现 parity |
| A4 加载器 | 自定义 safetensors 解析，加载码本张量并构造 `LUT4QuantizedLinear`；复用本工程 `ProbeResources` / `CompatibilityGuard` 做启动校验 | 804 张量映射全覆盖，无 unused key；失败明确报错而非静默回退 |
| A5 端到端 | 33 语言方向抽样翻译 + 术语约束 + 长文本，比对 FP16/INT4 基线质量；测真实 token/s、TTFT、峰值统一内存 | 报告真实性能数据，替换当前 perf.json 中「测试替身」口径 |

### 方案 B：`hunyuan_v1_dense` 的 Swift 架构注册（A3 展开）

基于 `mlx-swift-lm` 的自定义 model factory 注册 `hunyuan_v1_dense`，实现要点：

```
- 32 × DecoderLayer，hidden 2048，intermediate 6144，SiLU
- GQA: 16 Q heads / 4 KV heads / head_dim 128
- RMSNorm(eps 1e-5)；attention_bias = false；mlp_bias = false
- RoPE: 静态烘焙 base = 10000 × 1000^(128/126) = 11,158,839.93（等价 DynamicNTK-alpha）
- Q/K per-head RMSNorm 必须在 RoPE 之后（DO NOT 对齐 Qwen3 顺序）
- tie_word_embeddings = true：sanitize 阶段丢弃 lm_head.weight
- chat template 使用 checkpoint 自带 chat_template.jinja，无 system prompt
- 推荐采样：temperature 0.7 / top_p 0.6 / top_k 20 / repetition_penalty 1.05
```

验收：与官方 `mlx-lm` 的 `hunyuan_v1_dense.py` 做逐层数值对照（**仅验证用**），两个对抗 fixture
（切换 qk-norm / bias / tied / alpha / head_dim 全部开关）均通过。

### 方案 C：环境补齐清单（阻塞项）

1. 安装完整 Xcode（提供 SwiftUIMacros 插件与 mlx-swift Metal shader build step）；
2. 打通 `github.com` / `raw.githubusercontent.com`，或提供 `mlx-swift` + `mlx-swift-lm` 的本地
   checkout / 离线 SPM 镜像，以便 `Package.swift` 加入依赖；
3. 首次模型下载走 `hf-mirror.com`（已验证 200，可取得 1.01 GB 权重）；之后全程离线。

### 方案 D：过渡路线（**需用户明确确认，默认不执行**）

如果优先目标是「尽快拿到真实译文」而非严格 LUT4：
用现有 affine INT4 权重 + 方案 B 架构注册，走 MLX Swift 原生 `QuantizedLinear`。
**但 UI 与元数据必须标注 `affine INT4`，严禁标注 LUT4**（需求 5）。
这是**权重格式变更**，不是 Python 降级；需用户签字确认后才实施。

---

## 5. 本阶段已交付（全部真实可验证）

| 模块 | 状态 | 证据 |
|---|---|---|
| 模型结构 / 权重格式验证器 | ✅ 真实运行 | `hymnctl verify`，基于打包的真实 config + index |
| 禁止 INT4 冒充 LUT4 的代码级保证 | ✅ 回归测试 | `CompatibilityGuard` + 16 条兼容性用例 |
| Swift 6 严格并发工程（5 targets） | ✅ 构建通过 | `Reports/build.log` rc=0 |
| 单实例多请求调度 / 流式 / 批量 / 取消 | ✅ 实现 + 独立测试 | `Reports/test-report.md` 57/57 |
| SQLite 历史 + 术语库 | ✅ 实现 + 独立测试 | 文件持久化、事务批量、UPSERT |
| 主线程零阻塞 | ✅ 实测 | 主线程 10ms ticker，最大间隔 12.32 ms |
| macOS 原生 App（SwiftUI + AppKit） | ✅ 可启动 | `.app` + `HYMN_SMOKE_OK` 冒烟 |

**明确未交付**：真实 Hy-MT2 模型推理、LUT4 Metal 算子、模型权重下载与内置。
当前所有推理链路使用显式标注的 `FixtureBackend` / `ProbeBackend` 测试替身
（`performsRealModelInference = false`），输出为 `[fixture]` 占位 token，**不是译文**，
也不代表任何模型性能。性能数据均已在 `perf.json.disclaimer` 中标注口径。

---

## 6. 需要用户决策的分叉

1. **A（严格 LUT4）**：按方案 A 推进，需先补齐 LUT4 权重与 MLX Swift 依赖；
2. **D（过渡）**：允许先用 affine INT4 得到真实译文，但永不标为 LUT4；
3. **仅环境补齐**：先装 Xcode / 打通依赖源，我再把 MLX 后端接进现有工程
   （调度、SQLite、UI 层已就绪，可原样复用）。

在依赖源可达之前，我不会静默改用 Python 推理，也不会编造 LUT4 算子。
