# URBAN LIVE 技術架構

## 1. 使用情境與設計前提

```
觀眾手機（iPhone / Android，30～200 人）
      │  掃 QR Code → 手機網頁（不需 App、不需登入）
      │  WebSocket（同一個 Wi-Fi）
      ▼
Mac：URBAN LIVE（選單列 App）──AirPlay「鏡像顯示」──▶ Apple TV ──▶ 投影機 / 電視
      │
      └─ 透明、置頂、滑鼠穿透的彈幕圖層，疊在 Keynote / PowerPoint / PDF / 瀏覽器之上
```

- **鏡像顯示**：投影機看到的就是 Mac 螢幕本身。所以不需要投影端網頁、也不需要雙螢幕管理；
  彈幕只要畫在 Mac 主螢幕最上層，AirPlay 就會原樣送到 Apple TV。
- **不改變原本的簡報方式**：簡報照常在 Mac 播放，不需要上傳到任何系統。

## 2. 技術選型：方案 A（Swift + AppKit）vs 方案 B（Tauri 2 + React）

| 評估項目（依規格的優先順序） | 方案 A：Swift + SwiftUI + AppKit | 方案 B：Tauri 2 + React + TypeScript |
| --- | --- | --- |
| 1. 真正覆蓋 Mac 畫面 | 直接使用 `NSPanel`、`.nonactivatingPanel`、`collectionBehavior`、任意視窗層級 | Tauri 的視窗是 `NSWindow`，要做 non-activating panel、自訂層級需寫 Objective-C／Swift 外掛（如 tauri-nspanel），最後還是回到 AppKit |
| 2. AirPlay 鏡像正常顯示 | `sharingType = .readOnly`，系統合成後原樣鏡像（CI 已截圖驗證圖層可被擷取） | 相同（底層一樣是 AppKit） |
| 3. 不影響簡報操作 | 滑鼠穿透、不搶焦點、accessory App（不進 Dock） | 需外掛處理不搶焦點與 accessory 身分 |
| 4. 手機即時發送 | Network.framework 內建 HTTP + WebSocket，零相依 | Rust 生態成熟（tokio / axum） |
| 5. 穩定性 | 單一原生行程，約 2 MB，記憶體實測 200 人（各自上傳照片）最高 75 MB | WebView + Rust 行程，體積與記憶體較大 |
| 6. 視覺 | Core Animation 在 WindowServer 端動畫，60 FPS 不受主執行緒影響 | WebView CSS 動畫，透明 WebView 在全螢幕 Space 上的行為需另外驗證 |

**結論：採用方案 A。** 最重要的「蓋在全螢幕簡報上」只能靠 AppKit 的視窗 API 完成，用 Tauri 最後還是要寫原生外掛；
手機網頁本身是純 HTML/JS（內嵌在 App 內），不需要 React 也能做到規格要求的介面。

## 3. 元件

```
┌──────────────────────── URBAN LIVE.app（LSUIElement 選單列 App）────────────────────────┐
│ LiveServer（Network.framework，預設埠 8765，被佔用時自動往後找）                           │
│   GET  /j/<場次碼>    手機網頁（MobilePage，內嵌 HTML/CSS/JS，不依賴 CDN）                │
│   GET  /ws?s=<場次碼> WebSocket：hello / profile / send ⇄ welcome / ack / shown / state  │
│   POST /api/send      HTTP 備援（WebSocket 被網路擋住時）                               │
│   GET  /api/status    狀態查詢                                                         │
│                     │ 主執行緒                                                          │
│ AppModel ── LiveSession（隨機場次碼、有效時間、重開 App 後沿用）                          │
│          ── ModerationGate（封鎖 → 狀態 → 清理 → 敏感詞 → 重複 → 佇列 → 每 5 秒 1 則）  │
│          ── OverlayController ─▶ OverlayPanel（NSPanel，全螢幕透明）                    │
│                                  ├─ DanmakuStageView：DanmakuScheduler + Core Animation │
│                                  ├─ QRCardView（角落）／ LargeQRView（大型）           │
│          ── WindowLevelMonitor（每秒讀 CGWindowList，必要時墊高層級）                   │
│          ── HotKeyManager（Carbon 全域快捷鍵，可自訂）                                   │
│ StatusMenuController（選單列）  ControlPanel（SwiftUI：場次 / 外觀與預覽 / 管理 / 快捷鍵）│
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

| 位置 | 內容 |
| --- | --- |
| `Sources/DanmakuCore/` | 純邏輯、全部有單元測試：HTTP 解析、WebSocket（RFC 6455）、場次、審核、敏感詞、重複、限流、排程、軌道、顯示區域、視窗層級判斷 |
| `Sources/URBANLive/` | macOS App：伺服器、Overlay、渲染（三種樣式）、大頭貼、控制面板、選單列、快捷鍵、相容性測試 |
| `Tools/FullscreenProbe/` | 測試工具：模擬全螢幕簡報、分析截圖、解碼螢幕上的 QR Code |
| `tests/` | Node.js 測試：協定測試、200 支手機壓力測試、Chrome 端對端測試 |
| `scripts/` | 打包（App、ZIP、DMG、圖示）與整合測試 |

## 4. macOS 透明彈幕 Overlay

### 4.1 視窗設定（全部在 `OverlayPanel.swift`）

| 需求 | 做法 |
| --- | --- |
| 背景完全透明、無標題列與邊框 | `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`、`isOpaque = false`、`backgroundColor = .clear`、`hasShadow = false` |
| Always on Top | 層級至少 `.screenSaver`（1000），由 `WindowLevelMonitor` 動態調整 |
| 滑鼠穿透 | `ignoresMouseEvents = true`，所有子 view `hitTest` 回傳 nil |
| 不搶鍵盤焦點 | `canBecomeKey/Main = false`、non-activating panel |
| 切換 App 不消失 | `hidesOnDeactivate = false` |
| 多個 Spaces、全螢幕 Space | `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]` + App 為 accessory（`LSUIElement`） |
| AirPlay 鏡像 | `sharingType = .readOnly`（`.none` 會讓擷取 / 鏡像看不到） |
| 滿版（含選單列區域） | `constrainFrameRect` 原樣回傳；跟著 `NSScreen.screens[0]` |
| 解析度變化（開始 / 結束鏡像） | `didChangeScreenParametersNotification` → 重設大小、軌道與 QR 位置 |
| 鎖定畫面 | 收到 `com.apple.screenIsLocked` 時移開，解鎖後恢復 |

不使用任何「關閉系統安全機制」的方式（不需要輔助使用權限、不需要螢幕錄製權限、不改 SIP）。

### 4.2 不假設一定能蓋住 Keynote：自動層級 + 實測

簡報軟體播放時可能用：(1) 原生全螢幕 Space（層級 0）；(2) 更高層級的滿版視窗；(3) `CGDisplayCapture` 擷取螢幕。
Keynote 實際用哪一種、會不會隨版本改變，無法從文件確定，所以：

1. **自動層級**：每秒用 `CGWindowListCopyWindowInfo` 讀取視窗的擁有者與層級（只讀中繼資料，不需螢幕錄製權限）。
   若一般 App 的視窗蓋住螢幕 ≥ 80% 且層級 ≥ 彈幕，就把彈幕墊到它上面一層（上限 Shielding + 1）；
   系統視窗（登入、鎖定畫面）不列入，所以不會蓋過鎖定畫面。
2. **CI 實測**：在 GitHub 的 macOS 15 機器上用 `FullscreenProbe` 做出以上三種情況，截圖分析像素，四種情境都確認彈幕在最上層（見 [TESTING.md](TESTING.md)）。
3. **實機驗證工具**：App 內建「相容性測試」，60 秒內持續發送測試彈幕並記錄所有視窗層級，Keynote / PowerPoint 播放時可以直接看結果。
4. **保底方案**：Keynote「播放 > 在視窗中播放」、PowerPoint「觀眾自行瀏覽（視窗）」。

## 5. 彈幕渲染與動畫

- **三種樣式**（`DanmakuRenderer.swift`）：A 玻璃膠囊（皇家藍 → 深海藍半透明漸層、上緣反光、細邊框、柔和陰影）、
  B 經典高對比（無背景、白字 + 深色描邊 + 陰影）、C URBAN LIVE 訊息卡（白卡、皇家藍字、暖金側條、URBAN LIVE 小標籤）。
  暱稱以暖金（A/B）或電光藍（C）顯示；大頭貼為圓形（Emoji、照片或暱稱首字）。
- **大頭貼與暱稱大小**：標準（單行，大頭貼約 0.76 倍膠囊高）、大（預設，兩行：上行暱稱 0.8 倍字級、下行訊息，大頭貼約 1.7 倍）、
  特大（暱稱 0.95 倍字級，大頭貼約 2.3 倍並超出膠囊上下緣）。大頭貼以 320 px 繪製，相同 Emoji / 首字的大頭貼共用一張圖。
- **很多人都上傳照片**：每張照片解碼後約 400 KB（320×320×4），壓縮檔只有約 20～50 KB。所以 Mac 對每位觀眾只保存手機傳來的壓縮檔，
  他的彈幕要上螢幕時才以 ImageIO 解碼，解碼後的圖只留最近 24 張（LRU；同時最多 5 則在畫面上、12 則排隊，24 張足夠）。
  200 人都用照片時，照片本身約佔 10 MB（實測 200 張平均 50 KB），而不是全部解碼的 80 MB。
  WebSocket 讀取緩衝區在每則訊息處理完後釋放，不會讓每條連線一直留著約 70 KB 的照片訊息。
  實測 200 人各自上傳不同照片：App 記憶體最高 75 MB（RSS），活動監視器約 40 MB（見 [TESTING.md](TESTING.md)）。
  兩行版面每則較高，下方 30% 區域的軌道會從 3 條變 2 條。
- **字體**：系統字型粗體（英數為 SF Pro，中文自動使用蘋方），Emoji 為 Apple Color Emoji 彩色。
- **大小**：以 1920×1080 為基準，設定 48 px 在 1080p 上就是 48 px；其他解析度等比例換算。
  太長的彈幕先縮小字體（最小 60%），仍放不下才截斷加「…」，不會超出畫面。
- **動畫**：每則先畫成點陣圖，交給 `CALayer` + `CABasicAnimation` 線性移動。動畫在 WindowServer 端合成，
  不受主執行緒或簡報軟體忙碌影響；由右側完全進場、移動到完全離開左側。
- **時間**：預設通過畫面約 10 秒（可調 6～16 秒）；長彈幕最多延長 25%，速度稍快但停留較久。
- **軌道與不追撞**（`LaneAllocator`）：同一軌道要等前一則尾巴完全進場並留間距；速度較快的新彈幕在前一則離場前不會追上。
- **同時顯示上限**（`DanmakuScheduler`）：預設最多 5 則；其餘依先後排隊，佇列上限 = 2 × 同時上限 + 2（預設 12 則），
  等超過 30 秒丟棄並通知手機；佇列已滿時新訊息直接告知「太多了，稍後再送」——不假裝成功。

## 6. 手機 ⇄ Mac 協定

WebSocket 文字訊息（JSON，`t` 為類型），完整定義在 `Sources/DanmakuCore/LiveProtocol.swift`：

| 方向 | 訊息 | 用途 |
| --- | --- | --- |
| 手機 → Mac | `hello`（clientId、暱稱、大頭貼） | 連線後第一則 |
| | `profile` | 更新暱稱 / 大頭貼 |
| | `send`（id、text） | 送出彈幕 |
| | `vote`（turn） | 按「講師超棒」；`turn` 是手機看到的講師時段，主持人已換人時回 `stale_turn` |
| Mac → 手機 | `welcome` / `state` | 目前狀態（進行中 / 暫停 / 隱藏 / 結束）與限制，主持人操作時即時推送 |
| | `ack`（ok、code、message、retryAfter） | **Mac 收到並排入顯示佇列**才回成功；被擋下會說明原因 |
| | `shown` | 已出現在大螢幕 |
| | `dropped` | 排隊逾時或被主持人清空，沒有顯示 |
| | `speaker`（speaker、turn、votes、voted） | 主持人開始 / 換 / 結束講師投票（沒有 speaker = 結束） |
| | `vote`（ok、code、votes、voted） | 投票結果：`voted` / `already_voted` / `no_speaker` / `stale_turn` |
| | `votes`（turn、votes） | 票數更新，最多每秒廣播一次（200 人同時投票也只有幾次廣播） |
| | `bye` | 場次結束 / 連結失效 / 被封鎖，手機停止重連並提示 |

手機網頁只有在收到 `ack` 成功時才清空輸入框並顯示「已送出」；6 秒沒有回條就顯示失敗。
WebSocket 斷線會以 0.8 → 1.6 → 3.2 … 秒（最多 10 秒）自動重連；連續失敗 4 次改用 HTTP 備援。

HTTP 備援：`GET /api/status`（含目前講師與是否已投票）、`POST /api/send`、`POST /api/vote`。

## 6.1 講師投票與數據統計

- 邏輯在 `Sources/DanmakuCore/Statistics.swift`（有單元測試），App 端在 `AppModel` 的「講師超棒投票」「數據統計」段落。
- **講師時段**（`SpeakerTurn`）：主持人輸入講師姓名開始；換人時上一位自動結束。每個時段記錄票數與在場人數（時段內最高同時在線）。
- **一人一票**：以觀眾 IP 換算的代號（場次 ID + IP 的 SHA-256，不直接存 IP）判斷，與限流相同；同一個 IP 換瀏覽器或清除資料也不能重投。
- **人數**：參與人數 = 本場連上過的不同代號；最高同時在線每 0.5 秒取樣（同一支手機開兩個分頁算一個）。
- **換名次數**：暱稱換成和上一個不同的名字才算（第一次設定、清空、重新連線不算）；記錄換最多次的人與他用過的名字（只在進行中的場次）。
- **本月最佳講師**：所有講師時段依月份分組，講師姓名以全形半形、大小寫、空白、標點正規化後合併；可依總票數或得票率（票數 ÷ 在場人數）排名。
- **保存**：`~/Library/Application Support/URBANLive/statistics.json`。場次開始 / 結束、換講師時立即寫入，其他變動最多每 15 秒寫一次，App 結束（含收到 SIGTERM）時也會寫入。
  已結束的場次只保存數字與講師姓名（`SessionRecord`）；進行中的場次另外暫存代號與暱稱（防重複投票、換名王），場次結束即刪除。
  檔案損毀時會改名備份並重新開始，不影響 App 開啟。
- **大螢幕**：票數膠囊貼在 QR Code 旁（`VoteBadgeView`，Core Animation；很多人同時投票時重畫合併成一次，👏 排隊飄出最多 16 個）；
  公布卡片（`AnnouncementView`）與大型 QR Code 同一種設計，清空彈幕（⌃⌥⌘C）時一起收起。

## 7. 安全與防濫用

| 項目 | 做法 |
| --- | --- |
| 場次 | 每次「開始彈幕」或「重新產生連結」產生 8 碼隨機場次碼（系統安全亂數，32⁸ ≈ 1 兆種），舊 QR 立即失效；可設定有效時間（預設 3 小時） |
| 沒有遠端控制 | 網路介面只有「看網頁、送彈幕、查狀態」，所有主持人操作只能在 Mac 本機進行 |
| 每位觀眾頻率 | 以 IP 區分，預設每 5 秒 1 則（可調）；被擋下的訊息不消耗額度 |
| 長度 | 預設 25 字（Emoji 算 1 字，可調）；暱稱 10 字 |
| 內容清理 | 去除控制字元、RTL override、零寬字元，限制組合符號（防 Zalgo 亂碼） |
| 敏感詞 | 預設詞庫只收明確辱罵字詞（避免誤擋「幹部」等），比對忽略空白、標點與全半形；主持人可增修 |
| 重複訊息 | 同一人 30 秒內不能重複相同內容（可調） |
| 封鎖 | 控制面板「管理」可封鎖特定觀眾（IP + 裝置識別碼），立即斷線 |
| 洪水攻擊 | 單一連線每秒超過 20 則訊息、單則超過 160 KB、非文字訊框 → 斷線；同時連線上限 800 |
| 跨站連線 | WebSocket 檢查 Origin 必須與 Host 相同（或是設定的外部網址） |
| 照片大頭貼 | 只接受 JPEG / PNG、≤ 96 KB（手機端先裁成 320 px 並壓縮）；Mac 只在記憶體保存壓縮檔，斷線或場次結束即刪除，不寫入磁碟；主持人關閉照片大頭貼後，已連線的人也立即改用暱稱首字 |
| 轉送標頭 | 只有來自本機（通道程式）的連線才信任 `CF-Connecting-IP` / `X-Forwarded-For` |
| 講師投票 | 每人每位講師一票（以 IP 區分）；投票不受發言冷卻影響，但同樣受「單一連線每秒 20 則」與封鎖限制 |
| 統計檔 | 只在本機；不含訊息內容、照片、IP；匯出 CSV 時以 `'` 開頭處理 `= + - @`，避免在試算表被當成公式 |

## 8. 已知限制

- 手機必須連得到 Mac（同一個 Wi-Fi）；其他網路情況見 [NETWORK.md](NETWORK.md)。
- 彈幕只顯示在主螢幕（鏡像模式下就是唯一的螢幕）。
- 預設同時 5 則、每則約 10 秒，螢幕上每分鐘最多約 30 則；人很多時大部分人會收到「稍後再送」。可在控制面板調高同時顯示數或改用全螢幕區域。
- App 為 ad-hoc 簽章，未經 Apple 公證（需要 Apple Developer Program 帳號），第一次開啟需手動允許。
