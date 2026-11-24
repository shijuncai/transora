#!/usr/bin/env python3
"""H4：1260 全方向覆盖评测打分与诊断（Python 仅离线分析，不参与运行时推理）。

输入：Reports/coverage-1260-hypotheses.jsonl（hymnctl evaluate 真实推理产出）
输出：Reports/coverage-1260-report.json

严格口径：
  · 1196 个无参考方向只统计「可译性冒烟」（非空 / 与源不同 / 无错误 /
    重复串 / 替换字符 / 目标脚本占比），**不产出任何质量分数**。
  · 64 个 en 枢轴方向有 OPUS-100 参考译文，可算 BLEU/chrF2；
    但每方向仅 1 条，分数不稳定，只作回归信号，不是排行榜。
  · 低资源语言（tl/bo/mn）专项诊断只报告可观测现象，不臆测成因。
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# 默认指向流式解码修复后的全量重跑批次（最终口径）；
# 修复前批次可显式传 coverage-1260-hypotheses-before-streaming-fix.jsonl 打分。
HYP = ROOT / "Reports" / (sys.argv[1] if len(sys.argv) > 1
                          else "coverage-1260-hypotheses-after-fix.jsonl")
OUT = ROOT / "Reports" / (sys.argv[2] if len(sys.argv) > 2
                          else "coverage-1260-report.json")
MANIFEST = ROOT / "Eval" / "coverage-1260-manifest.json"

# 非拉丁目标语言：用于「是否输出了目标文字」的启发式诊断（不用于打分）
SCRIPT_RANGES = {
    "zh": [(0x4E00, 0x9FFF)],
    "ja": [(0x3040, 0x30FF), (0x4E00, 0x9FFF)],
    "ko": [(0xAC00, 0xD7AF)],
    "ar": [(0x0600, 0x06FF)],
    "fa": [(0x0600, 0x06FF)],
    "ur": [(0x0600, 0x06FF)],
    "ug": [(0x0600, 0x06FF)],
    "he": [(0x0590, 0x05FF)],
    "hi": [(0x0900, 0x097F)],
    "mr": [(0x0900, 0x097F)],
    "gu": [(0x0A80, 0x0AFF)],
    "bn": [(0x0980, 0x09FF)],
    "ta": [(0x0B80, 0x0BFF)],
    "te": [(0x0C00, 0x0C7F)],
    "th": [(0x0E00, 0x0E7F)],
    "km": [(0x1780, 0x17FF)],
    "my": [(0x1000, 0x109F)],
    "bo": [(0x0F00, 0x0FFF)],
    "ru": [(0x0400, 0x04FF)],
    "uk": [(0x0400, 0x04FF)],
    "kk": [(0x0400, 0x04FF)],
    "mn": [(0x0400, 0x04FF), (0x1800, 0x18AF)],
}

LOW_RESOURCE = ["tl", "bo", "mn"]


def max_run(s: str) -> int:
    if not s:
        return 0
    best = cur = 1
    for i in range(1, len(s)):
        if s[i] == s[i - 1]:
            cur += 1
            best = max(best, cur)
        else:
            cur = 1
    return best


def repeated_bigram_ratio(s: str) -> float:
    if len(s) < 4:
        return 0.0
    grams = [s[i:i + 2] for i in range(len(s) - 1)]
    return round(1.0 - len(set(grams)) / len(grams), 4)


def script_ratio(s: str, lang: str):
    ranges = SCRIPT_RANGES.get(lang)
    if not ranges or not s.strip():
        return None
    hits = sum(1 for ch in s if any(a <= ord(ch) <= b for a, b in ranges))
    return round(hits / len(s), 4)


def diagnose(row: dict) -> dict:
    h = (row.get("hypothesis") or "").strip()
    src = (row.get("source") or "").strip()
    n = len(h)
    r = script_ratio(h, row.get("target_lang", ""))
    repl_positions = [i for i, c in enumerate(h) if c == "\ufffd"]
    # 流式修复后，尾部单个 U+FFFD 是 StreamingTextDecoder.finish() 对
    # 「maxTokens 截断切到多字节字符」的如实标注，不是解码损坏，单独归类。
    truncation_marker = (
        len(repl_positions) > 0
        and all(i >= n - 2 for i in repl_positions)
        and len(repl_positions) <= 2
    )
    return {
        "non_empty": bool(h),
        "no_error": not row.get("error"),
        "distinct_from_source": bool(h) and h != src,
        "length": n,
        "replacement_chars": len(repl_positions),
        "truncation_marker": truncation_marker,
        "max_same_char_run": max_run(h),
        "max_run_ratio": round(max_run(h) / n, 4) if n else 0.0,
        "repeated_bigram_ratio": repeated_bigram_ratio(h),
        "target_script_ratio": r,
        "looks_degenerate": (
            not h
            or bool(row.get("error"))
            or (len(repl_positions) > 0 and not truncation_marker)
            or (n >= 8 and max_run(h) / n > 0.35)
            or (n >= 8 and repeated_bigram_ratio(h) > 0.75)
        ),
    }


def main() -> None:
    if not HYP.is_file():
        print(f"COVERAGE_SCORE_FAIL 缺少 {HYP}", file=sys.stderr)
        sys.exit(1)
    rows = []
    for line in HYP.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.is_file() else {}

    for r in rows:
        r["_diag"] = diagnose(r)

    scored = [r for r in rows if r.get("reference")]
    smoke = [r for r in rows if not r.get("reference")]

    # ---- 64 个有参考方向：真实 BLEU / chrF2 ----
    from sacrebleu import corpus_bleu, corpus_chrf
    direction_scores = {}
    by_direction = defaultdict(list)
    for r in scored:
        by_direction[f"{r['source_lang']}->{r['target_lang']}"].append(r)
    for d, items in sorted(by_direction.items()):
        refs = [x["reference"] for x in items]
        hyps = [x["hypothesis"] for x in items]
        direction_scores[d] = {
            "n": len(items),
            "bleu": round(corpus_bleu(hyps, [refs], tokenize="13a").score, 2),
            "chrf2": round(corpus_chrf(hyps, [refs]).score, 2),
            "avg_wall_ms": round(sum(x["wall_ms"] for x in items) / len(items), 1),
        }
    overall = None
    if scored:
        refs = [x["reference"] for x in scored]
        hyps = [x["hypothesis"] for x in scored]
        b = corpus_bleu(hyps, [refs], tokenize="13a")
        c = corpus_chrf(hyps, [refs])
        overall = {"bleu": round(b.score, 2), "chrf2": round(c.score, 2),
                   "signature": str(b)}

    # ---- 1196 个无参考方向：只做可译性冒烟统计 ----
    smoke_stats = {
        "n": len(smoke),
        "non_empty": sum(1 for r in smoke if r["_diag"]["non_empty"]),
        "no_error": sum(1 for r in smoke if r["_diag"]["no_error"]),
        "distinct_from_source": sum(1 for r in smoke if r["_diag"]["distinct_from_source"]),
        "with_replacement_char": sum(1 for r in smoke if r["_diag"]["replacement_chars"] > 0),
        "truncation_markers_only": sum(1 for r in smoke if r["_diag"]["truncation_marker"]),
        "degenerate_outputs": sum(1 for r in smoke if r["_diag"]["looks_degenerate"]),
        "quality_scores_produced": 0,
        "quality_scores_produced_note": "这 1196 个方向没有权威参考译文，本脚本刻意不产出任何 BLEU/COMET/chrF 分数。",
    }

    # ---- 按目标语言聚合（含参考与冒烟的所有方向） ----
    by_target = defaultdict(list)
    for r in rows:
        by_target[r["target_lang"]].append(r)
    per_target_language = {}
    for lang, items in sorted(by_target.items()):
        diag = [x["_diag"] for x in items]
        ratios = [d["target_script_ratio"] for d in diag
                  if d["target_script_ratio"] is not None]
        per_target_language[lang] = {
            "n": len(items),
            "non_empty": sum(1 for d in diag if d["non_empty"]),
            "no_error": sum(1 for d in diag if d["no_error"]),
            "degenerate": sum(1 for d in diag if d["looks_degenerate"]),
            "with_replacement_char": sum(1 for d in diag if d["replacement_chars"] > 0),
            "truncation_markers_only": sum(1 for d in diag if d["truncation_marker"]),
            "avg_max_run_ratio": round(sum(d["max_run_ratio"] for d in diag) / len(diag), 4),
            "avg_repeated_bigram_ratio": round(
                sum(d["repeated_bigram_ratio"] for d in diag) / len(diag), 4),
            "avg_target_script_ratio": round(sum(ratios) / len(ratios), 4) if ratios else None,
            "avg_wall_ms": round(sum(x["wall_ms"] for x in items) / len(items), 1),
        }

    # ---- 低资源语言专项：只报告可观测现象 ----
    low_resource = {}
    for lang in LOW_RESOURCE:
        items = by_target.get(lang, [])
        diag = [x["_diag"] for x in items]
        ratios = [d["target_script_ratio"] for d in diag
                  if d["target_script_ratio"] is not None]
        samples = [
            {"direction": f"{x['source_lang']}->{x['target_lang']}",
             "hypothesis": (x.get("hypothesis") or "")[:100],
             "max_run_ratio": x["_diag"]["max_run_ratio"],
             "repeated_bigram_ratio": x["_diag"]["repeated_bigram_ratio"],
             "replacement_chars": x["_diag"]["replacement_chars"]}
            for x in items if x["_diag"]["looks_degenerate"]
        ][:10]
        low_resource[lang] = {
            "directions_as_target": len(items),
            "non_empty": sum(1 for d in diag if d["non_empty"]),
            "degenerate": sum(1 for d in diag if d["looks_degenerate"]),
            "with_replacement_char": sum(1 for d in diag if d["replacement_chars"] > 0),
            "avg_target_script_ratio": round(sum(ratios) / len(ratios), 4) if ratios else None,
            "degenerate_examples": samples,
            "interpretation": "仅报告可观测的重复串 / 替换字符 / 目标文字占比；不臆测模型内部成因。",
        }

    degenerate_directions = [
        f"{r['source_lang']}->{r['target_lang']}" for r in rows
        if r["_diag"]["looks_degenerate"]
    ]

    result = {
        "tool": "sacrebleu 2.6.0 (仅 64 个有参考方向) + 自研可译性诊断；Python 仅离线分析",
        "hypothesis_file": str(HYP.relative_to(ROOT)),
        "backend": rows[0].get("backend", "unknown") if rows else "unknown",
        "sampling_mode": rows[0].get("sampling_mode", "unknown") if rows else "unknown",
        "request_level_reproducible": bool(rows and rows[0].get("request_level_reproducible")),
        "total_rows": len(rows),
        "expected_directions": manifest.get("total_directions", 1260),
        "directions_observed": len({f"{r['source_lang']}->{r['target_lang']}" for r in rows}),
        "directions_with_reference": len(scored),
        "directions_smoke_only": len(smoke),
        "overall_scored": overall,
        "directions_with_reference_scores": direction_scores,
        "coverage_smoke": smoke_stats,
        "per_target_language": per_target_language,
        "low_resource_diagnosis": low_resource,
        "degenerate_direction_count": len(degenerate_directions),
        "degenerate_directions_first_60": degenerate_directions[:60],
        "total_wall_ms": round(sum(r["wall_ms"] for r in rows), 1),
        "avg_wall_ms": round(sum(r["wall_ms"] for r in rows) / len(rows), 1) if rows else 0,
        "caveats": [
            "1196 个方向无权威平行参考译文，只做可译性冒烟，不产出任何质量分数；不得据此声称这些方向的翻译质量。",
            "64 个 en 枢轴方向每方向仅 1 条样本，BLEU/chrF2 不稳定，只作回归信号，不是 WMT/FLORES 排行榜。",
            "prompt 只含目标语言名、不含源语言名；非 en 枢轴方向的源句为真实语料锚句或英文代理句。",
            "tl/bo/mn 无 OPUS-100 平行语料；作为源语言时使用英文代理锚句，已在 manifest 标注 anchor_is_proxy。",
            "低资源语言专项只报告可观测现象（重复串 / 替换字符 / 目标文字占比），不臆测成因。",
            "流式解码修复后，尾部单个 U+FFFD 是 StreamingTextDecoder.finish() 对 maxTokens "
            "截断切到多字节字符的如实标注，单列 truncation_marker，不计入 looks_degenerate。",
            "评测为 greedy 解码、每请求按 seed 重建采样器，请求级可复现。",
            "本轮 1260 评测与 OPUS 259 条复跑、COMET 模型下载/打分并发执行，wall_ms 含 CPU/GPU 争抢，"
            "仅作粗略耗时参考、不是独立性能基准；纯推理性能以 Reports/h1-optimization-bench.json 为准。",
        ],
    }
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"COVERAGE_SCORE_OK rows={len(rows)} directions={result['directions_observed']} "
          f"scored={len(scored)} smoke={len(smoke)} "
          f"smoke_non_empty={smoke_stats['non_empty']} "
          f"degenerate={result['degenerate_direction_count']}")
    if overall:
        print(f"  scored_only overall_bleu={overall['bleu']} chrf2={overall['chrf2']}")
    for lang in LOW_RESOURCE:
        d = low_resource[lang]
        print(f"  low_resource {lang}: non_empty={d['non_empty']}/{d['directions_as_target']} "
              f"degenerate={d['degenerate']} script_ratio={d['avg_target_script_ratio']}")
    try:
        shown = str(OUT.relative_to(ROOT))
    except ValueError:
        shown = str(OUT)
    print(f"WROTE {shown}")


if __name__ == "__main__":
    main()
