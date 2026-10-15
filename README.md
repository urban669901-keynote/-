# URBAN 即時彈幕（macOS）

同仁用手機掃 QR Code 發送文字或 Emoji，彈幕即時飄過 Mac 畫面；Mac 以 **AirPlay 鏡像** 投到 Apple TV / 投影機，觀眾看到的就是疊了彈幕的簡報。

```
同仁手機 ──同一個 Wi-Fi──▶ Mac（URBAN 即時彈幕）──AirPlay 鏡像──▶ Apple TV ──▶ 投影機
```

- 原生 macOS 選單列 App：透明、置頂、**滑鼠穿透**的彈幕層，蓋在 Keynote、PowerPoint、PDF、YouTube、一般桌面上
- URBAN Blue 風格：深藍半透明玻璃膠囊、白色粗體字，預設 48 px
- 可調整字體大小、速度、不透明度、顯示區域；QR Code 可顯示 / 隱藏
- 內建手機網頁伺服器，不需安裝任何其他軟體，不需要網際網路
- 播放簡報時用全域快捷鍵暫停、清空、切換 QR Code

架構說明見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)；Keynote 相容性與實機測試清單見 [docs/TESTING.md](docs/TESTING.md)。

## 安裝

### 方式一：下載編譯好的 App
1. 到 GitHub 專案的 **Actions** →「macOS build & smoke test」→ 最新一次成功的執行 → 下載 Artifacts 中的 **URBANDanmaku-app**。
2. 解壓縮兩次（Artifacts 外層一個 zip，裡面是 `URBANDanmaku.zip`），把 `URBANDanmaku.app` 拖到「應用程式」。
3. 第一次打開：這個 App 沒有 Apple 開發者簽章，macOS 會擋下。請到 **系統設定 → 隱私權與安全性**，在下方按「強制打開」（macOS 14 以前可在 Finder 對 App 按右鍵 →「打開」）。

### 方式二：自己編譯（需要 Xcode 或 Command Line Tools，macOS 12 以上）
```bash
./scripts/build-app.sh            # 產生 dist/URBANDanmaku.app
open dist/URBANDanmaku.app
```

### 第一次啟動會看到的系統詢問
- **「是否允許接受連入的網路連線？」** → 允許（手機要連進來）。
- **「是否允許尋找區域網路上的裝置？」**（較新的 macOS）→ 允許。

## 會議前準備（約 3 分鐘）

1. **Mac 與手機連同一個 Wi-Fi**（不要用訪客網路，見疑難排解）。
2. **開啟 AirPlay 鏡像**：控制中心 →「螢幕鏡像」→ 選 Apple TV → 選 **鏡像** 內建顯示器（不要選「作為延伸顯示器」）。
3. **打開 URBAN 即時彈幕**：選單列出現對話框圖示，畫面右下角出現 QR Code。
4. 選單列 →「發送測試彈幕」，確認投影畫面看得到。
5. 打開簡報開始播放。**第一次使用 Keynote 播放前，請先做一次「相容性測試」**（見下方）。

## 選單列與快捷鍵

| 功能 | 選單列 | 全域快捷鍵（播放簡報時也能用） |
| --- | --- | --- |
| 顯示 / 關閉彈幕 | 顯示彈幕 | ⌃⌥⌘D |
| 暫停 / 繼續接收 | 暫停接收 | ⌃⌥⌘P |
| 清空畫面上的彈幕 | 清空畫面 | ⌃⌥⌘C |
| 顯示 / 隱藏 QR Code | 顯示 QR Code | ⌃⌥⌘R |
| 發送測試彈幕 | 發送測試彈幕 | ⌃⌥⌘T |
| 設定 | 設定… | |
| 相容性測試 | 相容性測試（Keynote / PowerPoint）… | |

⌃ = Control、⌥ = Option、⌘ = Command。Keynote 播放時選單列不會出現，請用快捷鍵。

- **暫停接收**：畫面上的彈幕繼續跑完，新送出的會被擋下，手機顯示「主持人暫停了彈幕」。
- **關閉彈幕**：整個彈幕層（含 QR Code）隱藏，手機顯示「彈幕目前沒有開啟」。
- 選單第二行是手機網址，點一下可複製；Mac 有多個網路（例如 Wi-Fi + 有線）時可在「切換網路介面」選擇手機連得到的那個。

## 設定

| 項目 | 預設 | 範圍 |
| --- | --- | --- |
| 字體大小 | 48 px | 24–120 px |
| 速度（通過整個畫面的時間） | 9 秒 | 4–20 秒 |
| 不透明度 | 100% | 20–100% |
| 顯示區域 | 上方 2/3 | 預設組合：上方 1/3、上半部、上方 2/3、全畫面、下半部，或自訂上下緣 |
| QR Code | 顯示、右下、200 px | 四個角落、120–360 px |
| 視窗層級 | 自動 | 自動 / 螢幕保護程式層級 / 最高層級 |

手機端：每則最多 40 字（Emoji 算 1 字），同一支手機連續 3 則後每 2 秒 1 則。

## 各種簡報軟體

| 軟體 | 建議做法 | 狀態 |
| --- | --- | --- |
| 一般桌面、網頁 | 直接使用 | CI 已自動驗證 |
| YouTube | 瀏覽器影片全螢幕 | 原生全螢幕 Space，CI 已自動驗證此類情境 |
| PDF | 預覽程式全螢幕 / 幻燈片秀 | 原生全螢幕情境 CI 已驗證；請用相容性測試確認 |
| PowerPoint | 投影片放映 | 請用相容性測試確認；保底：「觀眾自行瀏覽（視窗）」 |
| **Keynote** | 播放 | **請務必先用相容性測試確認**；保底：「播放 > 在視窗中播放」 |

Keynote 的完整方案（A 自動層級 → B 最高層級 → C Keynote 設定 → D 視窗模式）見 [docs/TESTING.md](docs/TESTING.md#3-keynote-可行方案依序嘗試)。

## 疑難排解

**手機打不開網頁 / 一直轉圈**
- 確認手機與 Mac 在**同一個 Wi-Fi**。公司「訪客網路」通常開啟「用戶端隔離」，手機之間、手機與電腦之間互相連不到 → 改用內部 Wi-Fi，或用 Mac 的「網際網路共享」/ 手機熱點讓大家連同一個網路。
- 關閉 Mac 的 VPN 再試。
- 系統設定 → 網路 → 防火牆：確認「URBAN 即時彈幕」為「允許連入連線」。
- QR Code 上的位址不是 Wi-Fi 的位址：選單列 →「切換網路介面」選 Wi-Fi（通常是 en0）。

**Keynote 播放時看不到彈幕**
依序試 [docs/TESTING.md](docs/TESTING.md#3-keynote-可行方案依序嘗試) 的方案 B → C → D。若都不行，請把 `~/Library/Logs/URBANDanmaku/` 裡的相容性測試紀錄傳給開發者。

**Apple TV 上看不到、Mac 上看得到**
確認是「鏡像」而不是「延伸顯示器」：相容性測試視窗的顯示器資訊應為「啟用中 1 個」。

**埠號 8765 被佔用**
App 會自動改用 8766、8767…，QR Code 會跟著更新。要固定其他埠號：`defaults write com.urban.danmaku port 9000` 後重新開啟 App。

## 開發

```bash
swift test                     # 核心邏輯單元測試
./scripts/build-app.sh         # 打包 App（UNIVERSAL=1 產生 Apple 晶片 + Intel 版本）
./scripts/smoke-test.sh        # 啟動 App、測 API、截圖驗證全螢幕覆蓋
open dist/URBANDanmaku.app --args --demo   # 展示模式：持續發送範例彈幕
```

品牌色在 `Sources/URBANDanmaku/Theme.swift`。
