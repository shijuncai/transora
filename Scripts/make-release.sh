#!/bin/bash
# 一键发布校验：构建 → 全量测试 → 图标 → .app → 运行时自检 → 真机冒烟
#               （含划词翻译数据链路自测）→ DMG
#
# 产物：dist/TransOra.app（含内嵌模型，约 450 MB）、dist/TransOra-0.8.7.dmg、
#       Reports/release-runtime.json、Reports/release-smoke.log、Reports/release-bundle-model.log
# 说明：ad-hoc 签名不等于 Apple 公证；正式分发仍需 Developer ID 签名与公证。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="0.8.7"
APP="$ROOT/dist/TransOra.app"

echo "=== 1/8 构建 ==="
./Scripts/build.sh >/dev/null
echo "BUILD_OK"

echo "=== 2/8 全量测试 ==="
./Scripts/test.sh >/dev/null
grep -E "^# pass" Reports/test-run.log | tail -1

echo "=== 2b/8 版本一致性（防止 Info.plist 与关于窗口漂移） ==="
# 版本号有三个来源：本脚本、make-app.sh、AppBrand.fallbackVersion。
# 少了这一步，就会出现「包是 0.8.1、关于窗口还显示 0.7.12」——实测踩过。
python3 - "$VERSION" <<'PYVER'
import pathlib, re, sys
want = sys.argv[1]
src = pathlib.Path("Sources/HymnApp/AppBrand.swift").read_text(encoding="utf-8")
m = re.search(r'static let fallbackVersion = "([^"]+)"', src)
got = m.group(1) if m else "(missing)"
app = re.search(r'^VERSION="([^"]+)"', pathlib.Path("Scripts/make-app.sh").read_text(encoding="utf-8"), re.M)
appv = app.group(1) if app else "(missing)"
bad = []
if got != want:
    bad.append(f"AppBrand.fallbackVersion={got}")
if appv != want:
    bad.append(f"make-app.sh VERSION={appv}")
if bad:
    print(f"VERSION_DRIFT {' '.join(bad)} 期望={want}")
    raise SystemExit(10)
print(f"VERSION_OK {want}")
PYVER

echo "=== 3/8 生成图标 ==="
./Scripts/make-icon.sh | tail -1

echo "=== 4/8 组装 .app ==="
./Scripts/make-app.sh | grep -E "APP_BUILT|CODESIGN|MODEL_"

echo "=== 4b/8 字体资产校验（PDF 版式重建用） ==="
# 为什么要锁 SHA-256：字体被静默换掉时，所有 golden 与体积基线都会飘，
# 而且渲染结果会变而没人知道。这里只校验仓库资产；
# 等 PDF 版式重建接进 UI（P5）后再校验「是否真的打进 .app」。
python3 - <<'PY'
import hashlib, pathlib, sys
expect = {
    "Resources/Fonts/LinguaNovaSong-Regular.ttf":
        "c254dd016bdc4cba5fb69f6c0fd95611d6b8c10971c9e7ac708f5b26545e2813",
    "Resources/Fonts/LinguaNovaSong-Bold.ttf":
        "0bce842c7db62dbd53c246aab840781ee2c1b955259de6776742568fa6e1c5e7",
}
bad = 0
for path, want in expect.items():
    p = pathlib.Path(path)
    if not p.exists():
        print(f"FONT_MISSING {path}")
        bad += 1
        continue
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    size = p.stat().st_size
    if got != want:
        print(f"FONT_SHA_MISMATCH {path} got={got[:16]} want={want[:16]}")
        bad += 1
    else:
        print(f"FONT_OK {p.name} {size} B")
# OFL 要求许可声明随字体走，缺了就是合规问题
if not pathlib.Path("Resources/Fonts/OFL.txt").exists():
    print("FONT_LICENSE_MISSING Resources/Fonts/OFL.txt")
    bad += 1
else:
    print("FONT_LICENSE_OK OFL.txt")
raise SystemExit(2 if bad else 0)
PY

echo "=== 5/8 运行时自检（唯一后端） ==="
.build/debug/hymnctl verify --json > Reports/release-runtime.json
python3 - <<'PY'
import json
d = json.load(open("Reports/release-runtime.json"))
print(f"VERIFY ready={d['ready']} gguf={d['ggufBytes']} B tensors={d['tensorCount']} "
      f"metal={d['metalDevice']} offline={d['offlineOnly']}")
print("FORMAT", d["weightFormat"])
if not d["ready"]:
    raise SystemExit(2)
PY

echo "=== 6/8 .app 真机冒烟（真实翻译 + 划词链路自测 + 主线程 tick） ==="
python3 - "$APP/Contents/MacOS/HymnTranslate" <<'PY' | tee Reports/release-smoke.log
import os, subprocess, sys, tempfile, atexit
env = dict(os.environ)
env["HYMN_HEADLESS_SMOKE"] = "1"
env["HYMN_SMOKE_TRANSLATE"] = "1"
env["HYMN_SELECTION_SELFTEST"] = "1"
tmpdb = tempfile.mktemp(prefix="transora-smoke-", suffix=".db")
env["HYMN_DB_PATH"] = tmpdb
atexit.register(lambda: os.path.exists(tmpdb) and os.remove(tmpdb))
for k in ("HYMN_SMOKE_SWITCH", "HYMN_SMOKE_SWITCH_TO", "HYMN_SMOKE_GUARD",
          "HYMN_BACKEND", "HYMN_PREF_SUITE"):
    env.pop(k, None)
try:
    p = subprocess.run([sys.argv[1]], env=env, capture_output=True, text=True, timeout=300)
except subprocess.TimeoutExpired:
    print("SMOKE_TIMEOUT 300s")
    raise SystemExit(3)
out = p.stdout or ""
print(out.strip())
if p.stderr.strip():
    print("STDERR", p.stderr.strip()[-500:])
if "HYMN_SMOKE_OK" not in out or "real=true" not in out:
    print("SMOKE_FAIL: 未出现真实推理就绪标志")
    raise SystemExit(4)
lines = out.splitlines()
main_line = next((l for l in lines if l.startswith("HYMN_SMOKE_TRANSLATION")), "")
expected = main_line.split("output=", 1)[1].split(" status=", 1)[0].strip() if "output=" in main_line else ""
selftest = next((l for l in lines if l.startswith("HYMN_SELECTION_SELFTEST")), "")
# output= 后面可能跟 pair= / error= 等字段，逐级切分，避免把字段内容算进译文。
selected = (selftest.split("output=", 1)[1]
            .split(" pair=", 1)[0].split(" error=", 1)[0].strip()
            if "output=" in selftest else "")
pair = (selftest.split(" pair=", 1)[1].split(" error=", 1)[0].strip()
        if " pair=" in selftest else "")
print(f"SELECTION_CHAIN main={expected!r} selection={selected!r} pair={pair!r} "
      f"error={'none' if 'error=none' in selftest else 'present'}")
if not expected or selected != expected or "error=none" not in selftest:
    print("SMOKE_FAIL: 划词翻译数据链路未产出与主窗口一致的译文")
    raise SystemExit(5)
if "->" in pair and pair.split("->")[0] == pair.split("->")[1]:
    print("SMOKE_FAIL: 划词语言对出现自译（源==目标）")
    raise SystemExit(7)
if p.returncode != 0:
    raise SystemExit(p.returncode or 6)
PY

echo "=== 7/8 合一包校验（模型内嵌且不依赖用户偏好） ==="
BUNDLED="$APP/Contents/Resources/Models/Hy-MT2-1.8B-1.25Bit-GGUF"
if [ ! -f "$BUNDLED/Hy-MT2-1.8B-1.25Bit.gguf" ]; then
  echo "BUNDLE_FAIL: 未在 Contents/Resources 内找到模型"
  exit 8
fi
echo "BUNDLE_MODEL_BYTES $(stat -f%z "$BUNDLED/Hy-MT2-1.8B-1.25Bit.gguf")"
python3 - "$APP/Contents/MacOS/HymnTranslate" <<'PY' | tee Reports/release-bundle-model.log
import os, subprocess, sys, tempfile, atexit
env = dict(os.environ)
env["HYMN_HEADLESS_SMOKE"] = "1"
env["HYMN_SMOKE_TRANSLATE"] = "1"
for k in ("HYMN_SHERRY_MODEL_DIR", "HYMN_SMOKE_SWITCH", "HYMN_SMOKE_SWITCH_TO",
          "HYMN_SMOKE_GUARD", "HYMN_BACKEND", "HYMN_PREF_SUITE", "HYMN_SELECTION_SELFTEST"):
    env.pop(k, None)
tmpdb = tempfile.mktemp(prefix="transora-bundle-", suffix=".db")
atexit.register(lambda: os.path.exists(tmpdb) and os.remove(tmpdb))
env["HYMN_DB_PATH"] = tmpdb
# 用参数域把「用户选择的模型目录」覆盖成无效路径，从而证明模型确实来自
# App 内部的 Contents/Resources，在全新机器上无需任何人工选择。
p = subprocess.run([sys.argv[1], "-hymn.modelDirectory", "/nonexistent-model-dir"],
                   env=env, capture_output=True, text=True, timeout=300)
out = p.stdout or ""
line = next((l for l in out.splitlines() if l.startswith("HYMN_SMOKE_TRANSLATION")), "")
ok = next((l for l in out.splitlines() if l.startswith("HYMN_SMOKE_OK")), "")
print(line.strip() or "HYMN_SMOKE_TRANSLATION (missing)")
print(ok.strip() or "HYMN_SMOKE_OK (missing)")
if "real=true" not in out or "output=" not in line:
    print("BUNDLE_FAIL: 内嵌模型未能完成真实推理")
    raise SystemExit(9)
print("BUNDLE_MODEL_OK")
PY

echo "=== 8/8 生成 DMG ==="
DMG="$ROOT/dist/TransOra-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "TransOra" -srcfolder "$APP" -ov -format UDZO -o "$DMG" >/dev/null
echo "DMG_OK $DMG ($(du -sh "$DMG" | awk '{print $1}'))"
echo "RELEASE_OK version=$VERSION"
