# A3-UI：App 图形化后端开关（阶段报告）

生成时间：2026-11-21（GMT+8）
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`
前置阶段：`Reports/stage-a3-complete.md`（并列 MLXBackend 已接入，D-1 为默认后端）

> ## 📌 后续状态更新（G4 / G8）
>
> 本文为 A3-UI 时点快照；此后 App 图形开关扩为 **D-1 / MLX / Sherry 三选一**，
> 且 **G8 起默认后端改为 `Hy-MT2-1.8B-1.25Bit.gguf`（Sherry STQ1_0 常驻 GEMV）**。
> 切换状态机、在途守卫、显式回滚仍然有效；最新结论见 `Reports/stage-g4-resident-gemv.md`。

---

## 1. 需求与结论

把 A3 遗留的「只能用 `HYMN_BACKEND=mlx` 环境变量切换后端」改成 App 内图形化开关。

**结论：已交付。** 新增 SwiftUI 分段选择器 + 完整的后端切换状态机，双向切换、在途请求守卫、失败显式回滚、切换后真实译文、主线程零阻塞均已实证。
**当时默认后端仍是 D-1**（G8 起已改为 Sherry 1.25bit GGUF），两个后端并列而非替换，
权重格式按后端如实标注 `affine INT4 (NOT LUT4)` 或 `Sherry STQ1_0 (NOT LUT4)`。

构建 `BUILD_OK rc=0`、测试 **131/131**、`.app` 83 MB 双模式 + 切换 + 故障注入冒烟全通过。

---

## 2. 设计：不是换个变量，是重建引擎

切换后端意味着**释放当前 1.8B 模型实例并加载另一个实现**，因此按项目规则做了以下约束：

| 约束 | 实现 |
|---|---|
| 单实例调度语义 | 有在途请求（`isRunning`）时**拒绝切换**，状态栏与警告区提示先取消/等待；`switchBackend` 内部也二次 guard，UI disabled 只是第一道 |
| 推理不阻塞主线程 | 旧引擎 `shutdown()` + 新引擎 `prepare()` 整体在 `Task.detached` 中执行；MainActor 在 await 期间正常刷新 UI。切换末尾刻意**不调用** `refreshData()`，避免把 SQLite 同步读取留在主线程 |
| 绝不静默降级 | 新后端 `prepare()` 失败 → 重新构造并 prepare 原后端显式回滚；连回滚都失败才降级 `FixtureBackend`，且状态栏明确写「输出不是译文」 |
| UI 不谎报身份 | `Picker` 用自定义 `Binding`：`get` 读 `AppModel.backendChoice`，`set` 只发 `switchBackend` 请求，**不直接改值**。只有成功才更新，失败自动回弹 |
| 实际后端与选择值分离 | `@Published activeBackendIdentifier` 从 `engine.backendIdentifier()` 读取。若降级为替身，UI 显示 `fixture-v0` 而不是假装还是 D-1/MLX |
| 历史记录可追溯 | `HistoryRecord.modelTag` 由硬编码 D-1 标识改为动态 `activeBackendIdentifier + (REAL INFERENCE, NOT LUT4)` |

环境变量 `HYMN_BACKEND=mlx` **仅影响启动初始选择**（保留给脚本/冒烟用），启动后以 UI 开关为准。

UI 上同步显示两后端取舍说明（来自 `stage-a3-complete.md` 第 6 节）、当前实际后端 identifier、切换中进度、错误警告；输出标签与 header 描述改为动态跟随当前后端，不再硬编码「32 层 Metal forward」。

---

## 3. 改动文件

| 文件 | 变更 |
|---|---|
| `Sources/HymnApp/AppModel.swift` | 新增顶层 `BackendChoice` 枚举（`native`/`mlx`，含 displayName/shortName/blurb）与 `makeBackend(_:)` 工厂；新增 6 个 `@Published` 开关状态；`switchBackend(to:)` 状态机；`bootstrap` 读取实际后端标识；`modelTag` 动态化 |
| `Sources/HymnApp/RootView.swift` | 新增 `backendSwitch` 卡片（segmented Picker + 自定义 Binding、取舍说明、ProgressView、警告区）；header / 输出标签动态化；翻译与批量按钮在切换期间 disabled |
| `Sources/HymnApp/main.swift` | 新增 `HYMN_SMOKE_SWITCH=1` / `HYMN_SMOKE_GUARD=1` 冒烟场景；`MainThreadTicker`（Timer + `RunLoop.main .common`，与 hymntest `TickRecorder` 同口径）；`HYMN_SMOKE_OK` 增加 backend / identifier 字段 |
| `Scripts/build.sh` | 新增 **Metal Toolchain cryptex 路径防呆**（见第 7 节） |
| `Reports/ui-backend-switch-perf.json` | 切换耗时、主线程心跳、译文、守卫与回滚的结构化数据 |
| 本报告 | 阶段交付记录 |

`HymnCore` / `HymnNative` / `HymnStore` / `HymnMLX` / `Package.swift` **零改动**，131 项既有测试未修改。

---

## 4. 构建与测试

| 项 | 结果 |
|---|---|
| `./Scripts/build.sh` | `BUILD_OK rc=0`，0 error；本轮全量 58.20 s，之后增量 0.60–0.63 s |
| `./Scripts/test.sh` | `TEST_OK rc=0`，**# pass 131 fail 0 total 131** |
| 测试套件 | compatibility / native-weights / tokenizer / weight-cache / metal-ops / forward / real-backend / mlx-backend / scheduler / engine / store / glossary / thread-isolation / performance |
| `./Scripts/make-app.sh` | `APP_BUILT`，`.app` 83 MB，内含 `mlx-swift_Cmlx.bundle` 的 `default.metallib` |

---

## 5. App 冒烟矩阵（headless，实跑模型推理）

所有场景都设置 `HYMN_MODEL_DIR` 指向真实 checkpoint，`NSHostingView` 会实例化整套 SwiftUI 视图树。

| # | 场景 | 结果 |
|---|---|---|
| 1 | 默认 D-1 直接翻译 | `backend=native` → **您好，很高兴见到您。**（6 chunks） |
| 2 | `HYMN_BACKEND=mlx` 直接翻译（环境变量回归） | `backend=mlx` → **你好，很高兴见到你。**（6 chunks） |
| 3 | 默认启动 → 图形开关切到 MLX → 翻译（重复 4 轮） | `success=true backend=mlx`，译文 **你好，很高兴见到你。** |
| 4 | MLX 启动 → 切回 D-1 → 翻译 | `success=true backend=native`，译文 **您好，很高兴见到您。** |
| 5 | 在途请求守卫 | `before=native after=native unchanged=true switches=0`，提示「请先取消或等待当前翻译完成」 |
| 6 | **故障注入**：临时目录软链除 `model.safetensors` 外全部文件 → 切到 MLX | `success=false backend=native switches=0`，`⚠️ 切换失败，已回滚到 D-1 原生 Metal：[BACKEND_UNAVAILABLE] 缺少 model.safetensors`；回滚后仍译出 **您好，很高兴见到您。** |

场景 6 证明「失败不谎报成功、不静默降级、原后端可恢复」这条承诺真实成立，而不只是代码里写了。
`HYMN_SMOKE_SWITCH_OK` 中的 `success` 字段明确区分成功/失败，失败时输出 `success=false`。

---

## 6. 性能数据（口径：后端切换，不是模型推理）

| 指标 | 实测 |
|---|---|
| D-1 → MLX 切换耗时 | **703–940 ms**（4 次：933 / 703 / 703 / 940） |
| MLX → D-1 切换耗时 | **2217 ms**（1 次；含 3.58 GB fp16 mmap 打开 + MPS kernel 预热 forward） |
| 切换期间主线程 tick 最大间隔 | **13.88–28.84 ms**（成功切换，5 次） |
| 主线程 tick 平均间隔 | **10.05–10.18 ms** |
| 故障回滚期间 tick 最大间隔 | 18.15–19.87 ms |
| 项目判据 | `maxGapMs < 100 ms`（`RealBackendTests`），全部满足 |

**口径声明（必须保留）**：

- 切换耗时是「释放旧模型 + 加载新模型」的一次性管理开销，**不是 TTFT、不是 token/s、不是推理性能**，不可与 `real-inference-perf.json` / `mlx-backend-perf.json` 混用。
- 所有数字为**单次测量**，非多轮统计均值；GPU 频率、页缓存状态会造成波动。
- 主线程心跳与项目基线同口径（`Timer` + `RunLoop.main .common`）。初版曾用 `Task.sleep` on MainActor 测出 44/39 ms，那是不同测量方式叠加主线程同步 I/O 的结果；统一口径并移除切换路径的 SQLite 同步读取后为 13.88–28.84 ms。此处如实记录这一过程，不挑选好看的数字。
- 运行时工具链本轮复核：Xcode 27.2 (27B52)、Swift 6.4.3、MetalToolchain-v27.2.47.0，`verify-xcode.sh` → `READY`。

---

## 7. 顺带修复的环境问题：Metal Toolchain cryptex 路径失效

本轮首次构建失败于 `unable to spawn process '.../MetalToolchain-v27.2.47.0.wmXecg/.../metal' (No such file or directory)`，
9 个 `CompileMetalFile` 之外的 C/C++/Swift 均无错误。原因是 cryptex 在 12:19 重新挂载，随机目录名由
`wmXecg` 变为 `WycIB6`，而 SwiftPM/XCBuild 把 metal 的**绝对路径**写进了 `.build/out` 构建描述。

处理：清理 `.build/out` 强制重新规划，构建即 `rc=0`。为避免反复踩坑，`Scripts/build.sh` 现在用
`.build/out/metal-toolchain.stamp` 记录 `xcrun --find metal` 的当前结果，路径变化时自动提示并清理构建描述。
该防护已实测：第二次构建不再触发清理（增量 0.60 s），stamp 内容为当前 `WycIB6` 路径。

---

## 8. 边界与未交付

- **未做像素级 UI 自动化**：控件通过 `NSHostingView` 实例化视图树验证编译/运行时正常，交互逻辑通过 `AppModel.switchBackend`（与点击同一入口）的冒烟覆盖；没有模拟真实鼠标点击。
- **故障注入只覆盖一条分支**：「新后端失败 + 原后端回滚成功」已实测；「连回滚都失败 → 显式降级 `FixtureBackend`」仅代码审查，未注入验证。
- 切换期间不刷新历史/术语库（数据未变化），下次翻译/添加术语时会正常刷新。
- 后端切换为**进程内热切换**，未做磁盘持久化：重启 App 仍回到默认 D-1（或 `HYMN_BACKEND` 指定值）。若需要「记住上次选择」，下一步可加 `UserDefaults` 偏好。
- 仍未交付：LUT4 权重（官方不存在，永不冒充）、BLEU/COMET 系统级评测、全部语言对覆盖、MLX 侧量化 KV cache 调优、MLX 取消粒度优化（改 `AsyncStream` 版 generate）。
- 性能数字均为单次测量，未做多轮统计均值。

---

## 9. 复现

```bash
cd /Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate
export HYMN_MODEL_DIR="$PWD/Models/Hy-MT2-1.8B-4bit"

./Scripts/build.sh            # BUILD_OK rc=0
./Scripts/test.sh             # 131/131
./Scripts/make-app.sh         # dist/HymnTranslate.app

APP="$PWD/dist/HymnTranslate.app/Contents/MacOS/HymnTranslate"

# 默认 D-1 / 环境变量 MLX 基线
HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 "$APP"
HYMN_BACKEND=mlx HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_TRANSLATE=1 "$APP"

# 图形开关同一入口：默认 → MLX，含主线程心跳
HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_SWITCH=1 HYMN_SMOKE_TRANSLATE=1 "$APP"

# 反向：MLX → D-1
HYMN_BACKEND=mlx HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_SWITCH=1 HYMN_SMOKE_TRANSLATE=1 "$APP"

# 在途请求守卫
HYMN_HEADLESS_SMOKE=1 HYMN_SMOKE_GUARD=1 "$APP"
```

图形界面直接启动 `dist/HymnTranslate.app`，在标题下方「推理后端」分段控件点选即可；
翻译进行中控件会置灰，切换期间显示进度，失败会在警告区写明原因并自动回弹。

关键日志：`Reports/build.log`、`Reports/test-run.log`、`Reports/test-report.md`、
`Reports/ui-backend-switch-perf.json`。
