import AppKit
import Combine

/// Mac 選單列圖示與選單。
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    var openControlPanel: (() -> Void)?
    var openCompatibilityTest: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "URBAN LIVE"

        model.objectWillChange
            .merge(with: model.settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
            .store(in: &cancellables)
        updateIcon()
    }

    private func updateIcon() {
        let symbol: String
        switch model.liveState {
        case .live: symbol = "text.bubble.fill"
        case .paused: symbol = "pause.circle.fill"
        case .hidden: symbol = "eye.slash"
        case .ended: symbol = "text.bubble"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "URBAN LIVE")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "LIVE" : ""
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcuts = model.settings.shortcuts

        menu.addItem(disabled(statusLine()))
        if let url = model.phoneURL {
            menu.addItem(item("複製手機連結：\(url)", #selector(copyURL)))
        } else if case let .failed(message) = model.serverState {
            menu.addItem(disabled("⚠️ 伺服器啟動失敗：\(message)"))
        }

        menu.addItem(.separator())
        if model.session == nil {
            menu.addItem(item("開始彈幕", #selector(startSession)))
        } else {
            menu.addItem(item(model.paused ? "恢復彈幕" : "暫停彈幕", #selector(togglePause), shortcuts[.togglePause]))
            menu.addItem(item(model.overlayHidden ? "顯示彈幕" : "隱藏彈幕", #selector(toggleOverlay), shortcuts[.toggleOverlay]))
            menu.addItem(item("清空彈幕", #selector(clear), shortcuts[.clearScreen]))
            let qr = item("顯示 QR Code", #selector(toggleQR), shortcuts[.toggleQRCode])
            qr.state = model.settings.qrVisible && !model.largeQR ? .on : .off
            menu.addItem(qr)
            let large = item("大型 QR Code（開場掃描用）", #selector(toggleLargeQR))
            large.state = model.largeQR ? .on : .off
            menu.addItem(large)
            menu.addItem(item("重新產生場次連結", #selector(regenerate)))
            menu.addItem(item("結束場次", #selector(endSession)))
        }
        menu.addItem(item("發送測試彈幕", #selector(sendTest)))

        menu.addItem(.separator())
        let panel = item("開啟控制面板…", #selector(showPanel))
        panel.keyEquivalent = ","
        panel.keyEquivalentModifierMask = [.command]
        menu.addItem(panel)
        menu.addItem(item("相容性測試（Keynote / PowerPoint）…", #selector(showCompatibility)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束 URBAN LIVE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        let stats = model.stats
        switch model.liveState {
        case .live: return "● 彈幕進行中｜\(stats.connected) 支手機｜已顯示 \(stats.shown) 則"
        case .paused: return "⏸ 已暫停｜\(stats.connected) 支手機"
        case .hidden: return "◌ 彈幕已隱藏｜\(stats.connected) 支手機"
        case .ended: return "○ 尚未開始場次"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, _ shortcut: Shortcut? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut {
            item.keyEquivalent = shortcut.key.lowercased()
            var mask: NSEvent.ModifierFlags = []
            if shortcut.display.contains("⌃") { mask.insert(.control) }
            if shortcut.display.contains("⌥") { mask.insert(.option) }
            if shortcut.display.contains("⇧") { mask.insert(.shift) }
            if shortcut.display.contains("⌘") { mask.insert(.command) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    // MARK: - 動作

    @objc private func copyURL() { model.copyPhoneURL() }
    @objc private func startSession() { model.startSession() }
    @objc private func endSession() { model.endSession() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func toggleOverlay() { model.toggleOverlayHidden() }
    @objc private func clear() { model.clearScreen() }
    @objc private func toggleQR() { model.toggleQRCode() }
    @objc private func toggleLargeQR() { model.largeQR.toggle() }
    @objc private func regenerate() { model.regenerateLink() }
    @objc private func sendTest() { model.sendTestMessage() }
    @objc private func showPanel() { openControlPanel?() }
    @objc private func showCompatibility() { openCompatibilityTest?() }
}
