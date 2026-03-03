import CoreGraphics
import Testing
@testable import ZWMServer

// MARK: - Helpers

private let testMonitor = MonitorInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055) // 25px menu bar
)

/// Build a tree with one workspace and N windows, returning (tree, [windowNodeIds]).
private func treeWithWindows(
    count: Int,
    layout: Layout = .horizontal,
    monitorId: UInt32 = 1
) -> (TreeState, [NodeId]) {
    var tree = TreeState().addWorkspace(name: "1", monitorId: monitorId)
    let wsId = tree.workspaceIds[0]

    // If we need a specific layout, wrap in a container
    if count > 1 {
        tree = tree.insertContainer(inParent: wsId, layout: layout)
        let containerId = tree.workspaceNode(wsId)!.childIds[0]
        var windowIds: [NodeId] = []
        for i in 0..<count {
            tree = tree.insertWindow(
                windowId: UInt32(i + 1), appPid: 1, appName: "App", title: "W\(i + 1)",
                inParent: containerId
            )
            let winId = tree.allWindows.first { $0.windowId == UInt32(i + 1) }!.id
            windowIds.append(winId)
        }
        return (tree, windowIds)
    } else if count == 1 {
        tree = tree.insertWindow(
            windowId: 1, appPid: 1, appName: "App", title: "W1",
            inParent: wsId
        )
        let winId = tree.allWindows.first { $0.windowId == 1 }!.id
        return (tree, [winId])
    }
    return (tree, [])
}

private func assertClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.5, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) < tolerance, "Expected \(a) ≈ \(b)", sourceLocation: sourceLocation)
}

// MARK: - Single window

@Test func singleWindowFillsMonitor() {
    let (tree, windowIds) = treeWithWindows(count: 1)
    let result = layoutTree(tree, monitors: [testMonitor])

    let frame = result.frames[windowIds[0]]!
    assertClose(frame.origin.x, 0)
    assertClose(frame.origin.y, 25) // menu bar offset
    assertClose(frame.size.width, 1920)
    assertClose(frame.size.height, 1055)
}

// MARK: - Horizontal split

@Test func twoWindowsHorizontalSplitEvenlyWithinVisibleFrame() {
    let (tree, windowIds) = treeWithWindows(count: 2, layout: .horizontal)
    let result = layoutTree(tree, monitors: [testMonitor])

    let left = result.frames[windowIds[0]]!
    let right = result.frames[windowIds[1]]!

    // Each window should be half the width
    assertClose(left.size.width, 960)
    assertClose(right.size.width, 960)

    // Full height
    assertClose(left.size.height, 1055)
    assertClose(right.size.height, 1055)

    // Left starts at x=0, right at x=960
    assertClose(left.origin.x, 0)
    assertClose(right.origin.x, 960)
}

@Test func threeWindowsHorizontalSplit() {
    let (tree, windowIds) = treeWithWindows(count: 3, layout: .horizontal)
    let result = layoutTree(tree, monitors: [testMonitor])

    let w1 = result.frames[windowIds[0]]!
    let w2 = result.frames[windowIds[1]]!
    let w3 = result.frames[windowIds[2]]!

    // Each should be 1/3 of width
    assertClose(w1.size.width, 640)
    assertClose(w2.size.width, 640)
    assertClose(w3.size.width, 640)
}

// MARK: - Vertical split

@Test func twoWindowsVerticalSplit() {
    let (tree, windowIds) = treeWithWindows(count: 2, layout: .vertical)
    let result = layoutTree(tree, monitors: [testMonitor])

    let top = result.frames[windowIds[0]]!
    let bottom = result.frames[windowIds[1]]!

    // Each should be half the height
    assertClose(top.size.height, 527.5)
    assertClose(bottom.size.height, 527.5)

    // Full width
    assertClose(top.size.width, 1920)
    assertClose(bottom.size.width, 1920)

    // Stacked vertically
    assertClose(top.origin.y, 25)
    assertClose(bottom.origin.y, 25 + 527.5)
}

// MARK: - Gaps

@Test func outerGapsInsetFromMonitorEdge() {
    let (tree, windowIds) = treeWithWindows(count: 1)
    let gaps = GapConfig(inner: 0, outer: 10)
    let result = layoutTree(tree, monitors: [testMonitor], gaps: gaps)

    let frame = result.frames[windowIds[0]]!
    assertClose(frame.origin.x, 10)
    assertClose(frame.origin.y, 35) // 25 menu bar + 10 outer gap
    assertClose(frame.size.width, 1900) // 1920 - 2*10
    assertClose(frame.size.height, 1035) // 1055 - 2*10
}

@Test func innerGapsBetweenWindows() {
    let (tree, windowIds) = treeWithWindows(count: 2, layout: .horizontal)
    let gaps = GapConfig(inner: 10, outer: 0)
    let result = layoutTree(tree, monitors: [testMonitor], gaps: gaps)

    let left = result.frames[windowIds[0]]!
    let right = result.frames[windowIds[1]]!

    // Total available = 1920 - 10 (one inner gap) = 1910, split evenly = 955 each
    assertClose(left.size.width, 955)
    assertClose(right.size.width, 955)

    // Left starts at 0, right starts at 955 + 10 gap = 965
    assertClose(left.origin.x, 0)
    assertClose(right.origin.x, 965)
}

@Test func innerAndOuterGapsCombined() {
    let (tree, windowIds) = treeWithWindows(count: 2, layout: .horizontal)
    let gaps = GapConfig(inner: 8, outer: 12)
    let result = layoutTree(tree, monitors: [testMonitor], gaps: gaps)

    let left = result.frames[windowIds[0]]!
    let right = result.frames[windowIds[1]]!

    // Usable width = 1920 - 2*12 = 1896, minus 1 inner gap of 8 = 1888, split = 944 each
    assertClose(left.size.width, 944)
    assertClose(right.size.width, 944)

    // Left starts at outer gap
    assertClose(left.origin.x, 12)
}

// MARK: - Nested containers

@Test func nestedHorizontalAndVerticalSplit() {
    // Create: workspace -> h-container -> [window1, v-container -> [window2, window3]]
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertContainer(inParent: wsId, layout: .horizontal)
    let hContainerId = tree.workspaceNode(wsId)!.childIds[0]

    // Add window1 to h-container
    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: hContainerId
    )
    let win1 = tree.allWindows.first { $0.windowId == 1 }!.id

    // Add v-container to h-container
    tree = tree.insertContainer(inParent: hContainerId, layout: .vertical)
    let vContainerId = tree.containerNode(hContainerId)!.childIds[1]

    // Add window2 and window3 to v-container
    tree = tree.insertWindow(
        windowId: 2, appPid: 1, appName: "App", title: "W2", inParent: vContainerId
    )
    tree = tree.insertWindow(
        windowId: 3, appPid: 1, appName: "App", title: "W3", inParent: vContainerId
    )
    let win2 = tree.allWindows.first { $0.windowId == 2 }!.id
    let win3 = tree.allWindows.first { $0.windowId == 3 }!.id

    let result = layoutTree(tree, monitors: [testMonitor])

    let f1 = result.frames[win1]!
    let f2 = result.frames[win2]!
    let f3 = result.frames[win3]!

    // win1 gets left half, win2 + win3 share right half vertically
    assertClose(f1.size.width, 960)
    assertClose(f1.size.height, 1055)

    assertClose(f2.size.width, 960)
    assertClose(f3.size.width, 960)
    assertClose(f2.size.height, 527.5)
    assertClose(f3.size.height, 527.5)
}

// MARK: - Weights

@Test func unequalWeightsProduceProportionalSizes() {
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertContainer(inParent: wsId, layout: .horizontal)
    let containerId = tree.workspaceNode(wsId)!.childIds[0]

    // Insert windows with different weights
    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1",
        inParent: containerId, weight: 2.0
    )
    tree = tree.insertWindow(
        windowId: 2, appPid: 1, appName: "App", title: "W2",
        inParent: containerId, weight: 1.0
    )
    let win1 = tree.allWindows.first { $0.windowId == 1 }!.id
    let win2 = tree.allWindows.first { $0.windowId == 2 }!.id

    let result = layoutTree(tree, monitors: [testMonitor])

    let f1 = result.frames[win1]!
    let f2 = result.frames[win2]!

    // Weight 2:1 means 2/3 and 1/3 of total width
    assertClose(f1.size.width, 1280) // 1920 * 2/3
    assertClose(f2.size.width, 640)  // 1920 * 1/3
}

// MARK: - Empty cases

@Test func emptyWorkspaceProducesNoFrames() {
    let tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let result = layoutTree(tree, monitors: [testMonitor])
    #expect(result.frames.isEmpty)
}

@Test func noMonitorsProducesNoFrames() {
    let (tree, _) = treeWithWindows(count: 2)
    let result = layoutTree(tree, monitors: [])
    #expect(result.frames.isEmpty)
}

// MARK: - Multiple workspaces

@Test func onlyVisibleWorkspaceWindowsGetFrames() {
    var tree = TreeState()
        .addWorkspace(name: "1", monitorId: 1)
        .addWorkspace(name: "2", monitorId: 1)
    let ws1Id = tree.workspaceIds[0]
    let ws2Id = tree.workspaceIds[1]

    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: ws1Id
    )
    tree = tree.insertWindow(
        windowId: 2, appPid: 1, appName: "App", title: "W2", inParent: ws2Id
    )

    // Both workspaces are assigned to monitor 1, so both get frames
    // (workspace visibility is a higher-level concern, not in layout engine)
    let result = layoutTree(tree, monitors: [testMonitor])
    #expect(result.frames.count == 2)
}

// MARK: - Multi-monitor

@Test func workspacesOnDifferentMonitors() {
    let monitor1 = MonitorInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    let monitor2 = MonitorInfo(
        id: 2,
        frame: CGRect(x: 1920, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1440, height: 900)
    )

    var tree = TreeState()
        .addWorkspace(name: "1", monitorId: 1)
        .addWorkspace(name: "2", monitorId: 2)
    let ws1Id = tree.workspaceIds[0]
    let ws2Id = tree.workspaceIds[1]

    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: ws1Id
    )
    tree = tree.insertWindow(
        windowId: 2, appPid: 1, appName: "App", title: "W2", inParent: ws2Id
    )

    let win1 = tree.allWindows.first { $0.windowId == 1 }!.id
    let win2 = tree.allWindows.first { $0.windowId == 2 }!.id

    let result = layoutTree(tree, monitors: [monitor1, monitor2])

    let f1 = result.frames[win1]!
    let f2 = result.frames[win2]!

    // Window 1 on monitor 1
    assertClose(f1.origin.x, 0)
    assertClose(f1.size.width, 1920)

    // Window 2 on monitor 2
    assertClose(f2.origin.x, 1920)
    assertClose(f2.size.width, 1440)
}

// MARK: - Fullscreen

@Test func fullscreenWindowGetsFullVisibleFrame() {
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: wsId
    )
    let winId = tree.allWindows.first { $0.windowId == 1 }!.id
    tree = tree.setWindowState(winId, .fullscreen)

    let result = layoutTree(tree, monitors: [testMonitor])
    let frame = result.frames[winId]!

    // Fullscreen window gets the entire visible frame, no gaps
    assertClose(frame.origin.x, 0)
    assertClose(frame.origin.y, 25) // menu bar
    assertClose(frame.size.width, 1920)
    assertClose(frame.size.height, 1055)
}

@Test func fullscreenWindowIgnoresGaps() {
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: wsId
    )
    let winId = tree.allWindows.first { $0.windowId == 1 }!.id
    tree = tree.setWindowState(winId, .fullscreen)

    let gaps = GapConfig(inner: 10, outer: 20)
    let result = layoutTree(tree, monitors: [testMonitor], gaps: gaps)
    let frame = result.frames[winId]!

    // Even with gaps configured, fullscreen uses the full visible frame
    assertClose(frame.origin.x, 0)
    assertClose(frame.origin.y, 25)
    assertClose(frame.size.width, 1920)
    assertClose(frame.size.height, 1055)
}

@Test func fullscreenWithOtherTilingWindows() {
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: wsId
    )
    tree = tree.insertWindow(
        windowId: 2, appPid: 1, appName: "App", title: "W2", inParent: wsId
    )
    let win1Id = tree.allWindows.first { $0.windowId == 1 }!.id
    let win2Id = tree.allWindows.first { $0.windowId == 2 }!.id

    // Make window 1 fullscreen
    tree = tree.setWindowState(win1Id, .fullscreen)

    let result = layoutTree(tree, monitors: [testMonitor])

    // Fullscreen window gets full visible frame
    let fsFrame = result.frames[win1Id]!
    assertClose(fsFrame.origin.x, 0)
    assertClose(fsFrame.origin.y, 25)
    assertClose(fsFrame.size.width, 1920)
    assertClose(fsFrame.size.height, 1055)

    // Other tiling window still gets laid out (behind fullscreen)
    let tilingFrame = result.frames[win2Id]!
    assertClose(tilingFrame.size.width, 1920)
    assertClose(tilingFrame.size.height, 1055)
}

// MARK: - Floating

// MARK: - BSP layout

@Test func bspThreeWindowsLayout() {
    // Build BSP: workspace(h) → [W1, vContainer → [W2, W3]]
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertWindow(windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: wsId)
    let win1 = tree.allWindows.first { $0.windowId == 1 }!.id

    tree = tree.insertWindowBSP(windowId: 2, appPid: 1, appName: "App", title: "W2", nearWindowId: win1)
    let win2 = tree.allWindows.first { $0.windowId == 2 }!.id

    tree = tree.insertWindowBSP(windowId: 3, appPid: 1, appName: "App", title: "W3", nearWindowId: win2)
    let win3 = tree.allWindows.first { $0.windowId == 3 }!.id

    let result = layoutTree(tree, monitors: [testMonitor])

    let f1 = result.frames[win1]!
    let f2 = result.frames[win2]!
    let f3 = result.frames[win3]!

    // W1: left half, full height
    assertClose(f1.origin.x, 0)
    assertClose(f1.size.width, 960)
    assertClose(f1.size.height, 1055)

    // W2: right half, top half
    assertClose(f2.origin.x, 960)
    assertClose(f2.size.width, 960)
    assertClose(f2.size.height, 527.5)

    // W3: right half, bottom half
    assertClose(f3.origin.x, 960)
    assertClose(f3.size.width, 960)
    assertClose(f3.size.height, 527.5)
}

@Test func bspFourWindowsGridLayout() {
    // Build BSP where W1 gets split last → 2x2 grid
    // workspace(h) → [vContainer[W1, W4], vContainer[W2, W3]]
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertWindow(windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: wsId)
    let win1 = tree.allWindows.first { $0.windowId == 1 }!.id

    // W2 splits W1 → [W1, W2] as siblings in workspace
    tree = tree.insertWindowBSP(windowId: 2, appPid: 1, appName: "App", title: "W2", nearWindowId: win1)
    let win2 = tree.allWindows.first { $0.windowId == 2 }!.id

    // W3 splits W2 → [W1, vContainer[W2, W3]]
    tree = tree.insertWindowBSP(windowId: 3, appPid: 1, appName: "App", title: "W3", nearWindowId: win2)

    // W4 splits W1 → [vContainer[W1, W4], vContainer[W2, W3]]
    tree = tree.insertWindowBSP(windowId: 4, appPid: 1, appName: "App", title: "W4", nearWindowId: win1)

    let w1 = tree.allWindows.first { $0.windowId == 1 }!.id
    let w2 = tree.allWindows.first { $0.windowId == 2 }!.id
    let w3 = tree.allWindows.first { $0.windowId == 3 }!.id
    let w4 = tree.allWindows.first { $0.windowId == 4 }!.id

    let result = layoutTree(tree, monitors: [testMonitor])

    // All 4 windows should form a 2x2 grid
    let f1 = result.frames[w1]!
    let f2 = result.frames[w2]!
    let f3 = result.frames[w3]!
    let f4 = result.frames[w4]!

    // Left column
    assertClose(f1.size.width, 960)
    assertClose(f4.size.width, 960)
    assertClose(f1.size.height, 527.5)
    assertClose(f4.size.height, 527.5)

    // Right column
    assertClose(f2.size.width, 960)
    assertClose(f3.size.width, 960)
    assertClose(f2.size.height, 527.5)
    assertClose(f3.size.height, 527.5)
}

// MARK: - Floating

@Test func floatingWindowUsesStoredFrame() {
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    tree = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W1", inParent: wsId
    )
    let winId = tree.allWindows.first { $0.windowId == 1 }!.id
    let floatFrame = CGRect(x: 200, y: 150, width: 600, height: 400)
    tree = tree.setWindowState(winId, .floating(floatFrame))

    let result = layoutTree(tree, monitors: [testMonitor])
    let frame = result.frames[winId]!

    assertClose(frame.origin.x, 200)
    assertClose(frame.origin.y, 150)
    assertClose(frame.size.width, 600)
    assertClose(frame.size.height, 400)
}
