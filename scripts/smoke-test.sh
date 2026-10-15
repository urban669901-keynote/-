#!/bin/bash
# 冒煙測試（macOS）：啟動打包好的 App，測試手機 API，並截圖驗證彈幕是否蓋在各種全螢幕視窗上。
# 先執行 ./scripts/build-app.sh。結果與截圖放在 dist/smoke/。
set -uo pipefail

cd "$(dirname "$0")/.."
OUT="dist/smoke"
APP_BIN="dist/URBANDanmaku.app/Contents/MacOS/URBANDanmaku"
BASE="http://127.0.0.1:8765"
DOMAIN="com.urban.danmaku"
rm -rf "${OUT}" && mkdir -p "${OUT}"

swift build -c release --product FullscreenProbe >/dev/null
PROBE="$(swift build -c release --product FullscreenProbe --show-bin-path)/FullscreenProbe"

FAILURES=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; FAILURES=$((FAILURES + 1)); }
expect_code() { # 說明 預期代碼 實際代碼
  if [[ "$3" == "$2" ]]; then pass "$1（HTTP $3）"; else fail "$1：預期 HTTP $2，實際 $3"; fi
}

APP_PID=""
launch_app() {
  "${APP_BIN}" --demo >>"${OUT}/app.log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 60); do
    curl -fsS "${BASE}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
stop_app() {
  [[ -n "${APP_PID}" ]] && kill "${APP_PID}" 2>/dev/null && wait "${APP_PID}" 2>/dev/null
  APP_PID=""
}
trap stop_app EXIT

shot() { screencapture -x "${OUT}/$1.png" 2>>"${OUT}/screencapture.log" || echo "screencapture 失敗：$1" >>"${OUT}/screencapture.log"; }

# ---------- 1. 伺服器與 API ----------
defaults delete "${DOMAIN}" >/dev/null 2>&1 || true
# 截圖驗證時先隱藏 QR Code，藍色與白色像素就只會來自彈幕本身
defaults write "${DOMAIN}" qrVisible -bool false

if launch_app; then pass "App 啟動、伺服器就緒"; else fail "伺服器沒有在 30 秒內啟動"; cat "${OUT}/app.log"; exit 1; fi

curl -fsS "${BASE}/" | grep -q "URBAN 即時彈幕" && pass "手機網頁" || fail "手機網頁"
curl -fsS "${BASE}/api/status" | grep -q '"state":"live"' && pass "狀態 API 回報 live" || fail "狀態 API"

code=$(curl -s -o "${OUT}/post.json" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary '{"text":"CI 測試 🎉 URBAN"}' "${BASE}/api/danmaku")
expect_code "送出彈幕" 200 "${code}"
grep -q '"ok":true' "${OUT}/post.json" && pass "回應 ok:true" || fail "回應內容：$(cat "${OUT}/post.json")"

codes=""
for _ in 1 2 3 4; do
  codes+="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary '{"text":"spam"}' "${BASE}/api/danmaku") "
done
[[ "${codes}" == *429* ]] && pass "同一支手機連發會被限流（${codes}）" || fail "沒有限流（${codes}）"

expect_code "錯誤格式" 400 "$(curl -s -o /dev/null -w '%{http_code}' --data-binary 'not json' "${BASE}/api/danmaku")"
expect_code "空白內容" 400 "$(curl -s -o /dev/null -w '%{http_code}' --data-binary '{"text":"   "}' "${BASE}/api/danmaku")"
expect_code "不存在的路徑" 404 "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/nope")"
expect_code "錯誤的方法" 405 "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/danmaku")"

# ---------- 2. 截圖驗證：彈幕是否蓋在全螢幕視窗上 ----------
sleep 2
shot "01-desktop"

run_probe() { # 名稱 情境 是否必須通過
  local name="$1" scenario="$2" required="$3"
  "${PROBE}" show "${scenario}" --seconds 10 >"${OUT}/probe-${name}.log" 2>&1 &
  local probe_pid=$!
  sleep 7
  shot "${name}"
  wait "${probe_pid}" 2>/dev/null
  sleep 1
  local result status
  result="$("${PROBE}" analyze "${OUT}/${name}.png")"
  status=$?
  echo "${result}" | tee -a "${OUT}/report.txt"
  if [[ ${status} -eq 1 && "${required}" == "required" ]]; then
    fail "${scenario}：彈幕被蓋住"
  elif [[ ${status} -eq 2 ]]; then
    echo "⚪️ ${scenario}：截圖無法判斷（runner 可能沒有螢幕錄製權限）"
  fi
}

run_probe "02-native-fullscreen" "fullscreen" required
run_probe "03-level-1000" "level:1000" required
run_probe "04-level-shielding" "shielding" required
run_probe "05-display-capture" "capture" optional

# ---------- 3. 有 QR Code 的展示截圖 ----------
stop_app
defaults write "${DOMAIN}" qrVisible -bool true
if launch_app; then
  sleep 4
  shot "06-desktop-with-qr"
else
  fail "第二次啟動失敗"
fi
stop_app
defaults delete "${DOMAIN}" >/dev/null 2>&1 || true

echo
echo "----- App 紀錄（層級變化）-----"
grep -E "URBANDanmaku" "${OUT}/app.log" || true
echo
if [[ ${FAILURES} -gt 0 ]]; then
  echo "❌ 共 ${FAILURES} 項失敗"
  exit 1
fi
echo "✅ 冒煙測試通過"
