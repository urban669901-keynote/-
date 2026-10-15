import AppKit

extension NSColor {
    /// 以 0xRRGGBB 建立 sRGB 顏色。
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 解析 "#RRGGBB"。
    convenience init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// URBAN 品牌色。
enum Brand {
    /// 皇家藍 #123B8A
    static let royalBlue = NSColor(hex: 0x123B8A)
    /// 電光藍 #2563EB
    static let electricBlue = NSColor(hex: 0x2563EB)
    /// 冰川白 #F5FAFF
    static let glacierWhite = NSColor(hex: 0xF5FAFF)
    /// 深海藍 #102A5B
    static let deepSea = NSColor(hex: 0x102A5B)
    /// 暖金 #F3C969（少量點綴）
    static let warmGold = NSColor(hex: 0xF3C969)
}

/// 測試與預覽用的範例彈幕（暱稱、Emoji 大頭貼、內容）。
enum Samples {
    struct Message {
        let nickname: String?
        let avatarEmoji: String?
        let avatarColor: String
        let text: String
    }

    static let messages: [Message] = [
        Message(nickname: "Kevin", avatarEmoji: "🦁", avatarColor: "#2563EB", text: "URBAN 今天衝三件 🔥"),
        Message(nickname: "小美", avatarEmoji: "🐰", avatarColor: "#DB2777", text: "早安大家 ☀️"),
        Message(nickname: nil, avatarEmoji: nil, avatarColor: "#123B8A", text: "👏👏👏"),
        Message(nickname: "阿哲", avatarEmoji: "🐯", avatarColor: "#EA580C", text: "這個數字太強了！"),
        Message(nickname: "Joyce", avatarEmoji: nil, avatarColor: "#2563EB", text: "加油 💪"),
        Message(nickname: "處經理", avatarEmoji: "🦅", avatarColor: "#102A5B", text: "URBAN 6699 最棒 💙"),
        Message(nickname: nil, avatarEmoji: nil, avatarColor: "#123B8A", text: "+1 👍"),
        Message(nickname: "新人小王", avatarEmoji: "🐼", avatarColor: "#16A34A", text: "收到！今天一起衝 🚀"),
    ]
}
