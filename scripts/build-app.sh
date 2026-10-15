#!/bin/bash
# 編譯並打包「URBAN LIVE.app」（需要 macOS + Xcode 或 Command Line Tools）。
#
#   ./scripts/build-app.sh             # 只編譯本機架構（Apple 晶片或 Intel）
#   UNIVERSAL=1 ./scripts/build-app.sh # 同時支援 Apple 晶片與 Intel（需要完整 Xcode）
#
# 產出：dist/URBAN LIVE.app、dist/URBAN-LIVE.zip、dist/URBAN-LIVE.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
EXECUTABLE="URBANLive"
APP_NAME="URBAN LIVE"
DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}.app"
WORK="${ROOT}/.build/package"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▶ 編譯（release）…"
swift build -c release --product "${EXECUTABLE}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product "${EXECUTABLE}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▶ 產生圖示"
rm -rf "${WORK}" && mkdir -p "${WORK}"
swift "${ROOT}/scripts/make-icon.swift" "${WORK}/AppIcon.iconset"
iconutil -c icns "${WORK}/AppIcon.iconset" -o "${WORK}/AppIcon.icns"

echo "▶ 打包 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${EXECUTABLE}" "${APP}/Contents/MacOS/${EXECUTABLE}"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "${WORK}/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "▶ Ad-hoc 簽章（非 Apple 公證，見 README）"
codesign --force --deep --sign - "${APP}"
codesign --verify --verbose "${APP}"

echo "▶ 壓縮 dist/URBAN-LIVE.zip"
rm -f "${DIST}/URBAN-LIVE.zip"
ditto -c -k --keepParent "${APP}" "${DIST}/URBAN-LIVE.zip"

echo "▶ 製作 dist/URBAN-LIVE.dmg（拖曳到「應用程式」安裝）"
STAGE="${WORK}/dmg"
rm -rf "${STAGE}" && mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DIST}/URBAN-LIVE.dmg"
hdiutil create -volname "URBAN LIVE" -srcfolder "${STAGE}" -ov -format UDZO "${DIST}/URBAN-LIVE.dmg" >/dev/null

lipo -info "${APP}/Contents/MacOS/${EXECUTABLE}" || true
ls -lh "${DIST}"
echo "✅ 完成：${APP}"
