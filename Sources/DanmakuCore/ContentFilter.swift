import Foundation

/// 敏感詞過濾。比對前先正規化：全形轉半形、轉小寫、去掉空白與標點，
/// 所以「幹 你 娘」、「F.U.C.K」這類拆字寫法也會被擋下。
public struct ContentFilter {
    /// 預設詞庫：只放明確的辱罵字詞，避免誤擋（例如不收「幹」單字，以免擋到「幹部」「能幹」）。
    /// 主持人可在控制面板增修。
    public static let defaultWords: [String] = [
        "幹你娘", "幹您娘", "幹恁娘", "姦你娘", "靠北", "靠杯", "靠腰", "雞掰", "機掰", "機歪",
        "他媽的", "你媽的", "操你", "肏", "王八蛋", "賤人", "婊子", "白痴", "白癡", "智障", "去死",
        "fuck", "shit", "bitch", "asshole", "motherfucker",
    ]

    public let words: [String]
    private let normalizedWords: [String]

    public init(words: [String] = ContentFilter.defaultWords) {
        let cleaned = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.words = cleaned
        normalizedWords = Array(Set(cleaned.map(Self.normalize).filter { !$0.isEmpty }))
    }

    /// 全形 → 半形、小寫，只保留文字與數字。
    public static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// 回傳第一個命中的敏感詞；沒有命中回傳 nil。
    public func firstMatch(in text: String) -> String? {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return nil }
        return normalizedWords.first { normalized.contains($0) }
    }
}

/// 同一位觀眾在一段時間內重複送出相同內容時擋下。
public struct DuplicateFilter {
    public var window: TimeInterval
    private var history: [String: [(text: String, at: TimeInterval)]] = [:]
    private var lastPrune: TimeInterval = 0

    public init(window: TimeInterval = 30) {
        self.window = window
    }

    /// 比對用的形式：保留 Emoji，忽略大小寫、全半形與空白。
    static func fingerprint(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    public func isDuplicate(key: String, text: String, now: TimeInterval) -> Bool {
        let fingerprint = Self.fingerprint(text)
        return history[key]?.contains { $0.text == fingerprint && now - $0.at < window } ?? false
    }

    public mutating func record(key: String, text: String, now: TimeInterval) {
        prune(now: now)
        var entries = history[key, default: []].filter { now - $0.at < window }
        entries.append((text: Self.fingerprint(text), at: now))
        history[key] = Array(entries.suffix(20))
    }

    public mutating func reset() {
        history.removeAll()
    }

    private mutating func prune(now: TimeInterval) {
        guard now - lastPrune > 60 else { return }
        lastPrune = now
        history = history.compactMapValues { entries in
            let kept = entries.filter { now - $0.at < window }
            return kept.isEmpty ? nil : kept
        }
    }
}
