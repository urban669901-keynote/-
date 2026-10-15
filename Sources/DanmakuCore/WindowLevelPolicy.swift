import CoreGraphics
import Foundation

/// 彈幕 Overlay 的視窗層級模式。
public enum WindowLevelMode: String, CaseIterable, Codable {
    /// 預設螢幕保護程式層級；偵測到其他 App 用更高層級蓋滿螢幕（例如簡報播放視窗）時自動往上墊一層。
    case auto
    /// 固定在螢幕保護程式層級（NSWindow.Level.screenSaver = 1000）。
    case screenSaver
    /// 固定在 Shielding Window 之上（螢幕被「擷取」時也能顯示）。
    case maximum

    public var title: String {
        switch self {
        case .auto: return "自動（建議）"
        case .screenSaver: return "螢幕保護程式層級"
        case .maximum: return "最高層級"
        }
    }
}

/// 從 CGWindowList 取得的一個螢幕上視窗的摘要。
public struct ObservedWindow: Equatable {
    public var ownerName: String
    public var ownerPID: Int32
    public var layer: Int
    /// 全域座標（左上角為原點，與 CGWindowList 相同）。
    public var bounds: CGRect
    /// 擁有者是否為一般 App（Dock 上有圖示的 App，例如 Keynote、PowerPoint、瀏覽器）。
    public var isRegularApp: Bool
    public var alpha: Double

    public init(ownerName: String, ownerPID: Int32, layer: Int, bounds: CGRect, isRegularApp: Bool, alpha: Double = 1) {
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.isRegularApp = isRegularApp
        self.alpha = alpha
    }

    /// 這個視窗蓋住螢幕的比例（0...1）。
    public func coverage(of screen: CGRect) -> Double {
        let area = screen.width * screen.height
        guard area > 0 else { return 0 }
        let overlap = bounds.intersection(screen)
        guard !overlap.isNull else { return 0 }
        return Double(overlap.width * overlap.height / area)
    }
}

public enum WindowLevelPolicy {
    /// 視窗蓋住螢幕多少比例以上，才當作「全螢幕簡報視窗」。
    public static let coverageThreshold = 0.8

    public struct Decision: Equatable {
        public var level: Int
        /// 造成層級被墊高的視窗（若有）。
        public var raisedAbove: ObservedWindow?
    }

    /// 判斷 Overlay 應該用的層級。
    ///
    /// - Parameters:
    ///   - baseLevel: 平常使用的層級（螢幕保護程式層級）。
    ///   - maximumLevel: 允許的最高層級（Shielding 層級 + 1）。
    ///   - ownPID: 自己的 process id，自己的視窗不列入計算。
    public static func decide(
        mode: WindowLevelMode,
        windows: [ObservedWindow],
        screen: CGRect,
        ownPID: Int32,
        baseLevel: Int,
        maximumLevel: Int
    ) -> Decision {
        switch mode {
        case .screenSaver:
            return Decision(level: baseLevel, raisedAbove: nil)
        case .maximum:
            return Decision(level: maximumLevel, raisedAbove: nil)
        case .auto:
            let blockers = windows.filter {
                $0.ownerPID != ownPID
                    && $0.isRegularApp
                    && $0.alpha > 0.05
                    && $0.layer >= baseLevel
                    && $0.coverage(of: screen) >= coverageThreshold
            }
            guard let top = blockers.max(by: { $0.layer < $1.layer }) else {
                return Decision(level: baseLevel, raisedAbove: nil)
            }
            let level = min(maximumLevel, top.layer + 1)
            return Decision(level: level, raisedAbove: top)
        }
    }
}
