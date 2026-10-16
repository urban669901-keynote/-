import Foundation

// 手機 ⇄ Mac 的 WebSocket 訊息（JSON，欄位 `t` 表示類型）。
//
// 手機 → Mac
//   {"t":"hello","clientId":"c_xxx","profile":{...}}   連線後第一則
//   {"t":"profile","profile":{...}}                      更新暱稱 / 大頭貼
//   {"t":"send","id":"m_1","text":"URBAN 今天衝三件 🔥"}
//   {"t":"vote","turn":"abc123"}                         講師超棒投票（turn = 手機看到的講師時段）
//   {"t":"gift","id":"g_1","kind":"rocket"}              免費送禮特效（popper / fireworks / rocket）
//   {"t":"ping"}
//
// Mac → 手機
//   {"t":"welcome","state":"live",...}                    目前狀態與限制
//   {"t":"state","state":"paused","message":"..."}        主持人操作時即時推送
//   {"t":"ack","id":"m_1","ok":true,"code":"queued",...}  已收到（或被拒絕的原因）
//   {"t":"shown","id":"m_1"}                              已出現在大螢幕
//   {"t":"dropped","id":"m_1","message":"..."}            排隊太久、或被清空，沒有顯示
//   {"t":"profile","ok":false,"message":"..."}
//   {"t":"speaker","speaker":"王小明","turn":"abc123","votes":0,"voted":false}  主持人開始 / 結束講師投票（沒有 speaker = 結束）
//   {"t":"vote","ok":true,"code":"voted","votes":23,"voted":true,...}           投票結果
//   {"t":"votes","turn":"abc123","votes":24}              票數更新（最多每秒一次）
//   {"t":"gift","id":"g_1","ok":true,"code":"sent","kind":"rocket","remaining":0,...}  送禮結果
//   {"t":"gifts","gifts":{"popper":5,"fireworks":2,"rocket":1}}  主持人調整送禮設定（沒有 gifts = 不開放）
//   {"t":"bye","code":"ended","message":"..."}            場次結束 / 連結失效 / 被封鎖

public struct AvatarSpec: Codable, Equatable {
    /// "none" / "emoji" / "photo"
    public var kind: String
    /// emoji 本身
    public var value: String?
    /// emoji 背景色（#RRGGBB）
    public var color: String?
    /// 照片：data URL（data:image/jpeg;base64,...）
    public var data: String?

    public init(kind: String, value: String? = nil, color: String? = nil, data: String? = nil) {
        self.kind = kind
        self.value = value
        self.color = color
        self.data = data
    }
}

public struct ViewerProfile: Codable, Equatable {
    public var nickname: String?
    public var avatar: AvatarSpec?

    public init(nickname: String? = nil, avatar: AvatarSpec? = nil) {
        self.nickname = nickname
        self.avatar = avatar
    }
}

public struct ClientMessage: Codable, Equatable {
    public var t: String
    public var clientId: String?
    public var profile: ViewerProfile?
    public var id: String?
    public var text: String?
    /// 投票的講師時段
    public var turn: String?
    /// 送禮的種類
    public var kind: String?

    public init(
        t: String, clientId: String? = nil, profile: ViewerProfile? = nil, id: String? = nil, text: String? = nil,
        turn: String? = nil, kind: String? = nil
    ) {
        self.t = t
        self.clientId = clientId
        self.profile = profile
        self.id = id
        self.text = text
        self.turn = turn
        self.kind = kind
    }

    public static func decode(_ text: String) -> ClientMessage? {
        try? JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
    }
}

public struct ServerMessage: Codable, Equatable {
    public var t: String
    public var id: String?
    public var ok: Bool?
    public var code: String?
    public var state: String?
    public var message: String?
    public var retryAfter: Double?
    public var queue: Int?
    public var maxLength: Int?
    public var cooldown: Double?
    public var allowPhoto: Bool?
    public var nickname: String?
    /// 大頭貼與暱稱的顯示大小（standard / large / extraLarge），手機預覽依此呈現
    public var profileSize: String?
    /// 講師投票：目前的講師、時段、票數、這支手機是否已投
    public var speaker: String?
    public var turn: String?
    public var votes: Int?
    public var voted: Bool?
    /// 送禮：種類、這種禮物還剩幾次；`gifts` 為每種禮物還剩幾次（沒有 = 主持人沒有開放）
    public var kind: String?
    public var remaining: Int?
    public var gifts: [String: Int]?

    public init(
        t: String, id: String? = nil, ok: Bool? = nil, code: String? = nil, state: String? = nil,
        message: String? = nil, retryAfter: Double? = nil, queue: Int? = nil, maxLength: Int? = nil,
        cooldown: Double? = nil, allowPhoto: Bool? = nil, nickname: String? = nil, profileSize: String? = nil,
        speaker: String? = nil, turn: String? = nil, votes: Int? = nil, voted: Bool? = nil,
        kind: String? = nil, remaining: Int? = nil, gifts: [String: Int]? = nil
    ) {
        self.t = t
        self.id = id
        self.ok = ok
        self.code = code
        self.state = state
        self.message = message
        self.retryAfter = retryAfter
        self.queue = queue
        self.maxLength = maxLength
        self.cooldown = cooldown
        self.allowPhoto = allowPhoto
        self.nickname = nickname
        self.profileSize = profileSize
        self.speaker = speaker
        self.turn = turn
        self.votes = votes
        self.voted = voted
        self.kind = kind
        self.remaining = remaining
        self.gifts = gifts
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// HTTP 備援通道（WebSocket 連不上時）：POST /api/send
public struct HTTPSendPayload: Codable, Equatable {
    public var session: String
    public var clientId: String?
    public var text: String
    public var nickname: String?

    public init(session: String, clientId: String? = nil, text: String, nickname: String? = nil) {
        self.session = session
        self.clientId = clientId
        self.text = text
        self.nickname = nickname
    }
}

/// HTTP 備援通道：POST /api/vote
public struct HTTPVotePayload: Codable, Equatable {
    public var session: String
    public var clientId: String?
    public var turn: String?

    public init(session: String, clientId: String? = nil, turn: String? = nil) {
        self.session = session
        self.clientId = clientId
        self.turn = turn
    }
}

/// HTTP 回應（手機網頁直接顯示 `message`）。
public struct APIResult: Codable, Equatable {
    public var ok: Bool
    public var code: String
    public var message: String
    public var retryAfter: Double?
    public var votes: Int?
    public var voted: Bool?
    public var remaining: Int?

    public init(
        ok: Bool, code: String, message: String, retryAfter: Double? = nil, votes: Int? = nil, voted: Bool? = nil, remaining: Int? = nil
    ) {
        self.ok = ok
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.votes = votes
        self.voted = voted
        self.remaining = remaining
    }
}

/// 驗證過的大頭貼。
public enum ValidatedAvatar: Equatable {
    case none
    case emoji(String, colorHex: String)
    case photo(Data)

    public static let maxPhotoBytes = 96 * 1024
    public static let palette = ["#123B8A", "#2563EB", "#102A5B", "#0EA5E9", "#7C3AED", "#DB2777", "#EA580C", "#16A34A", "#F3C969"]

    /// 不合格的內容一律退回 `.none`，不讓錯誤資料影響顯示。
    public static func validate(_ spec: AvatarSpec?, allowPhoto: Bool) -> ValidatedAvatar {
        guard let spec else { return .none }
        switch spec.kind {
        case "emoji":
            guard let value = spec.value, value.count == 1, value.unicodeScalars.count <= 12,
                  value.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C })
            else { return .none }
            let color = spec.color.flatMap { isHexColor($0) ? $0.uppercased() : nil } ?? palette[1]
            return .emoji(value, colorHex: color)
        case "photo":
            guard allowPhoto, let dataURL = spec.data else { return .none }
            let prefixes = ["data:image/jpeg;base64,", "data:image/png;base64,"]
            guard let prefix = prefixes.first(where: { dataURL.hasPrefix($0) }),
                  dataURL.count <= maxPhotoBytes * 4 / 3 + 64,
                  let bytes = Data(base64Encoded: String(dataURL.dropFirst(prefix.count))),
                  bytes.count <= maxPhotoBytes,
                  isJPEG(bytes) || isPNG(bytes)
            else { return .none }
            return .photo(bytes)
        default:
            return .none
        }
    }

    static func isHexColor(_ text: String) -> Bool {
        text.count == 7 && text.hasPrefix("#") && text.dropFirst().allSatisfy { $0.isHexDigit }
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    static func isPNG(_ data: Data) -> Bool {
        data.count > 8 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

/// 找出真正的觀眾位址。只有在連線來自本機（例如 cloudflared 等通道程式轉送）時，
/// 才信任轉送標頭；區域網路的手機無法藉由偽造標頭繞過限流。
public enum ClientAddress {
    public static func key(peer: String, headers: [String: String]) -> String {
        guard isLoopback(peer) else { return peer }
        let forwarded = headers["cf-connecting-ip"] ?? headers["x-forwarded-for"]?.split(separator: ",").first.map(String.init)
        let trimmed = forwarded?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? peer : trimmed
    }

    public static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.")
    }
}
