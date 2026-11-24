#!/usr/bin/env python3
"""H3：COMET 系统级翻译质量评测（Python 仅离线打分，不参与运行时推理）。

输入：hymnctl evaluate 产出的 JSONL（默认 Reports/translation-hypotheses-final.jsonl，对应最终二进制）
输出：Reports/comet-scores.json

严格口径：
  · 只有真实存在的 source / hypothesis / reference 三元组才送入 COMET。
  · 只有成功加载 Unbabel/wmt22-comet-da 并真实跑完 predict 才写 status=OK + 分数。
  · 环境/模型不可得时写 status=BLOCKED + 具体原因，never_fabricated=true，
    **绝不编造任何 COMET 分数**。
  · 评测模型约 2.32 GB，通过 HF_ENDPOINT=hf-mirror.com 下载，仅用于离线评测。
"""
import json
import os
import sys
import traceback
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# 默认对应最终二进制批次；修复前批次需显式传参，避免覆盖 comet-scores.json。
HYP = ROOT / "Reports" / (sys.argv[1] if len(sys.argv) > 1
                          else "translation-hypotheses-final.jsonl")
OUT = ROOT / "Reports" / "comet-scores.json"
MODEL = "Unbabel/wmt22-comet-da"
# 官方 ckpt 在 HF 仓库的实测大小（Content-Length: 2323649073）。
LOCAL_CKPT = ROOT / "Eval" / "comet-model" / "checkpoints" / "model.ckpt"
LOCAL_HPARAMS = ROOT / "Eval" / "comet-model" / "hparams.yaml"
EXPECTED_BYTES = 2_323_649_073


def main() -> None:
    if not HYP.is_file():
        print(f"COMET_FAIL 缺少 {HYP}", file=sys.stderr)
        sys.exit(1)

    rows = [json.loads(line) for line in HYP.read_text(encoding="utf-8").splitlines()
            if line.strip()]
    scored = [r for r in rows
              if r.get("reference") and r.get("hypothesis") and not r.get("error")]

    base = {
        "tool": "unbabel-comet (Unbabel/wmt22-comet-da)",
        "model": MODEL,
        "hypothesis_file": str(HYP.relative_to(ROOT)),
        "total_rows": len(rows),
        "eligible_rows": len(scored),
        "status": "BLOCKED",
        "never_fabricated": True,
        "note": "COMET 只在真实加载评测模型并跑完 predict 后产出分数；失败时绝不填充占位分数。",
    }

    # 评测模型走镜像，避免直连 HF 不稳定；不影响 App 运行时（运行时全程离线）。
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "0")

    try:
        from comet import download_model, load_from_checkpoint
        print(f"COMET_LOADING {MODEL} ...", flush=True)
        # 优先复用本地分段下载并校验过字节数的官方 ckpt，避免重复下载 2.32 GB。
        if LOCAL_CKPT.is_file():
            actual = LOCAL_CKPT.stat().st_size
            if actual != EXPECTED_BYTES:
                raise RuntimeError(
                    f"本地 ckpt 不完整: {actual}/{EXPECTED_BYTES} B，"
                    "请继续运行 Scripts/download-comet-model.py 后再打分；不使用残缺模型")
            model_path = str(LOCAL_CKPT)
            model_source = "local分段下载(字节数校验通过)"
        else:
            model_path = download_model(MODEL)
            model_source = "huggingface_hub"
        # unbabel-comet 2.2.x 的 load_from_checkpoint 需要同父目录的 hparams.yaml；
        # 本地布局 Eval/comet-model/{hparams.yaml,checkpoints/model.ckpt} 与 HF 快照一致。
        if LOCAL_HPARAMS.is_file():
            os.environ.setdefault("COMET_MODEL_DIR", str(LOCAL_CKPT.parent.parent))
        try:
            model = load_from_checkpoint(model_path, reload_hparams=True)
        except TypeError:
            model = load_from_checkpoint(model_path)
        print(f"COMET_MODEL_SOURCE={model_source}", flush=True)
        data = [
            {"src": r["source"], "mt": r["hypothesis"], "ref": r["reference"]}
            for r in scored
        ]
        print(f"COMET_PREDICT rows={len(data)} batch_size=8 ...", flush=True)
        # 不同 unbabel-comet / pytorch-lightning 版本的 predict 参数名不一致
        # （gpus=0 / devices=... / 仅 batch_size），逐个尝试，全部真实执行。
        last_predict_error = None
        output = None
        for kwargs in (
            {"batch_size": 8, "gpus": 0},
            {"batch_size": 8, "devices": 1, "accelerator": "cpu"},
            {"batch_size": 8},
        ):
            try:
                output = model.predict(data, **kwargs)
                print(f"COMET_PREDICT_KWARGS={kwargs}", flush=True)
                break
            except Exception as exc:  # noqa: BLE001
                last_predict_error = exc
                print(f"COMET_PREDICT_RETRY {type(exc).__name__}: {exc}", flush=True)
        if output is None:
            raise RuntimeError(f"predict 全部参数组合失败: {last_predict_error}")
        scores = [float(s) for s in output.scores]

        by_direction = defaultdict(list)
        for r, s in zip(scored, scores):
            by_direction[f"{r['source_lang']}->{r['target_lang']}"].append(s)
        direction_scores = {
            d: {"n": len(v), "comet": round(sum(v) / len(v), 4)}
            for d, v in sorted(by_direction.items())
        }

        result = {
            **base,
            "status": "OK",
            "model_source": model_source,
            "checkpoint_bytes": EXPECTED_BYTES if model_source != "huggingface_hub" else None,
            "system_score": round(float(output.system_score), 4),
            "mean_score": round(sum(scores) / len(scores), 4),
            "min_score": round(min(scores), 4),
            "max_score": round(max(scores), 4),
            "scored_rows": len(scores),
            "direction_count": len(direction_scores),
            "directions": direction_scores,
            "sampling_mode": scored[0].get("sampling_mode", "unknown") if scored else "unknown",
            "request_level_reproducible": bool(
                scored and scored[0].get("request_level_reproducible")),
            "caveats": [
                "wmt22-comet-da 训练于 WMT22 新闻领域，对 OPUS-100 领域与低资源语言的分数需谨慎解读。",
                "COMET 是神经评测模型给出的估计值，不等于人工评价；不得与 BLEU/chrF2 直接换算或比较绝对值。",
                "分数只覆盖有权威参考译文的样本，无参考方向不参与打分。",
                "每方向样本数少（本批为小样本回归信号），不是 WMT/FLORES 排行榜。",
            ],
        }
    except Exception as exc:  # noqa: BLE001
        result = {
            **base,
            "status": "BLOCKED",
            "reason": f"{type(exc).__name__}: {exc}",
            "traceback_tail": traceback.format_exc()[-1500:],
            "caveats": [
                "未产出任何 COMET 分数；本文件只记录阻塞原因，不代表翻译质量为 0 或任意数值。",
            ],
        }

    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"COMET_STATUS={result['status']} eligible={len(scored)}")
    if result["status"] == "OK":
        print(f"  system_score={result['system_score']} mean={result['mean_score']} "
              f"directions={result['direction_count']}")
    else:
        print(f"  reason={result.get('reason')}")
    print(f"WROTE {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
