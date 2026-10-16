import AppKit
import DanmakuCore
import QuartzCore

/// 用 AppKit 畫一張點陣圖（文字、Emoji 都可以用 NSAttributedString 直接畫）。
private func renderImage(size: CGSize, scale: CGFloat, draw: (CGRect) -> Void) -> CGImage? {
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

private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

// MARK: - 講師超棒票數（大螢幕角落）

/// 「👏 講師超棒」票數膠囊，放在 QR Code 旁邊；每有一票就跳一下，並飄出一個 👏。
/// 整個彈幕畫面大小的透明圖層，所以飄出來的 👏 不會被切掉。
final class VoteBadgeView: NSView {
    private let pill = CALayer()
    private var speaker: String?
    private var votes = 0
    private var pillSize = CGSize.zero
    private var unit: CGFloat = 1
    private var floatsUp = true
    private var claps = 0
    /// 一次很多人投票時，👏 排隊一個一個飄出來
    private var pendingClaps = 0
    private var clapTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        layer = root
        wantsLayer = true
        pill.isHidden = true
        root.addSublayer(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2 }

    var isShowing: Bool { speaker != nil }

    func update(speaker: String?, votes: Int) {
        let changed = speaker != self.speaker || votes != self.votes
        self.speaker = speaker
        self.votes = votes
        if changed { redraw() }
    }

    /// 依 QR Code 的位置擺放：QR 在下方時放在 QR 上面，在上方時放在 QR 下面；沒有 QR 時放在角落。
    func place(corner: QRPosition, qrFrame: CGRect?, margin: CGFloat, topInset: CGFloat, unit: CGFloat) {
        if unit != self.unit {
            self.unit = unit
            redraw()
        }
        let gap = 12 * unit
        let right = corner == .bottomRight || corner == .topRight
        let bottom = corner == .bottomRight || corner == .bottomLeft
        floatsUp = bottom
        let x = right ? (qrFrame?.maxX ?? bounds.maxX - margin) - pillSize.width : (qrFrame?.minX ?? bounds.minX + margin)
        let y: CGFloat
        if bottom {
            y = qrFrame.map { $0.maxY + gap } ?? bounds.minY + margin
        } else {
            y = qrFrame.map { $0.minY - gap - pillSize.height } ?? bounds.maxY - margin - topInset - pillSize.height
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: x, y: y, width: pillSize.width, height: pillSize.height)
        CATransaction.commit()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let speaker else {
            pill.isHidden = true
            return
        }
        let u = unit
        let name = text(speaker, size: 21 * u, weight: .bold, color: NSColor(hex: 0xF3C969))
        let tag = text("・講師超棒", size: 21 * u, weight: .semibold, color: NSColor(white: 1, alpha: 0.85))
        let count = text("\(votes)", size: 36 * u, weight: .heavy, color: .white)
        let unitText = text(" 票", size: 21 * u, weight: .bold, color: NSColor(white: 1, alpha: 0.9))
        let height = 84 * u
        let margin = 10 * u
        let icon = height - 16 * u
        let line1 = name.size().width + tag.size().width
        let line2 = count.size().width + unitText.size().width
        let width = min(margin * 2 + 8 * u + icon + 14 * u + max(line1, line2) + 26 * u, 640 * u)
        let size = CGSize(width: width, height: height + margin * 2)

        let image = renderImage(size: size, scale: scale) { rect in
            let capsule = rect.insetBy(dx: margin, dy: margin)
            let path = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowBlurRadius = 8 * u
            shadow.shadowOffset = NSSize(width: 0, height: -3 * u)
            shadow.set()
            Brand.deepSea.withAlphaComponent(0.94).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: Brand.royalBlue.withAlphaComponent(0.95), ending: Brand.deepSea.withAlphaComponent(0.95))?
                .draw(in: path, angle: -90)
            NSColor(white: 1, alpha: 0.35).setStroke()
            path.lineWidth = 1.5 * u
            path.stroke()

            // 暖金圓 + 👏
            let circle = CGRect(x: capsule.minX + 8 * u, y: capsule.midY - icon / 2, width: icon, height: icon)
            NSColor(hex: 0xF3C969).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let clap = text("👏", size: icon * 0.58, weight: .regular, color: .black)
            let clapSize = clap.size()
            clap.draw(at: CGPoint(x: circle.midX - clapSize.width / 2, y: circle.midY - clapSize.height / 2))

            let textX = circle.maxX + 14 * u
            let top = NSMutableAttributedString(attributedString: name)
            top.append(tag)
            top.draw(at: CGPoint(x: textX, y: capsule.midY + 2 * u))
            let bottom = NSMutableAttributedString(attributedString: count)
            bottom.append(unitText)
            bottom.draw(at: CGPoint(x: textX, y: capsule.midY - bottom.size().height + 4 * u))
        }
        let old = pill.frame
        pillSize = size
        pill.contents = image
        pill.contentsScale = scale
        pill.isHidden = false
        // 寬度改變時維持靠右 / 靠左對齊
        if old.width > 0, old.maxX >= bounds.midX {
            pill.frame = CGRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height)
        } else {
            pill.frame = CGRect(x: old.minX, y: old.minY, width: size.width, height: size.height)
        }
    }

    /// 有人投票：膠囊跳一下，飄出一個 👏（很多人同時投票時排隊飄出，最多 16 個）。
    func celebrate() {
        guard speaker != nil, !pill.isHidden else { return }
        if pill.animation(forKey: "pulse") == nil {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.12, 1]
            pulse.keyTimes = [0, 0.4, 1]
            pulse.duration = 0.35
            pill.add(pulse, forKey: "pulse")
        }
        pendingClaps = min(pendingClaps + 1, 16)
        guard clapTimer == nil else { return }
        spawnClap()
        pendingClaps -= 1
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] timer in
            guard let self, self.pendingClaps > 0, self.speaker != nil else {
                timer.invalidate()
                self?.clapTimer = nil
                return
            }
            self.pendingClaps -= 1
            self.spawnClap()
        }
        RunLoop.main.add(timer, forMode: .common)
        clapTimer = timer
    }

    private func spawnClap() {
        guard claps < 24, let layer else { return }
        claps += 1

        let u = unit
        let side = 64 * u
        let clap = CALayer()
        clap.contents = Self.clapImage(side: side, scale: scale)
        clap.contentsScale = scale
        let start = CGPoint(x: pill.frame.minX + 50 * u + CGFloat.random(in: -10...30) * u,
                            y: floatsUp ? pill.frame.maxY - 10 * u : pill.frame.minY + 10 * u)
        let distance = CGFloat.random(in: 180...300) * u * (floatsUp ? 1 : -1)
        let end = CGPoint(x: start.x + CGFloat.random(in: -70...40) * u, y: start.y + distance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clap.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        clap.position = end
        clap.opacity = 0
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: end)
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.6, 1]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1.25
        let group = CAAnimationGroup()
        group.animations = [move, fade, grow]
        group.duration = 1.6

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak clap] in
            clap?.removeFromSuperlayer()
            self?.claps -= 1
        }
        layer.addSublayer(clap)
        clap.add(group, forKey: "float")
        CATransaction.commit()
    }

    private static var clapCache: (side: CGFloat, image: CGImage)?

    private static func clapImage(side: CGFloat, scale: CGFloat) -> CGImage? {
        if let cached = clapCache, cached.side == side { return cached.image }
        let image = renderImage(size: CGSize(width: side, height: side), scale: scale) { rect in
            let clap = text("👏", size: side * 0.8, weight: .regular, color: .black)
            let size = clap.size()
            clap.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        if let image { clapCache = (side, image) }
        return image
    }
}

// MARK: - 公布卡片（本月最佳講師 / 本場數據）

private func centered(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ])
}

/// 全螢幕的公布卡片：半透明深色背景 + 置中白卡（和大型 QR Code 同一種設計）。
final class AnnouncementView: NSView {
    var announcement: Announcement? {
        didSet {
            isHidden = announcement == nil
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let gold = NSColor(hex: 0xF3C969)
    private static let muted = NSColor(hex: 0x64748B)

    override func draw(_ dirtyRect: NSRect) {
        guard let announcement else { return }
        NSColor(hex: 0x0B1530, alpha: 0.66).setFill()
        bounds.fill()
        let u = min(bounds.height / 1080, bounds.width / 1920)
        switch announcement {
        case let .bestSpeaker(month, order, ranks):
            drawBestSpeaker(month: month, order: order, ranks: ranks, u: u)
        case let .sessionSummary(summary):
            drawSummary(summary, u: u)
        }
    }

    /// 白色卡片 + 上方 URBAN LIVE 標籤；回傳標籤下緣的 y。
    private func drawCard(_ card: CGRect, u: CGFloat) -> CGFloat {
        let path = NSBezierPath(roundedRect: card, xRadius: 40 * u, yRadius: 40 * u)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadow.shadowBlurRadius = 40 * u
        shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
        shadow.set()
        Brand.glacierWhite.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let badge = centered("URBAN LIVE", size: 22 * u, weight: .heavy, color: .white)
        let badgeSize = NSSize(width: badge.size().width + 56 * u, height: 44 * u)
        let badgeRect = NSRect(x: card.midX - badgeSize.width / 2, y: card.minY + 34 * u, width: badgeSize.width, height: badgeSize.height)
        Brand.royalBlue.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize.height / 2, yRadius: badgeSize.height / 2).fill()
        badge.draw(in: NSRect(x: badgeRect.minX, y: badgeRect.midY - badge.size().height / 2, width: badgeRect.width, height: badge.size().height))
        return badgeRect.maxY
    }

    private func line(_ string: NSAttributedString, in card: CGRect, y: CGFloat, inset: CGFloat = 40) -> CGFloat {
        let height = string.size().height
        string.draw(in: NSRect(x: card.minX + inset, y: y, width: card.width - inset * 2, height: height + 4))
        return y + height
    }

    private func drawBestSpeaker(month: MonthKey, order: RankingOrder, ranks: [SpeakerRank], u: CGFloat) {
        let runnersUp = Array(ranks.dropFirst().prefix(4))
        let width = min(bounds.width * 0.82, 1180 * u)
        let rows = CGFloat(runnersUp.count)
        let height = (ranks.isEmpty ? 480 : 520) * u + rows * 50 * u + (rows > 0 ? 34 * u : 0)
        let card = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        var y = drawCard(card, u: u) + 18 * u
        y = line(centered("🏆 本月最佳講師", size: 56 * u, weight: .heavy, color: Brand.deepSea), in: card, y: y)
        y = line(centered("\(month.title) · \(order.title)", size: 26 * u, weight: .semibold, color: Self.muted), in: card, y: y + 6 * u)

        guard let winner = ranks.first else {
            y = line(centered("本月還沒有講師投票紀錄", size: 40 * u, weight: .bold, color: Brand.royalBlue), in: card, y: y + 90 * u)
            _ = line(centered("在控制面板「場次」分頁開始「講師超棒投票」", size: 26 * u, weight: .medium, color: Self.muted), in: card, y: y + 16 * u)
            return
        }
        // 冠軍：暖金標籤 + 大字姓名
        let crown = centered("🥇 冠軍", size: 26 * u, weight: .heavy, color: Brand.deepSea)
        let crownSize = NSSize(width: crown.size().width + 44 * u, height: 46 * u)
        let crownRect = NSRect(x: card.midX - crownSize.width / 2, y: y + 30 * u, width: crownSize.width, height: crownSize.height)
        Self.gold.setFill()
        NSBezierPath(roundedRect: crownRect, xRadius: crownSize.height / 2, yRadius: crownSize.height / 2).fill()
        crown.draw(in: NSRect(x: crownRect.minX, y: crownRect.midY - crown.size().height / 2, width: crownRect.width, height: crown.size().height))
        y = line(centered(winner.name, size: 96 * u, weight: .heavy, color: Brand.royalBlue), in: card, y: crownRect.maxY + 6 * u)
        y = line(centered(Self.details(winner), size: 32 * u, weight: .semibold, color: Brand.deepSea), in: card, y: y + 4 * u)

        y += 26 * u
        if !runnersUp.isEmpty {
            NSColor(hex: 0xDCE6F5).setFill()
            NSRect(x: card.minX + 120 * u, y: y, width: card.width - 240 * u, height: 2 * u).fill()
            y += 18 * u
        }
        let medals = ["🥈", "🥉", "4", "5"]
        for (index, rank) in runnersUp.enumerated() {
            let row = NSMutableAttributedString(attributedString: centered("\(medals[index])  \(rank.name)　", size: 30 * u, weight: .bold, color: Brand.deepSea))
            row.append(centered(Self.details(rank), size: 26 * u, weight: .medium, color: Self.muted))
            y = line(row, in: card, y: y) + 12 * u
        }
    }

    private static func details(_ rank: SpeakerRank) -> String {
        var parts = ["👏 \(rank.votes) 票"]
        if let gifts = GiftSummary.text(rank.gifts, separator: " ") { parts.append(gifts) }
        parts.append("分享 \(rank.turns) 次")
        if let rate = rank.voteRate { parts.append("得票率 \(Int((rate * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private func drawSummary(_ summary: SessionSummary, u: CGFloat) {
        let width = min(bounds.width * 0.86, 1280 * u)
        let height = (GiftSummary.text(summary.gifts) == nil ? 720 : 770) * u
        let card = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        var y = drawCard(card, u: u) + 18 * u
        y = line(centered("📊 本場數據", size: 56 * u, weight: .heavy, color: Brand.deepSea), in: card, y: y)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        y = line(centered("\(formatter.string(from: summary.date)) 開始", size: 26 * u, weight: .semibold, color: Self.muted), in: card, y: y + 6 * u)

        let tiles: [(String, String, String)] = [
            ("\(summary.participants)", "人", "參與人數"),
            ("\(summary.peakOnline)", "人", "最高同時在線"),
            ("\(summary.senders)", "人", "發過彈幕"),
            ("\(summary.shown)", "則", "彈幕上螢幕"),
            ("\(summary.votes)", "票", "講師超棒"),
            ("\(summary.nicknameChanges)", "次", "換名次數 XD"),
        ]
        let grid = NSRect(x: card.minX + 60 * u, y: y + 30 * u, width: card.width - 120 * u, height: 300 * u)
        let columns = 3
        let tileWidth = grid.width / CGFloat(columns)
        let tileHeight = grid.height / 2
        for (index, tile) in tiles.enumerated() {
            let rect = NSRect(x: grid.minX + CGFloat(index % columns) * tileWidth, y: grid.minY + CGFloat(index / columns) * tileHeight,
                              width: tileWidth, height: tileHeight).insetBy(dx: 10 * u, dy: 10 * u)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 24 * u, yRadius: 24 * u).fill()
            let value = NSMutableAttributedString(attributedString: centered(tile.0, size: 64 * u, weight: .heavy, color: Brand.royalBlue))
            value.append(centered(" " + tile.1, size: 26 * u, weight: .bold, color: Brand.royalBlue))
            let label = centered(tile.2, size: 24 * u, weight: .semibold, color: Self.muted)
            let total = value.size().height + label.size().height
            value.draw(in: NSRect(x: rect.minX, y: rect.midY - total / 2, width: rect.width, height: value.size().height + 2))
            label.draw(in: NSRect(x: rect.minX, y: rect.midY - total / 2 + value.size().height, width: rect.width, height: label.size().height + 2))
        }
        y = grid.maxY + 22 * u

        if !summary.speakers.isEmpty {
            let speakers = summary.speakers.prefix(4).map { "\($0.name) \($0.votes) 票" }.joined(separator: "　")
            y = line(centered("🎤 " + speakers, size: 28 * u, weight: .bold, color: Brand.deepSea), in: card, y: y) + 10 * u
        }
        if let gifts = GiftSummary.text(summary.gifts) {
            y = line(centered("🎁 禮物：" + gifts, size: 28 * u, weight: .bold, color: Brand.deepSea), in: card, y: y) + 10 * u
        }
        if let renamer = summary.topRenamer {
            _ = line(centered("👑 換名王：\(renamer)（換了 \(summary.topRenamerChanges) 次）XD", size: 28 * u, weight: .bold, color: NSColor(hex: 0xB7791F)),
                     in: card, y: y)
        }
    }
}
