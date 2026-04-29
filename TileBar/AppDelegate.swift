import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
        ensureAXTrust()
        Logger.log("launched")
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
