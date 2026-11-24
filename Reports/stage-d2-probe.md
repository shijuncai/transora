# HymnTranslate 阶段 D-2 探测报告：MLX Swift 本地依赖可用性复核

生成时间：2026-11-21 10:13 (GMT+8)
工程根目录：`/Users/Kavenshi/Documents/翻译软件ForMAC/HymnTranslate`
探测性质：**只做只读核查与隔离探针，未修改主工程 `Package.swift`，未改动 D-1 真实后端**

> ## 📌 后续状态更新（G4 / G8）
>
> 本文为 D-2 探测时点快照；此后 A1–A3 已完成 MLX Swift 全栈接入，
> **G8 起默认后端改为 `Hy-MT2-1.8B-1.25Bit.gguf`（Sherry STQ1_0 常驻 GEMV）**。
> D-1 / MLX 仍并列可显式选择。最新结论见 `Reports/stage-g4-resident-gemv.md`。

---

## 0. 结论（先说结果）

用户先后放入 `mlx-swift-main.zip` / `mlx-swift-main/` 与 `metal-cpp/`，并说明「swift 已安装」。
实测结论：

1. **Swift 编译器本来就可用**（Swift 6.4 / CommandLineTools），这一点从未是阻塞。
2. **唯一硬阻塞是 Xcode 附带的 Metal 工具链缺失**：`metal` / `metallib` / `metal-ar` / `xcodebuild` 全部不存在，
   `/Applications` 下无 Xcode.app，`xcode-select -p` = `/Library/Developer/CommandLineTools`。
3. **新放的 `metal-cpp/` 不能解除该阻塞**：它是 Apple 的 C++ 头文件绑定（95 个 `.hpp`、0 个可执行文件、
   0 个 `.metallib`），不是把 `.metal` 编译成 `.air`/`.metallib` 的编译器；且 `mlx-swift-main` 内部
   已自带更完整的 `metal-cpp`（139 个文件，含 MTL4 头），该副本是冗余的。
4. **好消息**：这份 `mlx-swift-main` 源码是**完整的**（`mlx-generated` 已内联 MLX C++ 核心，
   空的 `Source/Cmlx/mlx` / `mlx-c` 只是 submodule 占位，不影响编译），SwiftPM 6.4 能正确解析
   `swift-tools-version: 6.3;(experimentalCGen)`、`traits` 并拉取 `swift-numerics 1.1.1`。
   探针构建**没有任何 C / C++ / Swift 编译错误**，全部错误只来自 `CompileMetalFile`。
5. **更好的消息**：GitHub release CDN 现已恢复（此前记录的「直连 0 字节 / 限速 20 KB/s」已过期）。
   官方 `0.33.0` 提供预编译 `Cmlx.xcframework`，其中**确实包含 `default.metallib`**。
   这打开了一条「无需安装 Xcode、无需本机 Metal 编译器」的原生接入路径。

> 按用户硬性规则，本报告只给**具体适配方案**（第 6 节），在未获选择前不擅自替换后端、
> 不静默降级为 Python 推理、不把 affine INT4 冒充 LUT4。

---

## 1. 用户新增材料核实

| 路径 | 形态 | 实测 |
|---|---|---|
| `mlx-swift-main.zip` | GitHub 仓库源码 zip，3,000,248 B | 已解压；后续目录清单中已被移走，仅保留解压目录 |
| `mlx-swift-main/` | 源码树，16 MB / 84 个 `.swift` | 完整 main 分支快照（文件时间 2026-11-18） |
| `metal-cpp/` | Apple metal-cpp 头文件包，1.3 MB | 98 文件：95 `.hpp` + LICENSE + README + `make_single_header.py`；**0 可执行文件**；文件时间 2024-12-20 |

`mlx-swift-main` 内部关键构成：

```
Source/Cmlx/mlx-generated/     54 .cpp + 99 .h + 14 .metal   ← MLX C++ 核心已内联
Source/Cmlx/mlx               0 files  ← submodule 占位（.gitmodules 指向 ml-explore/mlx）
Source/Cmlx/mlx-c             0 files  ← submodule 占位（.gitmodules 指向 ml-explore/mlx-c）
Source/Cmlx/metal-cpp       139 files  ← 已自带，比新放的 98 文件更全
Source/Cmlx/fmt / json       117 / 53 files（vendored）
Plugins/CudaBuild/           Linux CUDA 用，macOS 不参与
```

`Package.swift` 中大量 `Invalid Exclude ... File not found` warning 正是因为 `mlx` / `mlx-c`
占位目录为空；这些是**警告而非错误**，不构成构建失败。

---

## 2. 工具链复核（本次实测，覆盖 11-20/11-21 旧记录）

| 项 | 结果 |
|---|---|
| `swift --version` | Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)，target arm64-apple-macosx27.0.0 |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` |
| `xcodebuild -version` | 失败：`tool 'xcodebuild' requires Xcode ... is a command line tools instance` |
| `/Applications/Xcode*` | 不存在 |
| `xcrun --find metal` / `metallib` / `metal-ar` | 三者均 `unable to find utility` |
| `xcrun --show-sdk-path` | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` |
| SwiftPM 解析 mlx-swift | **成功**（tools-version 6.3 + traits + swift-numerics 1.1.1，2.47 s 拉取完成） |
| 网络：github.com / mlx / mlx-c / swift-numerics | 均 HTTP 200 |
| 网络：GitHub release assets | HTTP **206** Range 可用，1 MiB 测速 101 KB/s – 594 KB/s |

> 环境事实变更：**release CDN 不再不可达**。旧笔记中「release CDN 直连 0 字节、
> ghproxy 限速 20 KB/s」对当前网络已不适用。

---

## 3. 隔离探针构建结果

探针工程：`research/mlx-swift-probe/`（独立 SwiftPM 包，`.package(path: "../../mlx-swift-main")`，
依赖 `MLX` / `MLXNN` 两个 product）。主工程 `HymnTranslate/Package.swift` **未被改动**。

```
$ cd research/mlx-swift-probe && swift build --disable-sandbox
PROBE_BUILD_RC=1
```

错误构成统计（`/tmp/mlx_probe_build.log`）：

| 错误 | 次数 |
|---|---|
| `unable to spawn process 'metal' (No such file or directory)` | 9 |
| `CompileMetalFile .../*.metal failed with a nonzero exit code` | 9 |
| `Build failed` | 1 |
| **C / C++ / Swift 编译错误** | **0** |
| **非 Metal 相关错误** | **0** |

SwiftPM 6.4 实际调用了 `CompileMetalFile` 规则（这与 mlx-swift README 里
「命令行 SwiftPM 不能编译 Metal shaders」的旧描述不同 —— 该版本已把 kernel 源码
放进 `mlx-generated/metal/`，由 SwiftPM 直接编译），命令形如：

```
metal -c -target air64-apple-macos14.0 ... \
  -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast \
  -o .../rms_norm.air \
  mlx-swift-main/Source/Cmlx/mlx-generated/metal/rms_norm.metal
```

失败点即 `metal` 二进制不存在。**结论：源码与 SwiftPM 都没问题，缺的只是 Metal 编译器。**

受影响的 14 个 `.metal` 中已见：`rms_norm.metal`、`rope.metal`、`layer_norm.metal`、
`random.metal`、`scaled_dot_product_attention.metal`（+vjp）、`conv.metal`、
`arg_reduce.metal`、`steel/attn/kernels/steel_attention.metal` 等。

---

## 4. 预编译二进制通道验证

GitHub API `repos/ml-explore/mlx-swift/releases?per_page=3` 返回（节选）：

| tag | asset | size |
|---|---|---|
| 0.33.0 | `Cmlx.xcframework.zip` | 228,419,768 B |
| 0.33.0 | `MLX.xcframework.zip` | 17,594,839 B |
| 0.33.0 | `MLXNN.xcframework.zip` | 9,493,546 B |
| 0.33.0 | `MLXOptimizers.xcframework.zip` | 4,867,015 B |
| 0.32.3 | `Cmlx.xcframework.zip` | 212,871,838 B |

用 HTTP Range 只读解析 `Cmlx.xcframework.zip` 的 EOCD + 中央目录（**未下载 228 MB 全量**：
取尾部 128 KiB 得 `cd_size=69199, cd_off=228350547, entries=479`，再取该段解析），确认其中含：

```
Cmlx.xcframework/macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib
Cmlx.xcframework/ios-arm64/Cmlx.framework/default.metallib
Cmlx.xcframework/tvos-arm64/Cmlx.framework/default.metallib
Cmlx.xcframework/xros-arm64/Cmlx.framework/default.metallib
Cmlx.xcframework/ios-arm64_x86_64-maccatalyst/Cmlx.framework/Versions/A/Resources/default.metallib
```

`default.metallib` 正是 MLX Metal 运行时所需的预编译 shader 库（`Package.swift` 中
`.define("METAL_PATH", to: "\"default.metallib\"")`）。因此**本机没有 `metal` 编译器
也可用官方预编译产物绕过**。

---

## 5. 阻塞定位（精确定义）

```
mlx-swift-main 源码完整  ✅
Swift 6.4 / SwiftPM 解析  ✅
swift-numerics 依赖拉取  ✅
C/C++/Swift 编译         ✅（0 error）
.metal → .air → metallib ❌  需要 xcrun metal / metallib（CommandLineTools 不提供）
release 预编译 metallib  ✅  可从官方 xcframework 获取
mlx-swift-lm（Hunyuan.swift）源码  ✅  已在 research/upstream/mlx-swift-lm
```

即：**D-2 的技术阻塞已从「多个依赖不可达」收敛为「二选一：装 Xcode，或用官方预编译二进制」**。

---

## 6. 具体适配方案（请用户选择）

共同前提（四案都遵守）：**D-1 的 `RealModelBackend` 保持默认且不被静默替换**；
新增 MLX 后端以 `InferenceBackend` 协议并列接入，`performsRealModelInference` 如实声明；
全程标注 `affine INT4 (NOT LUT4)`；Python 只做离线 golden；推理不阻塞主线程。

### 方案 A：安装完整 Xcode，源码编译 MLX Swift（官方推荐路径）
- 用户操作：安装 Xcode（≥16），`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
- 我执行：`swift build --disable-sandbox` 编译 `mlx-swift-main` → 接 `mlx-swift-lm` →
  新增 `MLXBackend` → 与 D-1 做**数值/译文交叉验证**（同一 prompt、同一权重、同一采样参数）。
- 优点：源码与二进制版本天然一致，可持续跟上游；性能可与 D-1 对照（MLX 有 batched prefill）。
- 成本/风险：Xcode 体积数 GB、需 Apple 账号与下载时间；首次编译 C++ 较慢。
- 对 D-1 影响：零（并列后端）。

### 方案 B：官方预编译 xcframework，二进制接入（无需 Xcode）— **推荐先做探针**
- 我执行：下载 `0.33.0` 的 `Cmlx / MLX / MLXNN / MLXOptimizers` xcframework（合计约 260 MB，
  当前测速下数分钟）→ 在**隔离探针**中用 `binaryTarget` 链接 → 跑最小 MLX 计算 + 模型加载 →
  通过后才谈接入主工程。
- 优点：立刻可验证、不动主工程、不需要用户装任何东西、完全可逆。
- 风险：**版本匹配** —— 用户给的是 main 快照（`Package.swift` 里 `MLX_VERSION = "0.32.0"`），
  release 是 0.33.0；Swift 层与 Cmlx ABI 必须配套。若不匹配需改用 0.33.0 源码 tag 或整套二进制。
  另外 `mlx-swift-lm` 需以源码编译并链接这些二进制 product，需处理 product 名映射。
- 对 D-1 影响：零（先探针，成功后才并列）。

### 方案 C：只提取 `default.metallib`，跳过 .metal 编译（最小下载、风险最高）
- 思路：用 Range 只取 macOS slice 的 `default.metallib`（不必下 228 MB），
  改 `mlx-swift-main/Package.swift` 把 14 个 `.metal` 从编译源排除，改用预编译库作为资源。
- 风险：C++ 侧 `mlx-generated` kernel 与 metallib 必须**逐符号严格同版本**，否则运行时缺 kernel
  或 ABI 错位；这是改上游构建脚本，容易埋隐性错误。**不推荐作为主路径**，只作为 B 失败时的诊断手段。

### 方案 D：维持 D-1，MLX Swift 仅作离线语义参考
- 不做运行时接入；`mlx-swift-main` 与 `research/upstream/mlx-swift-lm` 一起作为算子语义参考。
- 转去做尚未交付的性能优化（batched prefill）或 BLEU/COMET 翻译质量评测。
- 成本：零；但用户提供的 MLX Swift 不产生运行时价值。

---

## 7. 规则遵守声明

- 未把普通 affine INT4 冒充 LUT4；未编造任何算子或「已接入 MLX」的假结论。
- 遇到依赖不兼容，先给具体适配方案（第 6 节），**未静默降级为 Python 推理**，
  未静默替换或关闭 D-1 真实后端。
- 主工程 `Package.swift`、`Sources/`、`dist/` 在本阶段**零改动**；
  探针仅在 `research/mlx-swift-probe/`，可整体删除。
- 性能数据口径：本报告的 101–594 KB/s 是**网络下载测速**，不是模型推理性能；
  探针构建 rc=1 是**预期内的实证结果**，不计入 `test.sh` 的 120/120。

## 8. 复现

```bash
cd HymnTranslate
xcode-select -p                          # CommandLineTools
xcrun --find metal                       # 不存在 → 阻塞点
cd research/mlx-swift-probe && swift build --disable-sandbox   # rc=1，全部为 CompileMetalFile
curl -s "https://api.github.com/repos/ml-explore/mlx-swift/releases?per_page=3" | python3 -m json.tool
```

---

## 9. 决策变更与方案 A 准备状态（2026-11-21 10:30）

### 9.1 用户决策轨迹

- 先选 **C（只取 metallib）**，后改选 **A（安装完整 Xcode，源码编译 MLX Swift）**。
  C 路径已中止，未对 `mlx-swift-main/Package.swift` 做任何修改，C 的临时目录
  `research/mlx-swift-binaries/` 已清理（空目录）。
- 按用户硬性规则，两次都先给了具体适配方案，未静默替换 D-1 后端、未降级 Python。

### 9.2 C 阶段留下的有效实证（对 A 同样有价值）

即使不再走 C，以下结论仍成立，且降低了 A 的未知风险：

- `0.33.0` tag 的源码 zip（2,998,275 B）与本地 `mlx-swift-main` 快照比对：
  - `Source/Cmlx/mlx-generated/metal/` 下 **14 个 `.metal` 全部逐字节一致**（0 差异 / 0 增删）；
  - `Source/Cmlx/mlx-generated/` 下 **167 个文件（54 cpp + 99 h + 14 metal）全部逐字节一致**。
  - 即 main 快照的生成层与 0.33.0 release 同源，源码本身无版本错配迹象。
- 官方 `0.33.0/Cmlx.xcframework.zip`（228,419,768 B，479 entries）用 Range 解析中央目录确认
  含 macOS `default.metallib`（压缩 869,470 B / 解压 4,629,392 B）；该路径的提取尝试在
  修正 zip 字段偏移后被用户中断，**未产出文件、未用作任何构建输入**（如实记录）。

### 9.3 方案 A 当前实测状态

```
$ ./Scripts/verify-xcode.sh
FAIL  未找到 /Applications/Xcode*.app（完整 Xcode 尚未安装）
INFO  developer dir = /Library/Developer/CommandLineTools
FAIL  xcodebuild / metal / metallib / metal-ar 均不可用
INFO  swift: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 ...)
RESULT: NOT_READY
VERIFY_RC=1
```

磁盘可用 50 GiB，空间充足。**安装 Xcode 涉及 Apple 账号与系统级安装，必须由用户完成；
助手不能代装，也不应绕过。** 本阶段主工程 `Package.swift` / `Sources/` / `dist/` 仍为零改动。

### 9.4 已就绪的准备工作（Xcode 一到位即可一键续跑）

| 文件 | 作用 |
|---|---|
| `Scripts/verify-xcode.sh` | 只读检查 Xcode.app、developer dir、`xcodebuild`/`metal`/`metallib`/`metal-ar`、版本；已实测正确报 `NOT_READY` |
| `Scripts/build-mlx-swift.sh` | 前置检查 → 清理探针 `.build` → `swift build --disable-sandbox` 编译 54 cpp + 14 metal + 84 swift → 运行 GPU 探针；日志写 `Reports/mlx-swift-build.log` / `mlx-swift-probe-run.log` |
| `research/mlx-swift-probe/Sources/MLXSwiftProbe/main.swift` | 加强为 `matmul` + `softmax` + 打印默认设备；所用 API 均在 mlx-swift 源码中逐一核实过位置，非臆造；能验证 `default.metallib` 真的被加载，而不只是编译通过 |
| `research/mlx-swift-probe/Package.swift` | 本地 `.package(path: "../../mlx-swift-main")`，独立于主工程 |

### 9.5 用户需执行（一次性）

1. 安装完整 Xcode（App Store「Xcode」或 developer.apple.com 的 `.xip`，需约 7–10 GB）。
2. 首次启动接受 license，然后：
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```
3. 若 `xcrun --find metal` 仍失败（Xcode 16+ 把 Metal 编译器拆为可下载组件）：
   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```
4. 回到本工程运行：
   ```bash
   cd HymnTranslate
   ./Scripts/verify-xcode.sh        # 期望 RESULT: READY
   ./Scripts/build-mlx-swift.sh     # 期望 BUILD_OK + MLX_SWIFT_PROBE_OK device=gpu
   ```

### 9.6 Xcode 就绪后的分阶段交付（每阶段独立构建 / 测试 / 报告）

| 阶段 | 目标 | 验收 |
|---|---|---|
| A1 | 源码编译 mlx-swift，GPU 最小计算跑通 | `BUILD_OK rc=0` + `MLX_SWIFT_PROBE_OK device=gpu`，日志落盘 |
| A2 | 拉取 `mlx-swift-lm`（上游副本已不在 `research/upstream/`，需重新 clone），编译 `hunyuan_v1_dense` | 能用真实 `model.safetensors` 加载 804 张量 |
| A3 | 新增 `MLXBackend` 并列接入，与 D-1 做数值/译文/性能交叉验证 | 同 prompt、同权重、同采样参数下译文一致；`performsRealModelInference` 如实声明；UI 仍标 `affine INT4 (NOT LUT4)` |

> A3 之前，D-1 的 `RealModelBackend` 始终是默认后端。任何一步失败都如实记录，
> 不静默降级、不把「编译通过」说成「模型跑通」。

### 9.7 Xcode 安装后复核（2026-11-21 10:36）

用户告知 Xcode 已装完。`./Scripts/verify-xcode.sh` 实测：

```
OK    Xcode.app = /Applications/Xcode.app
OK    developer dir = /Applications/Xcode.app/Contents/Developer
OK    xcodebuild -> .../usr/bin/xcodebuild
FAIL  metal / metallib / metal-ar 均不可用
INFO  xcodebuild: Xcode 27.2 Build version 27B52
INFO  swift:      <空>
RESULT: NOT_READY  (VERIFY_RC=1)
```

定位到**两个必须管理员权限的前置条件**（助手执行环境禁用 `sudo`：
`sandbox` 与 `dangerouslyDisableSandbox` 两种模式都返回 `operation not permitted: sudo`）：

| # | 问题 | 证据 | 用户侧命令 |
|---|---|---|---|
| 1 | Xcode license 未接受 | `swift --version` / `xcrun --find metal` / `xcodebuild -downloadComponent` 均返回 `You have not agreed to the Xcode license agreements`；无 sudo 执行 `-license accept` 明确回 `requires admin privileges` | `sudo xcodebuild -license accept` |
| 2 | Metal Toolchain 组件未下载 | `XcodeDefault.xctoolchain/usr/bin/metal` 物理存在但只是 stub，直接调用报 `cannot execute tool 'metal' due to missing Metal Toolchain`；`metallib` / `metal-ar` 文件不存在；`/Library/Developer/Toolchains/` 为空 | `sudo xcodebuild -downloadComponent MetalToolchain` |

补充事实：Xcode.app 属 `root:wheel`，组件写入需管理员权限，故第二条也加 `sudo`。
`xcodebuild -checkFirstLaunchStatus` rc=0、license 仍未接受，说明首次启动流程完成不等于
命令行 license 已接受。

**当前 A1 尚未执行**：`Scripts/build-mlx-swift.sh` 会在第 0 步前置检查处主动拒绝，
不会在不完整工具链上产生误导性的「构建失败」结论。用户完成上述两条命令后，
依次运行 `./Scripts/verify-xcode.sh`（期望 `READY`）与 `./Scripts/build-mlx-swift.sh`。

主工程仍零改动；`swift build --disable-sandbox`（在切换 developer dir 前）最后一次
`Build complete!`，120/120 测试基线未受影响。

> ### ✅ 后续状态（2026-11-21 11:12）：A1 与 A2 已完成
> 用户完成 license + Metal Toolchain 两条 sudo 命令后，`verify-xcode.sh` 返回 `READY`；
> 补齐 `mlx` / `mlx-c` 两个官方 submodule 并把三个外部依赖本地化后，
> **A1**（`BUILD_OK rc=0` + `MLX_SWIFT_PROBE_OK device=gpu`）与
> **A2**（`hunyuan_v1_dense_registered=true`）均通过；
> 主工程回归 `BUILD_OK rc=0`、测试 **120/120**。
> 最新完整报告改为 **`Reports/stage-a1-a2-complete.md`**。
> 本节 9.2 中「`mlx`/`mlx-c` 空目录只是占位、不影响编译」的判断**已被实证推翻**，
> 见新报告第 2 节。
>
> ### ✅ 最终状态（2026-11-21 11:5x）：A3 已完成
> 并列 `MLXBackend` 已接入主工程（CLI `--backend mlx` / App `HYMN_BACKEND=mlx`），
> 测试 **131/131**，`.app` 双模式真实翻译冒烟通过。
> **最新完整报告：`Reports/stage-a3-complete.md`**。
> **A3 时点** D-1 仍是默认后端，结论是「并列而非替换」；权重标 `affine INT4 (NOT LUT4)`。
> ⚠️ **G8 起默认后端已改为 Sherry 1.25bit GGUF 常驻 GEMV**，见本文顶部状态更新块与
> `Reports/stage-g4-resident-gemv.md`；D-1 / MLX 仍并列可显式选择。
