import Foundation

/// 一次互動場次。每次「開始彈幕」或「重新產生連結」都會產生新的隨機識別碼，
/// 手機必須帶著這個識別碼才能連線與發送；舊的 QR Code 立即失效。
public struct LiveSession: Codable, Equatable {
    /// 去掉容易混淆的 0/O、1/I。
    public static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    public static let tokenLength = 8

    public var token: String
    public var startedAt: Date
    public var expiresAt: Date

    public init(token: String, startedAt: Date, expiresAt: Date) {
        self.token = token
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }

    /// 以系統安全亂數產生識別碼（32^8 ≈ 1 兆種組合）。
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<tokenLength).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public static func start(now: Date = Date(), duration: TimeInterval) -> LiveSession {
        LiveSession(token: newToken(), startedAt: now, expiresAt: now.addingTimeInterval(max(60, duration)))
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    public func remaining(now: Date = Date()) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    public func accepts(token candidate: String?, now: Date = Date()) -> Bool {
        guard let candidate, !isExpired(now: now) else { return false }
        // 固定時間比較，避免以回應時間猜測識別碼
        let lhs = Array(candidate.uppercased().utf8)
        let rhs = Array(token.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    /// 手機加入網址的路徑：`/j/<識別碼>`
    public var joinPath: String { "/j/\(token)" }

    /// 從 `/j/XXXX` 取出識別碼（格式不符回傳 nil）。
    public static func token(fromJoinPath path: String) -> String? {
        guard path.hasPrefix("/j/") else { return nil }
        let candidate = path.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: "/")).uppercased()
        guard candidate.count == tokenLength, candidate.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return candidate
    }
}
