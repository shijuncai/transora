#!/bin/bash
# 把 SwiftPM 产物组装为可分发的「译澜 TransOra」.app（英文名 TransOra 仍是包名与图标名）
#
# 保留内部 bundle identifier 与 Application Support 数据目录不变，
# 避免改名导致用户已保存的模型目录偏好、历史记录和术语库丢失。
#
# 默认把 450 MB 模型一起放进 Contents/Resources/Models/，产出「App + 模型」合一包：
# 拷到任意 Apple Silicon Mac 上双击即用，无需再手动选模型目录。
#   HYMN_EMBED_MODEL=0 ./Scripts/make-app.sh   → 退回 5 MB 轻量包（需首次选目录）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/debug"
APP="$ROOT/dist/TransOra.app"
VERSION="0.8.7"
BUILD_NUMBER="27"
EMBED_MODEL="${HYMN_EMBED_MODEL:-1}"

# 清理旧品牌产物（都是可重建的构建产物，不是用户数据）
rm -rf "$APP" "$ROOT/dist/LinguaNova.app" "$ROOT/dist/HymnTranslate.app"
rm -f "$ROOT/Assets/HymnTranslate.icns" "$ROOT/Assets/LinguaNova.icns"
rm -f "$ROOT/dist/HymnTranslate-"*.dmg "$ROOT/dist/LinguaNova-"*.dmg

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/HymnTranslate" "$APP/Contents/MacOS/HymnTranslate"

if [ -f "$ROOT/Assets/TransOra.icns" ]; then
  cp "$ROOT/Assets/TransOra.icns" "$APP/Contents/Resources/TransOra.icns"
fi

# 版式重建要把中文写回 PDF，必须带内置字体（OFL 允许随附，许可证一并放进去）
if [ -d "$ROOT/Resources/Fonts" ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$ROOT/Resources/Fonts/"*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null
  cp "$ROOT/Resources/Fonts/OFL.txt" "$APP/Contents/Resources/Fonts/" 2>/dev/null
  echo "FONTS_EMBEDDED $(du -sh "$APP/Contents/Resources/Fonts" | awk '{print $1}')"
else
  echo "WARN 缺少 Resources/Fonts，版式重建不可用" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>        <string>HymnTranslate</string>
  <key>CFBundleIdentifier</key>        <string>com.hymntranslate.macos</string>
  <key>CFBundleName</key>              <string>译澜</string>
  <key>CFBundleDisplayName</key>       <string>译澜</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleIconFile</key>          <string>TransOra</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key>           <string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key> <string>zh_CN</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key>  <string>Copyright © 2026 TransOra. On-device offline translation.</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSPrincipalClass</key>         <string>NSApplication</string>
  <key>LSUIElement</key>               <false/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <!-- 写入「提醒事项」用的 EventKit 隐私声明；不再发送 Apple Events，
       因此不再声明 NSAppleEventsUsageDescription。 -->
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>用于把划词翻译的译文加进「提醒事项」，不会读取或修改其它提醒。</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 开发机便利：把工程里的模型目录软链到 Application Support（不覆盖既有对象）。
# 分发版用户不需要这一步，改用设置页的「选择模型文件夹」。
SUPPORT="$HOME/Library/Application Support/HymnTranslate/Models"
mkdir -p "$SUPPORT"
NAME="Hy-MT2-1.8B-1.25Bit-GGUF"
MODELS="$ROOT/Models/$NAME"
if [ -d "$MODELS" ]; then
  LINK="$SUPPORT/$NAME"
  if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
    ln -s "$MODELS" "$LINK"
    echo "MODEL_LINK $LINK -> $MODELS"
  else
    echo "MODEL_LINK kept: $LINK"
  fi
fi

# 合一包：把模型放进 Contents/Resources/Models/（必须在 codesign 之前，
# 否则资源封印不包含这些文件，签名会失效）。NAME / MODELS 已在上方定义。
if [ "$EMBED_MODEL" = "1" ]; then
  if [ -f "$MODELS/Hy-MT2-1.8B-1.25Bit.gguf" ]; then
    mkdir -p "$APP/Contents/Resources/Models"
    # APFS 用 clonefile（写时复制，秒级）；非 APFS 退化为普通拷贝。
    cp -cR "$MODELS" "$APP/Contents/Resources/Models/$NAME" 2>/dev/null \
      || cp -R "$MODELS" "$APP/Contents/Resources/Models/$NAME"
    echo "MODEL_EMBEDDED Contents/Resources/Models/$NAME ($(du -sh "$APP/Contents/Resources/Models" | awk '{print $1}'))"
  else
    echo "MODEL_EMBED_SKIPPED 未找到 $MODELS/Hy-MT2-1.8B-1.25Bit.gguf"
    exit 3
  fi
else
  echo "MODEL_EMBED_DISABLED (轻量包，首次启动需选择模型目录)"
fi

# ad-hoc 签名：让 macOS 把 bundle 当作完整签名应用处理（不等于公证）。
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "CODESIGN_SKIPPED (ad-hoc 不可用)"
# 图标缓存：同一路径反复重建时 Finder / Dock 会沿用旧的 IconServices 缓存，
# 这里更新时间戳并向 LaunchServices 重新注册，尽量让新图标立即生效。
touch "$APP" "$APP/Contents/Info.plist" 2>/dev/null || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
  echo "ICON_CACHE_REFRESHED"
fi
echo "APP_BUILT $APP ($(du -sh "$APP" | awk '{print $1}'))"
echo "--- structure ---"
find "$APP" -maxdepth 4 -type f | sed "s|$APP|.|" | sort
