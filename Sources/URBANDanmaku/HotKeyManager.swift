import Carbon.HIToolbox
import Foundation

/// 全域快捷鍵。Keynote 播放中選單列不會出現，主持人只能靠快捷鍵暫停或清空彈幕。
///
/// 使用 Carbon `RegisterEventHotKey`：不需要「輔助使用」權限，在其他 App 全螢幕時也有效。
final class HotKeyManager {
    struct HotKey {
        let keyCode: Int
        let character: String
        let action: () -> Void
    }

    /// ⌃⌥⌘：一般 App 幾乎不會使用的組合，避免和 Keynote / PowerPoint 衝突。
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x5552_424E // 'URBN'

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private(set) var failed: [String] = []

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
        references.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func register(_ hotKeys: [HotKey]) {
        for (index, hotKey) in hotKeys.enumerated() {
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(hotKey.keyCode),
                Self.modifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references.append(reference)
                handlers[id] = hotKey.action
            } else {
                failed.append(hotKey.character)
                NSLog("URBANDanmaku: 無法註冊快捷鍵 ⌃⌥⌘\(hotKey.character)（\(status)），可能被其他 App 佔用")
            }
        }
    }
}
