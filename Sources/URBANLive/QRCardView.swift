import AppKit
import CoreImage

enum QRCodeGenerator {
    /// 產生黑白 QR Code（每個模組都是整數像素，放大投影後依然銳利）。
    static func makeImage(for string: String, modulePixels: Int = 16) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(modulePixels), y: CGFloat(modulePixels)))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent)
    }

    static func draw(_ image: CGImage, in rect: CGRect, context: CGContext, flipped: Bool) {
        context.saveGState()
        context.interpolationQuality = .none
        if flipped {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        } else {
            context.draw(image, in: rect)
        }
        context.restoreGState()
    }
}

private func centered(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingMiddle
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}

/// 畫面角落的小型 QR Code 卡片。
final class QRCardView: NSView {
    /// 所有尺寸以 QR 大小為比例計算，跟著螢幕解析度縮放。
    var qrSize: CGFloat = 220 { didSet { needsDisplay = true } }
    private(set) var url: String?
    private var qrImage: CGImage?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setURL(_ url: String?) {
        guard url != self.url else { return }
        self.url = url
        qrImage = url.flatMap { QRCodeGenerator.makeImage(for: $0) }
        needsDisplay = true
    }

    private static func unit(_ qrSize: CGFloat) -> CGFloat { qrSize / 220 }

    static func cardSize(qrSize: CGFloat) -> NSSize {
        let u = unit(qrSize)
        return NSSize(width: qrSize + 32 * u, height: 40 * u + 14 * u + qrSize + 52 * u)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let u = Self.unit(qrSize)
        let card = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: 20 * u, yRadius: 20 * u)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
        shadow.shadowBlurRadius = 12 * u
        shadow.shadowOffset = NSSize(width: 0, height: -4 * u)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 皇家藍標題列 + 暖金圓點
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Brand.royalBlue.setFill()
        NSRect(x: card.minX, y: card.minY, width: card.width, height: 40 * u).fill()
        NSGraphicsContext.restoreGraphicsState()
        let title = centered("URBAN LIVE", font: NSFont.systemFont(ofSize: 17 * u, weight: .heavy), color: .white)
        let titleHeight = title.size().height
        title.draw(in: NSRect(x: card.minX, y: card.minY + (40 * u - titleHeight) / 2, width: card.width, height: titleHeight))

        let qrRect = NSRect(x: (bounds.width - qrSize) / 2, y: 54 * u, width: qrSize, height: qrSize)
        if let qrImage {
            QRCodeGenerator.draw(qrImage, in: qrRect, context: context, flipped: true)
        } else {
            centered("找不到網路\n請確認 Mac 已連上 Wi-Fi", font: NSFont.systemFont(ofSize: 14 * u, weight: .semibold), color: .darkGray)
                .draw(in: qrRect.insetBy(dx: 8 * u, dy: qrSize / 2 - 24 * u))
        }

        let captionTop = qrRect.maxY + 8 * u
        centered("掃描發送早會彈幕", font: NSFont.systemFont(ofSize: 15 * u, weight: .bold), color: Brand.royalBlue)
            .draw(in: NSRect(x: card.minX + 6, y: captionTop, width: card.width - 12, height: 20 * u))
        if let url {
            centered(url.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: ""),
                     font: NSFont.monospacedSystemFont(ofSize: 11 * u, weight: .medium), color: NSColor(white: 0.45, alpha: 1))
                .draw(in: NSRect(x: card.minX + 6, y: captionTop + 22 * u, width: card.width - 12, height: 16 * u))
        }
    }
}

/// 大型 QR Code：開場時讓全場掃描。半透明深色背景 + 置中大卡片。
final class LargeQRView: NSView {
    private(set) var url: String?
    private var qrImage: CGImage?
    /// 本場已加入的人數（開場時顯示，鼓勵大家掃描）
    var joinedCount = 0 {
        didSet { if joinedCount != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setURL(_ url: String?) {
        guard url != self.url else { return }
        self.url = url
        qrImage = url.flatMap { QRCodeGenerator.makeImage(for: $0, modulePixels: 24) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor(hex: 0x0B1530, alpha: 0.62).setFill()
        bounds.fill()

        let u = bounds.height / 1080
        let qrSide = min(bounds.height * 0.5, bounds.width * 0.4)
        let cardWidth = qrSide + 120 * u
        let cardHeight = qrSide + 350 * u
        let card = NSRect(x: (bounds.width - cardWidth) / 2, y: (bounds.height - cardHeight) / 2, width: cardWidth, height: cardHeight)
        let path = NSBezierPath(roundedRect: card, xRadius: 36 * u, yRadius: 36 * u)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadow.shadowBlurRadius = 40 * u
        shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
        shadow.set()
        Brand.glacierWhite.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let badge = centered("URBAN LIVE", font: NSFont.systemFont(ofSize: 22 * u, weight: .heavy), color: .white)
        let badgeSize = NSSize(width: badge.size().width + 56 * u, height: 44 * u)
        let badgeRect = NSRect(x: card.midX - badgeSize.width / 2, y: card.minY + 34 * u, width: badgeSize.width, height: badgeSize.height)
        Brand.royalBlue.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize.height / 2, yRadius: badgeSize.height / 2).fill()
        badge.draw(in: NSRect(x: badgeRect.minX, y: badgeRect.midY - badge.size().height / 2, width: badgeRect.width, height: badge.size().height))

        centered("早會即時彈幕", font: NSFont.systemFont(ofSize: 40 * u, weight: .heavy), color: Brand.deepSea)
            .draw(in: NSRect(x: card.minX, y: badgeRect.maxY + 14 * u, width: card.width, height: 52 * u))

        let qrRect = NSRect(x: card.midX - qrSide / 2, y: badgeRect.maxY + 82 * u, width: qrSide, height: qrSide)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: qrRect.insetBy(dx: -14 * u, dy: -14 * u), xRadius: 18 * u, yRadius: 18 * u).fill()
        if let qrImage {
            QRCodeGenerator.draw(qrImage, in: qrRect, context: context, flipped: true)
        }

        centered("用手機相機掃描 · 不需下載 App、不需登入", font: NSFont.systemFont(ofSize: 22 * u, weight: .semibold), color: Brand.royalBlue)
            .draw(in: NSRect(x: card.minX + 10, y: qrRect.maxY + 30 * u, width: card.width - 20, height: 30 * u))
        if let url {
            centered(url, font: NSFont.monospacedSystemFont(ofSize: 18 * u, weight: .medium), color: NSColor(white: 0.4, alpha: 1))
                .draw(in: NSRect(x: card.minX + 10, y: qrRect.maxY + 66 * u, width: card.width - 20, height: 26 * u))
        }
        if joinedCount > 0 {
            let joined = centered("👥 已加入 \(joinedCount) 人", font: NSFont.systemFont(ofSize: 28 * u, weight: .heavy), color: Brand.deepSea)
            let size = NSSize(width: joined.size().width + 48 * u, height: 48 * u)
            let pill = NSRect(x: card.midX - size.width / 2, y: qrRect.maxY + 106 * u, width: size.width, height: size.height)
            NSColor(hex: 0xF3C969).setFill()
            NSBezierPath(roundedRect: pill, xRadius: size.height / 2, yRadius: size.height / 2).fill()
            joined.draw(in: NSRect(x: pill.minX, y: pill.midY - joined.size().height / 2, width: pill.width, height: joined.size().height))
        }
    }
}
