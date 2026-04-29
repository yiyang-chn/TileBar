import Cocoa

/// One of the four spatial directions used by the "move focused window in
/// direction X" hotkeys/menu items. Maps to the physical arrangement set
/// up in System Settings → Displays.
enum SpatialDirection {
    case left, right, up, down
}

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

    /// Find the screen positioned in `direction` from `src` based on the
    /// physical arrangement (NSScreen frames in CG coordinates). Requires
    /// perpendicular overlap, so a screen purely diagonal from `src` won't
    /// match either of the two perpendicular directions. Among multiple
    /// candidates, prefers the one with the largest perpendicular overlap;
    /// ties broken by smallest distance.
    static func screen(_ direction: SpatialDirection, from src: NSScreen) -> NSScreen? {
        let srcFrame = cgFrame(of: src)
        var best: (screen: NSScreen, overlap: CGFloat, distance: CGFloat)?
        for s in NSScreen.screens where s !== src {
            let f = cgFrame(of: s)
            let directionMatches: Bool
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                directionMatches = f.midX < srcFrame.midX
                distance = abs(srcFrame.minX - f.maxX)
                overlap = max(0, min(srcFrame.maxY, f.maxY) - max(srcFrame.minY, f.minY))
            case .right:
                directionMatches = f.midX > srcFrame.midX
                distance = abs(f.minX - srcFrame.maxX)
                overlap = max(0, min(srcFrame.maxY, f.maxY) - max(srcFrame.minY, f.minY))
            case .up:
                directionMatches = f.midY < srcFrame.midY
                distance = abs(srcFrame.minY - f.maxY)
                overlap = max(0, min(srcFrame.maxX, f.maxX) - max(srcFrame.minX, f.minX))
            case .down:
                directionMatches = f.midY > srcFrame.midY
                distance = abs(f.minY - srcFrame.maxY)
                overlap = max(0, min(srcFrame.maxX, f.maxX) - max(srcFrame.minX, f.minX))
            }
            guard directionMatches, overlap > 0 else { continue }
            if let cur = best {
                if overlap > cur.overlap
                    || (overlap == cur.overlap && distance < cur.distance) {
                    best = (s, overlap, distance)
                }
            } else {
                best = (s, overlap, distance)
            }
        }
        return best?.screen
    }

    /// True if any screen in the layout has a neighbour in `direction`.
    /// Used by the menu to decide whether the directional item is worth
    /// showing at all.
    static func anyDisplayHasNeighbour(_ direction: SpatialDirection) -> Bool {
        for s in NSScreen.screens {
            if screen(direction, from: s) != nil { return true }
        }
        return false
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
