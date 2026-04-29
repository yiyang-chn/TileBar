import Cocoa

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var recorder: HotkeyRecorderWindow?

    /// Called when the user wants to change the hotkey. The AppDelegate
    /// handles the actual save+register step.
    var onHotkeyChanged: ((HotkeySpec) -> Void)?

    /// Called when the user picks "重新加载配置". The AppDelegate re-reads
    /// the file and re-registers the hotkey.
    var onReloadConfig: (() -> Void)?

    override init() {
        super.init()
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "square.grid.2x2",
                                accessibilityDescription: "TileBar")
            btn.target = self
            btn.action = #selector(handleClick(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let tile = NSMenuItem(title: "立即平铺", action: #selector(tileNow), keyEquivalent: "")
        tile.target = self
        menu.addItem(tile)

        menu.addItem(.separator())

        let setHotkey = NSMenuItem(title: "设置快捷键…", action: #selector(openRecorder), keyEquivalent: "")
        setHotkey.target = self
        menu.addItem(setHotkey)

        let reload = NSMenuItem(title: "重新加载配置", action: #selector(reloadConfig), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 TileBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
        let isCtrl = event?.modifierFlags.contains(.control) ?? false
        if isRight || isCtrl {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            TilingActions.shared.toggle()
        }
    }

    @objc private func tileNow() {
        TilingActions.shared.tileNow()
    }

    @objc private func openRecorder() {
        if recorder == nil { recorder = HotkeyRecorderWindow() }
        guard let w = recorder else { return }
        w.onSave = { [weak self] spec in
            self?.onHotkeyChanged?(spec)
        }
        let cfg = AppConfigStore.load()
        let current = AppConfigStore.resolveHotkey(cfg)
        w.show(currentHotkey: current)
    }

    @objc private func reloadConfig() {
        onReloadConfig?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
