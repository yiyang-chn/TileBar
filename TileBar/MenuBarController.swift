import Cocoa

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

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

        let reset = NSMenuItem(title: "重置", action: nil, keyEquivalent: "")
        reset.isEnabled = false
        menu.addItem(reset)

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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
