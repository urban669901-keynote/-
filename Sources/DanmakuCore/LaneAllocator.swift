import Foundation

/// 彈幕軌道分配：同一條軌道上的彈幕不會互相重疊，也不會後面追撞前面。
///
/// 每則彈幕從軌道的起點（通常是畫面右緣；QR Code 卡片擋住的軌道則從卡片左緣）進入，
/// 以固定速度往左移動到完全離開。新的彈幕要放進某條軌道，需同時滿足：
/// 1. 前一則的尾巴已經完全進入畫面，並且多留了 `gap` 的間距；
/// 2. 若新彈幕比前一則快（較長的彈幕速度較快），在前一則離開畫面前不會追上它。
public struct LaneAllocator {
    private struct Lane {
        /// 前一則尾巴進入畫面 + gap 的時間。
        var tailClearAt: TimeInterval = 0
        /// 前一則完全離開畫面左緣的時間。
        var exitAt: TimeInterval = 0
    }

    private var lanes: [Lane]

    public init(laneCount: Int) {
        lanes = Array(repeating: Lane(), count: max(1, laneCount))
    }

    public var laneCount: Int { lanes.count }

    /// 改變軌道數（例如調整字體或顯示區域），保留既有軌道狀態。
    public mutating func resize(laneCount: Int) {
        let count = max(1, laneCount)
        if count < lanes.count {
            lanes.removeLast(lanes.count - count)
        } else if count > lanes.count {
            lanes.append(contentsOf: Array(repeating: Lane(), count: count - lanes.count))
        }
    }

    public mutating func reset() {
        lanes = Array(repeating: Lane(), count: lanes.count)
    }

    /// 這條軌道最早什麼時候可以放入一則以 `speed` 移動的新彈幕。
    private func availableAt(_ lane: Lane, speed: Double, travel: Double, gap: Double) -> TimeInterval {
        let noCatchUp = lane.exitAt - max(0, travel - gap) / speed
        return max(lane.tailClearAt, noCatchUp)
    }

    /// 取得最上方可用的軌道；全部忙碌時回傳 nil。
    /// - Parameter travel: 每條軌道起點的 x 座標（= 從起點到左緣的距離）。
    public mutating func acquire(
        now: TimeInterval,
        itemWidth: Double,
        speed: Double,
        gap: Double,
        travel: (Int) -> Double
    ) -> Int? {
        guard speed > 0 else { return nil }
        for index in lanes.indices {
            let distance = travel(index)
            guard availableAt(lanes[index], speed: speed, travel: distance, gap: gap) <= now else { continue }
            lanes[index].tailClearAt = now + (itemWidth + gap) / speed
            lanes[index].exitAt = now + (distance + itemWidth) / speed
            return index
        }
        return nil
    }

    /// 所有軌道起點相同時的簡便版本。
    public mutating func acquire(now: TimeInterval, itemWidth: Double, speed: Double, stageWidth: Double, gap: Double) -> Int? {
        acquire(now: now, itemWidth: itemWidth, speed: speed, gap: gap, travel: { _ in stageWidth })
    }

    /// 最快有軌道空出來的時間（給等待佇列排程用）。
    public func nextAvailableTime(speed: Double, stageWidth: Double, gap: Double) -> TimeInterval {
        guard speed > 0 else { return .infinity }
        return lanes.map { availableAt($0, speed: speed, travel: stageWidth, gap: gap) }.min() ?? 0
    }
}
