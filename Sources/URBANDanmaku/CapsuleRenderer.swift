import AppKit

/// 一則彈幕的外觀參數（全部由字體大小推算，確保每條軌道等高）。
struct CapsuleStyle: Equatable {
    let fontSize: CGFloat

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .bold) }
    var horizontalPadding: CGFloat { round(fontSize * 0.62) }
    var verticalPadding: CGFloat { round(fontSize * 0.24) }
    /// 圖片四周預留給陰影的空間。
    var shadowMargin: CGFloat { max(6, round(fontSize * 0.2)) }
    var borderWidth: CGFloat { max(1, fontSize * 0.035) }

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = Theme.textShadow
        shadow.shadowOffset = NSSize(width: 0, height: -max(1, fontSize / 28))
        shadow.shadowBlurRadius = max(1, fontSize / 14)
        return [
            .font: font,
            .foregroundColor: Theme.text,
            .shadow: shadow,
        ]
    }

    /// 文字行高：用中文、英文、Emoji 混合字串量，涵蓋 PingFang 與 Apple Color Emoji 的備援字型。
    var lineHeight: CGFloat {
        ceil(NSAttributedString(string: "國Ag😀", attributes: textAttributes).size().height)
    }

    var capsuleHeight: CGFloat { lineHeight + verticalPadding * 2 }
}

struct RenderedCapsule {
    let image: CGImage
    /// 含陰影邊距的圖片大小（pt）。
    let size: CGSize
    /// 膠囊本體（不含陰影）的寬度（pt），用來計算軌道間距。
    let capsuleWidth: CGFloat
}

/// 把一則彈幕畫成一張圖：深藍半透明玻璃膠囊 + 白色粗體字。
///
/// 預先畫成點陣圖再交給 Core Animation 移動，可確保 Emoji 為彩色、文字清晰，
/// 而且捲動動畫在 WindowServer 端執行，不會因為主執行緒忙碌而卡頓。
enum CapsuleRenderer {
    static func render(text: String, style: CapsuleStyle, lineHeight: CGFloat, scale: CGFloat) -> RenderedCapsule? {
        let string = NSAttributedString(string: text, attributes: style.textAttributes)
        let textSize = string.size()
        let capsuleWidth = ceil(textSize.width) + style.horizontalPadding * 2
        let capsuleHeight = max(lineHeight, ceil(textSize.height)) + style.verticalPadding * 2
        let margin = style.shadowMargin
        let size = CGSize(width: capsuleWidth + margin * 2, height: capsuleHeight + margin * 2)

        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)

        let capsuleRect = CGRect(x: margin, y: margin, width: capsuleWidth, height: capsuleHeight)
        let radius = capsuleHeight / 2
        let capsulePath = CGPath(roundedRect: capsuleRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 1. 外陰影：讓膠囊在白底投影片上也看得清楚。
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -margin * 0.3),
            blur: margin * 0.9,
            color: Theme.capsuleShadow.cgColor
        )
        context.addPath(capsulePath)
        context.setFillColor(Theme.capsuleBottom.cgColor)
        context.fillPath()
        context.restoreGState()

        // 2. 膠囊本體：深藍漸層（陰影那層已經畫了一次底色，這裡先清掉再畫，避免透明度疊加）。
        context.saveGState()
        context.addPath(capsulePath)
        context.clip()
        context.clear(capsuleRect)
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [Theme.capsuleTop.cgColor, Theme.capsuleBottom.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: capsuleRect.maxY),
                end: CGPoint(x: 0, y: capsuleRect.minY),
                options: []
            )
        }
        // 3. 玻璃反光：上半部一層淡白漸層。
        if let highlight = CGGradient(
            colorsSpace: colorSpace,
            colors: [Theme.capsuleHighlight.cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                highlight,
                start: CGPoint(x: 0, y: capsuleRect.maxY),
                end: CGPoint(x: 0, y: capsuleRect.midY),
                options: []
            )
        }
        context.restoreGState()

        // 4. 玻璃邊框。
        let inset = style.borderWidth / 2
        let borderRect = capsuleRect.insetBy(dx: inset, dy: inset)
        let borderRadius = borderRect.height / 2
        context.addPath(CGPath(roundedRect: borderRect, cornerWidth: borderRadius, cornerHeight: borderRadius, transform: nil))
        context.setStrokeColor(Theme.capsuleBorder.cgColor)
        context.setLineWidth(style.borderWidth)
        context.strokePath()

        // 5. 白色粗體文字（置中）。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let textOrigin = CGPoint(
            x: capsuleRect.minX + style.horizontalPadding,
            y: capsuleRect.minY + (capsuleHeight - textSize.height) / 2
        )
        string.draw(at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return RenderedCapsule(image: image, size: size, capsuleWidth: capsuleWidth)
    }
}
