#!/bin/bash
# 运行全部独立测试套件 + 性能基准，产物写入 Reports/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HYMN_REPORT_DIR="$ROOT/Reports" .build/debug/hymntest 2>&1 | tee Reports/test-run.log
RC=${PIPESTATUS[0]}
echo "TEST_OK rc=$RC"
exit "$RC"
