import DanmakuCore
import Foundation
import Network

/// 內建伺服器（Network.framework，不需安裝任何東西）。
///
/// 同一個連接埠同時提供：
/// - HTTP：手機網頁、狀態查詢、HTTP 備援發送（處理一個請求就關閉）
/// - WebSocket（`/ws`）：手機與 Mac 的即時雙向連線（送出、回條、狀態推送）
///
/// 這一層只負責傳輸；所有判斷（場次、審核、顯示）都在主執行緒的 AppModel。
final class LiveServer {
    enum State: Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    struct ConnectionInfo {
        let id: Int
        /// 觀眾位址（限流與封鎖用）
        let address: String
        let request: HTTPRequest
    }

    enum Event {
        case opened(ConnectionInfo)
        case text(Int, String)
        case closed(Int)
    }

    /// 主執行緒：HTTP 路由
    var router: ((HTTPRequest, String) -> HTTPResponse)?
    /// 主執行緒：WebSocket 事件
    var onEvent: ((Event) -> Void)?
    /// 主執行緒
    var onStateChange: ((State) -> Void)?

    static let maxConnections = 800
    static let maxMessageSize = 160 * 1024
    static let maxMessagesPerSecond = 20
    static let pingInterval: TimeInterval = 20
    static let idleTimeout: TimeInterval = 65

    private let queue = DispatchQueue(label: "com.urban.live.server")
    private var listener: NWListener?
    private var sockets: [Int: Socket] = [:]
    private var nextID = 1
    private var pingTimer: DispatchSourceTimer?
    /// 外部網址的主機名稱（設定了 Cloudflare Tunnel 等外部網址時允許其 Origin）
    private var externalHost: String?

    private final class Socket {
        let id: Int
        let connection: NWConnection
        var isWebSocket = false
        var reader = WebSocketReader(maxMessageSize: LiveServer.maxMessageSize)
        var lastSeen = Date()
        var windowStart = Date()
        var messagesInWindow = 0
        var closing = false

        init(id: Int, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }
    }

    // MARK: - 啟動

    func start(preferredPort: Int) {
        report(.starting)
        startListener(port: preferredPort, attemptsLeft: 10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        timer.resume()
        pingTimer = timer
    }

    func stop() {
        listener?.cancel()
        listener = nil
        pingTimer?.cancel()
    }

    private func startListener(port: Int, attemptsLeft: Int) {
        guard attemptsLeft > 0, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            report(.failed("找不到可用的連接埠"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            startListener(port: port + 1, attemptsLeft: attemptsLeft - 1)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report(.ready(port: UInt16(clamping: port)))
            case let .failed(error):
                NSLog("URBAN LIVE: port \(port) 無法使用：\(error)")
                listener?.cancel()
                self.queue.async { self.startListener(port: port + 1, attemptsLeft: attemptsLeft - 1) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    // MARK: - 對外（任何執行緒都可以呼叫）

    func setExternalHost(_ host: String?) {
        queue.async { [weak self] in self?.externalHost = host?.lowercased() }
    }

    func send(_ text: String, to id: Int) {
        queue.async { [weak self] in
            guard let socket = self?.sockets[id], socket.isWebSocket, !socket.closing else { return }
            socket.connection.send(content: WebSocket.textFrame(text), completion: .contentProcessed { _ in })
        }
    }

    func broadcast(_ text: String, to ids: [Int]) {
        let frame = WebSocket.textFrame(text)
        queue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                guard let socket = self.sockets[id], socket.isWebSocket, !socket.closing else { continue }
                socket.connection.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }

    /// 送出最後一則訊息後關閉連線。
    func close(_ id: Int, finalMessage: String?, code: UInt16 = 1000) {
        queue.async { [weak self] in
            guard let self, let socket = self.sockets[id], !socket.closing else { return }
            socket.closing = true
            var data = Data()
            if let finalMessage { data.append(WebSocket.textFrame(finalMessage)) }
            data.append(WebSocket.closeFrame(code: code))
            socket.connection.send(content: data, completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.5) { socket.connection.cancel() }
            })
        }
    }

    // MARK: - 連線

    private func accept(_ connection: NWConnection) {
        guard sockets.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let socket = Socket(id: nextID, connection: connection)
        nextID += 1
        sockets[socket.id] = socket

        connection.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket else { return }
            switch state {
            case .failed, .cancelled:
                if self.sockets.removeValue(forKey: socket.id) != nil, socket.isWebSocket {
                    self.emit(.closed(socket.id))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // 10 秒內沒有完成 HTTP 請求或升級成 WebSocket 就關閉
        queue.asyncAfter(deadline: .now() + 10) { [weak socket] in
            guard let socket, !socket.isWebSocket else { return }
            socket.connection.cancel()
        }
        receiveHTTP(socket, buffer: Data())
    }

    private func receiveHTTP(_ socket: Socket, buffer: Data) {
        socket.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPRequestParser.parse(buffer) {
            case let .complete(request, consumed):
                let peer = Self.peerAddress(of: socket.connection)
                let address = ClientAddress.key(peer: peer, headers: request.headers)
                if request.path == "/ws" && WebSocket.isUpgradeRequest(request) {
                    self.upgrade(socket, request: request, address: address, leftover: buffer.dropFirst(consumed))
                } else {
                    DispatchQueue.main.async {
                        let response = self.router?(request, address) ?? .text(503, "Not ready")
                        self.respondAndClose(socket, response)
                    }
                }
            case .incomplete:
                if isComplete || error != nil {
                    socket.connection.cancel()
                } else {
                    self.receiveHTTP(socket, buffer: buffer)
                }
            case .tooLarge:
                self.respondAndClose(socket, .text(413, "Payload Too Large"))
            case .invalid:
                self.respondAndClose(socket, .text(400, "Bad Request"))
            }
        }
    }

    private func respondAndClose(_ socket: Socket, _ response: HTTPResponse) {
        socket.connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                               completion: .contentProcessed { _ in socket.connection.cancel() })
    }

    /// 只接受從手機網頁本身發起的 WebSocket（Origin 與 Host 相同），避免其他網站代為連線。
    private func originAllowed(_ request: HTTPRequest) -> Bool {
        guard let origin = request.headers["origin"], let originHost = URL(string: origin)?.host else { return true }
        guard let host = request.headers["host"] else { return false }
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        if originHost.caseInsensitiveCompare(hostOnly) == .orderedSame { return true }
        // 透過外部網址（通道）連入時，Host 會是外部網域
        if let forwardedHost = request.headers["x-forwarded-host"], originHost.caseInsensitiveCompare(forwardedHost) == .orderedSame {
            return true
        }
        if let externalHost, originHost.lowercased() == externalHost {
            return true
        }
        return false
    }

    private func upgrade(_ socket: Socket, request: HTTPRequest, address: String, leftover: Data) {
        guard originAllowed(request), let handshake = WebSocket.handshakeResponse(for: request) else {
            respondAndClose(socket, .text(403, "Forbidden"))
            return
        }
        socket.isWebSocket = true
        socket.lastSeen = Date()
        socket.connection.send(content: handshake, completion: .contentProcessed { _ in })
        emit(.opened(ConnectionInfo(id: socket.id, address: address, request: request)))
        if !leftover.isEmpty {
            handleFrames(socket, Data(leftover))
        }
        receiveWebSocket(socket)
    }

    private func receiveWebSocket(_ socket: Socket) {
        socket.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleFrames(socket, data)
            }
            if isComplete || error != nil {
                socket.connection.cancel()
            } else if !socket.closing || data != nil {
                self.receiveWebSocket(socket)
            }
        }
    }

    private func handleFrames(_ socket: Socket, _ data: Data) {
        socket.lastSeen = Date()
        let result = socket.reader.consume(data)
        for event in result.events {
            switch event {
            case let .text(text):
                guard allowMessage(socket) else {
                    close(socket.id, finalMessage: nil, code: 1008)
                    return
                }
                emit(.text(socket.id, text))
            case .binary:
                close(socket.id, finalMessage: nil, code: 1003)
                return
            case let .ping(payload):
                socket.connection.send(content: WebSocket.encode(.pong, payload: payload), completion: .contentProcessed { _ in })
            case .pong:
                break
            case .close:
                close(socket.id, finalMessage: nil)
                return
            }
        }
        if let error = result.error {
            NSLog("URBAN LIVE: 連線 \(socket.id) 協定錯誤：\(error)")
            close(socket.id, finalMessage: nil, code: 1002)
        }
    }

    /// 單一連線每秒最多 20 則訊息（正常操作遠低於此），超過視為攻擊直接斷線。
    private func allowMessage(_ socket: Socket) -> Bool {
        let now = Date()
        if now.timeIntervalSince(socket.windowStart) >= 1 {
            socket.windowStart = now
            socket.messagesInWindow = 0
        }
        socket.messagesInWindow += 1
        return socket.messagesInWindow <= Self.maxMessagesPerSecond
    }

    /// 定時 ping；太久沒有任何回應（手機鎖屏、離開 Wi-Fi）就關閉。
    private func heartbeat() {
        let now = Date()
        let ping = WebSocket.encode(.ping)
        for socket in sockets.values where socket.isWebSocket && !socket.closing {
            if now.timeIntervalSince(socket.lastSeen) > Self.idleTimeout {
                socket.connection.cancel()
            } else {
                socket.connection.send(content: ping, completion: .contentProcessed { _ in })
            }
        }
    }

    private static func peerAddress(of connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "unknown" }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") {
            text = String(text[..<percent])
        }
        if text.hasPrefix("::ffff:") {
            text = String(text.dropFirst(7))
        }
        return text
    }
}
