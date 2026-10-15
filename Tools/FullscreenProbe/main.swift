// FullscreenProbe：CI / 開發用的測試工具，不隨 App 發佈。
//
// 模擬「簡報軟體」的各種全螢幕方式，讓我們在 macOS 上實際截圖驗證彈幕 Overlay 是否蓋在上面：
//
//   FullscreenProbe show fullscreen      原生全螢幕 Space（瀏覽器 YouTube、PowerPoint、Keynote 編輯畫面）
//   FullscreenProbe show level:1000      一般 App 用螢幕保護程式層級蓋滿螢幕（簡報播放視窗的常見做法）
//   FullscreenProbe show shielding       一般 App 用 Shielding 層級蓋滿螢幕
//   FullscreenProbe show capture         CGDisplayCapture 擷取整個螢幕（舊版 Keynote 的做法）
//   FullscreenProbe analyze shot.png     分析截圖：紅色 = 測試視窗、藍色膠囊 = 彈幕
//
// analyze 的結束代碼：0 = 彈幕可見、1 = 測試視窗可見但彈幕不可見、2 = 截圖裡看不到測試視窗（無法判斷）
import AppKit
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

func analyze(path: String) -> Int32 {
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
    if capsule > 1500 && white > 1500 {
        print("✅ \(summary) → 彈幕在全螢幕視窗上方")
        return 0
    }
    print("❌ \(summary) → 彈幕被蓋住")
    return 1
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：FullscreenProbe show <fullscreen|level:N|shielding|capture> [--seconds N]\n      FullscreenProbe analyze <png>")
    exit(64)
}

switch arguments[1] {
case "analyze":
    exit(analyze(path: arguments[2]))
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
