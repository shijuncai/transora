# H 阶段收尾交付总览（H1 / COMET / 1260 全方向 / 请求级可复现）

生成时间：2026-11-21 23:23:00 +0800

> 所有数字来自本机实测报告；无权威参考译文的方向不产质量分数。

## 1. Sampler 请求级可复现（含三阶段分数对照）

- 历史基线（Sampler 修复前 / 流式修复前）：BLEU 23.2 / chrF2 41.19 / COMET None — RNG state 跨请求延续；译文含流式解码字符损坏
- Sampler 修复后 / 流式修复前：BLEU 22.62 / chrF2 41.21 / COMET 0.7345 — 每请求重建 Sampler；译文仍含流式解码字符损坏
- 最终（Sampler + 流式解码修复）：BLEU 23.19 / chrF2 43.86 / COMET 0.7809 — 每请求重建 Sampler + streaming-decode 修复；对应最终交付二进制
- 流式解码修复带来的提升：ΔBLEU 0.57 / ΔchrF2 2.65 / ΔCOMET 0.0464
- Sampler 修复改变采样序列，属预期口径变化，不是权重或 prompt 改变。
- 端到端实证：同一请求插入其他请求后复跑译文逐字一致；greedy 亦确定。
- `hymnctl evaluate` 新增 `--seed` / `--greedy`，输出自带复现口径。

## 2. H1 推理优化

- batched prefill 与逐 token forward logits **逐位相等**（maxAbs=0）；prefill 892.4 ms → 556.4 ms（**1.60×**）
- int8 KV cache（有损、默认关闭）：corr 0.999994、top20 20/20、argmax 一致；KV 内存 67,108,864 B → 34,603,008 B，省 31.0 MiB
- fused dequant-GEMM：stq1_0_gemv 自 G4 起已是「解码即乘加」融合，无中间 fp16 权重缓存；本轮不重复造算子、不重复计功。
- 全量测试含 H1 数值等价与 int8 路径断言（见 test-report.md）。

## 3. COMET 系统级评测

- 模型 `Unbabel/wmt22-comet-da`，来源：local分段下载(字节数校验通过)，真实推理 256 条 / 64 方向
- **system_score 0.7809**（mean 0.7809，min 0.3244，max 0.9875）
- never_fabricated=True；打分输入为最终二进制产出的译文假说
- 已接入 `translation-quality-final.json`（comet.system_score=0.7809）

## 4. 1260 全方向覆盖评测

- 方向 **1260/1260** 全覆盖；有权威参考 64，仅可译性冒烟 1196
- 冒烟：非空 1196/1196、无错误 1196/1196、与源不同 1183/1196；**quality_scores_produced=0**
- 64 个有参考方向（每方向仅 1 句，回归信号非排行榜）：BLEU 23.76 / chrF2 40.27
- 退化方向 0；sampling=greedy、request_level_reproducible=True
- **流式解码修复前后**：退化方向 491 → 0；含替换字符方向 497 → 98
  - 低资源 tl：非空 35/35、退化 0、目标文字占比 None
  - 低资源 bo：非空 35/35、退化 0、目标文字占比 0.8277
  - 低资源 mn：非空 35/35、退化 0、目标文字占比 0.7418

## 5. 口径与边界

- 全程 STQ1_0 1.3125 bpw 常驻 GEMV（NOT LUT4 / NOT affine INT4）；运行时全程离线。
- Python 仅用于离线评测与打分；COMET 评测模型/venv 不进 App 运行时、不进 DMG。
- 1196 个无参考方向只做可译性冒烟，绝不产质量分数；低资源语言只报告可观测现象，不臆测模型内部成因。
- 修复前后分数口径不同，不可混用；所有修复前产物以 `-before-streaming-fix` / `-before-fix` 留档。
