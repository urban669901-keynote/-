import Foundation

/// 彈幕顯示區域模式。
public enum DisplayArea: String, CaseIterable, Codable {
    /// 整個畫面
    case full
    /// 上方約 30%
    case top
    /// 下方約 30%（預設）
    case bottom

    public var title: String {
        switch self {
        case .full: return "全螢幕"
        case .top: return "上方區域"
        case .bottom: return "下方區域"
        }
    }

    /// 上下各保留 2%，避免投影機 / 電視過掃描（overscan）把彈幕切掉。
    public var region: DisplayRegion {
        switch self {
        case .full: return DisplayRegion(top: 0.02, bottom: 0.98)
        case .top: return DisplayRegion(top: 0.02, bottom: 0.32)
        case .bottom: return DisplayRegion(top: 0.68, bottom: 0.98)
        }
    }
}

/// 彈幕可以出現的垂直範圍，以螢幕高度的比例表示（0 = 最上方，1 = 最下方）。
public struct DisplayRegion: Equatable, Codable {
    public static let minimumSpan = 0.1

    public private(set) var top: Double
    public private(set) var bottom: Double

    public init(top: Double, bottom: Double) {
        var top = min(max(top, 0), 1 - Self.minimumSpan)
        var bottom = min(max(bottom, 0), 1)
        if bottom - top < Self.minimumSpan {
            bottom = min(1, top + Self.minimumSpan)
            top = bottom - Self.minimumSpan
        }
        self.top = top
        self.bottom = bottom
    }

    /// 換算成「距離畫面頂端」的範圍。`topInset` 是瀏海等不可用區域。
    public func span(stageHeight: Double, topInset: Double = 0) -> (top: Double, bottom: Double) {
        let usable = max(0, stageHeight - topInset)
        return (topInset + top * usable, topInset + bottom * usable)
    }

    /// 這個範圍可以放幾條軌道（至少 1 條）。
    public func laneCount(stageHeight: Double, topInset: Double = 0, laneHeight: Double, laneSpacing: Double) -> Int {
        let range = self.span(stageHeight: stageHeight, topInset: topInset)
        let height = range.bottom - range.top
        guard laneHeight + laneSpacing > 0 else { return 1 }
        return max(1, Int((height + laneSpacing) / (laneHeight + laneSpacing)))
    }
}

/// 以 1920×1080 為設計基準：設定的字體大小是「在 1080p 畫面上的像素」，
/// 實際點數依螢幕高度等比例換算，所以不同解析度投影出來的比例一致。
public enum ReferenceScale {
    public static let referenceHeight = 1080.0

    public static func points(forReferencePixels pixels: Double, screenHeightPoints: Double) -> Double {
        guard screenHeightPoints > 0 else { return pixels }
        return pixels * screenHeightPoints / referenceHeight
    }
}
