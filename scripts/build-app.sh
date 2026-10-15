#!/bin/bash
# 編譯並打包 URBANDanmaku.app（需要 macOS + Xcode 或 Command Line Tools）。
#
#   ./scripts/build-app.sh             # 只編譯本機架構（Apple 晶片或 Intel）
#   UNIVERSAL=1 ./scripts/build-app.sh # 同時支援 Apple 晶片與 Intel（需要完整 Xcode）
#
# 產出：dist/URBANDanmaku.app 與 dist/URBANDanmaku.zip
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="URBANDanmaku"
DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▶ 編譯（release）…"
swift build -c release --product "${APP_NAME}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product "${APP_NAME}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▶ 打包 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "▶ Ad-hoc 簽章"
codesign --force --deep --sign - "${APP}"
codesign --verify --verbose "${APP}"

echo "▶ 壓縮 dist/${APP_NAME}.zip"
rm -f "${DIST}/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP}" "${DIST}/${APP_NAME}.zip"

lipo -info "${APP}/Contents/MacOS/${APP_NAME}" || true
echo "✅ 完成：${APP}"
