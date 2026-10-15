// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "URBANDanmaku",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "URBANDanmaku", targets: ["URBANDanmaku"]),
    ],
    targets: [
        // 純邏輯（HTTP 解析、訊息清理、限流、軌道分配、視窗層級判斷），可單元測試。
        .target(name: "DanmakuCore"),

        // macOS 選單列 App：透明置頂 NSPanel Overlay + 內建手機網頁伺服器。
        .executableTarget(
            name: "URBANDanmaku",
            dependencies: ["DanmakuCore"]
        ),

        // 測試工具（不隨 App 發佈）：模擬全螢幕 / 高層級簡報視窗，並分析截圖，
        // 用於在 CI 的 macOS 上驗證 Overlay 是否真的蓋在全螢幕視窗之上。
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
