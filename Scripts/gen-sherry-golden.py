#!/usr/bin/env python3
"""G4：生成常驻 STQ1_0 / Q6_K GEMV 与 32 层 forward 的离线 golden。

⚠️ Python 仅离线生成 Golden/，绝不进入运行时。
两份 golden 目的不同：
  1) sherry-gemv-manifest.json + *.f32：Python 直接从 GGUF 原始字节按 PR #22836 /
     ggml-quants.c 解码，验证 Swift Metal kernel 的「解码即乘加」是否逐元素一致；
  2) sherry-forward-manifest.json + *.f32：用已独立校验过的 fp16 展开缓存跑 32 层
     fp32 参考 forward，验证常驻模型把各层组装起来后的 logits / hidden 是否正确。
"""
import hashlib
import json
import math
import os
import struct
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
GGUF = ROOT / "Models/Hy-MT2-1.8B-1.25Bit-GGUF/Hy-MT2-1.8B-1.25Bit.gguf"
CACHE = ROOT / "Models/Hy-MT2-1.8B-1.25Bit-GGUF/weights.fp16.bin"
GOLDEN = ROOT / "Golden"

CODEBOOK = [
    0xA9, 0x89, 0x29, 0x09, 0xA6, 0x86, 0x26, 0x06,
    0x9A, 0x92, 0x1A, 0x12, 0x6A, 0x62, 0x4A, 0x42,
    0x01, 0x21, 0x81, 0xA1, 0x04, 0x24, 0x84, 0xA4,
    0x10, 0x18, 0x90, 0x98, 0x40, 0x48, 0x60, 0x68,
]

D = 128
HEADS = 16
KVH = 4
LAYERS = 32
HIDDEN = 2048
INTER = 6144
VOCAB = 120818
EPS = 1e-5
SCALE = D ** -0.5
ADJUSTED_BASE = 10000.0 * (1000.0 ** (D / (D - 2)))
FREQS = ADJUSTED_BASE ** (np.arange(0, D, 2, dtype=np.float64) / D)
PROMPT_IDS = [120000, 120006, 28036, 120007]


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
            return None
        if t == 10:
            return self.u64()
        if t == 11:
            v = struct.unpack_from("<q", self.b, self.o)[0]; self.o += 8; return v
        if t == 12:
            v = struct.unpack_from("<d", self.b, self.o)[0]; self.o += 8; return v
        raise ValueError(f"unsupported metadata type {t}")


def parse_gguf(buf):
    assert buf[:4] == b"GGUF", buf[:4]
    r = Reader(buf)
    version = r.u32()
    n_tensors = r.u64()
    n_kv = r.u64()
    for _ in range(n_kv):
        key = r.string()
        t = r.u32()
        r.value(t)
    tensors = {}
    for _ in range(n_tensors):
        name = r.string()
        nd = r.u32()
        dims = [r.u64() for _ in range(nd)]
        typ = r.u32()
        off = r.u64()
        tensors[name] = (dims, typ, off)
    alignment = 32
    data_start = ((r.o + alignment - 1) // alignment) * alignment
    return version, tensors, data_start


def fp16_to_float(h):
    sign = -1.0 if (h & 0x8000) else 1.0
    e = (h >> 10) & 0x1F
    m = h & 0x03FF
    if e == 0:
        return sign * m * (2.0 ** -24)
    if e == 31:
        return sign * math.inf if m == 0 else math.nan
    return sign * (1024 + m) * (2.0 ** (e - 25))


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


def decode_rows(buf, info, data_start, start_row, n_rows):
    dims, typ, off = info
    in_f = int(dims[0])
    bpr = in_f // 256
    vals = []
    for r in range(start_row, start_row + n_rows):
        b0 = r * bpr
        start = data_start + off + b0 * (42 if typ == 42 else 210)
        if typ == 42:
            vals.extend(dequant_stq1_0(buf, start, bpr))
        elif typ == 14:
            vals.extend(dequant_q6_K(buf, start, bpr))
        else:
            raise ValueError(f"unsupported type {typ}")
    arr = np.asarray(vals, dtype=np.float32).reshape(n_rows, in_f)
    # 与运行时一致：权重先舍入到 fp16，再以 fp32 参与乘加。
    return np.float16(arr).astype(np.float32)


def gemv_golden(buf, tensors, data_start):
    rng = np.random.default_rng(20261121)
    samples = []
    specs = [
        ("blk.0.attn_q.weight", 42, 32),
        ("blk.7.ffn_gate.weight", 42, 16),
        ("blk.31.ffn_down.weight", 42, 16),
        ("token_embd.weight", 14, 16),
    ]
    for name, expected_type, rows in specs:
        dims, typ, off = tensors[name]
        assert typ == expected_type, (name, typ)
        in_f = int(dims[0])
        W = decode_rows(buf, tensors[name], data_start, 0, rows)
        x = (rng.standard_normal(in_f).astype(np.float32) * 0.1)
        xh = np.float16(x).astype(np.float32)
        y = W @ xh
        yh = np.float16(y).astype(np.float32)
        slug = name.replace(".", "-")
        xf = f"sherry-gemv-{slug}-x.f32"
        yf = f"sherry-gemv-{slug}-y.f32"
        x.astype(np.float32).tofile(GOLDEN / xf)
        yh.astype(np.float32).tofile(GOLDEN / yf)
        samples.append({
            "tensor": name, "type": typ, "rows": rows,
            "in_features": in_f, "x_file": xf, "y_file": yf,
            "first8_y": [float(v) for v in yh[:8]],
            "y_min": float(yh.min()), "y_max": float(yh.max()),
        })
        print(f"  {name:<28} rows={rows} in={in_f} -> {yf}", flush=True)

    token_id = 120000
    emb = decode_rows(buf, tensors["token_embd.weight"], data_start,
                      token_id, 1)[0]
    emb_file = "sherry-embed-120000.f32"
    emb.astype(np.float32).tofile(GOLDEN / emb_file)
    manifest = {
        "purpose": "G4 常驻 STQ1_0/Q6_K Metal GEMV 独立 golden（离线校准）",
        "reference": "llama.cpp PR #22836 dequantize_row_stq1_0 + ggml-quants.c dequantize_row_q6_K",
        "note": "Python 直接从 GGUF 原始字节独立解码；仅离线生成 Golden，不进入运行时",
        "gguf": str(GGUF.relative_to(ROOT)),
        "gguf_bytes": os.path.getsize(GGUF),
        "data_start": data_start,
        "x_dtype": "fp32 输入，运行时转 fp16",
        "y_dtype": "fp32 保存 fp16 舍入后的期望值",
        "samples": samples,
        "embed": {
            "token_id": token_id,
            "file": emb_file,
            "first8": [float(v) for v in emb[:8]],
        },
    }
    (GOLDEN / "sherry-gemv-manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"GEMV_GOLDEN_OK samples={len(samples)}", flush=True)


def load_header(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        return json.loads(f.read(n))


class Weights:
    def __init__(self, path):
        self.header = load_header(path)
        self.mm = np.memmap(path, dtype=np.uint8, mode="r")
        self.table = {t["name"]: t for t in self.header["tensors"]}

    def get(self, name):
        t = self.table[name]
        arr = np.frombuffer(self.mm, dtype=np.float16,
                            count=t["byteCount"] // 2,
                            offset=self.header["dataStart"] + t["offset"])
        return arr.reshape(t["shape"]).astype(np.float32)


def rms_norm(x, w):
    return x * (1.0 / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + EPS)) * w


def rope(x, pos):
    ang = pos / FREQS
    c, s = np.cos(ang), np.sin(ang)
    a = x[..., :64].copy()
    b = x[..., 64:].copy()
    x[..., :64] = a * c - b * s
    x[..., 64:] = b * c + a * s
    return x


def attention(q, k_cache, v_cache):
    out = np.zeros(HIDDEN, dtype=np.float32)
    for h in range(HEADS):
        kv = h // (HEADS // KVH)
        qh = q[h * D:(h + 1) * D]
        kt = k_cache[:, kv * D:(kv + 1) * D]
        vt = v_cache[:, kv * D:(kv + 1) * D]
        scores = (kt @ qh) * SCALE
        scores -= scores.max()
        p = np.exp(scores)
        p /= p.sum()
        out[h * D:(h + 1) * D] = p @ vt
    return out


def forward_golden():
    w = Weights(CACHE)
    print(f"forward cache tensors={len(w.table)} dataBytes={w.header['dataBytes']}", flush=True)
    E = w.get("model.embed_tokens")
    k_caches = [[] for _ in range(LAYERS)]
    v_caches = [[] for _ in range(LAYERS)]
    final_logits = None
    final_hidden = None
    layer_hidden = []

    for pos, tid in enumerate(PROMPT_IDS):
        x = E[tid].copy()
        for l in range(LAYERS):
            p = f"model.layers.{l}"
            a = f"{p}.self_attn"
            m = f"{p}.mlp"
            h = rms_norm(x, w.get(f"{p}.input_layernorm.weight"))
            q = w.get(f"{a}.q_proj") @ h
            k = w.get(f"{a}.k_proj") @ h
            v = w.get(f"{a}.v_proj") @ h
            q = rope(q.reshape(HEADS, D).copy(), pos).reshape(-1)
            k = rope(k.reshape(KVH, D).copy(), pos).reshape(-1)
            q = rms_norm(q.reshape(HEADS, D), w.get(f"{a}.query_layernorm.weight")).reshape(-1)
            k = rms_norm(k.reshape(KVH, D), w.get(f"{a}.key_layernorm.weight")).reshape(-1)
            k_caches[l].append(k)
            v_caches[l].append(v)
            km = np.stack(k_caches[l], axis=0)
            vm = np.stack(v_caches[l], axis=0)
            x = x + w.get(f"{a}.o_proj") @ attention(q, km, vm)
            h2 = rms_norm(x, w.get(f"{p}.post_attention_layernorm.weight"))
            g = w.get(f"{m}.gate_proj") @ h2
            u = w.get(f"{m}.up_proj") @ h2
            silu = g / (1.0 + np.exp(-g))
            x = x + w.get(f"{m}.down_proj") @ (silu * u)
            if pos == len(PROMPT_IDS) - 1:
                layer_hidden.append(x.copy())
        final_hidden = rms_norm(x, w.get("model.norm.weight"))
        final_logits = E @ final_hidden
        print(f"  pos={pos} token={tid} argmax={int(final_logits.argmax())}", flush=True)

    final_logits.astype(np.float32).tofile(GOLDEN / "sherry-forward-logits.f32")
    final_hidden.astype(np.float32).tofile(GOLDEN / "sherry-forward-hidden.f32")
    np.stack(layer_hidden, axis=0).astype(np.float32).tofile(
        GOLDEN / "sherry-forward-layer-hidden.f32")
    top = np.argsort(-final_logits)[:20]
    meta = {
        "purpose": "G4 常驻模型 32 层 forward fp32 参考 golden（离线校准）",
        "weight_source": "Models/Hy-MT2-1.8B-1.25Bit-GGUF/weights.fp16.bin (Sherry STQ1_0 反量化 fp16)",
        "note": "用已独立校验的 fp16 展开缓存验证 32 层组装；kernel 字节级解码由 sherry-gemv-manifest.json 独立验证",
        "prompt_ids": PROMPT_IDS,
        "layers": LAYERS, "heads": HEADS, "kv_heads": KVH, "head_dim": D,
        "adjusted_rope_base": ADJUSTED_BASE, "rms_eps": EPS,
        "attention_scale": SCALE,
        "files": {
            "logits": "sherry-forward-logits.f32",
            "final_hidden": "sherry-forward-hidden.f32",
            "layer_hidden": "sherry-forward-layer-hidden.f32",
        },
        "logits": {
            "count": int(final_logits.size),
            "argmax": int(final_logits.argmax()),
            "min": float(final_logits.min()), "max": float(final_logits.max()),
            "mean": float(final_logits.mean()), "std": float(final_logits.std()),
            "top20_ids": [int(i) for i in top],
            "top20_values": [float(final_logits[i]) for i in top],
        },
        "layer_hidden_shape": [LAYERS, HIDDEN],
    }
    (GOLDEN / "sherry-forward-manifest.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print("FORWARD_GOLDEN_OK top5=" +
          str([(int(i), round(float(final_logits[i]), 4)) for i in top[:5]]), flush=True)


def main():
    if not GGUF.is_file():
        raise SystemExit(f"GGUF 不存在: {GGUF}")
    if not CACHE.is_file():
        raise SystemExit(f"fp16 缓存不存在（仅离线 golden 用）: {CACHE}")
    if not GOLDEN.is_dir():
        GOLDEN.mkdir(parents=True)
    buf = GGUF.read_bytes()
    sha = hashlib.sha256(buf).hexdigest()
    version, tensors, data_start = parse_gguf(buf)
    print(f"GGUF v{version} tensors={len(tensors)} data_start={data_start} sha256={sha[:12]}...", flush=True)
    gemv_golden(buf, tensors, data_start)
    forward_golden()
    print("SHERRY_GOLDEN_OK", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"SHERRY_GOLDEN_FAILED {type(exc).__name__}: {exc}", file=sys.stderr)
        raise
