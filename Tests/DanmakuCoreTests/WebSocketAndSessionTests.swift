import XCTest
@testable import DanmakuCore

/// 模擬瀏覽器送出的訊框（用戶端訊框必須遮罩）。
func clientFrame(_ opcode: WebSocket.Opcode, _ payload: Data, fin: Bool = true, mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]) -> Data {
    var frame = Data([(fin ? 0x80 : 0) | opcode.rawValue])
    let count = payload.count
    if count < 126 {
        frame.append(0x80 | UInt8(count))
    } else if count <= 0xFFFF {
        frame.append(0x80 | 126)
        frame.append(UInt8(count >> 8))
        frame.append(UInt8(count & 0xFF))
    } else {
        frame.append(0x80 | 127)
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
        }
    }
    frame.append(contentsOf: mask)
    frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
    return frame
}

final class WebSocketTests: XCTestCase {
    func testAcceptKeyMatchesRFCExample() {
        // RFC 6455 第 1.3 節的範例
        XCTAssertEqual(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testDetectsUpgradeAndBuildsHandshake() {
        let request = HTTPRequest(method: "GET", path: "/ws", query: "s=ABCDEFGH", headers: [
            "upgrade": "websocket",
            "connection": "keep-alive, Upgrade",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
            "sec-websocket-version": "13",
        ])
        XCTAssertTrue(WebSocket.isUpgradeRequest(request))
        let response = String(data: WebSocket.handshakeResponse(for: request)!, encoding: .utf8)!
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertFalse(WebSocket.isUpgradeRequest(HTTPRequest(method: "GET", path: "/ws")))
    }

    func testReadsMaskedTextAcrossChunks() {
        var reader = WebSocketReader(maxMessageSize: 1024)
        let frame = clientFrame(.text, Data("URBAN 今天衝三件 🔥".utf8))
        let first = reader.consume(frame.prefix(5))
        XCTAssertEqual(first.events, [])
        XCTAssertNil(first.error)
        let second = reader.consume(frame.dropFirst(5))
        XCTAssertEqual(second.events, [.text("URBAN 今天衝三件 🔥")])
    }

    func testReadsTwoFramesInOneChunkAndControlFrames() {
        var reader = WebSocketReader(maxMessageSize: 1024)
        var data = clientFrame(.text, Data("a".utf8))
        data.append(clientFrame(.ping, Data("p".utf8)))
        data.append(clientFrame(.text, Data("b".utf8)))
        let result = reader.consume(data)
        XCTAssertEqual(result.events, [.text("a"), .ping(Data("p".utf8)), .text("b")])
    }

    func testAssemblesFragmentedMessage() {
        var reader = WebSocketReader(maxMessageSize: 1024)
        var data = clientFrame(.text, Data("早安".utf8), fin: false)
        data.append(clientFrame(.ping, Data()))
        data.append(clientFrame(.continuation, Data(" URBAN".utf8), fin: true))
        XCTAssertEqual(reader.consume(data).events, [.ping(Data()), .text("早安 URBAN")])
    }

    func testMediumAndLargeLengths() {
        var reader = WebSocketReader(maxMessageSize: 200_000)
        let medium = String(repeating: "x", count: 300)
        let large = String(repeating: "y", count: 70_000)
        var data = clientFrame(.text, Data(medium.utf8))
        data.append(clientFrame(.text, Data(large.utf8)))
        XCTAssertEqual(reader.consume(data).events, [.text(medium), .text(large)])
    }

    func testRejectsUnmaskedOversizedAndBadFrames() {
        var reader = WebSocketReader(maxMessageSize: 10)
        XCTAssertNotNil(reader.consume(WebSocket.textFrame("hi")).error, "伺服器格式（未遮罩）的訊框應被拒絕")

        var small = WebSocketReader(maxMessageSize: 10)
        XCTAssertNotNil(small.consume(clientFrame(.text, Data(String(repeating: "z", count: 11).utf8))).error)

        var badUTF8 = WebSocketReader(maxMessageSize: 10)
        XCTAssertNotNil(badUTF8.consume(clientFrame(.text, Data([0xFF, 0xFE]))).error)
    }

    func testCloseFrame() {
        var reader = WebSocketReader(maxMessageSize: 100)
        let result = reader.consume(clientFrame(.close, Data([0x03, 0xE8])))
        XCTAssertEqual(result.events, [.close(code: 1000)])
    }

    func testServerFrameEncoding() {
        XCTAssertEqual([UInt8](WebSocket.textFrame("hi")), [0x81, 0x02, 0x68, 0x69])
        let medium = WebSocket.encode(.text, payload: Data(count: 300))
        XCTAssertEqual([UInt8](medium.prefix(4)), [0x81, 126, 0x01, 0x2C])
        let large = WebSocket.encode(.binary, payload: Data(count: 70_000))
        XCTAssertEqual([UInt8](large.prefix(2)), [0x82, 127])
        XCTAssertEqual(large.count, 70_000 + 10)
        XCTAssertEqual([UInt8](WebSocket.closeFrame(code: 4001, reason: "").prefix(4)), [0x88, 0x02, 0x0F, 0xA1])
    }
}

final class LiveSessionTests: XCTestCase {
    func testTokensAreRandomAndWellFormed() {
        let tokens = Set((0..<200).map { _ in LiveSession.newToken() })
        XCTAssertEqual(tokens.count, 200)
        for token in tokens {
            XCTAssertEqual(token.count, LiveSession.tokenLength)
            XCTAssertTrue(token.allSatisfy { LiveSession.alphabet.contains($0) })
        }
    }

    func testAcceptsOnlyMatchingUnexpiredToken() {
        let start = Date(timeIntervalSince1970: 1_000)
        let session = LiveSession(token: "ABCD2345", startedAt: start, expiresAt: start.addingTimeInterval(3600))
        XCTAssertTrue(session.accepts(token: "ABCD2345", now: start))
        XCTAssertTrue(session.accepts(token: "abcd2345", now: start), "大小寫不影響")
        XCTAssertFalse(session.accepts(token: "ABCD2346", now: start))
        XCTAssertFalse(session.accepts(token: nil, now: start))
        XCTAssertFalse(session.accepts(token: "ABCD2345", now: start.addingTimeInterval(3600)))
        XCTAssertEqual(session.remaining(now: start.addingTimeInterval(600)), 3000)
    }

    func testJoinPath() {
        XCTAssertEqual(LiveSession.token(fromJoinPath: "/j/ABCD2345"), "ABCD2345")
        XCTAssertEqual(LiveSession.token(fromJoinPath: "/j/abcd2345/"), "ABCD2345")
        XCTAssertNil(LiveSession.token(fromJoinPath: "/j/ABC"))
        XCTAssertNil(LiveSession.token(fromJoinPath: "/j/ABCD234O"), "O 不在字母表")
        XCTAssertNil(LiveSession.token(fromJoinPath: "/x/ABCD2345"))
    }
}

final class ProtocolTests: XCTestCase {
    func testDecodesClientMessages() {
        let hello = ClientMessage.decode(##"{"t":"hello","clientId":"c_1","profile":{"nickname":"小明","avatar":{"kind":"emoji","value":"🦁","color":"#2563EB"}}}"##)
        XCTAssertEqual(hello?.t, "hello")
        XCTAssertEqual(hello?.profile?.nickname, "小明")
        XCTAssertEqual(hello?.profile?.avatar?.value, "🦁")
        XCTAssertNil(ClientMessage.decode("not json"))
    }

    func testServerMessageOmitsNil() {
        XCTAssertEqual(ServerMessage(t: "shown", id: "m_1").json(), #"{"id":"m_1","t":"shown"}"#)
    }

    func testAvatarValidation() {
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "emoji", value: "🦁", color: "#2563eb"), allowPhoto: true),
                       .emoji("🦁", colorHex: "#2563EB"))
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "emoji", value: "A"), allowPhoto: true), .none)
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "emoji", value: "🦁🐯"), allowPhoto: true), .none)
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "emoji", value: "🦁", color: "red"), allowPhoto: true),
                       .emoji("🦁", colorHex: ValidatedAvatar.palette[1]))

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "photo", data: dataURL), allowPhoto: true), .photo(jpeg))
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "photo", data: dataURL), allowPhoto: false), .none)
        let notImage = "data:image/jpeg;base64," + Data("hello world".utf8).base64EncodedString()
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "photo", data: notImage), allowPhoto: true), .none)
        let svg = "data:image/svg+xml;base64," + Data("<svg/>".utf8).base64EncodedString()
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "photo", data: svg), allowPhoto: true), .none)
        let huge = "data:image/jpeg;base64," + Data(repeating: 0xFF, count: ValidatedAvatar.maxPhotoBytes + 10).base64EncodedString()
        XCTAssertEqual(ValidatedAvatar.validate(AvatarSpec(kind: "photo", data: huge), allowPhoto: true), .none)
    }

    func testClientAddressTrustsForwardedHeaderOnlyFromLoopback() {
        XCTAssertEqual(ClientAddress.key(peer: "192.168.1.20", headers: ["x-forwarded-for": "1.2.3.4"]), "192.168.1.20")
        XCTAssertEqual(ClientAddress.key(peer: "127.0.0.1", headers: ["cf-connecting-ip": "203.0.113.9"]), "203.0.113.9")
        XCTAssertEqual(ClientAddress.key(peer: "127.0.0.1", headers: ["x-forwarded-for": "203.0.113.9, 10.0.0.1"]), "203.0.113.9")
        XCTAssertEqual(ClientAddress.key(peer: "127.0.0.5", headers: [:]), "127.0.0.5")
    }
}
