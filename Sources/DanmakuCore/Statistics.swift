import CryptoKit
import Foundation

// 講師投票與數據統計。
//
// - 每一位講師上台是一個「投票時段」（SpeakerTurn）；同一場早會可以有好幾位講師輪流。
// - 每個人對同一個時段只能投一次（以 IP 區分，與限流相同）。
// - 進行中的場次以「代號」（場次 ID + IP 的雜湊）辨識同一個人，不保存 IP；
//   場次結束後只留下數字與講師姓名（SessionRecord），不含訊息內容、暱稱或照片。

// MARK: - 講師姓名

public enum SpeakerName {
    public static let maxLength = 20

    /// 顯示用：清掉控制字元與多餘空白，最多 20 個字。
    public static func clean(_ raw: String?) -> String? {
        MessageSanitizer.sanitizeNickname(raw, maxLength: maxLength)
    }

    /// 合併票數用的比對鍵：全形半形、大小寫、空白與標點不同，都算同一位講師。
    public static func key(_ name: String) -> String {
        let normalized = ContentFilter.normalize(name)
        return normalized.isEmpty ? name : normalized
    }
}

// MARK: - 代號

public enum PersonKey {
    /// 同一場內辨識同一個人（防止重複投票）用的代號，不直接保存 IP。
    public static func make(statisticsID: String, address: String) -> String {
        let digest = SHA256.hash(data: Data("\(statisticsID)|\(address)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func randomID() -> String {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<12).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

// MARK: - 投票時段

public struct SpeakerTurn: Codable, Equatable, Identifiable {
    public var id: String
    public var speaker: String
    public var startedAt: Date
    public var endedAt: Date?
    public var votes: Int
    /// 這段時間最多同時在線的人數（算得票率用）
    public var audience: Int

    public init(id: String, speaker: String, startedAt: Date, endedAt: Date? = nil, votes: Int = 0, audience: Int = 0) {
        self.id = id
        self.speaker = speaker
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.votes = votes
        self.audience = audience
    }

    /// 得票率 = 票數 ÷ 在線人數（最多 100%）。
    public var voteRate: Double? {
        audience > 0 ? min(1, Double(votes) / Double(audience)) : nil
    }
}

public enum VoteOutcome: Equatable {
    case accepted(votes: Int)
    case alreadyVoted(votes: Int)
    /// 目前沒有進行講師投票
    case noSpeaker
    /// 手機按的是上一位講師（主持人已經換人）
    case staleTurn
}

// MARK: - 換名紀錄

public struct NicknameTrail: Codable, Equatable {
    public static let maxNames = 6

    /// 用過的暱稱（第一個與最近幾個）
    public private(set) var names: [String]
    public private(set) var changes: Int

    public init(first: String) {
        names = [first]
        changes = 0
    }

    var current: String { names[names.count - 1] }

    mutating func change(to name: String) -> Bool {
        guard name != current else { return false }
        changes += 1
        names.append(name)
        if names.count > Self.maxNames { names.remove(at: 1) }
        return true
    }

    /// 例如「小明 → 大明 → 明明」；中間太多時以「…」省略。
    public var display: String {
        guard changes + 1 > names.count else { return names.joined(separator: " → ") }
        return ([names[0], "…"] + names.dropFirst()).joined(separator: " → ")
    }
}

// MARK: - 本場統計

public struct SessionStatistics: Codable, Equatable {
    public let id: String
    public let startedAt: Date
    public private(set) var updatedAt: Date
    public private(set) var participants: Set<String> = []
    public private(set) var peakOnline = 0
    public private(set) var senders: Set<String> = []
    public var messagesReceived = 0
    public var messagesShown = 0
    public var messagesBlocked = 0
    public private(set) var nicknameChanges = 0
    private var trails: [String: NicknameTrail] = [:]
    public private(set) var turns: [SpeakerTurn] = []
    /// 目前這位講師已經投過票的人
    private var voters: Set<String> = []

    public init(id: String = PersonKey.randomID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        updatedAt = startedAt
    }

    public var participantCount: Int { participants.count }
    public var senderCount: Int { senders.count }
    public var totalVotes: Int { turns.reduce(0) { $0 + $1.votes } }

    public var currentTurn: SpeakerTurn? {
        guard let last = turns.last, last.endedAt == nil else { return nil }
        return last
    }

    /// 換名次數最多的人（至少換過 1 次）。
    public var topRenamer: NicknameTrail? {
        trails.values
            .filter { $0.changes > 0 }
            .max { ($0.changes, $1.display) < ($1.changes, $0.display) }
    }

    public mutating func join(_ person: String, at date: Date = Date()) {
        participants.insert(person)
        updatedAt = date
    }

    /// 記錄暱稱；換成和上一個不同的暱稱才算「換名」（第一次設定、清空、重新連線都不算）。
    @discardableResult
    public mutating func setNickname(_ name: String?, for person: String) -> Bool {
        guard let name, !name.isEmpty else { return false }
        guard var trail = trails[person] else {
            trails[person] = NicknameTrail(first: name)
            return false
        }
        let changed = trail.change(to: name)
        trails[person] = trail
        if changed { nicknameChanges += 1 }
        return changed
    }

    /// 每隔一段時間記錄在線人數：更新最高同時在線，以及目前講師的在場人數。
    public mutating func recordOnline(_ count: Int, at date: Date = Date()) {
        peakOnline = max(peakOnline, count)
        if currentTurn != nil {
            turns[turns.count - 1].audience = max(turns[turns.count - 1].audience, count)
        }
        updatedAt = date
    }

    public mutating func recordSender(_ person: String) {
        senders.insert(person)
    }

    /// 開始為一位講師投票（若有上一位，先結束）。
    @discardableResult
    public mutating func startTurn(speaker: String, online: Int, at date: Date = Date(), id: String = PersonKey.randomID()) -> SpeakerTurn {
        endTurn(at: date)
        let turn = SpeakerTurn(id: id, speaker: speaker, startedAt: date, audience: online)
        turns.append(turn)
        voters = []
        updatedAt = date
        return turn
    }

    public mutating func endTurn(at date: Date = Date()) {
        guard currentTurn != nil else { return }
        turns[turns.count - 1].endedAt = date
        voters = []
        updatedAt = date
    }

    /// 投票：每個人對每位講師只能投一次。`turnID` 為手機看到的講師時段，nil 代表目前這位。
    public mutating func vote(_ person: String, turnID: String?, at date: Date = Date()) -> VoteOutcome {
        guard let turn = currentTurn else { return .noSpeaker }
        if let turnID, turnID != turn.id { return .staleTurn }
        guard !voters.contains(person) else { return .alreadyVoted(votes: turn.votes) }
        voters.insert(person)
        turns[turns.count - 1].votes += 1
        updatedAt = date
        return .accepted(votes: turns[turns.count - 1].votes)
    }

    public func hasVoted(_ person: String) -> Bool {
        currentTurn != nil && voters.contains(person)
    }

    /// 場次結束時保存的紀錄：只有數字與講師姓名。
    public func record(endedAt: Date) -> SessionRecord {
        var closed = turns
        if let last = closed.indices.last, closed[last].endedAt == nil {
            closed[last].endedAt = endedAt
        }
        return SessionRecord(
            id: id, startedAt: startedAt, endedAt: endedAt,
            participants: participants.count, peakOnline: peakOnline, senders: senders.count,
            messagesReceived: messagesReceived, messagesShown: messagesShown, messagesBlocked: messagesBlocked,
            nicknameChanges: nicknameChanges, turns: closed
        )
    }
}

// MARK: - 保存的紀錄

public struct SessionRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var participants: Int
    public var peakOnline: Int
    public var senders: Int
    public var messagesReceived: Int
    public var messagesShown: Int
    public var messagesBlocked: Int
    public var nicknameChanges: Int
    public var turns: [SpeakerTurn]

    public var totalVotes: Int { turns.reduce(0) { $0 + $1.votes } }
}

/// 存在 Mac 上的統計檔（JSON）。
public struct StatisticsArchive: Codable, Equatable {
    public var version = 1
    public var sessions: [SessionRecord] = []
    /// 進行中的場次（App 意外關閉後重開可以接著統計）
    public var active: SessionStatistics?

    public init(sessions: [SessionRecord] = [], active: SessionStatistics? = nil) {
        self.sessions = sessions
        self.active = active
    }

    /// 把進行中的場次轉成紀錄保存。
    public mutating func finishActive(at date: Date) {
        guard let active else { return }
        sessions.append(active.record(endedAt: date))
        self.active = nil
    }

    /// 所有講師時段（含進行中的場次），排行榜用。
    public var allTurns: [SpeakerTurn] {
        sessions.flatMap(\.turns) + (active?.turns ?? [])
    }

    /// 最近的講師（不重複，最新的在前），控制面板快速選擇用。
    public func recentSpeakers(limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for turn in allTurns.sorted(by: { $0.startedAt > $1.startedAt }) where seen.insert(SpeakerName.key(turn.speaker)).inserted {
            names.append(turn.speaker)
            if names.count == limit { break }
        }
        return names
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> StatisticsArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatisticsArchive.self, from: data)
    }
}

// MARK: - 本月最佳講師

public struct MonthKey: Hashable, Comparable, Codable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month], from: date)
        self.init(year: components.year ?? 2000, month: components.month ?? 1)
    }

    public var title: String { "\(year) 年 \(month) 月" }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

public enum RankingOrder: String, CaseIterable, Codable {
    /// 總票數（講越多次、票越多）
    case votes
    /// 得票率（票數 ÷ 在場人數；比較公平地比較只講一次的講師）
    case rate

    public var title: String {
        switch self {
        case .votes: return "依總票數"
        case .rate: return "依得票率"
        }
    }
}

public struct SpeakerRank: Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    /// 最近一次使用的寫法
    public let name: String
    public let votes: Int
    public let turns: Int
    public let audience: Int

    public var voteRate: Double? {
        audience > 0 ? min(1, Double(votes) / Double(audience)) : nil
    }
}

public enum SpeakerRanking {
    public static func rank(
        _ turns: [SpeakerTurn], month: MonthKey, order: RankingOrder = .votes, calendar: Calendar = .current
    ) -> [SpeakerRank] {
        let inMonth = turns.filter { MonthKey($0.startedAt, calendar: calendar) == month }
        let grouped = Dictionary(grouping: inMonth) { SpeakerName.key($0.speaker) }
        let ranks = grouped.map { key, group -> SpeakerRank in
            let latest = group.max { $0.startedAt < $1.startedAt }!
            return SpeakerRank(
                key: key, name: latest.speaker,
                votes: group.reduce(0) { $0 + $1.votes }, turns: group.count,
                audience: group.reduce(0) { $0 + $1.audience }
            )
        }
        return ranks.sorted { lhs, rhs in
            let lhsRate = lhs.voteRate ?? -1
            let rhsRate = rhs.voteRate ?? -1
            switch order {
            case .votes:
                if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
                if lhsRate != rhsRate { return lhsRate > rhsRate }
            case .rate:
                if lhsRate != rhsRate { return lhsRate > rhsRate }
                if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
            }
            return lhs.name < rhs.name
        }
    }

    /// 有講師紀錄的月份（新的在前）。
    public static func months(_ turns: [SpeakerTurn], calendar: Calendar = .current) -> [MonthKey] {
        Set(turns.map { MonthKey($0.startedAt, calendar: calendar) }).sorted(by: >)
    }
}

// MARK: - 匯出 CSV

public enum StatisticsCSV {
    public static let header = [
        "日期", "場次開始", "場次結束", "講師", "講師得票", "投票時在線人數", "得票率",
        "本場參與人數", "本場最高同時在線", "本場發言人數", "本場收到彈幕", "本場上螢幕", "本場擋下", "本場換名次數",
    ]

    /// 每位講師一列（沒有講師的場次也有一列），Excel / Numbers 可直接做樞紐分析。
    public static func make(_ archive: StatisticsArchive, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = formatter("yyyy-MM-dd", timeZone)
        let time = formatter("HH:mm", timeZone)
        var records = archive.sessions
        if let active = archive.active {
            records.append(active.record(endedAt: now))
        }
        var rows = [header]
        for record in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            let isActive = record.id == archive.active?.id
            let session = [
                String(record.participants), String(record.peakOnline), String(record.senders),
                String(record.messagesReceived), String(record.messagesShown), String(record.messagesBlocked),
                String(record.nicknameChanges),
            ]
            let base = [day.string(from: record.startedAt), time.string(from: record.startedAt), isActive ? "進行中" : time.string(from: record.endedAt)]
            if record.turns.isEmpty {
                rows.append(base + ["", "", "", ""] + session)
            }
            for turn in record.turns {
                let rate = turn.voteRate.map { String(format: "%.0f%%", $0 * 100) } ?? ""
                rows.append(base + [turn.speaker, String(turn.votes), String(turn.audience), rate] + session)
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        var value = field
        // 避免以 = + - @ 開頭的內容在試算表裡被當成公式
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - 回覆手機

extension VoteOutcome {
    public var code: String {
        switch self {
        case .accepted: return "voted"
        case .alreadyVoted: return "already_voted"
        case .noSpeaker: return "no_speaker"
        case .staleTurn: return "stale_turn"
        }
    }

    public func message(speaker: String?) -> String {
        switch self {
        case .accepted: return "已投給 \(speaker ?? "講師")，謝謝！"
        case .alreadyVoted: return "你已經投過這位講師了"
        case .noSpeaker: return "目前沒有進行講師投票"
        case .staleTurn: return "講師已經換人了，請再按一次"
        }
    }

    public var votes: Int? {
        switch self {
        case let .accepted(votes), let .alreadyVoted(votes): return votes
        case .noSpeaker, .staleTurn: return nil
        }
    }

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// WebSocket 回覆。
    public func reply(speaker: String?, turn: String?) -> ServerMessage {
        let voted: Bool?
        switch self {
        case .accepted, .alreadyVoted: voted = true
        case .noSpeaker, .staleTurn: voted = nil
        }
        return ServerMessage(t: "vote", ok: isAccepted, code: code, message: message(speaker: speaker),
                             speaker: speaker, turn: turn, votes: votes, voted: voted)
    }
}
