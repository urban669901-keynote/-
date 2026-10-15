import AppKit
import CoreImage

enum QRCodeGenerator {
    /// 產生黑白 QR Code（每個模組都是整數像素，投影放大後依然銳利）。
    static func makeImage(for string: String, modulePixels: Int = 12) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(modulePixels), y: CGFloat(modulePixels)))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent)
    }
}

/// 畫面角落的「掃碼發送彈幕」卡片。
final class QRCardView: NSView {
    static let padding: CGFloat = 14
    static let headerHeight: CGFloat = 34
    static let footerHeight: CGFloat = 46

    var qrSize: CGFloat = 200 {
        didSet { needsDisplay = true }
    }

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

    /// 依 QR 大小計算卡片尺寸。
    static func cardSize(qrSize: CGFloat) -> NSSize {
        NSSize(width: qrSize + padding * 2, height: headerHeight + padding + qrSize + footerHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let card = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 18
        let cardPath = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

        NSColor.white.withAlphaComponent(0.97).setFill()
        cardPath.fill()

        // 頂部 URBAN Blue 標題列
        NSGraphicsContext.saveGraphicsState()
        cardPath.addClip()
        Theme.urbanBlue.setFill()
        NSRect(x: card.minX, y: card.minY, width: card.width, height: Self.headerHeight).fill()
        NSGraphicsContext.restoreGraphicsState()

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.alignment = .center
        let header = NSAttributedString(string: "URBAN 即時彈幕", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: headerStyle,
        ])
        let headerTextHeight = header.size().height
        header.draw(in: NSRect(
            x: card.minX,
            y: card.minY + (Self.headerHeight - headerTextHeight) / 2,
            width: card.width,
            height: headerTextHeight
        ))

        let qrRect = NSRect(
            x: (bounds.width - qrSize) / 2,
            y: Self.headerHeight + Self.padding,
            width: qrSize,
            height: qrSize
        )
        if let qrImage {
            context.saveGState()
            context.interpolationQuality = .none
            // flipped 座標系下畫 CGImage 需要上下翻轉回來
            context.translateBy(x: qrRect.minX, y: qrRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(qrImage, in: CGRect(origin: .zero, size: qrRect.size))
            context.restoreGState()
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let message = NSAttributedString(string: "找不到 Wi-Fi 網路\n請確認 Mac 已連上網路", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.darkGray,
                .paragraphStyle: style,
            ])
            message.draw(in: qrRect.insetBy(dx: 8, dy: qrSize / 2 - 24))
        }

        let footerStyle = NSMutableParagraphStyle()
        footerStyle.alignment = .center
        footerStyle.lineBreakMode = .byTruncatingMiddle
        let caption = NSAttributedString(string: "手機掃描，發送文字或 Emoji", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Theme.urbanBlue,
            .paragraphStyle: footerStyle,
        ])
        let footerTop = qrRect.maxY + 6
        caption.draw(in: NSRect(x: card.minX + 6, y: footerTop, width: card.width - 12, height: 18))
        if let url {
            let link = NSAttributedString(string: url.replacingOccurrences(of: "http://", with: ""), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.gray,
                .paragraphStyle: footerStyle,
            ])
            link.draw(in: NSRect(x: card.minX + 6, y: footerTop + 19, width: card.width - 12, height: 16))
        }
    }
}
