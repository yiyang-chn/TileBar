import Cocoa

struct TileResult {
    let pid: pid_t
    let cgWindowID: CGWindowID
    let cgRect: CGRect
    let target: CGRect
}

enum TilingEngine {
    /// Two-stage layout:
    ///   1. Squarify the *weights* into N rectangles. Weight desc input
    ///      keeps aspect ratios close to 1 — Chrome still ends up bigger
    ///      than Terminal.
    ///   2. Assign each input window to the rectangle whose center is
    ///      closest to the window's current center, minimizing total
    ///      squared displacement. This is what makes drag-then-tile
    ///      respect the user's spatial intent: drag Claude to the left
    ///      of Slack, retile, and Claude lands in whatever rectangle
    ///      sits on the left side of the layout.
    ///
    /// The squarify-pairing is incidental — it pairs (window, rect) by
    /// weight order to satisfy the inner algorithm; we drop the pairing
    /// immediately and redo it by proximity.
    static func tile(_ items: [(WindowInfo, Double)], in bounds: CGRect) -> [TileResult] {
        guard !items.isEmpty else { return [] }
        let weighted = items.map { ($0.0, max($0.1, 1e-3)) }
        let total = weighted.map(\.1).reduce(0, +)
        let area = Double(bounds.width * bounds.height)

        // Stage 1: produce target rectangles via squarify. Areas in
        // descending order is what squarify needs internally — it does
        // not have to match the assignment we want at the end.
        let scaledByWeight = weighted
            .sorted { $0.1 > $1.1 }
            .map { ($0.0, $0.1 / total * area) }
        var paired: [(WindowInfo, CGRect)] = []
        squarify(scaledByWeight, in: bounds, out: &paired)
        let rects = paired.map { $0.1 }

        // Stage 2: assign windows to rectangles by spatial proximity.
        let windowCenters = items.map {
            CGPoint(x: $0.0.bounds.midX, y: $0.0.bounds.midY)
        }
        let rectCenters = rects.map {
            CGPoint(x: $0.midX, y: $0.midY)
        }
        let assignment = assignByProximity(windows: windowCenters, rects: rectCenters)

        return items.indices.map { i in
            TileResult(pid: items[i].0.pid,
                       cgWindowID: items[i].0.cgWindowID,
                       cgRect: items[i].0.bounds,
                       target: rects[assignment[i]].integral)
        }
    }

    /// Returns `result[i] = j`, meaning window i should be placed into
    /// rect j. Optimal (min total squared center-distance) by brute-force
    /// permutation for N ≤ 8 — a single display rarely holds more.
    /// Greedy nearest-pair fallback for N ≥ 9 (acceptably non-optimal
    /// but always finishes in O(n² log n)).
    private static func assignByProximity(
        windows: [CGPoint], rects: [CGPoint]
    ) -> [Int] {
        let n = windows.count
        precondition(n == rects.count)
        if n <= 1 { return Array(0..<n) }

        if n <= 8 {
            var perm = Array(0..<n)
            var bestPerm = perm
            var bestCost = costOf(perm, windows, rects)
            permute(&perm, from: 0) { current in
                let c = costOf(current, windows, rects)
                if c < bestCost {
                    bestCost = c
                    bestPerm = current
                }
            }
            return bestPerm
        }

        // Greedy fallback: keep grabbing the closest unmatched
        // (window, rect) pair until everyone is assigned.
        var assigned = Array(repeating: -1, count: n)
        var usedRects = Set<Int>()
        let pairs: [(w: Int, r: Int, d: Double)] = (0..<n).flatMap { wi in
            (0..<n).map { ri in
                let dx = windows[wi].x - rects[ri].x
                let dy = windows[wi].y - rects[ri].y
                return (wi, ri, Double(dx * dx + dy * dy))
            }
        }.sorted { $0.d < $1.d }
        for p in pairs {
            if assigned[p.w] == -1 && !usedRects.contains(p.r) {
                assigned[p.w] = p.r
                usedRects.insert(p.r)
            }
        }
        return assigned
    }

    private static func costOf(_ perm: [Int],
                               _ windows: [CGPoint],
                               _ rects: [CGPoint]) -> Double {
        var sum = 0.0
        for (i, j) in perm.enumerated() {
            let dx = windows[i].x - rects[j].x
            let dy = windows[i].y - rects[j].y
            sum += Double(dx * dx + dy * dy)
        }
        return sum
    }

    /// Standard recursive in-place permutation generator. Visits `a`
    /// once for each of the n! orderings.
    private static func permute(_ a: inout [Int],
                                from start: Int,
                                visit: ([Int]) -> Void) {
        if start == a.count {
            visit(a)
            return
        }
        for i in start..<a.count {
            a.swapAt(start, i)
            permute(&a, from: start + 1, visit: visit)
            a.swapAt(start, i)
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
    /// Overflow tolerance is computed *relative to the target size* — see
    /// `slackFor(_:)`. A 1800px-wide target absorbs ~27px of overflow as
    /// noise; a 600px target absorbs only ~9px. Floor of 8px so the check
    /// never gets absurdly tight on tiny windows.
    private static let overflowRelative: CGFloat = 0.015
    private static let overflowFloor: CGFloat = 8

    /// Per-bundleID minimum size learned across runs *within the same
    /// process lifetime*. Populated whenever overflow is detected: the
    /// actual size at that moment is the app's enforced minimum (or close
    /// to it), and that's the size we want to plan around next time so
    /// the iteration converges in one shot instead of grinding through
    /// the asymptotic shrink. Not persisted — re-learned after relaunch,
    /// which costs at most one extra iteration per stubborn app.
    private static var knownMinSizes: [String: CGSize] = [:]

    private static func slackFor(_ side: CGFloat) -> CGFloat {
        max(overflowFloor, side * overflowRelative)
    }

    /// Tile all visible app windows across all connected displays. Each
    /// display's windows are squarified independently within that display's
    /// visibleFrame. Returns the (pre, post) snapshots: `pre` is the state
    /// before tiling (used for undo), `post` is the actual state after
    /// tiling+reflow (used to detect "the user has not moved any window
    /// since we tiled").
    @discardableResult
    static func runTile() -> (pre: WindowSnapshot, post: WindowSnapshot)? {
        guard AXIsProcessTrusted() else { Logger.log("no AX trust"); return nil }
        guard !NSScreen.screens.isEmpty else { Logger.log("no screens"); return nil }

        let wins = WindowEnumerator.visibleAppWindows()
        guard !wins.isEmpty else { Logger.log("no windows"); return nil }

        // Group windows by their primary (max-area) display. Skip windows
        // that don't intersect any screen at all (off-screen / minimized).
        var groups: [ObjectIdentifier: (screen: NSScreen, wins: [WindowInfo])] = [:]
        for w in wins {
            guard let screen = ScreenGeometry.screenContaining(w.bounds) else { continue }
            let key = ObjectIdentifier(screen)
            if var g = groups[key] {
                g.wins.append(w)
                groups[key] = g
            } else {
                groups[key] = (screen, [w])
            }
        }
        let groupedWins = groups.values.flatMap { $0.wins }
        guard !groupedWins.isEmpty else { Logger.log("no windows on any screen"); return nil }

        let pre = capturePairs(for: groupedWins)
        guard !pre.entries.isEmpty else { return nil }
        let widToAX = Dictionary(uniqueKeysWithValues: pre.entries.map { ($0.cgWindowID, $0.ax) })

        // Disable AXEnhancedUserInterface for the whole batch — Electron apps
        // (Slack/Claude/Discord) silently ignore AX setSize without this.
        let pidsTouched = Set(groupedWins.map { $0.pid })
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
        for w in groupedWins { weights[w.cgWindowID] = ContentMeasurer.weight(for: w) }

        // bundleID lookup so the iteration loop can record observed
        // min-sizes back into `knownMinSizes`.
        let bidByWid: [CGWindowID: String] = Dictionary(
            uniqueKeysWithValues: groupedWins.compactMap { w in
                w.bundleID.map { (w.cgWindowID, $0) }
            })

        // Pre-boost from learned min-sizes: if a window's category weight
        // would allocate it less area than we've previously observed it
        // refusing to shrink below, scale up its weight to match. Done
        // per-display since each display tiles independently. The
        // existing iteration loop will still correct any residual error,
        // but typically converges in 1-2 rounds instead of 4-5.
        for (_, group) in groups {
            let bounds = ScreenGeometry.cgVisibleFrame(of: group.screen)
            let displayArea = Double(bounds.width * bounds.height)
            guard displayArea > 0 else { continue }
            var groupTotal = group.wins.reduce(0.0) {
                $0 + (weights[$1.cgWindowID] ?? 1.0)
            }
            for w in group.wins {
                guard let bid = w.bundleID,
                      let minSz = knownMinSizes[bid] else { continue }
                let minArea = Double(minSz.width * minSz.height)
                guard minArea > 0, groupTotal > 0 else { continue }
                let curWeight = weights[w.cgWindowID] ?? 1.0
                let curArea = curWeight / groupTotal * displayArea
                if curArea > 0, curArea < minArea {
                    let factor = minArea / curArea
                    weights[w.cgWindowID] = curWeight * factor
                    groupTotal += curWeight * (factor - 1)
                }
            }
        }

        var prevOverflowPx = CGFloat.infinity
        for attempt in 1...maxIterations {
            var overflows = 0
            var overflowPx: CGFloat = 0

            for (_, group) in groups {
                let bounds = ScreenGeometry.cgVisibleFrame(of: group.screen)
                let items = group.wins.compactMap { w -> (WindowInfo, Double)? in
                    guard widToAX[w.cgWindowID] != nil else { return nil }
                    return (w, weights[w.cgWindowID] ?? 1.0)
                }
                let plan = TilingEngine.tile(items, in: bounds)
                for t in plan {
                    guard let ax = widToAX[t.cgWindowID] else { continue }
                    AXWindowMover.move(ax, to: t.target)
                }
                for t in plan {
                    guard let ax = widToAX[t.cgWindowID],
                          let actual = AXWindowMover.readRect(ax) else { continue }
                    let ovW = max(0, actual.width - t.target.width)
                    let ovH = max(0, actual.height - t.target.height)
                    if ovW > slackFor(t.target.width) || ovH > slackFor(t.target.height) {
                        let factor = Double(actual.width * actual.height)
                                    / max(1, Double(t.target.width * t.target.height))
                        weights[t.cgWindowID] = (weights[t.cgWindowID] ?? 1.0) * factor
                        overflows += 1
                        overflowPx += ovW + ovH
                        // Record the observed min-size for this bundleID.
                        // `actual` is the app's enforced floor at this
                        // moment (we asked for smaller, it refused). Take
                        // max so multiple observations across a session
                        // converge upward to a stable upper bound.
                        if let bid = bidByWid[t.cgWindowID] {
                            let prev = knownMinSizes[bid] ?? .zero
                            knownMinSizes[bid] = CGSize(
                                width: max(prev.width, actual.width),
                                height: max(prev.height, actual.height))
                        }
                    }
                }
            }

            if overflows == 0 {
                Logger.log("tile converged in \(attempt)")
                break
            }
            // Magnitude-based early exit: a stubborn overflow that keeps
            // shrinking is fine; one that plateaus means we're geometrically
            // stuck and more iterations won't help. Threshold 0.98 means
            // <2% improvement counts as plateaued — gives slow-but-still-
            // progressing convergence one or two more shots before bailing.
            if overflowPx > prevOverflowPx * 0.98 {
                Logger.log("tile stalled at \(attempt) (overflows=\(overflows) px=\(Int(overflowPx)))")
                break
            }
            prevOverflowPx = overflowPx
            if attempt == maxIterations {
                Logger.log("tile gave up after \(attempt) (overflows=\(overflows) px=\(Int(overflowPx)))")
            }
        }

        // Post-tile clamp: any window whose final rect overflows its
        // display's visibleFrame gets pulled back inside, *position only*.
        // This catches stubborn apps (Tencent QQ/WeChat, certain Electron
        // builds) that ignore AX setSize. The window stays its actual size
        // and may end up overlapping a neighbor — overlap is unavoidable
        // when the sum of stubborn sizes exceeds the display — but at
        // least no part of any window ends up off-screen.
        for (_, group) in groups {
            let vf = ScreenGeometry.cgVisibleFrame(of: group.screen)
            for w in group.wins {
                guard let ax = widToAX[w.cgWindowID],
                      let actual = AXWindowMover.readRect(ax) else { continue }
                var newOrigin = actual.origin
                if actual.maxX > vf.maxX {
                    newOrigin.x = max(vf.minX, vf.maxX - actual.width)
                }
                if actual.minX < vf.minX {
                    newOrigin.x = vf.minX
                }
                if actual.maxY > vf.maxY {
                    newOrigin.y = max(vf.minY, vf.maxY - actual.height)
                }
                if actual.minY < vf.minY {
                    newOrigin.y = vf.minY
                }
                if newOrigin != actual.origin {
                    AXWindowMover.move(ax, to: CGRect(origin: newOrigin, size: actual.size))
                }
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

    /// Capture every visible app window's current AX rect. Used by callers
    /// that need a "pre" snapshot for actions whose entry path doesn't go
    /// through runTile() (e.g. a move-then-retile action wants its own pre
    /// to reflect the state *before the move*, not before the retile).
    static func snapshot() -> WindowSnapshot {
        capturePairs(for: WindowEnumerator.visibleAppWindows())
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
