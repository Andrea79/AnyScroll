//
//  KeyboardShortcut.swift
//  AnyScroll
//

import Cocoa
import Carbon.HIToolbox

/// A key plus modifiers that starts or stops auto-scroll from anywhere.
struct KeyboardShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    private static let usedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.usedModifiers)
    }

    /// Offered in Settings next to recording one's own.
    static let suggestions = [
        KeyboardShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.control, .option]),
        KeyboardShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option]),
        KeyboardShortcut(keyCode: UInt16(kVK_F6), modifiers: []),
    ]

    /// A plain key (or Shift + key) would be caught while typing, so it needs ⌘, ⌥ or ⌃,
    /// unless it is a function key.
    var isValid: Bool {
        !modifiers.subtracting(.shift).isEmpty || Self.functionKeys[keyCode] != nil
    }

    /// E.g. "⌃⌥S", "F6".
    var displayName: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    private var keyName: String {
        if let name = Self.functionKeys[keyCode] ?? Self.specialKeys[keyCode] { return name }
        return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    private static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    ]

    /// The character the key types with the current keyboard layout, without modifiers.
    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// Whether macOS itself uses this combination (Spotlight, Mission Control, screenshots…).
    /// Shortcuts of other apps can't be detected: macOS lets several apps register the same one.
    var isUsedBySystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return hotKeys.contains { hotKey in
            (hotKey["kHISymbolicHotKeyEnabled"] as? Bool) == true
                && (hotKey["kHISymbolicHotKeyCode"] as? Int) == Int(keyCode)
                && (hotKey["kHISymbolicHotKeyModifiers"] as? Int).map { UInt32($0) & Self.carbonModifierMask } == carbonModifiers
        }
    }

    private static let carbonModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    // MARK: - Storage

    var storedValue: [String: Int] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)]
    }

    init?(storedValue: Any?) {
        guard let value = storedValue as? [String: Int],
              let keyCode = value["keyCode"], let modifiers = value["modifiers"] else { return nil }
        self.init(keyCode: UInt16(keyCode), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
    }

    fileprivate var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}

/// Registers shortcuts with macOS as system-wide hot keys. This needs no permission:
/// AnyScroll is told only when one of these exact combinations is pressed.
@MainActor
final class GlobalHotKey {
    enum Slot: UInt32 {
        case toggle = 1  // the user's shortcut: starts or stops auto-scroll
        case stop = 2    // Esc, registered only while auto-scroll is active
    }

    static let escape = KeyboardShortcut(keyCode: UInt16(kVK_Escape), modifiers: [])

    var onPress: (@MainActor (Slot) -> Void)?
    private var hotKeys: [Slot: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  let slot = Slot(rawValue: id.id) else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.onPress?(slot) }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replaces the shortcut in a slot (nil removes it); false if macOS refused it.
    @discardableResult
    func register(_ shortcut: KeyboardShortcut?, for slot: Slot) -> Bool {
        if let existing = hotKeys.removeValue(forKey: slot) {
            UnregisterEventHotKey(existing)
        }
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x414E_5953), id: slot.rawValue)  // "ANYS"
        guard RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                  GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        hotKeys[slot] = ref
        return true
    }
}
