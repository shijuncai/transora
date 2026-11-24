#!/usr/bin/env python3
"""离线生成静态 TTF 字体资产（一次性脚本，不参与运行时）。

为什么要有这一步：
    官方只发布 CFF 轮廓的 OTF 和可变字体 TTF，**没有静态 TTF**。
    直接用 OTF 意味着 PDF 侧要写 CIDFontType0（CFF 子集器约 2000 行，易错），
    而静态 TTF 只需 glyf 子集器（约 1000 行）。所以这里把 VF 实例化成静态 TTF。

一个必须显式指定的坑：
    NotoSerifSC-VF 的默认 master 是 **ExtraLight（wght=200）**，不是 Regular。
    漏传 wght 会得到细宋，正文发虚，而且看起来像「字体选错了」，很难在 review 里发现。
    所以这里强制传轴值并断言 OS/2.usWeightClass。

命名：
    name 表实测无 Reserved Font Name（nameID 0 只有 © 2017-2024 Adobe），
    法律上可以保留原名；但 Noto 是 Google 商标，OFL 第 4 条也禁止用作者名推广修改版，
    所以工程上改名。nameID 0（版权）、13（许可）原样保留，13 是 OFL 全文。

用法：
    python3 Scripts/make-fonts.py <输入 VF.ttf> <输出目录>
"""

import hashlib
import os
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

FAMILY = "LinguaNova Song"
POSTSCRIPT_PREFIX = "LinguaNovaSong"

INSTANCES = [
    # (wght, 子族名, PostScript 后缀)
    (400, "Regular", "Regular"),
    (700, "Bold", "Bold"),
]

# instancing 之后这些表失去意义，留着只会白占体积
DROP_TABLES = ["gvar", "avar", "fvar", "HVAR", "VVAR", "MVAR", "STAT", "cvar", "DSIG"]

# 保留原样，不得改动（OFL 要求版权与许可声明随字体走）
PRESERVE_NAME_IDS = {0, 7, 13, 14}


def rename(font, subfamily, ps_suffix):
    """改写 name 表，保留版权/许可/商标原文。"""
    name = font["name"]
    full = f"{FAMILY} {subfamily}"
    ps = f"{POSTSCRIPT_PREFIX}-{ps_suffix}"

    # 收集原始记录里的版权与许可文本，改名后按平台重新写回
    preserved = {}
    for rec in list(name.names):
        if rec.nameID in PRESERVE_NAME_IDS:
            preserved.setdefault(rec.nameID, rec.toUnicode())

    replacements = {
        1: FAMILY,          # Font Family
        2: subfamily,       # Font Subfamily
        3: f"{ps};LinguaNova",  # Unique ID
        4: full,            # Full Name
        6: ps,              # PostScript Name
        16: FAMILY,         # Typographic Family
        17: subfamily,      # Typographic Subfamily
    }
    for name_id, value in replacements.items():
        name.setName(value, name_id, 3, 1, 0x409)   # Windows / Unicode BMP / en-US
        name.setName(value, name_id, 1, 0, 0)       # Macintosh / Roman / en

    for name_id, value in preserved.items():
        if name_id in replacements:
            continue
        name.setName(value, name_id, 3, 1, 0x409)


def subset_cmap_coverage(font):
    cmap = font.getBestCmap() or {}
    cjk = sum(1 for cp in cmap if 0x4E00 <= cp <= 0x9FFF)
    return len(cmap), cjk


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    source, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    source_hash = hashlib.sha256(open(source, "rb").read()).hexdigest()
    print(f"输入 {source}")
    print(f"     {os.path.getsize(source):,} 字节  sha256={source_hash}")

    for weight, subfamily, ps_suffix in INSTANCES:
        font = TTFont(source)

        # 显式给轴：默认 master 是 ExtraLight，不能省
        font = instancer.instantiateVariableFont(font, {"wght": weight}, inplace=False)

        for tag in DROP_TABLES:
            if tag in font:
                del font[tag]

        os2 = font["OS/2"]
        if os2.usWeightClass != weight:
            raise SystemExit(
                f"字重错：期望 {weight}，实际 {os2.usWeightClass}（VF 默认 master 可能是 ExtraLight）")
        os2.usWeightClass = weight
        # Regular 不能带 Bold 位，Bold 必须带，否则阅读器不会做粗体替换
        if weight >= 700:
            os2.fsSelection = (os2.fsSelection & ~0x40) | 0x20   # REGULAR=0, BOLD=1
            font["head"].macStyle |= 0x01
        else:
            os2.fsSelection = (os2.fsSelection | 0x40) & ~0x20
            font["head"].macStyle &= ~0x01

        # 关键：fontTools 默认会把 head.modified 改成「现在」，导致同样的输入
        # 每次产出不同字节，SHA-256 锁不住、golden 全飘。关掉时间戳重算，
        # 保留源字体的 created/modified。
        font.recalcTimestamp = False

        rename(font, subfamily, ps_suffix)

        path = os.path.join(out_dir, f"{POSTSCRIPT_PREFIX}-{ps_suffix}.ttf")
        font.save(path)

        check = TTFont(path)
        cmap_size, cjk_size = subset_cmap_coverage(check)
        cmap_format = sorted({t.format for t in check["cmap"].tables})
        has_glyf = "glyf" in check
        has_cff = "CFF " in check or "CFF2" in check
        gid_count = check["maxp"].numGlyphs
        first_gid = check.getGlyphID(check.getBestCmap()[0x4E2D]) if 0x4E2D in (check.getBestCmap() or {}) else None

        print(f"输出 {path}")
        print(f"     {os.path.getsize(path):,} 字节  sha256={hashlib.sha256(open(path,'rb').read()).hexdigest()}")
        print(f"     轮廓 {'glyf' if has_glyf else '?'}  CFF={has_cff}  字形 {gid_count}")
        print(f"     cmap {cmap_size} 码位（其中 CJK 统一表意 {cjk_size}），format {cmap_format}")
        print(f"     nameID1={check['name'].getDebugName(1)!r}  nameID6={check['name'].getDebugName(6)!r}")
        print(f"     usWeightClass={check['OS/2'].usWeightClass}  「中」的 GID={first_gid}")
        print(f"     保留表 {sorted(check.keys())}")
        print()

        if not has_glyf or has_cff:
            raise SystemExit("产物不是 glyf 轮廓，PDF 侧无法走 CIDFontType2")
        if check["post"].formatType != 3.0:
            print(f"注意：post 表 format={check['post'].formatType}，子集器需要处理")
        if 0x4E2D not in (check.getBestCmap() or {}):
            raise SystemExit("cmap 里没有「中」，字体覆盖异常")


if __name__ == "__main__":
    main()
