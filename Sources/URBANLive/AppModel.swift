import AppKit
import Combine
import DanmakuCore
import Network

/// 即時統計（每 0.5 秒更新一次到畫面，避免 200 人同時發送時 UI 過度重繪）。
struct LiveStats: Equatable {
    var connected = 0
    var received = 0
    var accepted = 0
    var rejected = 0
    var shown = 0
    var dropped = 0
    var queued = 0
    var onScreen = 0
    /// 最近一則上場前排隊的秒數
    var lastWait: Double = 0
}

/// 最近發言的觀眾（控制面板可封鎖）。
struct SenderRecord: Identifiable, Equatable {
    var id: String { address }
    let address: String
    var clientId: String?
    var nickname: String?
    var lastMessage: String
    var count: Int
    var lastAt: Date
}

/// 一支已連線的手機。
private final class Viewer {
    let id: Int
    let address: String
    var clientId: String?
    var nickname: String?
    var avatarImage: CGImage?

    init(id: Int, address: String) {
        self.id = id
        self.address = address
    }
}

/// App 中控：場次、伺服器、審核、Overlay、快捷鍵、統計。所有狀態都在主執行緒。
final class AppModel: ObservableObject {
    let settings: Settings
    let overlay: OverlayController
    let server = LiveServer()
    let levelMonitor: WindowLevelMonitor
    let compatibilityTest = CompatibilityTest()
    private let hotKeys = HotKeyManager()

    @Published private(set) var session: LiveSession?
    @Published private(set) var paused = false
    @Published private(set) var overlayHidden = false
    @Published var largeQR = false {
        didSet { overlay.largeQRVisible = largeQR }
    }
    @Published private(set) var stats = LiveStats()
    @Published private(set) var senders: [SenderRecord] = []
    @Published private(set) var blocked: [SenderRecord] = []
    @Published private(set) var serverState: LiveServer.State = .starting
    /// 區域網路網址（不含場次）
    @Published private(set) var lanURL: String?
    /// 手機加入網址（QR Code 內容）
    @Published private(set) var phoneURL: String?
    @Published private(set) var interfaces: [NetworkInfo.Interface] = []
    @Published private(set) var currentInterface: NetworkInfo.Interface?
    @Published private(set) var hotkeyFailures: Set<ShortcutAction> = []
    @Published private(set) var clock = Date()
    /// 錄製快捷鍵時暫停全域快捷鍵，避免按下的組合被攔截
    @Published var recordingShortcut = false {
        didSet { recordingShortcut ? hotKeys.unregisterAll() : registerHotkeys() }
    }

    private var gate: ModerationGate
    private var viewers: [Int: Viewer] = [:]
    private var counters = LiveStats()
    private var senderMap: [String: SenderRecord] = [:]
    private var sendersDirty = false
    private var cancellables = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()
    private var clockTimer: Timer?
    private var demoTimer: Timer?
    private var sampleIndex = 0
    private var messageCounter = 0
    private static let sessionKey = "activeSession"

    var liveState: LiveState {
        if session == nil { return .ended }
        if overlayHidden { return .hidden }
        return paused ? .paused : .live
    }

    init(settings: Settings) {
        self.settings = settings
        overlay = OverlayController(settings: settings)
        levelMonitor = WindowLevelMonitor(mode: settings.levelMode)
        gate = ModerationGate(settings: settings.moderation)
    }

    // MARK: - 啟動

    func start() {
        server.router = { [weak self] request, address in
            self?.route(request, address: address) ?? .text(503, "Not ready")
        }
        server.onEvent = { [weak self] event in self?.handle(event) }
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            self.serverState = state
            if case let .ready(port) = state { NSLog("URBAN LIVE: 伺服器已啟動，port \(port)") }
            self.refreshURL()
        }
        server.start(preferredPort: settings.port)

        overlay.stage.onShown = { [weak self] item, waited in self?.didShow(item, waited: waited) }
        overlay.stage.onDropped = { [weak self] item, reason in self?.didDrop(item, reason: reason) }

        levelMonitor.onLevelChange = { [weak self] level, decision in
            self?.overlay.setLevel(level)
            if let window = decision.raisedAbove {
                NSLog("URBAN LIVE: 彈幕層級 → \(level)（墊高到 \(window.ownerName) layer \(window.layer) 之上）")
            } else {
                NSLog("URBAN LIVE: 彈幕層級 → \(level)")
            }
        }
        levelMonitor.onSnapshot = { [weak self] snapshot in self?.compatibilityTest.record(snapshot) }
        compatibilityTest.emitTestMessage = { [weak self] text in
            self?.displayInternal(DanmakuContent(text: text, nickname: "相容性測試", avatar: nil))
        }

        settings.$levelMode
            .sink { [weak self] mode in
                guard let self else { return }
                self.levelMonitor.mode = mode
                DispatchQueue.main.async { self.levelMonitor.tick() }
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsChanged() }
            }
            .store(in: &cancellables)
        settings.$shortcuts
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotkeys() } }
            .store(in: &cancellables)

        // Wi-Fi 切換、拿到新 IP 時更新 QR Code
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshURL() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.urban.live.path"))

        // 螢幕鎖定時移開彈幕，解鎖後恢復
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.overlay.suspend()
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.overlay.resume()
        }

        // 若上次的場次還沒過期（例如 App 意外關閉後重開），沿用同一個連結，手機不用重掃
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let saved = try? JSONDecoder().decode(LiveSession.self, from: data),
           !saved.isExpired() {
            session = saved
            NSLog("URBAN LIVE: 恢復進行中的場次")
        }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer

        overlay.show()
        levelMonitor.start()
        registerHotkeys()
    }

    private func settingsChanged() {
        if gate.settings != settings.moderation {
            gate.update(settings.moderation)
        }
        refreshURL()
    }

    private func tick() {
        if let session, session.isExpired() {
            endSession(message: "場次時間已到，謝謝參與")
        }
        let now = Date()
        if session != nil, Int(now.timeIntervalSince1970) != Int(clock.timeIntervalSince1970) { clock = now }
        counters.connected = viewers.count
        counters.queued = overlay.stage.pendingCount
        counters.onScreen = overlay.stage.onScreenCount
        if counters != stats { stats = counters }
        if sendersDirty {
            sendersDirty = false
            senders = senderMap.values.sorted { $0.lastAt > $1.lastAt }
        }
    }

    // MARK: - 場次

    func startSession() {
        if let session, !session.isExpired() {
            paused = false
            setOverlayHidden(false)
            broadcastState()
            return
        }
        let newSession = LiveSession.start(duration: settings.sessionHours * 3600)
        session = newSession
        persistSession()
        gate.resetForNewSession()
        blocked = []
        senderMap = [:]
        sendersDirty = true
        counters = LiveStats()
        paused = false
        settings.qrVisible = true
        setOverlayHidden(false)
        refreshURL()
        NSLog("URBAN LIVE: 場次開始 \(phoneURL ?? "（尚無網址）")")
    }

    func endSession(message: String = "場次已結束，謝謝參與") {
        guard session != nil else { return }
        let bye = ServerMessage(t: "bye", code: "ended", message: message).json()
        for id in viewers.keys {
            server.close(id, finalMessage: bye, code: 4000)
        }
        viewers.removeAll()
        overlay.stage.clearScreen()
        session = nil
        persistSession()
        largeQR = false
        paused = false
        refreshURL()
        NSLog("URBAN LIVE: 場次結束")
    }

    /// 產生新的場次連結；舊 QR Code 立即失效，已連線的手機會被要求重新掃描。
    func regenerateLink() {
        guard session != nil else {
            startSession()
            return
        }
        let bye = ServerMessage(t: "bye", code: "relinked", message: "場次連結已更新，請重新掃描大螢幕上的 QR Code").json()
        for id in viewers.keys {
            server.close(id, finalMessage: bye, code: 4000)
        }
        viewers.removeAll()
        session = LiveSession.start(duration: settings.sessionHours * 3600)
        persistSession()
        refreshURL()
        NSLog("URBAN LIVE: 已重新產生連結 \(phoneURL ?? "")")
    }

    private func persistSession() {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        }
    }

    // MARK: - 主持人操作（選單、快捷鍵、控制面板）

    func togglePause() {
        paused.toggle()
        broadcastState()
    }

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        togglePause()
    }

    func toggleOverlayHidden() {
        setOverlayHidden(!overlayHidden)
    }

    func setOverlayHidden(_ hidden: Bool) {
        overlayHidden = hidden
        if hidden {
            overlay.hide()
        } else {
            overlay.show()
        }
        broadcastState()
    }

    func toggleQRCode() {
        if largeQR {
            largeQR = false
            return
        }
        settings.qrVisible.toggle()
    }

    func clearScreen() {
        overlay.stage.clearScreen()
    }

    func clearQueue() {
        overlay.stage.clearQueue()
    }

    func copyPhoneURL() {
        guard let phoneURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phoneURL, forType: .string)
    }

    func choose(interface: NetworkInfo.Interface?) {
        settings.preferredInterface = interface?.name
    }

    func block(_ record: SenderRecord) {
        gate.block(address: record.address, clientId: record.clientId)
        let bye = ServerMessage(t: "bye", code: "blocked", message: "你已被主持人暫停發言").json()
        for viewer in viewers.values where viewer.address == record.address || (record.clientId != nil && viewer.clientId == record.clientId) {
            server.close(viewer.id, finalMessage: bye, code: 4003)
            viewers.removeValue(forKey: viewer.id)
        }
        senderMap.removeValue(forKey: record.address)
        sendersDirty = true
        if !blocked.contains(where: { $0.address == record.address }) {
            blocked.insert(record, at: 0)
        }
    }

    func unblock(_ record: SenderRecord) {
        gate.unblock(address: record.address, clientId: record.clientId)
        blocked.removeAll { $0.address == record.address }
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleOverlay: toggleOverlayHidden()
        case .togglePause: togglePause()
        case .toggleQRCode: toggleQRCode()
        case .clearScreen: clearScreen()
        }
    }

    func registerHotkeys() {
        let bindings: [(ShortcutAction, Shortcut, () -> Void)] = ShortcutAction.allCases.compactMap { action in
            guard let shortcut = settings.shortcuts[action] else { return nil }
            return (action, shortcut, { [weak self] in self?.perform(action) })
        }
        hotkeyFailures = hotKeys.register(bindings)
    }

    // MARK: - 測試彈幕

    /// 發送一則範例彈幕（主持人測試用，不受暫停與限流影響）。
    func sendTestMessage() {
        let sample = Samples.messages[sampleIndex % Samples.messages.count]
        sampleIndex += 1
        let avatar: CGImage?
        if let emoji = sample.avatarEmoji {
            avatar = AvatarFactory.emojiAvatar(emoji, color: NSColor(hexString: sample.avatarColor) ?? Brand.electricBlue)
        } else {
            avatar = sample.nickname.flatMap(AvatarFactory.initialAvatar)
        }
        displayInternal(DanmakuContent(
            text: sample.text,
            nickname: settings.showNickname ? sample.nickname : nil,
            avatar: settings.showAvatar ? avatar : nil
        ))
    }

    /// `--demo`：持續發送範例彈幕（展示、截圖、自動測試用）。
    func startDemo(interval: TimeInterval = 1.2) {
        demoTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sendTestMessage() }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
        sendTestMessage()
    }

    func startCompatibilityTest() {
        compatibilityTest.start(mode: settings.levelMode)
    }

    private func displayInternal(_ content: DanmakuContent) {
        if overlayHidden { setOverlayHidden(false) }
        messageCounter += 1
        _ = overlay.stage.enqueue(DanmakuItem(id: "local-\(messageCounter)", content: content, connectionID: nil))
    }

    // MARK: - 網址

    private var externalBase: String? {
        let trimmed = settings.externalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), URL(string: trimmed)?.host != nil else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    func refreshURL() {
        let found = NetworkInfo.candidateInterfaces()
        if found != interfaces { interfaces = found }
        let chosen = found.first { $0.name == settings.preferredInterface } ?? found.first
        if chosen != currentInterface { currentInterface = chosen }

        var lan: String?
        if case let .ready(port) = serverState, let chosen {
            lan = "http://\(chosen.address):\(port)"
        }
        let base = externalBase ?? lan
        let join = session.flatMap { session in base.map { $0 + session.joinPath } }
        if lan != lanURL { lanURL = lan }
        if join != phoneURL {
            phoneURL = join
            if let join { NSLog("URBAN LIVE: 手機網址 \(join)") }
        }
        overlay.setURL(join)
        server.setExternalHost(externalBase.flatMap { URL(string: $0)?.host })
    }

    /// 手機連不上時的可能原因（顯示在控制面板）。
    var connectionHints: [String] {
        var hints: [String] = []
        if interfaces.isEmpty {
            hints.append("Mac 目前沒有連上 Wi-Fi 或區域網路，手機無法連線。")
        }
        hints.append("手機與 Mac 必須連同一個 Wi-Fi（同一個網段）。手機若用行動網路（4G/5G）會連不到。")
        hints.append("公司「訪客 Wi-Fi」常開啟用戶端隔離，裝置之間互相連不到 → 改用內部 Wi-Fi，或見說明文件的替代方案。")
        hints.append("系統設定 → 網路 → 防火牆：確認「URBAN LIVE」允許連入連線。")
        hints.append("Mac 開著 VPN 時，QR Code 可能指向錯誤的位址 → 關閉 VPN 或在「網路介面」選 Wi-Fi（通常是 en0）。")
        return hints
    }

    // MARK: - WebSocket 事件

    private func handle(_ event: LiveServer.Event) {
        switch event {
        case let .opened(info):
            let token = info.request.queryValue("s")
            guard let session, session.accepts(token: token) else {
                let message = session == nil ? LiveState.ended.phoneMessage : "這個連結已失效，請重新掃描大螢幕上的 QR Code"
                let code = session == nil ? "ended" : "invalid_session"
                server.close(info.id, finalMessage: ServerMessage(t: "bye", code: code, message: message).json(), code: 4001)
                return
            }
            if gate.isBlocked(address: info.address, clientId: nil) {
                server.close(info.id, finalMessage: ServerMessage(t: "bye", code: "blocked", message: "你已被主持人暫停發言").json(), code: 4003)
                return
            }
            viewers[info.id] = Viewer(id: info.id, address: info.address)

        case let .text(id, text):
            guard let viewer = viewers[id], let message = ClientMessage.decode(text) else { return }
            switch message.t {
            case "hello": hello(viewer, message)
            case "profile": applyProfile(viewer, message.profile, reply: true)
            case "send": receive(viewer, message)
            case "ping": server.send(ServerMessage(t: "pong").json(), to: id)
            default: break
            }

        case let .closed(id):
            viewers.removeValue(forKey: id)
        }
    }

    private func hello(_ viewer: Viewer, _ message: ClientMessage) {
        viewer.clientId = Self.cleanIdentifier(message.clientId)
        if gate.isBlocked(address: viewer.address, clientId: viewer.clientId) {
            server.close(viewer.id, finalMessage: ServerMessage(t: "bye", code: "blocked", message: "你已被主持人暫停發言").json(), code: 4003)
            viewers.removeValue(forKey: viewer.id)
            return
        }
        applyProfile(viewer, message.profile, reply: false)
        let state = liveState
        server.send(ServerMessage(
            t: "welcome",
            state: state.rawValue,
            message: state.phoneMessage,
            maxLength: settings.maxLength,
            cooldown: settings.cooldown,
            allowPhoto: settings.allowPhotoAvatar,
            nickname: viewer.nickname
        ).json(), to: viewer.id)
    }

    private func applyProfile(_ viewer: Viewer, _ profile: ViewerProfile?, reply: Bool) {
        switch gate.evaluateNickname(profile?.nickname) {
        case let .success(nickname):
            viewer.nickname = nickname
            if reply {
                server.send(ServerMessage(t: "profile", ok: true, nickname: nickname).json(), to: viewer.id)
            }
        case let .failure(rejection):
            viewer.nickname = nil
            server.send(ServerMessage(t: "profile", ok: false, code: rejection.code, message: rejection.message).json(), to: viewer.id)
        }
        let avatar = ValidatedAvatar.validate(profile?.avatar, allowPhoto: settings.allowPhotoAvatar)
        viewer.avatarImage = AvatarFactory.image(for: avatar, nickname: viewer.nickname)
        if var record = senderMap[viewer.address] {
            record.nickname = viewer.nickname
            senderMap[viewer.address] = record
            sendersDirty = true
        }
    }

    private func receive(_ viewer: Viewer, _ message: ClientMessage) {
        messageCounter += 1
        let messageID = Self.cleanIdentifier(message.id) ?? "m\(messageCounter)"
        counters.received += 1
        let result = gate.evaluate(
            text: message.text ?? "",
            address: viewer.address,
            clientId: viewer.clientId,
            now: ProcessInfo.processInfo.systemUptime,
            state: liveState,
            queueFull: overlay.stage.isQueueFull
        )
        switch result {
        case let .success(text):
            let position = overlay.stage.pendingCount + 1
            let busy = overlay.stage.onScreenCount >= settings.maxConcurrent || overlay.stage.pendingCount > 0
            // 先回條，再放進佇列（可能立刻上場並送出「已顯示」）
            server.send(ServerMessage(
                t: "ack", id: messageID, ok: true, code: "queued",
                message: busy ? "已送出，排隊中（前面還有 \(position - 1) 則）" : "已送出",
                queue: position
            ).json(), to: viewer.id)
            let item = DanmakuItem(
                id: messageID,
                content: DanmakuContent(
                    text: text,
                    nickname: settings.showNickname ? viewer.nickname : nil,
                    avatar: settings.showAvatar ? viewer.avatarImage : nil
                ),
                connectionID: viewer.id
            )
            if overlay.stage.enqueue(item) == nil {
                didDrop(item, reason: "目前彈幕太多，這則沒有顯示")
            } else {
                counters.accepted += 1
                record(viewer, text: text)
            }
        case let .failure(rejection):
            counters.rejected += 1
            server.send(ServerMessage(
                t: "ack", id: messageID, ok: false, code: rejection.code,
                message: rejection.message, retryAfter: rejection.retryAfter
            ).json(), to: viewer.id)
        }
    }

    private func record(_ viewer: Viewer, text: String) {
        var record = senderMap[viewer.address] ?? SenderRecord(
            address: viewer.address, clientId: viewer.clientId, nickname: viewer.nickname,
            lastMessage: text, count: 0, lastAt: Date()
        )
        record.clientId = viewer.clientId
        record.nickname = viewer.nickname
        record.lastMessage = text
        record.count += 1
        record.lastAt = Date()
        senderMap[viewer.address] = record
        if senderMap.count > 300, let oldest = senderMap.values.min(by: { $0.lastAt < $1.lastAt }) {
            senderMap.removeValue(forKey: oldest.address)
        }
        sendersDirty = true
    }

    private func didShow(_ item: DanmakuItem, waited: TimeInterval) {
        counters.shown += 1
        counters.lastWait = waited
        if let id = item.connectionID {
            server.send(ServerMessage(t: "shown", id: item.id).json(), to: id)
        }
    }

    private func didDrop(_ item: DanmakuItem, reason: String) {
        counters.dropped += 1
        if let id = item.connectionID {
            server.send(ServerMessage(t: "dropped", id: item.id, message: reason).json(), to: id)
        }
    }

    private func broadcastState() {
        let state = liveState
        server.broadcast(ServerMessage(t: "state", state: state.rawValue, message: state.phoneMessage).json(), to: Array(viewers.keys))
    }

    /// 只保留安全字元的識別碼（clientId、訊息 id）。
    private static func cleanIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 48,
              raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
        else { return nil }
        return raw
    }

    // MARK: - HTTP

    private func route(_ request: HTTPRequest, address: String) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(MobilePage.html)
        case ("GET", _) where request.path.hasPrefix("/j/"):
            return .html(MobilePage.html)
        case ("GET", "/api/status"):
            let state = session?.accepts(token: request.queryValue("s")) == true ? liveState : .ended
            return .json(200, ServerMessage(
                t: "status", state: state.rawValue, message: state.phoneMessage,
                maxLength: settings.maxLength, cooldown: settings.cooldown
            ))
        case ("POST", "/api/send"):
            return httpSend(request, address: address)
        case ("GET", "/healthz"):
            return .text(200, "ok")
        case ("GET", "/favicon.ico"), ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"):
            return HTTPResponse(status: 204)
        case (_, "/api/send"), (_, "/api/status"):
            return .text(405, "Method Not Allowed")
        default:
            return .text(404, "Not Found")
        }
    }

    /// WebSocket 無法使用時的備援：一次一則，回應即代表 Mac 已收到。
    private func httpSend(_ request: HTTPRequest, address: String) -> HTTPResponse {
        guard let payload = try? JSONDecoder().decode(HTTPSendPayload.self, from: request.body) else {
            return .json(400, APIResult(ok: false, code: "bad_request", message: "格式錯誤，請重新整理頁面"))
        }
        guard let session, session.accepts(token: payload.session) else {
            return .json(403, APIResult(ok: false, code: "invalid_session", message: "這個連結已失效，請重新掃描大螢幕上的 QR Code"))
        }
        counters.received += 1
        let clientId = Self.cleanIdentifier(payload.clientId)
        let result = gate.evaluate(
            text: payload.text, address: address, clientId: clientId,
            now: ProcessInfo.processInfo.systemUptime, state: liveState, queueFull: overlay.stage.isQueueFull
        )
        switch result {
        case let .success(text):
            let nickname = (try? gate.evaluateNickname(payload.nickname).get()) ?? nil
            messageCounter += 1
            let item = DanmakuItem(
                id: "h\(messageCounter)",
                content: DanmakuContent(
                    text: text,
                    nickname: settings.showNickname ? nickname : nil,
                    avatar: settings.showAvatar ? nickname.flatMap(AvatarFactory.initialAvatar) : nil
                ),
                connectionID: nil
            )
            guard overlay.stage.enqueue(item) != nil else {
                return .json(503, APIResult(ok: false, code: "queue_full", message: "目前彈幕太多，請稍後再送", retryAfter: 10))
            }
            counters.accepted += 1
            return .json(200, APIResult(ok: true, code: "queued", message: "已送出"))
        case let .failure(rejection):
            counters.rejected += 1
            let status: Int
            switch rejection.code {
            case "blocked": status = 403
            case "paused", "hidden": status = 423
            case "ended": status = 410
            case "queue_full": status = 503
            case "too_fast": status = 429
            default: status = 400
            }
            return .json(status, APIResult(ok: false, code: rejection.code, message: rejection.message, retryAfter: rejection.retryAfter))
        }
    }
}
