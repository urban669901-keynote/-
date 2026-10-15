import AppKit
import Combine
import DanmakuCore
import Network

/// App 中控：串起伺服器、Overlay、視窗層級監控與相容性測試。
final class AppModel: ObservableObject {
    let settings: Settings
    let overlay: OverlayController
    let server = DanmakuServer()
    let levelMonitor: WindowLevelMonitor
    let compatibilityTest = CompatibilityTest()

    @Published private(set) var overlayEnabled = false
    @Published private(set) var paused = false
    @Published private(set) var receivedCount = 0
    @Published private(set) var serverState: DanmakuServer.State = .starting
    @Published private(set) var phoneURL: String?
    @Published private(set) var interfaces: [NetworkInfo.Interface] = []
    @Published private(set) var currentInterface: NetworkInfo.Interface?

    private var gate = SubmissionGate()
    private var cancellables = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()
    private var demoTimer: Timer?
    private var sampleIndex = 0

    var overlayState: OverlayState {
        if !overlayEnabled { return .off }
        return paused ? .paused : .live
    }

    init(settings: Settings) {
        self.settings = settings
        overlay = OverlayController(settings: settings)
        levelMonitor = WindowLevelMonitor(mode: settings.levelMode)
    }

    func start() {
        server.router = { [weak self] request, ip in
            self?.route(request, ip: ip) ?? .text(503, "Not ready")
        }
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            self.serverState = state
            if case let .ready(port) = state {
                NSLog("URBANDanmaku: 伺服器已啟動，port \(port)")
            }
            self.refreshURL(preferredName: self.settings.preferredInterface)
        }
        server.start(preferredPort: settings.port)

        levelMonitor.onLevelChange = { [weak self] level, decision in
            self?.overlay.setLevel(level)
            if let window = decision.raisedAbove {
                NSLog("URBANDanmaku: 彈幕層級 → \(level)（墊高到 \(window.ownerName) layer \(window.layer) 之上）")
            } else {
                NSLog("URBANDanmaku: 彈幕層級 → \(level)")
            }
        }
        levelMonitor.onSnapshot = { [weak self] snapshot in
            self?.compatibilityTest.record(snapshot)
        }
        compatibilityTest.emitTestMessage = { [weak self] text in
            self?.display(text, countAsReceived: false)
        }

        settings.$levelMode
            .sink { [weak self] mode in
                guard let self else { return }
                self.levelMonitor.mode = mode
                // 在下一輪才取樣，確保其他訂閱者也拿到新值
                DispatchQueue.main.async { self.levelMonitor.tick() }
            }
            .store(in: &cancellables)
        settings.$preferredInterface
            .dropFirst()
            .sink { [weak self] name in self?.refreshURL(preferredName: name) }
            .store(in: &cancellables)

        // Wi-Fi 切換、拿到新 IP 時更新 QR Code
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshURL(preferredName: self.settings.preferredInterface)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.urban.danmaku.path"))

        // 螢幕鎖定時隱藏彈幕，解鎖後恢復
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.overlay.suspend()
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.overlay.resume()
        }

        setOverlayEnabled(true)
        levelMonitor.start()
    }

    // MARK: - 指令（選單、快捷鍵）

    func setOverlayEnabled(_ enabled: Bool) {
        overlayEnabled = enabled
        if enabled {
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    func toggleOverlay() {
        setOverlayEnabled(!overlayEnabled)
    }

    func togglePause() {
        paused.toggle()
    }

    func clear() {
        overlay.clear()
    }

    func toggleQRCode() {
        settings.qrVisible.toggle()
    }

    /// 發送一則範例彈幕（不受暫停與限流影響；若彈幕關閉中會自動開啟）。
    func sendTestMessage() {
        let text = Theme.sampleMessages[sampleIndex % Theme.sampleMessages.count]
        sampleIndex += 1
        display(text, countAsReceived: false)
    }

    func startCompatibilityTest() {
        compatibilityTest.start(mode: settings.levelMode)
    }

    /// `--demo`：持續發送範例彈幕（展示、截圖、CI 冒煙測試用）。
    func startDemo(interval: TimeInterval = 0.7) {
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sendTestMessage()
        }
        sendTestMessage()
    }

    func copyPhoneURL() {
        guard let phoneURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phoneURL, forType: .string)
    }

    func choose(interface: NetworkInfo.Interface?) {
        settings.preferredInterface = interface?.name
    }

    private func display(_ text: String, countAsReceived: Bool) {
        if !overlayEnabled {
            setOverlayEnabled(true)
        }
        overlay.enqueue(text)
        if countAsReceived {
            receivedCount += 1
        }
    }

    // MARK: - 網址

    private func refreshURL(preferredName: String?) {
        interfaces = NetworkInfo.candidateInterfaces()
        let chosen = interfaces.first(where: { $0.name == preferredName }) ?? interfaces.first
        currentInterface = chosen
        if case let .ready(port) = serverState, let chosen {
            phoneURL = "http://\(chosen.address):\(port)"
        } else {
            phoneURL = nil
        }
        overlay.setURL(phoneURL)
    }

    // MARK: - HTTP 路由

    private func route(_ request: HTTPRequest, ip: String) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(MobilePage.html)

        case ("GET", "/api/status"):
            let state = overlayState
            return .json(200, StatusPayload(state: state.rawValue, message: state.phoneMessage, maxLength: gate.maxLength))

        case ("POST", "/api/danmaku"):
            let outcome = gate.evaluate(
                body: request.body,
                clientKey: ip,
                now: ProcessInfo.processInfo.systemUptime,
                state: overlayState
            )
            switch outcome {
            case let .accepted(text):
                display(text, countAsReceived: true)
                return .json(200, APIResult(ok: true, code: "ok", message: "已送出"))
            case let .rejected(status, result):
                return .json(status, result)
            }

        case ("GET", "/healthz"):
            return .text(200, "ok")

        case ("GET", "/favicon.ico"), ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"):
            return HTTPResponse(status: 204)

        case (_, "/api/danmaku"), (_, "/api/status"):
            return .text(405, "Method Not Allowed")

        default:
            return .text(404, "Not Found")
        }
    }
}
