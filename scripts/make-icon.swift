// 產生 App 圖示（AppIcon.iconset），由 build-app.sh 呼叫：swift scripts/make-icon.swift <輸出資料夾>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let u = size / 1024

    // macOS 圖示外框：四周留白 100，圓角約 22%
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x123B8A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x2563EB), color(0x123B8A), color(0x102A5B)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // 彈幕飛過的光軌
    for (index, y) in [CGFloat(700), 330, 250].enumerated() {
        let width = [CGFloat(420), 300, 200][index] * u
        let x = [CGFloat(330), 560, 220][index] * u
        let streak = CGRect(x: x, y: y * u, width: width, height: 22 * u)
        context.addPath(CGPath(roundedRect: streak, cornerWidth: 11 * u, cornerHeight: 11 * u, transform: nil))
        context.setFillColor(color(0xFFFFFF, index == 0 ? 0.22 : 0.16))
        context.fillPath()
    }
    context.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    // URBAN
    let urban = NSAttributedString(string: "URBAN", attributes: [
        .font: NSFont.systemFont(ofSize: 150 * u, weight: .black),
        .foregroundColor: NSColor.white,
        .kern: 6 * u,
    ])
    let urbanSize = urban.size()
    urban.draw(at: CGPoint(x: size / 2 - urbanSize.width / 2, y: 520 * u))

    // 玻璃膠囊 + LIVE
    let capsule = CGRect(x: 232 * u, y: 380 * u, width: 560 * u, height: 150 * u)
    context.addPath(CGPath(roundedRect: capsule, cornerWidth: 75 * u, cornerHeight: 75 * u, transform: nil))
    context.setFillColor(color(0xF5FAFF))
    context.fillPath()
    let dot: CGFloat = 46 * u
    context.setFillColor(color(0xF3C969))
    context.fillEllipse(in: CGRect(x: capsule.minX + 62 * u, y: capsule.midY - dot / 2, width: dot, height: dot))
    let live = NSAttributedString(string: "LIVE", attributes: [
        .font: NSFont.systemFont(ofSize: 112 * u, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0x12 / 255.0, green: 0x3B / 255.0, blue: 0x8A / 255.0, alpha: 1),
        .kern: 10 * u,
    ])
    let liveSize = live.size()
    live.draw(at: CGPoint(x: capsule.minX + 140 * u + (capsule.width - 180 * u - liveSize.width) / 2, y: capsule.midY - liveSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in variants {
    guard let data = drawIcon(pixels: pixels) else { fatalError("無法產生 \(name)") }
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
print("✅ 已產生圖示：\(output)")
