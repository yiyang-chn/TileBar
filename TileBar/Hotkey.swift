import Cocoa
import Carbon.HIToolbox

/// A single global hotkey: hardware key code + modifier mask.
struct HotkeySpec: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    static let `default` = HotkeySpec(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: [.command, .option]
    )

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option)  { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// Canonical config string, e.g. "cmd+opt+t".
    func configString() -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option)  { parts.append("opt") }
        if modifiers.contains(.shift)   { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(KeyMap.name(for: keyCode) ?? "?")
        return parts.joined(separator: "+")
    }

    /// Pretty display string with macOS modifier glyphs, e.g. "⌘⌥T".
    func displayString() -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += (KeyMap.name(for: keyCode) ?? "?").uppercased()
        return s
    }

    /// Parse "cmd+opt+t" / "Ctrl+Shift+F1" / etc. Returns nil on any parse
    /// error (unknown token, no modifier, no key).
    static func parse(_ raw: String) -> HotkeySpec? {
        let lowered = raw.lowercased()
        let parts = lowered.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        var keyToken: String?
        for p in parts {
            switch p {
            case "cmd", "command", "⌘":
                mods.insert(.command)
            case "opt", "option", "alt", "⌥":
                mods.insert(.option)
            case "ctrl", "control", "⌃":
                mods.insert(.control)
            case "shift", "⇧":
                mods.insert(.shift)
            default:
                keyToken = p
            }
        }
        guard let k = keyToken,
              let kc = KeyMap.keyCode(for: k),
              !mods.isEmpty else { return nil }
        return HotkeySpec(keyCode: kc, modifiers: mods)
    }
}

/// Bidirectional name↔hardware-keyCode map. Covers letters, digits, common
/// punctuation, function keys, and named keys (space/return/...).
enum KeyMap {
    private static let table: [(name: String, code: UInt32)] = [
        ("a", UInt32(kVK_ANSI_A)), ("b", UInt32(kVK_ANSI_B)), ("c", UInt32(kVK_ANSI_C)),
        ("d", UInt32(kVK_ANSI_D)), ("e", UInt32(kVK_ANSI_E)), ("f", UInt32(kVK_ANSI_F)),
        ("g", UInt32(kVK_ANSI_G)), ("h", UInt32(kVK_ANSI_H)), ("i", UInt32(kVK_ANSI_I)),
        ("j", UInt32(kVK_ANSI_J)), ("k", UInt32(kVK_ANSI_K)), ("l", UInt32(kVK_ANSI_L)),
        ("m", UInt32(kVK_ANSI_M)), ("n", UInt32(kVK_ANSI_N)), ("o", UInt32(kVK_ANSI_O)),
        ("p", UInt32(kVK_ANSI_P)), ("q", UInt32(kVK_ANSI_Q)), ("r", UInt32(kVK_ANSI_R)),
        ("s", UInt32(kVK_ANSI_S)), ("t", UInt32(kVK_ANSI_T)), ("u", UInt32(kVK_ANSI_U)),
        ("v", UInt32(kVK_ANSI_V)), ("w", UInt32(kVK_ANSI_W)), ("x", UInt32(kVK_ANSI_X)),
        ("y", UInt32(kVK_ANSI_Y)), ("z", UInt32(kVK_ANSI_Z)),
        ("0", UInt32(kVK_ANSI_0)), ("1", UInt32(kVK_ANSI_1)), ("2", UInt32(kVK_ANSI_2)),
        ("3", UInt32(kVK_ANSI_3)), ("4", UInt32(kVK_ANSI_4)), ("5", UInt32(kVK_ANSI_5)),
        ("6", UInt32(kVK_ANSI_6)), ("7", UInt32(kVK_ANSI_7)), ("8", UInt32(kVK_ANSI_8)),
        ("9", UInt32(kVK_ANSI_9)),
        ("space", UInt32(kVK_Space)),
        ("return", UInt32(kVK_Return)), ("enter", UInt32(kVK_Return)),
        ("tab", UInt32(kVK_Tab)),
        ("escape", UInt32(kVK_Escape)), ("esc", UInt32(kVK_Escape)),
        ("delete", UInt32(kVK_Delete)),
        ("f1", UInt32(kVK_F1)), ("f2", UInt32(kVK_F2)), ("f3", UInt32(kVK_F3)),
        ("f4", UInt32(kVK_F4)), ("f5", UInt32(kVK_F5)), ("f6", UInt32(kVK_F6)),
        ("f7", UInt32(kVK_F7)), ("f8", UInt32(kVK_F8)), ("f9", UInt32(kVK_F9)),
        ("f10", UInt32(kVK_F10)), ("f11", UInt32(kVK_F11)), ("f12", UInt32(kVK_F12)),
        (",", UInt32(kVK_ANSI_Comma)), (".", UInt32(kVK_ANSI_Period)),
        (";", UInt32(kVK_ANSI_Semicolon)), ("'", UInt32(kVK_ANSI_Quote)),
        ("[", UInt32(kVK_ANSI_LeftBracket)), ("]", UInt32(kVK_ANSI_RightBracket)),
        ("/", UInt32(kVK_ANSI_Slash)), ("\\", UInt32(kVK_ANSI_Backslash)),
        ("-", UInt32(kVK_ANSI_Minus)), ("=", UInt32(kVK_ANSI_Equal)),
        ("`", UInt32(kVK_ANSI_Grave)),
    ]

    static func keyCode(for name: String) -> UInt32? {
        table.first { $0.name == name }?.code
    }

    static func name(for keyCode: UInt32) -> String? {
        table.first { $0.code == keyCode }?.name
    }
}

/// Owns the single Carbon EventHotKey registration. Re-register to swap
/// hotkeys at runtime; the previous registration is unregistered first.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var installedHandler = false

    /// Carbon four-char code "TLBR" identifying our hotkey events.
    private static let signature: OSType = 0x544C4252

    func register(_ spec: HotkeySpec, action: @escaping () -> Void) {
        installEventHandlerIfNeeded()
        unregister()
        self.handler = action

        let hkID = EventHotKeyID(signature: HotkeyManager.signature, id: 1)
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(spec.keyCode,
                                     spec.carbonModifiers,
                                     hkID,
                                     GetApplicationEventTarget(),
                                     0,
                                     &ref)
        if st == noErr {
            self.hotKeyRef = ref
            Logger.log("hotkey registered: \(spec.configString())")
        } else {
            Logger.log("hotkey register failed (status=\(st)) for \(spec.configString())")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard !installedHandler else { return }
        installedHandler = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.handler?() }
            return noErr
        }, 1, &spec, userData, nil)
    }
}
