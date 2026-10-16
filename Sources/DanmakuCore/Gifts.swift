import Foundation

// 免費送禮特效：拉炮、煙火、火箭。不涉及金錢，每個人每場有次數限制，
// 送出時大螢幕播放特效；講師投票進行中時算是送給目前的講師。

public enum GiftKind: String, CaseIterable, Codable {
    case popper
    case fireworks
    case rocket

    public var emoji: String {
        switch self {
        case .popper: return "🎉"
        case .fireworks: return "🎆"
        case .rocket: return "🚀"
        }
    }

    public var title: String {
        switch self {
        case .popper: return "拉炮"
        case .fireworks: return "煙火"
        case .rocket: return "火箭"
        }
    }

    /// 每人每場可以送幾次（主持人可調整，0 = 不開放）
    public var defaultQuota: Int {
        switch self {
        case .popper: return 5
        case .fireworks: return 2
        case .rocket: return 1
        }
    }

    /// 同一個人連續送禮至少間隔幾秒
    public static let cooldown: TimeInterval = 3
    public static let maxQuota = 10
}

public enum GiftOutcome: Equatable {
    /// 送出成功（這種禮物還剩幾次）
    case sent(remaining: Int)
    /// 這場的次數用完了
    case quotaUsed
    case tooFast(retryAfter: Double)
    /// 主持人沒有開放這種禮物
    case disabled
    /// 大螢幕上排隊的特效太多
    case busy
    /// 場次暫停、隱藏或已結束
    case notLive(String)

    public var code: String {
        switch self {
        case .sent: return "sent"
        case .quotaUsed: return "quota_used"
        case .tooFast: return "too_fast"
        case .disabled: return "disabled"
        case .busy: return "busy"
        case .notLive: return "not_live"
        }
    }

    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    public func message(kind: GiftKind, speaker: String?) -> String {
        switch self {
        case .sent:
            if let speaker { return "\(kind.emoji) \(kind.title)已送給 \(speaker)，看大螢幕！" }
            return "\(kind.emoji) \(kind.title)已送出，看大螢幕！"
        case .quotaUsed: return "這場的 \(kind.emoji) \(kind.title)已經用完了"
        case let .tooFast(retryAfter): return "送太快了，請等 \(Int(retryAfter.rounded(.up))) 秒"
        case .disabled: return "主持人目前沒有開放\(kind.title)"
        case .busy: return "大螢幕特效太多了，請稍後再送"
        case let .notLive(message): return message
        }
    }

    public var remaining: Int? {
        if case let .sent(remaining) = self { return remaining }
        return nil
    }

    public var retryAfter: Double? {
        if case let .tooFast(seconds) = self { return seconds }
        return nil
    }

    /// WebSocket 回覆。
    public func reply(id: String?, kind: GiftKind, speaker: String?) -> ServerMessage {
        ServerMessage(t: "gift", id: id, ok: isSent, code: code, message: message(kind: kind, speaker: speaker),
                      retryAfter: retryAfter, kind: kind.rawValue, remaining: remaining)
    }
}

/// HTTP 備援通道：POST /api/gift
public struct HTTPGiftPayload: Codable, Equatable {
    public var session: String
    public var clientId: String?
    public var kind: String

    public init(session: String, clientId: String? = nil, kind: String) {
        self.session = session
        self.clientId = clientId
        self.kind = kind
    }
}

/// 禮物數量的顯示文字，例如「🚀 3　🎆 5　🎉 20」；沒有就回傳 nil。
public enum GiftSummary {
    public static func text(_ counts: [String: Int]?, separator: String = "　") -> String? {
        let parts = GiftKind.allCases.reversed().compactMap { kind -> String? in
            guard let count = counts?[kind.rawValue], count > 0 else { return nil }
            return "\(kind.emoji) \(count)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }
}
