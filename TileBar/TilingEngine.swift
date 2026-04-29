import Cocoa

struct TileResult {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let cgRect: CGRect
    let target: CGRect
}

enum TilingEngine {
    static func tile(_ items: [(WindowInfo, Double)], in bounds: CGRect) -> [TileResult] {
        guard !items.isEmpty else { return [] }
        let weighted = items.map { ($0.0, max($0.1, 1e-3)) }
        let total = weighted.map(\.1).reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        let scaled = weighted
            .sorted { $0.1 > $1.1 }
            .map { ($0.0, $0.1 / total * area) }

        var rects: [(WindowInfo, CGRect)] = []
        squarify(scaled, in: bounds, out: &rects)

        return rects.map { pair in
            TileResult(pid: pair.0.pid,
                       cgWindowID: pair.0.cgWindowID,
                       cgRect: pair.0.bounds,
                       target: pair.1.integral)
        }
    }

    private static func squarify(_ items: [(WindowInfo, Double)],
                                 in initialRect: CGRect,
                                 out: inout [(WindowInfo, CGRect)]) {
        var rect = initialRect
        var queue = items
        var row: [(WindowInfo, Double)] = []

        while !queue.isEmpty {
            let head = queue[0]
            let side = Double(min(rect.width, rect.height))
            if side <= 0 { break }

            let withHead = row + [head]
            let w1 = worstAspect(row, side: side)
            let w2 = worstAspect(withHead, side: side)

            if row.isEmpty || w2 <= w1 {
                row.append(head)
                queue.removeFirst()
            } else {
                rect = placeRow(row, in: rect, out: &out)
                row.removeAll()
            }
        }

        if !row.isEmpty {
            _ = placeRow(row, in: rect, out: &out, isLast: true)
        }
    }

    private static func worstAspect(_ row: [(WindowInfo, Double)], side: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let areas = row.map { $0.1 }
        let s = areas.reduce(0, +)
        guard s > 0 else { return .infinity }
        let rmax = areas.max() ?? 0
        let rmin = max(areas.min() ?? 0, 1e-9)
        let s2 = s * s
        let w2 = side * side
        return max(w2 * rmax / s2, s2 / (w2 * rmin))
    }

    private static func placeRow(_ row: [(WindowInfo, Double)],
                                 in rect: CGRect,
                                 out: inout [(WindowInfo, CGRect)],
                                 isLast: Bool = false) -> CGRect {
        let totalArea = row.reduce(0.0) { $0 + $1.1 }
        guard totalArea > 0 else { return rect }
        let shortSide = Double(min(rect.width, rect.height))
        guard shortSide > 0 else { return rect }
        var stripThickness = totalArea / shortSide

        if rect.width <= rect.height {
            // strip across the top, items laid out along x
            let widthD = Double(rect.width)
            if isLast { stripThickness = Double(rect.height) }
            stripThickness = min(stripThickness, Double(rect.height))
            let y = Double(rect.minY)
            let h = stripThickness
            var x = Double(rect.minX)
            for (i, item) in row.enumerated() {
                let w = item.1 / totalArea * widthD
                var r = CGRect(x: x, y: y, width: w, height: h)
                if i == row.count - 1 {
                    r = CGRect(x: x, y: y, width: Double(rect.maxX) - x, height: h)
                }
                out.append((item.0, r))
                x += w
            }
            return CGRect(x: rect.minX,
                          y: rect.minY + CGFloat(h),
                          width: rect.width,
                          height: rect.height - CGFloat(h))
        } else {
            // strip down the left, items laid out along y
            let heightD = Double(rect.height)
            if isLast { stripThickness = Double(rect.width) }
            stripThickness = min(stripThickness, Double(rect.width))
            let x = Double(rect.minX)
            let w = stripThickness
            var y = Double(rect.minY)
            for (i, item) in row.enumerated() {
                let h = item.1 / totalArea * heightD
                var r = CGRect(x: x, y: y, width: w, height: h)
                if i == row.count - 1 {
                    r = CGRect(x: x, y: y, width: w, height: Double(rect.maxY) - y)
                }
                out.append((item.0, r))
                y += h
            }
            return CGRect(x: rect.minX + CGFloat(w),
                          y: rect.minY,
                          width: rect.width - CGFloat(w),
                          height: rect.height)
        }
    }
}

struct WindowSnapshot {
    struct Entry {
        let ax: AXUIElement
        let cgWindowID: CGWindowID
        let rect: CGRect
    }
    let entries: [Entry]
}

enum TilingPipeline {
    private static let maxIterations = 10
    /// A window is "overflowing" when its actual size exceeds the target by
    /// more than this many pixels along either axis. Electron apps have
    /// min-sizes that the algorithm only approaches asymptotically, so a
    /// few-pixel slack avoids spinning forever for "almost there" layouts.
    private static let overflowSlack: CGFloat = 10

    /// Tile all visible app windows on the main screen. Returns the (pre, post)
    /// snapshots: `pre` is the state before tiling (used for undo), `post` is
    /// the actual state after tiling+reflow (used to detect "the user has not
    /// moved any window since we tiled").
    @discardableResult
    static func runTile() -> (pre: WindowSnapshot, post: WindowSnapshot)? {
        guard AXIsProcessTrusted() else { Logger.log("no AX trust"); return nil }
        guard let screen = NSScreen.main else { Logger.log("no main screen"); return nil }
        let vf = screen.visibleFrame, sf = screen.frame
        let cgBounds = CGRect(x: vf.minX, y: sf.height - vf.maxY,
                              width: vf.width, height: vf.height)

        let wins = WindowEnumerator.visibleAppWindows()
        guard !wins.isEmpty else { Logger.log("no windows"); return nil }

        let pre = capturePairs(for: wins)
        guard !pre.entries.isEmpty else { return nil }
        let widToAX = Dictionary(uniqueKeysWithValues: pre.entries.map { ($0.cgWindowID, $0.ax) })

        // Disable AXEnhancedUserInterface for the whole batch — this is what
        // forces Electron apps (Slack/Claude/Discord) to actually obey
        // setSize. Restore at the end via defer.
        let pidsTouched = Set(wins.map { $0.pid })
        var prevEUI: [pid_t: Bool] = [:]
        for pid in pidsTouched {
            if let prev = AXWindowMover.setEnhancedUI(pid: pid, false) {
                prevEUI[pid] = prev
            }
        }
        defer {
            for (pid, prev) in prevEUI {
                AXWindowMover.setEnhancedUI(pid: pid, prev)
            }
        }

        var weights: [CGWindowID: Double] = [:]
        for w in wins { weights[w.cgWindowID] = ContentMeasurer.weight(for: w) }

        var prevOverflowPx = CGFloat.infinity
        for attempt in 1...maxIterations {
            let items = wins.compactMap { w -> (WindowInfo, Double)? in
                guard widToAX[w.cgWindowID] != nil else { return nil }
                return (w, weights[w.cgWindowID] ?? 1.0)
            }
            let plan = TilingEngine.tile(items, in: cgBounds)
            for t in plan {
                guard let ax = widToAX[t.cgWindowID] else { continue }
                AXWindowMover.move(ax, to: t.target)
            }
            var overflows = 0
            var overflowPx: CGFloat = 0
            for t in plan {
                guard let ax = widToAX[t.cgWindowID],
                      let actual = AXWindowMover.readRect(ax) else { continue }
                let ovW = max(0, actual.width - t.target.width)
                let ovH = max(0, actual.height - t.target.height)
                if ovW > overflowSlack || ovH > overflowSlack {
                    let factor = Double(actual.width * actual.height)
                                / max(1, Double(t.target.width * t.target.height))
                    weights[t.cgWindowID] = (weights[t.cgWindowID] ?? 1.0) * factor
                    overflows += 1
                    overflowPx += ovW + ovH
                }
            }
            if overflows == 0 {
                Logger.log("tile converged in \(attempt)")
                break
            }
            // Early exit: stop only when the total overflow PIXEL magnitude
            // isn't getting meaningfully smaller (< 5% improvement). Counting
            // overflowing windows alone is too coarse: a stubborn-but-shrinking
            // overflow shouldn't trigger a give-up.
            if overflowPx > prevOverflowPx * 0.95 {
                Logger.log("tile stalled at \(attempt) (overflows=\(overflows) px=\(Int(overflowPx)))")
                break
            }
            prevOverflowPx = overflowPx
            if attempt == maxIterations {
                Logger.log("tile gave up after \(attempt) (overflows=\(overflows) px=\(Int(overflowPx)))")
            }
        }

        let post = WindowSnapshot(entries: pre.entries.compactMap { e in
            AXWindowMover.readRect(e.ax).map {
                WindowSnapshot.Entry(ax: e.ax, cgWindowID: e.cgWindowID, rect: $0)
            }
        })
        return (pre, post)
    }

    /// Restore each window in `snapshot` to its stored rect. Silently skips
    /// windows whose AXUIElement is no longer valid (closed, app quit, etc.).
    static func restore(_ snapshot: WindowSnapshot) {
        // Same EUI dance as runTile: undo would also be ignored by Electron
        // apps without disabling enhanced UI for the move.
        let pids = Set(pidsFor(snapshot))
        var prev: [pid_t: Bool] = [:]
        for pid in pids {
            if let p = AXWindowMover.setEnhancedUI(pid: pid, false) { prev[pid] = p }
        }
        defer {
            for (pid, p) in prev { AXWindowMover.setEnhancedUI(pid: pid, p) }
        }
        for e in snapshot.entries {
            AXWindowMover.move(e.ax, to: e.rect)
        }
        Logger.log("restored \(snapshot.entries.count) windows")
    }

    private static func pidsFor(_ snap: WindowSnapshot) -> [pid_t] {
        snap.entries.compactMap { e in
            var pid: pid_t = 0
            return AXUIElementGetPid(e.ax, &pid) == .success ? pid : nil
        }
    }

    /// True if every window in `snapshot` is currently within `tolerance`
    /// pixels of where the snapshot says it was. Used by the smart toggle to
    /// decide tile vs. undo.
    static func currentMatches(_ snapshot: WindowSnapshot, tolerance: CGFloat = 12) -> Bool {
        for e in snapshot.entries {
            guard let cur = AXWindowMover.readRect(e.ax) else { return false }
            if abs(cur.minX - e.rect.minX) > tolerance
                || abs(cur.minY - e.rect.minY) > tolerance
                || abs(cur.width - e.rect.width) > tolerance
                || abs(cur.height - e.rect.height) > tolerance {
                return false
            }
        }
        return true
    }

    private static func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))"
    }

    /// Pair each WindowInfo with its closest-positioned AXUIElement, deduping
    /// per pid so multiple windows of the same app each get a unique element.
    private static func capturePairs(for wins: [WindowInfo]) -> WindowSnapshot {
        var pools: [pid_t: [(AXUIElement, CGRect)]] = [:]
        for pid in Set(wins.map { $0.pid }) {
            pools[pid] = AXWindowMover.snapshotWindows(pid: pid)
        }
        var entries: [WindowSnapshot.Entry] = []
        for w in wins {
            guard var pool = pools[w.pid], !pool.isEmpty else { continue }
            let idx = pool.indices.min { l, r in
                hypot(pool[l].1.minX - w.bounds.minX, pool[l].1.minY - w.bounds.minY)
                    < hypot(pool[r].1.minX - w.bounds.minX, pool[r].1.minY - w.bounds.minY)
            }!
            entries.append(.init(ax: pool[idx].0, cgWindowID: w.cgWindowID, rect: pool[idx].1))
            pool.remove(at: idx)
            pools[w.pid] = pool
        }
        return WindowSnapshot(entries: entries)
    }
}
