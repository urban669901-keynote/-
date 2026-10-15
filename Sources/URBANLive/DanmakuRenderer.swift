import AppKit
import DanmakuCore
import ImageIO

/// 一則彈幕要顯示的內容。
struct DanmakuContent {
    let text: String
    let nickname: String?
    let avatar: CGImage?
}

/// 某個樣式、某個字體大小下的尺寸（全部由字體大小推算，同一設定下每條軌道等高）。
struct DanmakuMetrics {
    let style: DanmakuStyle
    let profileSize: ProfileSize
    let fontSize: CGFloat
    let font: NSFont
    let lineHeight: CGFloat
    /// 圖片四周預留給陰影的空間
    let margin: CGFloat
    let gap: CGFloat

    // 單行（標準）
    let nicknameFont: NSFont
    let height: CGFloat
    let horizontalPadding: CGFloat
    let avatarDiameter: CGFloat

    // 兩行（大 / 特大）：上行暱稱、下行訊息
    let profileNicknameFont: NSFont
    let profileNicknameLineHeight: CGFloat
    let profileLineGap: CGFloat
    /// 兩行膠囊的高度
    let profileCapsuleHeight: CGFloat
    let profileAvatarDiameter: CGFloat
    /// 大頭貼是否超出膠囊上下緣（特大）
    let profileAvatarProtrudes: Bool

    init(style: DanmakuStyle, fontSize: CGFloat, profileSize: ProfileSize = .large) {
        self.style = style
        self.profileSize = profileSize
        self.fontSize = fontSize
        font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        lineHeight = DanmakuRenderer.lineHeight(for: font)
        gap = round(fontSize * 0.28)
        margin = max(6, round(fontSize * 0.26))

        nicknameFont = NSFont.systemFont(ofSize: round(fontSize * 0.62), weight: .semibold)
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

        let nicknameScale: CGFloat = profileSize == .extraLarge ? 0.95 : 0.8
        profileNicknameFont = NSFont.systemFont(ofSize: round(fontSize * nicknameScale), weight: .bold)
        profileNicknameLineHeight = DanmakuRenderer.lineHeight(for: profileNicknameFont)
        profileLineGap = round(fontSize * 0.02)
        let verticalPadding: CGFloat
        switch style {
        case .glass: verticalPadding = round(fontSize * 0.16)
        case .classic: verticalPadding = round(fontSize * 0.04)
        case .card: verticalPadding = round(fontSize * 0.2)
        }
        profileCapsuleHeight = profileNicknameLineHeight + profileLineGap + lineHeight + verticalPadding * 2
        profileAvatarProtrudes = profileSize == .extraLarge && style != .classic
        if profileSize == .extraLarge {
            profileAvatarDiameter = round(profileCapsuleHeight * (style == .classic ? 1.0 : 1.12))
        } else {
            profileAvatarDiameter = round(profileCapsuleHeight * (style == .classic ? 0.95 : 0.86))
        }
    }

    /// 兩行版面的整體高度（特大時大頭貼比膠囊高）。
    var profileBodyHeight: CGFloat { max(profileCapsuleHeight, profileAvatarDiameter) }

    /// 軌道高度。`profilesShown`：是否會顯示暱稱或大頭貼。
    func laneHeight(profilesShown: Bool) -> CGFloat {
        profilesShown && profileSize != .standard ? profileBodyHeight : height
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
        let key = Int(font.pointSize * 100) * 10 + (font.fontDescriptor.symbolicTraits.contains(.bold) ? 1 : 0)
        if let cached = lineHeightCache[key] { return cached }
        // 用中文、英文、Emoji 混合字串量，涵蓋蘋方與 Apple Color Emoji 的備援字型
        let height = ceil(NSAttributedString(string: "國Ag😀", attributes: [.font: font]).size().height)
        lineHeightCache[key] = height
        return height
    }

    static func laneHeight(style: DanmakuStyle, fontSize: CGFloat, profileSize: ProfileSize, profilesShown: Bool) -> CGFloat {
        DanmakuMetrics(style: style, fontSize: fontSize, profileSize: profileSize).laneHeight(profilesShown: profilesShown)
    }

    /// 繪製一則彈幕。太長時先縮小字體（最小 60%），仍放不下才截斷並加上「…」，確保不超出畫面。
    static func render(
        _ content: DanmakuContent,
        style: DanmakuStyle,
        fontSize: CGFloat,
        profileSize: ProfileSize = .large,
        scale: CGFloat,
        maxBodyWidth: CGFloat = .greatestFiniteMagnitude
    ) -> RenderedDanmaku? {
        let hasProfile = (content.nickname?.isEmpty == false) || content.avatar != nil
        let twoLine = profileSize != .standard && hasProfile

        func makeLayout(_ size: CGFloat, _ text: String) -> AnyLayout {
            let metrics = DanmakuMetrics(style: style, fontSize: size, profileSize: profileSize)
            return twoLine ? .profile(ProfileLayout(content: content, text: text, metrics: metrics))
                : .compact(CompactLayout(content: content, text: text, metrics: metrics))
        }

        var size = fontSize
        var text = content.text
        var layout = makeLayout(size, text)
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
            layout = makeLayout(size, text)
        }
        switch layout {
        case let .compact(compact): return drawCompact(compact, scale: scale)
        case let .profile(profile): return drawProfile(profile, scale: scale)
        }
    }

    // MARK: - 版面

    private enum AnyLayout {
        case compact(CompactLayout)
        case profile(ProfileLayout)

        var bodyWidth: CGFloat {
            switch self {
            case let .compact(layout): return layout.bodyWidth
            case let .profile(layout): return layout.bodyWidth
            }
        }
    }

    private static func tagString(_ m: DanmakuMetrics, scale: CGFloat = 1) -> (NSAttributedString, CGSize) {
        let tag = NSAttributedString(string: "URBAN LIVE", attributes: [
            .font: NSFont.systemFont(ofSize: max(9, round(m.fontSize * 0.27 * scale)), weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: m.fontSize * 0.02 * scale,
        ])
        let text = tag.size()
        return (tag, CGSize(width: ceil(text.width + m.fontSize * 0.62 * scale), height: ceil(m.fontSize * 0.5 * scale)))
    }

    /// 單行：大頭貼 + 暱稱 + 訊息
    private struct CompactLayout {
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
                attributed.append(NSAttributedString(string: nickname + "\u{2002}", attributes: DanmakuRenderer.nicknameAttributes(m, font: m.nicknameFont)))
            }
            attributed.append(NSAttributedString(string: text, attributes: DanmakuRenderer.messageAttributes(m)))
            self.attributed = attributed
            textSize = attributed.size()

            if m.style == .card {
                let made = DanmakuRenderer.tagString(m)
                tag = made.0
                tagSize = made.1
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

    /// 兩行：大大頭貼 + 上行暱稱（樣式 C 前面加 URBAN LIVE 標籤）+ 下行訊息
    private struct ProfileLayout {
        let metrics: DanmakuMetrics
        let nickname: NSAttributedString?
        let message: NSAttributedString
        let nicknameSize: CGSize
        let messageSize: CGSize
        let avatar: CGImage?
        let tag: NSAttributedString?
        let tagSize: CGSize
        /// 以下皆為相對本體左緣的 x
        let avatarX: CGFloat
        let capsuleX: CGFloat
        let textX: CGFloat
        let bodyWidth: CGFloat

        init(content: DanmakuContent, text: String, metrics m: DanmakuMetrics) {
            metrics = m
            avatar = content.avatar
            if let name = content.nickname, !name.isEmpty {
                nickname = NSAttributedString(string: name, attributes: DanmakuRenderer.nicknameAttributes(m, font: m.profileNicknameFont))
            } else {
                nickname = nil
            }
            message = NSAttributedString(string: text, attributes: DanmakuRenderer.messageAttributes(m))
            nicknameSize = nickname?.size() ?? .zero
            messageSize = message.size()

            if m.style == .card && nickname != nil {
                let made = DanmakuRenderer.tagString(m, scale: 1.1)
                tag = made.0
                tagSize = made.1
            } else {
                tag = nil
                tagSize = .zero
            }

            let capsule = m.profileCapsuleHeight
            let diameter = m.profileAvatarDiameter
            let edge: CGFloat
            switch m.style {
            case .glass: edge = round(m.fontSize * 0.6)
            case .classic: edge = round(m.fontSize * 0.14)
            case .card: edge = round(m.fontSize * 0.5)
            }
            if avatar != nil {
                if m.profileAvatarProtrudes {
                    // 特大：大頭貼坐在膠囊左端、上下超出
                    avatarX = 0
                    capsuleX = round(diameter * 0.5)
                } else if m.style == .classic {
                    avatarX = edge
                    capsuleX = 0
                } else {
                    avatarX = (capsule - diameter) / 2 + (m.style == .card ? round(m.fontSize * 0.1) : 0)
                    capsuleX = 0
                }
                textX = avatarX + diameter + round(m.gap * 1.1)
            } else {
                avatarX = 0
                capsuleX = 0
                textX = m.style == .card ? round(m.fontSize * 0.42) : edge
            }
            let firstLine = (tag != nil ? tagSize.width + round(m.gap * 0.6) : 0) + ceil(nicknameSize.width)
            bodyWidth = ceil(textX + max(firstLine, ceil(messageSize.width)) + edge)
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

    static func nicknameAttributes(_ m: DanmakuMetrics, font: NSFont) -> [NSAttributedString.Key: Any] {
        switch m.style {
        case .glass:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = max(1, m.fontSize / 16)
            return [.font: font, .foregroundColor: Brand.warmGold, .shadow: shadow]
        case .classic:
            return [.font: font, .foregroundColor: Brand.warmGold]
        case .card:
            return [.font: font, .foregroundColor: Brand.electricBlue]
        }
    }

    // MARK: - 繪製

    private static func makeContext(size: CGSize, scale: CGFloat) -> (CGContext, CGColorSpace)? {
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
        return (context, colorSpace)
    }

    private static func avatarRing(_ m: DanmakuMetrics, large: Bool) -> NSColor {
        switch m.style {
        case .glass: return NSColor(white: 1, alpha: large ? 0.9 : 0.65)
        case .classic: return NSColor.white
        case .card: return large ? Brand.royalBlue.withAlphaComponent(0.55) : Brand.electricBlue.withAlphaComponent(0.35)
        }
    }

    private static func drawCompact(_ layout: CompactLayout, scale: CGFloat) -> RenderedDanmaku? {
        let m = layout.metrics
        let size = CGSize(width: layout.bodyWidth + m.margin * 2, height: m.height + m.margin * 2)
        guard let made = makeContext(size: size, scale: scale) else { return nil }
        let (context, colorSpace) = made

        let body = CGRect(x: m.margin, y: m.margin, width: layout.bodyWidth, height: m.height)
        switch m.style {
        case .glass: drawGlassBackground(body, m, context, colorSpace)
        case .classic: break
        case .card: drawCardBackground(body, radius: body.height * 0.3, m, context)
        }

        var x = body.minX + layout.leftInset
        if let avatar = layout.avatar {
            let rect = CGRect(x: x, y: body.midY - m.avatarDiameter / 2, width: m.avatarDiameter, height: m.avatarDiameter)
            drawAvatar(avatar, in: rect, ring: avatarRing(m, large: false), ringWidth: max(1.5, m.avatarDiameter * 0.05),
                       context: context, outline: m.style == .classic, shadow: false)
            x = rect.maxX + m.gap
        }
        if let tag = layout.tag {
            let rect = CGRect(x: x, y: body.midY - layout.tagSize.height / 2, width: layout.tagSize.width, height: layout.tagSize.height)
            drawTag(tag, in: rect, context)
            x = rect.maxX + m.gap * 0.8
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawText(layout.attributed, at: CGPoint(x: x, y: body.minY + (m.height - layout.textSize.height) / 2), m)
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return RenderedDanmaku(image: image, size: size, bodyWidth: layout.bodyWidth, margin: m.margin)
    }

    private static func drawProfile(_ layout: ProfileLayout, scale: CGFloat) -> RenderedDanmaku? {
        let m = layout.metrics
        let bodyHeight = m.profileBodyHeight
        let size = CGSize(width: layout.bodyWidth + m.margin * 2, height: bodyHeight + m.margin * 2)
        guard let made = makeContext(size: size, scale: scale) else { return nil }
        let (context, colorSpace) = made

        let body = CGRect(x: m.margin, y: m.margin, width: layout.bodyWidth, height: bodyHeight)
        let capsule = CGRect(
            x: body.minX + layout.capsuleX,
            y: body.midY - m.profileCapsuleHeight / 2,
            width: layout.bodyWidth - layout.capsuleX,
            height: m.profileCapsuleHeight
        )
        switch m.style {
        case .glass: drawGlassBackground(capsule, m, context, colorSpace)
        case .classic: break
        case .card: drawCardBackground(capsule, radius: capsule.height * 0.24, m, context)
        }

        if let avatar = layout.avatar {
            let d = m.profileAvatarDiameter
            let rect = CGRect(x: body.minX + layout.avatarX, y: body.midY - d / 2, width: d, height: d)
            drawAvatar(avatar, in: rect, ring: avatarRing(m, large: true), ringWidth: max(2, d * 0.045),
                       context: context, outline: m.style == .classic, shadow: m.style != .classic)
        }

        // 文字區塊在膠囊內垂直置中：上行暱稱、下行訊息
        let blockHeight = (layout.nickname != nil ? layout.nicknameSize.height + m.profileLineGap : 0) + layout.messageSize.height
        let messageY = body.midY - blockHeight / 2
        var x = body.minX + layout.textX
        let nicknameY = messageY + layout.messageSize.height + m.profileLineGap
        if let tag = layout.tag {
            let rect = CGRect(x: x, y: nicknameY + (layout.nicknameSize.height - layout.tagSize.height) / 2,
                              width: layout.tagSize.width, height: layout.tagSize.height)
            drawTag(tag, in: rect, context)
            x = rect.maxX + round(m.gap * 0.6)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if let nickname = layout.nickname {
            drawText(nickname, at: CGPoint(x: x, y: nicknameY), m)
        }
        drawText(layout.message, at: CGPoint(x: body.minX + layout.textX, y: messageY), m)
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return RenderedDanmaku(image: image, size: size, bodyWidth: layout.bodyWidth, margin: m.margin)
    }

    private static func drawText(_ text: NSAttributedString, at origin: CGPoint, _ m: DanmakuMetrics) {
        if m.style == .classic {
            drawOutlinedText(text, at: origin, m)
        } else {
            text.draw(at: origin)
        }
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

        // 細緻邊框
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
    private static func drawCardBackground(_ body: CGRect, radius: CGFloat, _ m: DanmakuMetrics, _ context: CGContext) {
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
    private static func drawTag(_ tag: NSAttributedString, in rect: CGRect, _ context: CGContext) {
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

    private static func drawAvatar(
        _ image: CGImage, in rect: CGRect, ring: NSColor, ringWidth: CGFloat,
        context: CGContext, outline: Bool, shadow: Bool
    ) {
        if shadow {
            // 大頭貼底下的柔和陰影，讓人像從膠囊上「浮」出來
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.03), blur: rect.height * 0.12,
                              color: NSColor(white: 0, alpha: 0.45).cgColor)
            context.setFillColor(ring.cgColor)
            context.fillEllipse(in: rect)
            context.restoreGState()
        }

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
    /// 大頭貼放大後在 Retina 螢幕上約 300 px，所以以 320 px 繪製 / 縮圖，避免模糊。
    static let pixelSize = 320

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

    /// 相同 Emoji + 顏色、相同首字的大頭貼共用一張圖（200 人多半選同幾種動物）。
    private static var sharedCache: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let image = sharedCache[key] { return image }
        guard let image = make() else { return nil }
        if sharedCache.count > 300 { sharedCache.removeAll() }
        sharedCache[key] = image
        return image
    }

    static func emojiAvatar(_ emoji: String, color: NSColor) -> CGImage? {
        cached("e|\(emoji)|\(color.description)") { drawEmoji(emoji, color: color) }
    }

    private static func drawEmoji(_ emoji: String, color: NSColor) -> CGImage? {
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
        return cached("i|\(first)") { drawInitial(first) }
    }

    private static func drawInitial(_ first: Character) -> CGImage? {
        drawCircle(fill: Brand.electricBlue) { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.5, weight: .bold)
            let string = NSAttributedString(string: String(first).uppercased(), attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = string.size()
            string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    /// 只讀檔頭確認照片可用（JPEG / PNG、尺寸合理），不解碼整張圖。
    static func isUsablePhoto(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ $0 as String }),
              type == "public.jpeg" || type == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int
        else { return false }
        return min(width, height) > 8 && max(width, height) <= 4096
    }

    /// 照片：用 ImageIO 直接產生縮圖（不會把大圖完整解碼到記憶體），再裁成正方形。
    /// 直式照片往上裁（人像的臉通常在上半部），避免切到頭。
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
        let x = (thumbnail.width - side) / 2
        let y = (thumbnail.height - side) / 4 // CGImage 座標原點在左上角：往上偏
        return thumbnail.cropping(to: CGRect(x: x, y: y, width: side, height: side))
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
