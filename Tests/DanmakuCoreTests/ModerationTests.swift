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
        let input = family + "👍🏽" + "❤️" + "🇹🇼"
        XCTAssertEqual(MessageSanitizer.sanitize(input), input)
        XCTAssertEqual(MessageSanitizer.sanitize(String(repeating: family, count: 50), maxLength: 3), family + family + family)
    }

    func testDefaultLimitIs25VisibleCharacters() {
        XCTAssertEqual(MessageSanitizer.defaultMaxLength, 25)
        XCTAssertEqual(MessageSanitizer.sanitize(String(repeating: "彈", count: 100))?.count, 25)
        XCTAssertEqual(MessageSanitizer.sanitize("URBAN 今天衝三件 🔥"), "URBAN 今天衝三件 🔥")
    }

    func testStripsBidiOverrideAndLimitsMarks() {
        XCTAssertEqual(MessageSanitizer.sanitize("abc\u{202E}def"), "abcdef")
        let zalgo = "a" + String(repeating: "\u{0301}", count: 30)
        XCTAssertEqual(MessageSanitizer.sanitize(zalgo)?.unicodeScalars.count, 1 + MessageSanitizer.maxMarksPerCharacter)
    }

    func testNickname() {
        XCTAssertNil(MessageSanitizer.sanitizeNickname(nil))
        XCTAssertNil(MessageSanitizer.sanitizeNickname("   "))
        XCTAssertEqual(MessageSanitizer.sanitizeNickname("  小明\n"), "小明")
        XCTAssertEqual(MessageSanitizer.sanitizeNickname(String(repeating: "名", count: 30))?.count, 10)
    }
}

final class FilterTests: XCTestCase {
    func testContentFilterCatchesSpacedAndFullWidthVariants() {
        let filter = ContentFilter()
        XCTAssertNotNil(filter.firstMatch(in: "幹 你 娘"))
        XCTAssertNotNil(filter.firstMatch(in: "ＦＵＣＫ"))
        XCTAssertNotNil(filter.firstMatch(in: "f.u.c.k"))
        XCTAssertNil(filter.firstMatch(in: "幹部會議辛苦了"), "不應誤擋「幹部」")
        XCTAssertNil(filter.firstMatch(in: "祝媽媽的生日快樂"))
        XCTAssertNil(filter.firstMatch(in: "URBAN 今天衝三件 🔥"))
        XCTAssertNil(filter.firstMatch(in: "👍👍"))
    }

    func testCustomWords() {
        let filter = ContentFilter(words: ["  競爭對手  ", ""])
        XCTAssertEqual(filter.words, ["競爭對手"])
        XCTAssertNotNil(filter.firstMatch(in: "去 競爭 對手 那邊"))
        XCTAssertNil(filter.firstMatch(in: "白痴"), "自訂詞庫取代預設詞庫")
    }

    func testDuplicateFilter() {
        var filter = DuplicateFilter(window: 30)
        filter.record(key: "a", text: "加油 👍", now: 0)
        XCTAssertTrue(filter.isDuplicate(key: "a", text: "加油👍", now: 10))
        XCTAssertFalse(filter.isDuplicate(key: "b", text: "加油 👍", now: 10), "其他人不受影響")
        XCTAssertFalse(filter.isDuplicate(key: "a", text: "加油 💪", now: 10))
        XCTAssertFalse(filter.isDuplicate(key: "a", text: "加油 👍", now: 31), "超過時間可以再送")
    }

    func testRateLimiterOnePerFiveSeconds() {
        var limiter = RateLimiter(burst: 1, refillInterval: 5)
        XCTAssertTrue(limiter.check(key: "a", now: 0).allowed)
        let blocked = limiter.check(key: "a", now: 1)
        XCTAssertFalse(blocked.allowed)
        XCTAssertEqual(blocked.retryAfter, 4, accuracy: 0.001)
        XCTAssertTrue(limiter.check(key: "b", now: 1).allowed)
        XCTAssertTrue(limiter.check(key: "a", now: 5).allowed)
    }
}

final class ModerationGateTests: XCTestCase {
    private func evaluate(
        _ gate: inout ModerationGate, _ text: String, address: String = "10.0.0.2", clientId: String? = "c1",
        now: TimeInterval = 0, state: LiveState = .live, queueFull: Bool = false
    ) -> Result<String, Rejection> {
        gate.evaluate(text: text, address: address, clientId: clientId, now: now, state: state, queueFull: queueFull)
    }

    private func code(_ result: Result<String, Rejection>) -> String? {
        if case let .failure(rejection) = result { return rejection.code }
        return nil
    }

    func testAcceptanceFlow() {
        var gate = ModerationGate()
        XCTAssertEqual(try evaluate(&gate, " URBAN 今天衝三件 🔥 ").get(), "URBAN 今天衝三件 🔥")
        XCTAssertEqual(code(evaluate(&gate, "第二則", now: 2)), "too_fast")
        XCTAssertEqual(code(evaluate(&gate, "URBAN 今天衝三件 🔥", now: 6)), "duplicate")
        XCTAssertEqual(try evaluate(&gate, "第二則", now: 6).get(), "第二則")
    }

    func testStateEmptyFilterAndQueue() {
        var gate = ModerationGate()
        XCTAssertEqual(code(evaluate(&gate, "hi", state: .paused)), "paused")
        XCTAssertEqual(code(evaluate(&gate, "hi", state: .hidden)), "hidden")
        XCTAssertEqual(code(evaluate(&gate, "hi", state: .ended)), "ended")
        XCTAssertEqual(code(evaluate(&gate, "   ")), "empty")
        XCTAssertEqual(code(evaluate(&gate, "靠 北")), "filtered")
        XCTAssertEqual(code(evaluate(&gate, "hi", queueFull: true)), "queue_full")
        // 被擋下的訊息不消耗發言額度
        XCTAssertEqual(try evaluate(&gate, "hi").get(), "hi")
    }

    func testBlockingByAddressOrClient() {
        var gate = ModerationGate()
        gate.block(address: "10.0.0.9", clientId: "bad")
        XCTAssertEqual(code(evaluate(&gate, "hi", address: "10.0.0.9", clientId: "other")), "blocked")
        XCTAssertEqual(code(evaluate(&gate, "hi", address: "10.0.0.10", clientId: "bad")), "blocked")
        gate.unblock(address: "10.0.0.9", clientId: "bad")
        XCTAssertEqual(try evaluate(&gate, "hi", address: "10.0.0.9", clientId: "bad").get(), "hi")

        gate.block(address: "10.0.0.9", clientId: nil)
        gate.resetForNewSession()
        XCTAssertFalse(gate.isBlocked(address: "10.0.0.9", clientId: nil), "新場次重新開始")
    }

    func testSettingsUpdate() {
        var gate = ModerationGate(settings: ModerationSettings(maxLength: 5, cooldown: 1))
        XCTAssertEqual(try evaluate(&gate, "1234567890").get(), "12345")
        XCTAssertEqual(try evaluate(&gate, "abc", now: 1).get(), "abc")
        gate.update(ModerationSettings(maxLength: 5, cooldown: 1, blockedWords: ["abc"]))
        XCTAssertEqual(code(evaluate(&gate, "ABC", now: 5)), "filtered")
    }

    func testNicknames() {
        let gate = ModerationGate()
        XCTAssertEqual(try gate.evaluateNickname("  小明 ").get(), "小明")
        XCTAssertNil(try gate.evaluateNickname("").get())
        if case .success = gate.evaluateNickname("智障") { XCTFail("敏感暱稱應被拒絕") }
    }
}
