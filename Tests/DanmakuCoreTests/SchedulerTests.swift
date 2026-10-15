import XCTest
@testable import DanmakuCore

final class SchedulerTests: XCTestCase {
    let motion = MotionModel(baseDuration: 10, stageWidth: 1920)

    func testMotionModel() {
        XCTAssertEqual(motion.duration(itemWidth: 0), 10)
        XCTAssertEqual(motion.duration(itemWidth: 1920), 12.5)
        XCTAssertEqual(motion.duration(itemWidth: 5000), 12.5, "最多延長 25%")
        // 長彈幕速度較快，但停留時間較長
        XCTAssertGreaterThan(motion.speed(itemWidth: 1200), motion.speed(itemWidth: 300))
    }

    func testRespectsMaxConcurrentAndFIFO() {
        var scheduler = DanmakuScheduler<Int>(limits: .init(maxConcurrent: 5, maxPending: 30, maxWait: 60), laneCount: 10)
        for value in 1...8 {
            XCTAssertEqual(scheduler.enqueue(value, now: 0), value)
        }
        let first = scheduler.next(now: 0, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 })
        XCTAssertEqual(first.placed.map(\.item), [1, 2, 3, 4, 5], "同時最多 5 則")
        XCTAssertEqual(first.placed.map(\.lane), [0, 1, 2, 3, 4])
        XCTAssertEqual(scheduler.activeCount(now: 0), 5)
        XCTAssertEqual(scheduler.pendingCount, 3)

        // 還沒有任何一則離開畫面
        XCTAssertTrue(scheduler.next(now: 5, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 }).placed.isEmpty)

        // 全部離場後，剩下的依序上場
        let later = scheduler.next(now: 20, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 })
        XCTAssertEqual(later.placed.map(\.item), [6, 7, 8])
        XCTAssertEqual(later.placed.first?.waited, 20)
    }

    func testLaneReuseWithoutOverlap() {
        var scheduler = DanmakuScheduler<Int>(limits: .init(maxConcurrent: 10), laneCount: 1)
        _ = scheduler.enqueue(1, now: 0)
        _ = scheduler.enqueue(2, now: 0)
        let first = scheduler.next(now: 0, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 400 })
        XCTAssertEqual(first.placed.count, 1, "只有一條軌道，第二則要等")
        let placement = first.placed[0]
        // 第一則尾巴 (400 + 50) / speed 秒後完全進場
        let clear = (400 + 50) / placement.speed
        XCTAssertTrue(scheduler.next(now: clear - 0.01, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 400 }).placed.isEmpty)
        XCTAssertEqual(scheduler.next(now: clear + 0.01, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 400 }).placed.map(\.item), [2])
    }

    func testQueueLimitExpiryAndClear() {
        var scheduler = DanmakuScheduler<Int>(limits: .init(maxConcurrent: 1, maxPending: 3, maxWait: 30), laneCount: 1)
        XCTAssertNotNil(scheduler.enqueue(1, now: 0))
        XCTAssertNotNil(scheduler.enqueue(2, now: 0))
        XCTAssertNotNil(scheduler.enqueue(3, now: 0))
        XCTAssertTrue(scheduler.isFull)
        XCTAssertNil(scheduler.enqueue(4, now: 0), "佇列滿了直接拒絕")

        _ = scheduler.next(now: 0, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 })
        let expired = scheduler.next(now: 31, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 })
        XCTAssertEqual(expired.expired, [2, 3], "排隊超過 30 秒丟棄")

        _ = scheduler.enqueue(5, now: 40)
        _ = scheduler.enqueue(6, now: 40)
        XCTAssertEqual(scheduler.clearQueue(), [5, 6])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testUnrenderableItemsAreDropped() {
        var scheduler = DanmakuScheduler<Int>(limits: .init(), laneCount: 2)
        _ = scheduler.enqueue(1, now: 0)
        _ = scheduler.enqueue(2, now: 0)
        let result = scheduler.next(now: 0, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { $0 == 1 ? nil : 300 })
        XCTAssertEqual(result.expired, [1])
        XCTAssertEqual(result.placed.map(\.item), [2])
    }

    func testShorterLaneBehindQRCard() {
        var scheduler = DanmakuScheduler<Int>(limits: .init(), laneCount: 2)
        _ = scheduler.enqueue(1, now: 0)
        let result = scheduler.next(now: 0, motion: motion, gap: 50, laneStart: { $0 == 0 ? 1600 : 1920 }, width: { _ in 300 })
        XCTAssertEqual(result.placed.first?.startX, 1600)
        XCTAssertEqual(result.placed.first?.duration ?? 0, (1600 + 300) / motion.speed(itemWidth: 300), accuracy: 0.0001)
    }

    func testResetClearsEverything() {
        var scheduler = DanmakuScheduler<Int>(limits: .init(maxConcurrent: 1), laneCount: 1)
        _ = scheduler.enqueue(1, now: 0)
        _ = scheduler.enqueue(2, now: 0)
        _ = scheduler.next(now: 0, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 })
        XCTAssertEqual(scheduler.reset(), [2])
        XCTAssertEqual(scheduler.activeCount(now: 0), 0)
        _ = scheduler.enqueue(3, now: 1)
        XCTAssertEqual(scheduler.next(now: 1, motion: motion, gap: 50, laneStart: { _ in 1920 }, width: { _ in 300 }).placed.map(\.item), [3])
    }

    func testDisplayAreasAndReferenceScale() {
        XCTAssertEqual(DisplayArea.bottom.region.top, 0.68, accuracy: 0.0001)
        XCTAssertEqual(DisplayArea.top.region.bottom, 0.32, accuracy: 0.0001)
        // 1080p 底部 30%：可放 3 條 48px 彈幕
        let lanes = DisplayArea.bottom.region.laneCount(stageHeight: 1080, laneHeight: 84, laneSpacing: 14)
        XCTAssertEqual(lanes, 3)
        XCTAssertEqual(ReferenceScale.points(forReferencePixels: 48, screenHeightPoints: 1080), 48)
        XCTAssertEqual(ReferenceScale.points(forReferencePixels: 48, screenHeightPoints: 900), 40)
    }
}
