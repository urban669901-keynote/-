import DanmakuCore
import Foundation
import Network

/// 內建 HTTP 伺服器（Network.framework，不需安裝任何東西）。
/// 只做三件事：提供手機網頁、回報狀態、接收彈幕。每個連線處理一個請求就關閉。
final class DanmakuServer {
    enum State: Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    /// 在主執行緒呼叫，回傳要送給手機的回應。參數：請求、來源 IP。
    var router: ((HTTPRequest, String) -> HTTPResponse)?
    /// 在主執行緒呼叫。
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.urban.danmaku.server")
    private var listener: NWListener?
    private static let portAttempts = 10
    private static let requestTimeout: TimeInterval = 10

    func start(preferredPort: Int) {
        report(.starting)
        startListener(port: preferredPort, attemptsLeft: Self.portAttempts)
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
                // 最常見：連接埠被佔用 → 換下一個
                NSLog("URBANDanmaku: port \(port) failed: \(error)")
                listener?.cancel()
                DispatchQueue.main.async {
                    self.startListener(port: port + 1, attemptsLeft: attemptsLeft - 1)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    // MARK: - 連線

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            connection.cancel() // 已完成的連線呼叫 cancel 不會有影響
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPRequestParser.parse(buffer) {
            case let .complete(request):
                let ip = Self.remoteAddress(of: connection)
                DispatchQueue.main.async {
                    let response = self.router?(request, ip) ?? .text(503, "Server not ready")
                    self.send(response, on: connection)
                }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .tooLarge:
                self.send(.text(413, "Payload Too Large"), on: connection)
            case .invalid:
                self.send(.text(400, "Bad Request"), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func remoteAddress(of connection: NWConnection) -> String {
        guard case let .hostPort(host, _) = connection.endpoint else { return "unknown" }
        var text = "\(host)"
        if let percent = text.firstIndex(of: "%") {
            text = String(text[..<percent]) // 去掉 IPv6 scope（例如 %en0）
        }
        return text
    }
}
