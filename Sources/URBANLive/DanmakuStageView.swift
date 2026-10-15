import AppKit
import DanmakuCore
import QuartzCore

/// 一則待顯示的彈幕。
final class DanmakuItem {
    let id: String
    let content: DanmakuContent
    /// 來自哪個 WebSocket 連線（用來回報「已顯示 / 未顯示」）；HTTP 備援或測試彈幕為 nil。
    let connectionID: Int?
    let receivedAt: TimeInterval

    fileprivate var rendered: RenderedDanmaku?
    fileprivate var renderKey: String?

    init(id: String, content: DanmakuContent, connectionID: Int?, receivedAt: TimeInterval = CACurrentMediaTime()) {
        self.id = id
        self.content = content
        self.connectionID = connectionID
        self.receivedAt = receivedAt
    }
}

/// 彈幕舞台：排程（同時上限、軌道、佇列）+ Core Animation 捲動。
final class DanmakuStageView: NSView {
    struct Configuration: Equatable {
        var style: DanmakuStyle
        /// 1080p 基準的字體像素
        var referenceFontSize: Double
        var crossingSeconds: Double
        var opacity: Double
        var area: DisplayArea
        var maxConcurrent: Int
        /// 大頭貼與暱稱大小
        var profileSize: ProfileSize
        /// 是否顯示暱稱或大頭貼（決定軌道高度）
        var profilesShown: Bool
    }

    /// 上場時呼叫（已排隊秒數）。
    var onShown: ((DanmakuItem, TimeInterval) -> Void)?
    /// 沒有顯示就被移除時呼叫（原因會告訴手機）。
    var onDropped: ((DanmakuItem, String) -> Void)?

    private let container = CALayer()
    private var scheduler = DanmakuScheduler<DanmakuItem>(limits: DanmakuStageView.limits(maxConcurrent: 5))
    private var pumpTimer: Timer?
    private(set) var configuration = Configuration(
        style: .glass, referenceFontSize: 48, crossingSeconds: 10, opacity: 1, area: .bottom, maxConcurrent: 5,
        profileSize: .large, profilesShown: true
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        root.addSublayer(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - 狀態

    var pendingCount: Int { scheduler.pendingCount }
    var isQueueFull: Bool { scheduler.isFull }
    var onScreenCount: Int { scheduler.activeCount(now: CACurrentMediaTime()) }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2 }
    private var topInset: CGFloat { window?.screen?.safeAreaInsets.top ?? 0 }

    /// 依螢幕高度換算後的實際字體點數。
    var effectiveFontSize: CGFloat {
        CGFloat(ReferenceScale.points(forReferencePixels: configuration.referenceFontSize, screenHeightPoints: Double(max(bounds.height, 300))))
    }

    private var metrics: DanmakuMetrics {
        DanmakuMetrics(style: configuration.style, fontSize: effectiveFontSize, profileSize: configuration.profileSize)
    }
    private var laneSpacing: CGFloat { round(effectiveFontSize * 0.22) }
    private var gap: CGFloat { round(effectiveFontSize * 1.1) }

    /// 佇列上限依同時顯示數計算：預設 5 則同時顯示 → 最多排 12 則、最多等 30 秒。
    /// 排太長的話，觀眾送出後要等很久才上螢幕；排不進去的會立刻收到「太多了，稍後再送」。
    static func limits(maxConcurrent: Int) -> DanmakuScheduler<DanmakuItem>.Limits {
        .init(maxConcurrent: maxConcurrent, maxPending: maxConcurrent * 2 + 2, maxWait: 30)
    }

    func apply(_ newConfiguration: Configuration) {
        configuration = newConfiguration
        scheduler.limits = Self.limits(maxConcurrent: newConfiguration.maxConcurrent)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = Float(newConfiguration.opacity)
        CATransaction.commit()
        relayoutLanes()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        container.frame = bounds
        CATransaction.commit()
        relayoutLanes()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = scale
    }

    private func laneGeometry() -> (count: Int, firstCenterFromTop: CGFloat, pitch: CGFloat) {
        let height = metrics.laneHeight(profilesShown: configuration.profilesShown)
        let region = configuration.area.region
        let count = region.laneCount(
            stageHeight: Double(bounds.height),
            topInset: Double(topInset),
            laneHeight: Double(height),
            laneSpacing: Double(laneSpacing)
        )
        let span = region.span(stageHeight: Double(bounds.height), topInset: Double(topInset))
        let used = CGFloat(count) * height + CGFloat(count - 1) * laneSpacing
        let offset = max(0, (CGFloat(span.bottom - span.top) - used) / 2)
        return (count, CGFloat(span.top) + offset + height / 2, height + laneSpacing)
    }

    private func relayoutLanes() {
        scheduler.setLaneCount(laneGeometry().count)
    }

    // MARK: - 彈幕

    /// 放入佇列；回傳排隊位置，佇列已滿回傳 nil。
    func enqueue(_ item: DanmakuItem) -> Int? {
        guard let position = scheduler.enqueue(item, now: CACurrentMediaTime()) else { return nil }
        pump()
        startPumpIfNeeded()
        return position
    }

    /// 清空畫面上與排隊中的彈幕。
    func clearScreen() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        for item in scheduler.reset() {
            onDropped?(item, "主持人清空了彈幕，這則沒有顯示")
        }
        stopPump()
    }

    /// 只清空等待佇列，畫面上的繼續跑完。
    func clearQueue() {
        for item in scheduler.clearQueue() {
            onDropped?(item, "主持人清空了等待中的彈幕，這則沒有顯示")
        }
        stopPump()
    }

    private func startPumpIfNeeded() {
        guard pumpTimer == nil, scheduler.pendingCount > 0 else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
    }

    private func stopPump() {
        pumpTimer?.invalidate()
        pumpTimer = nil
    }

    private func pump() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let now = CACurrentMediaTime()
        let geometry = laneGeometry()
        let currentMetrics = metrics
        let motion = MotionModel(baseDuration: configuration.crossingSeconds, stageWidth: Double(bounds.width))
        let stageWidth = Double(bounds.width)
        let result = scheduler.next(
            now: now,
            motion: motion,
            gap: Double(gap),
            laneStart: { _ in stageWidth },
            width: { [weak self] item in
                guard let self, let rendered = self.rendered(item, metrics: currentMetrics) else { return nil }
                return Double(rendered.bodyWidth)
            }
        )
        for item in result.expired {
            onDropped?(item, "排隊太久，這則沒有顯示")
        }
        for placement in result.placed {
            guard let rendered = placement.item.rendered else { continue }
            let centerY = bounds.height - (geometry.firstCenterFromTop + CGFloat(placement.lane) * geometry.pitch)
            animate(rendered, startX: CGFloat(placement.startX), centerY: centerY, duration: placement.duration)
            onShown?(placement.item, placement.waited)
        }
        if scheduler.pendingCount == 0 {
            stopPump()
        }
    }

    private func rendered(_ item: DanmakuItem, metrics: DanmakuMetrics) -> RenderedDanmaku? {
        let key = "\(configuration.style.rawValue)-\(configuration.profileSize.rawValue)-\(Int(metrics.fontSize * 10))-\(Int(scale * 10))-\(Int(bounds.width))"
        if item.renderKey == key, let cached = item.rendered { return cached }
        let rendered = DanmakuRenderer.render(
            item.content,
            style: configuration.style,
            fontSize: metrics.fontSize,
            profileSize: configuration.profileSize,
            scale: scale,
            maxBodyWidth: bounds.width * 0.92
        )
        item.rendered = rendered
        item.renderKey = key
        return rendered
    }

    private func animate(_ rendered: RenderedDanmaku, startX: CGFloat, centerY: CGFloat, duration: Double) {
        let layer = CALayer()
        layer.contents = rendered.image
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.bounds = CGRect(origin: .zero, size: rendered.size)
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        // 本體從起點進場，移動到完全離開左緣
        let from = startX - rendered.margin
        let to = -(rendered.bodyWidth + rendered.margin)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: to, y: centerY)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.setCompletionBlock { [weak layer] in
            layer?.removeFromSuperlayer()
        }
        container.addSublayer(layer)
        layer.add(animation, forKey: "scroll")
        CATransaction.commit()
    }
}
