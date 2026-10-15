import Foundation

/// 手機送出的 JSON：`{"text": "..."}`
public struct SubmitPayload: Codable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// API 回應（手機網頁會直接顯示 `message`）。
public struct APIResult: Codable, Equatable {
    public var ok: Bool
    public var code: String
    public var message: String
    public var retryAfter: Double?

    public init(ok: Bool, code: String, message: String, retryAfter: Double? = nil) {
        self.ok = ok
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }
}

/// 狀態查詢回應（手機網頁顯示「開啟中 / 暫停中」）。
public struct StatusPayload: Codable, Equatable {
    public var state: String
    public var message: String
    public var maxLength: Int

    public init(state: String, message: String, maxLength: Int) {
        self.state = state
        self.message = message
        self.maxLength = maxLength
    }
}

public enum OverlayState: String, Equatable {
    case live
    case paused
    case off

    public var phoneMessage: String {
        switch self {
        case .live: return "彈幕開啟中"
        case .paused: return "主持人暫停了彈幕，請稍候"
        case .off: return "彈幕目前沒有開啟"
        }
    }
}

/// 決定一則投稿要不要顯示：格式 → 狀態 → 內容 → 限流。
public struct SubmissionGate {
    public enum Outcome: Equatable {
        case accepted(String)
        case rejected(status: Int, result: APIResult)
    }

    public var rateLimiter: RateLimiter
    public var maxLength: Int

    public init(rateLimiter: RateLimiter = RateLimiter(), maxLength: Int = MessageSanitizer.defaultMaxLength) {
        self.rateLimiter = rateLimiter
        self.maxLength = maxLength
    }

    public mutating func evaluate(body: Data, clientKey: String, now: TimeInterval, state: OverlayState) -> Outcome {
        guard let payload = try? JSONDecoder().decode(SubmitPayload.self, from: body) else {
            return .rejected(status: 400, result: APIResult(ok: false, code: "bad_request", message: "格式錯誤，請重新整理頁面"))
        }
        switch state {
        case .live:
            break
        case .paused:
            return .rejected(status: 423, result: APIResult(ok: false, code: "paused", message: state.phoneMessage))
        case .off:
            return .rejected(status: 503, result: APIResult(ok: false, code: "off", message: state.phoneMessage))
        }
        guard let text = MessageSanitizer.sanitize(payload.text, maxLength: maxLength) else {
            return .rejected(status: 400, result: APIResult(ok: false, code: "empty", message: "請輸入文字或 Emoji"))
        }
        let decision = rateLimiter.check(key: clientKey, now: now)
        guard decision.allowed else {
            let wait = max(1, Int(decision.retryAfter.rounded(.up)))
            return .rejected(status: 429, result: APIResult(
                ok: false,
                code: "too_fast",
                message: "送太快了，請 \(wait) 秒後再試",
                retryAfter: decision.retryAfter
            ))
        }
        return .accepted(text)
    }
}
