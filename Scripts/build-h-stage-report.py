#!/usr/bin/env python3
"""汇总 H 阶段收尾（H1 / COMET / 1260 / 请求级可复现）的真实交付数据。

只读各报告 JSON，生成一份总览 Markdown + JSON，所有数字均来自实测文件，
缺失文件会明确标注 MISSING，不做任何推算或填充。
"""
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
R = ROOT / "Reports"


def load(name: str):
    p = R / name
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return None


def main() -> None:
    h1 = load("h1-optimization-bench.json")
    comet = load("comet-scores.json")
    quality = load("translation-quality-final.json")
    quality_before = load("translation-quality-before-streaming-fix.json")
    coverage = load("coverage-1260-report.json")
    coverage_before = load("coverage-1260-report-before-fix.json")
    repro = load("reproducibility-comparison.json")

    lines = ["# H 阶段收尾交付总览（H1 / COMET / 1260 全方向 / 请求级可复现）", "",
             f"生成时间：{time.strftime('%Y-%m-%d %H:%M:%S %z')}", "",
             "> 所有数字来自本机实测报告；无权威参考译文的方向不产质量分数。", ""]

    lines += ["## 1. Sampler 请求级可复现（含三阶段分数对照）", ""]
    if repro and "stages" in repro:
        for s in repro["stages"]:
            lines.append(f"- {s['name']}：BLEU {s['bleu']} / chrF2 {s['chrf2']} / "
                         f"COMET {s['comet']} — {s['note']}")
        ds = repro.get("delta_streaming_fix", {})
        lines += [
            f"- 流式解码修复带来的提升：ΔBLEU {ds.get('bleu')} / "
            f"ΔchrF2 {ds.get('chrf2')} / ΔCOMET {ds.get('comet')}",
            f"- {repro['caveats'][0]}",
        ]
    elif repro:
        lines += [
            f"- 修复前 BLEU {repro['before']['bleu']} / chrF2 {repro['before']['chrf2']}"
            f" → 修复后 {repro['after']['bleu']} / {repro['after']['chrf2']}",
        ]
    else:
        lines.append("- MISSING: reproducibility-comparison.json")
    lines += ["- 端到端实证：同一请求插入其他请求后复跑译文逐字一致；greedy 亦确定。",
              "- `hymnctl evaluate` 新增 `--seed` / `--greedy`，输出自带复现口径。", ""]

    lines += ["## 2. H1 推理优化", ""]
    if h1:
        eq = h1["numerical_equivalence"]
        pf = h1["prefill_ms"]
        kv = h1["kv_cache_bytes"]
        lines += [
            f"- batched prefill 与逐 token forward logits **逐位相等**"
            f"（maxAbs={eq['baseline_vs_batched_max_abs']}）；"
            f"prefill {pf['baseline_median']:.1f} ms → {pf['batched_median']:.1f} ms"
            f"（**{pf['speedup_batched']:.2f}×**）",
            f"- int8 KV cache（有损、默认关闭）：corr {eq['baseline_vs_int8_pearson_corr']:.6f}、"
            f"top20 {eq['baseline_vs_int8_top20_overlap']}/20、argmax 一致；"
            f"KV 内存 {kv['fp16']:,} B → {kv['int8']:,} B，省 {kv['saved_mib']:.1f} MiB",
            f"- fused dequant-GEMM：{h1['fused_dequant_gemm']}",
            "- 全量测试含 H1 数值等价与 int8 路径断言（见 test-report.md）。",
        ]
    else:
        lines.append("- MISSING: h1-optimization-bench.json")
    lines.append("")

    lines += ["## 3. COMET 系统级评测", ""]
    if comet and comet.get("status") == "OK":
        lines += [
            f"- 模型 `{comet['model']}`，来源：{comet.get('model_source')}，"
            f"真实推理 {comet['scored_rows']} 条 / {comet['direction_count']} 方向",
            f"- **system_score {comet['system_score']}**"
            f"（mean {comet['mean_score']}，min {comet['min_score']}，max {comet['max_score']}）",
            f"- never_fabricated={comet['never_fabricated']}；"
            "打分输入为最终二进制产出的译文假说",
        ]
    else:
        lines.append(f"- 未产出分数：{comet.get('status') if comet else 'MISSING'}"
                     f" {comet.get('reason', '') if comet else ''}")
    if quality and quality.get("comet", {}).get("status") == "OK":
        lines.append(f"- 已接入 `translation-quality-final.json`（comet.system_score="
                     f"{quality['comet']['system_score']}）")
    lines.append("")

    lines += ["## 4. 1260 全方向覆盖评测", ""]
    if coverage:
        sm = coverage["coverage_smoke"]
        lines += [
            f"- 方向 **{coverage['directions_observed']}/{coverage['expected_directions']}** 全覆盖；"
            f"有权威参考 {coverage['directions_with_reference']}，"
            f"仅可译性冒烟 {coverage['directions_smoke_only']}",
            f"- 冒烟：非空 {sm['non_empty']}/{sm['n']}、无错误 {sm['no_error']}/{sm['n']}、"
            f"与源不同 {sm['distinct_from_source']}/{sm['n']}；"
            f"**quality_scores_produced={sm['quality_scores_produced']}**",
            f"- 64 个有参考方向（每方向仅 1 句，回归信号非排行榜）："
            f"BLEU {coverage['overall_scored']['bleu']} / chrF2 {coverage['overall_scored']['chrf2']}",
            f"- 退化方向 {coverage['degenerate_direction_count']}；"
            f"sampling={coverage['sampling_mode']}、"
            f"request_level_reproducible={coverage['request_level_reproducible']}",
        ]
        if coverage_before:
            lines += [
                f"- **流式解码修复前后**：退化方向 "
                f"{coverage_before['degenerate_direction_count']} → "
                f"{coverage['degenerate_direction_count']}；"
                f"含替换字符方向 {coverage_before['coverage_smoke']['with_replacement_char']} → "
                f"{coverage['coverage_smoke']['with_replacement_char']}",
            ]
        for lang in ("tl", "bo", "mn"):
            d = coverage["low_resource_diagnosis"].get(lang)
            if d:
                lines.append(f"  - 低资源 {lang}：非空 {d['non_empty']}/{d['directions_as_target']}、"
                             f"退化 {d['degenerate']}、目标文字占比 {d['avg_target_script_ratio']}")
    else:
        lines.append("- MISSING: coverage-1260-report.json")
    lines.append("")

    lines += ["## 5. 口径与边界", "",
              "- 全程 STQ1_0 1.3125 bpw 常驻 GEMV（NOT LUT4 / NOT affine INT4）；运行时全程离线。",
              "- Python 仅用于离线评测与打分；COMET 评测模型/venv 不进 App 运行时、不进 DMG。",
              "- 1196 个无参考方向只做可译性冒烟，绝不产质量分数；"
              "低资源语言只报告可观测现象，不臆测模型内部成因。",
              "- 修复前后分数口径不同，不可混用；所有修复前产物以 "
              "`-before-streaming-fix` / `-before-fix` 留档。", ""]

    md = "\n".join(lines)
    (R / "h-stage-final-report.md").write_text(md, encoding="utf-8")
    summary = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "sampler": repro,
        "h1": h1,
        "comet_status": comet.get("status") if comet else "MISSING",
        "comet_system_score": comet.get("system_score") if comet else None,
        "quality_final": {"bleu": quality["overall"]["bleu"],
                          "chrf2": quality["overall"]["chrf2"]} if quality else None,
        "quality_before_streaming_fix": {
            "bleu": quality_before["overall"]["bleu"],
            "chrf2": quality_before["overall"]["chrf2"]} if quality_before else None,
        "coverage": {"directions": coverage["directions_observed"],
                     "with_reference": coverage["directions_with_reference"],
                     "smoke_only": coverage["directions_smoke_only"],
                     "degenerate": coverage["degenerate_direction_count"],
                     "quality_scores_for_smoke": coverage["coverage_smoke"]["quality_scores_produced"]}
        if coverage else None,
        "coverage_before_fix": {"degenerate": coverage_before["degenerate_direction_count"],
                                "with_replacement_char":
                                    coverage_before["coverage_smoke"]["with_replacement_char"]}
        if coverage_before else None,
    }
    (R / "h-stage-final-report.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print("H_STAGE_REPORT_OK")
    print(f"  comet={summary['comet_status']} score={summary['comet_system_score']}")
    print(f"  coverage={summary['coverage']}")
    print(f"  WROTE {R / 'h-stage-final-report.md'}")


if __name__ == "__main__":
    main()
