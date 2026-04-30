import AppKit
import ApplicationServices

/// Tracks a freshly-tiled layout and propagates the user's edge drags
/// to adjacent windows. After ⌘⌥T tiles, dragging Chrome's right edge
/// makes Claude/Slack on the right shrink correspondingly; dragging
/// Claude's bottom edge makes Slack's top follow. Lives until the next
/// tile, undo, or app quit replaces it.
///
/// One instance per active tiled state. Each instance registers AX
/// resize/move observers for every tracked window; on event, looks up
/// the window's neighbours from a precomputed adjacency map and
/// resizes them so the tile invariant (no gaps, no overlaps) holds.
final class TileSession {
    private struct Entry {
        let ax: AXUIElement
        let cgWindowID: CGWindowID
        var rect: CGRect
    }

    private var entries: [Entry]
    private var observers: [pid_t: AXObserver] = [:]

    /// AXEnhancedUserInterface state we flipped at start, keyed by pid.
    /// Restored on stop. With EUI=true (the default for Electron apps
    /// like Slack and Claude desktop), AX setSize is silently ignored —
    /// position changes go through, but width/height don't, so edge-
    /// drag propagation would just shift neighbours sideways without
    /// resizing them. We hold EUI=false for the whole session so every
    /// propagation event resizes for real.
    private var disabledEUI: [pid_t: Bool] = [:]

    /// "Across" neighbours: their opposite edge meets ours.
    /// rightNeighbors[A] = windows whose left edge sat at A's right edge.
    /// When A's right edge moves, we slide their left edges to match.
    private var rightNeighbors: [CGWindowID: [CGWindowID]] = [:]
    private var leftNeighbors:  [CGWindowID: [CGWindowID]] = [:]
    private var bottomNeighbors:[CGWindowID: [CGWindowID]] = [:]
    private var topNeighbors:   [CGWindowID: [CGWindowID]] = [:]

    /// "Co-edge" siblings: their *same* edge sits on the same divider
    /// line as ours. When user drags the boundary at x=1103 by grabbing
    /// the top-right window's left edge, both the top-right AND the
    /// bottom-right windows' left edges are on that line — both must
    /// shift, not just the one the user grabbed.
    private var coRightEdge:  [CGWindowID: [CGWindowID]] = [:]
    private var coLeftEdge:   [CGWindowID: [CGWindowID]] = [:]
    private var coBottomEdge: [CGWindowID: [CGWindowID]] = [:]
    private var coTopEdge:    [CGWindowID: [CGWindowID]] = [:]

    /// Generous edge-matching tolerance. Squarify hands out integer-
    /// rounded targets, but apps with min-size constraints (Electron
    /// in particular — Slack, Claude desktop) may end up tens of pixels
    /// off the requested origin. A strict 2px window misses those, so
    /// we use ~10% of typical window width here. False positives are
    /// safe: a window 30px past its neighbour's edge is still
    /// effectively "adjacent" in any layout we'll see.
    private let edgeTolerance: CGFloat = 60

    /// Hard floor so a runaway drag doesn't crush a neighbour to zero.
    private let minSide: CGFloat = 80

    /// Set while we're issuing programmatic resizes to neighbours, to
    /// short-circuit the AX events those resizes themselves trigger.
    private var propagating = false

    init(snapshot: WindowSnapshot) {
        self.entries = snapshot.entries.map {
            Entry(ax: $0.ax, cgWindowID: $0.cgWindowID, rect: $0.rect)
        }
        computeAdjacencies()
    }

    deinit { stop() }

    func start() {
        // Disable EUI for every tracked app first — must happen before
        // any propagation can fire.
        var seenPids = Set<pid_t>()
        for entry in entries {
            var pid: pid_t = 0
            AXUIElementGetPid(entry.ax, &pid)
            guard seenPids.insert(pid).inserted else { continue }
            if let prev = AXWindowMover.setEnhancedUI(pid: pid, false) {
                disabledEUI[pid] = prev
            }
        }

        for entry in entries {
            register(entry)
        }
        Logger.log("TileSession started: \(entries.count) windows tracked")
        // Dump adjacency for debug visibility — easy to tell from the
        // log whether the layout we tracked matches reality.
        for e in entries {
            let r = e.rect
            Logger.log("  wid=\(e.cgWindowID) rect=(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))) "
                + "R→\(rightNeighbors[e.cgWindowID] ?? []) "
                + "B→\(bottomNeighbors[e.cgWindowID] ?? []) "
                + "coL→\(coLeftEdge[e.cgWindowID] ?? []) "
                + "coR→\(coRightEdge[e.cgWindowID] ?? []) "
                + "coT→\(coTopEdge[e.cgWindowID] ?? []) "
                + "coB→\(coBottomEdge[e.cgWindowID] ?? [])")
        }
    }

    func stop() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observers.removeAll()

        // Restore EUI to whatever each app had before we touched it.
        for (pid, prev) in disabledEUI {
            AXWindowMover.setEnhancedUI(pid: pid, prev)
        }
        disabledEUI.removeAll()
    }

    // MARK: - Adjacency

    private func computeAdjacencies() {
        for i in entries.indices {
            for j in entries.indices where i != j {
                let a = entries[i].rect, b = entries[j].rect
                let aID = entries[i].cgWindowID, bID = entries[j].cgWindowID

                // Across neighbours — A's right edge meets B's left edge.
                if abs(a.maxX - b.minX) < edgeTolerance {
                    let yOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
                    if yOverlap > 1 {
                        rightNeighbors[aID, default: []].append(bID)
                        leftNeighbors[bID, default: []].append(aID)
                    }
                }
                // Across neighbours — A's bottom edge meets B's top edge.
                if abs(a.maxY - b.minY) < edgeTolerance {
                    let xOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
                    if xOverlap > 1 {
                        bottomNeighbors[aID, default: []].append(bID)
                        topNeighbors[bID, default: []].append(aID)
                    }
                }
                // Co-edges — same edge on the same divider line. No
                // overlap requirement: in a squarified partition,
                // aligned edges mean the windows belong to the same
                // logical column / row even when they're stacked
                // (so their Y-ranges abut rather than overlap).
                if abs(a.minX - b.minX) < edgeTolerance {
                    coLeftEdge[aID, default: []].append(bID)
                }
                if abs(a.maxX - b.maxX) < edgeTolerance {
                    coRightEdge[aID, default: []].append(bID)
                }
                if abs(a.minY - b.minY) < edgeTolerance {
                    coTopEdge[aID, default: []].append(bID)
                }
                if abs(a.maxY - b.maxY) < edgeTolerance {
                    coBottomEdge[aID, default: []].append(bID)
                }
            }
        }
    }

    // MARK: - AX observer registration

    private func register(_ entry: Entry) {
        var pid: pid_t = 0
        AXUIElementGetPid(entry.ax, &pid)

        let observer: AXObserver
        if let existing = observers[pid] {
            observer = existing
        } else {
            var obs: AXObserver?
            let r = AXObserverCreate(pid, axCallback, &obs)
            guard r == .success, let o = obs else {
                Logger.log("AXObserverCreate failed pid=\(pid) err=\(r.rawValue)")
                return
            }
            observer = o
            observers[pid] = o
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               AXObserverGetRunLoopSource(o),
                               .defaultMode)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // The generic kAXResizedNotification / kAXMovedNotification are
        // the canonical window resize/move signals — kAXWindow* variants
        // exist but are inconsistently delivered across apps.
        let r1 = AXObserverAddNotification(observer, entry.ax,
                                           kAXResizedNotification as CFString, refcon)
        let r2 = AXObserverAddNotification(observer, entry.ax,
                                           kAXMovedNotification as CFString, refcon)
        Logger.log("  observer wid=\(entry.cgWindowID) pid=\(pid) resize=\(r1.rawValue) move=\(r2.rawValue)")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(_ element: AXUIElement) {
        if propagating { return }
        guard let idx = entries.firstIndex(where: { CFEqual($0.ax, element) }) else {
            Logger.log("AX event for unknown element")
            return
        }
        guard let newRect = AXWindowMover.readRect(element) else { return }
        let oldRect = entries[idx].rect
        let cgID = entries[idx].cgWindowID
        Logger.log("AX event wid=\(cgID) old=(\(Int(oldRect.minX)),\(Int(oldRect.minY)),\(Int(oldRect.width)),\(Int(oldRect.height))) new=(\(Int(newRect.minX)),\(Int(newRect.minY)),\(Int(newRect.width)),\(Int(newRect.height)))")

        let dLeft   = newRect.minX - oldRect.minX
        let dRight  = newRect.maxX - oldRect.maxX
        let dTop    = newRect.minY - oldRect.minY
        let dBottom = newRect.maxY - oldRect.maxY

        // Pure translation (whole-window move): both opposite edges
        // shifted by the same amount → ignore. The tile is broken either
        // way; let the user re-tile if they want it back.
        let widthChanged  = abs(dRight - dLeft) > 0.5
        let heightChanged = abs(dBottom - dTop) > 0.5
        if !widthChanged && !heightChanged {
            entries[idx].rect = newRect
            return
        }

        entries[idx].rect = newRect
        propagating = true
        defer { propagating = false }

        if widthChanged && abs(dRight) > 0.5 {
            // Across — windows to my right slide their left edges.
            shiftLeftEdge(of: rightNeighbors[cgID] ?? [], to: newRect.maxX)
            // Co — windows whose right edge was on the same divider
            // (typically my row-mates in the same column) move with me.
            shiftRightEdge(of: coRightEdge[cgID] ?? [], to: newRect.maxX)
        }
        if widthChanged && abs(dLeft) > 0.5 {
            shiftRightEdge(of: leftNeighbors[cgID] ?? [], to: newRect.minX)
            shiftLeftEdge(of: coLeftEdge[cgID] ?? [], to: newRect.minX)
        }
        if heightChanged && abs(dBottom) > 0.5 {
            shiftTopEdge(of: bottomNeighbors[cgID] ?? [], to: newRect.maxY)
            shiftBottomEdge(of: coBottomEdge[cgID] ?? [], to: newRect.maxY)
        }
        if heightChanged && abs(dTop) > 0.5 {
            shiftBottomEdge(of: topNeighbors[cgID] ?? [], to: newRect.minY)
            shiftTopEdge(of: coTopEdge[cgID] ?? [], to: newRect.minY)
        }
    }

    // MARK: - Edge propagation

    private func shiftLeftEdge(of ids: [CGWindowID], to newLeft: CGFloat) {
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.cgWindowID == id }) else { continue }
            var r = entries[i].rect
            let oldRight = r.maxX
            r.origin.x = newLeft
            r.size.width = max(minSide, oldRight - newLeft)
            apply(r, to: i)
        }
    }

    private func shiftRightEdge(of ids: [CGWindowID], to newRight: CGFloat) {
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.cgWindowID == id }) else { continue }
            var r = entries[i].rect
            r.size.width = max(minSide, newRight - r.minX)
            apply(r, to: i)
        }
    }

    private func shiftTopEdge(of ids: [CGWindowID], to newTop: CGFloat) {
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.cgWindowID == id }) else { continue }
            var r = entries[i].rect
            let oldBottom = r.maxY
            r.origin.y = newTop
            r.size.height = max(minSide, oldBottom - newTop)
            apply(r, to: i)
        }
    }

    private func shiftBottomEdge(of ids: [CGWindowID], to newBottom: CGFloat) {
        for id in ids {
            guard let i = entries.firstIndex(where: { $0.cgWindowID == id }) else { continue }
            var r = entries[i].rect
            r.size.height = max(minSide, newBottom - r.minY)
            apply(r, to: i)
        }
    }

    /// Move the neighbour to `target` and refresh its stored rect from
    /// the actual post-move geometry — apps may clamp due to min-size
    /// constraints, and we want stored == actual so the next AX event
    /// for the same window can be filtered as a no-op.
    private func apply(_ target: CGRect, to entryIndex: Int) {
        let cgID = entries[entryIndex].cgWindowID
        Logger.log("apply wid=\(cgID) target=(\(Int(target.minX)),\(Int(target.minY)),\(Int(target.width)),\(Int(target.height)))")
        AXWindowMover.move(entries[entryIndex].ax, to: target)
        if let actual = AXWindowMover.readRect(entries[entryIndex].ax) {
            entries[entryIndex].rect = actual
            Logger.log("  → actual=(\(Int(actual.minX)),\(Int(actual.minY)),\(Int(actual.width)),\(Int(actual.height)))")
        } else {
            entries[entryIndex].rect = target
            Logger.log("  → readRect failed, using target")
        }
    }
}

// MARK: - C callback

private func axCallback(_ observer: AXObserver,
                        _ element: AXUIElement,
                        _ notification: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    Logger.log("axCallback fired notif=\(notification as String)")
    guard let refcon = refcon else { return }
    let session = Unmanaged<TileSession>.fromOpaque(refcon).takeUnretainedValue()
    // Call directly — we're already on the main runloop (registered there
    // in `register(_:)`). Async-dispatching captured `element` past the
    // callback boundary is a CF lifetime hazard.
    session.handleEvent(element)
}
