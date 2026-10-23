// System-wide keyboard shortcuts (⌥M, ⌥⇧A) through Carbon's hot-key API.
// Hot keys registered this way need no Accessibility permission.

import AppKit
import Carbon

final class HotKeys {
    static let shared = HotKeys()
    fileprivate var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    /// keyCode is a kVK_* constant; modifiers are Carbon masks (optionKey, shiftKey, cmdKey, controlKey).
    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        installHandler()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464D_4E44), id: id) // 'FMND'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let made = ref else { return false }
        actions[id] = action
        refs.append(made)
        return true
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
