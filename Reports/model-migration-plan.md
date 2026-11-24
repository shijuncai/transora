# 模型迁移计划：Hy-MT2-1.8B-1.25bit-GGUF

建立时间：2026-11-21 12:4x (GMT+8)  
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`  
关联报告：`stage-d1-complete.md` / `stage-a3-complete.md` / `stage-a3-ui-backend-switch.md`

> ## ✅ 当前状态（2026-11-21 13:3x 更新）：**G0–G8 全部完成**
>
> 用户已选 **G1（纯 Metal 原生 GGUF 后端）**，并在本轮要求继续 G4 + 切换默认后端。  
> 现已把 Sherry 从「GGUF → 3.58 GB fp16 展开缓存 → MPS GEMM」升级为  
> **「461,860,800 B GGUF 常驻 MTLBuffer + 原生 Metal GEMV 解码即乘加」**：  
> 224 个 STQ1_0 线性层以 **1.3125 bpw 常驻**，Q6_K embedding 与 F32 norm 按权威公式处理，  
> 运行时**不再需要 `weights.fp16.bin`**（该缓存仅保留作离线 golden 生成）。  
> **默认后端已改为 `Hy-MT2-1.8B-1.25Bit.gguf`**；D-1 / MLX 仍并列可显式选择。  
> 构建 `rc=0`、测试 **164/164**、CLI/App 默认真实译文通过。  
> 详见 **`Reports/stage-g4-resident-gemv.md`** 与第 5 节进度表。
>
> 权重格式全程标注 `Sherry STQ1_0 1.3125 bpw 常驻 GEMV (NOT LUT4, NOT affine INT4)`，  
> 未静默替换为 Python 推理（Python 仅离线生成 Golden）。



---

## 1. 目标模型事实核查（实证，非推测）

### 1.1 来源与文件

| 项    | 值                                                       | 证据                                              |
| ---- | ------------------------------------------------------- | ----------------------------------------------- |
| 仓库   | `AngelSlim/Hy-MT2-1.8B-1.25Bit-GGUF`（Apache-2.0）        | `hf-mirror.com/api/models/...` HTTP 200         |
| 主文件  | `Hy-MT2-1.8B-1.25Bit.gguf` **461,860,800 B**（440.5 MiB） | HEAD `Content-Length`，支持 `Accept-Ranges: bytes` |
| 另有文件 | `Hy-MT2-1.8B-1.25bit-v2.gguf`                           | 仓库 siblings，**版本差异未核实**                         |
| 量化   | Sherry / STQ（Sparse Ternary Quantization），ggml `STQ1_0` | llama.cpp PR #22836；`GGML_TYPE_STQ1_0 = 42`     |
| 探测方式 | HTTP 206 Range 只读**前 12 MiB**，未下载 440 MB 全量             | `curl -r 0-12582911`，206 / 12,582,912 B         |

第三方文档给出的主文件 SHA256 为  
`cc497fe8f033b52b3b8b00a7669e9661435432f9d4cd43f7ed24400c01507a93`  
（来自 `kuotient/Hy-MT2-1.8B-1.25Bit-MLX` 模型卡，**本轮未自行复核**，下载后必须校验）。

### 1.2 GGUF 头部解析结果

GGUF **v3**，**354 个张量**，**34 条 metadata**，metadata/tensor-info 区结束于字节偏移 **5,090,196**。

关键 metadata（与现有 4bit 模型对照）：

| 键                                                          | 值                                                                                                  | 与现有模型                                                 |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `general.architecture`                                     | `hunyuan-dense`                                                                                    | 现有 `hunyuan_v1_dense`，同架构                             |
| `general.name`                                             | `HyMT2 1.8B 2bit Stride16`                                                                         | ⚠️ 元数据自身写「2bit」，但张量实测 1.3125 bpw，**以实测为准**            |
| `block_count` / `embedding_length` / `feed_forward_length` | 32 / 2048 / 6144                                                                                   | 完全一致                                                  |
| `attention.head_count` / `head_count_kv`                   | 16 / 4（GQA）                                                                                        | 完全一致                                                  |
| `attention.key_length` / `value_length`                    | 128 / 128                                                                                          | 完全一致                                                  |
| `attention.layer_norm_rms_epsilon`                         | 1e-5                                                                                               | 完全一致                                                  |
| `rope.freq_base`                                           | **11158840.0**，`rope.scaling.type = none`                                                          | 与项目静态烘焙值 11,158,839.93 一致；**dynamic-NTK 已烘焙为静态 base** |
| `context_length`                                           | 262144                                                                                             | 现有运行时 maxSeq 1024，需另行决策                               |
| `general.quantization_version` / `file_type`               | 2 / 41                                                                                             | 新值                                                    |
| `general.sampling.*`                                       | temp 0.7 / top_p 0.8 / top_k 20                                                                    | 与 `generation_config.json` 一致                         |
| `tokenizer.ggml.*`                                         | gpt2 / hunyuan-dense；120818 tokens、119758 merges；bos 120000 / eos 120020 / pad 120002 / sep 120007 | 与现有 `tokenizer.json` 同源                               |
| `tokenizer.chat_template`                                  | 内嵌                                                                                                 | 与现有 `chat_template.jinja` 待逐字比对                       |

### 1.3 张量布局（按 offset 差值反推，逐项实证）

| ggml type       | 数量      | 内容                                              | 实测密度           |
| --------------- | ------- | ----------------------------------------------- | -------------- |
| **42 = STQ1_0** | **224** | 32 层 × 7 个线性层（q/k/v/o + gate/up/down）           | **1.3125 bpw** |
| 0 = F32         | 129     | 32 层 × 4 个 norm（含 q_norm / k_norm）+ output_norm | 32 bpw         |
| 14 = Q6_K       | 1       | `token_embd.weight` `[2048, 120818]`，6.5625 bpw | 202,974,240 B  |

- 张量命名为 llama.cpp 风格：`blk.0.attn_q.weight` / `blk.0.attn_q_norm.weight` / `blk.0.ffn_gate.weight` …
- **无 `output.weight` / `lm_head`** → tied embedding，与现有模型一致。
- `attn_q_norm` / `attn_k_norm` 存在且维度 128 → **post-RoPE QK-Norm 语义不变**。

### 1.4 STQ1_0 权威结构（llama.cpp PR #22836，禁止自行编造）

```c
// 每 256 个权重一个 block，共 42 字节 = 336 bits / 256 = 1.3125 bpw
typedef struct {
    uint8_t qs[QK_K/8];    // 32 B：每 4 权重一个 4-bit codebook index（共 64 组）
    uint8_t sign[QK_K/32]; //  8 B：每 4 权重一个 1-bit table select
    ggml_half d;           //  2 B：整 block 的 fp16 scale
} block_stq1_0;
```

权重取值 `{-d, 0, +d}`，每 4 个 lane 恰有 1 个为 0（3:4 稀疏），  
`C(4,3) × 2³ = 32` 种组合 → 32 项码本查表。PR 提供 ARM NEON 参考实现  
（`vqtbl2q` + `vdotq_s32`）。**本地头部实测 223/224 个 type=42 张量全部为 1.3125 bpw，  
与该结构逐字节吻合**，实证闭环。

---

## 2. 兼容性判定：**架构不兼容**

| 现有组件                               | 依赖                              | GGUF 现实                              | 结论                     |
| ---------------------------------- | ------------------------------- | ------------------------------------ | ---------------------- |
| `SafeTensorsFile`                  | safetensors `[len][json][data]` | GGUF v3                              | ❌ 不可复用，需新 `GGUFReader` |
| `AffineINT4` / `MetalDequantizer`  | U32 nibble + BF16 scales/biases | STQ1_0 三值码本 + fp16 scale             | ❌ 不可复用                 |
| `WeightCache`（3.58 GB fp16）        | 225 INT4 + 129 BF16             | 224 STQ1_0 + 129 F32 + 1 Q6_K        | ❌ 需重建缓存                |
| `Golden/` 全套校准                     | 官方 MLX affine dequant           | 无对应 golden                           | ❌ 需新建离线 golden         |
| `MLXBackend` / `LLMModelFactory`   | safetensors + MLX 标准量化          | 不认 GGUF / type 42                    | ❌ 不可直接加载               |
| `HymnModel` 32 层 forward           | HF 风格张量名                        | llama.cpp 风格名                        | ✅ **语义可复用**，只需张量名映射    |
| `HymnTokenizer`                    | `tokenizer.json`                | GGUF 内嵌同款 vocab/merges/chat template | ✅ 可复用（需逐项比对）           |
| `HymnGenerator` / `SamplingConfig` | `generation_config.json`        | GGUF 内嵌同款采样参数                        | ✅ 可复用                  |
| 调度 / 流式 / 取消 / SQLite / UI         | 后端无关                            | —                                    | ✅ 可复用                  |

**结论：模型语义层（架构、超参、RoPE、QK-Norm、tied embedding、采样、tokenizer）几乎不变，  
不兼容集中在「权重容器 + 反量化算子」。** 因此适配是可控的模块替换，不是重写推理引擎。

---

## 3. 具体适配方案（先方案，后动手）

### G1（推荐）纯 Metal 原生 GGUF 后端 —— 真正「改用 GGUF」

新增并列第三后端 `SherryBackend`（`InferenceBackend`，`performsRealModelInference` 如实声明）：

1. `GGUFReader`：解析 v3 header / metadata / tensor info，mmap 零拷贝读取 data 区；
2. `STQ1_0` MSL kernel：严格按第 1.4 节权威结构解码（32 项码本、`3:4` 稀疏、fp16 scale），  
   **不得臆造算子**；`Q6_K` 解码 kernel；F32 norm → fp16；
3. 张量名映射 `blk.N.attn_q.weight` ⇄ `model.layers.N.self_attn.q_proj.weight`；
4. 复用 `HymnModel` 32 层 forward、`HymnTokenizer`、`HymnGenerator`、调度/流式/取消/SQLite；
5. 权重缓存可保持常驻 1.31 bpw（约 440 MB）或展开为 fp16 临时矩阵（按性能实测决定）。

- **验收**：与 llama.cpp PR #22836 CPU 参考逐元素反量化对齐；同一 prompt 与 D-1/MLX 三方 argmax / top-20 交叉验证；真实译文；测试 131→N 全通过；主线程零阻塞；峰值内存与 TTFT 实测报告。
- **风险**：码本索引语义必须与 PR 参考逐位一致；需下载完整权重与参考实现做 golden；v1/v2 文件版本需先确定。

### G2 离线转码为 MLX safetensors（快速接入，但**不再是 GGUF**）

用第三方 `hy-mt2-mlx` converter 把 GGUF 无损转码为 MLX **affine 2-bit** safetensors（约 745 MB），  
接现有 `MLXBackend`。**Python 仅作离线一次性权重转换，绝不进入运行时**。

- 优点：开发量最小，复用 A3 成果。
- 缺点：**必须如实标注「MLX affine 2-bit，NOT 1.25bit GGUF、NOT LUT4」**；权重变大；  
  需实证 MLX Swift `QuantizedLinear` 对 `bits=2` 的支持（本轮未验证，不预先承诺）；引入第三方转换依赖。
- 定位：**若只想要小模型的速度/内存收益**可选 G2；若要求是「模型改用 GGUF」则不满足。

### G3 引入 llama.cpp（PR #22836）C++ 后端

llama.cpp 是原生 C++（**不是 Python**，不违反「不得降级为 Python 推理」），但 STQ1_0 kernel 为  
CPU NEON、需引入第三方运行时，与项目「Swift 6 + MLX Swift + Metal」目标不一致。  
**建议仅作为 G1 的离线 golden 参考实现**，不作为生产后端。

> 三条路线共同约束：全程标注 `Sherry STQ1_0 1.3125 bpw (NOT LUT4, NOT affine INT4)`；  
> 新后端与 D-1 / MLX **并列**而非替换；推理不阻塞主线程；全程离线。  
> ⚠️ 规划时（G1）D-1 仍是默认；**G8 完成后默认已改为 Sherry GGUF**，见第 5 节进度表。

---

## 4. 计划表

| ID | 阶段        | 任务                                                    | 交付物                                     | 前置依赖    | 验收标准                             | 优先级 |
| -- | --------- | ----------------------------------------------------- | --------------------------------------- | ------- | -------------------------------- | --- |
| G0 | 事实核查      | 仓库/文件/头部/张量布局/格式定义实证                                  | 本报告第 1–2 节                              | —       | 结论可由 Range 头部 + 权威定义复现           | P0  |
| G1 | 决策        | 选 G1/G2/G3；确定 v1 或 v2 GGUF；下载全量 + SHA256 校验           | `Models/Hy-MT2-1.8B-1.25Bit-GGUF/`、校验记录 | G0、用户确认 | 文件完整、哈希与官方一致、版本明确                | P0  |
| G2 | 读取器       | `GGUFReader`（v3 header/kv/tensor info/mmap）           | `Sources/HymnSTQ/GGUFReader.swift` + 单测 | G1      | 354 张量 offsets/dims/type 与本报告一致  | P0  |
| G3 | 离线 golden | 用 llama.cpp PR #22836 CPU 参考生成 STQ1_0/Q6_K 反量化 golden | `Golden/stq-*.f32` + manifest           | G1      | 与参考实现逐元素零误差                      | P0  |
| G4 | 算子        | MSL `STQ1_0` / `Q6_K` 解码 kernel + F32→fp16            | `Sources/HymnSTQ/MetalSTQ.swift` + 算子测试 | G2、G3   | CPU / Metal / 参考三方对齐             | P0  |
| G5 | 组装        | 张量名映射 + 新权重缓存 / 常驻方案                                  | `HymnSTQModel` 或 `HymnModel` 适配层        | G4      | 32 层 logits 与参考 corr / argmax 对齐 | P0  |
| G6 | 后端接入      | `SherryBackend` 并列接入调度/流式/取消/SQLite/UI，图形开关扩为三选一      | `Sources/HymnMLX` 同级 target + 开关改造      | G5      | 真实译文、并发峰值 1、主线程零阻塞               | P1  |
| G7 | 测试/性能     | 新套件 + 三后端同 prompt 交叉验证 + 报告                           | `Reports/stage-g*.md`、性能 JSON           | G6      | 全套测试通过、性能数据标注口径                  | P1  |
| G8 | 收尾        | 更新 `stage-summary.md` / 项目记忆 / 默认模型决策                 | 文档                                      | G7      | 进度表全部完成                          | P2  |

> 注：上表为**初始计划**，实际交付路径与文件名的差异见第 4.1 / 4.2 节；  
> 最终状态以第 5 节进度表与 `Reports/stage-g4-resident-gemv.md` 为准。

### 4.1 实施路径调整（2026-11-21 13:0x，如实记录，现已完成闭环）

原计划 G4/G5 设想「常驻 1.31 bpw + 新 MSL GEMV kernel」。G1 阶段采用**先打通链路**的分步策略：  
把 GGUF 全部张量按权威公式解码为与 D-1 `WeightCache` **同构**的 fp16 缓存  
（张量名映射 llama.cpp → HF），复用已与 fp32 golden 对齐的 `HymnModel` / MPS GEMM。  
好处是算子正确性可独立验证、译文可立即对照；代价是运行时权重展开为 3.58 GB，  
**不是 1.31 bpw 常驻**。当时如实标注为 G4 剩余项，未说成「已完成 1.25bit 推理」。

### 4.2 G4 常驻 GEMV 落地（2026-11-21 13:3x）

本轮新增 `SherryGEMV`（`stq1_0_gemv` / `q6_k_embed_row` / `q6_k_gemv` 三个 MSL kernel）  
与 `SherryResidentModel`：

- GGUF 原始 `461,860,800 B` 一次性拷入常驻 `MTLBuffer`；
- 每 token **225 次常驻 GEMV**（32 层 × 7 线性层 + tied lm_head），  
  非量化算子仍复用 D-1 已 golden 对齐的 `MetalOps`；
- 129 个 F32 norm 转 `282,624 B` fp16 小 buffer（非量化元数据）；
- `SherryGenerator` 复用 `Sampler` / `SamplingConfig` / `GenerationMetrics`；
- `SherryBackend` 不再检查 `weights.fp16.bin`，`HYMN_SHERRY_MODEL_DIR` 严格优先、失败不静默回退。

独立 Python golden（`Scripts/gen-sherry-golden.py`）从 GGUF 原始字节解码并生成：  
GEMV 4 组 80 个元素、Q6_K embedding 行、32 层 fp32 forward logits/hidden。  
对齐结果：`GEMV maxAbs=7.63e-6`、`embedding maxAbs=0`、  
`logits corr=0.999999`、`top-20 20/20`、`argmax 28036`、`layer32 hidden corr=0.9999996`。  
`fp16 展开缓存` 仅保留作离线 golden / 对照，不再是运行时依赖。

---

## 5. 进度表

| ID                      | 状态        | 完成度  | 证据                                                                                                                                                                                                 | 日期               | 备注                                    |
| ----------------------- | --------- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------------------------------------- |
| G0 事实核查                 | ✅ **已完成** | 100% | 本报告第 1–2 节；Range 解析 GGUF v3 / 354 张量 / type 42=224 个 1.3125 bpw；PR #22836 结构定义；v1/v2 差异实证                                                                                                          | 2026-11-21 12:4x | 已补充：PR 枚举编号从 42 挪到 43，v1 属早期编号        |
| G1 决策/下载                | ✅ **已完成** | 100% | 用户选 G1；助手实证选定 **v1**（v2 为无参考的 type 40）；全量 461,860,800 B 下载，SHA256 与官方 LFS 完全一致                                                                                                                     | 2026-11-21 12:55 | v2 格式明确排除                             |
| G2 GGUFReader           | ✅ **已完成** | 100% | `Sources/HymnSTQ/GGUFFile.swift`；`gguf-reader` 12 项测试（v3/354 张量/类型分布/dataStart=5090208/32 层×7 线性层）                                                                                                 | 2026-11-21 12:59 | mmap 零拷贝                              |
| G3 离线 golden            | ✅ **已完成** | 100% | `Scripts/gen-gguf-golden.py` 独立 Python 实现；5 个 `gguf-*.f32` + manifest；PR #22836 / ggml-quants.c 源码固化在 `research/upstream/stq1_0-reference/`                                                        | 2026-11-21 12:59 | Python 仅离线，不进运行时                      |
| G4 解码算子 / 常驻 GEMV       | ✅ **已完成** | 100% | `SherryGEMV` 3 个 MSL kernel + `SherryResidentModel`；独立 Python/PR golden：GEMV 4 组 80 元素 `maxAbs=7.63e-6`、embedding `0`、logits `corr=0.999999`、top-20 `20/20`、argmax `28036`；**无 fp16 缓存也能 prepare** | 2026-11-21 13:2x | `461,860,800 B` 常驻，非 3.58 GB 展开       |
| G5 组装/映射                | ✅ **已完成** | 100% | `SherryCacheBuilder` 354 张量 → HF 名（现仅离线 golden 用）；`SherryResidentModel` 直接按 GGUF offset 映射 354 张量，32 层 forward 与 fp32 golden 对齐                                                                    | 2026-11-21 13:2x | 运行时不再依赖 fp16 缓存                       |
| G6 SherryBackend / 默认接入 | ✅ **已完成** | 100% | `SherryBackend` 切到常驻模型；CLI 默认、App 默认 `.sherry`、图形三选一、`HYMN_SHERRY_MODEL_DIR` 严格优先；D-1 / MLX 仍并列                                                                                                    | 2026-11-21 13:3x | 故障注入回滚通过                              |
| G7 测试/性能/报告             | ✅ **已完成** | 100% | `BUILD_OK rc=0`、**164/164**（新增 `sherry-resident` 10 项）；`sherry-resident-golden.json`、`sherry-resident-perf.json`、`stage-g4-resident-gemv.md`                                                       | 2026-11-21 13:3x | 主线程 tick max 11.79 ms、并发峰值 1、取消 42 ms |
| G8 收尾/默认后端              | ✅ **已完成** | 100% | 用户确认默认改为 `Hy-MT2-1.8B-1.25Bit.gguf`；CLI/App/usage/modelTag/make-app.sh 软链/Package.swift/状态块/记忆全部同步                                                                                                 | 2026-11-21 13:3x | 默认真译 `你好，很高兴见到你。`；G0–G8 全 100%        |


**当前生产基线**：`./Scripts/build.sh` rc=0、测试 **164/164**、
默认后端 **Sherry STQ1_0 1.25bit GGUF 常驻 GEMV**（`Hy-MT2-1.8B-1.25Bit.gguf`）、
`.app` 84 MB（v0.4.0）。三个后端（D-1 / MLX / Sherry）并列，CLI 与 App 均可显式选择；
权重格式全程如实标注，STQ1_0 永不冒充 LUT4 / affine INT4。

---

## 6. 规则遵守声明

- 未把 `STQ1_0` / `Q6_K` 冒充 LUT4、affine INT4 或任何未经验证的算子；
- 架构不兼容**先提出 G1/G2/G3 具体适配方案**，未静默切换、未静默降级为 Python 推理；
- Python 只允许出现在 G2 的**离线一次性权重转换**与 G3 的**离线 golden 生成**，永不作运行时后端；
- 所有格式结论来自本地 GGUF 头部 Range 实证 + llama.cpp PR 权威定义，不靠推测；
- 新后端并列而非替换，D-1 保持默认；推理继续 `Task.detached`、单实例调度、全程离线。

---

## 7. 复现本轮事实核查

```bash
# 仓库文件清单
curl -s "https://hf-mirror.com/api/models/AngelSlim/Hy-MT2-1.8B-1.25Bit-GGUF" | python3 -m json.tool

# 只读前 12 MiB 解析 GGUF 头部（不下载 440 MB 全量）
curl -sL -r 0-12582911 \
  -o /tmp/hymn_gguf_head.bin \
  "https://hf-mirror.com/AngelSlim/Hy-MT2-1.8B-1.25Bit-GGUF/resolve/main/Hy-MT2-1.8B-1.25Bit.gguf"
```

权威格式定义：<https://github.com/ggml-org/llama.cpp/pull/22836>；
第三方 MLX 移植（**仅作参考，不作运行时后端**）：<https://huggingface.co/kuotient/Hy-MT2-1.8B-1.25Bit-MLX>。

---

## 8. 后续计划表（H 系列，2026-11-21 14:0x 登记）

G0–G8 已全部 100% 完成（默认后端 = `Hy-MT2-1.8B-1.25Bit.gguf`）。
用户列出四项后续范围，其中第 4 项**明确排除**。详细适配方案与实证证据见
**`Reports/stage-h-roadmap.md`**。

| ID | 阶段 | 任务 | 交付物 | 前置依赖 | 验收标准 | 优先级 |
|---|---|---|---|---|---|---|
| H1-a | 量化 KV cache | `kv_write_int8` + `attention_decode_int8` MSL kernel，per-head fp16 scale | `Sources/HymnSTQ/` 新 kernel + 独立 golden | 现有 fp16 KV 布局实证 | 32 层 logits corr / top-20 / 译文不变；KV 显存减半 | P1 |
| H1-b | batched prefill | 多 token `stq1_0_gemm` tile kernel（先 4/8 token 微批） | 新 kernel + golden + TTFT 对照 | H1-a 或独立 | 长 prompt TTFT 下降、数值对齐 | P2 |
| H1-c | fused dequant-GEMM | 澄清现有 `stq1_0_gemv` **已是解码即乘加融合**；GEMM 属另一路径 | 口径说明 + 性能对照 | H1-b | 不重复宣称、不臆造算子 | P2 |
| H2-a | 语言覆盖基础设施 | `LanguageCatalog`（模型卡 36 语言）+ UI Picker 全量 | `HymnCore` + `RootView` + 独立测试 | — | 36 语言可选、旧语言名逐字不变 | P0 |
| H2-b | BLEU/chrF 系统评测 | 权威平行语料 + `hymnctl evaluate` + 离线打分 | `Eval/`、`Scripts/score-translation-eval.py`、JSON 报告 | H2-a、公开语料可达 | 参考译文真实可溯源、分数可复现 | P1 |
| H2-c | COMET | 神经评测模型 + PyTorch 运行时 | 评测脚本与分数 | 需下载 2.32 GB 评测模型（HF API 实测）与 torch | **不可得则明确未交付，绝不伪造分数** | P2 |
| H2-d | 全部语言对覆盖 | 36 语言以 en 为枢轴的双向评测 + 无语料语言冒烟 | 覆盖率统计 | H2-b | 如实标注覆盖范围，不把 64 方向说成 1260 方向 | P1 |
| H3-a | UserDefaults 持久化 | `BackendPreference` 契约 + App 接入 + 重启冒烟 | `HymnCore`、App、独立测试 | — | 双进程重启后选择保留、非法值回退 | P0 |
| H3-b | 像素级 UI 自动化 | CGEvent 真实点击 + 截图像素比对 | 可执行脚本 + 截图证据 | **辅助功能 + 屏幕录制 TCC 授权** | 真实点击后控件状态改变且像素有差异 | P2 |
| H4 | v2 GGUF 解析 | **明确排除，不实施** | 本表排除决议 | — | 不猜测 type=40 布局、不臆造算子 | 排除 |

**硬约束（适用全部 H 项）**：STQ1_0 永不冒充 LUT4 / affine INT4；运行时全程 Swift/Metal 原生、Python 只做离线 golden/评测；
推理不阻塞主线程；任何性能数字标注口径；不兼容先给适配方案，不静默降级。

---

## 9. 后续进度表（H 系列）

| ID | 状态 | 完成度 | 证据 | 日期 | 备注 |
|---|---|---|---|---|---|
| H1-a 量化 KV cache | ⬜ **方案已给，未实施** | 10% | 现状实证：fp16 KV，`maxSeq=1024`、`kvDim=512`，32 层 ×2 × 1024×512×2 B = **67,108,864 B（64 MiB）**；方案见 `stage-h-roadmap.md` 第 3 节 | 2026-11-21 14:0x | 改动核心推理，需独立 golden，风险最高 |
| H1-b batched prefill | ⬜ 未开始 | 0% | — | — | 依赖多 token GEMM tile kernel |
| H1-c fused dequant-GEMM | 🟡 **口径已澄清** | 30% | `stq1_0_gemv` 在 kernel 内直接解 42B/256 block 并乘加，已是融合实现；GEMM 是不同路径，不重复计功 | 2026-11-21 14:0x | 避免「已完成 fused GEMM」的虚假宣称 |
| H2-a 语言覆盖基础设施 | ✅ **已完成** | 100% | `Sources/HymnCore/Compatibility/LanguageCatalog.swift`（36 语言）；`RootView` Picker 由 3 项扩为 36 项；`RealModelBackend.languageName` 不再漏映射；`language-catalog` 套件 11 项全绿 | 2026-11-21 14:0x | 模型卡语言清单来自 `tencent/Hy-MT2-1.8B/raw/main/README.md` |
| H2-b BLEU/chrF | ✅ **已完成** | 100% | FLORES-200 官方 403 `GatedRepo` → 改用公开 `Helsinki-NLP/opus-100` test；32 个 en 枢轴 pair、259 样本、SHA256 固化；`pyarrow 26.0.1` + `sacrebleu 2.6.0`；`hymnctl evaluate` **259/259 成功、0 失败**；修复前总体 BLEU **22.04** / chrF2 **38.87**、64 方向 | 2026-11-21 14:2x | 修复后全量复测见 `translation-quality.json`；详见 `stage-h-roadmap.md` 第 9 节 |
| H2-c COMET | ⛔ **阻塞，如实未交付** | 0% | 本机 `torch` / `transformers` / `sentencepiece` 全部缺失；COMET 需神经评测模型（实测 2.32 GB）+ PyTorch，**不伪造分数** | 2026-11-21 14:0x | 方案与安装命令见 `stage-h-roadmap.md` 第 4 节 |
| H2-d 全部语言对覆盖 | 🟡 **本轮口径内完成** | 75% | 36 语言 UI/prompt 全覆盖；有权威参考译文的 32 语言 ×2 = 64 方向已逐条评测；`tl/bo/mn` 无平行语料，仅译文非空冒烟 3/3 | 2026-11-21 14:2x | **不是 36×35=1260 全方向**；1260 全方向因缺平行语料未做，口径写入 manifest 与 JSON `caveats` |
| H2-e 评测发现的措辞缺陷修复 | ✅ **已完成** | 100% | 评测实测 28/116 条 `en→X` 输出中文（7 语言），三后端对照定位为 Sherry 1.25bit 对「XX文」措辞敏感；改「XX语」后 7/7 正确；`LanguageCatalog` 只改 7 个名称 + `iw` 别名，新增 2 项断言，测试 **191/191**；修复后全量复测：**中文误出 28→1 / 116**、`en→es` 0→55.28、`en→he` 0→42.24、总体 BLEU 22.04→23.20 / chrF2 38.87→41.19 | 2026-11-21 14:4x | 对照存 `translation-quality-comparison.json`；`Sampler` 状态跨请求导致评测非请求级可复现（方法学发现，未修复），详见 `stage-h-roadmap.md` 第 9.6 节 |
| H3-a UserDefaults | ✅ **已完成** | 100% | `BackendPreference`（优先级 env > 偏好 > 默认 sherry、非法值回退、仅成功切换才写）；`backend-preference` 套件 14 项全绿；双进程重启冒烟：切到 mlx → 新进程读回 mlx → env 覆盖为 sherry | 2026-11-21 14:1x | 测试用 `HYMN_PREF_SUITE` 隔离，不污染真实偏好 |
| H3-b 像素级 UI 自动化 | 🟡 **工具已实现并编译，验证待授权** | 45% | 只读实测（14:50 复检仍 false）：`AXIsProcessTrusted=False`、`CGPreflightScreenCaptureAccess=False`、`screencapture` → `could not create image from display`、AppleEvent `-1712`。本轮新增 `Scripts/ui-backend-click.swift`（AXFrame 定位 + CGEvent 真实点击 + screencapture/ImageIO RGBA 像素差）与 `Scripts/ui-automation.sh`；`swiftc` 编译 **rc=0**，权限不足时 `rc=2 / UI_CLICK_BLOCKED / no_click_emitted=true`，报告写 `ui-automation-click.json` | 2026-11-21 14:5x | **仍未跑通**：AX 树是否暴露 SwiftUI segmented Picker、Retina 坐标换算、状态栏切换都须授权后实测；不拿编译通过或视图树实例化冒充像素级点击 |
| H4 v2 GGUF | ⛔ **明确排除** | 100%（决议） | v2 为 ggml `type=40`（模型卡 `1.25bit-new`）；PR #22836 与 mainline 均无该类型权威 block 布局/码本；第三方 MLX 参考仅覆盖 v1 的 STQ1_0 | 2026-11-21 14:0x | 按「未经验证不得编造算子」硬规则，不解析、不猜测、不冒充 |

**当前生产基线（推理计算核心未改；`RealModelBackend` 仅改语言名委托）**：`./Scripts/build.sh` rc=0、测试 **191/191**（164 + H2-a 11 + H3-a 14 + H2-e 2）、
默认后端 **Sherry STQ1_0 1.25bit GGUF 常驻 GEMV**、`.app` v0.4.0 / 84 MB。
H2/H3 只新增测试与评测工具链，**未改推理核心**、未替换后端、未把任何格式冒充为 LUT4。

> 注：以上是 **2026-11-21 16:00 之前的历史基线**。本节之后的第 10 节记录
> 「取消 D-1 / MLX 后端」的产品化改造，测试数与 .app 体积均随之变化。
>
> **状态更新（2026-11-21 晚）**：本表中 H1-a / H1-b / H1-c / H2-c / H2-d 及
> 「Sampler 请求级可复现（方法学发现，未修复）」均为当时快照，**不再代表现状**。
> 这四项已于当晚全部实施完成，真实数据与口径见 **第 12 节**；
> H1-c 的「不重复计功」结论保持不变，`fused dequant-GEMM` 仍不宣称新造算子。

---

## 10. 单后端产品化与上线准备（2026-11-21）

用户决议：**取消 D-1 原生 Metal 与 MLX Swift 两个后端，移除不需要的文件和配置，
主攻 1.25bit GGUF，优化 UI，为全功能 App 上线做准备**。

### 10.1 范围与变更清单

| 类别 | 具体变更 |
|---|---|
| Target 精简 | `Package.swift` 删除 `HymnNative` / `HymnMLX` 两个 product+target、两个本地 path 依赖（mlx-swift-lm / mlx-swift-main）、`HymnCore` 的 resources 声明；target 由 8 个降为 6 个，**零外部 SwiftPM 依赖** |
| 运行时合并 | Sherry 实际复用的最小运行时搬进 `HymnSTQ`：`SherryTokenizer` / `SherrySampling` / `SherryMetalOps`（去掉 MPS gemm 与 safetensors 错误类型）/ `SherryTypes` / `SherryPrompt` / `SherryRuntimeProbe`；`InferenceBackend` 等通用协议留在 `HymnCore` |
| 删除源码 | `RealModelBackend`、`BackendPreference`、`ProbeResources` / `ModelSpec` / `WeightFormat`、`model-probe` 资源、整个 `HymnNative` / `HymnMLX` 目录 |
| 删除测试 | `NativeTests` / `WeightCacheTests` / `ForwardTests` / `RealBackendTests` / `MLXBackendTests` / `MetalOpsTests` / `BackendPreferenceTests` / `CompatibilityTests`；新增 `RuntimeProbeTests`；测试数 **191 → 101**（全部通过） |
| 删除脚本 | `build-mlx-swift.sh`、`verify-xcode.sh`、`fetch-model.sh`、`gen-forward-golden.py`、以及只服务三选一 Picker 的 3 个 UI 自动化脚本 |
| CLI | 去掉 `--backend` / `weights` / `cache` / `forward`；`verify` 改为**只读运行时自检**（GGUF 头、config、tokenizer、Metal、格式标注、离线声明），`--json` 输出；`translate` / `evaluate` 固定唯一后端 |
| App | 删除 `BackendChoice`、三选一 Picker、`switchBackend` 状态机与 `HYMN_BACKEND` 覆盖；改为侧栏四页（翻译 / 历史 / 术语库 / 设置）+ 双栏编辑器 + 状态栏 + 完整菜单与快捷键 |
| 打包 | 去掉 MLX `default.metallib`、随 App 分发的 `Golden/` 与研发报告、4bit 软链；**`.app` 84 MB → 3.7 MB**（可执行文件 2.6 MB） |

退役源码/脚本未永久删除，归档在 `../_retired-20261121/`（364 KB），可随时取回。

### 10.2 大体积资源清理（用户确认后执行）

以下 6 项**移入系统废纸篓 `~/.Trash/*-retired-20261121-204702`**（可恢复，未永久删除）：

| 路径 | 体积 | 说明 |
|---|---|---|
| `Models/Hy-MT2-1.8B-4bit/` | 4.3 GB | D-1 / MLX 权重与 fp16 展开缓存 |
| `Models/Hy-MT2-1.8B-1.25Bit-GGUF/weights.fp16.bin` | 3.3 GB | 仅离线 golden，运行时不需要 |
| `research/` | 2.6 GB | MLX Swift / swift-numerics 上游副本与探针 |
| `mlx-swift-main/` / `swift-numerics-main/` / `metal-cpp/` | 约 38 MB | 上游源码副本 |
| Application Support 里的 4bit 悬空软链 | — | 一并移除 |

`Golden/`（2.4 MB）作为历史 golden 证据保留，但**不再随 .app 分发**；清理后重跑完整发布链路，
构建 / 测试 / 真机冒烟全部通过，证明运行时对以上资源**零依赖**。

### 10.3 上线准备清单

| 项 | 状态 | 证据 |
|---|---|---|
| Info.plist 完整元数据 | ✅ | v0.5.0 / build 4 / macOS 14+ / 类别 / 版权 / 中文开发区域 / 高分屏 |
| App 图标 | ✅ | `Assets/HymnTranslate.icns`，`Scripts/make-icon.swift` 纯代码绘制 10 个尺寸 |
| 首次启动模型引导 | ✅ | 设置页「选择模型目录…」→ UserDefaults `hymn.modelDirectory` → `locateSherryModelDirectory()` 候选 2；分发版不内嵌 440 MB |
| 资源缺失不静默降级 | ✅ | 错误横幅列出缺失文件 + 修复路径；显式切 Fixture 并标注「输出不是译文」；可「重新检测」 |
| 运行时自检 | ✅ | `hymnctl verify [--json]` → `Reports/release-runtime.json` |
| 签名 | ✅ | ad-hoc `codesign --force --deep --sign -`，`codesign -dv` 校验通过 |
| 动态库洁净化 | ✅ | `otool -L` 仅系统 `/usr/lib/swift/*` 与系统框架，**无第三方 / 无项目路径 dylib** |
| 一键发布 | ✅ | `Scripts/make-release.sh`：构建 → 测试 → 图标 → .app → 自检 → 真机冒烟 → DMG |
| 双进程重启持久化 | ✅ | 语言 / 最大长度 / 模型目录偏好写入 UserDefaults，第二进程冒烟读回并真译成功 |
| 界面像素级核对 | ✅ | `Reports/ui-final-translate.png`、`ui-final-settings.png`、`ui-final-app-window.png`；修正侧栏孤字换行 |
| Developer ID 签名 + Apple 公证 | ⬜ **未做** | 需要付费开发者账号；ad-hoc 签名不等于公证，正式上架/免警告分发前必须补齐 |
| 模型分发渠道 | ⬜ **未定** | DMG 仅 2.1 MB，不含 440 MB GGUF；需提供独立模型下载或在首次启动引导用户放置 |

### 10.4 本轮验证数据（清理后复跑）

- `./Scripts/build.sh` → **BUILD_OK rc=0**；`./Scripts/test.sh` → **101/101 通过、0 失败**（11 个套件 + 性能基准）。
- `hymnctl verify`：GGUF **461,860,800 B** / v3 / **354 tensors** / Apple M3 Pro / config+tokenizer OK / **READY** / 全程离线。
- `.app` 真机冒烟（headless，真实模型）：默认真译 **「你好，很高兴见到你。」**，6 tokens / **1212 ms**，
  主线程 10 ms tick `count=119 max=20.25 ms avg=10.26 ms`；`real=true`、`identifier=hymn-stq1_0-gguf-v1`、`error=none`。
  第二进程重启冒烟：1212 ms、`max=23.21 ms avg=10.18 ms`，译文一致，偏好读回成功。
- 产物：`dist/HymnTranslate.app` **3.7 MB**、`dist/HymnTranslate-0.5.0.dmg` **2.1 MB**、
  `Reports/release-runtime.json`、`Reports/release-smoke.log`。
- 已知噪声：macOS 27 的 `hdiutil create -volname -format` 给出弃用警告，DMG 产物正常。
- 工程从 Documents 目录直接双击 .app 时，macOS 会请求「文件与文件夹 → Documents」一次性授权；
  正式分发建议安装到 `/Applications`，模型目录由用户在设置页自行选择。

### 10.5 历史项状态结算

- **H3-a（BackendPreference）**：三选一偏好随后端退役而删除；改为产品化的语言 / 最大生成长度 / 模型目录偏好，
  双进程重启验证通过，旧的 `hymn.backend.choice` 键已清理。
- **H3-b（像素级 UI 自动化）**：16:33 授权后**已真跑通** —— AXFrame `[1584,526,131,24]`、
  CGEvent 点击 `(1649.5,538)`、控件区像素变化 **10872/12576（86.45%）**、`defaults` 写入 `mlx`。
  随后端切换 Picker 退役，工具归档到 `_retired-20261121`，`Reports/ui-automation-*.json` 保留为证据。
- **H1（量化 KV cache / batched prefill）、H2-c COMET、H2-d 1260 全方向、Sampler 请求级可复现、H4 v2 GGUF 排除**：
  状态不变，仍是已知边界，未在本轮伪造任何完成结论。
- 权重口径不变：**STQ1_0 1.3125 bpw 仅指 224 个线性层；NOT LUT4 / NOT affine INT4 / NOT fp16 展开缓存**。



---

## 11. 品牌化、UI 去技术化与划词即译（2026-11-21 21:xx）

用户决议：App 名称改为**智译星 / LinguaNova**；取消 UI 里的模型信息；
最小化进托盘后支持鼠标即划即译。

### 11.1 改名

| 位置 | 新值 |
|---|---|
| 显示名 / 窗口标题 / 菜单 / 关于页 | 智译星（全称「智译星 LinguaNova」） |
| `CFBundleName` / 英文品牌 | LinguaNova |
| `.app` / DMG | `dist/LinguaNova.app`、`dist/LinguaNova-0.6.0.dmg` |
| 版本 | v0.6.0（build 5） |
| 图标 | `Assets/LinguaNova.icns`，渐变底 +「译」+ 四角星（纯代码绘制） |

**内部 `CFBundleIdentifier`（com.hymntranslate.macos）与 Application Support 数据目录保持不变**，
避免改名导致用户已保存的模型目录偏好、历史记录、术语库丢失；界面不暴露该内部名。

### 11.2 UI 去模型信息

- 移除：侧栏底部「STQ1_0 / 1.3125 bpw / 常驻 GEMV / 永不标 LUT4」三行；状态栏的格式串与后端标识；
  设置页「推理后端（唯一，不可切换）」整卡、GGUF 文件名、张量数、运行时自检明细、数据库完整路径；
  历史列表的 tokens；页头的「真实推理 / 测试替身」「本地 1.8B 模型」。
- 保留（属于能力与操作信息，不是模型参数）：「已就绪 / 未就绪」「全程离线」徽章、初始化引导与
  「选择模型文件夹」按钮、上次用时（秒）、历史条数、36 语言选择器。
- 「最大生成长度」由 Stepper 改为用户向的四档 Picker（较短 / 标准 / 较长 / 超长，内部映射 64/128/256/512）。
- **口径**：UI 不再展示模型信息 ≠ 谎称其他格式。`hymnctl verify`、代码注释、历史 `model_tag`、
  CLI 输出与本计划表仍如实标注 STQ1_0 1.3125 bpw（NOT LUT4 / NOT affine INT4）。

### 11.3 托盘常驻与划词即译

- `NSStatusItem` 常驻菜单栏（sparkles 模板图标）；`windowShouldClose` → `orderOut` 且返回 false，
  关闭/最小化主窗口后进程不退出；Dock 重新打开恢复窗口。托盘菜单：打开 / 划词翻译开关 / 关于 / 退出。
- `SelectionWatcher`：全局 `leftMouseUp` 监听（含 `leftMouseDown` 用于隐藏浮窗），120 ms 延迟等待选区，
  2 秒内同文本去重，开关持久化到 `linguanova.selectionEnabled`。
- `SelectionCapture`：优先用 Accessibility 读 `kAXSelectedTextAttribute`（不碰剪贴板）；
  应用不暴露时回退模拟 ⌘C，用 `changeCount` 判定是否真的有新内容，并**保存/恢复剪贴板原字符串**。
  两条路径都需「辅助功能」授权，用户开启时会弹系统授权引导。
- `SelectionPanelController`：非激活 floating `NSPanel`（不抢焦点），在鼠标附近定位并限制在可见屏幕内，
  外部点击自动隐藏；浮窗显示原文、流式译文、复制译文、在主窗口打开。
- `AppModel.translateSelection`：独立 generation 机制丢弃过期结果，不覆盖主窗口输入/输出，
  译文写入历史并标 `SELECTION`；仍走 `RequestScheduler` 单实例调度与 `Task.detached` 推理。
- 主菜单「翻译 → 划词翻译 开/关」（⌘⇧T）提供不依赖托盘的等价开关。
- headless 冒烟跳过托盘与全局监听；`HYMN_SELECTION_SELFTEST=1` 验证划词数据链路；
  `HYMN_DB_PATH` 让冒烟写临时库，不污染用户历史。

### 11.4 本轮验证数据

- `BUILD_OK rc=0`（零警告）、测试 **101/101**、`hymnctl verify` READY（461,860,800 B / v3 / 354 tensors / M3 Pro / 离线）。
- 真机冒烟：真译「你好，很高兴见到你。」、主线程 tick `max=23.32 ms / avg=10.17 ms`；
  `SELECTION_CHAIN main='你好，很高兴见到你。' selection='你好，很高兴见到你。' error=none`。
- **真实跨应用划词 E2E**：TextEdit 中选中 `Hello, nice to meet you.` → 全局鼠标监听 → 浮窗弹出
  （`Reports/selection-popup.png`）→ 译文「你好，很高兴见到你。」→ SQLite 新增 `SELECTION` 记录。
- **托盘态 E2E**：点击关闭主窗口后，进程仍在、主窗口从屏幕窗口列表消失；
  再次划词新增一条 `SELECTION` 记录，译文一致。证据 `Reports/selection-e2e-evidence.json`，
  验证产生的 9 条测试历史已清理，用户原有 56 条数据未动。
- 界面截图：`Reports/ui-linguanova-translate.png`、`ui-linguanova-settings.png`、
  `ui-linguanova-menubar.png`（可见托盘星形图标）。
- 产物：`.app` **4.0 MB**、DMG **2.2 MB**。

### 11.5 已知边界（截至 v0.6.0 当时；12 节已结算其中四项）

> 本节为 21:2x 的当时状态。H1 优化、COMET、1260 全方向、Sampler 请求级可复现
> 已于当晚完成，见 **第 12 节**；下面「状态不变」一句仅对该时点有效。

- 托盘**下拉菜单**的自动化合成点击（CGEvent）在 macOS 27 上未弹出；`NSStatusItem` 的 tracking 可能不吃合成事件。
  托盘图标、常驻行为、托盘态划词均已实测；主菜单开关可等价使用。菜单交互需用真实鼠标人工确认。
- 划词依赖「辅助功能」授权，分发版首次开启会弹系统授权框；若用户拒绝，AX 与 ⌘C 两条路径都会失效。
- 上线阻塞不变：Developer ID 签名 + Apple 公证、440 MB 模型分发渠道、从 Documents 运行 .app 的 TCC 弹窗。
- H1 优化、COMET、1260 全方向、Sampler 请求级可复现已于当晚实施，见第 12 节；v2 GGUF 排除状态不变。

## 12. H 阶段收尾：请求级可复现 / H1 / COMET / 1260 全方向（2026-11-21 晚）

### 12.1 Sampler 请求级可复现

- **问题定位**：`Sampler` 唯一可变状态 `state: UInt64`（xorshift64）在 `SherryGenerator.init` 创建一次并跨请求复用；
  `SamplingConfig.seed` 是**从未被读取的死字段**，因此同一请求复跑结果依赖此前请求消耗的 RNG 步数，
  评测不是请求级可复现的。
- **改动**：`SherryGenerator.generate` 开头按 `sampling.seed`（为 0 时回退后端默认种子）重建**局部** `Sampler`，
  删除实例属性与 `NSLock`；局部量天然线程安全，单实例调度之外也不存在共享可变状态。
  首个请求译文不变（默认 seed 与修复前初始种子相同），变化的是第 2 个及之后的请求。
- **CLI**：`hymnctl evaluate` 新增 `--seed <uint64>` / `--greedy`；输出每行新增
  `sampling_mode` / `sampling_seed` / `request_level_reproducible`，评测结果自带复现口径。
- **验收**：新增 `sampler-determinism` 套件 7 项（纯采样器 4 项 + 真实后端端到端 3 项）。
  端到端实证：`a1=你好，很高兴见到你。` → 插入另一请求 `机器学习正在改变世界。` →
  `a2/a3` 与 `a1` **逐字一致**；greedy 模式亦确定且非空。测试数 **101 → 110**。

### 12.2 H1 推理优化

- **fused dequant-GEMM 口径澄清**：`stq1_0_gemv` 自 G4 起已是「解码即乘加」融合
  （直接读 42 B/256 GGUF block 解码并立即累加，无中间 fp16 权重缓存）。
  **实证已完成，本轮不重复造算子、不重复计功**。
- **batched prefill（无损，默认启用）**：新增 `SherryResidentModel.prefill(ids:chunkSize:)`，
  把 prompt 多 token 编码进按 8 token 分块的 command buffer；中间 token 跳过最终 norm + tied lm_head
  （只有最后一个 prompt token 的 logits 参与采样）；`MetalOps.submit` 只提交不等待，
  最后一次 `commit(wait)` 依靠 MTLCommandQueue FIFO 排空队列，保证 KV 写入顺序与逐 token 等价。
  `HYMN_BATCHED_PREFILL=0` 可回退到原逐 token 路径做 A/B 对照。
- **量化 KV cache（有损，默认关闭）**：新增 `kv_write_int8` / `attention_decode_int8` 两个 MSL kernel，
|  |  |  |
| --- | --- | --- |
  per-(token, kvHead) fp32 scale = max(|x|)/127；新增 `KVCacheMode`（fp16 / int8 / auto），
  `HYMN_KV_INT8=1` 或显式 `.int8` 才启用。
- **`hymnctl bench-h1 --runs 5` 实测**（22 个 prompt tokens，Apple M3 Pro，真实 Metal 执行）：

  | 指标 | 结果 |
  |---|---|
  | baseline（逐 token） vs batched logits | **逐位完全相等**，120,818 维 maxAbs = **0.0** |
  | prefill 中位耗时 | 892.4 ms → **556.4 ms（1.60×）**；int8 路径 514.1 ms |
  | int8 vs fp16 logits | Pearson corr **0.999994**、maxAbs 0.0312、top20 **20/20**、argmax 一致 |
  | KV cache 占用 | fp16 **67,108,864 B（64 MiB）** → int8 **34,603,008 B（33 MiB）**，省 **32,505,856 B ≈ 31.0 MiB** |
  | greedy 端到端译文 | fp16 = int8 = 「你好，很高兴见到你。」 |

- **如实边界**：int8 只省约 31 MiB（与 H1 早期预估一致），是有损优化且默认关闭，不夸大收益；
  `sherry-resident` 套件新增 4 项断言（prefill 逐元素等价、默认 fp16 64 MiB、int8 模式生效且更省、
  int8 logits corr 0.999993 / top20 20/20 / argmax 28036），全量 **112/112**。
  数据落盘 `Reports/h1-optimization-bench.json`。

### 12.3 COMET 系统级翻译质量评测（真实分数，非占位）

- **环境阻塞与解法**（全部如实记录，未静默降级）：
  1. 当前 WorkBuddy Python 3.13.12 无法安装 `unbabel-comet 2.2.7`（要求 `numpy<2`，而
     NumPy 1.26.4 无 cp313 wheel）→ 改用系统 Python 3.9.6 的独立 venv `Eval/.venv-comet39`。
  2. PyPI 直连实测仅约 20 KB/s，torch 138 MB 需数小时 → 改用清华 PyPI 镜像，3 分钟装齐
     torch 2.6.0 / pytorch-lightning 2.6.0 / unbabel-comet 2.2.7 / transformers 4.57.6 / sacrebleu。
  3. setuptools 82 移除 `pkg_resources`，导致 torchmetrics 0.10.3 import 失败 → 降级 setuptools 75.8.0。
  4. 官方 ckpt `Unbabel/wmt22-comet-da` 为 **2,323,649,073 B（2.32 GB）**，hf-mirror 单连接约
     0.2 MB/s → 新增 `Scripts/download-comet-model.py` 用 12 线程分段并发下载，实测约 5 MB/s、
     600 秒完成，字节数与服务端 Content-Length 完全一致；同时取回 `hparams.yaml`。
  5. `load_from_checkpoint` 以 `load_pretrained_weights=False` 从 ckpt 恢复权重，无需再下载
     2.2 GB 的 XLM-R 底座；只额外预取 XLM-R tokenizer（vocab 250002）。
- **只搬运官方字节**：下载脚本不改权重、不生成任何分数；`Scripts/score-comet.py` 在
  模型/依赖不可得时写 `status=BLOCKED` + 具体原因 + `never_fabricated=true`，**绝不填充占位分数**。
- **真实结果（最终值，对应修复后最终二进制）**：输入为请求级可复现且已修掉流式字符损坏的
  259 条最终批次 `Reports/translation-hypotheses-final.jsonl`，MPS 推理，256 条带权威参考译文。

  | 指标 | 最终值 | 流式修复前 |
  |---|---|---|
  | COMET system_score | **0.7809**（mean 0.7809 / min 0.3244 / max 0.9875） | 0.7345 |
  | BLEU / chrF2 | **23.19 / 43.86** | 22.62 / 41.21 |
  | 打分样本 / 方向 | 256 条 / 64 个 en 枢轴方向 | 同左 |
  | 最佳方向 | en→id 0.9507、en→pl 0.9448、id→en 0.9248、zh→en 0.9203 | — |
  | 最弱方向 | en→mr 0.3544、en→ta 0.3827、en→hi 0.3879、en→bn 0.4524、en→kk 0.4604 | — |

  **流式解码修复带来的真实提升**：BLEU +0.57、chrF2 +2.65、COMET **+0.0464**；
  没有调参、没有改权重，只是消除了译文里的 U+FFFD 残留与字符重复。
  修复前分数留档 `comet-scores-before-streaming-fix.json` / `translation-quality-before-streaming-fix.json`。
- **口径**：wmt22-comet-da 训练于 WMT22 新闻领域，对 OPUS-100 领域与低资源语言需谨慎解读；
  COMET 是神经模型给出的估计值，**不与 BLEU/chrF2 直接换算或比较绝对值**；无参考译文的样本不参与打分。
  最终结果落盘 `Reports/comet-scores.json`，并接入 `Reports/translation-quality-final.json`。
- **三阶段对照**（同 259 样本、同后端、同 maxTokens=64、同语言名映射）：
  历史基线 23.20 / 41.19 → Sampler 修复后 22.62 / 41.21 / COMET 0.7345 →
  最终 23.19 / 43.86 / COMET 0.7809。Sampler 修复改变采样序列属预期口径变化，
  流式修复只改字符串增量拼接；三阶段分数口径不同、不可混用。见 `Reports/reproducibility-comparison.json`。

### 12.4 1260 评测额外发现并修复：流式译文字符级损坏（真实 bug）

- **现象**：1260 全方向首轮评测中，509 个方向译文含 U+FFFD 替换字符且伴随相邻字符重复
  （`ཚཚ`、`वव`、`कक`），集中在高棉/天城/藏/缅/古吉拉特等复杂脚本语言；13 个拉丁系
  目标语言完全无退化。历史待办「tl/bo/mn 重复/替换字符原因未定位」由此定位到根因。
- **排除干扰**：509 条中仅 22 条替换字符只在尾部（`--tokens 32` 截断特征），**487 条中间也有**，
  证明不是 maxTokens 截断造成。
- **根因（实证，非推测）**：`HymnTokenizer.decode` 把 byte-level BPE 累积字节交给
  `String(decoding: as: UTF8.self)`，逐 token 解码时未完成的多字节字符尾部会变成 U+FFFD；
  旧 `SherryBackend.delta` 用 `Array(String)`（grapheme cluster）取前缀差，
  组合字符合并会让前缀失配 → 同一段被重复 yield，先前 yield 的 U+FFFD 又无法撤回。
- **修复**：新增 `SherrySTQ/StreamingTextDecoder`，按 **Unicode scalar 计数**做增量，
  屏蔽尾部连续 U+FFFD（未收齐的多字节字符）后再发送；生成结束时 `finish()` 冲刷，
  若确因截断留下未完成字节则如实补一个替换字符，不静默吞字。
  纯字符串层修复，**不改任何模型算子、权重或采样逻辑**。
- **实证**（`streaming-decode` 套件 6 项，全部通过）：
  - 旧逻辑 `"A\u{FFFD}" → "A中"` 拼出 `A\u{FFFD}中B`；新逻辑得 `A中B`。
  - 天城文组合字符 `क → क् → क्म`：旧逻辑拼出 `कक्क्म`（重复），新逻辑得 `क्म`。
  - 真实 tokenizer 5 种复杂脚本逐 token 解码：**旧逻辑 4/5 损坏，新逻辑 5/5 与一次性 decode 完全一致**。
- **端到端抽样**（9 个 zh→X 方向，修复后）：hi/km/my/bo 译文已完全干净，
  仅 gu/mn 各剩 1 个 U+FFFD 且都位于**字符串末尾**（截断切到多字节字符，如实标注）。
- 测试总数 **112 → 118**；首轮评测产物已留档为
  `Reports/coverage-1260-hypotheses-before-streaming-fix.jsonl` 与
  `.../coverage-1260-report-before-fix.json`，修复后全量重跑结果见 12.5。

### 12.5 1260 全方向覆盖评测（最终结果）

- **样本构造**（`Scripts/build-coverage-1260.py`，离线、不联网、不编造参考译文）：
  36 语言 × 35 目标 = **1260 方向**全覆盖；其中 **64 个 en 枢轴方向**有 OPUS-100 权威平行参考译文，
  **1196 个方向无参考，只做可译性冒烟**；33 种语言从已落盘语料取真实锚句，
  `tl/bo/mn` 无 OPUS 平行语料，用英文代理锚句并逐条标 `anchor_is_proxy`（共 105 条）。
- **真实推理**：`hymnctl evaluate --tokens 32 --greedy` 跑满 **1260/1260，零失败、零空输出**，
  每请求按 seed 重建 Sampler，请求级可复现。
- **修复后最终覆盖结果**（`Reports/coverage-1260-report.json`）：

  | 指标 | 修复前首轮 | 修复后最终 |
  |---|---|---|
  | 方向覆盖 | 1260/1260 | **1260/1260** |
  | 冒烟非空 / 无错误 | 1196 / 1196 | **1196 / 1196** |
  | 退化方向 | 491 | **0** |
  | 含 U+FFFD 方向 | 497 | **98（全部为尾部截断标注）** |
  | 64 有参考方向 BLEU / chrF2 | 23.05 / 38.31 | **23.76 / 40.27** |
  | bo / mn 退化 | 30/35、35/35 | **0/35、0/35** |
  | 1196 冒烟方向产出的质量分数 | 0 | **0（刻意不产）** |

- **如实口径**：64 个有参考方向每方向仅 1 句且 `--tokens 32` 截断，BLEU/chrF2 只作回归信号，
  不是 WMT/FLORES 排行榜；系统级质量结论以 259 条 / 每方向 4 句的
  `Reports/translation-quality-final.json`（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）为准。
  1196 个无参考方向**不产任何 BLEU/COMET/chrF 分数**，不得据此声称这些方向的翻译质量；
  tl/bo/mn 只报告可观测现象，不臆测模型内部成因。
- **低资源语言结论**：修复后 tl/bo/mn 作为目标的 35 个方向全部非空、零退化；
  bo 目标文字占比 0.8277、mn 0.7418。历史上「重复/替换字符」现象已归因于流式解码缺陷，
  **不是模型不支持这些语言**；剩余 98 个 U+FFFD 全部位于译文末尾，是 maxTokens 截断
  切到多字节字符时 `finish()` 的如实标注。
- 两次全量评测（各约 43 分钟）的译文假说、日志与报告均留档；判据统一后才做前后对比
  （尾部单个 U+FFFD 单列 `truncation_marker`，不计入 `looks_degenerate`）。

---

## 13. 划词浮窗按划词量自适应尺寸（2026-11-21 23:xx）

### 13.1 变更清单

- 原实现：`SelectionPopupView` 固定 `380×240`、译文区固定 `96` 高，与选区长度无关；
  `SelectionPanelController` 用固定 `NSPanel(380×240)`，只在显示前按鼠标位置摆一次。
- 新增 `Sources/HymnCore/UI/SelectionPopupLayout.swift`：纯 Swift、无 AppKit 依赖的尺寸计算
  （`SelectionPopupSizer` / `SelectionPopupLayout` / `SelectionPopupContent`），便于 headless 单测。
  - 宽度按「划词原文为主、译文为辅」的加权字符单位分四档：
    `compact 320` / `standard 380` / `wide 440` / `max 520`，并钳到屏幕宽度 − 32。
  - 高度按估算折行数计算：原文区最多 2/3/5/6 行（随档位放宽），译文区按行数给高度，
    全角/复杂脚本按 2 或 1.5 单位、窄拉丁字符 0.55、组合标记 0，带 10% 折行余量。
  - 上限 `min(640, 屏幕可见高度 × 0.62)`；超出时把剩余空间全给译文区并标记 `scrolls=true`，
    改为窗内滚动，浮窗不会盖住整块屏幕。下限 176。
  - 不变量：`height = baseHeight(121) + sourceHeight + translationHeight`，
    视图与 NSPanel contentSize 严格一致，不裁切不错位。
- `SelectionPopupView`：所有几何量改为读 `SelectionPopupState.layout`，
  分隔线换成显式高度 `Rectangle` 以避免 Divider 的隐式间距破坏恒等式。
- `SelectionPanelController`：`SelectionPopupState` 作为单一数据源；Combine 订阅
  `selectionSource / selectionTranslation / selectionError / isSelectionTranslating`，
  流式译文增长时自动跟随；节流条件为「宽度差 ≥ 1pt 或高度差 ≥ 12pt」，避免逐 token 抖动；
  尺寸变化后按同一锚点重新钳制到可见屏幕；`styleMask` 加 `.resizable`，
  `windowDidResize` 检测用户手动拖拽后**本轮**不再被自动尺寸覆盖。
  不使用窗口动画（异步帧会干扰手动判定且流式时会持续抖动）。
- `main.swift`：把 `translateSelection` 调到 `show(at:)` 之前，使首次布局基于本次选区，
  不会短暂显示上一次的译文。


### 13.2 验证数据（`make-release.sh` 最终二进制）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**130/130**（原 118 + 新 `selection-popup-layout` 12 项） |
| 运行时自检 / 真机冒烟 | READY；真译「你好，很高兴见到你。」；划词链路译文一致；tick max 23.47 ms / avg 10.13 ms |
| 产物 | `.app` 4.2 MB、DMG 2.3 MB（v0.6.0） |

真机实测（TextEdit 全选 → 全局 mouseUp → `CGWindowList` 读浮窗外框）：

| 划词量 | 窗口外框 | 内容宽度 | 内容高度≈ |
|---|---|---|---|
| 短 24 字符 | 320×209 | 320 | 181 |
| 中 125 字符 | 380×225 | 380 | 197 |
| 长 1115 字符 | 520×365 | 520 | 337 |

宽度与高度均严格单调递增。证据 `Reports/selection-popup-sizing.json`，
截图 `Reports/selection-popup-{short,medium,long}.png`。

### 13.3 如实边界

- `CGWindowList` 的 bounds 是窗口外框，含约 28pt 标题栏；表中「内容高度」为 `bounds.h − 28` 的近似值。
- 超长原文按档位最多显示 6 行并尾截断（用户自己选的内容，可复制），**译文完整显示或窗内滚动**，不丢失。
- 合成 `⌘A` 在长文本文件上偶发首字符偏移（曾出现 `This`→`his`），属自动化选区时序；
  延长等待后复现消失，与尺寸逻辑无关。真实鼠标跨应用 E2E 已另行验证（第 11 节）。
- 窗口可手动拖拽调整，拖拽后本轮自动尺寸让位；**下一次划词重新按文本量计算**（不做跨请求尺寸持久化），
  手动拖拽的像素级自动化未做，需真实鼠标确认。
- 上线阻塞项（Developer ID 签名 / 公证、440 MB 模型分发、Documents TCC、托盘菜单人工确认）不变。

---

## 14. 五项产品增强（2026-11-22 00:xx，v0.7.0）

### 14.1 关闭操作提示音

- 排查结论：源码**没有任何主动发声代码**（无 `NSBeep` / `NSSound` / `AudioServices`），
  菜单 action 全部有实现；「嘀嗒」来自 AppKit 在 responder chain 无人响应按键时
  调用 `noResponder(for:)` 播放的系统提示音。
- 实现 `SilentMainWindow` / `SilentFloatingPanel`（`Sources/HymnApp/SilentWindows.swift`），
  空覆盖 `noResponder(for:)` 且不调用 `super`：已注册的快捷键、文本输入、按钮操作
  **全部照常**，只有本来无效的事件被静默。不改系统全局音效、不影响其他 App。
  主窗口与划词浮窗均换成这两个子类；设置页「翻译偏好」标注「操作提示音：已关闭」。
- 验证：`nm -u` 确认二进制无 `NSBeep` 符号引用；菜单快捷键 ⌘1~5、文本输入、划词均正常。
  **声音是主观感知，需用户用真实操作确认已消失**；系统级音效（截图音等）不受影响。

### 14.2 零依赖 TXT / DOCX 导出底座

- `Sources/HymnCore/Documents/DocumentExport.swift`：`TranslationDocument` 统一描述
  标题 + 若干「原文/译文/备注」条目；`TranslationDocumentWriter` 产出 UTF-8 TXT
  与标准 OOXML DOCX（`[Content_Types].xml`、`_rels/.rels`、`word/document.xml`、
  `word/_rels/document.xml.rels`）。
- ZIP 为手写 store 模式（本地头 / 中央目录 / EOCD + CRC-32 IEEE 802.3），
  固定 DOS 时间戳保证字节级确定性；XML 1.0 实体转义并剔除非法控制字符。
  **不链接 zlib、不启动外部进程、不联网、不进 .app 任何第三方依赖**。
- `DocumentExporter`（AppKit 层）用 `NSSavePanel` 由用户指定位置写出，取消不落盘。
- 独立验证：Swift 侧 11 项 `document-export` 测试（CRC32 标准向量 `0xCBF43926`、
  ZIP 四部件与逐部件 CRC、XML 转义、中文/emoji、确定性、空文档）；
  Python `zipfile.testzip()` 通过、ET 解析通过；**macOS `textutil -convert txt` 成功读出
  中文、emoji 与被转义的 `<world>` 原文**。样品 `Reports/export-sample.docx` / `.txt`。

### 14.3 划词浮窗增加两个保存按钮

- `SelectionPopupView` 底部改成两行：复制译文 / 在主窗口打开；
  **保存为 TXT 格式 / 保存为 DOCX 格式**。导出内容含原文、译文与语言对。
- `SelectionPopupSizer` 同步更新：`footerHeight 28→56`、`minHeight 176→210`，
  baseHeight 自动 121→149，恒等式与全部 12 项布局测试仍成立。
  真机短划词浮窗外框 `320×238`（含约 28pt 标题栏），按钮完整无裁切。

### 14.4 14 种常用语言

- `LanguageCatalog.featuredCodes` = `zh, en, ja, ko, fr, de, es, pt, ru, it, ar, th, vi, id`
  （含简体中文，共 14 种）；`LanguagePicker` 只列这 14 种，主界面与设置页文案
  从「支持 36 种语言」改为「支持 14 种常用语言」。旧偏好若落在收敛掉的语言上回退默认值。
- **底层 36 种映射完整保留**：CLI `evaluate`、`hymnctl`、1260 全方向评测、
  历史记录中旧语言代码的显示都不受影响；没有删除数据，也没有宣称模型只支持 14 种。
  `document-export` 套件断言 `featuredCount == 14`、`count == 36`、每个 featured 都在 all 中。

### 14.5 历史记录单条与批量合并导出

- `HistoryView` 新增多选（`List(selection:)` 绑定到 AppModel 的 `@Published selectedHistoryIDs`，
  不用 `@State` 宏）、全选/取消选择、导出所选为 TXT / DOCX 两个按钮；
  每行新增导出菜单（TXT / DOCX）用于单条导出。单条与多条走同一
  `exportHistoryRecords` 路径，多条按列表顺序合并成一个文件。
- 搜索、回填、删除、清空功能保持不变。真机截图 `Reports/ui-v07-history.png`。

### 14.6 PDF 长文本翻译（支持几百页）

- 系统 **PDFKit** 逐页提取文字（`PDFTextExtractor`），无文字层/扫描件明确报错，
  **本版本不做 OCR，不编造文字**。`TextChunker`（HymnCore 纯逻辑）按页分块、
  保留段落边界、超长段落按上限硬切、空白页跳过、不跨页合并以保证页码精确。
- 新增侧栏第 5 页「PDF 翻译」（⌘5，原 ⌘1~4 不变）：选择 PDF → 显示页数/字数/段数 →
  进度条 + 开始/取消 → 最近几段译文预览 → 导出完整译文 TXT/DOCX。
- 翻译为**串行逐块**（单实例调度，不并发），每块 `maxTokens=512`，
  主线程只在每块结束后更新一次进度；完整译文保存在内存，预览限 6000 字符避免大字符串重绘。
  整体完成后写 1 条历史汇总，不为每块单独写记录。
- headless 冒烟实证：`HYMN_PDF_SMOKE` 走同一条链路，
  **310 页 / 1,534,446 字符 / 2787 块**，前 2 段真实模型翻译产出中文译文，
  DOCX 3,148 B / TXT 1,271 B 生成成功；主线程 tick max 22.09 ms / avg 10.13 ms。

### 14.7 验证与产物

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**149/149**（130 + `document-export` 11 + `text-chunker` 8） |
| 发布链路 | verify READY、真译「你好，很高兴见到你。」、划词链路一致、tick max 20.90 ms |
| 产物 | v0.7.0 build 6、`.app` 4.8 MB、DMG 2.4 MB |
| 截图 | `Reports/ui-v07-{translate,history,settings,pdf,selection-popup}.png` |

### 14.8 如实边界

- DOCX 是最小可用 OOXML 包（无 styles.xml / docProps），已由 `textutil` 与 Python zipfile
  验证可读；未在 Microsoft Word 桌面版里人工打开确认。
- PDF 分块翻译会损失跨段落上下文；块边界处可能出现语义不连贯，页码会写进导出文件。
  几百页 × 每块约 2–3 秒，**总耗时可达数十分钟到数小时**，UI 已明确提示并可取消。
- 扫描件（图片 PDF）无文字层，明确不支持；不调用任何 OCR 或联网服务。
- 保存面板由用户交互选择路径，**GUI 点击保存按钮未做像素级自动化**；
  写出的数据本身已用系统工具独立验证。
- 提示音抑制是代码层移除 AppKit 默认 beep 路径，**需用户主观确认**；
  系统级 UI 音效与其他 App 不受影响。
- 上线阻塞项不变（Developer ID 签名 / 公证、440 MB 模型分发、Documents TCC、托盘菜单人工确认）；
  STQ1_0 始终标 1.3125 bpw，NOT LUT4 / NOT affine INT4。

---

## 15. UI 顺序、精简与整体美化（2026-11-22 08:xx，v0.7.1）

### 15.1 五项调整

1. **PDF 翻译移到历史记录之上**：`AppSection` 顺序改为
   `translate → pdf → history → glossary → settings`，侧栏与视图菜单由同一 `allCases`
   生成，快捷键随顺序变为 ⌘1 翻译 / **⌘2 PDF 翻译** / ⌘3 历史 / ⌘4 术语库 / ⌘5 设置
   （`RootView.sidebarShortcut` 同步，不再有硬编码错位）。
2. **划词浮窗按钮**：`「保存为 TXT 格式」「保存为 DOCX 格式」` → `「存为txt」「存为docx」`，
   与「复制译文」放在**同一行**；「在主窗口打开」收成图标按钮（保留 help 提示）。
   `SelectionPopupSizer` 同步 `footerHeight 56→28`、`minHeight 210→182`（base 自动 149→121），
   12 项布局测试与恒等式仍全绿；真机短划词浮窗外框 `320×210`。
3. **取消「已就绪」「离线」提示**：删掉页头的「全程离线 / 已就绪」徽章、
   状态栏的状态圆点 + 「已就绪」+「离线」标签、设置页与 PDF 页的就绪徽章；
   `AppModel.status` 就绪时改为空字符串（异常时仍给可操作提示），
   `AppBrand.tagline` 改为「本机 AI 翻译」，副标题/说明文案中的「离线」字样同步清理。
   状态栏现在只保留操作反馈与耗时。
4. **左上角不显示版本号**：侧栏品牌区只显示「智译星」+「LinguaNova」。
   设置页「关于」卡片仍保留版本号（用户需要知道版本，且这不是左上角）。
5. **整体美化**：统一视觉令牌（渐变 `accentGradient`、柔和阴影、细边框）；
   侧栏加宽到 216、选中项左侧指示条 + 半透明圆角底、分组标题「工作区」、
   底部改成小卡片；品牌图标加渐变与阴影；`PageHeader` 改渐变图标底座 + 更大标题；
   `SectionCard` / `TextPanel` 圆角 14 + 阴影 + 标题小图标；
   `Badge` 加细描边；`EmptyStateView` 改圆形渐变底；
   PDF 译文预览空态改为居中图标 + 两行提示 + 圆角编辑区背景；
   按钮统一 `bordered` / `controlSize`，动作栏更紧凑。全部使用系统语义色，深浅色自动适配。

### 15.2 验证数据

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**149/149**（布局常量变更后 12 项全绿） |
| 发布链路 | verify READY、真译「你好，很高兴见到你。」、划词链路一致、tick max 22.94 ms / avg 10.13 ms |
| 产物 | v0.7.1 build 7、`.app` 5.0 MB、DMG 2.5 MB |
| 真机截图 | `Reports/ui-v071-{translate,pdf,history,settings,selection-popup}.png` |

真机逐项核对：左上角无版本号；侧栏顺序为 翻译 / PDF 翻译 / 历史记录 / 术语库 / 设置；
界面无「已就绪 / 未就绪 / 全程离线 / 离线」徽标；浮窗一行显示
「复制译文 / 存为txt / 存为docx / 图标按钮」且无截断重叠；
设置页关于卡片仍显示版本 0.7.1。验证产生的 1 条 SELECTION 历史已清理，原有 75 条未动。

### 15.3 如实边界

- 快捷键顺序随侧栏调整（⌘2 现在是 PDF 翻译，原 ⌘2 是历史记录），菜单与侧栏一致。
- 原文本框右侧可能出现系统 TextEditor 的垂直滚动条槽（由 macOS「始终显示滚动条」设置决定），
  不是布局错位；未强行关闭系统滚动条行为。
- 设置页仍显示版本号，符合「仅左上角不显示」的要求；如需全局隐藏可再调整。
- 上线阻塞项不变。

## 16. 划词弹窗「无效」修复与设置页精简（2026-11-22 09:xx，v0.7.2 build 8）

### 16.1 问题复现与真实根因

用户报告 v0.7.1 划词弹窗无效。对运行中的 `/Volumes/智译星 LinguaNova 1/LinguaNova.app`
（0.7.1 build 7）做真实划词复现：**浮窗其实会弹出**，但译文与中文原文逐字相同——
主窗口语言对是 `en → zh`，`translateSelection` 直接复用 `LanguagePair(source: sourceLang,
target: targetLang)`，划到中文文档时提示词变成「翻译成简体中文」，模型把原文照抄。
用户看到的「译文 = 原文」被理解为「弹窗无效」，证据 `Reports/selection-language-fix-evidence.json`。

复现中还定位到三处会放大该现象的可靠性缺陷：

| 缺陷 | 影响 |
|---|---|
| `SelectionWatcher.isCapturing` 布尔锁 | 某次 completion 丢失后永久为 true，之后所有 mouseUp 被挡，划词**永久失效且不恢复** |
| 剪贴板捕获轮询仅 12×20 ms | 长文本 / 慢应用 ⌘C 写入超过 240 ms 时误判「无选区」，不弹窗 |
| 缺辅助功能授权时静默失败 | 两条捕获路径都失败，用户看不到任何原因 |

### 16.2 修复内容

- 新增 `Sources/HymnCore/Compatibility/SelectionLanguageResolver.swift`（纯计算、可独立测试）：
  依据 Unicode 书写系统判定选区语言（假名优先于汉字，支持 ko/th/ar/ru；拉丁语系不臆造），
  自动选择**与选区不同**的目标语言；`en→zh` 划中文改为 `zh→en`，`zh→en` 划英文改为 `en→zh`。
  另按文本长度放宽划词 `maxTokens`（原固定 128 → 上限 512），长段落不再被截断。
- `AppModel.translateSelection` 改用解析后的语言对，浮窗 header 显示实际语言对（如「中 → 英」），
  历史记录写入实际 `source_lang / target_lang`，而非主窗口设置。
- `SelectionWatcher`：`isCapturing` 改为单调递增 `captureGeneration`，过期结果丢弃但不再永久阻塞；
  新增 `onAuthorizationNeeded`，未授权且捕获失败时弹系统授权引导（60 秒节流）。
- `SelectionCapture`：剪贴板轮询放宽到 30×30 ms（约 900 ms）。
- 捕获失败不再静默：设置页「划词翻译」行**仅在未授权时**显示「授予辅助功能权限」按钮；
  已授权时不显示任何常驻状态徽标（延续 v0.7.1「取消已就绪/离线提示」的约定）。
  App 切回前台时实时刷新授权状态，无需重启。
- **设置页移除「操作提示音」整行**（含「已关闭。无效按键不再播放系统提示音…」说明）；
  静默实现 `SilentMainWindow` / `SilentFloatingPanel` 保留，功能不受影响。
- 冒烟新增 `HYMN_SELECTION_SELFTEST_TEXT` 可指定选区文本；`make-release.sh` 的
  `SELECTION_CHAIN` 断言同步适配新增的 `pair=` 字段，并新增「源 != 目标」自译防护。

### 16.3 验证数据

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**168/168**（原 149 + `selection-language` 19 项） |
| 语言解析覆盖 | 49 组文本×语言对组合均不自译；中文/日文/韩文/泰文/阿拉伯/西里尔判定正确；长英文夹单汉字不误判 |
| 确定性自测 | 中文 `zh→en` → `Implants usually do not wear out over time.`；英文 `en→zh` → `你好，很高兴见到你。`；日文 `ja→zh` → `你好，今天天气很好。` |
| 真机中文划词 | 浮窗显示「中 → 英」，译文 `Implants generally do not wear out over time. The main reason …`，按钮完整无截断；SQLite 写入 `source_lang=zh / target_lang=en` |
| 发布链路 | verify READY（461,860,800 B / v3 / 354 tensors / M3 Pro）、真译一致、tick max 21.23 ms / avg 10.28 ms |
| 产物 | v0.7.2 build 8、`.app` 5.1 MB、DMG 2.5 MB |
| 截图 | `Reports/ui-v072-{selection-cn,settings,translate}.png` |

设置页真机核对：「翻译偏好」只剩「译文长度 / 划词翻译」两行，**无「操作提示音 / 操作静音」字样**；
左上角无版本号、侧栏顺序与无状态徽标均无回归。质量分数基线
（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）未重跑也未改动。

### 16.4 如实边界

- 拉丁语系（en/fr/de/es/pt/it/vi/id…）**无法仅凭 Unicode 可靠区分**，沿用主窗口源语言设置；
  需要固定方向时仍须在主窗口切换，浮窗会显示实际语言对供确认。
- 「源语言自动判定」只影响划词请求；主窗口翻译、CLI 评测、1260 全方向报告不受影响。
- 辅助功能授权由用户在系统设置中授予；未授权时代码只能给出引导，无法绕过 TCC。
  划词仍依赖 `AXIsProcessTrusted` / CGEvent 合成 ⌘C，授权前不可用。
- 从 DMG 挂载卷运行的实例与 `/Applications` 安装实例可能各自需要一次授权；
  重新签名/换路径后 macOS 可能要求重新授权，本版本已让该状态在界面可见。
- 保存面板 GUI 点击、托盘下拉菜单真实鼠标点击仍未做像素级自动化；上线阻塞项
  （Developer ID 签名 + Apple 公证、440 MB 模型分发、Documents 下 TCC）不变。
- STQ1_0 始终标 1.3125 bpw，NOT LUT4 / NOT affine INT4。

## 17. 划词弹窗「原文不是当前实际选区」修复（2026-11-22 10:0x，v0.7.3 build 9）

### 17.1 复现与根因

用户反馈 v0.7.2 划词弹窗显示的原文不是实际选中的文字。用 TextEdit 的 A / B 两段
明确标记文本 + 隔离 SQLite 数据库复现，落库 `source_text` 出现：
`dog`（A 句末单词）、`物通常不会`（B 少首字）、`over`（旧窗口的词）、
`brown fox jumps over the lazy dog. ALPHA_MARKER_1`（A 缺开头）、
`Hugging Face's logo …`（完全无关的浏览器网页全文）、
`Sparse Ternary Quantization` / `Structured Data`（其它应用的剪贴板残留）。
`HYMN_SELECTION_DEBUG=1` 日志证明 **AX 路径每次都读到正确全文**，错内容全部来自
剪贴板回退被无关 mouseUp 触发。完整证据 `Reports/selection-exact-text-evidence.json`。

| 根因 | 说明 |
|---|---|
| 并发捕获 | 每次 mouseUp 各起一个任务，多个 `captureViaClipboard` 同时模拟 ⌘C / 改写 / 恢复剪贴板，把彼此的 restore 当成新选区 |
| AX 焦点错误 | 用 `AXUIElementCreateSystemWide()` 的「系统键盘焦点」，跨窗口时读到旧窗口选区 |
| 误触发 | 任意 mouseUp（单击、切窗口、拖滚动条、系统事件）都发起捕获；剪贴板回退把别的窗口遗留内容当成当前选区 |
| 坐标漂移 | 手势位置在 MainActor 异步 Task 里用 `NSEvent.mouseLocation` 读取，连串事件读到同一「当前」位置，单击被误判成拖拽 |
| 无结果校验 | 选区动画中只读一次 AX；旧请求晚完成、用户切走应用时结果仍被采用 |

### 17.2 修复内容

- 新增 `Sources/HymnCore/Selection/SelectionCapturePolicy.swift`（纯计算）：
  选区连续两次采样一致才采用；`token` 与前台应用 PID 双重校验；剪贴板假阳性过滤；
  手势判定（必须真有 `leftMouseDragged` 且位移 ≥ 6 pt，或双击选词）。
- `SelectionWatcher` 改为**严格串行调度**：`pending` 只保留最新请求 + 单一 busy 槽位
  + 3 秒硬超时看门狗，任意时刻只有一个捕获在读写剪贴板；普通单击不再捕获。
- 事件位置改用 `event.cgEvent?.location` 在派发前同步读取，`anchor` 仍用 AppKit
  坐标供浮窗定位，消除异步位置漂移。
- `SelectionCapture` 改用 `AXUIElementCreateApplication(前台 PID)` 读
  `kAXSelectedTextAttribute`，AX 双读稳定才采用；模拟 ⌘C 的按键之间加 15 ms 间隔。
- 剪贴板回退前检查 `kAXSelectedTextRange`：明确为空则直接放弃；回退要求内容
  不同于原剪贴板且双读稳定；超时或校验失败一律返回 nil，**宁可不弹也不弹错**。
- 新增 `HYMN_SELECTION_DEBUG=1` 诊断输出（捕获来源 / PID / 文本前缀），默认关闭。

### 17.3 验证数据

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**196/196**（新增 `selection-capture-policy` 27 项） |
| 空转 37 秒 | `capture start` **0 次**、隔离库 **0 条**记录 → 单击/系统事件不再误捕获 |
| 拖拽但无选区 | **0 条**记录，不弹窗 |
| 案例 A | AX 实际选区 = 捕获原文 = `The quick brown fox jumps over the lazy dog. ALPHA_MARKER_1111.`，`en→zh`，仅 1 条 |
| 案例 B | AX 实际选区 = 捕获原文 = `植入物通常不会随着时间而磨损。BETA_MARKER_2222。`，`zh→en`，仅 1 条；**无 A 残留、无碎片** |
| 两次合计 | **2 条**记录（修复前同样操作会产生 6–10 条混杂记录） |
| 浮窗截图 | `Reports/ui-v073-selection-exact.png`：`中 → 英`、完整中文原文、完整英文译文、按钮齐全 |
| 发布链路 | verify READY、真译「你好，很高兴见到你。」、划词链路一致、tick max 23.88 ms / avg 10.15 ms |
| 产物 | v0.7.3 build 9、`.app` 5.1 MB、DMG 2.5 MB |

### 17.4 如实边界

- 拉丁语系仍无法凭 Unicode 细分（沿用 v0.7.2 的语言对解析）；**选区恰好等于
  剪贴板原内容时，剪贴板回退会主动放弃**（宁可不弹也不弹错的保守取舍）。
- Electron / 网页应用若不暴露 AX 选区信息，仍依赖模拟 ⌘C；手势过滤已把误触发
  降到最低，但 TCC 授权不可绕过。双击 / 三击选词走 `doubleClick` 判定，未做像素级
  手势自动化覆盖所有应用。
- 只改划词捕获链路；主窗口翻译、CLI 评测、1260 全方向与质量分数基线
  （BLEU 23.19 / chrF2 43.86 / COMET 0.7809）未重跑也未改动。
- 上线阻塞项不变；STQ1_0 始终标 1.3125 bpw，NOT LUT4 / NOT affine INT4。






## 18. 划词「完全不弹窗」+ 侧栏热区 + 语言栏对齐（2026-11-22 10:4x，v0.7.4 build 10）

用户反馈「这次又是没有出现划词弹窗」，并要求两处 UI 调整：侧栏 5 个按钮改成
**整块圆角矩形可点击激活**（此前只有文字/图标像素响应）、「翻译」页的「源语言 /
目标语言」标签与下拉菜单**同一行**且中间切换按钮**与下拉菜单等高**。

### 18.1 划词弹窗：三条真实成因 + 一条防御性补强

| # | 成因 | 证据 | 修复 |
|---|---|---|---|
| 1 | `SelectionWatcher.finish` 里「2 秒内相同文本不重复弹」把用户反复划同一词/同一句的第二次起全部吞掉，表现为「怎么划都不弹」 | 0.7.4 真机：同一段 `uick brown fox jumps over the lazy dog. ALPHA` 间隔 3 s 划两次，**两次都 `accepted source=ax`** | 彻底移除文本去重；串行调度已保证一个手势只有一个结果 |
| 2 | 剪贴板回退过保守：① 要求新内容必须不同于原剪贴板（选区恰好等于剪贴板内容、或反复划同一词即放弃）；② AX `kAXSelectedTextRange.length==0` 直接放弃，而网页/Electron 的 AX 焦点元素常误报空选区 | 0.7.3 报告 17.4 明写「选区恰好等于剪贴板原内容时会主动放弃」 | 改「哨兵剪贴板」：先清空并记录 `changeCount`，之后变化只可能来自本次 ⌘C；由 changeCount + 双读稳定 + 前台 PID 承担防误触，不再与旧内容比较；AX 空选区只记日志不再拦截 |
| 3 | 只装 `addGlobalMonitorForEvents`，用户在**智译星自己窗口**里划词毫无反应（global monitor 不接收本 App 事件） | 0.7.4 日志多次出现 `gesture accepted local=true` 且 AX 成功取到文本 | 同时装 local monitor；`shouldIgnoreLocalWindow` 过滤浮窗自身事件（否则点「复制译文」会被当划词）；浮窗按钮点击不受 `onOutsideClick` 影响 |
| 4 | 防御性：无辅助功能授权时全局监听**静默不投递**，旧版只在「捕获失败」后提示授权，而捕获根本不会开始 | 本次真机 `trusted=true`，**未复现授权失效**；但 0.7.1 曾从 DMG 挂载卷运行、每次 ad-hoc 重签都可能使 TCC 失效 | 启动时主动申请一次授权；`refreshAuthorization()` 在应用激活 + 4 s 定时轮询中检测变化并重装监听；未授权时设置页仍显示授权按钮 |

配套：`ClipboardSnapshot` 在清空前保存**所有**剪贴板类型的数据并原样恢复，
避免划词一次就丢掉用户复制的图片/富文本；`HYMN_SELECTION_DEBUG=1` 补齐
手势被忽略、哨兵回退、超时、token/PID 拒绝等原因日志。
另加手势级去重（0.5 s 内、终点相差 < 14 pt、且两次都已通过手势判定才拦第二次），
用于挡住部分应用/合成事件补发的重复拖拽；**不拦用户手工反复划词、也不拦双击选词**。

### 18.2 UI 两项

- `RootView.swift` 侧栏：去掉左侧 3 pt 小竖条，激活态改为整块
  `RoundedRectangle(cornerRadius: 9)` 填充 `accentColor.opacity(0.18)` + 同色描边；
  在 `background/overlay` 之后加 `.contentShape(RoundedRectangle(cornerRadius: 9))`，
  把 padding 与 `Spacer` 撑开的透明区域一并声明为点击热区（此前 `.buttonStyle(.plain)`
  只响应文字/图标像素）。
- `UIComponents.swift` `LanguagePicker` 由 `VStack` 改 `HStack`，标签与下拉菜单同行；
  新增共享 `LanguageBarMetrics.controlHeight = 30`，下拉与中间交换按钮统一
  `.controlSize(.large)` + `.frame(height:)`，严格等高。

### 18.3 验证（v0.7.4 build 10）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**200/200**（新增 4 项哨兵剪贴板策略测试） |
| 发布链路 | `make-release.sh` 全绿：verify READY（461,860,800 B / 354 tensors / M3 Pro / 离线）、真译「你好，很高兴见到你。」、划词链路一致、tick max 21.98 ms / avg 10.13 ms |
| 侧栏热区 | 合成点击 `窗口内 (150, 133)`（按钮右侧空白、远离文字与图标）成功从「设置」切到「术语库」；截图 `Reports/ui-v074-sidebar-full-hit.png` 显示整块圆角矩形高亮 |
| 语言栏 | `Reports/ui-v074-translate.png`：「源语言 英文 (en)」「目标语言 简体中文 (zh)」标签与下拉同行，中间 ⇄ 按钮与两侧下拉上下边缘齐平 |
| 浮窗可见 | `Reports/ui-v074-selection-popup.png`：原文 `k brown fox jumps over the lazy dog. ALPHA`、语言对「英 → 中」、真实译文「棕色狐狸跳过了懒狗。阿尔法」、底部「复制译文 / 存为 txt / 存为 docx」齐全 |
| 反复划同一段 | 间隔 3 s 两次相同拖拽各产生 1 条 `accepted`，**第二次未被去重吞掉** |
| AX 完整文本 | 捕获到完整 B `植入物通常不会随着时间而磨损。BETA_MARKER_2222。` 与完整 A 前缀 |
| 哨兵剪贴板 | 0.7.4 首轮真机（WorkBuddy 窗口，AX 不稳定）端到端成功：`clipboard stable ... text=现在启动真机 App 做 UI 与划词验证。`；最终轮 TextEdit 全走 AX 路径，哨兵仅出现「无选区时正确超时放弃」 |
| 产物 | v0.7.4 build 10、`.app` 5.2 MB、`dist/LinguaNova-0.7.4.dmg` 2.5 MB |

### 18.4 如实边界

- 本次真机 `trusted=true`，**授权失效不是本次复现到的根因**，第 4 项是防御性补强；
  用户换构建/换路径后若系统要求重新授权，需在「系统设置 → 隐私与安全性 → 辅助功能」
  重新勾选，App 会自动重装监听。
- 合成 CGEvent 拖拽在 TextEdit 上仍会偶发「一次脚本拖拽 → 两组手势」并读到半截选区
  （本轮日志 6 条 accepted 中有 2 条是片段）。这是测试工具的合成事件噪声，
  真实鼠标单次拖拽不产生该序列；已加的手势级去重在本轮 `hit=0`（两次事件间隔 > 0.5 s），
  **未宣称完全消除**。上次 17.3 的 A/B 各 1 条记录口径不变。
- 无选区、⌘C 未生效时仍按「宁可不弹也不弹错」放弃；哨兵清空剪贴板后会完整恢复，
  但目标 App 若在本次 ⌘C 时另有写入，仍可能读到该内容。
- 只改划词捕获链路与两处 UI；主窗口翻译、CLI 评测、1260 全方向与质量分数基线
  （BLEU 23.19 / chrF2 43.86 / COMET 0.7809）未重跑也未改动；
  STQ1_0 全程标 1.3125 bpw 常驻 GEMV，NOT LUT4 / NOT affine INT4。

## 19. v0.7.5：撤销哨兵剪贴板回归 + 关于窗口层级 + 文案（2026-11-22 11:0x–11:2x，build 11）

用户反馈四点：①「关于智译星」弹窗落在其它窗口下面；② 左下角「划词即译」
改成「划词即译，长PDF翻译」；③ **直接划词不弹窗、只有自己按 ⌘C 才弹，
并且 ⌘V 粘贴功能混乱**；④ **反复弹「隐私与安全性」授权提示，但权限已经打开**。

### 19.1 先认账：③④ 是上一节 v0.7.4 引入的回归

| 现象 | 真正根因 |
|---|---|
| 直接划词不弹窗 | `SelectionCapture.attemptAX` 写成 `accessibilityTrusted ? selectedTextViaAX(...) : ""`。`AXIsProcessTrusted()` 在 TCC 记录指向旧路径副本 / App 未重启时会**误报 false**，于是整条 AX 路径被跳过，只剩剪贴板兜底 |
| 只有 ⌘C 才弹 | v0.7.4 的「哨兵剪贴板」先 `clearContents()` 再模拟 ⌘C；模拟按键在授权未生效时无效，changeCount 不变，用户**自己按 ⌘C** 成了唯一能让 changeCount 变化的途径 |
| ⌘V 混乱 | 哨兵把用户剪贴板清空近 1 秒（AX 采样 180+180 ms + 轮询 900 ms），期间的 ⌘V 粘贴到空内容；`ClipboardSnapshot` 恢复又改写 changeCount / 所有类型 |
| 反复弹授权框 | v0.7.4 新增的「启动时主动申请 + 捕获失败即提示 + 授权状态变化重装监听」会反复调用 `AXIsProcessTrustedWithOptions`，该 API **每次调用都会弹系统引导**，即使已授权 |

**结论**：`AXIsProcessTrusted()` 的布尔值不能当作「能否读 AX」的开关，更不能据此
反复弹系统框；划词链路**绝不能改写用户剪贴板**。

### 19.2 修复

- `SelectionCapture.swift` 重写：
  - **剪贴板全程只读**：`observeClipboard` 只记录 `changeCount` 并轮询，
    不 `clearContents`、不模拟 ⌘C、不恢复剪贴板；用户在划词后自行 ⌘C 仍可触发
    （正式化为无副作用兜底），超时则 `pasteboard left untouched`。
  - **AX 无条件尝试**：删掉 `accessibilityTrusted ?` 门槛；权限真不足时
    `AXUIElementCopyAttributeValue` 自己会返回失败，无需预判。
  - **增强 AX 读取**：焦点元素之外沿父链向上 3 层、再看直接子节点（前 12 个），
    覆盖 Electron / 网页把 `kAXSelectedTextAttribute` 放在 AXWebArea 容器的情况；
    采样次数 3 → 5。
  - 删除 `ClipboardSnapshot`、`postCopyShortcut`、`axReportsEmptySelection`。
- 授权提示：删除 `SelectionWatcher.onAuthorizationNeeded` 及启动 / 捕获失败两处调用，
  删除 `main.swift` 的自动授权回调与 60 秒节流计时；`promptAccessibility()` 只由
  **用户主动点击**的设置页按钮 / 主菜单「划词翻译 开/关」触发，并加 debug 日志。
  4 秒轮询仅刷新状态与重装监听，不弹任何窗口。
- 设置页：未授权时不再写「授予辅助功能权限」这种暗示用户没开权限的文案，
  改为「若已在系统设置授权仍无反应，请完全退出后重新打开 App；也可点右侧复查。」
  + 按钮「复查授权状态」。
- 关于窗口：弃用 `NSApplication.orderFrontStandardAboutPanel`（托盘态 / App 未激活时
  层级不可控），改 `AppDelegate.showAbout` 自建 `NSWindow`：
  `level = .floating`、`canJoinAllSpaces`、`orderFrontRegardless()` + `makeKeyAndOrderFront`，
  内容用 `UIComponents.swift` 新增的 `AboutView`（图标 / 名称 / 版本 / 隐私说明）。
- `RootView.swift` 左下角文案改「划词即译，长PDF翻译」（系统字体渲染为「长 PDF 翻译」）。
- 诊断开关（默认关闭）：`HYMN_FORCE_UNTRUSTED=1` 强制 `accessibilityTrusted` 返回
  false，用于复现「已授权但 API 误报」现场；`HYMN_SELECTION_DEBUG=1` 记录
  `promptAccessibility invoked` 便于确认没有自动弹框。

### 19.3 验证（v0.7.5 build 11）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**200/200** |
| 发布链路 | `make-release.sh` 全绿：verify READY（461,860,800 B / 354 tensors / M3 Pro / 离线）、真译「你好，很高兴见到你。」、划词链路 `pair=en->zh error=none`、tick max 24.92 ms / avg 10.13 ms |
| **直接划词（模拟授权误报）** | `HYMN_FORCE_UNTRUSTED=1` 下日志 `ax stable ... accepted source=ax`，浮窗 `layer=3` 出现；**证明不再依赖 trusted 布尔值** |
| **⌘V 不受影响** | 剪贴板预置 `PASTE_SENTINEL_FINAL_075`，划词后立刻与 2 秒后读取均**逐字不变**；日志含 `clipboard observation timeout; pasteboard left untouched` |
| **不再弹权限框** | 全程 `promptAccessibility invoked` 计数 **0**（含启动、划词失败、应用激活、4 秒轮询多轮） |
| 关于窗口 | `Reports/ui-v075-about-topmost.png` 全屏截图显示关于窗口盖在 WorkBuddy / 浏览器之上；`ui-v075-about-window.png` 内容完整无裁切（版本 0.7.5） |
| 左下角文案 | `Reports/ui-v075-main.png`：「划词即译，长 PDF 翻译」单行完整；语言栏同行对齐、侧栏整块圆角高亮保持 |
| 设置页 | `Reports/ui-v075-settings.png`：中性复查文案与按钮，无「已就绪/离线」或模型技术信息 |
| 产物 | v0.7.5 build 11、`.app` 5.2 MB、`dist/LinguaNova-0.7.5.dmg` 2.5 MB |

### 19.4 如实边界

- 本轮用 `HYMN_FORCE_UNTRUSTED=1` **模拟**用户「已授权但 API 误报」；
  未在用户真实 TCC 状态下复现（本机 `AXIsProcessTrusted()` 正常返回 true）。
  AX 路径在模拟条件下仍工作，说明门槛已解除；但 TCC 彻底无权限时
  `AXUIElementCopyAttributeValue` 会失败，此时只能靠用户自行 ⌘C 兜底。
- 只读观察路径真机验证了「AX 不可用时超时且剪贴板 untouched」，
  **未端到端复现「用户手动 ⌘C → 弹窗」的成功案例**（TextEdit 均走 AX 路径）；
  该行为由 changeCount 变化的逻辑保证。
- 关于窗口 `level = .floating` 会一直浮在其它应用窗口之上直到关闭，这是为满足
  「显示在桌面最上层」的取舍；不是模态窗口，不影响主窗口操作。
- 合成 CGEvent 拖拽仍会偶发重复手势 / 半截选区（本轮手势级去重命中 1 次），
  真实鼠标单次拖拽不产生该序列。质量基线 BLEU 23.19 / chrF2 43.86 /
  COMET 0.7809 未重跑也未改动；STQ1_0 1.3125 bpw，NOT LUT4 / NOT affine INT4。

## 20. v0.7.6：恢复模拟 ⌘C（不清空剪贴板）+ 新品牌图标（2026-11-22 11:28–11:4x，build 12）

用户两点：①「直接划词无法弹窗，只有 command+C 才出现弹窗」；② 用提供的
`Blue Gradient LN Monogram Icon` 替换 App 的 logo。

### 20.1 为什么 v0.7.5 的「只读观察」不够

v0.7.5 为了保证 ⌘V 不被破坏，把剪贴板路径改成完全只读 —— 这在权限正常时没问题，
但一旦 AX 读不到选区（网页 / 部分 Electron / 授权未生效），就只剩「用户自己按 ⌘C」
能触发，正是用户看到的现象。**只读观察不能替代自动复制**。

### 20.2 本轮做法：模拟 ⌘C，但绝不清空剪贴板

`SelectionCapture.captureViaClipboard` 重写为三段时间窗：

| 时间 | 行为 |
|---|---|
| t=0 | 记录 `changeCount` 与剪贴板**完整快照**（所有类型），然后发模拟 ⌘C；**不 clearContents、不写数据** |
| 0–450 ms 内出现新内容 | 判定为模拟按键生效：采用文本，并**恢复原剪贴板**（⌘V 仍粘用户自己复制的内容），诊断 `simulated-copy` |
| 450 ms–1.2 s 内出现新内容 | 判定为用户自己按的 ⌘C：采用文本，**不恢复**（剪贴板归用户），诊断 `user-copy` |
| 1.2 s 仍无变化 | 放弃，剪贴板从未被本进程改动；诊断 `no-selection` |

另加诊断分流：
- `selectedTextViaAX` 现在返回 `(text, disabled)`，按 `AXError.apiDisabled` 区分
  **权限未生效**（`ax-disabled`）与**应用不暴露选区**（`ax-empty`）；
- 设置页在 `ax-disabled` 时显示橙色说明 + 「打开辅助功能设置」按钮 + **当前 App 完整路径**，
  方便用户把系统设置里重复的旧条目删掉、只保留正在运行的这个；
- 新增诊断开关 `HYMN_SKIP_AX=1`（默认关闭）强制走剪贴板路径，便于验证模拟复制。

**必须如实说明的根因**：用户环境里模拟 ⌘C 与 AX 读取同时失效，最可能是
**辅助功能授权没有对当前构建生效**——项目只有 ad-hoc 签名（`security find-identity`
返回 0 valid identities），每次重新构建 cdhash 都会变，TCC 记录随之失效；
系统设置里还容易留下多个同名旧条目。这是 macOS 的签名机制限制，不是代码能绕过的。

### 20.3 品牌图标

- 新增 `Assets/logo-source.png`（用户提供的 1254×1254 素材）与
  `Scripts/make-icon-from-image.swift`：从四角洪泛填充把白底置为透明（白色字母因被
  蓝色隔断不受影响）、两轮收边清掉抗锯齿白点、等比缩放到 1024 画布（内容占 92%），
  导出 10 个尺寸后 `iconutil` 打包。
- `Scripts/make-icon.sh` 优先使用 `logo-source.png`，缺失时回退到原代码绘制。
- `make-app.sh` 增加 `touch` + `lsregister -f`：同一路径重建时刷新
  IconServices / LaunchServices 缓存（此前 Finder 一直显示旧图标）。
- 新增 `AppIconMark`（读取 `NSApp.applicationIconImage`），侧栏左上角、设置页「关于」卡片、
  关于窗口统一显示同一个 logo，替换原来的紫蓝渐变 + sparkles。

### 20.4 验证（v0.7.6 build 12）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**200/200** |
| 发布链路 | `make-release.sh` 全绿：verify READY、真译「你好，很高兴见到你。」、划词链路 `en->zh error=none`、tick max 19.53 ms / avg 10.14 ms |
| AX 路径直接划词 | TextEdit 拖拽未按 ⌘C：`ax stable ... accepted source=ax`，浮窗 `layer=3` 出现，剪贴板保持 `PASTE_SENTINEL_076` |
| **模拟 ⌘C 生效** | `HYMN_SKIP_AX=1` 强制剪贴板路径：日志 `simulated ⌘C ok, clipboard restored; text=uick brown fox ...`，浮窗出现，**不按 ⌘C 也弹窗** |
| **⌘V 不被破坏** | 同一轮预置 `PASTE_SENTINEL_076B`，划词后 0.4 s 与 2.4 s 读取均逐字不变（模拟复制后已恢复） |
| 图标文件 | `dist/LinguaNova.app/Contents/Resources/LinguaNova.icns` 与 `Assets/LinguaNova.icns` md5 一致；`CFBundleIconFile=LinguaNova` |
| Finder 图标 | `dist` 目录与 `/tmp` 新路径副本均显示蓝色 LN 圆角图标（`Reports/ui-v076-finder-icon.png`） |
| 界面图标 | 主窗口左上角、关于窗口均为新 logo（`ui-v076-main.png`、`ui-v076-about.png`），版本 0.7.6 |
| 产物 | v0.7.6 build 12、`.app` 5.3 MB、`dist/LinguaNova-0.7.6.dmg` 2.5 MB |

### 20.5 用户侧必须做的一步（否则仍可能只有 ⌘C 有效）

1. 完全退出所有正在运行的智译星（包括托盘里的）；
2. 把新 `LinguaNova.app` 放到 `/Applications`，**只保留一份**；
3. 打开「系统设置 → 隐私与安全性 → 辅助功能」，**删除列表里所有旧的「智译星」条目**，
   再点 `+` 添加 `/Applications/LinguaNova.app`；
4. 完全退出并重新打开 App。设置页若仍出现橙色提示，会直接显示当前 App 路径，
   对照删除旧条目即可。

### 20.6 如实边界

- 项目无代码签名证书，**每次重新构建 ad-hoc 签名后都可能需要重新授权**；
  这是 TCC 的签名匹配机制，非代码缺陷。要彻底消除，需要 Developer ID 证书。
- 本轮用 `HYMN_SKIP_AX=1` 验证模拟复制，验证时本机辅助功能是有效的；
  **无法在用户真实授权失效的环境下复现并验证**，只能通过设置页诊断 + 上述步骤排查。
- 模拟 ⌘C 生效时剪贴板会被选区内容覆盖约 100–200 ms，随后恢复；
  若用户恰好在该窗口内按 ⌘V，仍可能粘贴到选区文本（概率极低）。
- 图标缓存需要重启 Finder 才彻底刷新；本轮通过 `lsregister -f` 已让 `dist` 目录即时更新，
  但其他已缓存的旧路径可能需要重新登录。
- 质量基线 BLEU 23.19 / chrF2 43.86 / COMET 0.7809 未重跑也未改动；
  STQ1_0 1.3125 bpw，NOT LUT4 / NOT affine INT4。

## 21. v0.7.7：菜单栏 / 划词浮窗 / 状态栏图标统一为 LN（2026-11-22 11:52–11:5x，build 13）

用户要求把菜单栏托盘与划词浮窗里的图标也换成新 logo。

### 21.1 改动

- `TrayController.brandStatusImage()`：直接用 `NSApp.applicationIconImage` 按 18 pt 绘制
  菜单栏图标（`isTemplate = false`，保留品牌彩色），图标缺失时才回退到 `sparkles` 符号。
- `TrayController.about` 改走 `onAbout` → `AppDelegate.showAbout`：托盘菜单里的「关于」
  此前仍调用系统标准面板，层级会掉到其它窗口下面，本轮一并修正。
- `SelectionPopupView` 标题前的 `sparkles` 换成 `AppIconMark(size: 16)`。
- `RootView` 底部状态栏与左下角卡片的 `sparkles` 换成 `AppIconMark(size: 12 / 13)`。
- 至此 Dock、Finder、菜单栏、侧栏、关于卡片、关于窗口、划词浮窗、状态栏全部是同一张
  `LinguaNova.icns`（`AppIconMark` 读取 App 真实图标，缺失时回退渐变符号）。

### 21.2 验证（v0.7.7 build 13）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**200/200** |
| 发布链路 | `make-release.sh` 全绿；verify READY；真译「你好，很高兴见到你。」；tick max 29.88 ms / avg 10.39 ms |
| 菜单栏 | `Reports/ui-v077-menubar-icon.png`：蓝色圆角 LN 小图标位于菜单栏右侧，可辨识、与相邻图标间距正常 |
| 划词浮窗 | `Reports/ui-v077-popup-icon.png`：标题「智译星」前为 LN 图标，16 pt 与标题协调、无裁切；原文/译文/按钮正常 |
| 主窗口 | `Reports/ui-v077-main-icons.png`：左上角、左下角卡片、底部状态栏三处均为同一 LN 图标 |
| 剪贴板 | 本轮划词仍 `accepted source=ax`，剪贴板哨兵 `PASTE_SENTINEL_077` 不变 |
| 产物 | v0.7.7 build 13、`.app` 5.3 MB、`dist/LinguaNova-0.7.7.dmg` 2.5 MB |

### 21.3 如实边界

- 菜单栏图标 18 pt 是 macOS 标准尺寸，但彩色方块（内容留 8% 边距）视觉上比相邻的
  线条符号略小一圈；保持标准尺寸未放大，避免挤压菜单栏。
- 又一次重新构建 = ad-hoc 重签，**辅助功能授权可能再次失效**；用户升级后若划词无反应，
  按第 20.5 节清理旧条目并只保留 `/Applications/LinguaNova.app` 再授权一次。
- 未重跑质量基线（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）；STQ1_0 1.3125 bpw，
  NOT LUT4 / NOT affine INT4。

## 22. v0.7.8：App + 模型合一安装包（2026-11-22 12:0x–12:1x，build 14）

用户问「DMG 拿到其他 Mac 能直接用吗」，核实后发现四道门槛（模型不在包内、Gatekeeper
拦截、仅 arm64/14+、辅助功能需重新授权），随后要求**把模型放进 Contents/Resources/
做合一安装包**。

### 22.1 改动

| 文件 | 改动 |
|---|---|
| `Scripts/make-app.sh` | 默认 `HYMN_EMBED_MODEL=1`：把 `Models/Hy-MT2-1.8B-1.25Bit-GGUF` 用 `cp -cR`（APFS clonefile，秒级、写时复制）拷进 `Contents/Resources/Models/`，**在 codesign 之前**执行，否则资源封印不含这些文件、签名失效；`HYMN_EMBED_MODEL=0` 仍可产出 5 MB 轻量包 |
| `Sources/HymnSTQ/SherryBackend.swift` | `locateSherryModelDirectory()` 新增第 3 优先级候选：`Bundle.main.resourceURL/Models/Hy-MT2-1.8B-1.25Bit-GGUF`。顺序为 环境变量 > 用户选择 > **包内** > 工作目录 > Application Support |
| `Scripts/make-release.sh` | 新增第 7/8 步「合一包校验」：断言包内 gguf 存在（461,860,800 B），并用 NSArgumentDomain 把 `hymn.modelDirectory` **覆盖成无效路径**后跑真实翻译，只有 `real=true` 且产出译文才通过；输出 `Reports/release-bundle-model.log` |
| 版本 | 0.7.8 build 14 |

设计取舍：**包内优先级低于用户选择**。用户若在设置页显式指向某个目录，仍以他的选择为准；
全新机器没有该偏好时才自动用包内模型，因此不需要任何人工步骤。

### 22.2 验证（v0.7.8 build 14）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**200/200** |
| 组装 | `MODEL_EMBEDDED Contents/Resources/Models/Hy-MT2-1.8B-1.25Bit-GGUF (450M)`，`.app` 455 MB |
| 运行时自检 | verify READY：461,860,800 B / v3 / 354 tensors / M3 Pro / offline=true |
| 常规冒烟 | 真译「你好，很高兴见到你。」，划词链路 `en->zh error=none`，tick max 29.69 ms / avg 10.28 ms |
| **合一包校验** | 偏好覆盖为 `/nonexistent-model-dir` 后仍 `real=true`、译出「你好，很高兴见到你。」→ `BUNDLE_MODEL_OK` |
| **只读卷运行** | 挂载 `dist/LinguaNova-0.7.8.dmg`（只读 UDZO），直接从卷内二进制运行并覆盖偏好：`HYMN_SMOKE_OK ready=true real=true`，说明 mmap 读只读卷无问题 |
| **图形界面** | 同一无效偏好启动，状态栏无「模型未就绪」、翻译按钮可用；点翻译后 0.8 秒产出「你好，很高兴见到你。」，落库 `en->zh`（`Reports/ui-v078-unified-main.png`） |
| 签名 | `codesign --verify --deep --strict` → `valid on disk` / `satisfies its Designated Requirement`；`spctl -a` 仍 `rejected`（无公证，预期） |
| 模型一致性 | 包内 gguf 与 `Models/` 源文件 md5 均为 `9b96b598c36e9ffbfcafedd919b2fd54` |
| 产物 | `.app` 455 MB、`dist/LinguaNova-0.7.8.dmg` **442 MB** |

### 22.3 如实边界

- **Gatekeeper 仍会拦**：ad-hoc 签名 + 未公证，`spctl` 明确 `rejected`。新机器首次打开
  需「右键 → 打开」（macOS 15+ 还要去「隐私与安全性」点「仍要打开」），或
  `xattr -dr com.apple.quarantine /Applications/LinguaNova.app`。合一包解决的是
  「模型要单独拷」，不是「免安装验证」。
- 仍为 **arm64 单架构**、`LSMinimumSystemVersion 14.0`；Intel Mac 不可用，
  macOS 13 及更早不可用。且只在 macOS 27.0.1 + Xcode 27 构建与真机验证过，
  **未在 macOS 14/15 实机跑过**。
- 划词即译仍需在新机器上手动授予「辅助功能」；每次重新构建 ad-hoc 重签都可能使
  TCC 授权失效（第 20.5 节步骤仍适用）。
- DMG 从 2.5 MB 变 442 MB，gguf 已 1.25bit 量化、压缩率有限；每次 `make-app.sh`
  都会重拷 450 MB，靠 APFS clonefile 保持秒级。
- 未重跑质量基线（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）；STQ1_0 1.3125 bpw，
  NOT LUT4 / NOT affine INT4。

## 23. v0.7.9：划词浮窗朗读按钮 + 拉丁语系语言对修正（2026-11-22 16:5x–17:1x，build 15）

用户两点：① 浮窗加一个扬声器按钮，用 `AVSpeechSynthesizer` 朗读译文，位置在「返回主界面」
左边；② 划词翻译非英语内容时仍显示「英 → 中」，要修。

### 23.1 「英→中」的真正成因

`SelectionLanguageResolver.detect` 只按 Unicode 书写系统判定（假名/谚文/汉字/泰/阿/西里尔），
**拉丁字母一律返回 nil**；`resolve` 于是落到 `latinLanguages.contains(preferredSource)` 分支，
把任何拉丁文字都当成主窗口源语言（通常是 `en`）。法语、德语、西班牙语、葡萄牙语、意大利语、
越南语、印尼语因此全部显示「英 → 中」。

更糟的是这不止是标签错误：请求带着错误的源语言进入提示词，模型会把法语当英语处理。
本轮实测复现——同一句法语在错标为 `en` 时被音译成「乌德拉伊斯」（把 *voudrais* 当专名），
标成 `fr` 后正确译为「你好，我想预订一张两人桌位。」

**修复**：拉丁字母语言交给系统 `NLLanguageRecognizer`（离线统计模型，无网络）。
置信度门槛取 **0.45**，依据实测：

| 输入 | 置信度 | 结论 |
|---|---|---|
| 完整句子 fr/de/es/pt/it/vi/id/en | 0.95–1.00 | 采用 |
| `Bonjour` / `Hola amigo` / `Danke schön` | 0.63 / 0.98 / 1.00 | 采用 |
| `OK` / `test` / `Hello` | 0.29 / 0.13 / 0.13 | 拒绝，回落主窗口设置 |
| `a` / `123` / `3.14` | 无输出 | 拒绝 |

只接受「拉丁语系 + `LanguageCatalog` 已收录」的结果，避免出现界面显示不了的语言。
书写系统判定仍然优先（日文假名→ja、汉字→zh 等结果确定，不需要统计模型）。

### 23.2 朗读按钮

- `AppModel` 新增 `isSelectionSpeaking`、`toggleSelectionSpeech()`、`stopSelectionSpeech()`；
  合成器 `AVSpeechSynthesizer` 懒加载复用，音色按**译文目标语言**选（读的是译文）：
  `zh→zh-CN`、`en→en-US`、`ja→ja-JP` …… 找不到精确音色时按语言前缀兜底。
- 状态复位不用 delegate：`stopSpeaking` 的 `didCancel` 是异步的，与紧接着的 `speak`
  有竞态，会让图标在刚开始朗读时就被复位。改为 200 ms 轮询 `synthesizer.isSpeaking`，
  开始后转为 false 即认定播完；未启动给 3 秒宽限。
- 浮窗底部一行改为「复制译文 / 存为 txt / 存为 docx / 🔊 / 窗口图标」，扬声器紧邻
  「打开主窗口」的左侧；`HStack` 间距 6 → 5 保证 320 窄档不挤压。
- 图标语义：空闲 `speaker.wave.2.fill`（灰），朗读中 `speaker.wave.3.fill` + 强调色。
  **不用 `speaker.slash`**——它容易被读成「已静音」，与「点击停止」语义相反。
- 新划词、点 ✕、点浮窗外都会停止朗读。
- 诊断：`HYMN_SELECTION_DEBUG=1` 时输出 `[speech] button tapped / speech start lang=… voice=… chars=… / speech speaking`。

### 23.3 验证（v0.7.9 build 15）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**218/218**（新增 18 项语言识别用例） |
| 发布链路 | `make-release.sh` 全绿：verify READY、真译「你好，很高兴见到你。」、划词 `en->zh error=none`、tick max 25.21 ms / avg 10.28 ms、`BUNDLE_MODEL_OK` |
| 语言标签 | 真机划法语浮窗显示 **法 → 中**（`Reports/ui-v079-popup-fr-pair.png`），译文「我想预订一张双人餐桌」 |
| 多语实测 | `fr→zh`「你好，我想预订一张两人桌位。」、`de→zh`「您好，我想预订一张两人使用的餐桌。」 |
| 朗读 | 辅助功能按下按钮 → `[speech] button tapped` → `speech start lang=zh voice=com.apple.voice.compact.zh-CN.Tingting` → `speech speaking`（真实开始合成） |
| 朗读态图标 | `Reports/ui-v079-popup-speaking.png`：绿色三声波，位于窗口图标左侧 |
| 不自动朗读 | 连续 3 次划词，`accepted` 3 次、`[speech]` **0 次**，历史 3 条均 `fr->zh` |
| 产物 | v0.7.9 build 15、`.app` 455 MB、`dist/LinguaNova-0.7.9.dmg` 442 MB |

### 23.4 如实边界

- **混合语言选区仍可能判错**：一次合成拖拽同时选中法语与德语两行时，识别器按整体判为 `de`，
  法语行被按德语处理（音译）。真实使用中选区通常是单一语言；这是识别模型在混合文本上的固有限制。
- 无法凭书写系统区分同一文字的近亲语言（如西/葡、挪/丹）；本机实测这两组在整句上可分开，
  但极短文本仍可能给出低置信度并回落到主窗口设置。
- 音色依赖系统已安装语音：本机 `zh-CN Tingting` 可用；若目标机器未安装对应语音，会回落到
  系统默认音色（仍可朗读，但发音可能不标准）。未做「语音未安装」的界面提示。
- 朗读是同步合成到系统音频输出，**无法在无音频设备的 CI 环境验证声音本身**；
  本轮只验证到合成器进入 speaking 状态。
- 诊断期曾出现一次「未点击即朗读」，加标记日志后连续多轮（含发布版 3 轮）未复现，
  **未定位到成因，也未宣称已消除**；若再次出现请反馈。
- 未重跑质量基线（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）；STQ1_0 1.3125 bpw，
  NOT LUT4 / NOT affine INT4。

## 24. v0.7.10：「复制/存为」改成等大图标 + 新增备忘录与提醒事项（2026-11-22 17:5x–18:0x，build 16）

用户要求：浮窗底部「复制译文 / 存为txt / 存为docx」三个按钮做到与朗读按钮同尺寸，
再加入「备忘录」「提醒事项」，底排一共 7 个按钮。

### 24.1 底排按钮

| # | 按钮 | 图标 | 动作 |
|---|---|---|---|
| 1 | 复制译文 | `doc.on.doc` | 写入剪贴板 |
| 2 | 存为 TXT | `doc.plaintext` | 系统保存面板 |
| 3 | 存为 DOCX | `doc.richtext` | 系统保存面板 |
| 4 | 存入备忘录 | `note.text` | AppleScript 新建备忘录 |
| 5 | 加入提醒事项 | `checklist` | AppleScript 新建提醒 |
| 6 | 朗读 / 停止 | `speaker.wave.2.fill` → `wave.3.fill` | AVSpeechSynthesizer |
| 7 | 在主窗口打开 | `macwindow` | 跳主窗口 |

实现要点：统一用 `footerIcon(_:_:enabled:tint:action:)` 生成——纯图标 + `frame(maxWidth: .infinity)`
+ `contentShape(Rectangle())`，7 个单元格等分 292 pt 内容宽（每格约 41 pt，图标 12 pt）。
含义靠 `.help` tooltip 说明。窄档 320 时不再有文字被挤压的风险（此前 5 个按钮里 3 个是含文字的）。

### 24.2 备忘录 / 提醒事项

这两个 App 没有进程内 API，只能走 AppleScript（`NSAppleScript`）：

- 文本组装与转义抽到 `HymnCore/Compatibility/SelectionShareFormat.swift`（纯计算，可测）：
  - 备忘录正文 `htmlBody`：按行包 `<div>`（Notes 的 `body` 是 HTML，纯文本会把换行吃掉），
    含「原文（语言对）」「译文」两个小标题，并转义 `& < >`；
  - 提醒事项正文 `plainBody`：纯文本保留换行；
  - 标题 `title(from:limit:)`：取译文首行，超长截断加省略号，空译文返回空串；
  - `appleScriptLiteral`：转义反斜杠/双引号，换行压成空格（标题必须单行）。
- 正文一律写临时文件，脚本用 `read POSIX file … as «class utf8»` 读取，
  **不把用户文本拼进脚本源码**；只有标题走字面量转义。
- 执行前先 `compileAndReturnError`：语法错误直接报错，不用等执行失败。
- 错误码 `-1743/-1744/-10004` 统一映射为「需授权」，在浮窗语言标签位置显示
  「需授权「自动化」」2.2 秒；成功则显示「已存入备忘录 / 已加入提醒事项」。
  提示复用语言对的胶囊位置，不额外占浮窗高度。

### 24.3 验证（v0.7.10 build 16）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**230/230**（新增 12 项 `selection-share` 用例） |
| 发布链路 | `make-release.sh` 全绿：verify READY、真译、划词 `en->zh error=none`、`BUNDLE_MODEL_OK` |
| 底排 7 按钮 | `Reports/ui-v0710-popup-7buttons.png`：320 窄档等宽排列，无重叠/截断 |
| AppleScript 语法 | Notes 与 Reminders 两段脚本 `compileAndReturnError` 均 `COMPILE_OK`（含引号/反斜杠/换行标题） |
| 失败路径 | 真机按「存入备忘录」→ `[action] notes failed notAuthorized("备忘录")`，浮窗显示「需授权「自动化」」；按「加入提醒事项」同样；2.2 秒后自动恢复「法 → 中」（`ui-v0710-popup-notice.png`） |
| 产物 | v0.7.10 build 16、`.app` 455 MB、`dist/LinguaNova-0.7.10.dmg` 442 MB |

### 24.4 如实边界

- **端到端「备忘录里真的多出一条」未验证**：Apple Events 的「自动化」授权只能由用户在系统弹窗里点
  「好」，无法在无交互环境授予；从终端启动时 TCC 把责任进程算作宿主进程，因此直接返回
  `-10004 权限违规`。正常从访达/应用程序启动时，首次点击会弹出「智译星想要控制备忘录」，
  同意后长期有效。**这一步需要用户自己点一次。**
- 与辅助功能一样，**每次重新构建（ad-hoc 重签）都可能让「自动化」授权失效**，需要重新允许一次。
- 若用户拒绝授权，目前只在浮窗显示一句话，没有「打开系统设置 → 自动化」的跳转按钮（辅助功能有）。
- 提醒事项只写「名称 + 备注」，不设到期时间/列表选择（提醒会进入默认列表）。
- 未重跑质量基线（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）；STQ1_0 1.3125 bpw，
  NOT LUT4 / NOT affine INT4。

## 25. v0.7.11：弃用 Apple Events，改走文件导入与 EventKit + 2 秒悬停提示（2026-11-22 18:1x–18:3x，build 17）

用户两点：① 在「系统设置 → 隐私与安全性 → 自动化」勾选智译星后仍然无效；
② 光标停在 7 个按钮上 2 秒要显示按钮名称。

### 25.1 为什么「勾了还是无效」

先取证，再改：

| 证据 | 结论 |
|---|---|
| `codesign -d -r-` → `designated => cdhash H"922f255d…"` | ad-hoc 签名没有稳定身份，TCC 记录的是**二进制哈希**，每次重新构建都会对不上 |
| Info.plist 缺 `NSAppleEventsUsageDescription` | 发给其它 App 的 Apple Events 缺少用途声明，系统可以拒绝而不弹授权框 |
| `osascript -e 'tell application "Notes" to activate'` → 成功；`get name of first note` / `count notes` / `count reminders` → **全部 -10004 权限违规** | 不是脚本写错：连只读命令都被拒；`activate` 只是启动事件所以能过 |
| `AEDeterminePermissionToAutomateTarget` 对 Notes 返回 `0`（已授权），对 Reminders 返回 `-1744`（待授权），实际发送却仍 `-10004` | 授权状态与事件结果不一致 → 这条路在当前签名方式下不可靠 |

**结论：不再依赖 Apple Events。** 这不是参数问题，是 ad-hoc 签名 + TCC 的系统限制，
继续调参数只会让用户反复去系统设置里点。

### 25.2 两条替代通道

| 目标 | 新实现 | 是否需要权限 | 验证 |
|---|---|---|---|
| 备忘录 | 写临时 `.txt` 到 `~/Library/Caches/HymnTranslate/ShareQueue/`，用 `NSWorkspace.open(_:withApplicationAt:configuration:)` 交给备忘录导入；`activates = false` 不抢焦点；文件首行即标题 | **完全不需要**（LaunchServices 常规打开） | 真机新建成「我想预订一张双人餐桌」，正文含「原文（法文 → 简体中文）/ 译文」，且备忘录留在后台（`Reports/ui-v0711-notes-imported.png`） |
| 提醒事项 | EventKit：`EKEventStore.requestFullAccessToReminders()` → `EKReminder(title:notes:)` 存入默认列表 | 标准「提醒事项」隐私授权（`NSRemindersFullAccessUsageDescription`），**与自动化无关** | 已拒绝时 `authorizationStatus == .denied` 快速失败并提示；授权框未出现时 12 秒兜底提示（本轮环境无法点授权框，见 25.4） |

同时移除：`NSAppleEventsUsageDescription`、`NSAppleScript` 桥接、`SelectionShareFormat.htmlBody`
与 `appleScriptLiteral`（备忘录用纯文本、提醒用 EventKit，都不再需要 HTML/脚本转义）。
`SelectionShareFormat` 只保留 `plainBody` 与 `title`。

失败提示区分到根因，且都控制在一句话内（复用语言对胶囊位置）：
「已存入备忘录」「已加入提醒事项」「需授权「提醒事项」」「备忘录导入失败」。

### 25.3 悬停 2 秒显示名称

不用系统 `.help`（约 3 秒且在这个非激活面板里不一定出现），改为自绘气泡：

- 每格 `.onHover` → 启动 2.0 s `Task`，到点后 `withAnimation` 显示；
- 移出或换格立即取消（旧的计时器 cancel，不会串台）；
- 气泡画在按钮行正上方，**横向跟随被悬停的单元格**，并按估算宽度夹在浮窗内；
- 7 个按钮仍保留 `.accessibilityLabel`，VoiceOver 可读。

验证：第 4 格显示「存入备忘录」（`ui-v0711-hover-tip.png`）；
第 7 格显示「在主窗口打开」且右侧未被窗口裁切（`ui-v0711-hover-tip-edge.png`）。

### 25.4 验证（v0.7.11 build 17）

| 项 | 结果 |
|---|---|
| 构建 / 测试 | `BUILD_OK rc=0` 零警告、**224/224**（移除 6 项随 HTML/AppleScript 死代码一起删掉的用例） |
| 发布链路 | `make-release.sh` 全绿：verify READY、真译、划词 `en->zh error=none`、`BUNDLE_MODEL_OK` |
| Info.plist | 有 `NSRemindersFullAccessUsageDescription`，无 `NSAppleEventsUsageDescription` |
| 备忘录写入 | `[action] notes saved title=我想预订一张双人餐桌`；备忘录列表出现同名条目，正文含原文与译文 |
| 提醒事项失败路径 | `[action] reminder failed notAuthorized("提醒事项")`（本机此前请求被记为拒绝 → 快速失败，不卡 UI） |
| 产物 | v0.7.11 build 17、`.app` 455 MB、`dist/LinguaNova-0.7.11.dmg` 442 MB |

### 25.5 如实边界

- **「提醒事项」写入成功未端到端验证**：EventKit 的授权框需要用户点「允许」，本轮无交互环境里
  弹框未出现（请求挂起），我只能验证到「已拒绝 → 快速失败」和「12 秒兜底提示」两条路径。
  用户首次点击会看到系统的「智译星想要访问提醒事项」，允许后即可写入。
- 备忘录走**文件导入**，条目落在「**导入的备忘录**」文件夹（不是默认文件夹），
  正文为纯文本（不再有加粗小标题），标题取译文首行。这是换取「不需要任何权限」的代价。
- 导入会在 `~/Library/Caches/HymnTranslate/ShareQueue/` 留下 `.txt`，每次写入会清理一天前的旧文件。
- 悬停气泡是估算宽度做边界夹取，极长按钮名可能偏差几像素（当前 7 个都够用）。
- 未重跑质量基线（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）；STQ1_0 1.3125 bpw，
  NOT LUT4 / NOT affine INT4。

## 26. v0.7.12：划词底排按钮可配置 + 4 个网页动作（2026-11-22 18:5x–19:2x，build 18）

### 26.1 需求

1. 设置页能自定义划词浮窗底部的 7 个按钮（显示 / 删除）；
2. 新增「译文 Bing 搜索」「译文 Google 搜索」「译文发送微博」「译文淘宝搜索」；
3. 底排**最多 7 个**。

### 26.2 设计：清单驱动，不再写死

新增 `HymnCore/Selection/SelectionActionCatalog.swift`（纯计算、无 AppKit，可独立测试）：

- `SelectionActionID`（11 个 case）：`copy / txt / docx / notes / reminders / speak / main /
  bing / google / weibo / taobao`，每个带 `title`（悬停气泡 + accessibilityLabel）、
  `symbol`（SF Symbol）、`detail`（设置页一行说明）、`isOnline`、`requiresTranslation`。
- `SelectionActionPreferences`：`maxCount = 7`、`minCount = 1`、`defaultOrder`（= v0.7.11 的 7 个，
  升级不跳变）；`normalized` 做**去重 + 按声明顺序排序 + 截到 7 个**；
  `init(rawValue:)` 忽略未知短码，全部无效时回落出厂值；`toggled(_:)` 越界直接返回原值。
- 顺序恒为枚举声明顺序：增删只改变「哪些在」，不会让已有按钮左右乱跳。

偏好落在 `UserDefaults` 的 `hymn.selection.actions`（逗号分隔短码），
出厂即 `copy,txt,docx,notes,reminders,speak,main`。

### 26.3 浮窗：定宽 7 格 + 整排居中

`SelectionPopupView` 的 `footerButtons` 改成
`model.selectionActions.ordered.compactMap(footerButton(for:))`，每个动作映射到
标题/图标/可用性/回调（网页动作额外 `onClose()` 收起浮窗，否则非激活面板会盖在浏览器上）。

布局按**固定 7 格**算单元格宽度 `(content - 2*6)/7`（320 pt 档约 40 pt），再用
`.frame(maxWidth: .infinity)` 让少于 7 个时整排居中——避免只剩 2 个按钮时被拉成两块巨大热区。
悬停气泡的 x 按「起始 x + 索引 × 格宽」重算，仍然夹在浮窗内。

可用性沿用原语义：存 TXT/DOCX 与「回主窗口」只依赖原文；其余（复制、朗读、备忘录、提醒、
四个网页动作）要求有译文。

### 26.4 设置页：分组开关 + 预览 + 上限提示

`SettingsView` 新增卡片「划词面板按钮」：说明文字、`n/7` 计数胶囊（满 7 变橙）、
「恢复默认」（默认态禁用）、当前组合的图标预览（不足 7 个显示「还可添加 n 个」，满则「已满」）、
「本机操作」7 行与「网页操作」4 行开关。已满 7 个时未选中的行显示「已达上限」并禁用，
整行 0.55 透明度；网页组单独标注「会把译文发送到对应网站」，并补一句
「这几个按钮只在默认浏览器里打开网页，翻译本身仍在本机完成」。

开关用 `Binding(get: { contains(id) }, set: { _ in model.toggleSelectionAction(id) })`，
真实状态始终来自 model；越界时只更新状态栏文案，不动偏好。

### 26.5 网页动作：URLComponents 编码

| 动作 | 地址 |
|---|---|
| Bing | `https://www.bing.com/search?q=<译文>` |
| Google | `https://www.google.com/search?q=<译文>` |
| 淘宝 | `https://s.taobao.com/search?q=<译文>` |
| 微博 | `https://service.weibo.com/share/share.php?title=<译文>` |

- 一律用 `URLComponents + URLQueryItem` 编码。手写
  `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)` 会漏掉 `&` `+` `=` `#`，
  中文译文里一出现就被截断（单元测试用 `C++ & Rust=快 #1` 锁住）。
- 查询串先做「去首尾空白 + 换行/连续空白折叠成一个空格」，再按 1000 字符截断（避免 414）。
- 打开后收起浮窗；状态栏给「已在浏览器打开「…」」。
- **微博额外把译文写进剪贴板**：分享页在未登录浏览器里会先跳 `passport.weibo.com` 登录页，
  `title` 可能丢失，登录后直接粘贴即可；状态栏写明「已复制译文并打开微博」。

### 26.6 验证（v0.7.12 build 18）

| 项 | 结果 |
|---|---|
| 构建 | `BUILD_OK rc=0` **零警告**（顺手清掉 `GGUFTests` 里一处无效 `try`） |
| 测试 | **255/255**（原 224 + 新增 `selection-actions` 31 项） |
| 发布链路 | `make-release.sh` 全绿：verify READY、真译、划词 `en->zh error=none`、`BUNDLE_MODEL_OK` |
| 产物 | `.app` 455 MB（内嵌模型）、`dist/LinguaNova-0.7.12.dmg` **443 MB** |
| 只读卷 | 从挂载的 DMG 直接运行：`real=true`，tick max 20.77 ms / avg 10.28 ms |
| 设置页 7/7 | 网页四行「已达上限」+ 开关禁用（`ui-v0712-settings-full-7.png`） |
| 取消 DOCX → 6/7 | 预览「还可添加 1 个」、网页行解除禁用（`ui-v0712-settings-5-selected.png`） |
| 开启 Bing → 7/7 | 预览末尾出现 `b.circle`，状态栏「已加入「译文 Bing 搜索」」 |
| 恢复默认 | 回到出厂 7 个，`defaults read` = `copy,txt,docx,notes,reminders,speak,main`（`ui-v0712-settings-reset.png`） |
| 浮窗 7 个（自定义） | copy / txt / notes / reminders / speak / main / **bing**（`ui-v0712-popup-custom7.png`） |
| 浮窗 5 个 | copy / bing / google / weibo / taobao，定宽居中、不被拉宽（`ui-v0712-popup-5buttons.png`） |
| 悬停 | 第 7 格 2 秒显示「译文 Bing 搜索」，不越界（`ui-v0712-hover-bing.png`） |
| Bing | Safari `bing.com/search?q=你好`，标题「你好 - Search」（`ui-v0712-bing-search.png`） |
| Google | Safari 标题「你好，不错 - Google 搜索」 |
| 淘宝 | Safari 标题「你好，不错_淘宝搜索」（`ui-v0712-taobao-search.png`） |
| 微博 | 打开分享页 → 未登录跳登录页（`ui-v0712-weibo-share.png`）；`pbpaste` == 译文，状态栏「已复制译文并打开微博」 |

证据汇总：`Reports/v0712-configurable-footer-evidence.json`。

### 26.7 如实边界

- **微博**：`service.weibo.com/share/share.php` 需要浏览器已登录微博；未登录先跳登录页，
  因此补了剪贴板兜底，但「打开分享页后自动填好正文」这一步在未登录状态下无法验证。
- 网页动作会把译文带出本机，属于用户主动点击才发生的行为；翻译本身仍全程离线，
  设置页已单独提示「不想外发就不勾选」。
- 最窄档（320 pt）7 格每格约 40 pt，按钮名靠悬停气泡识别，不做文字标签。
- Google 在部分网络环境不可达；URL 构造与打开行为与 Bing 完全同一条代码路径。
- 未重跑质量基线（BLEU 23.19 / chrF2 43.86 / COMET 0.7809）；STQ1_0 1.3125 bpw，
  NOT LUT4 / NOT affine INT4。

## 27. v0.8.2：跨页控件高度统一 + 翻译页页头图标（2026-11-24 03:4x–03:5x，build 22）

### 27.1 需求

1. PDF 翻译 / 历史记录 / 术语库 / 设置 里的下拉菜单与按钮，高度统一成「翻译」页语言栏的高度；
2. 「翻译」页左上角「翻译」二字前加上与其它四页一致的图标。

### 27.2 做法：一个修饰器 + 复用 PageHeader

- `UIComponents.swift` 新增 `ControlMetrics.height = LanguageBarMetrics.controlHeight`（**30 pt**），
  以及 `View.unifiedControlHeight()`：`controlSize(.large)` + `frame(height: 30)`。
  只靠 `controlSize(.large)` 不够——不同控件族（bordered 按钮 28、roundedBorder 输入框 22、
  menu Picker 24）自然高度不同，必须再钉一个固定 frame，同一行里才会严格齐平。
- `PageHeader` 增加可选 `trailing: AnyView?`；`TranslateView.header` 直接改用 `PageHeader`
  （图标 `character.bubble`，38 pt 渐变圆角 + 白色符号、标题 23 pt），右侧快捷键胶囊作为 `trailing`。
  原来那套 24 pt 标题是第二份实现，跨页切换时标题会跳 1 pt，现在只剩一处定义。

### 27.3 覆盖范围

| 页面 | 统一到 30 pt 的控件 |
|---|---|
| 翻译 | 动作栏「翻译 / 取消 / 复制译文」（语言栏下拉与 ⇄ 本来就是 30） |
| PDF 翻译 | 选择 PDF…、纯译文↔版式重建分段控件、开始翻译/开始重建、取消、保存为 TXT/DOCX、打开译文 PDF、逐段对照报告、在访达中显示、错误条「重新选择」 |
| 历史记录 | 搜索框、刷新、清空全部、全选、取消选择、导出所选为 TXT/DOCX |
| 术语库 | 源术语 / 目标译法输入框、添加 |
| 设置 | 译文长度下拉、选择模型文件夹…、重新检测、复查授权状态、打开辅助功能设置、清空本地数据、恢复默认 |
| 通用 | `ErrorBanner` 的「重新检测」 |

**未动**：历史记录 / 术语库列表行里的图标按钮（导出、载入、删除、删除术语）保持紧凑，
它们是行内附属操作，拉到 30 pt 会把行高撑高、一屏少显示两条；设置页的开关（Toggle）也保持原尺寸。

### 27.4 验证（v0.8.2 build 22）

| 项 | 结果 |
|---|---|
| 构建 | `BUILD_OK` 零警告 |
| 测试 | **439/439**（本次为纯 UI 改动，未增删用例） |
| 版本一致性 | `VERSION_OK 0.8.2`（`AppBrand.fallbackVersion` / `make-app.sh` / `make-release.sh` 三处一致） |
| 发布链路 | 8 步全绿：439/439、字体 SHA 一致、verify READY、真译「你好，很高兴见到你。」、划词 `en->zh error=none`、`BUNDLE_MODEL_OK`、DMG 461 MB |
| 产物 | `.app` 487 MB、`dist/LinguaNova-0.8.2.dmg` 461 MB（483,868,804 B）<br>SHA-256 `0f48b4322b9cba820e5999678de6fc94a786e164821d2811d6fa50f36a02ab4a` |
| 安装 | `/Applications/LinguaNova.app` = 0.8.2 build 22，`codesign --verify --deep --strict` 通过 |
| 界面 | 翻译页页头出现 38 pt 图标；五页控件高度一致，截图 `ui-v082-*.png` |

### 27.5 如实边界

- 分段控件（纯译文 / 版式重建）钉到 30 pt 后，两段文字上下留白比系统默认略宽，属预期；
  它仍是 `.segmented` 原生绘制，没有自绘。
- `roundedBorder` 输入框拉高到 30 pt 后文字仍垂直居中，但光标高度随字号（未放大字号）。
- ad-hoc 每次重签会让 TCC 记录失配：本次安装后设置页显示「复查授权状态」即为此，
  用户需在系统设置里重新勾选辅助功能。

## 28. v0.8.4：栏缝（间隔区）切开——署名/地址不再与标题/正文黏连（2026-11-24，build 24）

### 28.1 需求（用户标注）

`Sample/Biodegradation.pdf` 上：绿色标了「署名」行与「Present address」行，
红色方框标了「间隔区」（用于分隔不同段落）。要求：

1. 署名、地址**不要再和标题、正文翻在一起**；
2. 红框标出的间隔区要当作段落分隔**生效**（不能跨缝拼成一段）。

### 28.2 根因：行先被并成「假行」，分栏判据就永久失效

| 层 | 事实 | 本样本数值 |
|---|---|---|
| ① 行内字距阈值 | `max(1.6em, 12pt)` 判「同一基线两 run 之间是不是词距」 | 正文 10 pt → 阈值 16 pt，而**栏距只有 13.8 pt（1.38 em）** |
| ② 角标落在栏缝里 | 作者名末尾的 `1`（8.4 pt）正好填进缝里，把「名字 → 标题」压到 12.35 pt；阈值按 `max(字号)=21 pt` 算成 33.6 pt，必然并合 | 地址行的 `3` 同理 |
| ③ 分栏判据 | `detectColumns` 找的是「**没有任何一行跨过**的竖缝」 | 假行跨过了 → 这条缝再也找不到 |

③ 是关键：只要有一行跨过栏缝，整页双栏识别就退化成「一栏」，后面按 y 排序、
按行距断段，左右两栏的行自然交错进同一段。所以修在行层面无效，**必须在 run 层先切区域**。

### 28.3 修法

- **`PDFRegionCutter`（新增）**：对一页的 run 做递归 XY 切分。
  竖缝用扫描线求「覆盖数 ≤ 1」的竖条（允许一条页眉/页码跨过），宽度 ≥ 6 pt；
  成立条件：两侧各 ≥ 3 个 run **且各 ≥ 2 条基线**、纵向重叠 ≥ 50%、跨缝 run 必须在带外。
  「≥2 条基线」是分水岭——表格一行、目录一行、`30 cm × 30 cm × 1 cm` 这类行内宽空格
  都只有 1 条基线，不会被当成分栏。横带：整幅无 run 的横条，高 ≥ 12 pt。竖缝优先。
- **`PDFLineBuilder.buildLines`**：先切区域，再逐区域 `makeLines`；
  `mergeInlineFragments` 也只在区域内做（跨区域合并且正是「作者+标题」黏连的来源）。
  另加兜底：只有碎片（去空白 ≤ 4 字）才允许并回本行。
- **排版侧右边界**：`blockLimits` 增加「不得越过同一纵向带里的右边邻居」。
  首页左栏分两截（前部信息窄、正文宽），窄块按正文栏宽扩框会压到右栏的关键词行
  （实测「电子邮件」与「关键词」叠成一团）。同时保底不缩到原框以内。
- **旋转小字钉住**：`isRotatedLabel`（角度非零 + ≤2 行 + ≤80 字）。
  插图右缘竖排的 `Int. Microbiol.`（6 pt）以前被翻成「微生物学」并压在图上。
- **缺字上下标 ASCII 兜底**：`PDFGlyphFallback`。`H₂O` 的 U+2082 思源宋体没有，
  以前直接丢字印成「H O」；现在换成 `H2O`。装饰符号（`⇑`）**不换**，缺字如实报告。
- **把两份「钉子块」条件清单合成一份 `keepsOriginal`**：以前排版循环和翻译阶段各抄一份，
  一旦不同步就会出现「排版时钉住、翻译时照翻」。
- **重排溢出回落原文**：reflow 里放不下时不再丢弃溢出行（静默删字），先用原文重排一遍。
- **R5 基准改成「本次计划要排的文字」**：`H₂O → H2O` 是换写法不是少字，
  以前会误报 `text-truncated`（实测 3 个假阳性，清零后 `codes=[]`）。

### 28.4 结构变化（同一文件、同一份 run）

| 页 | 块（前 → 后） | 行（前 → 后） |
|---|---|---|
| 1 | 48 → **19** | 68 → 81 |
| 2 | 13 → 11 | 50 → 67 |
| 4 | 24 → 13 | 59 → 97 |
| 6 | 21 → 15 | 37 → 57 |
| 8 | 27 → 16 | 64 → 108 |

块数变少、行数变多 = 假行消失（以前一行里塞着左右两栏）。

### 28.5 验证（v0.8.4 build 24）

| 项 | 结果 |
|---|---|
| 构建 | `BUILD_OK` 零警告 |
| 测试 | **478/478**（新增 `pdf-region` 18 项） |
| 发布链路 | 8 步全绿：`VERSION_OK 0.8.4`、字体 SHA、verify READY、真译、划词 `en->zh`、`BUNDLE_MODEL_OK`、DMG 462 MB |
| 本样本（10 页） | `translated=169 kept=257 failed=0`，**`passed=true codes=[]`** |
| 回归样本（6 页） | `translated=132 kept=410 failed=0`，`codes=[glyph-missing=2,text-overlap=1]`（与 v0.8.3 基线一致） |
| 界面 | 作者 9 行独立成块 / 标题独立 / 摘要独立 / 三段单位各自成块 / 关键词独立 / 左右正文分开；通讯作者电话邮件留在左栏 |
| 图边水印 | `Int. Microbiol.` 保持英文原位 |
| 产物 | `.app` 487 MB、`dist/LinguaNova-0.8.4.dmg` 462 MB（483,944,898 B）<br>SHA-256 `8a12065caaf1e7f8844def0a18b596f3870721c8405141b1b8bd95add832d33c` |
| 成品 | `Sample/Biodegradation-修复版.pdf`（1,039,613 B） |
| 截图 | `Reports/pdf-v084-p{1,3,4,5,6}-*.png` |

### 28.6 边界

- 栏距比字距还小（例如 10 pt 栏距 @ 12 pt 字 = 0.8 em）时几何上无法区分「栏缝」与「宽词距」，
  本轮不做。
- 作者名单是一整块，中文重排后 9 个名字连成一段（原来一行一个）；要一行一个需要
  在 P2 输出里加 `type: author`，本轮没做。
- 单行表格、目录点线、行内宽空格靠「≥2 条基线」排除，不做语义判断。
- 第 3 页的无线表仍是「按列钉住、保持原文」，不是重建表格。
- 参考文献仍会被翻译（既有边界）。
- 重排页若连原文都放不下，仍然只能丢弃溢出行并在报告里标 `needsReview`。

## 29. v0.8.5：只有横线的表格 + 整页重排的顺序与兜底（2026-11-24，build 25）

### 29.1 用户标注（`Sample/mycelia strains and sustainable growth.pdf` 第 5 页）

1. 红框：Table 2 里的文字显示不完整、没有换行；
2. 绿框：两段正文没有翻译出来；
3. 用户的判断「表格内译文超出限制，导致绿框文字没翻出来」——正确。

### 29.2 根因链

| 环 | 事实 | 后果 |
|---|---|---|
| ① | Table 2 只画两条通栏横线、零竖线，而网格法要求横竖各 ≥1 条 | 该页识别出 **0 张表** |
| ② | 74 个单元格各自成段（框高 6.3 pt），中文放不下 → 扩框/溢出 | 与邻格叠字（`O-H拉伸O-H stretching`） |
| ③ | 溢出块 ≥2 → 页脚注 → `pageNotes ≥ 2` → **整页重排**，且表格不在 obstacles 里 | 正文被推进表格区域乱流 |
| ④ | `flow` 排不下只计数、不点名、不留原字节 | 831 字的 `Water uptake is an inherent…` 整段消失 |
| ⑤ | 重排页「保留原字节」按算子区间整体保留，而表头 8 格共用一个 TJ | 已翻译格子被复活 → 中英叠字 |

### 29.3 修法

- **`PDFRuledTable`（新增）**：横线配对成「带」（先试最高的，避免把表头切在表外）→
  基线聚类成行（上标并进本行、单碎片行并回邻行）→ 同行相邻 run 间隙 ≥5 pt 的右侧起点作为列首，
  支持度 ≥ `max(3, 行数/5)` 才认 → 否决条件：<3 列、<5 行、跨列 run >8%、
  整句占比 >20%、格内占满率 >85%。实测 p5 = 12×8、p4 = 6×10，其余 7 页 0 表。
- **单元格排版**：竖直内缩 2→1 pt；字号取格内 run 的中位数（新增 `cellFontSize`）；
  `maxRight/DownExpandRatio = 0`（不许扩到邻列/下一行）；译文放不下退原文，
  原文也放不下就整格保持原字节（**绝不画半截**）。
- **驱逐逻辑统一**：删掉「重排页特例」，重排页与普通页共用
  「默认全保留 − 要重画的块/格 + 共用 TJ 的 forcedRuns」，reflow 不再吞字、也不再复活译文。
- **重排顺序**：同栏已放置的块构成天花板，后续块顶边取 `min(原顶边, 最低已放置下沿 − gap)`；
  `Outcome.unplaced` 从计数改成**块 id 名单**，调用方保留原字节并二次重排时把它们当障碍物。
- **缺字兜底**：`PDFGlyphFallback` 增加 30 条「拉丁变音字母 → 基本字母」
  （`ğ→g`、`ş→s`、`İ→I`、`ı→i`、`ł→l`、`ø→o`、`ß→ss`…），只在字体确实没有该字形时生效。

### 29.4 验证（v0.8.5 build 25）

| 项 | 结果 |
|---|---|
| 构建 | `BUILD_OK` 零警告 |
| 测试 | **493/493**（+`pdf-ruled-table` 10、+`pdf-reflow` 3、+缺字 2） |
| 本样本 9 页 | `translated=452 kept=63 failed=0`，**`passed=true codes=[]`** |
| 第 5 页 | `reflow=false blocks=17 plans=16 notes=0 tables=1`；绿框两段 8 行 / 5 行 fit 回原栏位 |
| 第 9 页 | 参考文献顺序单调、`reading-order` 0；土耳其字母正常（原来 `glyph-missing=1`） |
| 产物 | `.app` 487 MB、`dist/LinguaNova-0.8.5.dmg` 462 MB（483,938,702 B）<br>SHA-256 `31c3d4d8548fd5d26799897de70d0830df068ae481a6ff2b38127b10c11f2272` |
| 成品 | `Sample/mycelia strains and sustainable growth-修复版.pdf` |
| 报告 | `Reports/stage-p9-ruled-table-and-reflow-order.md`；截图 `pdf-v084-*-before.png` / `pdf-v085-*.png` |

### 29.5 边界

- 表格仍**不翻译**（沿用既有策略）：6.4 pt 格子、8.6 pt 行高，中文压到 4.5 pt 也放不下一页以上，
  翻出来必然叠字或半截。单元格翻译通道已修好，接模型侧是另一个独立决定。
- 只有横线的表才走推断路径；「三栏文字被横线夹住」靠三条否决条件挡住，但极端版式仍可能误判。
- 合并单元格仍不认识。
- 重排仍只下移、不开新页；排不下的块留在原位并标 `needsReview`。
- 位置保留式排版在中文比英文短的地方会留较大段间距（第 4、5 页可见），不是丢字。
