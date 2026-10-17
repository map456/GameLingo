import Carbon
import Foundation

/// 全域快捷鍵。用 Carbon 的 RegisterEventHotKey：不需要「輔助使用」權限，遊戲在前景時也有效。
final class HotkeyService {
    static let shared = HotkeyService()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    private init() {}

    /// 註冊一組快捷鍵。keyCode 用 kVK_ANSI_*，modifiers 用 controlKey | optionKey 這類 Carbon 常數。
    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C_474F), id: id)  // 'GLGO'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            return true
        }
        return false
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyService.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
