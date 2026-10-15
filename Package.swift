// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "URBANLive",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "URBANLive", targets: ["URBANLive"]),
    ],
    targets: [
        // 純邏輯：HTTP / WebSocket 協定、場次、審核、排程、軌道分配、視窗層級判斷。全部有單元測試。
        .target(name: "DanmakuCore"),

        // macOS 選單列 App：透明置頂 NSPanel Overlay + 內建手機網頁與 WebSocket 伺服器。
        .executableTarget(
            name: "URBANLive",
            dependencies: ["DanmakuCore"]
        ),

        // 測試工具（不隨 App 發佈）：模擬全螢幕 / 高層級簡報視窗、分析截圖、解碼 QR Code。
        .executableTarget(
            name: "FullscreenProbe",
            path: "Tools/FullscreenProbe"
        ),

        .testTarget(
            name: "DanmakuCoreTests",
            dependencies: ["DanmakuCore"]
        ),
    ]
)
