import CryptoKit
import Foundation

/// 最小、完整的 WebSocket（RFC 6455）伺服器端實作：握手、訊框解析、分段組合、控制訊框。
/// 不依賴第三方套件；和 HTTP 共用同一個連接埠（手機網頁與即時連線同一個網址）。
public enum WebSocket {
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA

        var isControl: Bool { rawValue >= 0x8 }
    }

    public struct Frame: Equatable {
        public var fin: Bool
        public var opcode: Opcode
        public var payload: Data
    }

    public enum FrameParseResult: Equatable {
        case frame(Frame, consumed: Int)
        case incomplete
        case protocolError(String)
    }

    // MARK: - 握手

    public static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    public static func isUpgradeRequest(_ request: HTTPRequest) -> Bool {
        request.method == "GET"
            && request.headers["upgrade"]?.lowercased() == "websocket"
            && (request.headers["connection"]?.lowercased().contains("upgrade") ?? false)
            && request.headers["sec-websocket-key"] != nil
    }

    public static func handshakeResponse(for request: HTTPRequest) -> Data? {
        guard let key = request.headers["sec-websocket-key"]?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            return nil
        }
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey(for: key))\r\n\r\n"
        return Data(response.utf8)
    }

    // MARK: - 訊框

    /// 解析一個訊框。用戶端送來的訊框依規範必須遮罩（masked）。
    public static func parseFrame(_ data: Data, maxPayload: Int, requireMask: Bool = true) -> FrameParseResult {
        let header = [UInt8](data.prefix(14))
        guard header.count >= 2 else { return .incomplete }

        let fin = header[0] & 0x80 != 0
        guard header[0] & 0x70 == 0 else { return .protocolError("RSV 位元不應設定") }
        guard let opcode = Opcode(rawValue: header[0] & 0x0F) else { return .protocolError("未知的 opcode") }
        let masked = header[1] & 0x80 != 0
        if requireMask && !masked { return .protocolError("用戶端訊框必須遮罩") }

        var length = Int(header[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard header.count >= 4 else { return .incomplete }
            length = Int(header[2]) << 8 | Int(header[3])
            offset = 4
        } else if length == 127 {
            guard header.count >= 10 else { return .incomplete }
            var value: UInt64 = 0
            for index in 2..<10 {
                value = value << 8 | UInt64(header[index])
            }
            guard value <= UInt64(maxPayload) else { return .protocolError("訊息太大") }
            length = Int(value)
            offset = 10
        }
        guard length <= maxPayload else { return .protocolError("訊息太大") }
        if opcode.isControl && (length > 125 || !fin) {
            return .protocolError("控制訊框格式錯誤")
        }

        var mask: [UInt8] = []
        if masked {
            guard header.count >= offset + 4 else { return .incomplete }
            mask = Array(header[offset..<(offset + 4)])
            offset += 4
        }
        guard data.count >= offset + length else { return .incomplete }

        let start = data.startIndex + offset
        var payload = [UInt8](data[start..<(start + length)])
        if masked {
            for index in payload.indices {
                payload[index] ^= mask[index & 3]
            }
        }
        return .frame(Frame(fin: fin, opcode: opcode, payload: Data(payload)), consumed: offset + length)
    }

    /// 編碼伺服器送出的訊框（伺服器端不遮罩）。
    public static func encode(_ opcode: Opcode, payload: Data = Data(), fin: Bool = true) -> Data {
        var frame = Data()
        frame.append((fin ? 0x80 : 0) | opcode.rawValue)
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    public static func textFrame(_ text: String) -> Data {
        encode(.text, payload: Data(text.utf8))
    }

    public static func closeFrame(code: UInt16 = 1000, reason: String = "") -> Data {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(120)))
        return encode(.close, payload: payload)
    }
}

/// 把 TCP 收到的位元組組成完整的 WebSocket 訊息（處理半包、黏包、分段）。
public struct WebSocketReader {
    public enum Event: Equatable {
        case text(String)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        case close(code: UInt16?)
    }

    public let maxMessageSize: Int
    private var buffer = Data()
    private var fragments: Data?
    private var fragmentOpcode: WebSocket.Opcode = .text

    public init(maxMessageSize: Int) {
        self.maxMessageSize = maxMessageSize
    }

    /// 回傳解析出的事件；`error` 不為 nil 時應關閉連線。
    public mutating func consume(_ data: Data) -> (events: [Event], error: String?) {
        buffer.append(data)
        defer { compact() }
        var events: [Event] = []
        while true {
            switch WebSocket.parseFrame(buffer, maxPayload: maxMessageSize) {
            case .incomplete:
                return (events, nil)
            case let .protocolError(message):
                return (events, message)
            case let .frame(frame, consumed):
                buffer.removeFirst(consumed)
                switch frame.opcode {
                case .ping:
                    events.append(.ping(frame.payload))
                case .pong:
                    events.append(.pong(frame.payload))
                case .close:
                    let bytes = [UInt8](frame.payload)
                    let code = bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil
                    events.append(.close(code: code))
                    return (events, nil)
                case .text, .binary:
                    guard fragments == nil else { return (events, "分段訊息尚未結束") }
                    if frame.fin {
                        guard let event = Self.message(frame.opcode, frame.payload) else { return (events, "文字不是 UTF-8") }
                        events.append(event)
                    } else {
                        fragments = frame.payload
                        fragmentOpcode = frame.opcode
                    }
                case .continuation:
                    guard var partial = fragments else { return (events, "多餘的分段訊框") }
                    partial.append(frame.payload)
                    guard partial.count <= maxMessageSize else { return (events, "訊息太大") }
                    if frame.fin {
                        fragments = nil
                        guard let event = Self.message(fragmentOpcode, partial) else { return (events, "文字不是 UTF-8") }
                        events.append(event)
                    } else {
                        fragments = partial
                    }
                }
            }
        }
    }

    /// `removeFirst` 只縮小 Data 的範圍，底層記憶體不會釋放：不整理的話，每條連線會一直留著
    /// 收過的最大訊息（例如約 70 KB 的照片大頭貼），200 人就是十幾 MB。
    private mutating func compact() {
        if buffer.isEmpty {
            buffer = Data()
        } else if buffer.startIndex != 0 {
            buffer = buffer.withUnsafeBytes { Data($0) }
        }
    }

    private static func message(_ opcode: WebSocket.Opcode, _ payload: Data) -> Event? {
        if opcode == .binary { return .binary(payload) }
        guard let text = String(data: payload, encoding: .utf8) else { return nil }
        return .text(text)
    }
}
