import Cocoa

/// Single owner of "tile or undo?" decision-making + debouncing. Both the
/// menu bar click and the global hotkey go through `toggle()`.
final class TilingActions {
    static let shared = TilingActions()

    /// Post-completion lockout. Stops a single physical hotkey from
    /// firing twice (key repeat / contact bounce), without making the
    /// user wait noticeably to re-tile after a real second press.
    private static let debounceAfter: TimeInterval = 0.15

    /// Fired around the synchronous tile/move work. Used by the menu bar
    /// to swap to a "busy" icon so the user has feedback that the press
    /// was received even when the work blocks the main runloop.
    var onBusyChanged: ((Bool) -> Void)?

    /// Fired when a tile attempt was rolled back due to overlap (windows
    /// can't all fit on the display). Subscriber typically surfaces a
    /// toast so the user knows why ⌘⌥T appeared to do nothing.
    var onTileFailed: (() -> Void)?

    private var pre: WindowSnapshot?
    private var post: WindowSnapshot?
    private var session: TileSession?
    private var inFlight = false

    /// Replace the active TileSession with a fresh one wrapping `snap`.
    /// Always call after a successful tile so edge-drag propagation
    /// tracks the new layout.
    private func replaceSession(with snap: WindowSnapshot) {
        session?.stop()
        let s = TileSession(snapshot: snap)
        s.start()
        session = s
    }

    /// Drop the active session — the layout is no longer valid (undone,
    /// or about to be re-tiled).
    private func clearSession() {
        session?.stop()
        session = nil
    }

    /// Smart toggle: if the user hasn't moved any window since the last tile,
    /// undo. Otherwise tile fresh.
    func toggle() {
        guard !inFlight else { Logger.log("toggle dropped: still busy"); return }
        inFlight = true
        onBusyChanged?(true)
        defer {
            onBusyChanged?(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceAfter) {
                self.inFlight = false
            }
        }

        if let post = post,
           let pre = pre,
           TilingPipeline.currentMatches(post) {
            clearSession()
            TilingPipeline.restore(pre)
            self.pre = nil
            self.post = nil
            return
        }
        clearSession()
        guard let result = TilingPipeline.runTile() else {
            // Tile rolled back (overlap detected). Clear stale toggle
            // state so the next ⌘⌥T tries fresh, and surface the failure.
            self.pre = nil
            self.post = nil
            onTileFailed?()
            return
        }
        self.pre = result.pre
        self.post = result.post
        replaceSession(with: result.post)
    }

    /// Force a fresh tile, regardless of toggle state. Used by the explicit
    /// "立即平铺" menu item.
    func tileNow() {
        guard !inFlight else { Logger.log("tileNow dropped: still busy"); return }
        inFlight = true
        onBusyChanged?(true)
        defer {
            onBusyChanged?(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceAfter) {
                self.inFlight = false
            }
        }
        clearSession()
        guard let result = TilingPipeline.runTile() else {
            self.pre = nil
            self.post = nil
            onTileFailed?()
            return
        }
        self.pre = result.pre
        self.post = result.post
        replaceSession(with: result.post)
    }

    /// Send the focused window to the display physically positioned in
    /// `direction` from the current one (left/right/up/down per the System
    /// Settings → Displays arrangement). No-op if there's no display in
    /// that direction. Same atomicity guarantees as moveFocusedToDisplay.
    ///
    /// Captures the focused window ONCE and reuses the snapshot for both
    /// the direction calculation and the move. Querying AX's focused-window
    /// attribute twice in quick succession has been observed to put some
    /// apps (Tencent WeChat) into a state where the second query returns a
    /// reference whose moves get silently undone — single-query is more
    /// reliable.
    func moveFocusedInDirection(_ direction: SpatialDirection) {
        Logger.log("hotkey: direction \(direction)")
        guard !inFlight else { Logger.log("  dropped: still busy"); return }
        guard NSScreen.screens.count >= 2 else { Logger.log("  single display"); return }
        inFlight = true
        onBusyChanged?(true)
        defer {
            onBusyChanged?(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceAfter) {
                self.inFlight = false
            }
        }
        guard let focused = MoveActions.captureFocused() else { Logger.log("  no focused window"); return }
        guard let target = MoveActions.directionTarget(direction, from: focused) else { return }
        runMoveAndRetile(focused: focused, dstIndex: target)
    }

    /// Send the focused window to display N (1-indexed) AND re-tile every
    /// affected display. The toggle state is updated atomically:
    ///   - `pre`  = the user's arrangement BEFORE the move (so the next ⌘⌥T
    ///              undoes the whole compound operation in one shot)
    ///   - `post` = the final tiled state after the auto-retile
    /// If only one display is connected, the action is a no-op.
    func moveFocusedToDisplay(_ index: Int) {
        Logger.log("hotkey: digit \(index)")
        guard !inFlight else { Logger.log("  dropped: still busy"); return }
        guard NSScreen.screens.count >= 2 else { Logger.log("  single display"); return }
        inFlight = true
        onBusyChanged?(true)
        defer {
            onBusyChanged?(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceAfter) {
                self.inFlight = false
            }
        }
        guard let focused = MoveActions.captureFocused() else { Logger.log("  no focused window"); return }
        runMoveAndRetile(focused: focused, dstIndex: index)
    }

    /// Shared "capture pre-snapshot, move, retile, update toggle state"
    /// path used by both moveFocusedToDisplay and moveFocusedInDirection.
    /// `inFlight` is assumed already held by the caller.
    private func runMoveAndRetile(focused: FocusedWindow, dstIndex: Int) {
        clearSession()
        let preSnap = TilingPipeline.snapshot()
        MoveActions.move(focused, toDisplay: dstIndex)
        let postSnap: WindowSnapshot
        if let result = TilingPipeline.runTile() {
            postSnap = result.post
        } else {
            postSnap = TilingPipeline.snapshot()
        }
        self.pre = preSnap
        self.post = postSnap
        replaceSession(with: postSnap)
    }
}
