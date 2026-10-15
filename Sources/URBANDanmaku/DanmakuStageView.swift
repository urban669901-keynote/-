import AppKit
import DanmakuCore
import QuartzCore

/// 彈幕舞台：負責軌道分配、等待佇列與 Core Animation 捲動。
final class DanmakuStageView: NSView {
    struct Configuration: Equatable {
        var fontSize: CGFloat
        var crossingSeconds: Double
        var opacity: Double
        var region: DisplayRegion
    }

    /// 等待佇列上限：超過就丟掉最舊的，避免活動高峰時越積越多。
    static let maxPending = 60
    /// 等太久的彈幕（秒）直接丟棄，避免結束很久才冒出來。
    static let maxPendingAge: TimeInterval = 20

    private let container = CALayer()
    private var allocator = LaneAllocator(laneCount: 1)
    private var pending: [(text: String, enqueuedAt: TimeInterval)] = []
    private var drainTimer: Timer?

    private var style = CapsuleStyle(fontSize: 48)
    private var lineHeight: CGFloat = 60
    private var configuration = Configuration(fontSize: 48, crossingSeconds: 9, opacity: 1, region: .default)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // layer-hosting view：由我們完全控制 layer 樹。
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        container.frame = root.bounds
        container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(container)
        recalculateStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    /// 完全不接收滑鼠事件（視窗本身也已設定 ignoresMouseEvents）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var activeCount: Int { container.sublayers?.count ?? 0 }
    var pendingCount: Int { pending.count }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2 }
    private var laneSpacing: CGFloat { round(configuration.fontSize * 0.28) }
    private var gap: CGFloat { round(configuration.fontSize * 1.2) }
    private var speed: Double { Double(bounds.width) / max(1, configuration.crossingSeconds) }
    /// 瀏海等不可用區域。
    private var topInset: CGFloat { window?.screen?.safeAreaInsets.top ?? 0 }

    func apply(_ newConfiguration: Configuration) {
        let previous = configuration
        configuration = newConfiguration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = Float(newConfiguration.opacity)
        CATransaction.commit()
        if previous.fontSize != newConfiguration.fontSize {
            recalculateStyle()
        }
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

    private func recalculateStyle() {
        style = CapsuleStyle(fontSize: configuration.fontSize)
        lineHeight = style.lineHeight
    }

    private var laneHeight: CGFloat { lineHeight + style.verticalPadding * 2 }

    private func relayoutLanes() {
        let count = configuration.region.laneCount(
            stageHeight: Double(bounds.height),
            topInset: Double(topInset),
            laneHeight: Double(laneHeight),
            laneSpacing: Double(laneSpacing)
        )
        allocator.resize(laneCount: count)
    }

    /// 軌道中心的 y 座標（左下角為原點）。
    private func laneCenterY(_ lane: Int) -> CGFloat {
        let span = configuration.region.span(stageHeight: Double(bounds.height), topInset: Double(topInset))
        let fromTop = CGFloat(span.top) + laneSpacing / 2 + CGFloat(lane) * (laneHeight + laneSpacing) + laneHeight / 2
        return bounds.height - fromTop
    }

    // MARK: - 彈幕

    /// 放入一則彈幕；軌道都滿時先排隊。回傳 false 代表佇列已滿被丟棄（理論上不會，最舊的會先被丟）。
    @discardableResult
    func enqueue(_ text: String) -> Bool {
        let now = CACurrentMediaTime()
        if pending.isEmpty, spawn(text, now: now) {
            return true
        }
        pending.append((text: text, enqueuedAt: now))
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
        scheduleDrain()
        return true
    }

    func clear() {
        pending.removeAll()
        drainTimer?.invalidate()
        drainTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        allocator.reset()
    }

    private func spawn(_ text: String, now: TimeInterval) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        guard let rendered = CapsuleRenderer.render(text: text, style: style, lineHeight: lineHeight, scale: scale) else {
            return true // 畫不出來就略過，不要卡住佇列。
        }
        guard let lane = allocator.acquire(
            now: now,
            itemWidth: Double(rendered.capsuleWidth),
            speed: speed,
            stageWidth: Double(bounds.width),
            gap: Double(gap)
        ) else { return false }

        let margin = style.shadowMargin
        let item = CALayer()
        item.contents = rendered.image
        item.contentsScale = scale
        item.contentsGravity = .resize
        item.bounds = CGRect(origin: .zero, size: rendered.size)
        item.anchorPoint = CGPoint(x: 0, y: 0.5)

        // 膠囊本體從右緣外開始，移動到完全離開左緣。
        let startX = bounds.width - margin
        let endX = -rendered.size.width
        let y = laneCenterY(lane)
        let duration = Double(startX - endX) / speed

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        item.position = CGPoint(x: endX, y: y)
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = startX
        animation.toValue = endX
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.setCompletionBlock { [weak item] in
            item?.removeFromSuperlayer()
        }
        container.addSublayer(item)
        item.add(animation, forKey: "scroll")
        CATransaction.commit()
        return true
    }

    private func scheduleDrain() {
        guard drainTimer == nil else { return }
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.drain()
        }
    }

    private func drain() {
        let now = CACurrentMediaTime()
        pending.removeAll { now - $0.enqueuedAt > Self.maxPendingAge }
        while let next = pending.first {
            guard spawn(next.text, now: now) else { break }
            pending.removeFirst()
        }
        if pending.isEmpty {
            drainTimer?.invalidate()
            drainTimer = nil
        }
    }
}
