import DanmakuCore
import Foundation

/// 統計檔：`~/Library/Application Support/URBANLive/statistics.json`，只存在這台 Mac。
/// 內容只有數字與講師姓名；進行中的場次另外暫存觀眾代號（雜湊，不是 IP）以防重複投票，場次結束後刪除。
final class StatisticsStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("URBANLive", isDirectory: true).appendingPathComponent("statistics.json")
    }

    func load() -> StatisticsArchive {
        guard let data = try? Data(contentsOf: url) else { return StatisticsArchive() }
        do {
            return try StatisticsArchive.decode(data)
        } catch {
            // 檔案損毀：留一份備份再重新開始，不要讓 App 打不開
            let backup = url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("URBAN LIVE: 統計檔無法讀取，已備份為 \(backup.lastPathComponent)：\(error)")
            return StatisticsArchive()
        }
    }

    @discardableResult
    func save(_ archive: StatisticsArchive) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("URBAN LIVE: 統計檔無法儲存：\(error)")
            return false
        }
    }

    /// 匯出 CSV（加上 BOM，Excel 打開中文才不會亂碼）。
    func exportCSV(_ archive: StatisticsArchive, to destination: URL) throws {
        let text = "\u{FEFF}" + StatisticsCSV.make(archive)
        try Data(text.utf8).write(to: destination, options: .atomic)
    }
}

/// 大螢幕上的公布卡片。
enum Announcement: Equatable {
    case bestSpeaker(month: MonthKey, order: RankingOrder, ranks: [SpeakerRank])
    case sessionSummary(SessionSummary)
}

/// 「本場數據」卡片的內容。
struct SessionSummary: Equatable {
    var date: Date
    var participants: Int
    var peakOnline: Int
    var senders: Int
    var shown: Int
    var votes: Int
    var nicknameChanges: Int
    var topRenamer: String?
    var topRenamerChanges: Int
    var speakers: [(name: String, votes: Int)]

    init(_ stats: SessionStatistics) {
        date = stats.startedAt
        participants = stats.participantCount
        peakOnline = stats.peakOnline
        senders = stats.senderCount
        shown = stats.messagesShown
        votes = stats.totalVotes
        nicknameChanges = stats.nicknameChanges
        topRenamer = stats.topRenamer?.display
        topRenamerChanges = stats.topRenamer?.changes ?? 0
        speakers = stats.turns.map { (name: $0.speaker, votes: $0.votes) }
    }

    /// 已結束的場次（紀錄裡沒有暱稱，所以沒有「換名王」）。
    init(record: SessionRecord) {
        date = record.startedAt
        participants = record.participants
        peakOnline = record.peakOnline
        senders = record.senders
        shown = record.messagesShown
        votes = record.totalVotes
        nicknameChanges = record.nicknameChanges
        topRenamer = nil
        topRenamerChanges = 0
        speakers = record.turns.map { (name: $0.speaker, votes: $0.votes) }
    }

    static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool {
        lhs.date == rhs.date && lhs.participants == rhs.participants && lhs.peakOnline == rhs.peakOnline
            && lhs.senders == rhs.senders && lhs.shown == rhs.shown && lhs.votes == rhs.votes
            && lhs.nicknameChanges == rhs.nicknameChanges && lhs.topRenamer == rhs.topRenamer
            && lhs.topRenamerChanges == rhs.topRenamerChanges
            && lhs.speakers.map(\.name) == rhs.speakers.map(\.name) && lhs.speakers.map(\.votes) == rhs.speakers.map(\.votes)
    }
}
