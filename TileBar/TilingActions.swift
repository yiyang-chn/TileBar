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

    /// Send the focused window to display N (1-indexed) AND re-tile every
    /// affected display. The toggle state is updated atomically:
    ///   - `pre`  = the user's arrangement BEFORE the move (so the next ⌘⌥T
    ///              undoes the whole compound operation in one shot)
    ///   - `post` = the final tiled state after the auto-retile
    /// If only one display is connected, the action is a no-op.
    func moveFocusedToDisplay(_ index: Int) {
        guard !inFlight else { return }
        guard NSScreen.screens.count >= 2 else { return }
        inFlight = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.inFlight = false }
        }
        let preSnap = TilingPipeline.snapshot()
        MoveActions.moveFocusedWindowToDisplay(index: index)
        // Re-tile both displays so the receiving display absorbs the new
        // window into its layout and the source display closes the gap.
        if let result = TilingPipeline.runTile() {
            self.pre = preSnap
            self.post = result.post
        } else {
            self.pre = preSnap
            self.post = TilingPipeline.snapshot()
        }
    }
}
