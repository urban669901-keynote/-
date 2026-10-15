import CoreGraphics
import XCTest
@testable import DanmakuCore

final class LaneAllocatorTests: XCTestCase {
    let width = 1920.0
    let speed = 200.0
    let gap = 40.0

    func testFillsFromTopAndAvoidsOverlap() {
        var allocator = LaneAllocator(laneCount: 3)
        XCTAssertEqual(allocator.acquire(now: 0, itemWidth: 400, speed: speed, stageWidth: width, gap: gap), 0)
        XCTAssertEqual(allocator.acquire(now: 0.1, itemWidth: 400, speed: speed, stageWidth: width, gap: gap), 1)
        XCTAssertEqual(allocator.acquire(now: 0.2, itemWidth: 400, speed: speed, stageWidth: width, gap: gap), 2)
        XCTAssertNil(allocator.acquire(now: 0.3, itemWidth: 400, speed: speed, stageWidth: width, gap: gap))

        // 第一則尾巴 (400 + 40) / 200 = 2.2 秒後完全進入畫面
        XCTAssertEqual(allocator.nextAvailableTime(speed: speed, stageWidth: width, gap: gap), 2.2, accuracy: 0.0001)
        XCTAssertNil(allocator.acquire(now: 2.1, itemWidth: 100, speed: speed, stageWidth: width, gap: gap))
        XCTAssertEqual(allocator.acquire(now: 2.2 + 1e-9, itemWidth: 100, speed: speed, stageWidth: width, gap: gap), 0)
    }

    func testFasterItemDoesNotCatchUp() {
        var allocator = LaneAllocator(laneCount: 1)
        XCTAssertEqual(allocator.acquire(now: 0, itemWidth: 200, speed: 100, stageWidth: 1000, gap: 20), 0)
        // 前一則尾巴 2.2 秒進場、12 秒離場。速度 1000 的新彈幕 1 秒就跑完全程，
        // 必須等到 12 - (1000 - 20) / 1000 = 11.02 秒後才能出發。
        XCTAssertNil(allocator.acquire(now: 5, itemWidth: 200, speed: 1000, stageWidth: 1000, gap: 20))
        XCTAssertEqual(allocator.nextAvailableTime(speed: 1000, stageWidth: 1000, gap: 20), 11.02, accuracy: 0.0001)
        XCTAssertEqual(allocator.acquire(now: 11.02 + 1e-9, itemWidth: 200, speed: 1000, stageWidth: 1000, gap: 20), 0)
    }

    func testResizeKeepsState() {
        var allocator = LaneAllocator(laneCount: 2)
        _ = allocator.acquire(now: 0, itemWidth: 400, speed: speed, stageWidth: width, gap: gap)
        allocator.resize(laneCount: 4)
        XCTAssertEqual(allocator.laneCount, 4)
        XCTAssertEqual(allocator.acquire(now: 0, itemWidth: 400, speed: speed, stageWidth: width, gap: gap), 1)
        allocator.resize(laneCount: 0)
        XCTAssertEqual(allocator.laneCount, 1)
        allocator.reset()
        XCTAssertEqual(allocator.acquire(now: 0, itemWidth: 400, speed: speed, stageWidth: width, gap: gap), 0)
    }
}

final class DisplayRegionTests: XCTestCase {
    func testClampsAndKeepsMinimumSpan() {
        let region = DisplayRegion(top: 0.95, bottom: 0.2)
        XCTAssertEqual(region.top, 0.9, accuracy: 0.0001)
        XCTAssertEqual(region.bottom, 1.0, accuracy: 0.0001)
    }

    func testSpanAndLaneCount() {
        let region = DisplayRegion(top: 0, bottom: 0.5)
        let span = region.span(stageHeight: 1080, topInset: 0)
        XCTAssertEqual(span.top, 0)
        XCTAssertEqual(span.bottom, 540)
        // 每條 72 + 間距 12：(540 + 12) / 84 = 6.57 → 6 條
        XCTAssertEqual(region.laneCount(stageHeight: 1080, laneHeight: 72, laneSpacing: 12), 6)
        // 太小也至少 1 條
        XCTAssertEqual(DisplayRegion(top: 0, bottom: 0.1).laneCount(stageHeight: 300, laneHeight: 200, laneSpacing: 10), 1)
    }

    func testTopInsetForNotch() {
        let span = DisplayRegion(top: 0, bottom: 1).span(stageHeight: 1000, topInset: 40)
        XCTAssertEqual(span.top, 40)
        XCTAssertEqual(span.bottom, 1000)
    }
}

final class WindowLevelPolicyTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let base = 1000
    let maximum = 2_147_483_629

    func window(_ owner: String, pid: Int32 = 42, layer: Int, bounds: CGRect? = nil, regular: Bool = true) -> ObservedWindow {
        ObservedWindow(ownerName: owner, ownerPID: pid, layer: layer, bounds: bounds ?? screen, isRegularApp: regular)
    }

    func decide(_ mode: WindowLevelMode, _ windows: [ObservedWindow]) -> WindowLevelPolicy.Decision {
        WindowLevelPolicy.decide(mode: mode, windows: windows, screen: screen, ownPID: 1, baseLevel: base, maximumLevel: maximum)
    }

    func testAutoStaysAtBaseForNormalFullScreenSpace() {
        // 原生全螢幕（例如瀏覽器播放 YouTube）層級是 0，Overlay 不需要墊高。
        XCTAssertEqual(decide(.auto, [window("Safari", layer: 0)]).level, base)
    }

    func testAutoRaisesAboveCoveringPresentationWindow() {
        let keynote = window("Keynote", layer: 1500)
        let decision = decide(.auto, [keynote, window("Dock", layer: 20, regular: false)])
        XCTAssertEqual(decision.level, 1501)
        XCTAssertEqual(decision.raisedAbove, keynote)
    }

    func testAutoIgnoresSystemOwnSmallAndInvisibleWindows() {
        let windows = [
            window("loginwindow", layer: 2_000_000_000, regular: false),
            window("URBANDanmaku", pid: 1, layer: 5000),
            window("Keynote", layer: 3000, bounds: CGRect(x: 0, y: 0, width: 400, height: 300)),
            ObservedWindow(ownerName: "Ghost", ownerPID: 9, layer: 4000, bounds: screen, isRegularApp: true, alpha: 0),
        ]
        XCTAssertEqual(decide(.auto, windows).level, base)
    }

    func testAutoIsCappedAtMaximum() {
        XCTAssertEqual(decide(.auto, [window("Capture", layer: maximum + 10)]).level, maximum)
    }

    func testFixedModes() {
        let keynote = window("Keynote", layer: 1500)
        XCTAssertEqual(decide(.screenSaver, [keynote]).level, base)
        XCTAssertEqual(decide(.maximum, []).level, maximum)
    }
}
