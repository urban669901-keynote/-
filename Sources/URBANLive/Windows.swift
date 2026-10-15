import AppKit
import DanmakuCore
import SwiftUI

/// 用 SwiftUI 內容建立一般視窗（控制面板、相容性測試）。關閉視窗不會結束 App，彈幕服務繼續在背景執行。
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
            // 先讓 SwiftUI 算出內容尺寸再置中，否則小螢幕上視窗會超出畫面
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

struct CompatibilityView: View {
    @ObservedObject var test: CompatibilityTest
    @ObservedObject var settings: Settings
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keynote / PowerPoint 相容性測試").font(.title2).bold()
            Text("""
            1. 按「開始 60 秒測試」，畫面上會每 2 秒出現一則「🧪 相容性測試」彈幕。
            2. 立刻切到 Keynote（或 PowerPoint、PDF、瀏覽器）開始全螢幕播放。
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
                        .buttonStyle(.borderedProminent)
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
        .frame(width: 640)
    }
}
