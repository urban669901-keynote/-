// FullscreenProbe：CI / 開發用的測試工具，不隨 App 發佈。
//
// 模擬「簡報軟體」的各種全螢幕方式，讓我們在 macOS 上實際截圖驗證彈幕 Overlay 是否蓋在上面：
//
//   FullscreenProbe show fullscreen      原生全螢幕 Space（瀏覽器 YouTube、PowerPoint、Keynote 編輯畫面）
//   FullscreenProbe show level:1000      一般 App 用螢幕保護程式層級蓋滿螢幕（簡報播放視窗的常見做法）
//   FullscreenProbe show shielding       一般 App 用 Shielding 層級蓋滿螢幕
//   FullscreenProbe show capture         CGDisplayCapture 擷取整個螢幕（舊版 Keynote 的做法）
//   FullscreenProbe analyze shot.png     分析截圖：紅色 = 測試視窗、藍色膠囊 = 彈幕
//   FullscreenProbe qr shot.png          解碼截圖中的 QR Code（確認畫面上的 QR Code 真的掃得出來）
//   FullscreenProbe photos <dir> <N>     產生 N 張彼此不同的 320×320 人像測試照片（JPEG，壓力測試用）
//
// analyze 的結束代碼：0 = 彈幕可見、1 = 測試視窗可見但彈幕不可見、2 = 截圖裡看不到測試視窗（無法判斷）
import AppKit
import CoreImage
import ImageIO

let probeColor = NSColor(srgbRed: 0.86, green: 0.10, blue: 0.10, alpha: 1)

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let scenario: String
    let seconds: Double
    var window: NSWindow?
    var captured = false

    init(scenario: String, seconds: Double) {
        self.scenario = scenario
        self.seconds = seconds
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let screen = NSScreen.screens[0]

        switch scenario {
        case "fullscreen":
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "FullscreenProbe"
            window.backgroundColor = probeColor
            window.collectionBehavior = [.fullScreenPrimary]
            window.makeKeyAndOrderFront(nil)
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                window.toggleFullScreen(nil)
            }

        case "capture":
            let result = CGDisplayCapture(CGMainDisplayID())
            captured = result == .success
            print("CGDisplayCapture: \(result.rawValue)")
            showCoveringWindow(level: Int(CGShieldingWindowLevel()), screen: screen)

        case "shielding":
            showCoveringWindow(level: Int(CGShieldingWindowLevel()), screen: screen)

        default:
            if scenario.hasPrefix("level:"), let level = Int(scenario.dropFirst("level:".count)) {
                showCoveringWindow(level: level, screen: screen)
            } else {
                print("未知的情境：\(scenario)")
                exit(64)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.captured { CGDisplayRelease(CGMainDisplayID()) }
            exit(0)
        }
    }

    private func showCoveringWindow(level: Int, screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = probeColor
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.canJoinAllSpaces]
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        print("probe window level \(level) frame \(screen.frame)")
    }
}

/// - Parameters:
///   - minCapsule / minWhite: 判定「彈幕可見」所需的藍色膠囊與白色文字像素數。
///     多則彈幕同時在畫面上時用預設值；只有一則時可調低（--min-capsule / --min-white）。
func analyze(path: String, minCapsule: Int = 1500, minWhite: Int = 1500) -> Int32 {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
        print("[\(path)] 無法讀取截圖")
        return 2
    }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var probe = 0
    var capsule = 0
    var white = 0

    pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var index = 0
    while index < pixels.count {
        let r = Int(pixels[index])
        let g = Int(pixels[index + 1])
        let b = Int(pixels[index + 2])
        if r > 150 && g < 90 && b < 90 {
            probe += 1
        } else if b > 110 && b > r + 40 && b > g + 30 {
            capsule += 1
        } else if r > 225 && g > 225 && b > 225 {
            white += 1
        }
        index += 4
    }

    let total = max(1, width * height)
    let probeRatio = Double(probe) / Double(total)
    let name = URL(fileURLWithPath: path).lastPathComponent
    let summary = String(
        format: "[%@] %dx%d 測試視窗(紅) %.1f%%｜彈幕膠囊(藍) %d px｜白色(文字/QR) %d px",
        name, width, height, probeRatio * 100, capsule, white
    )
    if probeRatio < 0.3 {
        print("⚪️ \(summary) → 截圖中看不到測試視窗，無法判斷（可能沒有螢幕錄製權限）")
        return 2
    }
    if capsule > minCapsule && white > minWhite {
        print("✅ \(summary) → 彈幕在全螢幕視窗上方")
        return 0
    }
    print("❌ \(summary) → 彈幕被蓋住")
    return 1
}

func decodeQR(path: String) -> Int32 {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
        print("無法讀取截圖：\(path)")
        return 2
    }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: image).compactMap { $0 as? CIQRCodeFeature } ?? []
    for feature in features {
        print(feature.messageString ?? "")
    }
    return features.isEmpty ? 1 : 0
}

/// 產生彼此不同的人像測試照片：隨機背景、膚色、髮色、衣服顏色，再加上像真實照片的雜訊，
/// 讓 JPEG 大小接近手機實際上傳的照片（約 20～50 KB），而不是純色圖那種幾 KB。
func makePhotos(directory: String, count: Int) -> Int32 {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return 1 }
    var generator = SystemRandomNumberGenerator()
    func random(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &generator) }
    func color(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> CGColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).cgColor
    }
    let side = 320
    var totalBytes = 0
    for index in 0..<count {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        let size = CGFloat(side)
        let backgroundHue = random(0...1)
        let gradient = CGGradient(colorsSpace: space, colors: [color(backgroundHue, 0.35, 0.95), color(backgroundHue, 0.55, 0.6)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        for _ in 0..<18 { // 背景散景
            context.setFillColor(color(random(0...1), 0.3, 1).copy(alpha: random(0.1...0.35))!)
            let d = random(20...90)
            context.fillEllipse(in: CGRect(x: random(-20...size), y: random(-20...size), width: d, height: d))
        }
        let skin = color(random(0.04...0.09), random(0.25...0.5), random(0.55...0.95))
        context.setFillColor(color(random(0...1), random(0.3...0.8), random(0.2...0.7)))      // 衣服
        context.fillEllipse(in: CGRect(x: 10, y: -150, width: 300, height: 230))
        context.setFillColor(skin)
        context.fill(CGRect(x: 135, y: 60, width: 50, height: 50))                             // 脖子
        let faceWidth = random(105...130)
        context.fillEllipse(in: CGRect(x: 160 - faceWidth / 2, y: 95, width: faceWidth, height: random(135...160))) // 臉
        context.setFillColor(color(random(0.02...0.1), random(0.3...0.8), random(0.08...0.5)))  // 頭髮
        context.fillEllipse(in: CGRect(x: 160 - faceWidth / 2 - 8, y: 175, width: faceWidth + 16, height: random(80...110)))
        context.setFillColor(color(0, 0, 0.12))                                               // 眼睛
        context.fillEllipse(in: CGRect(x: 160 - faceWidth * 0.22 - 6, y: 172, width: 12, height: 12))
        context.fillEllipse(in: CGRect(x: 160 + faceWidth * 0.22 - 6, y: 172, width: 12, height: 12))
        context.setStrokeColor(color(0.0, 0.5, 0.6))
        context.setLineWidth(5)
        context.addArc(center: CGPoint(x: 160, y: 150), radius: 26, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        context.strokePath()

        // 照片雜訊
        if let data = context.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
            for offset in stride(from: 0, to: side * side * 4, by: 4) {
                let noise = Int.random(in: -14...14, using: &generator)
                for channel in 0..<3 {
                    pixels[offset + channel] = UInt8(clamping: Int(pixels[offset + channel]) + noise)
                }
            }
        }
        guard let image = context.makeImage() else { return 1 }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(String(format: "photo-%03d.jpg", index))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return 1 }
        totalBytes += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
    print("已產生 \(count) 張測試照片，平均 \(totalBytes / max(1, count) / 1024) KB")
    return 0
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：FullscreenProbe show <fullscreen|level:N|shielding|capture> [--seconds N]\n      FullscreenProbe analyze <png>\n      FullscreenProbe qr <png>")
    exit(64)
}

switch arguments[1] {
case "analyze":
    func option(_ name: String, _ fallback: Int) -> Int {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count, let value = Int(arguments[index + 1]) else { return fallback }
        return value
    }
    exit(analyze(path: arguments[2], minCapsule: option("--min-capsule", 1500), minWhite: option("--min-white", 1500)))
case "qr":
    exit(decodeQR(path: arguments[2]))
case "photos":
    exit(makePhotos(directory: arguments[2], count: arguments.count > 3 ? Int(arguments[3]) ?? 200 : 200))
case "show":
    var seconds = 8.0
    if let flag = arguments.firstIndex(of: "--seconds"), flag + 1 < arguments.count, let value = Double(arguments[flag + 1]) {
        seconds = value
    }
    let app = NSApplication.shared
    let delegate = ProbeDelegate(scenario: arguments[2], seconds: seconds)
    app.delegate = delegate
    app.run()
default:
    print("未知的指令：\(arguments[1])")
    exit(64)
}
