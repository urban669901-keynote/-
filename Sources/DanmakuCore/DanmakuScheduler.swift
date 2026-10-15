import Foundation

/// 彈幕移動速度模型。
///
/// 以「通過畫面的時間」為準（預設 10 秒，可在 8～12 秒間調整）；
/// 越長的彈幕時間稍微拉長（最多 +25%），但速度仍比短彈幕快，觀眾有足夠時間讀完。
public struct MotionModel: Equatable {
    public var baseDuration: Double
    public var stageWidth: Double

    public init(baseDuration: Double, stageWidth: Double) {
        self.baseDuration = max(1, baseDuration)
        self.stageWidth = max(1, stageWidth)
    }

    public func duration(itemWidth: Double) -> Double {
        baseDuration * (1 + 0.25 * min(1, max(0, itemWidth / stageWidth)))
    }

    /// 每秒移動的點數。
    public func speed(itemWidth: Double) -> Double {
        (stageWidth + itemWidth) / duration(itemWidth: itemWidth)
    }
}

/// 彈幕排程：同時顯示上限、軌道分配、等待佇列與丟棄策略。
///
/// - 同時在畫面上的彈幕不超過 `maxConcurrent`（預設 5）。
/// - 其餘依先後順序排隊；佇列滿了，新訊息直接告知手機「太多了，稍後再送」（不假裝成功）。
/// - 排隊超過 `maxWait` 秒的訊息丟棄並通知手機，避免散會後才冒出來。
public struct DanmakuScheduler<Item> {
    public struct Limits: Equatable {
        public var maxConcurrent: Int
        public var maxPending: Int
        public var maxWait: TimeInterval

        public init(maxConcurrent: Int = 5, maxPending: Int = 30, maxWait: TimeInterval = 60) {
            self.maxConcurrent = max(1, maxConcurrent)
            self.maxPending = max(1, maxPending)
            self.maxWait = max(1, maxWait)
        }
    }

    public struct Placement {
        public let item: Item
        public let lane: Int
        /// 起點 x 座標（從這裡往左移動到 -width）
        public let startX: Double
        public let width: Double
        public let speed: Double
        public let duration: Double
        /// 排隊等了幾秒
        public let waited: Double
    }

    public var limits: Limits
    private var lanes: LaneAllocator
    private var activeExits: [TimeInterval] = []
    private var queue: [(item: Item, enqueuedAt: TimeInterval)] = []

    public init(limits: Limits = Limits(), laneCount: Int = 1) {
        self.limits = limits
        lanes = LaneAllocator(laneCount: laneCount)
    }

    public var pendingCount: Int { queue.count }
    public var isFull: Bool { queue.count >= limits.maxPending }
    public var laneCount: Int { lanes.laneCount }

    public func activeCount(now: TimeInterval) -> Int {
        activeExits.filter { $0 > now }.count
    }

    public mutating func setLaneCount(_ count: Int) {
        lanes.resize(laneCount: count)
    }

    /// 放入佇列，回傳排隊位置（1 起算）；佇列已滿回傳 nil。
    public mutating func enqueue(_ item: Item, now: TimeInterval) -> Int? {
        guard !isFull else { return nil }
        queue.append((item: item, enqueuedAt: now))
        return queue.count
    }

    /// 取出現在可以上場的彈幕。
    /// - Parameters:
    ///   - laneStart: 每條軌道起點的 x 座標
    ///   - width: 彈幕寬度；回傳 nil 代表無法顯示（直接丟棄）
    public mutating func next(
        now: TimeInterval,
        motion: MotionModel,
        gap: Double,
        laneStart: (Int) -> Double,
        width: (Item) -> Double?
    ) -> (placed: [Placement], expired: [Item]) {
        activeExits.removeAll { $0 <= now }

        var expired: [Item] = []
        queue.removeAll { entry in
            guard now - entry.enqueuedAt > limits.maxWait else { return false }
            expired.append(entry.item)
            return true
        }

        var placed: [Placement] = []
        while let head = queue.first, activeExits.count < limits.maxConcurrent {
            guard let itemWidth = width(head.item), itemWidth > 0 else {
                queue.removeFirst()
                expired.append(head.item)
                continue
            }
            let speed = motion.speed(itemWidth: itemWidth)
            guard let lane = lanes.acquire(now: now, itemWidth: itemWidth, speed: speed, gap: gap, travel: laneStart) else {
                break // 依先後順序：排第一的還沒輪到，後面的也不插隊
            }
            let startX = laneStart(lane)
            let duration = (startX + itemWidth) / speed
            activeExits.append(now + duration)
            placed.append(Placement(
                item: head.item,
                lane: lane,
                startX: startX,
                width: itemWidth,
                speed: speed,
                duration: duration,
                waited: now - head.enqueuedAt
            ))
            queue.removeFirst()
        }
        return (placed, expired)
    }

    /// 清空等待佇列（畫面上的不受影響），回傳被清掉的項目。
    public mutating func clearQueue() -> [Item] {
        defer { queue.removeAll() }
        return queue.map { $0.item }
    }

    /// 清空畫面與佇列。
    public mutating func reset() -> [Item] {
        activeExits.removeAll()
        lanes.reset()
        return clearQueue()
    }
}
