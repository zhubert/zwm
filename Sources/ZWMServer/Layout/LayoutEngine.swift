import CoreGraphics

/// Pure layout function: given a tree, monitors, and gap config,
/// compute the frame for every tiling window.
public func layoutTree(
    _ tree: TreeState,
    monitors: [MonitorInfo],
    gaps: GapConfig = GapConfig()
) -> LayoutResult {
    var frames: [NodeId: CGRect] = [:]

    for wsId in tree.workspaceIds {
        guard let ws = tree.workspaceNode(wsId) else { continue }

        // Find the monitor for this workspace
        let monitor: MonitorInfo
        if let monId = ws.monitorId, let m = monitors.first(where: { $0.id == monId }) {
            monitor = m
        } else if let first = monitors.first {
            monitor = first
        } else {
            continue
        }

        // Handle fullscreen window (may be nested inside a container):
        // give it the full visible frame, remaining tiling windows still get
        // laid out behind it.
        if let fsId = firstFullscreenWindow(ws.childIds, tree: tree) {
            frames[fsId] = monitor.visibleFrame
        }

        // Compute usable area after outer gaps
        let usable = CGRect(
            x: monitor.visibleFrame.minX + gaps.outer,
            y: monitor.visibleFrame.minY + gaps.outer,
            width: monitor.visibleFrame.width - 2 * gaps.outer,
            height: monitor.visibleFrame.height - 2 * gaps.outer
        )

        // Layout tiling children — flatten BSP tree into grid.
        // Fullscreen windows are excluded automatically (state != .tiling).
        let leaves = collectTilingLeaves(ws.childIds, tree: tree)
        layoutGrid(leaves, in: usable, direction: ws.layout, gaps: gaps, frames: &frames)

        // Floating windows keep their stored frame
        for floatId in ws.floatingWindowIds {
            if case .window(let w) = tree.node(floatId), case .floating(let rect) = w.state {
                frames[floatId] = rect
            }
        }
    }

    return LayoutResult(frames: frames)
}

/// Find the first fullscreen window anywhere in a subtree (depth-first).
private func firstFullscreenWindow(_ childIds: some Sequence<NodeId>, tree: TreeState) -> NodeId? {
    for id in childIds {
        switch tree.node(id) {
        case .window(let w) where w.state == .fullscreen:
            return id
        case .tilingContainer(let tc):
            if let found = firstFullscreenWindow(tc.childIds, tree: tree) { return found }
        default:
            break
        }
    }
    return nil
}

/// Collect all tiling leaf window IDs by flattening containers depth-first.
private func collectTilingLeaves(_ childIds: [NodeId], tree: TreeState) -> [NodeId] {
    var leaves: [NodeId] = []
    var stack = childIds.reversed() as [NodeId]
    while let id = stack.popLast() {
        switch tree.node(id) {
        case .window(let w) where w.state == .tiling:
            leaves.append(id)
        case .tilingContainer(let tc):
            stack.append(contentsOf: tc.childIds.reversed())
        default:
            break
        }
    }
    return leaves
}

/// Lay out windows in a grid: columns (horizontal) or rows (vertical).
private func layoutGrid(
    _ windowIds: [NodeId],
    in rect: CGRect,
    direction: Layout,
    gaps: GapConfig,
    frames: inout [NodeId: CGRect]
) {
    guard !windowIds.isEmpty else { return }

    if windowIds.count == 1 {
        frames[windowIds[0]] = rect
        return
    }

    let n = windowIds.count
    let majorCount = Int(ceil(sqrt(Double(n))))  // number of columns (or rows)
    let basePerMajor = n / majorCount
    let extra = n % majorCount

    let isHorizontal = direction == .horizontal
    let majorSpace = isHorizontal ? rect.width : rect.height
    let minorSpace = isHorizontal ? rect.height : rect.width
    let majorGaps = CGFloat(majorCount - 1) * gaps.inner
    let majorSize = (majorSpace - majorGaps) / CGFloat(majorCount)

    var windowIdx = 0
    for major in 0..<majorCount {
        let minorCount = basePerMajor + (major < extra ? 1 : 0)
        let majorOffset = CGFloat(major) * (majorSize + gaps.inner)

        let minorGaps = CGFloat(max(minorCount - 1, 0)) * gaps.inner
        let minorSize = (minorSpace - minorGaps) / CGFloat(max(minorCount, 1))

        for minor in 0..<minorCount {
            let minorOffset = CGFloat(minor) * (minorSize + gaps.inner)

            let frame: CGRect
            if isHorizontal {
                frame = CGRect(
                    x: rect.minX + majorOffset,
                    y: rect.minY + minorOffset,
                    width: majorSize,
                    height: minorSize
                )
            } else {
                frame = CGRect(
                    x: rect.minX + minorOffset,
                    y: rect.minY + majorOffset,
                    width: minorSize,
                    height: majorSize
                )
            }
            frames[windowIds[windowIdx]] = frame
            windowIdx += 1
        }
    }
}