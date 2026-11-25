#!/bin/bash
# 校验界面文案的英文覆盖：代码里出现的每个 `L("…")` 都要在词典里有译文。
#
# 为什么要这一步：词典用中文原文当 key，漏译不会报错、只会静默回退成中文，
# 英文界面里就会突然冒出中文句子。这个脚本把「漏译」变成可检测的失败。
#
# 追加新文案后跑一次：./Scripts/check-localization.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import pathlib, re, sys

app = pathlib.Path("Sources/HymnApp")
table = pathlib.Path("Sources/HymnApp/Localization.swift").read_text(encoding="utf-8")

# 1) 词典条目
entries = set()
# 只解析 LocalizationTable.english 这一块；LanguageNames.english 也是同名字段，不能混。
block = table.split("enum LocalizationTable", 1)[1]
block = block.split("static let english: [String: String] = [", 1)[1]
block = block.split("\n    ]", 1)[0]
for line in block.splitlines():
    m = re.match(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', line)
    if m:
        entries.add(m.group(1))

# 2) 代码里直接写死的 key
used = {}
for f in sorted(app.glob("*.swift")):
    if f.name == "Localization.swift":
        continue
    for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        for m in re.finditer(r'L\("((?:[^"\\]|\\.)*)"', line):
            used.setdefault(m.group(1), f"{f.name}:{i}")

# 3) 运行时动态传入的 key（划词动作标题/说明来自 HymnCore）
core = pathlib.Path("Sources/HymnCore/Selection/SelectionActionCatalog.swift").read_text(encoding="utf-8")
for m in re.finditer(r'case \.[A-Za-z]+:\s*return "([^"]*)"', core):
    if re.search(r'[\u4e00-\u9fff]', m.group(1)):   # 跳过 SF Symbol 名
        used.setdefault(m.group(1), "SelectionActionCatalog.swift")

missing = sorted(k for k in used if k not in entries)
unused = sorted(k for k in entries if k not in used)

print(f"LOCALIZATION keys={len(used)} translations={len(entries)} missing={len(missing)} unused={len(unused)}")
for k in missing:
    print(f"  MISSING {used[k]:28} {k}")
for k in unused[:20]:
    print(f"  UNUSED  {k}")

if missing:
    print("LOCALIZATION_FAIL 请把这些 key 的英文补进 LocalizationTable.english")
    sys.exit(2)
print("LOCALIZATION_OK")
PY
