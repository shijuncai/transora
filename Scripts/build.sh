#!/bin/bash
# HymnTranslate 构建脚本（单后端产品版）
#
# 零外部 SwiftPM 依赖：不链接 MLX，不需要 metal-cpp / .metallib，
# 所有 MSL kernel 都在运行时由 device.makeLibrary(source:) 编译，
# 因此也不再需要处理 Xcode MetalToolchain cryptex 路径漂移。
# CommandLineTools 环境下仍需 --disable-sandbox。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p Reports

swift build --disable-sandbox 2>&1 | tee Reports/build.log
RC=${PIPESTATUS[0]}
echo "BUILD_OK rc=$RC"
exit "$RC"
