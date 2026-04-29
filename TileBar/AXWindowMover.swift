import ApplicationServices
import Cocoa

// MARK: - Private CoreGraphics symbols
//
// `_AXUIElementGetWindow` and `CGSMoveWindow` are private SPI used by every
// serious macOS window manager (Yabai, Hammerspoon, Magnet, Rectangle…) to
// forcibly position windows belonging to apps whose own NSWindow controllers
// ignore or undo AX-driven moves. Tencent's WeChat and QQ are the canonical
// examples — their `windowDidMove:` handlers snap the window back to its
// previous position immediately after every AX setPosition call. Going
// through CoreGraphics' WindowServer layer is the only reliable way to
// move them.

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ outWindowID: UnsafeMutablePointer<UInt32>) -> AXError

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSMoveWindow")
private func CGSMoveWindow(_ cid: UInt32,
                           _ wid: UInt32,
                           _ position: UnsafePointer<CGPoint>) -> Int32

enum AXWindowMover {
    /// Toggle the private `AXEnhancedUserInterface` flag for an app. Electron
    /// apps (Slack, Discord, Claude desktop, VS Code, …) with this flag set
    /// to true silently ignore AX-driven resize. Industry-standard workaround
    /// used by Yabai, Rectangle, Magnet, etc.: set to false, do the move,
    /// restore the original value. Returns the previous value (or nil if the
    /// app doesn't expose the attribute).
    @discardableResult
    static func setEnhancedUI(pid: pid_t, _ enabled: Bool) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        var current: CFTypeRef?
        let prev: Bool? = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &current) == .success
            ? (current as? Bool)
            : nil
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, enabled as CFBoolean)
        return prev
    }

    static func snapshotWindows(pid: pid_t) -> [(AXUIElement, CGRect)] {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard err == .success, let wins = raw as? [AXUIElement] else {
            Logger.log("AX windows fetch failed pid=\(pid) err=\(err.rawValue)")
            return []
        }
        return wins.compactMap { w in
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success
            else { return nil }
            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
            return (w, CGRect(origin: p, size: s))
        }
    }

    static func readRect(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Set position, then size, then position again. setSize can re-clamp the
    /// origin if the window has min/max size constraints that conflict with
    /// the requested size; setting position once more pins it to where we
    /// actually want it.
    static func move(_ window: AXUIElement, to target: CGRect) {
        var pos = target.origin
        var sz = target.size

        if let v = AXValueCreate(.cgPoint, &pos) {
            let r = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
            if r != .success { Logger.log("AX setPos(1) err=\(r.rawValue)") }
        }
        if let v = AXValueCreate(.cgSize, &sz) {
            let r = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
            if r != .success { Logger.log("AX setSize err=\(r.rawValue)") }
        }
        if let v = AXValueCreate(.cgPoint, &pos) {
            let r = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
            if r != .success { Logger.log("AX setPos(2) err=\(r.rawValue)") }
        }
    }

    /// Force-move via CGSMoveWindow (private CoreGraphics API). Bypasses
    /// NSWindow's `windowDidMove:` handlers, so it works on apps that
    /// silently undo AX setPosition (Tencent WeChat/QQ, some older Java
    /// apps). Position-only — size still has to go through AX setSize and
    /// will be ignored by stubborn apps.
    @discardableResult
    static func cgsForceMove(_ axWin: AXUIElement, to point: CGPoint) -> Bool {
        var wid: UInt32 = 0
        let r = _AXUIElementGetWindow(axWin, &wid)
        guard r == .success, wid != 0 else {
            Logger.log("CGS: _AXUIElementGetWindow failed err=\(r.rawValue)")
            return false
        }
        let cid = CGSMainConnectionID()
        var p = point
        let result = CGSMoveWindow(cid, wid, &p)
        if result != 0 {
            Logger.log("CGS: CGSMoveWindow returned \(result)")
            return false
        }
        return true
    }
}
