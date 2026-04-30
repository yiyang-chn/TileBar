import Cocoa

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var settings: SettingsWindow?

    private static let idleIcon = NSImage(systemSymbolName: "square.grid.2x2",
                                          accessibilityDescription: "TileBar")
    private static let busyIcon = NSImage(systemSymbolName: "square.grid.2x2.fill",
                                          accessibilityDescription: "TileBar (busy)")

    /// Settings were saved. AppDelegate persists + re-registers hotkeys.
    var onSettingsSaved: ((HotkeySpec, NSEvent.ModifierFlags, Bool) -> Void)?

    /// User picked "把焦点窗口送到显示器 N" from the menu (1-indexed).
    var onMoveToDisplay: ((Int) -> Void)?

    /// User picked "送到左/右/上/下方显示器" — physical direction in the
    /// current display arrangement.
    var onMoveInDirection: ((SpatialDirection) -> Void)?

    override init() {
        super.init()
        if let btn = statusItem.button {
            btn.image = Self.idleIcon
            btn.target = self
            btn.action = #selector(handleClick(_:))
            // Both buttons open the menu — there's no "click to tile"
            // shortcut anymore. Tiling stays available via the global
            // hotkey and the "立即平铺" / "Tile Now" menu item.
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    /// Swap the menu bar icon between idle and busy. Called synchronously
    /// around the tile/move work in TilingActions; `display()` forces an
    /// immediate redraw so the user sees the change even though the main
    /// runloop is about to block on the AX RPCs.
    func setBusy(_ busy: Bool) {
        guard let btn = statusItem.button else { return }
        btn.image = busy ? Self.busyIcon : Self.idleIcon
        btn.display()
    }

    @objc private func handleScreenChange() {
        // didChangeScreenParametersNotification fires before NSScreen.screens
        // has been updated; defer to read the post-change layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let tile = NSMenuItem(title: L10n.menuTileNow,
                              action: #selector(tileNow),
                              keyEquivalent: "")
        tile.target = self
        menu.addItem(tile)

        let screens = NSScreen.screens
        if screens.count >= 2 {
            for (i, _) in screens.enumerated() {
                let n = i + 1
                guard n <= 9 else { break }
                let item = NSMenuItem(title: L10n.menuMoveToDisplay(n),
                                      action: #selector(moveToDisplayN(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = n
                menu.addItem(item)
            }
            // Directional items, only shown if the current screen layout
            // actually has a neighbour in that direction.
            let directional: [(label: String, dir: SpatialDirection, tag: Int)] = [
                (L10n.menuMoveLeft,  .left,  0),
                (L10n.menuMoveRight, .right, 1),
                (L10n.menuMoveUp,    .up,    2),
                (L10n.menuMoveDown,  .down,  3),
            ]
            for entry in directional where ScreenGeometry.anyDisplayHasNeighbour(entry.dir) {
                let item = NSMenuItem(title: entry.label,
                                      action: #selector(moveInDirection(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = entry.tag
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.menuSettings,
                                      action: #selector(openSettings),
                                      keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.menuQuit,
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func tileNow() {
        TilingActions.shared.tileNow()
    }

    @objc private func moveToDisplayN(_ sender: NSMenuItem) {
        onMoveToDisplay?(sender.tag)
    }

    @objc private func moveInDirection(_ sender: NSMenuItem) {
        let dirs: [SpatialDirection] = [.left, .right, .up, .down]
        guard sender.tag >= 0, sender.tag < dirs.count else { return }
        onMoveInDirection?(dirs[sender.tag])
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindow() }
        guard let w = settings else { return }
        w.onSave = { [weak self] spec, mods, vim in
            self?.onSettingsSaved?(spec, mods, vim)
        }
        let cfg = AppConfigStore.load()
        w.show(currentTile: AppConfigStore.resolveHotkey(cfg),
               currentMod: AppConfigStore.resolveDisplayPrefix(cfg),
               currentVim: AppConfigStore.resolveVimKeys(cfg))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
