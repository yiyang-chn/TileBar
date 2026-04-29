import Cocoa

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var recorder: HotkeyRecorderWindow?

    /// Tile hotkey was changed via the recorder. AppDelegate persists +
    /// re-registers.
    var onHotkeyChanged: ((HotkeySpec) -> Void)?

    /// Move-to-display modifier prefix was changed via the recorder.
    var onDisplayPrefixChanged: ((NSEvent.ModifierFlags) -> Void)?

    /// User picked "把焦点窗口送到显示器 N" from the menu (1-indexed).
    var onMoveToDisplay: ((Int) -> Void)?

    /// User picked "重新加载配置".
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
        rebuildMenu()
        // Rebuild menu on display add/remove so the per-display items stay
        // in sync with the actual screens.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func handleScreenChange() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let tile = NSMenuItem(title: "立即平铺",
                              action: #selector(tileNow),
                              keyEquivalent: "")
        tile.target = self
        menu.addItem(tile)

        let screens = NSScreen.screens
        if screens.count >= 2 {
            for (i, _) in screens.enumerated() {
                let n = i + 1
                guard n <= 9 else { break }
                let item = NSMenuItem(title: "把焦点窗口送到显示器 \(n)",
                                      action: #selector(moveToDisplayN(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = n
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let setHotkey = NSMenuItem(title: "设置平铺快捷键…",
                                   action: #selector(openTileRecorder),
                                   keyEquivalent: "")
        setHotkey.target = self
        menu.addItem(setHotkey)

        let setPrefix = NSMenuItem(title: "设置移动窗口修饰键…",
                                   action: #selector(openPrefixRecorder),
                                   keyEquivalent: "")
        setPrefix.target = self
        menu.addItem(setPrefix)

        let reload = NSMenuItem(title: "重新加载配置",
                                action: #selector(reloadConfig),
                                keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 TileBar",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
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

    @objc private func moveToDisplayN(_ sender: NSMenuItem) {
        onMoveToDisplay?(sender.tag)
    }

    @objc private func openTileRecorder() {
        if recorder == nil { recorder = HotkeyRecorderWindow() }
        guard let w = recorder else { return }
        w.onSave = { [weak self] spec in self?.onHotkeyChanged?(spec) }
        w.onSaveModifiers = nil
        let cfg = AppConfigStore.load()
        w.show(currentHotkey: AppConfigStore.resolveHotkey(cfg))
    }

    @objc private func openPrefixRecorder() {
        if recorder == nil { recorder = HotkeyRecorderWindow() }
        guard let w = recorder else { return }
        w.onSave = nil
        w.onSaveModifiers = { [weak self] mods in self?.onDisplayPrefixChanged?(mods) }
        let cfg = AppConfigStore.load()
        w.showModifierOnly(currentMods: AppConfigStore.resolveDisplayPrefix(cfg))
    }

    @objc private func reloadConfig() {
        onReloadConfig?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
