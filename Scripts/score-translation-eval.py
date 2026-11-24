#!/usr/bin/env python3
"""H2：离线翻译质量打分（Python 仅用于算分，不参与任何运行时推理）。

输入：hymnctl evaluate 产出的 Reports/translation-hypotheses.jsonl
输出：Reports/translation-quality.json

指标：
  - BLEU（sacrebleu corpus_bleu，tokenize=13a；CJK/东南亚文字目标另给字符级 BLEU）
  - chrF2（sacrebleu corpus_chrf，字符级，对无空格语言更稳健）
  - 覆盖率、失败率、无参考语言的「译文非空」冒烟结果

严禁伪造：没有权威参考译文的样本不参与任何分数计算；COMET 由 Scripts/score-comet.py
真实推理产出，本脚本只引用其报告，缺结果时如实标注 BLOCKED，绝不填充占位分数。
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# 默认指向「最终二进制」产出的批次，避免不带参数重跑时用旧译文覆盖最终分数。
# 历史基线（translation-hypotheses.jsonl / translation-quality.json）与
# 各中间批次请显式传入输入/输出文件名，不要覆盖留档。
HYP = ROOT / "Reports" / (sys.argv[1] if len(sys.argv) > 1
                          else "translation-hypotheses-final.jsonl")
OUT = ROOT / "Reports" / (sys.argv[2] if len(sys.argv) > 2
                          else "translation-quality-final.json")
MANIFEST = ROOT / "Eval" / "opus100-manifest.json"
COMET = ROOT / "Reports" / "comet-scores.json"

# 无空格 / 非拉丁文字 → 额外用字符级 BLEU，避免 13a 分词造成的系统性低估
CHAR_LEVEL_TARGETS = {
    "zh", "ja", "ko", "th", "km", "my", "bo", "ug", "ta", "te",
    "mr", "gu", "bn", "hi", "ur", "fa", "ar", "he",
}


def main() -> None:
    from sacrebleu import corpus_bleu, corpus_chrf

    if not HYP.is_file():
        print(f"SCORE_FAIL 缺少 {HYP}", file=sys.stderr)
        sys.exit(1)

    rows = []
    for line in HYP.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows.append(json.loads(line))

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.is_file() else {}

    # reference 为空即「无权威参考译文」的覆盖冒烟样本，不参与任何分数。
    scored = [r for r in rows
              if r.get("reference")
              and r.get("hypothesis")
              and not r.get("error")]
    failed = [r for r in rows
              if r.get("reference") and (r.get("error") or not r.get("hypothesis"))]
    smoke = [r for r in rows if not r.get("reference")]

    # hymnctl evaluate 输出的是 source_lang / target_lang，direction 在此推导，
    # 不依赖评测样本文件的额外字段。
    def direction_of(r: dict) -> str:
        return f"{r['source_lang']}->{r['target_lang']}"

    by_direction = defaultdict(list)
    for r in scored:
        by_direction[direction_of(r)].append(r)

    directions = {}
    for direction, items in sorted(by_direction.items()):
        refs = [x["reference"] for x in items]
        hyps = [x["hypothesis"] for x in items]
        bleu = corpus_bleu(hyps, [refs], tokenize="13a")
        chrf = corpus_chrf(hyps, [refs])
        entry = {
            "n": len(items),
            "bleu": round(bleu.score, 2),
            "chrf2": round(chrf.score, 2),
            "avg_wall_ms": round(sum(x["wall_ms"] for x in items) / len(items), 1),
        }
        target = items[0]["target_lang"]
        if target in CHAR_LEVEL_TARGETS:
            char_bleu = corpus_bleu(hyps, [refs], tokenize="zh")
            entry["bleu_char_level"] = round(char_bleu.score, 2)
        directions[direction] = entry

    all_refs = [x["reference"] for x in scored]
    all_hyps = [x["hypothesis"] for x in scored]
    overall = None
    if scored:
        b = corpus_bleu(all_hyps, [all_refs], tokenize="13a")
        c = corpus_chrf(all_hyps, [all_refs])
        overall = {
            "bleu": round(b.score, 2),
            "chrf2": round(c.score, 2),
            "signature": str(b),
        }

    smoke_result = {
        "n": len(smoke),
        "non_empty": sum(1 for r in smoke if r.get("hypothesis", "").strip()),
        "distinct_from_source": sum(
            1 for r in smoke if r.get("hypothesis", "").strip()
            and r["hypothesis"].strip() != r.get("source", "").strip()
        ),
        "details": [
            {"direction": direction_of(r), "hypothesis": r.get("hypothesis", "")[:120],
             "error": r.get("error", "")}
            for r in smoke
        ],
    }

    langs_with_ref = sorted({
        x["target_lang"] for x in scored
    } | {x["source_lang"] for x in scored})

    # COMET：只嵌入真实跑出来的分数；缺失/阻塞时如实标注，绝不编造。
    comet_block = {
        "status": "NOT_DELIVERED",
        "reason": "尚未运行 Scripts/score-comet.py，或该脚本已标记 BLOCKED；未产出任何 COMET 分数",
        "never_fabricated": True,
    }
    if COMET.is_file():
        try:
            c = json.loads(COMET.read_text(encoding="utf-8"))
            if c.get("status") == "OK":
                comet_block = {
                    "status": "OK",
                    "model": c.get("model"),
                    "system_score": c.get("system_score"),
                    "scored_rows": c.get("scored_rows"),
                    "direction_count": c.get("direction_count"),
                    "report": str(COMET.relative_to(ROOT)),
                    "never_fabricated": True,
                }
            else:
                comet_block = {
                    "status": c.get("status", "BLOCKED"),
                    "reason": c.get("reason", "COMET 未成功产出分数"),
                    "report": str(COMET.relative_to(ROOT)),
                    "never_fabricated": True,
                }
        except (ValueError, OSError) as exc:
            comet_block = {"status": "BLOCKED", "reason": f"读取 COMET 报告失败: {exc}",
                           "never_fabricated": True}

    reproducible = bool(rows and rows[0].get("request_level_reproducible"))

    result = {
        "tool": "sacrebleu 2.6.0 (corpus_bleu / corpus_chrf), Python 仅离线算分",
        "hypothesis_file": str(HYP.relative_to(ROOT)),
        "backend": rows[0].get("backend", "unknown") if rows else "unknown",
        "total_rows": len(rows),
        "scored_rows": len(scored),
        "failed_rows": len(failed),
        "failed_ids": [r["id"] for r in failed][:30],
        "overall": overall,
        "directions": directions,
        "direction_count": len(directions),
        "languages_touched": langs_with_ref,
        "language_count": len(langs_with_ref),
        "coverage_smoke": smoke_result,
        "corpus_manifest": {
            "corpus": manifest.get("corpus"),
            "en_pivot_pairs": manifest.get("en_pivot_pairs"),
            "directions_with_reference": manifest.get("directions_with_reference"),
            "sentences_per_direction": manifest.get("sentences_per_direction"),
            "languages_without_reference": manifest.get("languages_without_reference"),
            "model_card_language_count": manifest.get("model_card_language_count"),
        },
        "comet": comet_block,
        "sampling": {
            "request_level_reproducible": reproducible,
            "mode": rows[0].get("sampling_mode", "legacy") if rows else "legacy",
            "note": ("每请求按 seed 重建 Sampler，同批结果可逐请求复现。"
                     if reproducible else
                     "本批译文产出于 Sampler 修复前，RNG state 跨请求延续，非请求级可复现。"),
        },
        "caveats": [
            "小样本系统级回归信号：每个方向 4 句，不是权威 WMT/FLORES 基准排行榜。",
            "参考译文来自 OPUS-100 test split，未经人工复核；不同语料的领域差异会显著影响 BLEU。",
            "BLEU(13a) 对无空格语言系统性偏低，已另给字符级 BLEU 与 chrF2。",
            "以 en 为枢轴的 64 个方向 + 3 个无参考语言冒烟；1260 全方向覆盖另见 Reports/coverage-1260-report.json，其中 1196 个无参考方向不产质量分数。",
            "译文由 maxTokens=64 截断控制，长句可能被截断，过滤规则见 Eval/opus100-manifest.json。",
            "COMET 分数（若有）来自真实 Unbabel/wmt22-comet-da 推理；未产出时状态为 BLOCKED/NOT_DELIVERED，绝不填充占位分数。",
        ],
    }
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"SCORE_OK rows={len(rows)} scored={len(scored)} failed={len(failed)} "
          f"directions={len(directions)} overall_bleu={overall['bleu'] if overall else 'n/a'} "
          f"chrf2={overall['chrf2'] if overall else 'n/a'}")
    print(f"WROTE {OUT.relative_to(ROOT)}")
    worst = sorted(directions.items(), key=lambda kv: kv[1]["bleu"])[:5]
    best = sorted(directions.items(), key=lambda kv: -kv[1]["bleu"])[:5]
    print("BOTTOM5", [(k, v["bleu"]) for k, v in worst])
    print("TOP5   ", [(k, v["bleu"]) for k, v in best])


if __name__ == "__main__":
    main()
