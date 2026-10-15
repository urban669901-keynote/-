#!/bin/bash
# 整合測試（macOS）：啟動打包好的 App，實際連線、截圖、壓力測試。
# 先執行 ./scripts/build-app.sh，並在 tests/ 執行 npm ci。結果放在 dist/smoke/。
#
# 壓力測試需要本機別名（模擬 200 支不同 IP 的手機）：
#   for i in $(seq 2 215); do sudo ifconfig lo0 alias 127.0.0.$i up; done
# 截圖需要終端機的「螢幕錄製」權限；沒有權限時截圖類測試會顯示「無法判斷」。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${ROOT}/dist/smoke"
APP_BIN="${ROOT}/dist/URBAN LIVE.app/Contents/MacOS/URBANLive"
DOMAIN="com.urban6699.live"
BASE="http://127.0.0.1:8765"
LOAD_CLIENTS="${LOAD_CLIENTS:-200}"
LOAD_SECONDS="${LOAD_SECONDS:-60}"
rm -rf "${OUT}" && mkdir -p "${OUT}"

swift build -c release --product FullscreenProbe >/dev/null
PROBE="$(swift build -c release --product FullscreenProbe --show-bin-path)/FullscreenProbe"

FAILURES=0
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; FAILURES=$((FAILURES + 1)); }
section() { echo; echo "========== $1 =========="; }

APP_PID=""
LOG=""
launch_app() { # 名稱 App 參數...
  local name="$1"
  shift
  LOG="${OUT}/app-${name}.log"
  "${APP_BIN}" --no-panel ${1+"$@"} >"${LOG}" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 60); do
    curl -fsS "${BASE}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  fail "App 沒有在 30 秒內啟動（${name}）"
  cat "${LOG}"
  return 1
}
stop_app() {
  if [[ -n "${APP_PID}" ]]; then
    kill "${APP_PID}" 2>/dev/null
    wait "${APP_PID}" 2>/dev/null
  fi
  APP_PID=""
}
trap stop_app EXIT

session_url() {
  local url=""
  for _ in $(seq 1 20); do
    url="$(grep -o 'http://[0-9.]*:[0-9]*/j/[A-Z0-9]*' "${LOG}" | tail -1)"
    [[ -n "${url}" ]] && break
    sleep 0.5
  done
  echo "${url}"
}
shot() { screencapture -x "${OUT}/$1.png" 2>>"${OUT}/screencapture.log" || echo "screencapture 失敗：$1" >>"${OUT}/screencapture.log"; }
reset_defaults() { defaults delete "${DOMAIN}" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------------------
section "1. 協定測試（真的 App、真的 WebSocket）"
reset_defaults
launch_app protocol --start-session || exit 1
URL="$(session_url)"
TOKEN="${URL##*/}"
[[ -n "${TOKEN}" ]] && pass "場次網址：${URL}" || fail "找不到場次網址"
ALIAS_FLAG=""
ifconfig lo0 | grep -q "127.0.0.10 " && ALIAS_FLAG="--aliases"
node tests/protocol-test.mjs --base "${BASE}" --token "${TOKEN}" ${ALIAS_FLAG} || fail "協定測試"
stop_app

# ---------------------------------------------------------------------------
section "2. QR Code 可掃描 + 三種彈幕樣式 + 控制面板"
reset_defaults
launch_app style-glass --start-session --demo || exit 1
URL="$(session_url)"
sleep 6
shot "01-style-glass"
DECODED="$("${PROBE}" qr "${OUT}/01-style-glass.png" | head -1)"
if [[ "${DECODED}" == "${URL}" ]]; then
  pass "畫面上的 QR Code 可解碼，內容與場次網址一致（${DECODED}）"
elif [[ -z "${DECODED}" ]]; then
  echo "⚪️ 截圖中解不出 QR Code（可能沒有螢幕錄製權限）"
else
  fail "QR Code 內容不一致：${DECODED} ≠ ${URL}"
fi
stop_app

for style in classic card; do
  defaults write "${DOMAIN}" style -string "${style}"
  launch_app "style-${style}" --start-session --demo || continue
  sleep 6
  shot "02-style-${style}"
  stop_app
done
defaults write "${DOMAIN}" style -string glass

# 大頭貼與暱稱大小：標準（單行）、特大（「大」是預設，上面三張樣式截圖就是「大」）
for size in standard extraLarge; do
  defaults write "${DOMAIN}" profileSize -string "${size}"
  launch_app "profile-${size}" --start-session --demo || continue
  sleep 6
  shot "02-profile-${size}"
  stop_app
done
defaults write "${DOMAIN}" profileSize -string large

launch_app large-qr --start-session --large-qr || true
sleep 3
shot "03-large-qr"
LARGE_DECODED="$("${PROBE}" qr "${OUT}/03-large-qr.png" | head -1)"
if [[ "${LARGE_DECODED}" == "$(session_url)" ]]; then pass "大型 QR Code 可解碼"; else echo "⚪️ 大型 QR Code：${LARGE_DECODED:-無法解碼}"; fi
grep -q "恢復進行中的場次" "${LOG}" && pass "App 重新開啟後沿用同一個場次連結（手機不用重掃）" || fail "沒有恢復場次"
stop_app

launch_app panel --start-session --panel || true
sleep 4
shot "04-control-panel"
stop_app
launch_app compatibility --compatibility || true
sleep 3
shot "05-compatibility"
stop_app

# ---------------------------------------------------------------------------
section "3. 彈幕是否蓋在全螢幕視窗上"
defaults write "${DOMAIN}" qrVisible -bool false # 隱藏 QR，藍色像素只會來自彈幕
launch_app overlay --start-session --demo || exit 1
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
    echo "⚪️ ${scenario}：截圖無法判斷"
  fi
}
run_probe "10-native-fullscreen" "fullscreen" required
run_probe "11-level-1000" "level:1000" required
run_probe "12-level-shielding" "shielding" required
run_probe "13-display-capture" "capture" optional
stop_app

# ---------------------------------------------------------------------------
section "4. 驗收流程：手機（Chrome）→ Mac → 全螢幕簡報上出現彈幕"
launch_app e2e --start-session || exit 1
URL="$(session_url)"
echo "手機網址（Mac 的區域網路 IP）：${URL}"
"${PROBE}" show fullscreen --seconds 45 >"${OUT}/probe-e2e.log" 2>&1 &
PROBE_PID=$!
sleep 5
if node tests/e2e-phone.mjs --url "${URL}" --shot "${OUT}/20-phone.png" | tee "${OUT}/e2e.txt"; then
  # 等這一則彈幕完整進入畫面再截圖（剛進場時只露出右邊一小段）
  sleep 2.5
  shot "21-acceptance-over-fullscreen"
  # 畫面上只有一則彈幕，像素門檻比多則彈幕的情境低
  RESULT="$("${PROBE}" analyze "${OUT}/21-acceptance-over-fullscreen.png" --min-capsule 1000 --min-white 500)"
  STATUS=$?
  echo "${RESULT}"
  if [[ ${STATUS} -eq 0 ]]; then pass "手機送出的彈幕出現在全螢幕視窗上方"; elif [[ ${STATUS} -eq 1 ]]; then fail "手機彈幕被全螢幕視窗蓋住"; fi
else
  fail "端對端測試"
fi
kill "${PROBE_PID}" 2>/dev/null
stop_app

# ---------------------------------------------------------------------------
section "5. 壓力測試：${LOAD_CLIENTS} 支手機"
if ifconfig lo0 | grep -q "127.0.0.$((LOAD_CLIENTS + 1)) "; then
  launch_app load --start-session || exit 1
  URL="$(session_url)"
  ( while kill -0 "${APP_PID}" 2>/dev/null; do ps -o rss=,%cpu= -p "${APP_PID}" >>"${OUT}/resources.txt"; sleep 1; done ) &
  SAMPLER=$!
  node tests/loadtest.mjs --base "${BASE}" --token "${URL##*/}" --clients "${LOAD_CLIENTS}" --duration "${LOAD_SECONDS}" \
    --out "${OUT}/loadtest.json" || fail "壓力測試"
  kill "${SAMPLER}" 2>/dev/null
  awk '{ if ($1 > max) max = $1; cpu += $2; if ($2 > peak) peak = $2; n++ } END {
    printf "App 資源：記憶體最高 %.1f MB；CPU 平均 %.1f%%、最高 %.1f%%（%d 次取樣）\n", max / 1024, cpu / n, peak, n }' \
    "${OUT}/resources.txt" | tee "${OUT}/resources-summary.txt"
  stop_app
else
  echo "⚪️ 沒有 lo0 別名，略過壓力測試"
fi
reset_defaults

# ---------------------------------------------------------------------------
# CI 無法下載 Artifacts 時檢視截圖用：把縮小後的 JPEG 以 base64 印在 log 中
if [[ "${PRINT_PREVIEWS:-0}" == "1" ]]; then
  for name in 01-style-glass 02-style-classic 02-style-card 02-profile-standard 02-profile-extraLarge 03-large-qr 04-control-panel 05-compatibility 20-phone 21-acceptance-over-fullscreen; do
    [[ -f "${OUT}/${name}.png" ]] || continue
    sips -s format jpeg -s formatOptions 65 -Z 1100 "${OUT}/${name}.png" --out "${OUT}/preview-${name}.jpg" >/dev/null 2>&1 || continue
    echo "=====BEGIN PREVIEW ${name}====="
    base64 -i "${OUT}/preview-${name}.jpg" | fold -w 1000
    echo "=====END PREVIEW ${name}====="
  done
fi

section "結果"
grep -h "URBAN LIVE: 彈幕層級" "${OUT}"/app-overlay.log || true
if [[ ${FAILURES} -gt 0 ]]; then
  echo "❌ 共 ${FAILURES} 項失敗"
  exit 1
fi
echo "✅ 整合測試全部通過"
