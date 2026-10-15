import Foundation

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

    public struct Preset: Equatable {
        public var name: String
        public var region: DisplayRegion
    }

    public static let presets: [Preset] = [
        Preset(name: "上方 1/3", region: DisplayRegion(top: 0, bottom: 1.0 / 3.0)),
        Preset(name: "上半部", region: DisplayRegion(top: 0, bottom: 0.5)),
        Preset(name: "上方 2/3", region: DisplayRegion(top: 0, bottom: 2.0 / 3.0)),
        Preset(name: "全畫面", region: DisplayRegion(top: 0, bottom: 1)),
        Preset(name: "下半部", region: DisplayRegion(top: 0.5, bottom: 1)),
    ]

    public static let `default` = DisplayRegion(top: 0, bottom: 2.0 / 3.0)

    /// 換算成「距離畫面頂端」的像素範圍。`topInset` 是瀏海等不可用區域。
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
