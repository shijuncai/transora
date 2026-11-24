#!/usr/bin/env python3
"""H4：构建 36 语言 1260 全方向覆盖评测样本（离线工具链，不进 App 运行时）。

诚实口径（严禁伪造）：
  · 36×35=1260 个方向全部生成样本并交给真实后端翻译。
  · 只有 OPUS-100 en 枢轴的 64 个方向有权威平行参考译文，可算 BLEU/chrF2。
  · 其余 1196 个方向**没有**参考译文，只做可译性冒烟（非空 / 与源不同 / 不崩溃 /
    重复字符与替换字符诊断），绝不产出或推断任何质量分数。
  · 源句锚点取自已落盘的 Eval/opus100-samples.jsonl 真实语料；
    OPUS-100 未覆盖的语言没有母语真实文本，用英文代理句并显式标注 anchor_is_proxy。
  · 本脚本不联网、不生成参考译文、不修改任何平行语料。
"""
import json
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Eval" / "opus100-samples.jsonl"
OUT = ROOT / "Eval" / "coverage-1260-samples.jsonl"
MANIFEST = ROOT / "Eval" / "coverage-1260-manifest.json"

# 模型卡 36 语言（与 LanguageCatalog.swift / fetch-eval-data.py 完全一致）
MODEL_LANGS = (
    "zh en fr pt es ja tr ru ar ko th it de vi ms id tl hi pl cs nl km my fa gu "
    "ur te mr he bn ta uk bo kk mn ug"
).split()

PROXY_SENTENCE = "Machine learning is changing the world."


def main() -> None:
    if not SRC.is_file():
        print(f"COVERAGE_BUILD_FAIL 缺少 {SRC}", flush=True)
        raise SystemExit(1)
    rows = [json.loads(line) for line in SRC.read_text(encoding="utf-8").splitlines()
            if line.strip()]
    with_ref = [r for r in rows if r.get("reference")]

    # 有权威参考译文的方向：每方向取第一条（该方向原有 4 条平行句）
    ref_by_dir = {}
    for r in with_ref:
        key = f"{r['source_lang']}->{r['target_lang']}"
        ref_by_dir.setdefault(key, r)

    # 每种语言的真实锚句：取该语言作为源语言的第一条长度合适的真实句子
    anchors = {}
    for r in with_ref:
        lang = r["source_lang"]
        sentence = r["source"].strip()
        if lang not in anchors and 20 <= len(sentence) <= 110:
            anchors[lang] = sentence
    proxy_langs = [lang for lang in MODEL_LANGS if lang not in anchors]

    samples = []
    for src in MODEL_LANGS:
        for tgt in MODEL_LANGS:
            if src == tgt:
                continue
            direction = f"{src}->{tgt}"
            if direction in ref_by_dir:
                r = ref_by_dir[direction]
                samples.append({
                    "id": f"cov-{src}-{tgt}",
                    "source_lang": src,
                    "target_lang": tgt,
                    "source": r["source"],
                    "reference": r["reference"],
                    "has_reference": True,
                    "anchor_is_proxy": False,
                    "corpus": "Helsinki-NLP/opus-100:test",
                    "direction": direction,
                })
            else:
                samples.append({
                    "id": f"cov-{src}-{tgt}",
                    "source_lang": src,
                    "target_lang": tgt,
                    "source": anchors.get(src, PROXY_SENTENCE),
                    "reference": "",
                    "has_reference": False,
                    "anchor_is_proxy": src not in anchors,
                    "corpus": "none (coverage smoke only)",
                    "direction": direction,
                })

    with OUT.open("w", encoding="utf-8") as f:
        for s in samples:
            f.write(json.dumps(s, ensure_ascii=False, sort_keys=True) + "\n")

    n_ref = sum(1 for s in samples if s["has_reference"])
    n_smoke = len(samples) - n_ref
    n_proxy = sum(1 for s in samples if s["anchor_is_proxy"])
    manifest = {
        "created": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "model_card_languages": MODEL_LANGS,
        "model_card_language_count": len(MODEL_LANGS),
        "total_directions": len(MODEL_LANGS) * (len(MODEL_LANGS) - 1),
        "total_samples": len(samples),
        "directions_with_reference": n_ref,
        "directions_smoke_only": n_smoke,
        "reference_corpus": "Helsinki-NLP/opus-100 test split（已落盘 Eval/opus100-samples.jsonl，未修改）",
        "real_anchor_languages": len(anchors),
        "proxy_anchor_languages": proxy_langs,
        "proxy_sentence": PROXY_SENTENCE,
        "samples_using_proxy_source": n_proxy,
        "per_language_anchor": anchors,
        "important_caveat": (
            f"{n_smoke} 个方向没有权威平行参考译文，只做可译性冒烟，"
            "不产出任何 BLEU/COMET/chrF 等质量分数，也不得据此声称这些方向的翻译质量。"
            f"仅 {n_ref} 个 en 枢轴方向有参考译文并可打分。"
            "使用英文代理源句的方向只验证目标语言生成能力，不代表该源语言的真实输入。"
        ),
        "output": str(OUT.relative_to(ROOT)),
    }
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"COVERAGE_BUILD_OK directions={len(samples)} with_reference={n_ref} "
          f"smoke_only={n_smoke} real_anchors={len(anchors)} proxy_langs={proxy_langs} "
          f"proxy_samples={n_proxy}", flush=True)
    print(f"WROTE {OUT.relative_to(ROOT)}", flush=True)
    print(f"WROTE {MANIFEST.relative_to(ROOT)}", flush=True)


if __name__ == "__main__":
    main()
