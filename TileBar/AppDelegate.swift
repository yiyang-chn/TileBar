import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var trustTimer: Timer?
    private var currentConfig = AppConfig.default
    private var tileHotkeyID: UInt32?
    private var displayHotkeyIDs: [UInt32] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
        menuBar.onSettingsSaved = { [weak self] spec, mods, vim in
            self?.applySettings(spec: spec, mods: mods, vim: vim)
        }
        menuBar.onMoveToDisplay = { idx in TilingActions.shared.moveFocusedToDisplay(idx) }
        menuBar.onMoveInDirection = { dir in TilingActions.shared.moveFocusedInDirection(dir) }
        // Visual feedback while a tile/move is in progress. Bridged here
        // so TilingActions stays UI-agnostic.
        TilingActions.shared.onBusyChanged = { [weak self] busy in
            self?.menuBar.setBusy(busy)
        }
        currentConfig = AppConfigStore.load()
        registerAllHotkeys()
        ensureAXTrust()
        // Re-register the per-display hotkey set whenever displays are
        // added/removed so the digit count matches reality.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        Logger.log("launched")
    }

    @objc private func handleScreenChange() {
        Logger.log("screens changed; re-registering display hotkeys")
        // didChangeScreenParametersNotification fires *before* NSScreen.screens
        // has been updated to reflect the new layout (especially on hot-plug).
        // Defer the actual registration so we read the post-change screen
        // list, not the stale one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.registerDisplayHotkeys()
        }
    }

    private func registerAllHotkeys() {
        registerTileHotkey()
        registerDisplayHotkeys()
    }

    private func registerTileHotkey() {
        if let id = tileHotkeyID { HotkeyManager.shared.unregister(id) }
        let spec = AppConfigStore.resolveHotkey(currentConfig)
        tileHotkeyID = HotkeyManager.shared.register(spec) {
            TilingActions.shared.toggle()
        }
    }

    private func registerDisplayHotkeys() {
        for id in displayHotkeyIDs { HotkeyManager.shared.unregister(id) }
        displayHotkeyIDs.removeAll()
        let screens = NSScreen.screens
        // Single display = no point grabbing the user's ⌘⌥1 globally.
        guard screens.count >= 2 else { return }
        let mods = AppConfigStore.resolveDisplayPrefix(currentConfig)

        // Numbered targets: prefix + 1..N → "send to display N".
        for (i, _) in screens.enumerated() {
            let n = i + 1
            guard n <= 9 else { break }
            guard let kc = KeyMap.keyCode(for: "\(n)") else { continue }
            let spec = HotkeySpec(keyCode: kc, modifiers: mods)
            if let id = HotkeyManager.shared.register(spec, action: {
                TilingActions.shared.moveFocusedToDisplay(n)
            }) {
                displayHotkeyIDs.append(id)
            }
        }

        // Spatial directional moves: prefix + ←/→/↑/↓ → send focused
        // window to the neighbouring display in that physical direction.
        // No-op when no display sits in that direction.
        var directions: [(name: String, dir: SpatialDirection)] = [
            ("left",  .left),
            ("right", .right),
            ("up",    .up),
            ("down",  .down),
        ]
        // Optional Vim-style HJKL aliases for the same four directions.
        // Off by default; enabled via the settings window's checkbox.
        if AppConfigStore.resolveVimKeys(currentConfig) {
            directions.append(contentsOf: [
                ("h", .left),
                ("j", .down),
                ("k", .up),
                ("l", .right),
            ])
        }
        for (name, dir) in directions {
            guard let kc = KeyMap.keyCode(for: name) else { continue }
            let spec = HotkeySpec(keyCode: kc, modifiers: mods)
            if let id = HotkeyManager.shared.register(spec, action: {
                TilingActions.shared.moveFocusedInDirection(dir)
            }) {
                displayHotkeyIDs.append(id)
            }
        }
    }

    /// Apply the bundle of settings produced by the unified Settings
    /// window: persist, then re-register the affected hotkey groups.
    /// Only re-registers what actually changed to avoid taking down a
    /// global hotkey grab unnecessarily.
    private func applySettings(spec: HotkeySpec,
                               mods: NSEvent.ModifierFlags,
                               vim: Bool) {
        let prevHotkey = currentConfig.hotkey
        let prevPrefix = currentConfig.moveToDisplayPrefix
        let prevVim = currentConfig.enableVimKeys ?? false

        currentConfig.hotkey = spec.configString()
        currentConfig.moveToDisplayPrefix = HotkeySpec.formatModifiers(mods)
        currentConfig.enableVimKeys = vim
        AppConfigStore.save(currentConfig)

        if currentConfig.hotkey != prevHotkey {
            registerTileHotkey()
        }
        if currentConfig.moveToDisplayPrefix != prevPrefix || vim != prevVim {
            registerDisplayHotkeys()
        }
    }

    private func ensureAXTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: true]
        if AXIsProcessTrustedWithOptions(opts) { return }

        let a = NSAlert()
        a.messageText = L10n.axTitle
        a.informativeText = L10n.axBody
        a.addButton(withTitle: L10n.axOpenSettings)
        a.addButton(withTitle: L10n.axLater)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            if AXIsProcessTrusted() {
                t.invalidate()
                self?.trustTimer = nil
                Logger.log("AX trust granted")
            }
        }
    }
}
