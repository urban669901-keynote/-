import XCTest
@testable import DanmakuCore

final class StatisticsTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    // MARK: 講師投票

    func testOneVotePerPersonPerSpeaker() {
        var stats = SessionStatistics(id: "s1")
        let first = stats.startTurn(speaker: "王小明", online: 3, id: "t1")
        XCTAssertEqual(stats.vote("p1", turnID: first.id), .accepted(votes: 1))
        XCTAssertEqual(stats.vote("p1", turnID: first.id), .alreadyVoted(votes: 1), "同一個人不能重複投同一位講師")
        XCTAssertEqual(stats.vote("p2", turnID: nil), .accepted(votes: 2))
        XCTAssertTrue(stats.hasVoted("p1"))

        // 換下一位講師：每個人又可以投一次
        let second = stats.startTurn(speaker: "李大華", online: 3, id: "t2")
        XCTAssertFalse(stats.hasVoted("p1"))
        XCTAssertEqual(stats.vote("p1", turnID: second.id), .accepted(votes: 1))
        XCTAssertEqual(stats.turns.map(\.votes), [2, 1])
        XCTAssertNotNil(stats.turns[0].endedAt, "換講師時上一位自動結束")
        XCTAssertEqual(stats.totalVotes, 3)
    }

    func testVoteNeedsCurrentSpeaker() {
        var stats = SessionStatistics(id: "s1")
        XCTAssertEqual(stats.vote("p1", turnID: nil), .noSpeaker)
        stats.startTurn(speaker: "王小明", online: 1, id: "t1")
        XCTAssertEqual(stats.vote("p1", turnID: "old"), .staleTurn, "按到上一位講師的按鈕不算")
        stats.endTurn()
        XCTAssertNil(stats.currentTurn)
        XCTAssertEqual(stats.vote("p1", turnID: "t1"), .noSpeaker)
    }

    func testVoteReplyMessages() {
        let accepted = VoteOutcome.accepted(votes: 5).reply(speaker: "王小明", turn: "t1")
        XCTAssertEqual(accepted.ok, true)
        XCTAssertEqual(accepted.code, "voted")
        XCTAssertEqual(accepted.votes, 5)
        XCTAssertEqual(accepted.voted, true)
        XCTAssertTrue(accepted.message?.contains("王小明") == true)
        let again = VoteOutcome.alreadyVoted(votes: 5).reply(speaker: "王小明", turn: "t1")
        XCTAssertEqual(again.ok, false)
        XCTAssertEqual(again.voted, true)
        XCTAssertEqual(VoteOutcome.staleTurn.reply(speaker: nil, turn: nil).code, "stale_turn")
        let json = VoteOutcome.noSpeaker.reply(speaker: nil, turn: nil).json()
        XCTAssertTrue(json.contains("\"code\":\"no_speaker\""))
        XCTAssertFalse(json.contains("votes"), "沒有的欄位不輸出")
    }

    // MARK: 人數與換名

    func testParticipantsPeakOnlineAndAudience() {
        var stats = SessionStatistics(id: "s1")
        stats.join("p1")
        stats.join("p2")
        stats.join("p1")
        XCTAssertEqual(stats.participantCount, 2, "重新連線不重複計算")
        stats.recordOnline(5)
        stats.startTurn(speaker: "王小明", online: 3)
        stats.recordOnline(7)
        stats.recordOnline(2)
        XCTAssertEqual(stats.peakOnline, 7)
        XCTAssertEqual(stats.currentTurn?.audience, 7, "講師時段的在場人數取最高值")
        stats.recordSender("p1")
        stats.recordSender("p1")
        XCTAssertEqual(stats.senderCount, 1)
    }

    func testNicknameChangesCountOnlyRealChanges() {
        var stats = SessionStatistics(id: "s1")
        XCTAssertFalse(stats.setNickname("小明", for: "p1"), "第一次設定不算換名")
        XCTAssertFalse(stats.setNickname("小明", for: "p1"), "重新連線送同樣的暱稱不算")
        XCTAssertTrue(stats.setNickname("大明", for: "p1"))
        XCTAssertFalse(stats.setNickname(nil, for: "p1"), "清空不算")
        XCTAssertFalse(stats.setNickname("大明", for: "p1"), "清空後改回原本的不算")
        XCTAssertTrue(stats.setNickname("明明", for: "p1"))
        XCTAssertFalse(stats.setNickname("Amy", for: "p2"))
        XCTAssertTrue(stats.setNickname("amy", for: "p2"))
        XCTAssertEqual(stats.nicknameChanges, 3)
        XCTAssertEqual(stats.topRenamer?.changes, 2)
        XCTAssertEqual(stats.topRenamer?.display, "小明 → 大明 → 明明")
    }

    func testNicknameTrailKeepsFirstAndLatestNames() {
        var stats = SessionStatistics(id: "s1")
        for index in 0...9 {
            stats.setNickname("名字\(index)", for: "p1")
        }
        XCTAssertEqual(stats.topRenamer?.changes, 9)
        XCTAssertEqual(stats.topRenamer?.display, "名字0 → … → 名字5 → 名字6 → 名字7 → 名字8 → 名字9")
    }

    // MARK: 保存

    func testRecordAndArchiveRoundTrip() throws {
        var stats = SessionStatistics(id: "s1", startedAt: date("2026-10-15T01:00:00Z"))
        stats.join("p1")
        stats.setNickname("阿凱", for: "p1")
        stats.messagesShown = 4
        stats.startTurn(speaker: "王小明", online: 1, at: date("2026-10-15T01:05:00Z"), id: "t1")
        _ = stats.vote("p1", turnID: "t1")
        var archive = StatisticsArchive(active: stats)

        let decoded = try StatisticsArchive.decode(archive.encoded())
        XCTAssertEqual(decoded.active?.turns, archive.active?.turns)
        XCTAssertEqual(decoded.active?.participantCount, 1)
        XCTAssertTrue(decoded.active?.hasVoted("p1") == true, "App 重開後仍記得誰投過票")

        archive.finishActive(at: date("2026-10-15T01:30:00Z"))
        XCTAssertNil(archive.active)
        XCTAssertEqual(archive.sessions.count, 1)
        let record = archive.sessions[0]
        XCTAssertEqual(record.participants, 1)
        XCTAssertEqual(record.messagesShown, 4)
        XCTAssertEqual(record.turns.first?.endedAt, date("2026-10-15T01:30:00Z"), "進行中的講師時段在場次結束時一起結束")
        let json = String(decoding: try archive.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("阿凱"), "結束後的紀錄不保存觀眾暱稱")
        XCTAssertFalse(json.contains("p1"), "結束後的紀錄不保存觀眾代號")
    }

    func testPersonKeyDoesNotContainAddress() {
        let key = PersonKey.make(statisticsID: "s1", address: "192.168.1.23")
        XCTAssertEqual(key.count, 16)
        XCTAssertFalse(key.contains("192"))
        XCTAssertEqual(key, PersonKey.make(statisticsID: "s1", address: "192.168.1.23"))
        XCTAssertNotEqual(key, PersonKey.make(statisticsID: "s2", address: "192.168.1.23"), "不同場次的代號不同")
    }

    // MARK: 本月最佳講師

    func testMonthlyRankingMergesNameVariantsAndFiltersMonth() {
        let turns = [
            SpeakerTurn(id: "a", speaker: "Amy Chen", startedAt: date("2026-10-02T01:00:00Z"), votes: 10, audience: 40),
            SpeakerTurn(id: "b", speaker: "amy  chen", startedAt: date("2026-10-09T01:00:00Z"), votes: 12, audience: 40),
            SpeakerTurn(id: "c", speaker: "ＡＭＹ Chen", startedAt: date("2026-10-16T01:00:00Z"), votes: 3, audience: 20),
            SpeakerTurn(id: "d", speaker: "王小明", startedAt: date("2026-10-10T01:00:00Z"), votes: 18, audience: 20),
            SpeakerTurn(id: "e", speaker: "王小明", startedAt: date("2026-09-30T23:00:00Z"), votes: 99, audience: 99),
            SpeakerTurn(id: "f", speaker: "李大華", startedAt: date("2026-10-20T01:00:00Z"), votes: 0, audience: 0),
        ]
        let october = MonthKey(year: 2026, month: 10)
        let byVotes = SpeakerRanking.rank(turns, month: october, order: .votes, calendar: utc)
        XCTAssertEqual(byVotes.map(\.name), ["ＡＭＹ Chen", "王小明", "李大華"], "同一人不同寫法合併，名字用最近一次的寫法")
        XCTAssertEqual(byVotes[0].votes, 25)
        XCTAssertEqual(byVotes[0].turns, 3)
        XCTAssertEqual(byVotes[1].votes, 18, "9 月的票不算進 10 月")
        XCTAssertNil(byVotes[2].voteRate)

        let byRate = SpeakerRanking.rank(turns, month: october, order: .rate, calendar: utc)
        XCTAssertEqual(byRate.first?.name, "王小明", "得票率 90% 高於 25/100")
        XCTAssertEqual(SpeakerRanking.months(turns, calendar: utc), [october, MonthKey(year: 2026, month: 9)])
    }

    func testRecentSpeakersAreUniqueAndNewestFirst() {
        var old = SessionStatistics(id: "s1", startedAt: date("2026-10-01T01:00:00Z"))
        old.startTurn(speaker: "王小明", online: 0, at: date("2026-10-01T01:00:00Z"))
        old.startTurn(speaker: "李大華", online: 0, at: date("2026-10-01T01:10:00Z"))
        var archive = StatisticsArchive(active: old)
        archive.finishActive(at: date("2026-10-01T02:00:00Z"))
        var today = SessionStatistics(id: "s2", startedAt: date("2026-10-02T01:00:00Z"))
        today.startTurn(speaker: "王小明 ", online: 0, at: date("2026-10-02T01:00:00Z"))
        archive.active = today
        XCTAssertEqual(archive.recentSpeakers(), ["王小明 ", "李大華"])
    }

    func testSpeakerNameCleaning() {
        XCTAssertEqual(SpeakerName.clean("  王小明\n"), "王小明")
        XCTAssertNil(SpeakerName.clean("   "))
        XCTAssertEqual(SpeakerName.clean(String(repeating: "講", count: 30))?.count, SpeakerName.maxLength)
        XCTAssertEqual(SpeakerName.key("Amy Chen"), SpeakerName.key("ａｍｙ-chen"))
    }

    // MARK: 送禮

    func testGiftQuotaCooldownAndTotals() {
        var stats = SessionStatistics(id: "s1", startedAt: date("2026-10-15T01:00:00Z"))
        let t0 = date("2026-10-15T01:00:10Z")
        XCTAssertEqual(stats.giftCheck(.rocket, person: "p1", quota: 1, at: t0), .sent(remaining: 0))
        stats.recordGift(.rocket, person: "p1", at: t0)
        XCTAssertEqual(stats.giftCheck(.rocket, person: "p1", quota: 1, at: t0.addingTimeInterval(10)), .quotaUsed, "火箭每場 1 次")
        XCTAssertEqual(stats.giftCheck(.popper, person: "p1", quota: 5, at: t0.addingTimeInterval(1)), .tooFast(retryAfter: 2),
                       "連續送禮至少間隔 3 秒")
        XCTAssertEqual(stats.giftCheck(.popper, person: "p1", quota: 5, at: t0.addingTimeInterval(3.5)), .sent(remaining: 4))
        XCTAssertEqual(stats.giftCheck(.popper, person: "p2", quota: 5, at: t0.addingTimeInterval(1)), .sent(remaining: 4), "冷卻時間每人分開算")
        XCTAssertEqual(stats.giftCheck(.fireworks, person: "p2", quota: 0, at: t0), .disabled, "次數設為 0 = 不開放")

        stats.startTurn(speaker: "王小明", online: 2, at: t0.addingTimeInterval(20))
        stats.recordGift(.popper, person: "p2", at: t0.addingTimeInterval(21))
        stats.recordGift(.popper, person: "p1", at: t0.addingTimeInterval(22))
        XCTAssertEqual(stats.giftCount(.rocket), 1)
        XCTAssertEqual(stats.giftCount(.popper), 2)
        XCTAssertEqual(stats.totalGifts, 3)
        XCTAssertEqual(stats.currentTurn?.giftCount(.popper), 2, "講師投票進行中時算進目前講師")
        XCTAssertEqual(stats.currentTurn?.giftCount(.rocket), 0, "講師開始前送的不算給講師")
        XCTAssertEqual(stats.giftsRemaining(for: "p1", quotas: [.popper: 5, .fireworks: 2, .rocket: 1]),
                       ["popper": 4, "fireworks": 2, "rocket": 0])
        XCTAssertEqual(stats.giftsRemaining(for: "p1", quotas: [.popper: 5, .rocket: 0]), ["popper": 4], "沒開放的禮物不出現")

        let record = stats.record(endedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(record.giftCount(.popper), 2)
        XCTAssertEqual(GiftSummary.text(record.gifts), "🚀 1　🎉 2")
        let ranks = SpeakerRanking.rank(record.turns, month: MonthKey(year: 2026, month: 10), calendar: utc)
        XCTAssertEqual(ranks.first?.gifts, ["popper": 2])
    }

    func testGiftReplyMessages() {
        let sent = GiftOutcome.sent(remaining: 0).reply(id: "g1", kind: .rocket, speaker: "王小明")
        XCTAssertEqual(sent.ok, true)
        XCTAssertEqual(sent.code, "sent")
        XCTAssertEqual(sent.kind, "rocket")
        XCTAssertEqual(sent.remaining, 0)
        XCTAssertEqual(sent.message, "🚀 火箭已送給 王小明，看大螢幕！")
        let fast = GiftOutcome.tooFast(retryAfter: 1.2).reply(id: "g2", kind: .popper, speaker: nil)
        XCTAssertEqual(fast.ok, false)
        XCTAssertEqual(fast.retryAfter, 1.2)
        XCTAssertEqual(fast.message, "送太快了，請等 2 秒")
        XCTAssertEqual(GiftOutcome.busy.code, "busy")
        XCTAssertNil(GiftSummary.text([:]))
    }

    func testArchiveFromBeforeGiftsStillLoads() throws {
        // 加入送禮功能之前的統計檔（沒有 gifts 欄位）必須還能讀
        let json = """
        {"version":1,"sessions":[{"id":"s0","startedAt":"2026-10-01T01:00:00Z","endedAt":"2026-10-01T02:00:00Z",
        "participants":30,"peakOnline":28,"senders":12,"messagesReceived":40,"messagesShown":35,"messagesBlocked":5,
        "nicknameChanges":3,"turns":[{"id":"t0","speaker":"王小明","startedAt":"2026-10-01T01:10:00Z",
        "endedAt":"2026-10-01T01:30:00Z","votes":20,"audience":28}]}]}
        """
        let archive = try StatisticsArchive.decode(Data(json.utf8))
        XCTAssertEqual(archive.sessions.first?.turns.first?.votes, 20)
        XCTAssertEqual(archive.sessions.first?.giftCount(.rocket), 0)
        XCTAssertEqual(SpeakerRanking.rank(archive.allTurns, month: MonthKey(year: 2026, month: 10), calendar: utc).first?.gifts, [:])
    }

    // MARK: 匯出

    func testCSVHasOneRowPerSpeakerAndEscapesFields() {
        var stats = SessionStatistics(id: "s1", startedAt: date("2026-10-15T01:00:00Z"))
        stats.join("p1")
        stats.startTurn(speaker: "王小明, Kevin", online: 4, at: date("2026-10-15T01:05:00Z"))
        _ = stats.vote("p1", turnID: nil)
        stats.recordGift(.fireworks, person: "p1", at: date("2026-10-15T01:06:00Z"))
        stats.startTurn(speaker: "=SUM(A1)", online: 4, at: date("2026-10-15T01:20:00Z"))
        var archive = StatisticsArchive(active: stats)
        archive.finishActive(at: date("2026-10-15T01:40:00Z"))
        archive.active = SessionStatistics(id: "s2", startedAt: date("2026-10-16T01:00:00Z"))

        let csv = StatisticsCSV.make(archive, now: date("2026-10-16T01:10:00Z"), timeZone: TimeZone(identifier: "UTC")!)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "表頭 + 2 位講師 + 進行中的場次")
        XCTAssertEqual(lines[0], StatisticsCSV.header.joined(separator: ","))
        XCTAssertTrue(lines[1].hasPrefix("2026-10-15,01:00,01:40,\"王小明, Kevin\",1,4,25%,0,1,0,1,"), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(",0,1,0"), "本場禮物：火箭 0、煙火 1、拉炮 0")
        XCTAssertTrue(lines[2].contains(",'=SUM(A1),"), "公式開頭的內容加上 ' 避免被試算表執行")
        XCTAssertTrue(lines[3].hasPrefix("2026-10-16,01:00,進行中,,,,,,,,0,"), lines[3])
    }
}
