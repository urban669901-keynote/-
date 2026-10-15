import AppKit
import DanmakuCore

/// 「相容性測試」：60 秒內持續發送測試彈幕，同時記錄螢幕上所有視窗的層級。
///
/// 使用方式：開始測試 → 切到 Keynote / PowerPoint 開始播放 → 看投影畫面上是否出現測試彈幕
/// → 結束播放回到測試視窗看結果。紀錄檔存在 ~/Library/Logs/URBANDanmaku/，可以拿來回報問題。
final class CompatibilityTest: ObservableObject {
    static let duration = 60
    static let messageInterval = 2

    @Published private(set) var isRunning = false
    @Published private(set) var secondsLeft = 0
    @Published private(set) var liveLines: [String] = []
    @Published private(set) var results: [String] = []
    @Published private(set) var logURL: URL?
    @Published private(set) var displaySummary = CompatibilityTest.describeDisplays()

    /// 發送一則測試彈幕（由 AppModel 提供）。
    var emitTestMessage: ((String) -> Void)?

    private struct Observation {
        var maxLayer: Int
        var overlayLevelAtMax: Int
        var seconds: Int
    }

    private var timer: Timer?
    private var fileHandle: FileHandle?
    private var observations: [String: Observation] = [:]
    private var sentCount = 0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/URBANDanmaku", isDirectory: true)
    }

    // MARK: - 取樣（每秒由 WindowLevelMonitor 呼叫）

    func record(_ snapshot: WindowLevelMonitor.Snapshot) {
        let lines = snapshot.logLines(limit: 10)
        liveLines = lines
        guard isRunning else { return }
        write(lines)

        var seenThisTick = Set<String>()
        for window in snapshot.windows where window.ownerPID != ownPID
            && window.isRegularApp
            && window.coverage(of: snapshot.screen) >= WindowLevelPolicy.coverageThreshold {
            var observation = observations[window.ownerName]
                ?? Observation(maxLayer: window.layer, overlayLevelAtMax: snapshot.overlayLevel, seconds: 0)
            if window.layer >= observation.maxLayer {
                observation.maxLayer = window.layer
                observation.overlayLevelAtMax = snapshot.overlayLevel
            }
            if seenThisTick.insert(window.ownerName).inserted {
                observation.seconds += 1
            }
            observations[window.ownerName] = observation
        }
    }

    // MARK: - 測試流程

    func start(mode: WindowLevelMode) {
        stop(writeResults: false)
        observations = [:]
        results = []
        sentCount = 0
        displaySummary = Self.describeDisplays()
        openLogFile(mode: mode)
        isRunning = true
        secondsLeft = Self.duration
        emitNext()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop(writeResults: Bool = true) {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        isRunning = false
        secondsLeft = 0
        if writeResults {
            results = summarize()
            write(["", "===== 測試結果 ====="] + results)
        }
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func tick() {
        secondsLeft -= 1
        if secondsLeft % Self.messageInterval == 0 {
            emitNext()
        }
        if secondsLeft <= 0 {
            stop()
        }
    }

    private func emitNext() {
        sentCount += 1
        emitTestMessage?("🧪 相容性測試 #\(sentCount)：看得到就代表 OK")
    }

    private func summarize() -> [String] {
        var lines: [String] = []
        if observations.isEmpty {
            lines.append("測試期間沒有偵測到蓋滿螢幕的 App 視窗。")
            lines.append("請在 60 秒內切到 Keynote / PowerPoint 並開始播放，再測一次。")
        }
        for (owner, observation) in observations.sorted(by: { $0.value.seconds > $1.value.seconds }) {
            if observation.overlayLevelAtMax > observation.maxLayer {
                lines.append("✅ \(owner)：全螢幕視窗層級 \(observation.maxLayer)，彈幕層級 \(observation.overlayLevelAtMax) → 彈幕在上方（共 \(observation.seconds) 秒）")
            } else {
                lines.append("⚠️ \(owner)：全螢幕視窗層級 \(observation.maxLayer) ≥ 彈幕層級 \(observation.overlayLevelAtMax) → 彈幕可能被蓋住。請改用「最高層級」或視窗模式播放（見說明文件）。")
            }
        }
        lines.append("")
        lines.append("層級判斷只是理論值；請以投影畫面上有沒有看到「🧪 相容性測試」彈幕為準。")
        lines.append("若 Keynote 播放時看不到：請改用 Keynote「播放 > 在視窗中播放」，或見 docs/TESTING.md。")
        return lines
    }

    // MARK: - 紀錄檔

    private func openLogFile(mode: WindowLevelMode) {
        let directory = Self.logDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("compat-\(formatter.string(from: Date())).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        logURL = url

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        write([
            "URBAN 即時彈幕 相容性測試",
            "App 版本：\(version)",
            "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "視窗層級模式：\(mode.title)",
            "顯示器：\(displaySummary)",
            "",
        ])
    }

    private func write(_ lines: [String]) {
        guard let fileHandle else { return }
        let text = lines.joined(separator: "\n") + "\n"
        try? fileHandle.write(contentsOf: Data(text.utf8))
    }

    /// 顯示器摘要：鏡像到 Apple TV 時，macOS 只會有 1 個「啟用中」的螢幕。
    static func describeDisplays() -> String {
        var onlineCount: UInt32 = 0
        var activeCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        CGGetActiveDisplayList(0, nil, &activeCount)
        let main = CGMainDisplayID()
        let size = CGDisplayBounds(main).size
        let mirrored = CGDisplayIsInMirrorSet(main) != 0
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 1
        var text = "主螢幕 \(Int(size.width))×\(Int(size.height)) pt @\(Int(scale))x｜啟用中 \(activeCount) 個、連線中 \(onlineCount) 個｜鏡像：\(mirrored ? "是" : "否")"
        if activeCount > 1 && !mirrored {
            text += "（目前是延伸桌面；彈幕只會出現在主螢幕）"
        }
        return text
    }
}
