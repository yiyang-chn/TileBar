import Cocoa

/// Single owner of "tile or undo?" decision-making + debouncing. Both the
/// menu bar click and the global hotkey go through `toggle()`.
final class TilingActions {
    static let shared = TilingActions()

    private var pre: WindowSnapshot?
    private var post: WindowSnapshot?
    private var inFlight = false

    /// Smart toggle: if the user hasn't moved any window since the last tile,
    /// undo. Otherwise tile fresh.
    func toggle() {
        guard !inFlight else { return }
        inFlight = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.inFlight = false }
        }

        if let post = post,
           let pre = pre,
           TilingPipeline.currentMatches(post) {
            TilingPipeline.restore(pre)
            self.pre = nil
            self.post = nil
            return
        }
        guard let result = TilingPipeline.runTile() else { return }
        self.pre = result.pre
        self.post = result.post
    }

    /// Force a fresh tile, regardless of toggle state. Used by the explicit
    /// "立即平铺" menu item.
    func tileNow() {
        guard !inFlight else { return }
        inFlight = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.inFlight = false }
        }
        guard let result = TilingPipeline.runTile() else { return }
        self.pre = result.pre
        self.post = result.post
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
        guard !inFlight else { Logger.log("  inFlight, skipping"); return }
        guard NSScreen.screens.count >= 2 else { Logger.log("  single display"); return }
        inFlight = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.inFlight = false }
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
        guard !inFlight else { Logger.log("  inFlight, skipping"); return }
        guard NSScreen.screens.count >= 2 else { Logger.log("  single display"); return }
        inFlight = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.inFlight = false }
        }
        guard let focused = MoveActions.captureFocused() else { Logger.log("  no focused window"); return }
        runMoveAndRetile(focused: focused, dstIndex: index)
    }

    /// Shared "capture pre-snapshot, move, retile, update toggle state"
    /// path used by both moveFocusedToDisplay and moveFocusedInDirection.
    /// `inFlight` is assumed already held by the caller.
    private func runMoveAndRetile(focused: FocusedWindow, dstIndex: Int) {
        let preSnap = TilingPipeline.snapshot()
        MoveActions.move(focused, toDisplay: dstIndex)
        if let result = TilingPipeline.runTile() {
            self.pre = preSnap
            self.post = result.post
        } else {
            self.pre = preSnap
            self.post = TilingPipeline.snapshot()
        }
    }
}
