import AppKit
import Combine
import DanmakuCore

/// 管理彈幕 Overlay 視窗：位置（跟著主螢幕）、層級、彈幕舞台與 QR Code。
final class OverlayController {
    private let settings: Settings
    private let panel: OverlayPanel
    private let rootView = NSView()
    let stage = DanmakuStageView(frame: .zero)
    private let qrCard = QRCardView(frame: .zero)
    private let largeQR = LargeQRView(frame: .zero)
    private var cancellables = Set<AnyCancellable>()

    private(set) var isVisible = false
    private(set) var level: Int = NSWindow.Level.screenSaver.rawValue
    private var url: String?
    var largeQRVisible = false {
        didSet { layoutQR() }
    }

    init(settings: Settings) {
        self.settings = settings
        let frame = Self.targetScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = OverlayPanel(frame: frame)

        rootView.wantsLayer = true
        rootView.frame = NSRect(origin: .zero, size: frame.size)
        rootView.autoresizingMask = [.width, .height]
        stage.frame = rootView.bounds
        stage.autoresizingMask = [.width, .height]
        largeQR.frame = rootView.bounds
        largeQR.autoresizingMask = [.width, .height]
        rootView.addSubview(stage)
        rootView.addSubview(qrCard) // QR Code 在彈幕上方，隨時掃得到
        rootView.addSubview(largeQR)
        panel.contentView = rootView

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 在值改變「之前」送出，延到下一輪再讀新值
                DispatchQueue.main.async { self?.applySettings() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // AirPlay 鏡像開始 / 結束、為 Apple TV 調整解析度時都會觸發
            self?.fitToScreen()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.bringToFront()
        }
        applySettings()
    }

    /// 主螢幕（有選單列的那個）。鏡像模式下只有這一個螢幕。
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    func show() {
        isVisible = true
        fitToScreen()
        bringToFront()
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
    }

    /// 暫時移開（螢幕鎖定），不改變 isVisible。
    func suspend() {
        panel.orderOut(nil)
    }

    func resume() {
        if isVisible { bringToFront() }
    }

    func bringToFront() {
        guard isVisible else { return }
        panel.orderFrontRegardless()
    }

    /// 目前 QR Code 指向的網址；nil 代表沒有場次，QR Code 不顯示。
    func setURL(_ url: String?) {
        self.url = url
        qrCard.setURL(url)
        largeQR.setURL(url)
        layoutQR()
    }

    func setLevel(_ newLevel: Int) {
        guard newLevel != level else { return }
        level = newLevel
        panel.level = NSWindow.Level(rawValue: newLevel)
        bringToFront()
    }

    func fitToScreen() {
        guard let screen = Self.targetScreen() else { return }
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }
        applySettings()
    }

    private func applySettings() {
        stage.apply(.init(
            style: settings.style,
            referenceFontSize: settings.fontSize,
            crossingSeconds: settings.crossingSeconds,
            opacity: settings.opacity,
            area: settings.area,
            maxConcurrent: settings.maxConcurrent,
            profileSize: settings.profileSize,
            profilesShown: settings.showNickname || settings.showAvatar
        ))
        layoutQR()
    }

    private func layoutQR() {
        let hasURL = url != nil
        largeQR.isHidden = !(hasURL && largeQRVisible)
        qrCard.isHidden = !(hasURL && settings.qrVisible) || largeQRVisible

        let bounds = rootView.bounds
        let scale = bounds.height / 1080
        let qrSize = CGFloat(settings.qrSize) * max(scale, 0.5)
        qrCard.qrSize = qrSize
        let size = QRCardView.cardSize(qrSize: qrSize)
        let margin = 28 * max(scale, 0.5)
        let topInset = (panel.screen ?? Self.targetScreen())?.safeAreaInsets.top ?? 0
        let x: CGFloat
        let y: CGFloat
        switch settings.qrPosition {
        case .bottomRight:
            x = bounds.maxX - size.width - margin
            y = bounds.minY + margin
        case .bottomLeft:
            x = bounds.minX + margin
            y = bounds.minY + margin
        case .topRight:
            x = bounds.maxX - size.width - margin
            y = bounds.maxY - size.height - margin - topInset
        case .topLeft:
            x = bounds.minX + margin
            y = bounds.maxY - size.height - margin - topInset
        }
        qrCard.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        qrCard.needsDisplay = true
        largeQR.needsDisplay = true
    }
}
