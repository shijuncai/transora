#!/usr/bin/env python3
"""H2：从公开权威平行语料抽取评测样本（离线工具链，不进 App 运行时）。

数据源：Helsinki-NLP/opus-100 的 test split（Apache 授权、非 gated、可匿名下载）。
FLORES-200 官方仓库为 GatedRepo（403），因此改用 OPUS-100；绝不自行编造参考译文。

产出：
  Eval/opus100-samples.jsonl      每行一条评测样本（含真实 reference）
  Eval/opus100-manifest.json      语料来源、方向覆盖、过滤规则、缺失语言说明

对模型卡 36 种语言中 OPUS-100 没有平行语料的 3 种（tl/bo/mn），
只生成 `has_reference=false` 的「译文非空」覆盖冒烟样本，不参与 BLEU 打分。
"""
import hashlib
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVAL = ROOT / "Eval"
CACHE = EVAL / "parquet"
OUT = EVAL / "opus100-samples.jsonl"
MANIFEST = EVAL / "opus100-manifest.json"
BASE = "https://hf-mirror.com/datasets/Helsinki-NLP/opus-100/resolve/main/{pair}/test-00000-of-00001.parquet"
API = "https://hf-mirror.com/api/datasets/Helsinki-NLP/opus-100"

# 模型卡 tencent/Hy-MT2-1.8B 的 language: 字段（2026-11-21 实证）
MODEL_LANGS = (
    "zh en fr pt es ja tr ru ar ko th it de vi ms id tl hi pl cs nl km my fa gu "
    "ur te mr he bn ta uk bo kk mn ug"
).split()

SENTENCES_PER_DIRECTION = 4
MIN_SRC, MAX_SRC = 20, 110
MIN_REF, MAX_REF = 10, 200


def fetch(url: str, dest: Path, tries: int = 3) -> bytes:
    if dest.exists() and dest.stat().st_size > 1024:
        return dest.read_bytes()
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "HymnTranslate-Eval/1.0"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if data[:4] != b"PAR1":
                raise ValueError(f"not parquet: {data[:16]!r}")
            dest.write_bytes(data)
            return data
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.5 * (i + 1))
    raise RuntimeError(f"download failed {url}: {last}")


def clean(s: str) -> str:
    return s.replace("\xa0", " ").replace("\r", " ").replace("\n", " ").strip()


def main() -> None:
    import pyarrow.parquet as pq

    # 注意：本执行环境的路径 shim 下 mkdir(exist_ok=True) 对已存在目录会误抛
    # FileExistsError，因此改用 is_dir() 预检（与 gen-forward-golden.py 同样处理）。
    if not EVAL.is_dir():
        EVAL.mkdir(parents=True)
    if not CACHE.is_dir():
        CACHE.mkdir(parents=True)

    with urllib.request.urlopen(API, timeout=40) as r:
        api = json.load(r)
    pairs = sorted({
        s["rfilename"].split("/")[0]
        for s in api.get("siblings", [])
        if "/test-" in s["rfilename"] and s["rfilename"].endswith(".parquet")
    })
    # 以 en 为枢轴，且另一端属于模型卡语言
    pivots = []
    for pair in pairs:
        parts = pair.split("-")
        if len(parts) != 2 or "en" not in parts:
            continue
        other = parts[0] if parts[1] == "en" else parts[1]
        if other in MODEL_LANGS and other != "en":
            pivots.append((pair, other))
    pivots.sort(key=lambda x: x[1])
    covered = {x[1] for x in pivots}
    missing = [x for x in MODEL_LANGS if x != "en" and x not in covered]

    print(f"model_languages={len(MODEL_LANGS)} en_pivot_pairs={len(pivots)} "
          f"covered_non_en={len(covered)} missing={missing}", flush=True)

    samples = []
    per_pair = {}
    for pair, other in pivots:
        url = BASE.format(pair=pair)
        dest = CACHE / f"{pair}.parquet"
        data = fetch(url, dest)
        table = pq.read_table(dest)
        cols = table.schema.names
        # 结构列 translation: struct<l1, l2>
        struct_name = "translation" if "translation" in cols else cols[0]
        langs = [f.name for f in table.schema.field(struct_name).type]
        rows = table.column(struct_name).to_pylist()
        picked = []
        for row in rows:
            if len(picked) >= SENTENCES_PER_DIRECTION:
                break
            a, b = lang_a, lang_b = langs[0], langs[1]
            if not (a in MODEL_LANGS or a == "en") or not (b in MODEL_LANGS or b == "en"):
                continue
            # 两个方向各取同一组平行句，保证双向可比
            src_a, ref_b = clean(row.get(a, "") or ""), clean(row.get(b, "") or "")
            if not (MIN_SRC <= len(src_a) <= MAX_SRC and MIN_REF <= len(ref_b) <= MAX_REF):
                continue
            if not (MIN_SRC <= len(ref_b) <= MAX_SRC and MIN_REF <= len(src_a) <= MAX_REF):
                continue
            picked.append((a, b, src_a, ref_b))
        for idx, (a, b, src_a, ref_b) in enumerate(picked):
            samples.append({
                "id": f"{pair}-a{idx}", "corpus": "Helsinki-NLP/opus-100:test",
                "pair": pair, "source_lang": a, "target_lang": b,
                "source": src_a, "reference": ref_b,
                "has_reference": True, "direction": f"{a}->{b}",
            })
            samples.append({
                "id": f"{pair}-b{idx}", "corpus": "Helsinki-NLP/opus-100:test",
                "pair": pair, "source_lang": b, "target_lang": a,
                "source": ref_b, "reference": src_a,
                "has_reference": True, "direction": f"{b}->{a}",
            })
        per_pair[pair] = {
            "rows": table.num_rows, "picked": len(picked) * 2,
            "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data), "languages": langs,
        }
        print(f"  {pair:<8} rows={table.num_rows:>5} picked={len(picked)*2:>2} "
              f"sha={per_pair[pair]['sha256'][:12]}", flush=True)

    # 无权威参考译文的语言：只做「译文非空」覆盖冒烟，不参与 BLEU
    smoke_sentence = "Machine learning is changing the world."
    for lang in missing:
        samples.append({
            "id": f"smoke-en-{lang}", "corpus": "none",
            "pair": f"en-{lang}", "source_lang": "en", "target_lang": lang,
            "source": smoke_sentence, "reference": "",
            "has_reference": False, "direction": f"en->{lang}",
        })

    with OUT.open("w", encoding="utf-8") as f:
        for s in samples:
            f.write(json.dumps(s, ensure_ascii=False, sort_keys=True) + "\n")

    manifest = {
        "created": time.strftime("%Y-%m-%d %H:%M:%S %z"),
        "corpus": "Helsinki-NLP/opus-100 (test split)",
        "corpus_url": "https://huggingface.co/datasets/Helsinki-NLP/opus-100",
        "mirror": "hf-mirror.com",
        "license_note": "公开非 gated 数据集；FLORES-200 官方仓库为 GatedRepo(403)，故未使用",
        "model_card_languages": MODEL_LANGS,
        "model_card_language_count": len(MODEL_LANGS),
        "en_pivot_pairs": len(pivots),
        "directions_with_reference": len(pivots) * 2,
        "sentences_per_direction": SENTENCES_PER_DIRECTION,
        "filter": {"min_src_chars": MIN_SRC, "max_src_chars": MAX_SRC,
                   "min_ref_chars": MIN_REF, "max_ref_chars": MAX_REF,
                   "note": "过滤长句避免 maxTokens 截断污染 BLEU；不修改任何参考译文"},
        "languages_without_reference": missing,
        "coverage_smoke_samples": len(missing),
        "total_samples": len(samples),
        "important_caveat": (
            "这是以 en 为枢轴的 64 个方向 + 3 个无参考语言冒烟，"
            "不是 36x35=1260 个全语言对；未覆盖方向不声称做过质量评测。"
        ),
        "per_pair": per_pair,
        "output": str(OUT.relative_to(ROOT)),
    }
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"WROTE {OUT.relative_to(ROOT)} lines={len(samples)}", flush=True)
    print(f"WROTE {MANIFEST.relative_to(ROOT)}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"FETCH_EVAL_FAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
