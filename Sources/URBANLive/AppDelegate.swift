import AppKit
import DanmakuCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusMenu: StatusMenuController!
    private var controlPanel: HostingWindow<ControlPanelView>!
    private var compatibilityWindow: HostingWindow<CompatibilityView>!
    private var activity: NSObjectProtocol?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 accessory 身分執行（不出現在 Dock）：只有這樣，彈幕視窗才能進入其他 App 的全螢幕 Space。
        NSApp.setActivationPolicy(.accessory)

        // 簡報期間不要被 App Nap 降速（伺服器要即時回應手機）
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "URBAN LIVE 即時彈幕"
        )
        ProcessInfo.processInfo.disableAutomaticTermination("URBAN LIVE 即時彈幕")

        let settings = Settings.shared
        let arguments = ProcessInfo.processInfo.arguments
        // --stats-file：自動測試用，統計寫到指定檔案，不碰使用者的資料
        let statisticsURL = Self.value(after: "--stats-file", in: arguments).map { URL(fileURLWithPath: $0) }
        model = AppModel(settings: settings, statisticsURL: statisticsURL)

        // 收到 SIGTERM（例如 kill、系統要求結束）時也先寫入統計檔再結束
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source

        compatibilityWindow = HostingWindow(title: "相容性測試") { [unowned self] in
            CompatibilityView(test: self.model.compatibilityTest, settings: settings, onStart: {
                self.model.startCompatibilityTest()
            })
        }
        controlPanel = HostingWindow(title: "URBAN LIVE 控制面板") { [unowned self] in
            ControlPanelView(model: self.model, settings: settings, openCompatibilityTest: {
                self.compatibilityWindow.show()
            })
        }

        statusMenu = StatusMenuController(model: model)
        statusMenu.openControlPanel = { [unowned self] in self.controlPanel.show() }
        statusMenu.openCompatibilityTest = { [unowned self] in self.compatibilityWindow.show() }

        model.start()

        if arguments.contains("--start-session") {
            model.startSession()
        }
        if let speaker = Self.value(after: "--speaker", in: arguments) {
            model.startVoting(for: speaker)
        }
        if let kind = Self.value(after: "--gift-demo", in: arguments).flatMap(GiftKind.init(rawValue:)) {
            model.startGiftDemo(kind)
        }
        switch Self.value(after: "--announce", in: arguments) {
        case "best": model.showBestSpeaker()
        case "summary": model.showSessionSummary()
        default: break
        }
        if let tab = Self.value(after: "--panel-tab", in: arguments) {
            model.panelTab = tab
        }
        if arguments.contains("--large-qr") {
            model.largeQR = true
        }
        if arguments.contains("--demo") {
            model.startDemo()
        }
        if arguments.contains("--compatibility") {
            compatibilityWindow.show()
        } else if arguments.contains("--panel") || (settings.openPanelAtLaunch && !arguments.contains("--no-panel")) {
            controlPanel.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// 從 Finder / Launchpad 再次打開 App 時，打開控制面板（選單列 App 沒有 Dock 圖示可以點）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlPanel?.show()
        return false
    }
}
