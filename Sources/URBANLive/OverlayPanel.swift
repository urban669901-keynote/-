import AppKit

/// 全螢幕透明、置頂、滑鼠穿透的彈幕視窗。
///
/// 能蓋在其他 App 全螢幕 Space（YouTube、PowerPoint、PDF、Keynote 編輯畫面）上的必要條件：
/// 1. App 為 accessory（Info.plist 的 LSUIElement）—— 一般 App 的視窗無法進入別人的全螢幕 Space；
/// 2. 使用 `.nonactivatingPanel` 的 NSPanel —— 顯示時不會啟用本 App，不會把簡報踢出全螢幕；
/// 3. collectionBehavior 含 `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.stationary`；
/// 4. 視窗層級至少為 `.screenSaver`（.floating / .statusBar 會被全螢幕內容蓋住）。
///
/// Keynote 播放中的視窗層級無法事先保證，因此層級由 `WindowLevelMonitor` 動態調整，
/// 並提供「相容性測試」實測。
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "URBAN 彈幕 Overlay"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true        // 滑鼠穿透：點擊直接落到簡報上
        isFloatingPanel = true
        hidesOnDeactivate = false        // 切到 Keynote 時不要自動隱藏
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        sharingType = .readOnly          // 允許被螢幕鏡像 / 擷取（.none 會讓 AirPlay、錄影看不到）
        level = .screenSaver

        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,           // 出現在每一個桌面與全螢幕 Space
            .fullScreenAuxiliary,        // 允許和別人的全螢幕視窗並存
            .stationary,                 // Mission Control / 切換 Space 時不跟著動
            .ignoresCycle,               // 不出現在 ⌘` 視窗循環
        ]
        if #available(macOS 13.0, *) {
            behavior.insert(.canJoinAllApplications)
        }
        collectionBehavior = behavior
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 不要讓系統把視窗限制在選單列下方；彈幕要蓋滿整個螢幕。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
