#!/usr/bin/env python3
"""离线生成 GGUF / STQ1_0 / Q6_K 反量化 golden（G1 / G3 阶段）。

⚠️ 这份 Python 实现**独立于** Sources/HymnSTQ/*.swift：两者都照抄 llama.cpp
PR #22836 与 ggml-quants.c 的权威公式，但代码路径互不引用，用于交叉验证。
Python 仅用于离线生成 Golden/，**绝不进入运行时**。

用法：
    python3 Scripts/gen-gguf-golden.py [GGUF路径]
输出：
    Golden/gguf-golden-manifest.json
    Golden/gguf-<slug>.f32
"""
import hashlib
import json
import math
import os
import struct
import sys
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GGUF = ROOT / "Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf"
GOLDEN = ROOT / "Golden"

# PR #22836 stq1_0_codebook[32]
CODEBOOK = [
    0xA9, 0x89, 0x29, 0x09, 0xA6, 0x86, 0x26, 0x06,
    0x9A, 0x92, 0x1A, 0x12, 0x6A, 0x62, 0x4A, 0x42,
    0x01, 0x21, 0x81, 0xA1, 0x04, 0x24, 0x84, 0xA4,
    0x10, 0x18, 0x90, 0x98, 0x40, 0x48, 0x60, 0x68,
]

SAMPLES = [
    ("blk.0.attn_q.weight", 42, 8),
    ("blk.0.attn_k.weight", 42, 4),
    ("blk.7.ffn_gate.weight", 42, 4),
    ("blk.31.ffn_down.weight", 42, 4),
    ("token_embd.weight", 14, 4),
]


def fp16_to_float(h: int) -> float:
    sign = -1.0 if (h & 0x8000) else 1.0
    e = (h >> 10) & 0x1F
    m = h & 0x03FF
    if e == 0:
        return sign * m * (2.0 ** -24)
    if e == 31:
        return sign * math.inf if m == 0 else math.nan
    return sign * (1024 + m) * (2.0 ** (e - 25))


class Reader:
    def __init__(self, buf):
        self.b = buf
        self.o = 4

    def u32(self):
        v = struct.unpack_from("<I", self.b, self.o)[0]
        self.o += 4
        return v

    def u64(self):
        v = struct.unpack_from("<Q", self.b, self.o)[0]
        self.o += 8
        return v

    def string(self):
        n = self.u64()
        v = self.b[self.o:self.o + n].decode("utf-8", "replace")
        self.o += n
        return v

    def value(self, t):
        if t == 0:
            v = self.b[self.o]; self.o += 1; return v
        if t == 1:
            v = struct.unpack_from("<b", self.b, self.o)[0]; self.o += 1; return v
        if t == 2:
            v = struct.unpack_from("<H", self.b, self.o)[0]; self.o += 2; return v
        if t == 3:
            v = struct.unpack_from("<h", self.b, self.o)[0]; self.o += 2; return v
        if t == 4:
            return self.u32()
        if t == 5:
            v = struct.unpack_from("<i", self.b, self.o)[0]; self.o += 4; return v
        if t == 6:
            v = struct.unpack_from("<f", self.b, self.o)[0]; self.o += 4; return v
        if t == 7:
            v = self.b[self.o]; self.o += 1; return bool(v)
        if t == 8:
            return self.string()
        if t == 9:
            et = self.u32()
            n = self.u64()
            for _ in range(n):
                self.value(et)
            return ("array", et, n)
        if t == 10:
            return self.u64()
        if t == 11:
            v = struct.unpack_from("<q", self.b, self.o)[0]; self.o += 8; return v
        if t == 12:
            v = struct.unpack_from("<d", self.b, self.o)[0]; self.o += 8; return v
        raise ValueError(f"unsupported metadata type {t}")


def parse(path: Path):
    with open(path, "rb") as f:
        buf = f.read()  # 440 MB，仅离线脚本使用
    assert buf[:4] == b"GGUF", buf[:4]
    r = Reader(buf)
    version = r.u32()
    n_tensors = r.u64()
    n_kv = r.u64()
    metadata = {}
    for _ in range(n_kv):
        k = r.string()
        t = r.u32()
        metadata[k] = r.value(t)
    tensors = {}
    for _ in range(n_tensors):
        name = r.string()
        nd = r.u32()
        dims = [r.u64() for _ in range(nd)]
        typ = r.u32()
        off = r.u64()
        tensors[name] = (dims, typ, off)
    alignment = int(metadata.get("general.alignment", 32))
    data_start = ((r.o + alignment - 1) // alignment) * alignment
    return buf, version, metadata, tensors, data_start


def dequant_stq1_0(buf, start, blocks):
    out = [0.0] * (blocks * 256)
    for b in range(blocks):
        base = start + b * 42
        d = fp16_to_float(struct.unpack_from("<H", buf, base + 40)[0])
        for g in range(64):
            code = (buf[base + g // 2] >> (4 * (g & 1))) & 0x0F
            sign = (buf[base + 32 + g // 8] >> (g % 8)) & 0x01
            qpack = CODEBOOK[(sign << 4) | code]
            row = (g // 16) * 64 + (g % 16)
            for p in range(4):
                q = (qpack >> (2 * p)) & 3
                out[b * 256 + row + p * 16] = (q - 1) * d
    return out


def dequant_q6_K(buf, start, blocks):
    out = [0.0] * (blocks * 256)
    for b in range(blocks):
        base = start + b * 210
        d = fp16_to_float(struct.unpack_from("<H", buf, base + 208)[0])
        ql, qh, sc = base, base + 128, base + 192
        y0 = b * 256
        for half in range(2):
            ql_off, qh_off, sc_off = ql + half * 64, qh + half * 32, sc + half * 8
            y = y0 + half * 128
            for l in range(32):
                isx = l // 16
                qhl = buf[qh_off + l]
                q1 = ((buf[ql_off + l] & 0x0F) | (((qhl >> 0) & 3) << 4)) - 32
                q2 = ((buf[ql_off + l + 32] & 0x0F) | (((qhl >> 2) & 3) << 4)) - 32
                q3 = ((buf[ql_off + l] >> 4) | (((qhl >> 4) & 3) << 4)) - 32
                q4 = ((buf[ql_off + l + 32] >> 4) | (((qhl >> 6) & 3) << 4)) - 32
                s0 = struct.unpack_from("<b", buf, sc_off + isx + 0)[0]
                s2 = struct.unpack_from("<b", buf, sc_off + isx + 2)[0]
                s4 = struct.unpack_from("<b", buf, sc_off + isx + 4)[0]
                s6 = struct.unpack_from("<b", buf, sc_off + isx + 6)[0]
                out[y + l] = d * s0 * q1
                out[y + l + 32] = d * s2 * q2
                out[y + l + 64] = d * s4 * q3
                out[y + l + 96] = d * s6 * q4
    return out


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_GGUF
    if not path.is_file():
        raise SystemExit(f"GGUF 不存在: {path}")
    if not GOLDEN.is_dir():
        GOLDEN.mkdir(parents=True)

    sha = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            sha.update(chunk)

    buf, version, metadata, tensors, data_start = parse(path)
    hist = {}
    for _, (_, typ, _) in tensors.items():
        hist[str(typ)] = hist.get(str(typ), 0) + 1

    samples = []
    for name, expected_type, blocks in SAMPLES:
        dims, typ, off = tensors[name]
        assert typ == expected_type, (name, typ)
        block_bytes = 42 if typ == 42 else 210
        start = data_start + off
        vals = (dequant_stq1_0 if typ == 42 else dequant_q6_K)(buf, start, blocks)
        slug = name.replace(".", "-")
        fname = f"gguf-{slug}.f32"
        arr = array("f", vals)
        with open(GOLDEN / fname, "wb") as f:
            arr.tofile(f)
        samples.append({
            "tensor": name, "type": typ, "blocks": blocks,
            "elements": len(vals), "bytes": len(vals) * 4,
            "file": fname, "first8": vals[:8],
        })
        print(f"  {name:<28} type={typ} blocks={blocks} -> {fname} ({len(vals)} floats)")

    manifest = {
        "source": "AngelSlim/Hy-MT2-1.8B-1.25Bit-GGUF / Hy-MT2-1.8B-1.25Bit.gguf",
        "sha256": sha.hexdigest(),
        "file_bytes": os.path.getsize(path),
        "gguf_version": version,
        "tensor_count": len(tensors),
        "metadata_count": len(metadata),
        "type_histogram": hist,
        "data_start": data_start,
        "reference": "llama.cpp PR #22836 dequantize_row_stq1_0 + ggml-quants.c dequantize_row_q6_K",
        "note": "Python 独立实现，仅离线生成 Golden/，绝不进入运行时",
        "samples": samples,
    }
    with open(GOLDEN / "gguf-golden-manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(f"\nGGUF_GOLDEN_OK sha256={sha.hexdigest()} tensors={len(tensors)} "
          f"version={version} hist={hist} samples={len(samples)}")


if __name__ == "__main__":
    main()
