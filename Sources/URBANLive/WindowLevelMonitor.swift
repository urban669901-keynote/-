import AppKit
import DanmakuCore

/// 每秒檢查一次螢幕上的視窗，必要時調高 Overlay 層級，並提供診斷資料。
///
/// 為什麼需要：macOS 的全螢幕 Space（瀏覽器、PowerPoint、Keynote 編輯畫面）只要層級 ≥ screenSaver
/// 就能蓋上去；但簡報軟體的「播放視窗」可能使用更高的層級，甚至擷取整個螢幕。
/// 無法事先保證，所以執行時讀取 CGWindowList（不需要螢幕錄製權限：只讀擁有者名稱與層級，不讀內容），
/// 一旦發現一般 App 用更高層級蓋滿螢幕，就把 Overlay 墊到它上面一層。
final class WindowLevelMonitor {
    struct Snapshot {
        var date: Date
        var overlayLevel: Int
        var decision: WindowLevelPolicy.Decision
        var frontmostApp: String
        /// 依層級由高到低排序。
        var windows: [ObservedWindow]
        var screen: CGRect
    }

    static let baseLevel = NSWindow.Level.screenSaver.rawValue
    /// Shielding Window（螢幕被擷取時系統放的遮罩）之上一層。
    static let maximumLevel = Int(CGShieldingWindowLevel()) + 1

    var mode: WindowLevelMode
    /// 層級改變時呼叫（主執行緒）。
    var onLevelChange: ((Int, WindowLevelPolicy.Decision) -> Void)?
    /// 每次取樣後呼叫（主執行緒），給診斷視窗與測試紀錄使用。
    var onSnapshot: ((Snapshot) -> Void)?

    private(set) var currentLevel: Int
    private(set) var lastSnapshot: Snapshot?
    private var timer: Timer?
    private var regularAppCache: [Int32: Bool] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(mode: WindowLevelMode) {
        self.mode = mode
        currentLevel = Self.baseLevel
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.2
        tick()
    }

    func tick() {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let windows = captureWindows()
        let decision = WindowLevelPolicy.decide(
            mode: mode,
            windows: windows,
            screen: screen,
            ownPID: ownPID,
            baseLevel: Self.baseLevel,
            maximumLevel: Self.maximumLevel
        )
        if decision.level != currentLevel {
            currentLevel = decision.level
            onLevelChange?(decision.level, decision)
        }
        let snapshot = Snapshot(
            date: Date(),
            overlayLevel: currentLevel,
            decision: decision,
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
            windows: windows,
            screen: screen
        )
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private func captureWindows() -> [ObservedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [ObservedWindow] = []
        for info in list {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            let pid = pidNumber.int32Value
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            result.append(ObservedWindow(
                ownerName: owner,
                ownerPID: pid,
                layer: layerNumber.intValue,
                bounds: bounds,
                isRegularApp: isRegularApp(pid),
                alpha: alpha
            ))
        }
        return result.sorted { $0.layer > $1.layer }
    }

    private func isRegularApp(_ pid: Int32) -> Bool {
        if let cached = regularAppCache[pid] { return cached }
        let regular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        if regularAppCache.count > 500 { regularAppCache.removeAll() }
        regularAppCache[pid] = regular
        return regular
    }
}

extension WindowLevelMonitor.Snapshot {
    /// 一行文字摘要（寫入相容性測試紀錄）。
    func logLines(limit: Int = 8) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        var lines = ["[\(formatter.string(from: date))] 前景 App：\(frontmostApp)｜彈幕層級：\(overlayLevel)" +
            (decision.raisedAbove.map { "（已墊高到 \($0.ownerName) 之上）" } ?? "")]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows.prefix(limit) {
            let coverage = Int((window.coverage(of: screen) * 100).rounded())
            let kind = window.ownerPID == ownPID ? "本彈幕" : (window.isRegularApp ? "App" : "系統")
            let layer = String(window.layer)
            let paddedLayer = String(repeating: " ", count: max(0, 10 - layer.count)) + layer
            let paddedCoverage = String(repeating: " ", count: max(0, 3 - String(coverage).count)) + String(coverage)
            lines.append("  layer \(paddedLayer)  覆蓋 \(paddedCoverage)%  \(window.ownerName)（\(kind)）")
        }
        return lines
    }
}
