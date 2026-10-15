import Foundation

/// 場次目前的狀態（也是手機上顯示的狀態）。
public enum LiveState: String, Equatable {
    /// 彈幕進行中
    case live
    /// 主持人暫停
    case paused
    /// 主持人暫時隱藏彈幕
    case hidden
    /// 沒有場次 / 場次已結束
    case ended

    public var phoneMessage: String {
        switch self {
        case .live: return "彈幕進行中，輸入訊息就能上大螢幕"
        case .paused: return "主持人暫停了彈幕，請稍候"
        case .hidden: return "彈幕暫時隱藏中，請稍候"
        case .ended: return "場次已結束，請等待下一場"
        }
    }
}

public struct ModerationSettings: Equatable {
    /// 單則訊息最多幾個字（Emoji 算 1 字）
    public var maxLength: Int
    public var nicknameMaxLength: Int
    /// 每位觀眾每幾秒最多 1 則
    public var cooldown: TimeInterval
    /// 同一位觀眾幾秒內不能重複送出相同內容
    public var duplicateWindow: TimeInterval
    public var blockedWords: [String]

    public init(
        maxLength: Int = MessageSanitizer.defaultMaxLength,
        nicknameMaxLength: Int = MessageSanitizer.defaultNicknameMaxLength,
        cooldown: TimeInterval = 5,
        duplicateWindow: TimeInterval = 30,
        blockedWords: [String] = ContentFilter.defaultWords
    ) {
        self.maxLength = maxLength
        self.nicknameMaxLength = nicknameMaxLength
        self.cooldown = cooldown
        self.duplicateWindow = duplicateWindow
        self.blockedWords = blockedWords
    }
}

public struct Rejection: Error, Equatable {
    public var code: String
    public var message: String
    public var retryAfter: Double?

    public init(code: String, message: String, retryAfter: Double? = nil) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }
}

/// 決定一則彈幕能不能上螢幕：封鎖 → 場次狀態 → 內容 → 敏感詞 → 重複 → 佇列 → 頻率。
public struct ModerationGate {
    public private(set) var settings: ModerationSettings
    public private(set) var blockedAddresses: Set<String> = []
    public private(set) var blockedClients: Set<String> = []

    private var limiter: RateLimiter
    private var duplicates: DuplicateFilter
    private var filter: ContentFilter

    public init(settings: ModerationSettings = ModerationSettings()) {
        self.settings = settings
        limiter = RateLimiter(burst: 1, refillInterval: settings.cooldown)
        duplicates = DuplicateFilter(window: settings.duplicateWindow)
        filter = ContentFilter(words: settings.blockedWords)
    }

    public mutating func update(_ newSettings: ModerationSettings) {
        if newSettings.cooldown != settings.cooldown {
            limiter = RateLimiter(burst: 1, refillInterval: newSettings.cooldown)
        }
        if newSettings.blockedWords != settings.blockedWords {
            filter = ContentFilter(words: newSettings.blockedWords)
        }
        duplicates.window = newSettings.duplicateWindow
        settings = newSettings
    }

    /// 新場次：清除限流、重複紀錄與封鎖名單。
    public mutating func resetForNewSession() {
        limiter.reset()
        duplicates.reset()
        blockedAddresses.removeAll()
        blockedClients.removeAll()
    }

    // MARK: - 封鎖

    public mutating func block(address: String, clientId: String?) {
        blockedAddresses.insert(address)
        if let clientId { blockedClients.insert(clientId) }
    }

    public mutating func unblock(address: String, clientId: String?) {
        blockedAddresses.remove(address)
        if let clientId { blockedClients.remove(clientId) }
    }

    public func isBlocked(address: String, clientId: String?) -> Bool {
        if blockedAddresses.contains(address) { return true }
        if let clientId, blockedClients.contains(clientId) { return true }
        return false
    }

    // MARK: - 判斷

    public mutating func evaluate(
        text raw: String,
        address: String,
        clientId: String?,
        now: TimeInterval,
        state: LiveState,
        queueFull: Bool
    ) -> Result<String, Rejection> {
        if isBlocked(address: address, clientId: clientId) {
            return .failure(Rejection(code: "blocked", message: "你已被主持人暫停發言"))
        }
        guard state == .live else {
            return .failure(Rejection(code: state.rawValue, message: state.phoneMessage))
        }
        guard let text = MessageSanitizer.sanitize(raw, maxLength: settings.maxLength) else {
            return .failure(Rejection(code: "empty", message: "請輸入文字或 Emoji"))
        }
        if filter.firstMatch(in: text) != nil {
            return .failure(Rejection(code: "filtered", message: "訊息含有不適當的字詞，請修改後再送"))
        }
        if duplicates.isDuplicate(key: address, text: text, now: now) {
            return .failure(Rejection(code: "duplicate", message: "請不要重複送出相同的訊息"))
        }
        if queueFull {
            return .failure(Rejection(code: "queue_full", message: "目前彈幕太多，請稍後再送", retryAfter: 10))
        }
        let decision = limiter.check(key: address, now: now)
        guard decision.allowed else {
            let wait = max(1, Int(decision.retryAfter.rounded(.up)))
            return .failure(Rejection(code: "too_fast", message: "請等 \(wait) 秒後再送", retryAfter: decision.retryAfter))
        }
        duplicates.record(key: address, text: text, now: now)
        return .success(text)
    }

    /// 暱稱：空白視為不設定；含敏感詞則拒絕。
    public func evaluateNickname(_ raw: String?) -> Result<String?, Rejection> {
        guard let nickname = MessageSanitizer.sanitizeNickname(raw, maxLength: settings.nicknameMaxLength) else {
            return .success(nil)
        }
        if filter.firstMatch(in: nickname) != nil {
            return .failure(Rejection(code: "filtered", message: "暱稱含有不適當的字詞，請修改"))
        }
        return .success(nickname)
    }
}
