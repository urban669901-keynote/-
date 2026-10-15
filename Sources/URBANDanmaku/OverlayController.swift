import AppKit
import Combine
import DanmakuCore

/// 管理彈幕 Overlay 視窗：位置（跟著主螢幕）、層級、彈幕舞台與 QR Code 卡片。
final class OverlayController {
    private let settings: Settings
    private let panel: OverlayPanel
    private let rootView = NSView()
    private let stage = DanmakuStageView(frame: .zero)
    private let qrCard = QRCardView(frame: .zero)
    private var cancellables = Set<AnyCancellable>()

    private(set) var isVisible = false
    private(set) var level: Int = NSWindow.Level.screenSaver.rawValue

    init(settings: Settings) {
        self.settings = settings
        let frame = Self.targetScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = OverlayPanel(frame: frame)

        rootView.wantsLayer = true
        rootView.frame = NSRect(origin: .zero, size: frame.size)
        rootView.autoresizingMask = [.width, .height]
        stage.frame = rootView.bounds
        stage.autoresizingMask = [.width, .height]
        rootView.addSubview(stage)
        rootView.addSubview(qrCard) // QR 卡片在彈幕上方，確保隨時掃得到
        panel.contentView = rootView

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // AirPlay 鏡像開始/結束、「為 Apple TV 最佳化」切換解析度時都會觸發
            self?.fitToScreen()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringToFront()
        }

        applySettings()
    }

    /// 主螢幕（有選單列的那個）。鏡像模式下只有這一個螢幕。
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    var panelWindowNumber: Int { panel.windowNumber }
    var activeCount: Int { stage.activeCount + stage.pendingCount }

    func show() {
        isVisible = true
        fitToScreen()
        bringToFront()
    }

    func hide() {
        isVisible = false
        stage.clear()
        panel.orderOut(nil)
    }

    /// 暫時隱藏（例如螢幕鎖定），不清空、不改變 isVisible。
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

    func enqueue(_ text: String) {
        stage.enqueue(text)
    }

    func clear() {
        stage.clear()
    }

    func setURL(_ url: String?) {
        qrCard.setURL(url)
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
        layoutQRCard()
        applyStage()
    }

    private func applySettings() {
        // objectWillChange 在值改變「之前」送出，延到下一輪再讀新值。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyStage()
            self.layoutQRCard()
        }
    }

    private func applyStage() {
        stage.apply(.init(
            fontSize: CGFloat(settings.fontSize),
            crossingSeconds: settings.crossingSeconds,
            opacity: settings.opacity,
            region: settings.region
        ))
    }

    private func layoutQRCard() {
        qrCard.isHidden = !settings.qrVisible
        qrCard.qrSize = CGFloat(settings.qrSize)
        let size = QRCardView.cardSize(qrSize: CGFloat(settings.qrSize))
        let bounds = rootView.bounds
        let margin: CGFloat = 28
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
    }
}
