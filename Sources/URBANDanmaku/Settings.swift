import Combine
import DanmakuCore
import Foundation

enum QRPosition: String, CaseIterable {
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

/// 使用者設定（存在 UserDefaults，改了立即套用）。
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Defaults {
        static let fontSize = 48.0
        static let crossingSeconds = 9.0
        static let opacity = 1.0
        static let region = DisplayRegion.default
        static let qrVisible = true
        static let qrPosition = QRPosition.bottomRight
        static let qrSize = 200.0
        static let levelMode = WindowLevelMode.auto
        static let port = 8765
    }

    private enum Key {
        static let fontSize = "fontSize"
        static let crossingSeconds = "crossingSeconds"
        static let opacity = "opacity"
        static let regionTop = "regionTop"
        static let regionBottom = "regionBottom"
        static let qrVisible = "qrVisible"
        static let qrPosition = "qrPosition"
        static let qrSize = "qrSize"
        static let levelMode = "windowLevelMode"
        static let port = "port"
        static let preferredInterface = "preferredInterface"
    }

    private let store: UserDefaults

    /// 字體大小（pt）。預設 48。
    @Published var fontSize: Double { didSet { store.set(fontSize, forKey: Key.fontSize) } }
    /// 彈幕從右到左通過整個畫面需要幾秒（越小越快）。
    @Published var crossingSeconds: Double { didSet { store.set(crossingSeconds, forKey: Key.crossingSeconds) } }
    /// 彈幕整體不透明度 0.2...1。
    @Published var opacity: Double { didSet { store.set(opacity, forKey: Key.opacity) } }
    /// 顯示區域上緣（0 = 畫面頂端）。
    @Published var regionTop: Double { didSet { store.set(regionTop, forKey: Key.regionTop) } }
    /// 顯示區域下緣（1 = 畫面底部）。
    @Published var regionBottom: Double { didSet { store.set(regionBottom, forKey: Key.regionBottom) } }
    @Published var qrVisible: Bool { didSet { store.set(qrVisible, forKey: Key.qrVisible) } }
    @Published var qrPosition: QRPosition { didSet { store.set(qrPosition.rawValue, forKey: Key.qrPosition) } }
    @Published var qrSize: Double { didSet { store.set(qrSize, forKey: Key.qrSize) } }
    @Published var levelMode: WindowLevelMode { didSet { store.set(levelMode.rawValue, forKey: Key.levelMode) } }
    /// 手機網址優先使用的網路介面（例如 en0）；nil 代表自動。
    @Published var preferredInterface: String? { didSet { store.set(preferredInterface, forKey: Key.preferredInterface) } }

    /// 伺服器埠號。被佔用時會自動往後找。只能用 `defaults write` 修改。
    let port: Int

    var region: DisplayRegion {
        DisplayRegion(top: regionTop, bottom: regionBottom)
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        fontSize = store.object(forKey: Key.fontSize) as? Double ?? Defaults.fontSize
        crossingSeconds = store.object(forKey: Key.crossingSeconds) as? Double ?? Defaults.crossingSeconds
        opacity = store.object(forKey: Key.opacity) as? Double ?? Defaults.opacity
        regionTop = store.object(forKey: Key.regionTop) as? Double ?? Defaults.region.top
        regionBottom = store.object(forKey: Key.regionBottom) as? Double ?? Defaults.region.bottom
        qrVisible = store.object(forKey: Key.qrVisible) as? Bool ?? Defaults.qrVisible
        qrPosition = (store.string(forKey: Key.qrPosition)).flatMap(QRPosition.init(rawValue:)) ?? Defaults.qrPosition
        qrSize = store.object(forKey: Key.qrSize) as? Double ?? Defaults.qrSize
        levelMode = (store.string(forKey: Key.levelMode)).flatMap(WindowLevelMode.init(rawValue:)) ?? Defaults.levelMode
        preferredInterface = store.string(forKey: Key.preferredInterface)
        let storedPort = store.integer(forKey: Key.port)
        port = (1024...65000).contains(storedPort) ? storedPort : Defaults.port
    }

    func applyRegion(_ region: DisplayRegion) {
        regionTop = region.top
        regionBottom = region.bottom
    }

    func resetToDefaults() {
        fontSize = Defaults.fontSize
        crossingSeconds = Defaults.crossingSeconds
        opacity = Defaults.opacity
        applyRegion(Defaults.region)
        qrVisible = Defaults.qrVisible
        qrPosition = Defaults.qrPosition
        qrSize = Defaults.qrSize
        levelMode = Defaults.levelMode
    }
}
