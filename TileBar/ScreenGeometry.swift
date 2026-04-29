import Cocoa

/// Display-related geometry helpers. Centralizes NS↔CG coordinate
/// translation and "which display is this rect on?" decisions so the rest
/// of the codebase doesn't have to remember which axis is flipped.
enum ScreenGeometry {
    /// Height (in points) of NSScreen.screens[0] — the screen with the
    /// menu bar. Needed for NS→CG y-axis flipping because all NS coords
    /// are expressed relative to that screen's bottom-left.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Convert a rect from NS coordinates (bottom-left origin, primary-relative)
    /// to CG coordinates (top-left origin, primary-relative).
    static func nsToCG(_ ns: CGRect) -> CGRect {
        CGRect(x: ns.minX,
               y: primaryHeight - ns.maxY,
               width: ns.width,
               height: ns.height)
    }

    /// CG-coordinate visibleFrame for a screen (already excludes menu bar
    /// and Dock).
    static func cgVisibleFrame(of screen: NSScreen) -> CGRect {
        nsToCG(screen.visibleFrame)
    }

    /// CG-coordinate full frame for a screen.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        nsToCG(screen.frame)
    }

    /// Find the screen that contains the largest area of `cgRect`. Returns
    /// nil only if the rect intersects no screen at all (window dragged
    /// fully off-screen).
    static func screenContaining(_ cgRect: CGRect) -> NSScreen? {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let intersect = cgFrame(of: s).intersection(cgRect)
            if intersect.isNull { continue }
            let area = intersect.width * intersect.height
            if area > bestArea {
                bestArea = area
                bestScreen = s
            }
        }
        return bestScreen
    }

    /// 1-indexed position of `screen` in `NSScreen.screens`. Matches the
    /// numbering shown in System Settings → Displays → Arrangement when you
    /// hold Option.
    static func displayIndex(of screen: NSScreen) -> Int? {
        NSScreen.screens.firstIndex(of: screen).map { $0 + 1 }
    }

    /// Equiproportional remap of a window from one visibleFrame to another.
    /// A window taking 50% of the source's width and 100% of its height ends
    /// up taking 50% × 100% of the destination's visibleFrame, in the same
    /// relative spot. Both rects in CG coordinates.
    static func remap(_ winCG: CGRect, from srcVF: CGRect, to dstVF: CGRect) -> CGRect {
        let srcW = max(srcVF.width, 1)
        let srcH = max(srcVF.height, 1)
        let relX = (winCG.minX - srcVF.minX) / srcW
        let relY = (winCG.minY - srcVF.minY) / srcH
        let relW = winCG.width / srcW
        let relH = winCG.height / srcH
        return CGRect(x: dstVF.minX + relX * dstVF.width,
                      y: dstVF.minY + relY * dstVF.height,
                      width: relW * dstVF.width,
                      height: relH * dstVF.height)
    }
}
