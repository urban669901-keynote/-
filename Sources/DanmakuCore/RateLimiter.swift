import Foundation

/// 每支手機（以 IP 區分）的 token bucket 限流，避免有人狂刷。
public struct RateLimiter {
    public struct Decision: Equatable {
        public var allowed: Bool
        /// 被擋下時，建議幾秒後再試。
        public var retryAfter: TimeInterval
    }

    /// 連續可送幾則。
    public var burst: Int
    /// 每隔幾秒補 1 則額度。
    public var refillInterval: TimeInterval

    private var buckets: [String: (tokens: Double, updatedAt: TimeInterval)] = [:]
    private var lastPrune: TimeInterval = 0

    public init(burst: Int = 3, refillInterval: TimeInterval = 2) {
        self.burst = max(1, burst)
        self.refillInterval = max(0.1, refillInterval)
    }

    public mutating func check(key: String, now: TimeInterval) -> Decision {
        prune(now: now)
        var bucket = buckets[key] ?? (tokens: Double(burst), updatedAt: now)
        let elapsed = max(0, now - bucket.updatedAt)
        bucket.tokens = min(Double(burst), bucket.tokens + elapsed / refillInterval)
        bucket.updatedAt = now

        if bucket.tokens >= 1 {
            bucket.tokens -= 1
            buckets[key] = bucket
            return Decision(allowed: true, retryAfter: 0)
        }
        buckets[key] = bucket
        return Decision(allowed: false, retryAfter: (1 - bucket.tokens) * refillInterval)
    }

    public mutating func reset() {
        buckets.removeAll()
    }

    /// 每分鐘清掉早已補滿的紀錄，避免無限長大。
    private mutating func prune(now: TimeInterval) {
        guard now - lastPrune > 60 else { return }
        lastPrune = now
        let fullAfter = Double(burst) * refillInterval
        buckets = buckets.filter { now - $0.value.updatedAt < fullAfter }
    }
}
