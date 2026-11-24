#!/bin/bash
# 生成 Assets/TransOra.icns
# 有 Assets/logo-source.png 时按品牌图生成（当前即「白色圆角卡 + 渐变 TO」）；
# 缺图时回退到 Scripts/make-icon.swift 纯代码绘制的渐变图标。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/TransOra.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$ROOT/Assets" "$ROOT/.build"

if [ -f "$ROOT/Assets/logo-source.png" ]; then
  swiftc -O "$ROOT/Scripts/make-icon-from-image.swift" \
    -o "$ROOT/.build/make-icon-from-image" -framework AppKit
  "$ROOT/.build/make-icon-from-image" "$ROOT/Assets/logo-source.png" "$ICONSET"
else
  swiftc -O "$ROOT/Scripts/make-icon.swift" -o "$ROOT/.build/make-icon" -framework AppKit
  "$ROOT/.build/make-icon" "$ICONSET"
fi
iconutil -c icns "$ICONSET" -o "$ROOT/Assets/TransOra.icns"
echo "ICON_OK $ROOT/Assets/TransOra.icns"
