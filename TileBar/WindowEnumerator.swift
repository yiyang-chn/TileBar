import Cocoa

struct WindowInfo {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let bundleID: String?
    let ownerName: String
    let bounds: CGRect
}

enum WindowEnumerator {
    private static let ownerBlacklist: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "WindowManager", "Wallpaper",
        "TileBar"
    ]

    static func visibleAppWindows() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let activeFrame = NSScreen.main?.frame ?? .zero

        return list.compactMap { d -> WindowInfo? in
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = d[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let owner = d[kCGWindowOwnerName as String] as? String,
                  !ownerBlacklist.contains(owner),
                  let wid = d[kCGWindowNumber as String] as? CGWindowID,
                  let bDict = d[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { return nil }

            guard rect.width * rect.height > 5000 else { return nil }
            guard rect.intersects(activeFrame) else { return nil }

            let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return WindowInfo(pid: pid, cgWindowID: wid, bundleID: bid,
                              ownerName: owner, bounds: rect)
        }
    }
}
