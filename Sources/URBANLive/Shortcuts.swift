import AppKit
import Carbon.HIToolbox

/// 可以設定全域快捷鍵的動作。
enum ShortcutAction: String, CaseIterable, Codable {
    case toggleOverlay
    case togglePause
    case toggleQRCode
    case clearScreen

    var title: String {
        switch self {
        case .toggleOverlay: return "顯示／隱藏彈幕"
        case .togglePause: return "暫停／恢復"
        case .toggleQRCode: return "顯示／隱藏 QR Code"
        case .clearScreen: return "清空彈幕"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .toggleOverlay: return Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey), key: "B")
        case .togglePause: return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey), key: "P")
        case .toggleQRCode: return Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | shiftKey), key: "Q")
        case .clearScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey | cmdKey), key: "C")
        }
    }
}

/// 一組快捷鍵：Carbon 鍵碼 + Carbon 修飾鍵。
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    /// 依 Apple 慣例的順序顯示：⌃⌥⇧⌘
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// 已知會和系統功能重疊的組合。
    var systemConflictNote: String? {
        if keyCode == UInt32(kVK_ANSI_Q) && modifiers == UInt32(cmdKey | shiftKey) {
            return "⇧⌘Q 也是 macOS「登出」的快捷鍵。URBAN LIVE 執行時通常會優先攔截；若按下後出現登出對話框，請改用其他組合。"
        }
        return nil
    }

    /// 從錄製時按下的按鍵建立（至少要有 ⌘、⌃ 或 ⌥ 其中之一）。
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let character = event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !character.isEmpty, character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, key: character)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// 全域快捷鍵（Carbon `RegisterEventHotKey`）：不需要「輔助使用」權限，
/// 在 Keynote / PowerPoint 全螢幕播放、選單列看不到時也有效。
final class HotKeyManager {
    private static let signature: OSType = 0x5552_424C // 'URBL'

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    manager.handlers[id]?()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        handlers.removeAll()
    }

    /// 註冊一組快捷鍵，回傳註冊失敗（被其他 App 佔用）的動作。
    func register(_ bindings: [(ShortcutAction, Shortcut, () -> Void)]) -> Set<ShortcutAction> {
        unregisterAll()
        var failed = Set<ShortcutAction>()
        for (index, binding) in bindings.enumerated() {
            let (action, shortcut, handler) = binding
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references.append(reference)
                handlers[id] = handler
            } else {
                failed.insert(action)
                NSLog("URBAN LIVE: 無法註冊快捷鍵 \(shortcut.display)（\(status)）")
            }
        }
        return failed
    }
}
