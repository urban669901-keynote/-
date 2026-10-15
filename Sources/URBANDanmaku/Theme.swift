import AppKit

/// URBAN Blue 視覺設定。要改品牌色只需要改這裡。
enum Theme {
    /// 主色：URBAN Blue。
    static let urbanBlue = NSColor(srgbRed: 11 / 255, green: 61 / 255, blue: 145 / 255, alpha: 1)

    /// 彈幕膠囊：深藍半透明玻璃（上亮下深的漸層）。
    static let capsuleTop = NSColor(srgbRed: 30 / 255, green: 82 / 255, blue: 178 / 255, alpha: 0.80)
    static let capsuleBottom = NSColor(srgbRed: 7 / 255, green: 33 / 255, blue: 92 / 255, alpha: 0.84)
    /// 玻璃反光（膠囊上半部）。
    static let capsuleHighlight = NSColor(white: 1, alpha: 0.22)
    /// 玻璃邊框。
    static let capsuleBorder = NSColor(white: 1, alpha: 0.38)
    static let capsuleShadow = NSColor(white: 0, alpha: 0.35)

    static let text = NSColor.white
    static let textShadow = NSColor(white: 0, alpha: 0.35)

    /// 測試用的範例彈幕。
    static let sampleMessages = [
        "早安 URBAN ☀️",
        "👏👏👏",
        "簡報很清楚！",
        "加油 💪",
        "🎉🎉",
        "URBAN Blue 好看 💙",
        "+1 👍",
        "這個數字太強了 🔥",
        "☕️ 咖啡續命中",
        "🙌",
    ]
}
