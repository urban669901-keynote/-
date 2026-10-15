# URBAN 即時彈幕：技術架構（v1，鏡像顯示版）

## 1. 為什麼改架構

實際使用環境是：

```
同仁手機 ──Wi-Fi──▶ Mac（URBAN 即時彈幕）──AirPlay「鏡像顯示」──▶ Apple TV ──HDMI──▶ 投影機
```

**鏡像模式下 macOS 只有一個畫面**：投影機看到的就是 Mac 螢幕本身。因此：

| 舊想法（延伸螢幕）| 新架構（鏡像） |
| --- | --- |
| 投影端開一個彈幕網頁 / 第二個視窗 | 不需要：投影畫面 = Mac 畫面 |
| 需要「選擇哪個螢幕投影」的雙螢幕管理介面 | 不需要：Overlay 永遠放在主螢幕 |
| 彈幕和簡報分屬不同視窗 | 彈幕必須**疊在 Mac 自己的畫面最上層**，蓋住 Keynote / PowerPoint / PDF / YouTube |

所以核心變成：**一個原生 macOS 透明、置頂、滑鼠穿透的 Overlay 視窗**，加上一個內建的手機網頁伺服器。AirPlay 鏡像會原樣把整個畫面（包含 Overlay）送到 Apple TV，不需要另外處理投影端。

## 2. 元件

```
┌──────────────────────── URBANDanmaku.app（選單列 App，LSUIElement）────────────────────────┐
│                                                                                           │
│  DanmakuServer (Network.framework, :8765)                                                 │
│    GET  /            手機網頁（MobilePage，內嵌 HTML，不依賴 CDN）                         │
│    GET  /api/status  {state: live|paused|off}                                             │
│    POST /api/danmaku {text} ─▶ SubmissionGate（格式 → 狀態 → 清理 → 每支手機限流）        │
│                                         │                                                 │
│                                         ▼                                                 │
│  AppModel（中控）──▶ OverlayController ──▶ OverlayPanel（NSPanel，全螢幕透明）            │
│      ▲                    │                 ├─ DanmakuStageView：軌道分配 + Core Animation │
│      │                    │                 └─ QRCardView：角落的 QR Code 卡片             │
│      │                    ▼                                                               │
│      │            WindowLevelMonitor（每秒讀 CGWindowList，必要時墊高層級）                │
│      │                                                                                    │
│  StatusMenuController（選單列）  HotKeyManager（⌃⌥⌘ 全域快捷鍵）                          │
│  SettingsView / CompatibilityView（SwiftUI 視窗）                                          │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

| 檔案 | 職責 |
| --- | --- |
| `Sources/DanmakuCore/` | 純邏輯、可單元測試：HTTP 解析、訊息清理、限流、軌道分配、顯示區域、視窗層級判斷 |
| `OverlayPanel.swift` | 透明置頂視窗的所有 macOS 設定（見第 3 節） |
| `DanmakuStageView.swift` | 軌道分配、等待佇列、`CABasicAnimation` 捲動 |
| `CapsuleRenderer.swift` | 把文字畫成「深藍半透明玻璃膠囊 + 白色粗體字」點陣圖（彩色 Emoji） |
| `WindowLevelMonitor.swift` | 自動層級 + 診斷資料 |
| `CompatibilityTest.swift` | 60 秒相容性測試，紀錄寫到 `~/Library/Logs/URBANDanmaku/` |
| `DanmakuServer.swift` / `MobilePage.swift` | 手機端伺服器與網頁 |
| `Tools/FullscreenProbe` | CI 測試工具：模擬各種全螢幕方式並分析截圖 |

技術選擇：Swift + AppKit（SwiftUI 只用在設定視窗），**零第三方相依套件**。App 本體約 2 MB，不需要安裝 Node / Python / 瀏覽器。

## 3. macOS 全螢幕、Spaces 與鏡像相容性

### 3.1 讓 Overlay 出現在別人的全螢幕 Space 上

以下條件**缺一不可**（Apple DTS 在開發者論壇的建議，也是 DropOver 等工具的做法）：

| 設定 | 值 | 原因 |
| --- | --- | --- |
| App 啟用政策 | `LSUIElement = true`（accessory）| 一般 App 的視窗無法進入其他 App 的全螢幕 Space |
| 視窗類別 | `NSPanel` + `.nonactivatingPanel` + `.borderless` | 顯示時不會啟用本 App，不會把簡報踢出全螢幕 |
| `collectionBehavior` | `.canJoinAllSpaces` `.fullScreenAuxiliary` `.stationary` `.ignoresCycle`（macOS 13+ 再加 `.canJoinAllApplications`）| 出現在每個 Space（含全螢幕 Space），切換時不跟著滑動 |
| `level` | 至少 `.screenSaver`（1000）| `.floating`(3)、`.statusBar`(25) 會被全螢幕內容蓋住 |
| `ignoresMouseEvents` | `true` | 滑鼠穿透，點擊直接落到簡報上 |
| `hidesOnDeactivate` | `false` | 切到 Keynote 時不會自動隱藏 |
| `canBecomeKey/Main` | `false` | 永遠不搶鍵盤焦點，簡報翻頁鍵不受影響 |
| `sharingType` | `.readOnly` | 允許被擷取 / 鏡像（設成 `.none` 可能讓鏡像、錄影看不到彈幕）|
| `constrainFrameRect` | 原樣回傳 | 讓視窗蓋到選單列區域，真正滿版 |

### 3.2 簡報「播放視窗」的層級不能事先保證 → 自動層級

全螢幕 Space 裡的視窗層級是 0，`screenSaver` 一定在上面。但簡報軟體的**播放模式**可能：

1. 用原生全螢幕 Space（層級 0）→ 沒問題；
2. 用一個蓋滿螢幕、層級更高的視窗 → 需要把 Overlay 墊到它上面；
3. 用 `CGDisplayCapture` 擷取整個螢幕（舊版 Keynote 的做法）→ 系統會在 Shielding 層級放遮罩，Overlay 要在 Shielding 之上才看得到。

Keynote 屬於哪一種、會不會隨版本改變，**無法從文件確定**，所以不做假設：

- `WindowLevelMonitor` 每秒用 `CGWindowListCopyWindowInfo` 讀取螢幕上所有視窗的擁有者與層級（只讀中繼資料，**不需要螢幕錄製權限**）。
- 若有**一般 App**（Dock 上有圖示的 App）的視窗蓋住螢幕 ≥ 80%，且層級 ≥ Overlay，就把 Overlay 設為它的層級 + 1，上限為 Shielding 層級 + 1。
- 系統視窗（登入視窗、鎖定畫面、Dock）不列入，所以不會蓋過鎖定畫面；螢幕鎖定時 Overlay 也會自動隱藏。
- 設定中可改為「固定螢幕保護程式層級」或「固定最高層級」。

### 3.3 實測方式

- **CI 自動測試**（`scripts/smoke-test.sh` + `Tools/FullscreenProbe`）：在 GitHub 的 macOS 機器上，用測試工具分別做出「原生全螢幕 Space」、「層級 1000 滿版視窗」、「Shielding 層級滿版視窗」、「CGDisplayCapture 擷取螢幕」四種情境，截圖後分析像素，確認彈幕膠囊是否出現在紅色測試視窗上方。
- **實機測試**（Keynote、PowerPoint、AirPlay、投影機）無法在 CI 自動化，App 內建「相容性測試」：60 秒內持續發送測試彈幕並記錄所有視窗層級，見 [TESTING.md](TESTING.md)。
- **保底方案**：Keynote「播放 > 在視窗中播放」。視窗化的簡報只是一般視窗，Overlay 一定在它上面。

### 3.4 AirPlay 鏡像

- 鏡像時 `NSScreen.screens` 只有一個，Overlay 永遠使用主螢幕（`NSScreen.screens[0]`）。
- 開始 / 結束鏡像、或 macOS 為 Apple TV 調整解析度時，會收到 `didChangeScreenParametersNotification`，Overlay 自動重設大小與軌道數。
- 瀏海機種使用 `safeAreaInsets` 避開瀏海區域。
- 如果誤選成「延伸顯示器」，相容性測試會顯示「目前是延伸桌面」，彈幕只會出現在主螢幕。

## 4. 彈幕渲染

- 每則彈幕先用 CoreGraphics 畫成點陣圖（膠囊漸層、玻璃反光、邊框、陰影、白色粗體字、彩色 Emoji），再交給 `CALayer` + `CABasicAnimation(position.x)` 線性移動。動畫在 WindowServer 端執行，主執行緒忙碌時也不會卡頓。
- **軌道分配**（`LaneAllocator`）：由上往下找第一條可用軌道；同一軌道的下一則要等前一則尾巴完全進場再留一段間距，且速度較快的新彈幕不會在離場前追撞前一則。
- 所有軌道都滿時排入等待佇列（上限 60 則，等超過 20 秒丟棄），避免活動高峰時塞車越來越久。
- 速度以「通過整個畫面的秒數」定義，所以長短彈幕速度一致、不同解析度體感一致。

## 5. 手機端與 API

| 方法 | 路徑 | 說明 |
| --- | --- | --- |
| GET | `/` | 手機網頁 |
| GET | `/api/status` | `{"state":"live\|paused\|off","message":"…","maxLength":40}` |
| POST | `/api/danmaku` | `{"text":"…"}` → 200 `{"ok":true}`；400 格式錯誤 / 空白；423 暫停中；429 太快（含 `retryAfter`）；503 彈幕關閉 |
| GET | `/healthz` | `ok`（給腳本檢查） |

- 文字清理：換行與 Tab 變空白、連續空白合併、移除 RTL override 與零寬字元、限制組合符號（防 Zalgo）、以「看得到的字元」計算最多 40 字（一個 Emoji 算 1 字）。
- 限流：每支手機（以 IP 區分）連續 3 則，之後每 2 秒補 1 則。
- 僅監聽區域網路，不儲存任何訊息，不需要帳號。

## 6. 已知限制

- 手機與 Mac 必須在同一個區域網路。公司「訪客 Wi-Fi」通常開啟用戶端隔離，手機會連不到 Mac（見 README 疑難排解）。
- 彈幕只出現在主螢幕（鏡像模式下就是唯一的螢幕）；不提供多螢幕管理。
- 沒有內容審核，主持人用「暫停」與「清空」處理。
