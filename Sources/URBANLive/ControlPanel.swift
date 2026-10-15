import AppKit
import DanmakuCore
import SwiftUI

/// 控制面板：四個分頁，關閉後彈幕服務仍在背景執行（選單列可隨時再打開）。
struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var openCompatibilityTest: () -> Void

    var body: some View {
        TabView {
            SessionTab(model: model, settings: settings)
                .tabItem { Text("場次") }
            AppearanceTab(model: model, settings: settings)
                .tabItem { Text("外觀與預覽") }
            ModerationTab(model: model, settings: settings)
                .tabItem { Text("管理") }
            AdvancedTab(model: model, settings: settings, openCompatibilityTest: openCompatibilityTest)
                .tabItem { Text("快捷鍵與進階") }
        }
        .padding(16)
        .frame(width: 760, height: 660)
    }
}

// MARK: - 場次

private struct SessionTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    private var statusText: String {
        guard let session = model.session else { return "尚未開始" }
        let remaining = Int(session.remaining(now: model.clock))
        let time = String(format: "%d:%02d:%02d", remaining / 3600, (remaining % 3600) / 60, remaining % 60)
        switch model.liveState {
        case .live: return "彈幕進行中 · 剩餘 \(time)"
        case .paused: return "已暫停 · 剩餘 \(time)"
        case .hidden: return "彈幕已隱藏 · 剩餘 \(time)"
        case .ended: return "尚未開始"
        }
    }

    private var statusColor: Color {
        switch model.liveState {
        case .live: return .green
        case .paused, .hidden: return .orange
        case .ended: return .secondary
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                    Text(statusText).font(.title2).bold()
                    Spacer()
                    Text("URBAN LIVE").font(.headline).foregroundColor(Color(nsColor: Brand.royalBlue))
                }

                HStack(spacing: 10) {
                    if model.session == nil {
                        Button {
                            model.startSession()
                        } label: {
                            Label("開始彈幕", systemImage: "play.fill").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button {
                            model.togglePause()
                        } label: {
                            Label(model.paused ? "恢復彈幕" : "暫停彈幕", systemImage: model.paused ? "play.fill" : "pause.fill")
                                .frame(minWidth: 110)
                        }
                        .controlSize(.large)
                        Button {
                            model.toggleOverlayHidden()
                        } label: {
                            Label(model.overlayHidden ? "顯示彈幕" : "隱藏彈幕", systemImage: model.overlayHidden ? "eye" : "eye.slash")
                                .frame(minWidth: 100)
                        }
                        .controlSize(.large)
                        Button {
                            model.clearScreen()
                        } label: {
                            Label("清空彈幕", systemImage: "trash").frame(minWidth: 90)
                        }
                        .controlSize(.large)
                        Spacer()
                        Button {
                            model.endSession()
                        } label: {
                            Label("結束場次", systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                    }
                    Button {
                        model.sendTestMessage()
                    } label: {
                        Label("測試彈幕", systemImage: "text.bubble")
                    }
                    .controlSize(.large)
                }

                GroupBox(label: Label("QR Code 與連線網址", systemImage: "qrcode")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(settings.qrVisible && !model.largeQR ? "隱藏 QR Code" : "顯示 QR Code") {
                                model.largeQR = false
                                settings.qrVisible.toggle()
                            }
                            Button(model.largeQR ? "縮回角落" : "切換大型 QR Code") {
                                model.largeQR.toggle()
                            }
                            Button("複製連結") { model.copyPhoneURL() }
                                .disabled(model.phoneURL == nil)
                            Button("重新產生場次連結") { model.regenerateLink() }
                                .disabled(model.session == nil)
                        }
                        if let url = model.phoneURL {
                            Text(url).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        } else if model.session == nil {
                            Text("按「開始彈幕」後產生場次連結與 QR Code").foregroundColor(.secondary)
                        } else {
                            Text("⚠️ 找不到可用的網路位址").foregroundColor(.orange)
                        }
                        HStack(spacing: 16) {
                            Text("Mac 區域網路 IP：\(model.currentInterface?.address ?? "無")")
                            if model.interfaces.count > 1 {
                                Picker("網路介面", selection: Binding(
                                    get: { model.currentInterface?.name ?? "" },
                                    set: { name in model.choose(interface: model.interfaces.first { $0.name == name }) }
                                )) {
                                    ForEach(model.interfaces, id: \.name) { interface in
                                        Text(interface.label).tag(interface.name)
                                    }
                                }
                                .frame(width: 320)
                            }
                        }
                        .font(.callout)
                        .foregroundColor(.secondary)
                        if case let .failed(message) = model.serverState {
                            Text("⚠️ 伺服器啟動失敗：\(message)").foregroundColor(.red)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("即時狀態", systemImage: "chart.bar")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        StatTile(title: "連線中的手機", value: model.stats.connected)
                        StatTile(title: "已收到", value: model.stats.received)
                        StatTile(title: "已顯示", value: model.stats.shown)
                        StatTile(title: "被擋下", value: model.stats.rejected)
                        StatTile(title: "畫面上", value: model.stats.onScreen)
                        StatTile(title: "排隊中", value: model.stats.queued)
                        StatTile(title: "未顯示（逾時/清空）", value: model.stats.dropped)
                        VStack {
                            Button("清空等待佇列") { model.clearQueue() }
                                .disabled(model.stats.queued == 0)
                        }
                    }
                    .padding(6)
                }

                DisclosureGroup("手機連不上？") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.connectionHints, id: \.self) { hint in
                            Text("• " + hint).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
            }
            .padding(4)
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 外觀與預覽

private struct AppearanceTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var background: PreviewBackground = .dark

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Label("即時預覽（1080p 畫面縮小 50%）", systemImage: "eye")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("預覽背景", selection: $background) {
                            ForEach(PreviewBackground.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        Image(nsImage: PreviewRenderer.image(settings: settings, background: background))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(8)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("彈幕樣式", systemImage: "paintpalette")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("樣式", selection: $settings.style) {
                            ForEach(DanmakuStyle.allCases, id: \.self) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        SliderRow(title: "字體大小", value: $settings.fontSize, range: 32...72, step: 2,
                                  display: "\(Int(settings.fontSize)) px")
                        SliderRow(title: "移動速度", value: Binding(
                            get: { -settings.crossingSeconds },
                            set: { settings.crossingSeconds = (-$0).rounded() }
                        ), range: -16...(-6), step: 1, display: "通過約 \(Int(settings.crossingSeconds)) 秒")
                        SliderRow(title: "不透明度", value: $settings.opacity, range: 0.3...1, step: 0.05,
                                  display: "\(Int((settings.opacity * 100).rounded()))%")
                        Text("字體大小以 1920×1080 為基準；Mac 螢幕解析度不同時會等比例換算，投影出來的比例一致。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("顯示區域與數量", systemImage: "rectangle.split.3x1")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("顯示區域", selection: $settings.area) {
                            ForEach(DisplayArea.allCases, id: \.self) { area in
                                Text(area.title).tag(area)
                            }
                        }
                        .pickerStyle(.segmented)
                        Stepper("同時最多顯示 \(settings.maxConcurrent) 則（其餘排隊）", value: $settings.maxConcurrent, in: 1...12)
                        Toggle("顯示暱稱", isOn: $settings.showNickname)
                        Toggle("顯示大頭貼", isOn: $settings.showAvatar)
                        Toggle("允許觀眾上傳照片當大頭貼（關閉時只能選 Emoji 大頭貼）", isOn: $settings.allowPhotoAvatar)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("QR Code", systemImage: "qrcode")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("小型 QR 位置", selection: $settings.qrPosition) {
                            ForEach(QRPosition.allCases, id: \.self) { position in
                                Text(position.title).tag(position)
                            }
                        }
                        .pickerStyle(.segmented)
                        SliderRow(title: "QR 大小", value: $settings.qrSize, range: 140...400, step: 10,
                                  display: "\(Int(settings.qrSize)) px")
                    }
                    .padding(6)
                }

                HStack {
                    Button("發送測試彈幕") { model.sendTestMessage() }
                    Spacer()
                    Button("外觀恢復預設值") { settings.resetAppearance() }
                }
            }
            .padding(4)
        }
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
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(display).monospacedDigit().frame(width: 120, alignment: .trailing)
        }
    }
}

enum PreviewBackground: String, CaseIterable {
    case dark
    case light
    case photo

    var title: String {
        switch self {
        case .dark: return "深色投影片"
        case .light: return "白色投影片"
        case .photo: return "照片背景"
        }
    }
}

/// 即時預覽：把三則範例彈幕畫在模擬的投影片背景上（1080p 的一半大小）。
enum PreviewRenderer {
    static func image(settings: Settings, background: PreviewBackground) -> NSImage {
        let size = NSSize(width: 960, height: 300)
        let previewScale: CGFloat = 0.5
        let fontSize = CGFloat(settings.fontSize) * previewScale
        let samples = [Samples.messages[0], Samples.messages[2], Samples.messages[3]]
        let rendered: [RenderedDanmaku] = samples.compactMap { sample in
            let avatar: CGImage?
            if let emoji = sample.avatarEmoji {
                avatar = AvatarFactory.emojiAvatar(emoji, color: NSColor(hexString: sample.avatarColor) ?? Brand.electricBlue)
            } else {
                avatar = sample.nickname.flatMap(AvatarFactory.initialAvatar)
            }
            let content = DanmakuContent(
                text: sample.text,
                nickname: settings.showNickname ? sample.nickname : nil,
                avatar: settings.showAvatar ? avatar : nil
            )
            return DanmakuRenderer.render(content, style: settings.style, fontSize: fontSize, scale: 2, maxBodyWidth: size.width * 0.92)
        }

        return NSImage(size: size, flipped: false) { rect in
            PreviewRenderer.drawBackground(background, in: rect)
            let lane = DanmakuRenderer.laneHeight(style: settings.style, fontSize: fontSize) + fontSize * 0.25
            let xs: [CGFloat] = [40, 520, 160]
            for (index, item) in rendered.enumerated() {
                let y = rect.height - 40 - lane * CGFloat(index + 1) + (lane - item.size.height) / 2
                let frame = CGRect(x: xs[index % xs.count] - item.margin, y: y, width: item.size.width, height: item.size.height)
                NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(settings.opacity))
                NSGraphicsContext.current?.cgContext.draw(item.image, in: frame)
            }
            return true
        }
    }

    private static func drawBackground(_ background: PreviewBackground, in rect: NSRect) {
        switch background {
        case .dark:
            NSColor(hex: 0x0F172A).setFill()
            rect.fill()
            text("2026 Q4 業績目標", size: 34, color: .white, at: CGPoint(x: 40, y: rect.height - 70))
            NSColor(white: 1, alpha: 0.15).setFill()
            NSRect(x: 40, y: rect.height - 92, width: 300, height: 4).fill()
        case .light:
            NSColor.white.setFill()
            rect.fill()
            text("2026 Q4 業績目標", size: 34, color: NSColor(hex: 0x111827), at: CGPoint(x: 40, y: rect.height - 70))
            NSColor(hex: 0xE5E7EB).setFill()
            NSRect(x: 40, y: 30, width: rect.width - 80, height: 90).fill()
        case .photo:
            let gradient = NSGradient(colors: [NSColor(hex: 0xF59E0B), NSColor(hex: 0xEC4899), NSColor(hex: 0x3B82F6), NSColor(hex: 0x10B981)])
            gradient?.draw(in: rect, angle: 25)
            for index in 0..<14 {
                let d = CGFloat(40 + (index * 37) % 120)
                NSColor(white: index % 2 == 0 ? 1 : 0, alpha: 0.25).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat((index * 131) % 900), y: CGFloat((index * 71) % 260), width: d, height: d)).fill()
            }
        }
    }

    private static func text(_ string: String, size: CGFloat, color: NSColor, at point: CGPoint) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ]).draw(at: point)
    }
}

// MARK: - 管理

private struct ModerationTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Label("最近發言的觀眾（可封鎖）", systemImage: "person.2")) {
                    if model.senders.isEmpty {
                        Text("還沒有人發言").foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    } else {
                        List(model.senders) { record in
                            HStack {
                                Text(record.nickname ?? "（未設定暱稱）").bold().frame(width: 120, alignment: .leading)
                                Text(record.address).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                Text("\(record.count) 則").frame(width: 50)
                                Text(record.lastMessage).lineLimit(1)
                                Spacer()
                                Button("封鎖") { model.block(record) }
                            }
                        }
                        .frame(height: 200)
                    }
                }

                if !model.blocked.isEmpty {
                    GroupBox(label: Label("已封鎖", systemImage: "hand.raised")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.blocked) { record in
                                HStack {
                                    Text(record.nickname ?? "（未設定暱稱）").bold()
                                    Text(record.address).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                                    Spacer()
                                    Button("解除封鎖") { model.unblock(record) }
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox(label: Label("防洗版", systemImage: "shield")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("每位觀眾每 \(Int(settings.cooldown)) 秒最多 1 則", value: $settings.cooldown, in: 1...60, step: 1)
                        Stepper("單則最多 \(settings.maxLength) 字（Emoji 算 1 字）", value: $settings.maxLength, in: 5...60)
                        Stepper(settings.duplicateWindow > 0
                                ? "同一人 \(Int(settings.duplicateWindow)) 秒內不能重複相同內容"
                                : "不限制重複內容",
                                value: $settings.duplicateWindow, in: 0...300, step: 10)
                        Picker("場次有效時間", selection: $settings.sessionHours) {
                            ForEach([1.0, 2, 3, 4, 6, 8, 12], id: \.self) { hours in
                                Text("\(Int(hours)) 小時").tag(hours)
                            }
                        }
                        .frame(width: 260)
                        Text("場次到期後自動結束，手機會收到「場次已結束」。新的場次會產生新的隨機連結。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("敏感詞（一行一個；含有這些字詞的訊息與暱稱會被擋下）", systemImage: "text.badge.xmark")) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: Binding(
                            get: { settings.blockedWords.joined(separator: "\n") },
                            set: { settings.blockedWords = $0.components(separatedBy: .newlines) }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                        HStack {
                            Text("比對時會忽略空白、標點與全形半形差異。").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("恢復預設詞庫") { settings.blockedWords = ContentFilter.defaultWords }
                        }
                    }
                    .padding(6)
                }
            }
            .padding(4)
        }
    }
}

// MARK: - 快捷鍵與進階

private struct AdvancedTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var openCompatibilityTest: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Label("全域快捷鍵（Keynote 全螢幕播放時也有效）", systemImage: "keyboard")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ShortcutAction.allCases, id: \.self) { action in
                            ShortcutRow(action: action, model: model, settings: settings)
                        }
                        HStack {
                            Text("按「錄製」後按下新的組合（需包含 ⌘、⌃ 或 ⌥），按 Esc 取消。")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("快捷鍵恢復預設") { settings.resetShortcuts() }
                        }
                    }
                    .padding(6)
                }

                GroupBox(label: Label("視窗層級與相容性", systemImage: "square.stack.3d.up")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("視窗層級", selection: $settings.levelMode) {
                            ForEach(WindowLevelMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .frame(width: 320)
                        Text("「自動」會在偵測到簡報播放視窗使用更高層級時，自動把彈幕墊到它上面。第一次在 Keynote 使用前，請先跑一次相容性測試。")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("開啟相容性測試…", action: openCompatibilityTest)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("外部網址（選用，進階）", systemImage: "globe")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("例如 https://xxxx.trycloudflare.com（留空 = 使用區域網路）", text: $settings.externalBaseURL)
                        Text("手機不在同一個 Wi-Fi 時，可自行用 Cloudflare Tunnel 等工具把本機 \(model.lanURL ?? "http://<Mac IP>:8765") 轉成外部網址，填在這裡後 QR Code 會改用外部網址。這會讓網際網路上的人也能連到彈幕頁（仍需場次連結），請只在需要時使用。")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("其他", systemImage: "gearshape")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("啟動 App 時打開控制面板", isOn: $settings.openPanelAtLaunch)
                        if case let .ready(port) = model.serverState {
                            Text("伺服器埠號：\(port)（被佔用時會自動換下一個）").font(.callout).foregroundColor(.secondary)
                        }
                        Button("打開紀錄資料夾") {
                            try? FileManager.default.createDirectory(at: CompatibilityTest.logDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(CompatibilityTest.logDirectory)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(4)
        }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(action.title).frame(width: 150, alignment: .leading)
                Text(recording ? "請按下新的組合鍵…" : (settings.shortcuts[action]?.display ?? "未設定"))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 170, alignment: .leading)
                Button(recording ? "取消" : "錄製") {
                    recording ? stopRecording() : startRecording()
                }
                if model.hotkeyFailures.contains(action) {
                    Text("⚠️ 已被其他 App 使用，請換一組").foregroundColor(.orange)
                }
            }
            if let note = settings.shortcuts[action]?.systemConflictNote {
                Text(note).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startRecording() {
        recording = true
        model.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                settings.shortcuts[action] = shortcut
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        model.recordingShortcut = false
    }
}
