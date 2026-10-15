import Combine
import DanmakuCore
import Foundation

/// 彈幕樣式。
enum DanmakuStyle: String, CaseIterable, Codable {
    /// 樣式 A：深藍半透明玻璃膠囊（預設）
    case glass
    /// 樣式 B：無背景、白字深色描邊
    case classic
    /// 樣式 C：白色 URBAN LIVE 訊息卡
    case card

    var title: String {
        switch self {
        case .glass: return "A 玻璃膠囊"
        case .classic: return "B 經典高對比"
        case .card: return "C URBAN LIVE 訊息卡"
        }
    }
}

/// 大頭貼與暱稱的大小。「大」與「特大」改為兩行：上行暱稱、下行訊息，大頭貼放大讓人像看得清楚。
enum ProfileSize: String, CaseIterable, Codable {
    /// 單行：小大頭貼 + 暱稱 + 訊息
    case standard
    /// 兩行，大頭貼約為單行的 1.7 倍（預設）
    case large
    /// 兩行，大頭貼超出膠囊上下緣，約為單行的 2.3 倍
    case extraLarge

    var title: String {
        switch self {
        case .standard: return "標準（單行）"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }
}

enum QRPosition: String, CaseIterable, Codable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    var title: String {
        switch self {
        case .bottomRight: return "右下"
        case .bottomLeft: return "左下"
        case .topRight: return "右上"
        case .topLeft: return "左上"
        }
    }
}

/// 使用者設定（存在 UserDefaults，改了立即套用，不需重新啟動）。
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Defaults {
        static let style = DanmakuStyle.glass
        static let profileSize = ProfileSize.large
        static let fontSize = 48.0
        static let crossingSeconds = 10.0
        static let opacity = 1.0
        static let area = DisplayArea.bottom
        static let maxConcurrent = 5
        static let qrSize = 220.0
        static let maxLength = 25
        static let cooldown = 5.0
        static let duplicateWindow = 30.0
        static let sessionHours = 3.0
        static let port = 8765
    }

    private let store: UserDefaults

    // 外觀
    @Published var style: DanmakuStyle { didSet { save(style.rawValue, "style") } }
    /// 以 1920×1080 為基準的像素（32～72，預設 48），實際大小依螢幕解析度換算。
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    /// 單則彈幕通過畫面約幾秒（預設 10 秒）。
    @Published var crossingSeconds: Double { didSet { save(crossingSeconds, "crossingSeconds") } }
    @Published var opacity: Double { didSet { save(opacity, "opacity") } }
    @Published var area: DisplayArea { didSet { save(area.rawValue, "area") } }
    @Published var maxConcurrent: Int { didSet { save(maxConcurrent, "maxConcurrent") } }
    @Published var showNickname: Bool { didSet { save(showNickname, "showNickname") } }
    @Published var showAvatar: Bool { didSet { save(showAvatar, "showAvatar") } }
    /// 大頭貼與暱稱大小（預設「大」）
    @Published var profileSize: ProfileSize { didSet { save(profileSize.rawValue, "profileSize") } }
    @Published var allowPhotoAvatar: Bool { didSet { save(allowPhotoAvatar, "allowPhotoAvatar") } }

    // QR Code
    @Published var qrVisible: Bool { didSet { save(qrVisible, "qrVisible") } }
    @Published var qrPosition: QRPosition { didSet { save(qrPosition.rawValue, "qrPosition") } }
    /// 小型 QR 的大小（1080p 基準像素）。
    @Published var qrSize: Double { didSet { save(qrSize, "qrSize") } }

    // 管理
    @Published var maxLength: Int { didSet { save(maxLength, "maxLength") } }
    @Published var cooldown: Double { didSet { save(cooldown, "cooldown") } }
    @Published var duplicateWindow: Double { didSet { save(duplicateWindow, "duplicateWindow") } }
    @Published var blockedWords: [String] { didSet { save(blockedWords, "blockedWords") } }
    @Published var sessionHours: Double { didSet { save(sessionHours, "sessionHours") } }

    // 進階
    @Published var levelMode: WindowLevelMode { didSet { save(levelMode.rawValue, "windowLevelMode") } }
    @Published var preferredInterface: String? { didSet { save(preferredInterface, "preferredInterface") } }
    /// 選用：外部網址（例如自行架設的 Cloudflare Tunnel），QR Code 會改用這個網址。
    @Published var externalBaseURL: String { didSet { save(externalBaseURL, "externalBaseURL") } }
    @Published var shortcuts: [ShortcutAction: Shortcut] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
            save(try? JSONEncoder().encode(encoded), "shortcuts")
        }
    }
    @Published var openPanelAtLaunch: Bool { didSet { save(openPanelAtLaunch, "openPanelAtLaunch") } }

    /// 伺服器埠號（被佔用時自動往後找）。只能用 `defaults write` 修改。
    let port: Int

    init(store: UserDefaults = .standard) {
        self.store = store
        style = store.string(forKey: "style").flatMap(DanmakuStyle.init(rawValue:)) ?? Defaults.style
        fontSize = Self.clamp(store.object(forKey: "fontSize") as? Double ?? Defaults.fontSize, 32, 72)
        crossingSeconds = Self.clamp(store.object(forKey: "crossingSeconds") as? Double ?? Defaults.crossingSeconds, 6, 16)
        opacity = Self.clamp(store.object(forKey: "opacity") as? Double ?? Defaults.opacity, 0.3, 1)
        area = store.string(forKey: "area").flatMap(DisplayArea.init(rawValue:)) ?? Defaults.area
        maxConcurrent = Int(Self.clamp(Double(store.object(forKey: "maxConcurrent") as? Int ?? Defaults.maxConcurrent), 1, 12))
        showNickname = store.object(forKey: "showNickname") as? Bool ?? true
        showAvatar = store.object(forKey: "showAvatar") as? Bool ?? true
        profileSize = store.string(forKey: "profileSize").flatMap(ProfileSize.init(rawValue:)) ?? Defaults.profileSize
        allowPhotoAvatar = store.object(forKey: "allowPhotoAvatar") as? Bool ?? true
        qrVisible = store.object(forKey: "qrVisible") as? Bool ?? true
        qrPosition = store.string(forKey: "qrPosition").flatMap(QRPosition.init(rawValue:)) ?? .bottomRight
        qrSize = Self.clamp(store.object(forKey: "qrSize") as? Double ?? Defaults.qrSize, 140, 400)
        maxLength = Int(Self.clamp(Double(store.object(forKey: "maxLength") as? Int ?? Defaults.maxLength), 5, 60))
        cooldown = Self.clamp(store.object(forKey: "cooldown") as? Double ?? Defaults.cooldown, 1, 60)
        duplicateWindow = Self.clamp(store.object(forKey: "duplicateWindow") as? Double ?? Defaults.duplicateWindow, 0, 600)
        blockedWords = store.stringArray(forKey: "blockedWords") ?? ContentFilter.defaultWords
        sessionHours = Self.clamp(store.object(forKey: "sessionHours") as? Double ?? Defaults.sessionHours, 0.5, 12)
        levelMode = store.string(forKey: "windowLevelMode").flatMap(WindowLevelMode.init(rawValue:)) ?? .auto
        preferredInterface = store.string(forKey: "preferredInterface")
        externalBaseURL = store.string(forKey: "externalBaseURL") ?? ""
        openPanelAtLaunch = store.object(forKey: "openPanelAtLaunch") as? Bool ?? true

        var loaded: [ShortcutAction: Shortcut] = [:]
        if let data = store.data(forKey: "shortcuts"),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            for (key, value) in decoded {
                if let action = ShortcutAction(rawValue: key) { loaded[action] = value }
            }
        }
        for action in ShortcutAction.allCases where loaded[action] == nil {
            loaded[action] = action.defaultShortcut
        }
        shortcuts = loaded

        let storedPort = store.integer(forKey: "port")
        port = (1024...65000).contains(storedPort) ? storedPort : Defaults.port
    }

    var moderation: ModerationSettings {
        ModerationSettings(
            maxLength: maxLength,
            nicknameMaxLength: MessageSanitizer.defaultNicknameMaxLength,
            cooldown: cooldown,
            duplicateWindow: duplicateWindow,
            blockedWords: blockedWords
        )
    }

    func resetAppearance() {
        style = Defaults.style
        fontSize = Defaults.fontSize
        crossingSeconds = Defaults.crossingSeconds
        opacity = Defaults.opacity
        area = Defaults.area
        maxConcurrent = Defaults.maxConcurrent
        showNickname = true
        showAvatar = true
        profileSize = Defaults.profileSize
        qrSize = Defaults.qrSize
        qrPosition = .bottomRight
    }

    func resetShortcuts() {
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    }

    private func save(_ value: Any?, _ key: String) {
        store.set(value, forKey: key)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
