import AppKit
import DanmakuCore
import SwiftUI

// MARK: - 設定

struct SettingsView: View {
    @ObservedObject var settings: Settings
    var onPreview: () -> Void

    private var speedBinding: Binding<Double> {
        // 滑桿往右 = 越快 = 通過畫面的秒數越少
        Binding(
            get: { -settings.crossingSeconds },
            set: { settings.crossingSeconds = (-$0).rounded() }
        )
    }

    private var topBinding: Binding<Double> {
        Binding(
            get: { settings.regionTop },
            set: { settings.regionTop = min($0, settings.regionBottom - DisplayRegion.minimumSpan) }
        )
    }

    private var bottomBinding: Binding<Double> {
        Binding(
            get: { settings.regionBottom },
            set: { settings.regionBottom = max($0, settings.regionTop + DisplayRegion.minimumSpan) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Label("彈幕外觀", systemImage: "textformat.size")) {
                VStack(alignment: .leading, spacing: 8) {
                    SliderRow(title: "字體大小", value: $settings.fontSize, range: 24...120, step: 2,
                              display: "\(Int(settings.fontSize)) px")
                    SliderRow(title: "速度", value: speedBinding, range: -20...(-4), step: 1,
                              display: "通過約 \(Int(settings.crossingSeconds)) 秒")
                    SliderRow(title: "不透明度", value: $settings.opacity, range: 0.2...1, step: 0.05,
                              display: "\(Int((settings.opacity * 100).rounded()))%")
                }
                .padding(6)
            }

            GroupBox(label: Label("顯示區域", systemImage: "rectangle.topthird.inset.filled")) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(DisplayRegion.presets, id: \.name) { preset in
                                Button(preset.name) { settings.applyRegion(preset.region) }
                                    .controlSize(.small)
                            }
                        }
                        SliderRow(title: "上緣", value: topBinding, range: 0...0.9, step: 0.01,
                                  display: "\(Int((settings.regionTop * 100).rounded()))%")
                        SliderRow(title: "下緣", value: bottomBinding, range: 0.1...1, step: 0.01,
                                  display: "\(Int((settings.regionBottom * 100).rounded()))%")
                    }
                    RegionPreview(top: settings.regionTop, bottom: settings.regionBottom)
                }
                .padding(6)
            }

            GroupBox(label: Label("QR Code", systemImage: "qrcode")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("在畫面上顯示 QR Code（⌃⌥⌘R）", isOn: $settings.qrVisible)
                    Picker("位置", selection: $settings.qrPosition) {
                        ForEach(QRPosition.allCases, id: \.self) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    SliderRow(title: "大小", value: $settings.qrSize, range: 120...360, step: 10,
                              display: "\(Int(settings.qrSize)) px")
                }
                .padding(6)
            }

            GroupBox(label: Label("進階", systemImage: "square.stack.3d.up")) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("視窗層級", selection: $settings.levelMode) {
                        ForEach(WindowLevelMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text("「自動」會在偵測到簡報播放視窗使用更高層級時，自動把彈幕墊到它上面。若 Keynote 播放時仍看不到彈幕，可改成「最高層級」並用「相容性測試」確認。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            HStack {
                Button("發送預覽彈幕", action: onPreview)
                Spacer()
                Button("恢復預設值") { settings.resetToDefaults() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(display)
                .monospacedDigit()
                .frame(width: 108, alignment: .trailing)
        }
    }
}

/// 16:9 小螢幕示意：藍色區塊是彈幕會出現的範圍。
struct RegionPreview: View {
    var top: Double
    var bottom: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.8))
                Rectangle()
                    .fill(Color(nsColor: Theme.urbanBlue))
                    .frame(width: geometry.size.width, height: geometry.size.height * CGFloat(bottom - top))
                    .offset(y: geometry.size.height * CGFloat(top))
                RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(width: 128, height: 72)
    }
}

// MARK: - 相容性測試

struct CompatibilityView: View {
    @ObservedObject var test: CompatibilityTest
    @ObservedObject var settings: Settings
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keynote / PowerPoint 相容性測試").font(.title2).bold()
            Text("""
            1. 按「開始 60 秒測試」，畫面上會每 2 秒出現一則「🧪 相容性測試」彈幕。
            2. 立刻切到 Keynote（或 PowerPoint、PDF、YouTube）開始播放。
            3. 看 Mac 螢幕與 Apple TV 投影畫面上，測試彈幕是否出現在簡報上方。
            4. 按 Esc 結束播放，回到這裡查看結果與紀錄檔。
            """)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if test.isRunning {
                    Button("停止測試") { test.stop() }
                    Text("剩餘 \(test.secondsLeft) 秒").monospacedDigit().foregroundColor(.secondary)
                } else {
                    Button("開始 60 秒測試", action: onStart)
                }
                Spacer()
                Picker("視窗層級", selection: $settings.levelMode) {
                    ForEach(WindowLevelMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .frame(width: 260)
            }

            Text(test.displaySummary).font(.caption).foregroundColor(.secondary)

            if !test.results.isEmpty {
                GroupBox(label: Text("測試結果")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(test.results.enumerated()), id: \.offset) { item in
                            Text(item.element).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            GroupBox(label: Text("目前螢幕上的視窗（層級由高到低）")) {
                ScrollView {
                    Text(test.liveLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 170)
            }

            HStack {
                if let url = test.logURL {
                    Button("打開紀錄檔") { NSWorkspace.shared.open(url) }
                }
                Button("打開紀錄資料夾") {
                    try? FileManager.default.createDirectory(at: CompatibilityTest.logDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(CompatibilityTest.logDirectory)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

// MARK: - 視窗

/// 用 SwiftUI 內容建立一般視窗（設定、相容性測試）。
final class HostingWindow<Content: View> {
    private let title: String
    private let makeContent: () -> Content
    private var window: NSWindow?

    init(title: String, content: @escaping () -> Content) {
        self.title = title
        makeContent = content
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: makeContent())
            let window = NSWindow(contentViewController: controller)
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        guard let window else { return }
        if !window.isVisible {
            // 先讓 SwiftUI 算出內容尺寸再置中，否則視窗會以 0 寬度置中後往右長、超出小螢幕
            if let view = window.contentViewController?.view {
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                if size.width > 0, size.height > 0 {
                    window.setContentSize(size)
                }
            }
            window.center()
        }
        // accessory App 需要主動啟用，視窗才會出現在最前面
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
