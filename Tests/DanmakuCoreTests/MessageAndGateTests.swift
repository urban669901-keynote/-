import XCTest
@testable import DanmakuCore

final class MessageSanitizerTests: XCTestCase {
    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(MessageSanitizer.sanitize("  早安\n\n大家\t好  "), "早安 大家 好")
    }

    func testEmptyBecomesNil() {
        XCTAssertNil(MessageSanitizer.sanitize("   \n\t "))
        XCTAssertNil(MessageSanitizer.sanitize("\u{200B}\u{202E}"))
    }

    func testKeepsEmojiSequencesAsOneCharacter() {
        let family = "👨‍👩‍👧‍👦"
        let thumbs = "👍🏽"
        let heart = "❤️"
        let flag = "🇹🇼"
        let input = family + thumbs + heart + flag
        XCTAssertEqual(MessageSanitizer.sanitize(input), input)
        XCTAssertEqual(MessageSanitizer.sanitize(String(repeating: family, count: 50), maxLength: 3), family + family + family)
    }

    func testTruncatesByVisibleCharacters() {
        let long = String(repeating: "彈", count: 100)
        XCTAssertEqual(MessageSanitizer.sanitize(long)?.count, MessageSanitizer.defaultMaxLength)
    }

    func testStripsBidiOverride() {
        XCTAssertEqual(MessageSanitizer.sanitize("abc\u{202E}def"), "abcdef")
    }

    func testLimitsCombiningMarks() {
        let zalgo = "a" + String(repeating: "\u{0301}", count: 30)
        let result = MessageSanitizer.sanitize(zalgo) ?? ""
        XCTAssertEqual(result.unicodeScalars.count, 1 + MessageSanitizer.maxMarksPerCharacter)
    }
}

final class RateLimiterTests: XCTestCase {
    func testBurstThenBlockThenRefill() {
        var limiter = RateLimiter(burst: 3, refillInterval: 2)
        XCTAssertTrue(limiter.check(key: "a", now: 0).allowed)
        XCTAssertTrue(limiter.check(key: "a", now: 0.1).allowed)
        XCTAssertTrue(limiter.check(key: "a", now: 0.2).allowed)
        let blocked = limiter.check(key: "a", now: 0.3)
        XCTAssertFalse(blocked.allowed)
        XCTAssertGreaterThan(blocked.retryAfter, 0)
        XCTAssertLessThanOrEqual(blocked.retryAfter, 2)

        // 其他手機不受影響
        XCTAssertTrue(limiter.check(key: "b", now: 0.3).allowed)

        // 2 秒後補回 1 則
        XCTAssertTrue(limiter.check(key: "a", now: 2.4).allowed)
        XCTAssertFalse(limiter.check(key: "a", now: 2.5).allowed)
    }
}

final class SubmissionGateTests: XCTestCase {
    private func body(_ text: String) -> Data {
        try! JSONEncoder().encode(SubmitPayload(text: text))
    }

    func testAcceptsAndSanitizes() {
        var gate = SubmissionGate()
        XCTAssertEqual(gate.evaluate(body: body(" 加油\n💪 "), clientKey: "ip", now: 0, state: .live), .accepted("加油 💪"))
    }

    func testRejectsBadJSON() {
        var gate = SubmissionGate()
        guard case let .rejected(status, result) = gate.evaluate(body: Data("nope".utf8), clientKey: "ip", now: 0, state: .live) else {
            return XCTFail()
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(result.code, "bad_request")
    }

    func testRespectsPausedAndOff() {
        var gate = SubmissionGate()
        guard case let .rejected(pausedStatus, paused) = gate.evaluate(body: body("hi"), clientKey: "ip", now: 0, state: .paused) else {
            return XCTFail()
        }
        XCTAssertEqual(pausedStatus, 423)
        XCTAssertEqual(paused.code, "paused")

        guard case let .rejected(offStatus, off) = gate.evaluate(body: body("hi"), clientKey: "ip", now: 0, state: .off) else {
            return XCTFail()
        }
        XCTAssertEqual(offStatus, 503)
        XCTAssertEqual(off.code, "off")
    }

    func testRateLimitsPerClient() {
        var gate = SubmissionGate(rateLimiter: RateLimiter(burst: 1, refillInterval: 2))
        XCTAssertEqual(gate.evaluate(body: body("1"), clientKey: "ip", now: 0, state: .live), .accepted("1"))
        guard case let .rejected(status, result) = gate.evaluate(body: body("2"), clientKey: "ip", now: 0.5, state: .live) else {
            return XCTFail()
        }
        XCTAssertEqual(status, 429)
        XCTAssertEqual(result.code, "too_fast")
        XCTAssertNotNil(result.retryAfter)
    }

    func testEmptyMessageDoesNotConsumeQuota() {
        var gate = SubmissionGate(rateLimiter: RateLimiter(burst: 1, refillInterval: 2))
        guard case .rejected(400, _) = gate.evaluate(body: body("   "), clientKey: "ip", now: 0, state: .live) else {
            return XCTFail()
        }
        XCTAssertEqual(gate.evaluate(body: body("ok"), clientKey: "ip", now: 0.1, state: .live), .accepted("ok"))
    }
}
