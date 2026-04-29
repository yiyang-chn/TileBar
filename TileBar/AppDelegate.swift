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
        menuBar.onHotkeyChanged = { [weak self] spec in self?.applyNewTileHotkey(spec) }
        menuBar.onDisplayPrefixChanged = { [weak self] mods in self?.applyNewDisplayPrefix(mods) }
        menuBar.onMoveToDisplay = { idx in TilingActions.shared.moveFocusedToDisplay(idx) }
        menuBar.onMoveByDelta = { delta in TilingActions.shared.moveFocusedByDelta(delta) }
        menuBar.onReloadConfig = { [weak self] in self?.reloadConfig() }
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
        registerDisplayHotkeys()
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

        // Directional cycling: prefix + ←/→ for prev/next display, with wrap.
        let directions: [(name: String, delta: Int)] = [("left", -1), ("right", +1)]
        for (name, delta) in directions {
            guard let kc = KeyMap.keyCode(for: name) else { continue }
            let spec = HotkeySpec(keyCode: kc, modifiers: mods)
            if let id = HotkeyManager.shared.register(spec, action: {
                TilingActions.shared.moveFocusedByDelta(delta)
            }) {
                displayHotkeyIDs.append(id)
            }
        }
    }

    private func reloadConfig() {
        currentConfig = AppConfigStore.load()
        registerAllHotkeys()
        Logger.log("config reloaded")
    }

    private func applyNewTileHotkey(_ spec: HotkeySpec) {
        currentConfig.hotkey = spec.configString()
        AppConfigStore.save(currentConfig)
        registerTileHotkey()
    }

    private func applyNewDisplayPrefix(_ mods: NSEvent.ModifierFlags) {
        currentConfig.moveToDisplayPrefix = HotkeySpec.formatModifiers(mods)
        AppConfigStore.save(currentConfig)
        registerDisplayHotkeys()
    }

    private func ensureAXTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: true]
        if AXIsProcessTrustedWithOptions(opts) { return }

        let a = NSAlert()
        a.messageText = "TileBar 需要 Accessibility 权限"
        a.informativeText = "请在『系统设置 → 隐私与安全性 → 辅助功能』中勾选 TileBar，然后回到这里。"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "稍后")
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
