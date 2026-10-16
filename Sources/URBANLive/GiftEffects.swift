import AppKit
import DanmakuCore
import QuartzCore

/// 免費送禮特效：🎉 拉炮（兩側彩帶）、🎆 煙火（空中綻放）、🚀 火箭（從下方噴射衝上天）。
/// 整個畫面大小的透明圖層。火箭一次一支；拉炮與煙火最多同時 4 個；其餘排隊，總數上限 30。
final class GiftEffectsView: NSView {
    static let capacity = 30
    private static let smallSlots = 4

    private struct Pending {
        let kind: GiftKind
        let banner: String
    }

    private var queue: [Pending] = []
    private var playingRocket = false
    private var playingSmall = 0
    /// 清空時加一，讓清空前排定的收尾動作失效
    private var generation = 0
    private var bannerSlots = [Bool](repeating: false, count: 3)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2 }
    private var unit: CGFloat { max(bounds.height / 1080, 0.4) }

    /// 正在播放與排隊中的特效數量。
    var load: Int { queue.count + (playingRocket ? 1 : 0) + playingSmall }
    var canAccept: Bool { load < Self.capacity }

    func enqueue(_ kind: GiftKind, banner: String) {
        guard canAccept else { return }
        queue.append(Pending(kind: kind, banner: banner))
        pump()
    }

    /// 清空（⌃⌥⌘C 或結束場次）：停止所有特效、清掉排隊。
    func clear() {
        generation += 1
        queue.removeAll()
        playingRocket = false
        playingSmall = 0
        bannerSlots = bannerSlots.map { _ in false }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func pump() {
        var index = 0
        while index < queue.count {
            let item = queue[index]
            let isRocket = item.kind == .rocket
            if isRocket ? playingRocket : playingSmall >= Self.smallSlots {
                index += 1
                continue
            }
            queue.remove(at: index)
            if isRocket { playingRocket = true } else { playingSmall += 1 }
            let duration = play(item)
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.generation == current else { return }
                if isRocket { self.playingRocket = false } else { self.playingSmall = max(0, self.playingSmall - 1) }
                self.pump()
            }
        }
    }

    /// 播放一個特效，回傳佔用的秒數（之後可以播下一個）。
    private func play(_ item: Pending) -> TimeInterval {
        showBanner(item.banner, kind: item.kind)
        switch item.kind {
        case .rocket: return launchRocket()
        case .fireworks: return fireworks()
        case .popper: return popper()
        }
    }

    // MARK: - 🚀 火箭

    private func launchRocket() -> TimeInterval {
        guard let root = layer else { return 0 }
        let u = unit
        let size = 230 * u
        let flight: CFTimeInterval = 3.0
        let startX = bounds.width * CGFloat.random(in: 0.3...0.7)
        let start = CGPoint(x: startX, y: -size)
        let end = CGPoint(x: startX + CGFloat.random(in: -60...60) * u, y: bounds.height + size * 1.4)

        // 噴射尾焰與煙霧：發射點跟著火箭尾巴移動，已經噴出的粒子留在原地，形成一道尾跡
        let tailOffset = CGPoint(x: 0, y: -size * 0.42)
        let smoke = makeEmitter(cells: [Self.smokeCell(u)], additive: false)
        let flame = makeEmitter(cells: [Self.flameCell(u), Self.sparkCell(u, color: NSColor(hex: 0xFFD978))], additive: true)
        for emitter in [smoke, flame] {
            root.addSublayer(emitter)
            emitter.emitterPosition = end + tailOffset
            let move = CABasicAnimation(keyPath: "emitterPosition")
            move.fromValue = NSValue(point: start + tailOffset)
            move.toValue = NSValue(point: end + tailOffset)
            move.duration = flight
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            emitter.add(move, forKey: "follow")
        }

        // 火箭本體：🚀 Emoji 原本指向右上，轉 45° 變成直直往上
        let rocket = CALayer()
        rocket.contents = Self.emojiImage("🚀", side: size, scale: scale)
        rocket.contentsScale = scale
        rocket.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        rocket.position = end
        rocket.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
        root.addSublayer(rocket)
        let fly = CABasicAnimation(keyPath: "position")
        fly.fromValue = NSValue(point: start)
        fly.toValue = NSValue(point: end)
        fly.duration = flight
        fly.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        shake.values = [CGFloat.pi / 4 - 0.04, CGFloat.pi / 4 + 0.04, CGFloat.pi / 4 - 0.04]
        shake.duration = 0.18
        shake.repeatCount = .infinity
        rocket.add(fly, forKey: "fly")
        rocket.add(shake, forKey: "shake")

        let current = generation
        // 衝到上方時炸開一團金色火花
        DispatchQueue.main.asyncAfter(deadline: .now() + flight * 0.8) { [weak self] in
            guard let self, self.generation == current else { return }
            self.burst(at: CGPoint(x: (startX + end.x) / 2, y: self.bounds.height * 0.82),
                       colors: [NSColor(hex: 0xF3C969), .white, NSColor(hex: 0xFFB020)], strength: 1.3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + flight) { [weak self] in
            guard let self, self.generation == current else { return }
            smoke.birthRate = 0
            flame.birthRate = 0
            rocket.removeFromSuperlayer()
        }
        removeLater([smoke, flame], after: flight + 3)
        return flight + 0.6
    }

    // MARK: - 🎆 煙火

    private func fireworks() -> TimeInterval {
        let palettes: [[NSColor]] = [
            [NSColor(hex: 0xF3C969), .white],
            [NSColor(hex: 0x2563EB), NSColor(hex: 0x7DD3FC)],
            [NSColor(hex: 0xF472B6), NSColor(hex: 0xFDE68A)],
            [NSColor(hex: 0x34D399), .white],
        ]
        let current = generation
        for index in 0..<3 {
            let delay = Double(index) * 0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == current else { return }
                let point = CGPoint(x: self.bounds.width * CGFloat.random(in: 0.15...0.85),
                                    y: self.bounds.height * CGFloat.random(in: 0.5...0.85))
                self.burst(at: point, colors: palettes.randomElement()!, strength: 1)
            }
        }
        return 2.4
    }

    /// 一團向四面八方散開、受重力下墜的火花。
    private func burst(at point: CGPoint, colors: [NSColor], strength: CGFloat) {
        guard let root = layer else { return }
        let u = unit
        let cells = colors.map { color -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = Self.dotImage(scale: scale)
            cell.contentsScale = scale
            cell.birthRate = Float(420 * strength)
            cell.lifetime = 1.6
            cell.lifetimeRange = 0.4
            cell.velocity = 380 * u * strength
            cell.velocityRange = 120 * u
            cell.emissionRange = .pi * 2
            cell.yAcceleration = -260 * u
            cell.scale = 0.42 * u
            cell.scaleRange = 0.15 * u
            cell.scaleSpeed = -0.12 * u
            cell.alphaSpeed = -0.55
            cell.color = color.cgColor
            return cell
        }
        let emitter = makeEmitter(cells: cells, additive: true)
        emitter.emitterPosition = point
        root.addSublayer(emitter)
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.generation == current else { return }
            emitter.birthRate = 0
        }
        removeLater([emitter], after: 2.4)
    }

    // MARK: - 🎉 拉炮

    private func popper() -> TimeInterval {
        guard let root = layer else { return 0 }
        let u = unit
        let colors = [NSColor(hex: 0xF3C969), NSColor(hex: 0x2563EB), NSColor(hex: 0xF472B6), NSColor(hex: 0x34D399), NSColor(hex: 0xFB923C), .white]
        var emitters: [CAEmitterLayer] = []
        for (x, angle) in [(bounds.width * 0.04, CGFloat.pi / 3), (bounds.width * 0.96, CGFloat.pi * 2 / 3)] {
            let cells = colors.map { color -> CAEmitterCell in
                let cell = CAEmitterCell()
                cell.contents = Self.confettiImage(scale: scale)
                cell.contentsScale = scale
                cell.birthRate = 70
                cell.lifetime = 2.6
                cell.velocity = 1050 * u
                cell.velocityRange = 280 * u
                cell.emissionLongitude = angle
                cell.emissionRange = .pi / 9
                cell.yAcceleration = -900 * u
                cell.spin = 4
                cell.spinRange = 8
                cell.scale = 0.6 * u
                cell.scaleRange = 0.2 * u
                cell.alphaSpeed = -0.3
                cell.color = color.cgColor
                return cell
            }
            let emitter = makeEmitter(cells: cells, additive: false)
            emitter.emitterPosition = CGPoint(x: x, y: -10 * u)
            root.addSublayer(emitter)
            emitters.append(emitter)
        }
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == current else { return }
            emitters.forEach { $0.birthRate = 0 }
        }
        removeLater(emitters, after: 3.2)
        return 1.6
    }

    // MARK: - 字幕（誰送的）

    private func showBanner(_ text: String, kind: GiftKind) {
        guard let root = layer else { return }
        let slot = bannerSlots.firstIndex(of: false) ?? 0
        bannerSlots[slot] = true
        let u = unit
        let font = NSFont.systemFont(ofSize: (kind == .rocket ? 40 : 32) * u, weight: .heavy)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Brand.deepSea])
        let textSize = string.size()
        let height = textSize.height + 26 * u
        let size = CGSize(width: min(textSize.width + 64 * u, bounds.width * 0.9), height: height)
        let image = Self.render(size: size, scale: scale) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSGradient(starting: NSColor(hex: 0xFFE7A3), ending: NSColor(hex: 0xF3C969))?.draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 2
            path.stroke()
            string.draw(with: NSRect(x: rect.minX + 32 * u, y: rect.midY - textSize.height / 2 + 2 * u,
                                     width: rect.width - 64 * u, height: textSize.height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let banner = CALayer()
        banner.contents = image
        banner.contentsScale = scale
        banner.bounds = CGRect(origin: .zero, size: size)
        banner.position = CGPoint(x: bounds.midX, y: bounds.height * 0.86 - CGFloat(slot) * (height + 14 * u))
        banner.shadowColor = NSColor.black.cgColor
        banner.shadowOpacity = 0.35
        banner.shadowRadius = 10 * u
        banner.shadowOffset = CGSize(width: 0, height: -4 * u)
        banner.opacity = 0
        root.addSublayer(banner)

        let duration: CFTimeInterval = kind == .rocket ? 3.8 : 2.8
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.85, 1]
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.08, 1, 1]
        pop.keyTimes = [0, 0.08, 0.14, 1]
        let group = CAAnimationGroup()
        group.animations = [fade, pop]
        group.duration = duration
        banner.add(group, forKey: "banner")

        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            banner.removeFromSuperlayer()
            guard let self, self.generation == current else { return }
            self.bannerSlots[slot] = false
        }
    }

    // MARK: - 共用

    private func makeEmitter(cells: [CAEmitterCell], additive: Bool) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.renderMode = additive ? .additive : .unordered
        emitter.emitterCells = cells
        // 從現在開始發射（不要先模擬一段時間）
        emitter.beginTime = CACurrentMediaTime()
        return emitter
    }

    private func removeLater(_ layers: [CALayer], after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            layers.forEach { $0.removeFromSuperlayer() }
        }
    }

    private static func flameCell(_ u: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = softDotImage(scale: 2)
        cell.contentsScale = 2
        cell.birthRate = 260
        cell.lifetime = 0.55
        cell.lifetimeRange = 0.15
        cell.velocity = 240 * u
        cell.velocityRange = 80 * u
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 9
        cell.scale = 1.1 * u
        cell.scaleSpeed = -1.2 * u
        cell.alphaSpeed = -1.6
        cell.color = NSColor(hex: 0xFF8A1E).cgColor
        cell.greenRange = 0.25
        return cell
    }

    private static func smokeCell(_ u: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = softDotImage(scale: 2)
        cell.contentsScale = 2
        cell.birthRate = 70
        cell.lifetime = 2.2
        cell.lifetimeRange = 0.5
        cell.velocity = 110 * u
        cell.velocityRange = 60 * u
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 4
        cell.scale = 1.4 * u
        cell.scaleSpeed = 1.1 * u
        cell.alphaSpeed = -0.4
        cell.color = NSColor(white: 0.85, alpha: 0.55).cgColor
        return cell
    }

    private static func sparkCell(_ u: CGFloat, color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = dotImage(scale: 2)
        cell.contentsScale = 2
        cell.birthRate = 90
        cell.lifetime = 0.9
        cell.velocity = 320 * u
        cell.velocityRange = 120 * u
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 3
        cell.yAcceleration = -300 * u
        cell.scale = 0.3 * u
        cell.alphaSpeed = -1
        cell.color = color.cgColor
        return cell
    }

    // MARK: - 圖片

    private static var images: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let image = images[key] { return image }
        guard let image = make() else { return nil }
        images[key] = image
        return image
    }

    private static func render(size: CGSize, scale: CGFloat, draw: (CGRect) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func emojiImage(_ emoji: String, side: CGFloat, scale: CGFloat) -> CGImage? {
        cached("emoji|\(emoji)|\(Int(side))|\(scale)") {
            render(size: CGSize(width: side, height: side), scale: scale) { rect in
                let string = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: side * 0.78)])
                let size = string.size()
                string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
        }
    }

    /// 白色實心圓點（以 color 上色）。
    private static func dotImage(scale: CGFloat) -> CGImage? {
        cached("dot|\(scale)") {
            render(size: CGSize(width: 24, height: 24), scale: scale) { rect in
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            }
        }
    }

    /// 邊緣柔和的圓點（火焰、煙霧）。
    private static func softDotImage(scale: CGFloat) -> CGImage? {
        cached("soft|\(scale)") {
            render(size: CGSize(width: 48, height: 48), scale: scale) { rect in
                NSGradient(colors: [NSColor.white, NSColor.white.withAlphaComponent(0)])?
                    .draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            }
        }
    }

    /// 彩帶紙片。
    private static func confettiImage(scale: CGFloat) -> CGImage? {
        cached("confetti|\(scale)") {
            render(size: CGSize(width: 22, height: 12), scale: scale) { rect in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}
