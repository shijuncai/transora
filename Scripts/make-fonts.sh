#!/bin/bash
# 离线生成 PDF 版式重建用的静态字体资产（一次性，不参与运行时）。
#
# 用法：./Scripts/make-fonts.sh [NotoSerifSC-VF.ttf 路径] [输出目录]
#   默认输入 /tmp/fontwork/NotoSerifSC-VF.ttf
#   默认输出 Resources/Fonts
#
# 为什么要有这一步：
#   思源宋体官方只发 CFF 轮廓的 OTF 和可变字体 TTF，没有静态 TTF。
#   直接用 OTF，PDF 侧就要写 CFF 子集器（约 2000 行，一个 subr 错就整段字形乱）；
#   实例化成静态 TTF 后只需 glyf 子集器（约 700 行），所以在这里一次性转换。
#
# 产物是二进制资产，**入库并锁 SHA-256**（见 make-release.sh 4b 步）。
# 构建流程只校验不重生成：重生成的字节可能不同，会让 golden 全飘。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SRC="${1:-/tmp/fontwork/NotoSerifSC-VF.ttf}"
OUT="${2:-Resources/Fonts}"

if [ ! -f "$SRC" ]; then
  echo "找不到输入字体：$SRC" >&2
  echo "从 notofonts/noto-cjk 取 Serif/Variable/TTF/Subset/NotoSerifSC-VF.ttf（约 25 MB）。" >&2
  echo "GitHub blob API 可用：curl -H 'Accept: application/vnd.github.raw' \\" >&2
  echo "  'https://api.github.com/repos/notofonts/noto-cjk/git/blobs/<sha>' -o $SRC" >&2
  exit 2
fi

PY="${HYMN_FONT_PYTHON:-python3}"
if ! "$PY" -c "import fontTools" >/dev/null 2>&1; then
  echo "缺少 fonttools。这是一个离线开发脚本，不在运行时依赖里：" >&2
  echo "  python3 -m venv /tmp/fontvenv && /tmp/fontvenv/bin/pip install fonttools" >&2
  echo "  HYMN_FONT_PYTHON=/tmp/fontvenv/bin/python ./Scripts/make-fonts.sh" >&2
  exit 3
fi

"$PY" Scripts/make-fonts.py "$SRC" "$OUT"

echo ""
echo "=== 产物校验 ==="
shasum -a 256 "$OUT"/LinguaNovaSong-*.ttf
echo "下一步：把上面的 SHA-256 更新到 Scripts/make-release.sh 的 4b 步。"
