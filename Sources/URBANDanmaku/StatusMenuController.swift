import AppKit
import Combine

/// Mac 選單列圖示與選單：開啟、暫停、清空、QR Code、設定。
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    var openSettings: (() -> Void)?
    var openCompatibilityTest: (() -> Void)?

    /// 全域快捷鍵（與 AppDelegate 註冊的一致，這裡只用來顯示在選單上）。
    enum Shortcut {
        static let toggleOverlay = "d"
        static let pause = "p"
        static let clear = "c"
        static let qrCode = "r"
        static let test = "t"
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "URBAN 即時彈幕"

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
        switch model.overlayState {
        case .live: symbol = "text.bubble.fill"
        case .paused: symbol = "pause.circle.fill"
        case .off: symbol = "text.bubble"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "URBAN 即時彈幕")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "彈" : ""
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        switch model.serverState {
        case .starting:
            menu.addItem(disabledItem("伺服器啟動中…"))
        case let .failed(message):
            menu.addItem(disabledItem("⚠️ 伺服器啟動失敗：\(message)"))
        case .ready:
            if let url = model.phoneURL {
                let item = NSMenuItem(title: "手機網址：\(url)（點一下複製）", action: #selector(copyURL), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            } else {
                menu.addItem(disabledItem("⚠️ 找不到 Wi-Fi 網路，請確認 Mac 已連線"))
            }
            if model.interfaces.count > 1 {
                menu.addItem(interfaceMenuItem())
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("顯示彈幕", #selector(toggleOverlay), Shortcut.toggleOverlay, checked: model.overlayEnabled))
        menu.addItem(item("暫停接收", #selector(togglePause), Shortcut.pause, checked: model.paused))
        menu.addItem(item("清空畫面", #selector(clear), Shortcut.clear))
        menu.addItem(item("顯示 QR Code", #selector(toggleQRCode), Shortcut.qrCode, checked: model.settings.qrVisible))
        menu.addItem(item("發送測試彈幕", #selector(sendTest), Shortcut.test))

        menu.addItem(.separator())
        let settingsItem = item("設定…", #selector(showSettings), ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(item("相容性測試（Keynote / PowerPoint）…", #selector(showCompatibilityTest), nil))

        menu.addItem(.separator())
        let hint = disabledItem("快捷鍵 ⌃⌥⌘ + D 顯示 / P 暫停 / C 清空 / R QR Code")
        menu.addItem(hint)
        let quit = NSMenuItem(title: "結束 URBAN 即時彈幕", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        switch model.overlayState {
        case .live: return "● 接收中｜已收到 \(model.receivedCount) 則"
        case .paused: return "⏸ 已暫停接收｜已收到 \(model.receivedCount) 則"
        case .off: return "○ 彈幕已關閉"
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String?, checked: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        item.target = self
        if key != nil && key != "," {
            item.keyEquivalentModifierMask = [.control, .option, .command]
        }
        if let checked {
            item.state = checked ? .on : .off
        }
        return item
    }

    private func interfaceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "切換網路介面", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for interface in model.interfaces {
            let item = NSMenuItem(title: interface.label, action: #selector(chooseInterface(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interface.name
            item.state = interface == model.currentInterface ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - 動作

    @objc private func copyURL() { model.copyPhoneURL() }
    @objc private func toggleOverlay() { model.toggleOverlay() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func clear() { model.clear() }
    @objc private func toggleQRCode() { model.toggleQRCode() }
    @objc private func sendTest() { model.sendTestMessage() }
    @objc private func showSettings() { openSettings?() }
    @objc private func showCompatibilityTest() { openCompatibilityTest?() }

    @objc private func chooseInterface(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        model.choose(interface: model.interfaces.first { $0.name == name })
    }
}
