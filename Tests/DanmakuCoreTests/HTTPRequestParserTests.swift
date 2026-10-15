import XCTest
@testable import DanmakuCore

final class HTTPRequestParserTests: XCTestCase {
    func testParsesSimpleGet() {
        let raw = "GET /api/status?x=1 HTTP/1.1\r\nHost: 192.168.1.2:8765\r\nAccept: */*\r\n\r\n"
        guard case let .complete(request, consumed) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(request.queryValue("x"), "1")
        XCTAssertNil(request.queryValue("y"))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/status")
        XCTAssertEqual(request.query, "x=1")
        XCTAssertEqual(request.headers["host"], "192.168.1.2:8765")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testWaitsForBodyThenParsesPost() {
        let body = #"{"text":"早安 ☀️"}"#
        let bodyBytes = Data(body.utf8)
        let head = "POST /api/danmaku HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(bodyBytes.count)\r\n\r\n"
        var data = Data(head.utf8)
        XCTAssertEqual(HTTPRequestParser.parse(data), .incomplete)

        data.append(bodyBytes.prefix(5))
        XCTAssertEqual(HTTPRequestParser.parse(data), .incomplete)

        data.append(bodyBytes.dropFirst(5))
        data.append(Data([0x81, 0x80])) // 之後的位元組不屬於這個請求
        guard case let .complete(request, consumed) = HTTPRequestParser.parse(data) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(consumed, data.count - 2)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testIncompleteHeaders() {
        XCTAssertEqual(HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)), .incomplete)
    }

    func testRejectsGarbage() {
        guard case .invalid = HTTPRequestParser.parse(Data("HELLO\r\n\r\n".utf8)) else {
            return XCTFail("expected invalid")
        }
    }

    func testRejectsChunked() {
        let raw = "POST /api/danmaku HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        guard case .invalid = HTTPRequestParser.parse(Data(raw.utf8)) else {
            return XCTFail("expected invalid")
        }
    }

    func testRejectsHugeBody() {
        let raw = "POST /api/danmaku HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"
        XCTAssertEqual(HTTPRequestParser.parse(Data(raw.utf8)), .tooLarge)
    }

    func testRejectsHugeHeaders() {
        let raw = "GET / HTTP/1.1\r\nX-Junk: " + String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes + 10)
        XCTAssertEqual(HTTPRequestParser.parse(Data(raw.utf8)), .tooLarge)
    }

    func testResponseSerialization() {
        let response = HTTPResponse.json(429, APIResult(ok: false, code: "too_fast", message: "慢一點"))
        let text = String(data: response.serialized(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix(#"{"code":"too_fast","message":"慢一點","ok":false}"#))
        XCTAssertTrue(text.contains("Content-Length: \(response.body.count)\r\n"))
    }
}
