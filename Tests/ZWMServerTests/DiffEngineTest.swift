import CoreGraphics
import Testing
@testable import ZWMServer

// MARK: - Helpers

private let monitor = MonitorInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
)

/// Build a tree with a workspace and N windows in a container.
private func buildTree(windowCount: Int, layout: Layout = .horizontal) -> (TreeState, [NodeId]) {
    var tree = TreeState().addWorkspace(name: "1", monitorId: 1)
    let wsId = tree.workspaceIds[0]

    if windowCount == 0 { return (tree, []) }

    tree = tree.insertContainer(inParent: wsId, layout: layout)
    let containerId = tree.workspaceNode(wsId)!.childIds[0]
    var winIds: [NodeId] = []
    for i in 0..<windowCount {
        tree = tree.insertWindow(
            windowId: UInt32(i + 1), appPid: 1, appName: "App", title: "W\(i + 1)",
            inParent: containerId
        )
        winIds.append(tree.allWindows.first { $0.windowId == UInt32(i + 1) }!.id)
    }
    return (tree, winIds)
}

// MARK: - No changes

@Test func identicalLayoutsProduceEmptyDiff() {
    let (tree, _) = buildTree(windowCount: 2)
    let layout = layoutTree(tree, monitors: [monitor])
    let diff = diffLayouts(
        old: layout, new: layout,
        oldFocusedWindowId: nil, newFocusedWindowId: nil,
        tree: tree
    )
    #expect(diff.isEmpty)
}

// MARK: - New windows

@Test func newWindowInLayoutProducesChange() {
    let (tree1, _) = buildTree(windowCount: 1)
    let layout1 = layoutTree(tree1, monitors: [monitor])

    let (tree2, _) = buildTree(windowCount: 2)
    let layout2 = layoutTree(tree2, monitors: [monitor])

    let diff = diffLayouts(
        old: layout1, new: layout2,
        oldFocusedWindowId: nil, newFocusedWindowId: nil,
        tree: tree2
    )
    // At least the new window should appear, and the old one may have resized
    #expect(!diff.isEmpty)
    #expect(diff.toSet.count >= 1)
}

// MARK: - Frame changes

@Test func changedFrameDetected() {
    let (tree, winIds) = buildTree(windowCount: 1)
    let nodeId = winIds[0]
    let wid = tree.windowNode(nodeId)!.windowId

    let old = LayoutResult(frames: [nodeId: CGRect(x: 0, y: 0, width: 960, height: 1080)])
    let new = LayoutResult(frames: [nodeId: CGRect(x: 0, y: 0, width: 1920, height: 1080)])

    let diff = diffLayouts(
        old: old, new: new,
        oldFocusedWindowId: nil, newFocusedWindowId: nil,
        tree: tree
    )
    #expect(diff.toSet.count == 1)
    #expect(diff.toSet[0].windowId == wid)
    #expect(diff.toSet[0].frame.size.width == 1920)
}

@Test func subPixelChangeIgnored() {
    let (tree, winIds) = buildTree(windowCount: 1)
    let nodeId = winIds[0]

    let old = LayoutResult(frames: [nodeId: CGRect(x: 0, y: 0, width: 960, height: 1080)])
    let new = LayoutResult(frames: [nodeId: CGRect(x: 0.3, y: 0.2, width: 960.4, height: 1080.1)])

    let diff = diffLayouts(
        old: old, new: new,
        oldFocusedWindowId: nil, newFocusedWindowId: nil,
        tree: tree
    )
    #expect(diff.toSet.isEmpty)
}

@Test func exactToleranceBoundary() {
    let (tree, winIds) = buildTree(windowCount: 1)
    let nodeId = winIds[0]

    // Exactly 1px difference — should be ignored (< tolerance means within)
    let old = LayoutResult(frames: [nodeId: CGRect(x: 0, y: 0, width: 960, height: 1080)])
    let justUnder = LayoutResult(frames: [nodeId: CGRect(x: 0.99, y: 0, width: 960, height: 1080)])
    let justOver = LayoutResult(frames: [nodeId: CGRect(x: 1.01, y: 0, width: 960, height: 1080)])

    let diffUnder = diffLayouts(old: old, new: justUnder, oldFocusedWindowId: nil, newFocusedWindowId: nil, tree: tree)
    let diffOver = diffLayouts(old: old, new: justOver, oldFocusedWindowId: nil, newFocusedWindowId: nil, tree: tree)

    #expect(diffUnder.toSet.isEmpty)
    #expect(diffOver.toSet.count == 1)
}

// MARK: - Focus changes

@Test func focusChangeDetected() {
    let (tree, _) = buildTree(windowCount: 2)
    let layout = layoutTree(tree, monitors: [monitor])

    let diff = diffLayouts(
        old: layout, new: layout,
        oldFocusedWindowId: 1, newFocusedWindowId: 2,
        tree: tree
    )
    #expect(diff.toFocus == 2)
}

@Test func sameFocusProducesNoFocusChange() {
    let (tree, _) = buildTree(windowCount: 1)
    let layout = layoutTree(tree, monitors: [monitor])

    let diff = diffLayouts(
        old: layout, new: layout,
        oldFocusedWindowId: 1, newFocusedWindowId: 1,
        tree: tree
    )
    #expect(diff.toFocus == nil)
}

@Test func focusFromNoneToSomeDetected() {
    let (tree, _) = buildTree(windowCount: 1)
    let layout = layoutTree(tree, monitors: [monitor])

    let diff = diffLayouts(
        old: layout, new: layout,
        oldFocusedWindowId: nil, newFocusedWindowId: 1,
        tree: tree
    )
    #expect(diff.toFocus == 1)
}

// MARK: - Window removed

@Test func removedWindowNotInDiff() {
    let (tree, winIds) = buildTree(windowCount: 2)
    let layout = layoutTree(tree, monitors: [monitor])

    // New layout has only window 1 (window 2 was removed)
    let smallerLayout = LayoutResult(frames: [winIds[0]: layout.frames[winIds[0]]!])

    let diff = diffLayouts(
        old: layout, new: smallerLayout,
        oldFocusedWindowId: nil, newFocusedWindowId: nil,
        tree: tree
    )
    // No changes needed — window 2 is just gone, and window 1 didn't move
    #expect(diff.toSet.isEmpty)
}
