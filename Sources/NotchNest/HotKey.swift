import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that only belongs to NotchNest while it's enabled (e.g. ⌘V while the
/// notch is open). Carbon hot keys need no Accessibility permission and swallow the keystroke,
/// so the app underneath doesn't also paste/copy/select/delete.
@MainActor
final class HotKey {
    private static let signature = OSType(0x4E4E_5354)  // 'NNST'

    private let keyCode: Int
    private let modifiers: Int
    private let id: UInt32
    private let action: () -> Void
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { ref != nil }

    /// `modifiers` are Carbon flags (`cmdKey`, …); 0 means the bare key, e.g. Delete.
    init(keyCode: Int, modifiers: Int = cmdKey, id: UInt32, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.id = id
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            let handled = MainActor.assumeIsolated { hotKey.handle(pressed) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                var newRef: EventHotKeyRef?
                let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                                 EventHotKeyID(signature: Self.signature, id: id),
                                                 GetApplicationEventTarget(), 0, &newRef)
                if status == noErr { ref = newRef } else { ActivityLog.note("shortcut \(id) couldn't register: \(status)") }
            } else if let ref {
                UnregisterEventHotKey(ref)
                self.ref = nil
            }
        }
    }

    private func handle(_ pressed: EventHotKeyID) -> Bool {
        guard pressed.signature == Self.signature, pressed.id == id else { return false }
        action()
        return true
    }
}
