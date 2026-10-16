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

/// 觀眾的大頭貼來源。
private enum AvatarSource {
    case none
    /// Emoji 或暱稱首字：同樣的圖多人共用
    case shared(CGImage)
    /// 上傳的照片：只保留手機傳來的壓縮檔（約 20～50 KB），要上螢幕時才解碼
    case photo(Data)
}

/// 最近上螢幕的照片大頭貼（已解碼）只留少量；其他人的照片保持壓縮狀態，
/// 所以 100～200 人都上傳照片時，記憶體只多幾 MB。
private struct PhotoCache {
    let capacity: Int
    private var images: [Int: CGImage] = [:]
    private var order: [Int] = []
    var count: Int { images.count }

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func image(for id: Int, decode: () -> CGImage?) -> CGImage? {
        if let image = images[id] {
            order.removeAll { $0 == id }
            order.append(id)
            return image
        }
        guard let image = decode() else { return nil }
        images[id] = image
        order.append(id)
        while order.count > capacity {
            images.removeValue(forKey: order.removeFirst())
        }
        return image
    }

    mutating func remove(_ id: Int) {
        images.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    mutating func removeAll() {
        images.removeAll()
        order.removeAll()
    }
}

/// 一支已連線的手機。
private final class Viewer {
    let id: Int
    let address: String
    /// 統計用代號（場次 ID + IP 的雜湊）：同一個人重新連線也是同一個代號
    let person: String
    var clientId: String?
    var nickname: String?
    var avatar: AvatarSource = .none

    init(id: Int, address: String, person: String) {
        self.id = id
        self.address = address
        self.person = person
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
    /// 本場統計（控制面板顯示用，每秒最多更新一次）
    @Published private(set) var sessionStats: SessionStatistics?
    /// 過去的場次紀錄
    @Published private(set) var history: [SessionRecord] = []
    @Published private(set) var recentSpeakers: [String] = []
    /// 大螢幕上的公布卡片（本月最佳講師 / 本場數據）
    @Published private(set) var announcement: Announcement?
    /// 控制面板目前的分頁
    @Published var panelTab = "session"

    private var gate: ModerationGate
    private var photoCache = PhotoCache(capacity: 24)
    private var loggedPhotoCount = 0
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

    private let statisticsStore: StatisticsStore
    private var archive = StatisticsArchive()
    private var statisticsDirty = false
    private var lastStatisticsSave = Date()
    private var lastStatisticsPublish = Date.distantPast
    private var votesDirty = false
    private var lastVotesBroadcast = Date.distantPast

    var liveState: LiveState {
        if session == nil { return .ended }
        if overlayHidden { return .hidden }
        return paused ? .paused : .live
    }

    init(settings: Settings, statisticsURL: URL? = nil) {
        self.settings = settings
        overlay = OverlayController(settings: settings)
        levelMonitor = WindowLevelMonitor(mode: settings.levelMode)
        gate = ModerationGate(settings: settings.moderation)
        statisticsStore = StatisticsStore(url: statisticsURL)
    }

    var statisticsFileURL: URL { statisticsStore.url }

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

        // 統計：場次還在就接著統計；場次已經不在（例如過期）就把上次的統計存成紀錄
        archive = statisticsStore.load()
        if session != nil {
            if archive.active == nil { archive.active = SessionStatistics() }
        } else if let active = archive.active {
            archive.finishActive(at: active.updatedAt)
        }
        saveStatistics(force: true)
        publishStatistics(force: true)
        refreshVoteBadge()

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
        logPhotoUsage()

        archive.active?.recordOnline(uniqueOnline, at: now)
        overlay.setJoinedCount(archive.active?.participantCount ?? 0)
        if votesDirty, now.timeIntervalSince(lastVotesBroadcast) >= 1, let turn = archive.active?.currentTurn {
            votesDirty = false
            lastVotesBroadcast = now
            server.broadcast(ServerMessage(t: "votes", turn: turn.id, votes: turn.votes).json(), to: Array(viewers.keys))
        }
        publishStatistics()
        saveStatistics()
    }

    /// 目前在線人數（同一支手機開兩個分頁只算一次）。
    private var uniqueOnline: Int {
        Set(viewers.values.map(\.address)).count
    }

    /// 照片大頭貼的人數與佔用（壓縮檔總和）有變化時寫進系統紀錄，方便現場排查與壓力測試量測。
    private func logPhotoUsage() {
        var count = 0
        var bytes = 0
        for viewer in viewers.values {
            if case let .photo(data) = viewer.avatar {
                count += 1
                bytes += data.count
            }
        }
        guard count != loggedPhotoCount else { return }
        loggedPhotoCount = count
        NSLog("URBAN LIVE: 照片大頭貼 \(count) 人，壓縮檔共 \(bytes / 1024) KB，已解碼快取 \(photoCache.count) 張")
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
        archive.finishActive(at: Date())
        archive.active = SessionStatistics()
        saveStatistics(force: true)
        publishStatistics(force: true)
        refreshVoteBadge()
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
        photoCache.removeAll()
        overlay.stage.clearScreen()
        session = nil
        persistSession()
        if let active = archive.active {
            NSLog("URBAN LIVE: 本場統計：參與 \(active.participantCount) 人、最高同時在線 \(active.peakOnline) 人、講師票數 \(active.totalVotes)、換名 \(active.nicknameChanges) 次")
        }
        archive.finishActive(at: Date())
        saveStatistics(force: true)
        publishStatistics(force: true)
        refreshVoteBadge()
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
        photoCache.removeAll()
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
        hideAnnouncement()
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

    // MARK: - 講師超棒投票

    var currentTurn: SpeakerTurn? { sessionStats?.currentTurn }

    /// 開始為一位講師投票；已經在投票時就換成這一位（上一位自動結束）。
    func startVoting(for rawName: String) {
        guard session != nil, let name = SpeakerName.clean(rawName) else { return }
        if archive.active == nil { archive.active = SessionStatistics() }
        archive.active?.startTurn(speaker: name, online: uniqueOnline)
        NSLog("URBAN LIVE: 講師投票開始：\(name)")
        turnChanged()
    }

    func stopVoting() {
        guard archive.active?.currentTurn != nil else { return }
        archive.active?.endTurn()
        NSLog("URBAN LIVE: 講師投票結束")
        turnChanged()
    }

    private func turnChanged() {
        votesDirty = false
        for viewer in viewers.values {
            server.send(speakerMessage(for: viewer).json(), to: viewer.id)
        }
        refreshVoteBadge()
        saveStatistics(force: true)
        publishStatistics(force: true)
    }

    private func speakerMessage(for viewer: Viewer) -> ServerMessage {
        let turn = archive.active?.currentTurn
        return ServerMessage(
            t: "speaker", speaker: turn?.speaker, turn: turn?.id, votes: turn?.votes,
            voted: turn.map { _ in archive.active?.hasVoted(viewer.person) ?? false }
        )
    }

    private func vote(_ viewer: Viewer, _ message: ClientMessage) {
        let outcome = archive.active?.vote(viewer.person, turnID: Self.cleanIdentifier(message.turn)) ?? .noSpeaker
        let turn = archive.active?.currentTurn
        server.send(outcome.reply(speaker: turn?.speaker, turn: turn?.id).json(), to: viewer.id)
        if outcome == .staleTurn {
            server.send(speakerMessage(for: viewer).json(), to: viewer.id)
        }
        if case let .accepted(votes) = outcome {
            didVote(votes)
        }
    }

    private func didVote(_ votes: Int) {
        votesDirty = true
        statisticsDirty = true
        overlay.voteAdded(votes: votes)
    }

    private func refreshVoteBadge() {
        let turn = archive.active?.currentTurn
        overlay.setVote(speaker: turn?.speaker, votes: turn?.votes ?? 0)
    }

    // MARK: - 數據統計

    private func personKey(_ address: String) -> String {
        PersonKey.make(statisticsID: archive.active?.id ?? "none", address: address)
    }

    /// 控制面板與排行榜用的資料，每秒最多更新一次。
    private func publishStatistics(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatisticsPublish) >= 1 else { return }
        lastStatisticsPublish = now
        if sessionStats != archive.active {
            sessionStats = archive.active
            statisticsDirty = true
        }
        if history != archive.sessions { history = archive.sessions }
        let speakers = archive.recentSpeakers()
        if recentSpeakers != speakers { recentSpeakers = speakers }
    }

    /// 寫入統計檔：有變動時最多每 15 秒一次；場次開始 / 結束、換講師時立即寫入。
    private func saveStatistics(force: Bool = false) {
        guard force || (statisticsDirty && Date().timeIntervalSince(lastStatisticsSave) >= 15) else { return }
        statisticsStore.save(archive)
        statisticsDirty = false
        lastStatisticsSave = Date()
    }

    /// 本月（或指定月份）的講師排行。
    func ranking(for month: MonthKey) -> [SpeakerRank] {
        SpeakerRanking.rank(archive.allTurns, month: month, order: settings.rankingOrder)
    }

    /// 有講師紀錄的月份，一定包含本月。
    var rankingMonths: [MonthKey] {
        let months = Set(SpeakerRanking.months(archive.allTurns) + [MonthKey(Date())])
        return months.sorted(by: >)
    }

    func showBestSpeaker(month: MonthKey = MonthKey(Date())) {
        setAnnouncement(.bestSpeaker(month: month, order: settings.rankingOrder, ranks: ranking(for: month)))
    }

    func showSessionSummary() {
        if let active = archive.active {
            setAnnouncement(.sessionSummary(SessionSummary(active)))
        } else if let last = archive.sessions.last {
            setAnnouncement(.sessionSummary(SessionSummary(record: last)))
        }
    }

    func hideAnnouncement() {
        setAnnouncement(nil)
    }

    private func setAnnouncement(_ value: Announcement?) {
        announcement = value
        overlay.setAnnouncement(value)
        if value != nil && overlayHidden { setOverlayHidden(false) }
    }

    func exportStatistics(to url: URL) throws {
        try statisticsStore.exportCSV(archive, to: url)
    }

    /// 清除過去的場次紀錄（進行中的場次不受影響）。
    func clearHistory() {
        archive.sessions = []
        saveStatistics(force: true)
        publishStatistics(force: true)
    }

    /// App 結束前寫入統計檔。
    func shutdown() {
        saveStatistics(force: true)
        server.stop()
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
            if archive.active == nil { archive.active = SessionStatistics() }
            viewers[info.id] = Viewer(id: info.id, address: info.address, person: personKey(info.address))

        case let .text(id, text):
            guard let viewer = viewers[id], let message = ClientMessage.decode(text) else { return }
            switch message.t {
            case "hello": hello(viewer, message)
            case "profile": applyProfile(viewer, message.profile, reply: true)
            case "send": receive(viewer, message)
            case "vote": vote(viewer, message)
            case "ping": server.send(ServerMessage(t: "pong").json(), to: id)
            default: break
            }

        case let .closed(id):
            viewers.removeValue(forKey: id)
            photoCache.remove(id)
        }
    }

    private func hello(_ viewer: Viewer, _ message: ClientMessage) {
        viewer.clientId = Self.cleanIdentifier(message.clientId)
        if gate.isBlocked(address: viewer.address, clientId: viewer.clientId) {
            server.close(viewer.id, finalMessage: ServerMessage(t: "bye", code: "blocked", message: "你已被主持人暫停發言").json(), code: 4003)
            viewers.removeValue(forKey: viewer.id)
            return
        }
        archive.active?.join(viewer.person)
        applyProfile(viewer, message.profile, reply: false)
        let state = liveState
        let turn = archive.active?.currentTurn
        server.send(ServerMessage(
            t: "welcome",
            state: state.rawValue,
            message: state.phoneMessage,
            maxLength: settings.maxLength,
            cooldown: settings.cooldown,
            allowPhoto: settings.allowPhotoAvatar,
            nickname: viewer.nickname,
            profileSize: settings.profileSize.rawValue,
            speaker: turn?.speaker,
            turn: turn?.id,
            votes: turn?.votes,
            voted: turn.map { _ in archive.active?.hasVoted(viewer.person) ?? false }
        ).json(), to: viewer.id)
    }

    private func applyProfile(_ viewer: Viewer, _ profile: ViewerProfile?, reply: Bool) {
        switch gate.evaluateNickname(profile?.nickname) {
        case let .success(nickname):
            viewer.nickname = nickname
            if archive.active?.setNickname(nickname, for: viewer.person) == true {
                NSLog("URBAN LIVE: 有人換名了（本場第 \(archive.active?.nicknameChanges ?? 0) 次）")
            }
            if reply {
                server.send(ServerMessage(t: "profile", ok: true, nickname: nickname).json(), to: viewer.id)
            }
        case let .failure(rejection):
            viewer.nickname = nil
            server.send(ServerMessage(t: "profile", ok: false, code: rejection.code, message: rejection.message).json(), to: viewer.id)
        }
        let validated = ValidatedAvatar.validate(profile?.avatar, allowPhoto: settings.allowPhotoAvatar)
        photoCache.remove(viewer.id)
        if case let .photo(data) = validated, AvatarFactory.isUsablePhoto(data) {
            viewer.avatar = .photo(data)
        } else {
            // 照片無法使用時退回暱稱首字
            let fallback: ValidatedAvatar
            if case .photo = validated { fallback = .none } else { fallback = validated }
            viewer.avatar = AvatarFactory.image(for: fallback, nickname: viewer.nickname).map(AvatarSource.shared) ?? .none
        }
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
        archive.active?.messagesReceived += 1
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
                    avatar: avatarImage(for: viewer)
                ),
                connectionID: viewer.id
            )
            if overlay.stage.enqueue(item) == nil {
                didDrop(item, reason: "目前彈幕太多，這則沒有顯示")
            } else {
                counters.accepted += 1
                archive.active?.recordSender(viewer.person)
                record(viewer, text: text)
            }
        case let .failure(rejection):
            counters.rejected += 1
            archive.active?.messagesBlocked += 1
            server.send(ServerMessage(
                t: "ack", id: messageID, ok: false, code: rejection.code,
                message: rejection.message, retryAfter: rejection.retryAfter
            ).json(), to: viewer.id)
        }
    }

    /// 這位觀眾的彈幕要用的大頭貼。照片在這時才解碼（並留在小型快取裡）。
    private func avatarImage(for viewer: Viewer) -> CGImage? {
        guard settings.showAvatar else { return nil }
        switch viewer.avatar {
        case .none:
            return nil
        case let .shared(image):
            return image
        case let .photo(data):
            // 主持人中途關閉「允許照片大頭貼」時立即生效：改用暱稱首字
            guard settings.allowPhotoAvatar else { return viewer.nickname.flatMap(AvatarFactory.initialAvatar) }
            return photoCache.image(for: viewer.id) { AvatarFactory.photoAvatar(data) }
                ?? viewer.nickname.flatMap(AvatarFactory.initialAvatar)
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
        // 主持人的測試彈幕、相容性測試不算進統計
        if !item.id.hasPrefix("local-") { archive.active?.messagesShown += 1 }
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
            let valid = session?.accepts(token: request.queryValue("s")) == true
            let state = valid ? liveState : .ended
            let person = personKey(address)
            if valid { archive.active?.join(person) }
            let turn = valid ? archive.active?.currentTurn : nil
            return .json(200, ServerMessage(
                t: "status", state: state.rawValue, message: state.phoneMessage,
                maxLength: settings.maxLength, cooldown: settings.cooldown,
                speaker: turn?.speaker, turn: turn?.id, votes: turn?.votes,
                voted: turn.map { _ in archive.active?.hasVoted(person) ?? false }
            ))
        case ("POST", "/api/send"):
            return httpSend(request, address: address)
        case ("POST", "/api/vote"):
            return httpVote(request, address: address)
        case ("GET", "/healthz"):
            return .text(200, "ok")
        case ("GET", "/favicon.ico"), ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"):
            return HTTPResponse(status: 204)
        case (_, "/api/send"), (_, "/api/status"), (_, "/api/vote"):
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
        archive.active?.messagesReceived += 1
        let person = personKey(address)
        archive.active?.join(person)
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
            archive.active?.recordSender(person)
            return .json(200, APIResult(ok: true, code: "queued", message: "已送出"))
        case let .failure(rejection):
            counters.rejected += 1
            archive.active?.messagesBlocked += 1
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

    /// WebSocket 無法使用時的投票備援。
    private func httpVote(_ request: HTTPRequest, address: String) -> HTTPResponse {
        guard let payload = try? JSONDecoder().decode(HTTPVotePayload.self, from: request.body) else {
            return .json(400, APIResult(ok: false, code: "bad_request", message: "格式錯誤，請重新整理頁面"))
        }
        guard let session, session.accepts(token: payload.session) else {
            return .json(403, APIResult(ok: false, code: "invalid_session", message: "這個連結已失效，請重新掃描大螢幕上的 QR Code"))
        }
        guard !gate.isBlocked(address: address, clientId: Self.cleanIdentifier(payload.clientId)) else {
            return .json(403, APIResult(ok: false, code: "blocked", message: "你已被主持人暫停發言"))
        }
        let person = personKey(address)
        archive.active?.join(person)
        let outcome = archive.active?.vote(person, turnID: Self.cleanIdentifier(payload.turn)) ?? .noSpeaker
        if case let .accepted(votes) = outcome { didVote(votes) }
        let speaker = archive.active?.currentTurn?.speaker
        return .json(outcome.isAccepted ? 200 : 409, APIResult(
            ok: outcome.isAccepted, code: outcome.code, message: outcome.message(speaker: speaker),
            votes: outcome.votes, voted: outcome.votes != nil
        ))
    }
}
