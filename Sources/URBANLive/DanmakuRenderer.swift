import AppKit
import DanmakuCore
import ImageIO

/// 一則彈幕要顯示的內容。
struct DanmakuContent {
    let text: String
    let nickname: String?
    let avatar: CGImage?
}

/// 某個樣式、某個字體大小下的尺寸（全部由字體大小推算，同一樣式每條軌道等高）。
struct DanmakuMetrics {
    let style: DanmakuStyle
    let fontSize: CGFloat
    let font: NSFont
    let nicknameFont: NSFont
    let lineHeight: CGFloat
    let height: CGFloat
    let horizontalPadding: CGFloat
    /// 圖片四周預留給陰影的空間
    let margin: CGFloat
    let avatarDiameter: CGFloat
    let gap: CGFloat

    init(style: DanmakuStyle, fontSize: CGFloat) {
        self.style = style
        self.fontSize = fontSize
        font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        nicknameFont = NSFont.systemFont(ofSize: round(fontSize * 0.62), weight: .semibold)
        lineHeight = DanmakuRenderer.lineHeight(for: font)
        gap = round(fontSize * 0.28)
        switch style {
        case .glass:
            height = lineHeight + round(fontSize * 0.24) * 2
            horizontalPadding = round(fontSize * 0.6)
            avatarDiameter = round(height * 0.76)
        case .classic:
            height = lineHeight + round(fontSize * 0.12) * 2
            horizontalPadding = round(fontSize * 0.14)
            avatarDiameter = round(lineHeight * 0.92)
        case .card:
            height = lineHeight + round(fontSize * 0.3) * 2
            horizontalPadding = round(fontSize * 0.56)
            avatarDiameter = round(height * 0.68)
        }
        margin = max(6, round(fontSize * 0.26))
    }
}

struct RenderedDanmaku {
    let image: CGImage
    /// 含陰影邊距的圖片大小（pt）
    let size: CGSize
    /// 彈幕本體寬度（pt，不含陰影），軌道分配用這個寬度
    let bodyWidth: CGFloat
    let margin: CGFloat
}

/// 把彈幕畫成點陣圖，交給 Core Animation 移動。
///
/// 預先畫好再移動，Emoji 一定是彩色、文字邊緣清晰，捲動動畫在 WindowServer 端執行，
/// Keynote / PowerPoint 忙碌時也不會卡頓。
enum DanmakuRenderer {
    private static var lineHeightCache: [Int: CGFloat] = [:]

    static func lineHeight(for font: NSFont) -> CGFloat {
        let key = Int(font.pointSize * 100)
        if let cached = lineHeightCache[key] { return cached }
        // 用中文、英文、Emoji 混合字串量，涵蓋蘋方與 Apple Color Emoji 的備援字型
        let height = ceil(NSAttributedString(string: "國Ag😀", attributes: [.font: font]).size().height)
        lineHeightCache[key] = height
        return height
    }

    static func laneHeight(style: DanmakuStyle, fontSize: CGFloat) -> CGFloat {
        DanmakuMetrics(style: style, fontSize: fontSize).height
    }

    /// 繪製一則彈幕。太長時先縮小字體（最小 60%），仍放不下才截斷並加上「…」，確保不超出畫面。
    static func render(
        _ content: DanmakuContent,
        style: DanmakuStyle,
        fontSize: CGFloat,
        scale: CGFloat,
        maxBodyWidth: CGFloat = .greatestFiniteMagnitude
    ) -> RenderedDanmaku? {
        var size = fontSize
        var text = content.text
        var layout = Layout(content: content, text: text, metrics: DanmakuMetrics(style: style, fontSize: size))
        var attempts = 0
        while layout.bodyWidth > maxBodyWidth && attempts < 40 {
            attempts += 1
            if size > fontSize * 0.6 + 0.5 {
                size = max(fontSize * 0.6, floor(size * maxBodyWidth / layout.bodyWidth))
            } else if text.count > 1 {
                text = String(text.dropLast(text.hasSuffix("…") ? 2 : 1)) + "…"
            } else {
                break
            }
            layout = Layout(content: content, text: text, metrics: DanmakuMetrics(style: style, fontSize: size))
        }
        return draw(layout, scale: scale)
    }

    // MARK: - 版面

    private struct Layout {
        let metrics: DanmakuMetrics
        let attributed: NSAttributedString
        let textSize: CGSize
        let avatar: CGImage?
        let tag: NSAttributedString?
        let tagSize: CGSize
        let leftInset: CGFloat
        let bodyWidth: CGFloat

        init(content: DanmakuContent, text: String, metrics m: DanmakuMetrics) {
            metrics = m
            avatar = content.avatar
            let attributed = NSMutableAttributedString()
            if let nickname = content.nickname, !nickname.isEmpty {
                attributed.append(NSAttributedString(string: nickname + "\u{2002}", attributes: DanmakuRenderer.nicknameAttributes(m)))
            }
            attributed.append(NSAttributedString(string: text, attributes: DanmakuRenderer.messageAttributes(m)))
            self.attributed = attributed
            textSize = attributed.size()

            if m.style == .card {
                let tag = NSAttributedString(string: "URBAN LIVE", attributes: [
                    .font: NSFont.systemFont(ofSize: max(9, round(m.fontSize * 0.27)), weight: .heavy),
                    .foregroundColor: NSColor.white,
                    .kern: m.fontSize * 0.02,
                ])
                self.tag = tag
                let tagText = tag.size()
                tagSize = CGSize(width: ceil(tagText.width + m.fontSize * 0.62), height: ceil(m.fontSize * 0.5))
            } else {
                tag = nil
                tagSize = .zero
            }

            switch m.style {
            case .glass:
                leftInset = avatar != nil ? (m.height - m.avatarDiameter) / 2 : m.horizontalPadding
            case .classic:
                leftInset = m.horizontalPadding
            case .card:
                leftInset = round(m.fontSize * 0.42)
            }
            var width = leftInset
            if avatar != nil { width += m.avatarDiameter + m.gap }
            if tag != nil { width += tagSize.width + m.gap * 0.8 }
            width += ceil(textSize.width) + m.horizontalPadding
            bodyWidth = ceil(width)
        }
    }

    static func messageAttributes(_ m: DanmakuMetrics) -> [NSAttributedString.Key: Any] {
        switch m.style {
        case .glass:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -max(1, m.fontSize / 28))
            shadow.shadowBlurRadius = max(1, m.fontSize / 14)
            return [.font: m.font, .foregroundColor: NSColor.white, .shadow: shadow]
        case .classic:
            return [.font: m.font, .foregroundColor: NSColor.white]
        case .card:
            return [.font: m.font, .foregroundColor: Brand.royalBlue]
        }
    }

    static func nicknameAttributes(_ m: DanmakuMetrics) -> [NSAttributedString.Key: Any] {
        switch m.style {
        case .glass, .classic:
            return [.font: m.nicknameFont, .foregroundColor: Brand.warmGold]
        case .card:
            return [.font: m.nicknameFont, .foregroundColor: Brand.electricBlue]
        }
    }

    // MARK: - 繪製

    private static func draw(_ layout: Layout, scale: CGFloat) -> RenderedDanmaku? {
        let m = layout.metrics
        let size = CGSize(width: layout.bodyWidth + m.margin * 2, height: m.height + m.margin * 2)
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < 16_384,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        let body = CGRect(x: m.margin, y: m.margin, width: layout.bodyWidth, height: m.height)
        switch m.style {
        case .glass: drawGlassBackground(body, m, context, colorSpace)
        case .classic: break
        case .card: drawCardBackground(body, m, context)
        }

        var x = body.minX + layout.leftInset
        if let avatar = layout.avatar {
            let rect = CGRect(x: x, y: body.midY - m.avatarDiameter / 2, width: m.avatarDiameter, height: m.avatarDiameter)
            let ring: NSColor
            switch m.style {
            case .glass: ring = NSColor(white: 1, alpha: 0.65)
            case .classic: ring = NSColor.white
            case .card: ring = Brand.electricBlue.withAlphaComponent(0.35)
            }
            drawAvatar(avatar, in: rect, ring: ring, ringWidth: max(1.5, m.avatarDiameter * 0.05), context: context, outline: m.style == .classic)
            x = rect.maxX + m.gap
        }
        if let tag = layout.tag {
            let rect = CGRect(x: x, y: body.midY - layout.tagSize.height / 2, width: layout.tagSize.width, height: layout.tagSize.height)
            drawTag(tag, in: rect, m, context)
            x = rect.maxX + m.gap * 0.8
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let origin = CGPoint(x: x, y: body.minY + (m.height - layout.textSize.height) / 2)
        if m.style == .classic {
            drawOutlinedText(layout.attributed, at: origin, m)
        } else {
            layout.attributed.draw(at: origin)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return RenderedDanmaku(image: image, size: size, bodyWidth: layout.bodyWidth, margin: m.margin)
    }

    /// 樣式 A：深藍半透明玻璃膠囊。
    private static func drawGlassBackground(_ body: CGRect, _ m: DanmakuMetrics, _ context: CGContext, _ colorSpace: CGColorSpace) {
        let radius = body.height / 2
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 柔和陰影（在白底投影片上也能看清楚輪廓）
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -m.margin * 0.3), blur: m.margin * 0.9, color: NSColor(white: 0, alpha: 0.38).cgColor)
        context.addPath(path)
        context.setFillColor(Brand.deepSea.withAlphaComponent(0.9).cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.clear(body)
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [Brand.royalBlue.withAlphaComponent(0.86).cgColor, Brand.deepSea.withAlphaComponent(0.9).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        }
        // 玻璃反光
        if let highlight = CGGradient(
            colorsSpace: colorSpace,
            colors: [NSColor(white: 1, alpha: 0.2).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(highlight, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
        }
        context.restoreGState()

        // 細緻邊框：上緣帶一點電光藍
        let lineWidth = max(1, m.fontSize * 0.032)
        let inset = body.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let insetRadius = inset.height / 2
        context.saveGState()
        context.addPath(CGPath(roundedRect: inset, cornerWidth: insetRadius, cornerHeight: insetRadius, transform: nil))
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor(white: 1, alpha: 0.32).cgColor)
        context.strokePath()
        context.restoreGState()
    }

    /// 樣式 C：白色圓角訊息卡 + 左側暖金細條。
    private static func drawCardBackground(_ body: CGRect, _ m: DanmakuMetrics, _ context: CGContext) {
        let radius = body.height * 0.3
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -m.margin * 0.35), blur: m.margin, color: NSColor(hex: 0x0B1530, alpha: 0.32).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(Brand.glacierWhite.cgColor)
        context.fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.45))
        context.setFillColor(Brand.warmGold.cgColor)
        context.fill(CGRect(x: body.minX, y: body.minY, width: max(3, m.fontSize * 0.09), height: body.height))
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1)
        context.setStrokeColor(Brand.royalBlue.withAlphaComponent(0.12).cgColor)
        context.strokePath()
        context.restoreGState()
    }

    /// 樣式 C 的「URBAN LIVE」小標籤。
    private static func drawTag(_ tag: NSAttributedString, in rect: CGRect, _ m: DanmakuMetrics, _ context: CGContext) {
        context.saveGState()
        let radius = rect.height / 2
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(Brand.royalBlue.cgColor)
        context.fillPath()
        let dot = rect.height * 0.26
        context.setFillColor(Brand.warmGold.cgColor)
        context.fillEllipse(in: CGRect(x: rect.minX + rect.height * 0.32, y: rect.midY - dot / 2, width: dot, height: dot))
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let size = tag.size()
        tag.draw(at: CGPoint(x: rect.minX + rect.height * 0.32 + dot + rect.height * 0.18, y: rect.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 樣式 B：深色描邊 + 陰影，再疊上白字，任何背景都清楚。
    private static func drawOutlinedText(_ text: NSAttributedString, at origin: CGPoint, _ m: DanmakuMetrics) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -max(1, m.fontSize * 0.04))
        shadow.shadowBlurRadius = max(2, m.fontSize * 0.16)

        let outline = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: outline.length)
        outline.addAttribute(.strokeColor, value: NSColor(hex: 0x0B1530, alpha: 0.95), range: range)
        outline.addAttribute(.strokeWidth, value: 16, range: range) // 正值：只描邊（字體大小的 16%）
        outline.addAttribute(.shadow, value: shadow, range: range)
        outline.draw(at: origin)
        text.draw(at: origin)
    }

    private static func drawAvatar(_ image: CGImage, in rect: CGRect, ring: NSColor, ringWidth: CGFloat, context: CGContext, outline: Bool) {
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        // aspect fill
        let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var drawRect = rect
        if imageAspect > 1 {
            drawRect.size.width = rect.height * imageAspect
            drawRect.origin.x = rect.midX - drawRect.width / 2
        } else if imageAspect < 1 {
            drawRect.size.height = rect.width / imageAspect
            drawRect.origin.y = rect.midY - drawRect.height / 2
        }
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        context.restoreGState()

        context.saveGState()
        if outline {
            context.setStrokeColor(NSColor(hex: 0x0B1530, alpha: 0.9).cgColor)
            context.setLineWidth(ringWidth * 2.2)
            context.strokeEllipse(in: rect.insetBy(dx: -ringWidth * 0.6, dy: -ringWidth * 0.6))
        }
        context.setStrokeColor(ring.cgColor)
        context.setLineWidth(ringWidth)
        context.strokeEllipse(in: rect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        context.restoreGState()
    }
}

/// 把手機送來的大頭貼設定轉成圖片（每位觀眾只轉一次並快取）。
enum AvatarFactory {
    static let pixelSize = 160

    static func image(for avatar: ValidatedAvatar, nickname: String?) -> CGImage? {
        switch avatar {
        case let .emoji(emoji, colorHex):
            return emojiAvatar(emoji, color: NSColor(hexString: colorHex) ?? Brand.electricBlue)
        case let .photo(data):
            return photoAvatar(data) ?? nickname.flatMap(initialAvatar)
        case .none:
            return nickname.flatMap(initialAvatar)
        }
    }

    static func emojiAvatar(_ emoji: String, color: NSColor) -> CGImage? {
        drawCircle(fill: color) { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.58)
            let string = NSAttributedString(string: emoji, attributes: [.font: font])
            let size = string.size()
            string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    /// 沒有選大頭貼但有暱稱：用暱稱第一個字。
    static func initialAvatar(_ nickname: String) -> CGImage? {
        guard let first = nickname.first else { return nil }
        return drawCircle(fill: Brand.electricBlue) { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.5, weight: .bold)
            let string = NSAttributedString(string: String(first).uppercased(), attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = string.size()
            string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    /// 照片：用 ImageIO 直接產生縮圖（不會把大圖完整解碼到記憶體），再裁成正方形。
    static func photoAvatar(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ $0 as String }),
              type == "public.jpeg" || type == "public.png"
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize * 2,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let side = min(thumbnail.width, thumbnail.height)
        guard side > 8 else { return nil }
        let crop = CGRect(x: (thumbnail.width - side) / 2, y: (thumbnail.height - side) / 2, width: side, height: side)
        return thumbnail.cropping(to: crop)
    }

    private static func drawCircle(fill: NSColor, content: (CGRect) -> Void) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        content(rect)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
