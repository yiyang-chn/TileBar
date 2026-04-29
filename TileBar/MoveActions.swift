import Cocoa
import ApplicationServices

/// One-shot window manipulations that don't go through the tiling pipeline.
enum MoveActions {
    /// Compute the 1-indexed target display for the focused window after
    /// shifting `delta` displays (with cyclic wrap-around). Returns nil if
    /// the move can't be resolved (single display, no AX trust, no focused
    /// window, focused window not on any screen).
    static func computeTargetDisplay(delta: Int) -> Int? {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { return nil }
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedWindowAttribute as CFString,
                                            &winRef) == .success,
              let focused = winRef
        else { return nil }
        let win = focused as! AXUIElement
        guard let currentRect = AXWindowMover.readRect(win),
              let srcScreen = ScreenGeometry.screenContaining(currentRect),
              let srcIdx = screens.firstIndex(of: srcScreen) else { return nil }
        let n = screens.count
        // Modulo for negative: ((a % n) + n) % n
        let dstIdx = ((srcIdx + delta) % n + n) % n
        return dstIdx + 1
    }

    /// Move the focused window of the frontmost app to display N (1-indexed
    /// against `NSScreen.screens`). Preserves the window's relative position
    /// and size proportions within visibleFrame, so a window that filled
    /// 60% of the source display ends up filling 60% of the destination.
    /// No-op if:
    ///   - AX permission is missing,
    ///   - there's no frontmost app or no focused window,
    ///   - `index` is out of range,
    ///   - the focused window is already on display `index`.
    static func moveFocusedWindowToDisplay(index: Int) {
        guard AXIsProcessTrusted() else {
            Logger.log("no AX trust"); return
        }
        let screens = NSScreen.screens
        guard index >= 1, index <= screens.count else {
            Logger.log("display \(index) out of range (have \(screens.count))"); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            Logger.log("no frontmost app"); return
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedWindowAttribute as CFString,
                                            &winRef) == .success,
              let focused = winRef
        else {
            Logger.log("no focused window for pid=\(pid)"); return
        }
        let win = focused as! AXUIElement
        guard let currentRect = AXWindowMover.readRect(win) else {
            Logger.log("can't read focused window rect"); return
        }
        guard let srcScreen = ScreenGeometry.screenContaining(currentRect) else {
            Logger.log("focused window on no screen?"); return
        }
        let dstScreen = screens[index - 1]
        if dstScreen === srcScreen {
            Logger.log("focused window already on display \(index)"); return
        }
        let srcVF = ScreenGeometry.cgVisibleFrame(of: srcScreen)
        let dstVF = ScreenGeometry.cgVisibleFrame(of: dstScreen)
        let target = ScreenGeometry.remap(currentRect, from: srcVF, to: dstVF).integral

        // EUI dance: same workaround as the tile pipeline. Without it,
        // Electron apps reject the size change part of the move.
        let prevEUI = AXWindowMover.setEnhancedUI(pid: pid, false)
        defer {
            if let p = prevEUI { AXWindowMover.setEnhancedUI(pid: pid, p) }
        }
        AXWindowMover.move(win, to: target)
        Logger.log("moved focused window (pid=\(pid)) to display \(index)")
    }
}
