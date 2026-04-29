import Cocoa
import ApplicationServices

/// Snapshot of the currently-focused window across the AX layer. Capture
/// once per user action and pass around — querying AX twice for the same
/// window has been observed to put some apps (notably Tencent WeChat) into
/// a state where the second query returns a stale reference whose moves
/// get silently undone.
struct FocusedWindow {
    let pid: pid_t
    let appName: String
    let win: AXUIElement
    let rect: CGRect
    let screen: NSScreen
    let displayIndex: Int
}

/// One-shot window manipulations that don't go through the tiling pipeline.
enum MoveActions {
    /// Resolve the frontmost app's focused window in one AX traversal.
    static func captureFocused() -> FocusedWindow? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "?"
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedWindowAttribute as CFString,
                                            &winRef) == .success,
              let focused = winRef
        else { return nil }
        let win = focused as! AXUIElement
        guard let rect = AXWindowMover.readRect(win),
              let screen = ScreenGeometry.screenContaining(rect)
        else { return nil }
        let dispIdx = ScreenGeometry.displayIndex(of: screen) ?? 0
        return FocusedWindow(pid: pid, appName: appName, win: win,
                             rect: rect, screen: screen, displayIndex: dispIdx)
    }

    /// Resolve the 1-indexed display sitting in `direction` from where
    /// `focused` currently lives. Returns nil if no neighbour exists or
    /// the focused window's screen isn't in `NSScreen.screens` anymore.
    static func directionTarget(_ direction: SpatialDirection,
                                from focused: FocusedWindow) -> Int? {
        guard let dstScreen = ScreenGeometry.screen(direction, from: focused.screen),
              let dstIdx = NSScreen.screens.firstIndex(of: dstScreen)
        else {
            Logger.log("no display in direction \(direction) from display \(focused.displayIndex)")
            return nil
        }
        return dstIdx + 1
    }

    /// Move the captured focused window to display `dstIndex` (1-indexed).
    /// Equiproportional remap within visibleFrame. AX first; on apps that
    /// silently undo AX moves (Tencent NSWindow handlers), fall back to
    /// `CGSMoveWindow` (private SPI) to force the position. Position-only —
    /// resizing will be reconciled by the auto-retile pass.
    static func move(_ focused: FocusedWindow, toDisplay dstIndex: Int) {
        let screens = NSScreen.screens
        guard dstIndex >= 1, dstIndex <= screens.count else {
            Logger.log("display \(dstIndex) out of range (have \(screens.count))")
            return
        }
        let dstScreen = screens[dstIndex - 1]
        if dstScreen === focused.screen {
            Logger.log("focused window already on display \(dstIndex)")
            return
        }
        let srcVF = ScreenGeometry.cgVisibleFrame(of: focused.screen)
        let dstVF = ScreenGeometry.cgVisibleFrame(of: dstScreen)
        let target = ScreenGeometry.remap(focused.rect, from: srcVF, to: dstVF).integral
        Logger.log("move pid=\(focused.pid) (\(focused.appName)) src=display\(focused.displayIndex) dst=display\(dstIndex) target=\(target)")

        // EUI dance: same workaround as the tile pipeline. Without it,
        // Electron apps reject the size change part of the move.
        let prevEUI = AXWindowMover.setEnhancedUI(pid: focused.pid, false)
        defer {
            if let p = prevEUI { AXWindowMover.setEnhancedUI(pid: focused.pid, p) }
        }

        // Auto-retry AX move up to N times with a short delay between
        // attempts. Tencent WeChat / QQ in particular tend to reject the
        // first AX setPosition attempt (their NSWindow handler snaps the
        // window back), but accept a subsequent one after their handler
        // has settled. Single user action shouldn't require multiple
        // hotkey presses, so we internalize the retry. CG window list is
        // the ground truth for verification — AX readback can lie.
        let maxAttempts = 5
        var landed = false
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                Thread.sleep(forTimeInterval: 0.08)
            }
            AXWindowMover.move(focused.win, to: target)
            if let cgRect = cgWindowRect(forPid: focused.pid, near: target),
               let actualScreen = ScreenGeometry.screenContaining(cgRect) {
                let actualIdx = ScreenGeometry.displayIndex(of: actualScreen) ?? 0
                if actualIdx == dstIndex {
                    Logger.log("move OK (AX, attempt \(attempt)): now on display \(dstIndex) at \(cgRect)")
                    landed = true
                    break
                }
            }
        }

        if !landed {
            Logger.log("AX retried \(maxAttempts)× — falling back to CGS")
            // Tencent-style fallback: go straight to WindowServer via the
            // private CGSMoveWindow SPI. Position-only; the size stays
            // whatever it was (sizing will be reconciled by the auto-
            // retile pass that follows this action).
            _ = AXWindowMover.cgsForceMove(focused.win, to: target.origin)
            if let cgRect2 = cgWindowRect(forPid: focused.pid, near: target) {
                let s2 = ScreenGeometry.screenContaining(cgRect2)
                let i2 = s2.flatMap { ScreenGeometry.displayIndex(of: $0) } ?? 0
                if i2 == dstIndex {
                    Logger.log("move OK (CGS): now on display \(dstIndex) at \(cgRect2)")
                } else {
                    Logger.log("move FAILED (AX×\(maxAttempts) and CGS): on display\(i2) at \(cgRect2)")
                }
            }
        }
    }

    /// Find the on-screen window of `pid` whose CG bounds are closest to
    /// `near`. CG window list is the ground truth for actual position
    /// (AX attribute reads can be stale or fabricated).
    private static func cgWindowRect(forPid pid: pid_t, near: CGRect) -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var best: (rect: CGRect, distance: CGFloat)?
        for d in list {
            guard let p = d[kCGWindowOwnerPID as String] as? pid_t, p == pid,
                  let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
                  let bDict = d[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { continue }
            let dist = hypot(r.minX - near.minX, r.minY - near.minY)
            if best == nil || dist < best!.distance {
                best = (r, dist)
            }
        }
        return best?.rect
    }
}
