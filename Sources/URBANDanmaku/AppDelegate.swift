import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusMenu: StatusMenuController!
    private var hotKeys: HotKeyManager!
    private var settingsWindow: HostingWindow<SettingsView>!
    private var compatibilityWindow: HostingWindow<CompatibilityView>!
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保險：即使 Info.plist 沒設 LSUIElement，也以 accessory 身分執行（不出現在 Dock）。
        // 只有 accessory App 的視窗能進入其他 App 的全螢幕 Space。
        NSApp.setActivationPolicy(.accessory)

        // 簡報期間不要被 App Nap 降速（伺服器要即時回應手機）
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "接收即時彈幕"
        )
        ProcessInfo.processInfo.disableAutomaticTermination("接收即時彈幕")

        let settings = Settings.shared
        model = AppModel(settings: settings)

        settingsWindow = HostingWindow(title: "URBAN 即時彈幕 設定") { [unowned self] in
            SettingsView(settings: settings, onPreview: { self.model.sendTestMessage() })
        }
        compatibilityWindow = HostingWindow(title: "相容性測試") { [unowned self] in
            CompatibilityView(test: self.model.compatibilityTest, settings: settings, onStart: {
                self.model.startCompatibilityTest()
            })
        }

        statusMenu = StatusMenuController(model: model)
        statusMenu.openSettings = { [unowned self] in self.settingsWindow.show() }
        statusMenu.openCompatibilityTest = { [unowned self] in self.compatibilityWindow.show() }

        hotKeys = HotKeyManager()
        hotKeys.register([
            .init(keyCode: kVK_ANSI_D, character: "D") { [unowned self] in self.model.toggleOverlay() },
            .init(keyCode: kVK_ANSI_P, character: "P") { [unowned self] in self.model.togglePause() },
            .init(keyCode: kVK_ANSI_C, character: "C") { [unowned self] in self.model.clear() },
            .init(keyCode: kVK_ANSI_R, character: "R") { [unowned self] in self.model.toggleQRCode() },
            .init(keyCode: kVK_ANSI_T, character: "T") { [unowned self] in self.model.sendTestMessage() },
        ])

        model.start()

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") {
            model.startDemo()
        }
        if arguments.contains("--settings") {
            settingsWindow.show()
        }
        if arguments.contains("--compatibility") {
            compatibilityWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.server.stop()
    }

    /// 從 Finder 再次打開 App 時，打開設定視窗（accessory App 沒有 Dock 圖示可以點）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return false
    }
}
