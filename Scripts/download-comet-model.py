#!/usr/bin/env python3
"""分段并发下载 COMET 官方评测模型 ckpt（仅离线评测工具链，不进 App 运行时）。

服务端 hf-mirror.com → cas-bridge 支持 HTTP Range（实测 206）。单连接约 200 KB/s，
2.32 GB 需数小时；本脚本用多线程分段下载以缩短等待，并支持断点续传
（已完成的 .part 文件直接跳过）。

只搬运官方 Unbabel/wmt22-comet-da 的原始字节，不改动、不生成任何模型权重，
也**不产生任何评测分数**；打分由 Scripts/score-comet.py 真实推理完成。
"""
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST_DIR = ROOT / "Eval" / "comet-model" / "checkpoints"
DEST = DEST_DIR / "model.ckpt"
PARTS_DIR = ROOT / "Eval" / "comet-model" / ".parts"
URL = "https://hf-mirror.com/Unbabel/wmt22-comet-da/resolve/main/checkpoints/model.ckpt"
TOTAL = 2_323_649_073  # 服务端 Content-Length，实测
CHUNK = 16 * 1024 * 1024
WORKERS = 12
RETRIES = 3


def fetch_part(i: int, start: int, end: int) -> tuple:
    part = PARTS_DIR / f"part-{i:04d}"
    want = end - start + 1
    if part.exists() and part.stat().st_size == want:
        return i, want, True
    last = None
    for attempt in range(RETRIES):
        try:
            req = urllib.request.Request(URL, headers={
                "Range": f"bytes={start}-{end}",
                "User-Agent": "HymnTranslate-COMET-Downloader/1.0",
            })
            with urllib.request.urlopen(req, timeout=180) as r:
                data = r.read()
            if len(data) != want:
                raise ValueError(f"part {i}: got {len(data)} want {want} (status={r.status})")
            tmp = part.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(part)
            return i, want, False
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"part {i} failed after {RETRIES} tries: {last}")


def main() -> None:
    DEST_DIR.mkdir(parents=True, exist_ok=True)
    PARTS_DIR.mkdir(parents=True, exist_ok=True)
    ranges = []
    start = 0
    i = 0
    while start < TOTAL:
        end = min(start + CHUNK - 1, TOTAL - 1)
        ranges.append((i, start, end))
        start = end + 1
        i += 1
    print(f"COMET_DL_START total={TOTAL} parts={len(ranges)} chunk={CHUNK} workers={WORKERS}",
          flush=True)
    t0 = time.time()
    done = 0
    cached = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(fetch_part, *r): r[0] for r in ranges}
        for fut in as_completed(futures):
            idx, size, was_cached = fut.result()
            done += size
            if was_cached:
                cached += size
            if done % (CHUNK * 5) < CHUNK or done >= TOTAL:
                elapsed = time.time() - t0
                speed = (done - cached) / elapsed / 1024 if elapsed > 0 else 0
                print(f"COMET_DL_PROGRESS {done}/{TOTAL} ({100*done/TOTAL:.1f}%) "
                      f"speed={speed:.0f}KB/s elapsed={elapsed:.0f}s", flush=True)

    # 顺序拼接（校验总字节数）
    with DEST.open("wb") as out:
        for idx, _, _ in ranges:
            part = PARTS_DIR / f"part-{idx:04d}"
            out.write(part.read_bytes())
    size = DEST.stat().st_size
    print(f"COMET_DL_OK bytes={size} expected={TOTAL} match={size == TOTAL} "
          f"elapsed={time.time()-t0:.0f}s", flush=True)
    if size != TOTAL:
        raise SystemExit(2)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"COMET_DL_FAIL {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
