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

    /// rightNeighbors[A] = windows whose left edge sat at A's right edge
    /// at session start. When A's right edge moves, we slide their left
    /// edges to match. Symmetric for the other three directions.
    private var rightNeighbors: [CGWindowID: [CGWindowID]] = [:]
    private var leftNeighbors:  [CGWindowID: [CGWindowID]] = [:]
    private var bottomNeighbors:[CGWindowID: [CGWindowID]] = [:]
    private var topNeighbors:   [CGWindowID: [CGWindowID]] = [:]

    /// Squarify uses .integral on its output, so neighbouring edges may
    /// differ by ≤1px from rounding. Use a small tolerance when matching
    /// edges.
    private let edgeTolerance: CGFloat = 2

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
        for entry in entries {
            register(entry)
        }
        Logger.log("TileSession started: \(entries.count) windows tracked")
    }

    func stop() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observers.removeAll()
    }

    // MARK: - Adjacency

    private func computeAdjacencies() {
        for i in entries.indices {
            for j in entries.indices where i != j {
                let a = entries[i].rect, b = entries[j].rect
                let aID = entries[i].cgWindowID, bID = entries[j].cgWindowID

                // A's right edge meets B's left edge, with vertical overlap.
                if abs(a.maxX - b.minX) < edgeTolerance {
                    let yOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
                    if yOverlap > 1 {
                        rightNeighbors[aID, default: []].append(bID)
                        leftNeighbors[bID, default: []].append(aID)
                    }
                }
                // A's bottom edge meets B's top edge, with horizontal overlap.
                if abs(a.maxY - b.minY) < edgeTolerance {
                    let xOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
                    if xOverlap > 1 {
                        bottomNeighbors[aID, default: []].append(bID)
                        topNeighbors[bID, default: []].append(aID)
                    }
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
        AXObserverAddNotification(observer, entry.ax,
                                  kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(observer, entry.ax,
                                  kAXWindowMovedNotification as CFString, refcon)
    }

    // MARK: - Event handling

    fileprivate func handleEvent(_ element: AXUIElement) {
        if propagating { return }
        guard let idx = entries.firstIndex(where: { CFEqual($0.ax, element) }) else { return }
        guard let newRect = AXWindowMover.readRect(element) else { return }
        let oldRect = entries[idx].rect
        let cgID = entries[idx].cgWindowID

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
            shiftLeftEdge(of: rightNeighbors[cgID] ?? [], to: newRect.maxX)
        }
        if widthChanged && abs(dLeft) > 0.5 {
            shiftRightEdge(of: leftNeighbors[cgID] ?? [], to: newRect.minX)
        }
        if heightChanged && abs(dBottom) > 0.5 {
            shiftTopEdge(of: bottomNeighbors[cgID] ?? [], to: newRect.maxY)
        }
        if heightChanged && abs(dTop) > 0.5 {
            shiftBottomEdge(of: topNeighbors[cgID] ?? [], to: newRect.minY)
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
        AXWindowMover.move(entries[entryIndex].ax, to: target)
        if let actual = AXWindowMover.readRect(entries[entryIndex].ax) {
            entries[entryIndex].rect = actual
        } else {
            entries[entryIndex].rect = target
        }
    }
}

// MARK: - C callback

private func axCallback(_ observer: AXObserver,
                        _ element: AXUIElement,
                        _ notification: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let session = Unmanaged<TileSession>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        session.handleEvent(element)
    }
}
