# HymnTranslate 阶段交付汇总（构建 / 测试 / 性能）

> ## ⚠️ 下方「最新状态」是 2026-11-21 14:2x 的历史快照
>
> 其中「量化 KV cache / batched prefill 仅给方案未实施」「COMET 未交付」
> 「不是 1260 全方向」等边界均已变化：当晚 H1 优化、COMET 真实打分、
> 1260 全方向覆盖、Sampler 请求级可复现已全部实施，并额外修复了 1260 评测
> 暴露的流式译文字符级损坏 bug。**当前状态以
> `Reports/model-migration-plan.md` 第 12 节与 `Reports/h-stage-final-report.md` 为准**；
> 本文保留原貌作历史对照。

生成时间：2026-11-20 23:45 (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`

> ## ✅ 最新状态（2026-11-21 14:2x）：H 阶段后续任务已登记进计划表/进度表
>
> 用户列出四项后续范围（性能优化 / 系统级评测与全语言覆盖 / 持久化与像素级 UI 自动化 /
> v2 GGUF 明确排除），现已写入 **`Reports/model-migration-plan.md` 第 8 节计划表、
> 第 9 节进度表**，详细适配方案与实证证据见 **`Reports/stage-h-roadmap.md`**。
> 本轮实际交付：`BackendPreference`（后端选择重启持久化，双进程冒烟通过）、
> `LanguageCatalog`（模型卡 36 种语言，UI 选择器由 3 项扩为 36 项）、
> 基于公开权威平行语料 OPUS-100 的 BLEU/chrF 离线评测链路（`hymnctl evaluate`）。
> 构建 `rc=0`、测试 **191/191**。**推理计算核心零改动**（仅 `RealModelBackend` 的语言名
> 委托到 `LanguageCatalog`，属提示词层），默认后端仍是 Sherry GGUF。
> 系统级 BLEU 评测（259 条真实译文 / 64 方向）还发现并修复了 1.25bit 后端对 7 种语言的
> 提示词措辞退化（「XX文」→「XX语」），详见 `Reports/stage-h-roadmap.md` 第 9 节。
>
> ⚠️ 如实标注的边界：**量化 KV cache / batched prefill 仅给方案未实施**；
> **COMET 未交付、不伪造分数**（缺 torch 与神经评测模型）；
> **像素级 UI 自动化工具已实现并编译通过，但验证被 TCC 权限阻塞**（辅助功能 + 屏幕录制均未授权，
> 14:50 复检仍 false）；`./Scripts/ui-automation.sh mlx` 授权后一键可跑，不拿编译通过或视图树实例化冒充真实点击；
> **v2 GGUF（type=40）明确排除**（无权威格式定义，不得臆造算子）；
> 语言覆盖是 36 语言以 en 为枢轴的 64 个有参考方向 + 3 个无参考冒烟，**不是 1260 个全方向**。
>
> ## ✅ 前一阶段（2026-11-21 13:3x）：G4 常驻 GEMV + G8 默认后端切换完成
>
> **默认后端已改为 `Hy-MT2-1.8B-1.25Bit.gguf`（Sherry STQ1_0 1.25bit GGUF）**：
> 224 个线性层以 42 B/256 = **1.3125 bpw 常驻**在 `461,860,800 B` MTLBuffer，
> 由原生 Metal GEMV 直接「解码即乘加」，**不再展开 3.58 GB fp16 缓存**；
> Q6_K tied embedding 与 129 个 F32 norm 仍按权威公式处理。
> `SherryBackend.performsRealModelInference = true`，构建 `rc=0`、测试 **164/164**，
> CLI 不带参数与 App 默认均产出真实译文 `你好，很高兴见到你。`。
> 独立 Python / llama.cpp PR #22836 golden：GEMV `maxAbs=7.63e-6`、embedding `0`、
> 32 层 logits `corr=0.999999`、top-20 `20/20`、argmax `28036` 一致。
> **最新完整报告：`Reports/stage-g4-resident-gemv.md`**；计划表/进度表见
> `Reports/model-migration-plan.md`（G0–G8 全部 100%）。
> D-1（`affine INT4 (NOT LUT4)`）与 MLX 仍并列，可显式
> `--backend native|mlx` / App 图形开关选择；各后端权重格式如实标注，
> STQ1_0 永不冒充 LUT4 / affine INT4。
> 本文第 3 节及以下历史快照、口径声明仍是阶段 0–4 的**测试替身**数据，不能当作模型推理性能；
> 下方「D-1 完成」「模型迁移 G1」「阶段 D 过渡版」等状态块均为历史记录，不再代表当前默认后端。

> ## 📌 阶段 D 过渡版更新（2026-11-21 00:10）
>
> 本文是**阶段 0–4 的历史汇总**（当时 57/57 测试）。用户随后选择「过渡」= 路线 D，
> 最新交付以 **`Reports/stage-d-transition.md`** 为准，关键变化：
>
> - 测试从 **57/57** 增至 **72/72 通过**（新增 `native-weights` 15 项，全部针对真实 1 GB 权重）；
> - 真实 `model.safetensors` 已落盘（1,007,776,125 B），新增 `HymnNative` 原生模块与
>   `Golden/` 官方 MLX 校准数据；CPU / Metal / 官方 MLX 反量化三方逐元素 **0 误差**；
> - `hymnctl weights` 为新增 CLI 子命令；`.app` 升级 v0.2.0，标题与标注改为
>   **affine INT4 (NOT LUT4)**；冒烟输出 `HYMN_SMOKE_OK … status=过渡版 D：…`；
> - 性能数据分两个口径：本文第 3 节仍是**测试替身**调度数据，
>   `Reports/native-perf.json` 是**真实权重反量化**数据，两者都不能当作翻译 token/s；
> - **仍未交付完整模型 forward 与真实译文**；MLX Swift 运行时依赖在本机依然不可达
>   （`hunyuan_v1_dense` 架构注册这一项阻塞已由上游解除）。

> ⚠️ **口径声明**：本轮所有性能数据来自显式标注的测试替身后端
> `fixture-v0 (TEST DOUBLE / NOT MODEL INFERENCE)`，度量的是 Swift 原生调度、流式、取消、
> SQLite 与主线程隔离链路的开销，**不包含任何模型推理**，不代表 Hy-MT2 1.8B 的 token/s。
> 真实推理性能须待 MLX Swift 依赖可达、LUT4 权重与算子验证通过后另行测量。

---

## 1. 构建结果

| 项 | 结果 |
|---|---|
| 命令 | `swift build --disable-sandbox`（CommandLineTools 下必须禁用 SwiftPM manifest 沙箱） |
| 退出码 | **0** (`Build complete!`) |
| 工具链 | Swift 6.4 / swift-tools-version 6.0 / macOS 14+ deployment target / arm64 |
| 严格并发 | 全部 target 启用 `.swiftLanguageMode(.v6)` |
| 外部依赖 | **0**（系统 libsqlite3 / AppKit / SwiftUI / Foundation） |
| 产物 | `HymnCore`(lib)、`HymnStore`(lib)、`hymnctl`、`hymntest`、`HymnTranslate`(App) |
| 完整日志 | `Reports/build.log` |

编译修正历程（真实记录，5 次构建）：
1. `AsyncThrowingStream` 的 `init` 要求 `Failure == any Error` → 统一改为 `any Error`；
2. actor 方法 `cancel(id:)` 参数标签缺失 → 修正；
3. 复杂字符串插值触发编译器诊断崩溃 → 拆成局部变量；
4. `stats()` 多语句函数缺 `return`（Swift 6 不再隐式返回）→ 修正；
5. `Thread.isMainThread` 在 async 上下文被禁用 → 改用 `pthread_main_np()`；
6. `utsname.machine` 独占访问冲突 → 预取 `MemoryLayout.size`；
7. **环境问题**：CommandLineTools 缺 `SwiftUIMacros` 插件，`@State` 宏无法展开 →
   状态迁移到 `@MainActor ObservableObject` 的 `@Published`，保留 SwiftUI 视图体系；
8. **环境问题**：`static var` 全局可变状态并发不安全 → 加 `@MainActor` 隔离。

剩余 2 类 warning 均为 CommandLineTools 安装不完整导致的链接器搜索路径提示
（`/Library/Developer/CommandLineTools/Developer/usr/lib`、`.../Library/Frameworks`），
不影响产物运行。

---

## 2. 测试报告

命令：`HYMN_REPORT_DIR=<Reports> .build/debug/hymntest`（`Scripts/test.sh` 可复现）
**结果：57 / 57 通过，0 失败，退出码 0。**

| 模块（独立测试套件） | 用例 | 结果 |
|---|---|---|
| Compatibility — 真实 checkpoint 解析、格式判定、防冒充 | 16 | 16/16 |
| Scheduler — 单实例、优先级、排队取消、快照 | 6 | 6/6 |
| Engine — 流式、聚合、取消、批量、并发峰值、能力标志 | 11 | 11/11 |
| SQLiteStore — 迁移、CRUD、事务批量、LIKE 转义、UPSERT、文件持久化 | 11 | 11/11 |
| Glossary — 最长匹配、语言对过滤、prompt 注入 | 8 | 8/8 |
| MainThreadIsolation — ticker 响应性、token 线程归属 | 5 | 5/5 |

关键断言：
- **需求 5**：`CompatibilityGuard.requireLUT4` 对 affine INT4 抛错通过；反证用例证明分类器能识别
  真正的 LUT4 契约（非硬编码 false）。
- **需求 6**：12 个并发请求下后端 `peakConcurrency == 1`。
- **需求 10**：360 个推理 token 中主线程产出数 = **0**。
- 详细逐条结果：`Reports/test-report.md`；TAP 原始输出：`Reports/test-run.log`。

---

## 3. 性能数据（`Reports/perf.json`）

环境：Apple M3 Pro / 18 GB / macOS 27.0.1 / Swift 6.4，Debug 构建（未开 `-O`）。

| 指标 | 数值 |
|---|---|
| 调度吞吐（300 请求，零延迟） | **37,846 req/s**（总计 7.93 ms，成功率 100%） |
| 流式首 token avg / p50 / p95 / max | **1.57 / 1.46 / 1.51 / 7.82 ms** |
| 批量 100 请求（8 token/请求） | **116.6 req/s**（857.40 ms，800 tokens） |
| 取消响应延迟 | **2.19 ms**（停止前已产出 12 tokens / 上限 100,000） |
| SQLite 事务批量写入 5,000 行 | **156,589 rows/s**（31.93 ms） |
| SQLite 分页查询（200 次） | **0.038 ms/次** |
| 主线程 ticker 平均 / 最大间隔 | **10.00 / 12.32 ms**（10 ms 周期，39 次打点） |

> 主线程最大间隔 12.32 ms 接近 10 ms ticker 基准，说明后台推理负载未造成主线程可观测卡顿。
> 注意首 token 延迟包含测试替身的固定 `Task.sleep`，不是模型 prefill 时间。

---

## 4. CLI 与 App 运行验证

| 命令 | 结果 |
|---|---|
| `hymnctl verify` | 输出 17 行兼容性报告，判定 `LUT4 可加载: NO`，列出 5 条 BLOCKER |
| `hymnctl verify --json` | 结构化 JSON（供后续 CI 消费） |
| `hymnctl translate --db /tmp/hymn_cli_demo.db` | 8 chunks 流式输出，14.63 ms，历史落库 1 行（sqlite3 独立复核通过） |
| `hymnctl batch --count 20` | 20/20 成功，121.9 req/s，`maxConcurrency=1` |
| `hymnctl cancel` | `cancelled=true`，16/10000 tokens，取消延迟 2.21 ms |
| `Scripts/make-app.sh` | 生成 `dist/HymnTranslate.app`（Info.plist + PkgInfo + 资源 bundle） |
| `HYMN_HEADLESS_SMOKE=1 <app>/Contents/MacOS/HymnTranslate` | `HYMN_SMOKE_OK verdictLines=17 isLUT4=false status=就绪（LUT4 权重未就绪…）`，rc=0 |

---

## 5. 需求对照

| # | 需求 | 状态 |
|---|---|---|
| 1 | Swift 6 / SwiftUI / AppKit | ✅ 全部真实编译运行（`@State` 因缺 SwiftUIMacros 改用 `@Published`，见报告） |
| 2 | MLX Swift + Metal 原生推理 | ⛔ **未接入**：依赖源不可达，见 stage0 报告 BLOCKER 3 |
| 3 | 内置 HY-MT2 1.8B | ⛔ **未下载/未内置**：真实元数据已验证，权重文件未获取 |
| 4 | LUT4 混合精度，先验证兼容性 | ✅ 已完成并给出 `NO` 结论与全部证据 |
| 5 | 不得把 INT4 冒充 LUT4 | ✅ 代码级 `CompatibilityGuard` + 回归测试 + UI 显式 `LUT4 NOT READY` |
| 6 | 单模型实例、多请求调度 | ✅ `RequestScheduler` actor，峰值并发实测 = 1 |
| 7 | 流式 / 批量 / 取消 | ✅ 三套独立实现与测试 |
| 8 | SQLite 历史 + 术语库 | ✅ 系统 libsqlite3，含迁移/事务/UPSERT/FTS 友好的 LIKE 转义 |
| 9 | 全程离线（首次下载除外） | ✅ 运行期零网络调用；模型元数据已随包内置 |
| 10 | 推理不阻塞主线程 | ✅ `Task.detached` + 实测 0 主线程 token、最大 tick 间隔 12.32 ms |

**开发规则遵循情况**：先完成兼容性分析（阶段 0）→ 再建最小可运行原生程序（`hymnctl verify`）
→ 各模块独立实现独立测试 → 每阶段提供构建/测试/性能产物 →
遇到不兼容时提出具体适配方案（stage0 报告第 4 节），**未静默降级为 Python 推理，未编造模型算子**。

---

## 6. 未交付 / 待验证清单

1. MLX Swift / MLXLLM 依赖链接与 `ModelContainer` 真实加载；
2. `hunyuan_v1_dense` Swift 架构实现与注册（post-RoPE QK-Norm、DynamicNTK-alpha）；
3. LUT4 权重产出、自定义 Metal LUT-dequant kernel 及逐层数值对齐；
4. 真实翻译质量评测与真实 token/s / TTFT / 峰值内存；
5. 完整 Xcode 下的 Release 构建、签名、公证与 `.app` 分发。

前置条件与逐步方案见 `Reports/stage0-compatibility.md` 第 4 节，
**需用户在「严格 LUT4」/「affine INT4 过渡」/「仅补齐环境」三条路线中选择**。
