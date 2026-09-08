import Carbon
import Foundation

/// Global hotkeys via Carbon `RegisterEventHotKey`. Works without Accessibility permission
/// (unlike `NSEvent.addGlobalMonitorForEvents`). Zero dependencies.
///
/// Hotkeys keep firing while our own overlay window is key, so callers must route them
/// through the app state machine rather than acting blindly (see PLAN.md §7).
final class HotKeyManager {
    struct HotKey {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let handler: () -> Void
    }

    /// Well-known hotkey ids. Only `capture` is registered in M0; `send` arrives in M2.
    enum ID: UInt32 {
        case capture = 1   // ⌘⇧A
        case send = 2      // ⌘⇧⏎
    }

    private static let signature: OSType = {
        // 'ANST' as a four-char code.
        let chars: [UInt8] = Array("ANST".utf8)
        return chars.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, hotKey: HotKey)] = [:]

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                manager.fire(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        if status != noErr {
            Log.error("InstallEventHandler failed: \(status)")
        }
    }

    deinit {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Register a hotkey. `keyCode` is a Carbon virtual key code (e.g. `kVK_ANSI_A`),
    /// `modifiers` is a Carbon modifier mask (`cmdKey | shiftKey`).
    @discardableResult
    func register(_ id: ID, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        let hotKey = HotKey(id: id.rawValue, keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), handler: handler)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: hotKey.id)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.error("RegisterEventHotKey(\(id)) failed: \(status)")
            return false
        }
        registered[hotKey.id] = (ref, hotKey)
        return true
    }

    func unregister(_ id: ID) {
        guard let entry = registered.removeValue(forKey: id.rawValue) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    private func fire(id: UInt32) {
        guard let entry = registered[id] else { return }
        DispatchQueue.main.async { entry.hotKey.handler() }
    }
}
