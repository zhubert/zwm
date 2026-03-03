import Testing
@testable import ZWMServer

// MARK: - Helpers

/// Build a tree with one workspace and return (tree, workspaceId).
private func treeWithWorkspace(name: String = "1") -> (TreeState, NodeId) {
    let tree = TreeState().addWorkspace(name: name)
    let wsId = tree.workspaceIds[0]
    return (tree, wsId)
}

/// Insert a test window into a parent, returning (tree, windowNodeId).
private func insertTestWindow(
    _ tree: TreeState,
    parent: NodeId,
    windowId: UInt32 = 1,
    appName: String = "TestApp"
) -> (TreeState, NodeId) {
    let newTree = tree.insertWindow(
        windowId: windowId, appPid: 1, appName: appName, title: "Window \(windowId)",
        inParent: parent
    )
    // The new window is the last-generated node
    let windowNodeId = newTree.allWindows.first { $0.windowId == windowId }!.id
    return (newTree, windowNodeId)
}

// MARK: - Node ID generation

@Test func nodeIdGeneratorProducesSequentialIds() {
    var gen = NodeIdGenerator()
    let a = gen.generate()
    let b = gen.generate()
    let c = gen.generate()
    #expect(a.rawValue == 1)
    #expect(b.rawValue == 2)
    #expect(c.rawValue == 3)
}

@Test func nodeIdDescription() {
    let id = NodeId(rawValue: 42)
    #expect(id.description == "node-42")
}

// MARK: - Empty tree

@Test func emptyTreeHasNoNodesOrWorkspaces() {
    let tree = TreeState()
    #expect(tree.nodes.isEmpty)
    #expect(tree.workspaceIds.isEmpty)
    #expect(tree.focusedWindowId == nil)
    #expect(tree.allWindows.isEmpty)
}

// MARK: - Workspace mutations

@Test func addWorkspaceCreatesWorkspaceNode() {
    let (tree, wsId) = treeWithWorkspace(name: "main")
    #expect(tree.workspaceIds.count == 1)
    let ws = tree.workspaceNode(wsId)
    #expect(ws != nil)
    #expect(ws?.name == "main")
    #expect(ws?.childIds.isEmpty == true)
}

@Test func addMultipleWorkspaces() {
    let tree = TreeState()
        .addWorkspace(name: "1")
        .addWorkspace(name: "2")
        .addWorkspace(name: "3")
    #expect(tree.workspaceIds.count == 3)
    #expect(tree.workspaceMRU == ["1", "2", "3"])
}

@Test func workspaceLookupByName() {
    let tree = TreeState()
        .addWorkspace(name: "code")
        .addWorkspace(name: "web")
    #expect(tree.workspace("code")?.name == "code")
    #expect(tree.workspace("web")?.name == "web")
    #expect(tree.workspace("missing") == nil)
}

// MARK: - Window mutations

@Test func insertWindowAddsToWorkspace() {
    let (tree, wsId) = treeWithWorkspace()
    let (newTree, winId) = insertTestWindow(tree, parent: wsId, windowId: 100)

    let ws = newTree.workspaceNode(wsId)!
    #expect(ws.childIds.count == 1)
    #expect(ws.childIds[0] == winId)

    let win = newTree.windowNode(winId)!
    #expect(win.windowId == 100)
    #expect(win.parentId == wsId)
    #expect(win.state == .tiling)
}

@Test func insertMultipleWindowsPreservesOrder() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, _) = insertTestWindow(t1, parent: wsId, windowId: 2)
    let (t3, _) = insertTestWindow(t2, parent: wsId, windowId: 3)

    let ws = t3.workspaceNode(wsId)!
    #expect(ws.childIds.count == 3)

    let windowIds = ws.childIds.map { t3.windowNode($0)!.windowId }
    #expect(windowIds == [1, 2, 3])
}

@Test func insertWindowAfterSpecificNode() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, win1) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, _) = insertTestWindow(t1, parent: wsId, windowId: 2)

    // Insert window 3 after window 1
    let t3 = t2.insertWindow(
        windowId: 3, appPid: 1, appName: "App", title: "W3",
        inParent: wsId, afterNodeId: win1
    )
    let ws = t3.workspaceNode(wsId)!
    let windowIds = ws.childIds.map { t3.windowNode($0)!.windowId }
    #expect(windowIds == [1, 3, 2])
}

@Test func insertWindowIntoNonexistentParentIsNoop() {
    let tree = TreeState()
    let bogusId = NodeId(rawValue: 999)
    let result = tree.insertWindow(
        windowId: 1, appPid: 1, appName: "App", title: "W",
        inParent: bogusId
    )
    #expect(result == tree)
}

// MARK: - Immutability

@Test func mutationsDoNotModifyOriginalTree() {
    let (original, wsId) = treeWithWorkspace()
    let _ = insertTestWindow(original, parent: wsId, windowId: 1)

    // Original tree should be unchanged
    #expect(original.allWindows.isEmpty)
    let ws = original.workspaceNode(wsId)!
    #expect(ws.childIds.isEmpty)
}

// MARK: - Remove mutations

@Test func removeWindowFromWorkspace() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, win1) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, _) = insertTestWindow(t1, parent: wsId, windowId: 2)

    let t3 = t2.removeNode(win1)
    let ws = t3.workspaceNode(wsId)!
    #expect(ws.childIds.count == 1)
    #expect(t3.windowNode(win1) == nil)
}

@Test func removeContainerRemovesDescendants() {
    let (tree, wsId) = treeWithWorkspace()
    let t1 = tree.insertContainer(inParent: wsId, layout: .horizontal)
    let containerId = t1.workspaceNode(wsId)!.childIds[0]

    let (t2, win1) = insertTestWindow(t1, parent: containerId, windowId: 1)
    let (t3, win2) = insertTestWindow(t2, parent: containerId, windowId: 2)

    let t4 = t3.removeNode(containerId)
    #expect(t4.node(containerId) == nil)
    #expect(t4.node(win1) == nil)
    #expect(t4.node(win2) == nil)
    #expect(t4.workspaceNode(wsId)!.childIds.isEmpty)
}

@Test func removeFocusedWindowClearsFocus() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, winId) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let t2 = t1.setFocus(winId)
    #expect(t2.focusedWindowId == winId)

    let t3 = t2.removeNode(winId)
    #expect(t3.focusedWindowId == nil)
}

@Test func removeNonexistentNodeIsNoop() {
    let (tree, _) = treeWithWorkspace()
    let bogusId = NodeId(rawValue: 999)
    let result = tree.removeNode(bogusId)
    #expect(result == tree)
}

// MARK: - Move mutations

@Test func moveWindowBetweenWorkspaces() {
    let tree = TreeState()
        .addWorkspace(name: "1")
        .addWorkspace(name: "2")
    let ws1Id = tree.workspaceIds[0]
    let ws2Id = tree.workspaceIds[1]

    let (t1, winId) = insertTestWindow(tree, parent: ws1Id, windowId: 1)

    let t2 = t1.moveNode(winId, toParent: ws2Id, atIndex: 0)

    #expect(t2.workspaceNode(ws1Id)!.childIds.isEmpty)
    #expect(t2.workspaceNode(ws2Id)!.childIds == [winId])
    #expect(t2.windowNode(winId)!.parentId == ws2Id)
}

@Test func moveWindowToSpecificIndex() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, _) = insertTestWindow(t1, parent: wsId, windowId: 2)

    // Add second workspace with one window, then move it to ws at index 1
    let t3 = t2.addWorkspace(name: "2")
    let ws2Id = t3.workspaceIds[1]
    let (t4, win3) = insertTestWindow(t3, parent: ws2Id, windowId: 3)

    let t5 = t4.moveNode(win3, toParent: wsId, atIndex: 1)
    let children = t5.workspaceNode(wsId)!.childIds
    #expect(children.count == 3)
    // win3 should be at index 1
    #expect(t5.windowNode(children[1])!.windowId == 3)
}

// MARK: - Container mutations

@Test func insertContainerIntoWorkspace() {
    let (tree, wsId) = treeWithWorkspace()
    let t1 = tree.insertContainer(inParent: wsId, layout: .vertical)

    let ws = t1.workspaceNode(wsId)!
    #expect(ws.childIds.count == 1)

    let containerId = ws.childIds[0]
    let container = t1.containerNode(containerId)!
    #expect(container.layout == .vertical)
    #expect(container.parentId == wsId)
}

@Test func nestedContainers() {
    let (tree, wsId) = treeWithWorkspace()
    let t1 = tree.insertContainer(inParent: wsId, layout: .horizontal)
    let outerId = t1.workspaceNode(wsId)!.childIds[0]

    let t2 = t1.insertContainer(inParent: outerId, layout: .vertical)
    let innerId = t2.containerNode(outerId)!.childIds[0]

    let inner = t2.containerNode(innerId)!
    #expect(inner.layout == .vertical)
    #expect(inner.parentId == outerId)
}

// MARK: - Layout mutations

@Test func setLayoutChangesContainerLayout() {
    let (tree, wsId) = treeWithWorkspace()
    let t1 = tree.insertContainer(inParent: wsId, layout: .horizontal)
    let containerId = t1.workspaceNode(wsId)!.childIds[0]

    let t2 = t1.setLayout(containerId, .vertical)
    #expect(t2.containerNode(containerId)!.layout == .vertical)

    let t3 = t2.setLayout(containerId, .horizontal)
    #expect(t3.containerNode(containerId)!.layout == .horizontal)
}

@Test func setLayoutOnNonContainerIsNoop() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, winId) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let t2 = t1.setLayout(winId, .vertical)
    #expect(t2 == t1)
}

// MARK: - Focus mutations

@Test func setFocusUpdatesCurrentFocus() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, win1) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: wsId, windowId: 2)

    let t3 = t2.setFocus(win1)
    #expect(t3.focusedWindowId == win1)

    let t4 = t3.setFocus(win2)
    #expect(t4.focusedWindowId == win2)
}

@Test func setFocusUpdatesWorkspaceMRU() {
    let tree = TreeState()
        .addWorkspace(name: "1")
        .addWorkspace(name: "2")
    let ws1Id = tree.workspaceIds[0]
    let ws2Id = tree.workspaceIds[1]

    let (t1, win1) = insertTestWindow(tree, parent: ws1Id, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: ws2Id, windowId: 2)

    // Focus window in workspace 2
    let t3 = t2.setFocus(win2)
    #expect(t3.workspaceMRU == ["2", "1"])

    // Focus window in workspace 1
    let t4 = t3.setFocus(win1)
    #expect(t4.workspaceMRU == ["1", "2"])
}

@Test func setFocusOnNonWindowIsNoop() {
    let (tree, wsId) = treeWithWorkspace()
    let result = tree.setFocus(wsId)
    #expect(result.focusedWindowId == nil)
}

// MARK: - Query methods

@Test func workspaceContainingFindsTransitiveParent() {
    let (tree, wsId) = treeWithWorkspace(name: "dev")
    let t1 = tree.insertContainer(inParent: wsId, layout: .horizontal)
    let containerId = t1.workspaceNode(wsId)!.childIds[0]
    let (t2, winId) = insertTestWindow(t1, parent: containerId, windowId: 1)

    let ws = t2.workspaceContaining(winId)
    #expect(ws?.name == "dev")
}

@Test func allWindowsReturnsEveryWindow() {
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, _) = insertTestWindow(t1, parent: wsId, windowId: 2)
    let t3 = t2.insertContainer(inParent: wsId, layout: .horizontal)
    let containerId = t3.workspaceNode(wsId)!.childIds.last!
    let (t4, _) = insertTestWindow(t3, parent: containerId, windowId: 3)

    let windows = t4.allWindows
    #expect(windows.count == 3)
    let ids = Set(windows.map(\.windowId))
    #expect(ids == [1, 2, 3])
}

// MARK: - BSP insertion

@Test func bspFirstWindowAddsAsSibling() {
    // With only 1 window in workspace, BSP just adds as sibling (no container)
    let (tree, wsId) = treeWithWorkspace()
    let (t1, win1) = insertTestWindow(tree, parent: wsId, windowId: 1)

    let t2 = t1.insertWindowBSP(
        windowId: 2, appPid: 1, appName: "App", title: "W2",
        nearWindowId: win1
    )

    let ws = t2.workspaceNode(wsId)!
    #expect(ws.childIds.count == 2)
    // Both should be direct window children (no container)
    #expect(t2.windowNode(ws.childIds[0]) != nil)
    #expect(t2.windowNode(ws.childIds[1]) != nil)
}

@Test func bspThirdWindowCreatesContainer() {
    // With 2 windows, BSP wraps the focused one in a container
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: wsId, windowId: 2)

    let t3 = t2.insertWindowBSP(
        windowId: 3, appPid: 1, appName: "App", title: "W3",
        nearWindowId: win2
    )

    let ws = t3.workspaceNode(wsId)!
    // Workspace should have [W1, container]
    #expect(ws.childIds.count == 2)
    #expect(t3.windowNode(ws.childIds[0]) != nil) // W1
    let container = t3.containerNode(ws.childIds[1])!
    // Container should be vertical (alternated from workspace's horizontal)
    #expect(container.layout == .vertical)
    #expect(container.childIds.count == 2)
    // Container has [W2, W3]
    #expect(t3.windowNode(container.childIds[0])!.windowId == 2)
    #expect(t3.windowNode(container.childIds[1])!.windowId == 3)
}

@Test func bspFourthWindowNestedContainer() {
    // BSP split on W3 (inside vertical container) creates a horizontal sub-container
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: wsId, windowId: 2)
    let t3 = t2.insertWindowBSP(
        windowId: 3, appPid: 1, appName: "App", title: "W3",
        nearWindowId: win2
    )
    let win3 = t3.allWindows.first { $0.windowId == 3 }!.id

    let t4 = t3.insertWindowBSP(
        windowId: 4, appPid: 1, appName: "App", title: "W4",
        nearWindowId: win3
    )

    // Tree should be: workspace → [W1, vContainer → [W2, hContainer → [W3, W4]]]
    let ws = t4.workspaceNode(wsId)!
    #expect(ws.childIds.count == 2)
    let vContainer = t4.containerNode(ws.childIds[1])!
    #expect(vContainer.layout == .vertical)
    #expect(vContainer.childIds.count == 2)
    let hContainer = t4.containerNode(vContainer.childIds[1])!
    #expect(hContainer.layout == .horizontal)
    #expect(hContainer.childIds.count == 2)
    #expect(t4.windowNode(hContainer.childIds[0])!.windowId == 3)
    #expect(t4.windowNode(hContainer.childIds[1])!.windowId == 4)
}

// MARK: - Container collapse on removal

@Test func removeFromBSPCollapsesContainer() {
    // Build BSP tree: workspace → [W1, vContainer → [W2, W3]]
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: wsId, windowId: 2)
    let t3 = t2.insertWindowBSP(
        windowId: 3, appPid: 1, appName: "App", title: "W3",
        nearWindowId: win2
    )

    // Remove W3 — container should collapse, leaving workspace → [W1, W2]
    let win3 = t3.allWindows.first { $0.windowId == 3 }!.id
    let t4 = t3.removeNode(win3)

    let ws = t4.workspaceNode(wsId)!
    #expect(ws.childIds.count == 2)
    #expect(t4.windowNode(ws.childIds[0])!.windowId == 1)
    #expect(t4.windowNode(ws.childIds[1])!.windowId == 2)
    // Container should be gone
    #expect(t4.nodes.values.compactMap { if case .tilingContainer = $0 { true } else { nil } }.isEmpty)
}

@Test func removeFromNestedBSPCollapsesChain() {
    // Build: workspace → [W1, vContainer → [W2, hContainer → [W3, W4]]]
    let (tree, wsId) = treeWithWorkspace()
    let (t1, _) = insertTestWindow(tree, parent: wsId, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: wsId, windowId: 2)
    let t3 = t2.insertWindowBSP(
        windowId: 3, appPid: 1, appName: "App", title: "W3",
        nearWindowId: win2
    )
    let win3id = t3.allWindows.first { $0.windowId == 3 }!.id
    let t4 = t3.insertWindowBSP(
        windowId: 4, appPid: 1, appName: "App", title: "W4",
        nearWindowId: win3id
    )

    // Remove W4 — hContainer collapses, leaving vContainer → [W2, W3]
    let win4 = t4.allWindows.first { $0.windowId == 4 }!.id
    let t5 = t4.removeNode(win4)

    let ws = t5.workspaceNode(wsId)!
    #expect(ws.childIds.count == 2)
    let vContainer = t5.containerNode(ws.childIds[1])!
    #expect(vContainer.childIds.count == 2)
    #expect(t5.windowNode(vContainer.childIds[0])!.windowId == 2)
    #expect(t5.windowNode(vContainer.childIds[1])!.windowId == 3)

    // Remove W2 — vContainer collapses, leaving workspace → [W1, W3]
    let win2id = t5.allWindows.first { $0.windowId == 2 }!.id
    let t6 = t5.removeNode(win2id)

    let ws2 = t6.workspaceNode(wsId)!
    #expect(ws2.childIds.count == 2)
    #expect(t6.windowNode(ws2.childIds[0])!.windowId == 1)
    #expect(t6.windowNode(ws2.childIds[1])!.windowId == 3)
}

@Test func moveFromBSPCollapsesSourceContainer() {
    // Build BSP tree: workspace1 → [W1, vContainer → [W2, W3]], workspace2 → []
    let tree = TreeState()
        .addWorkspace(name: "1")
        .addWorkspace(name: "2")
    let ws1Id = tree.workspaceIds[0]
    let ws2Id = tree.workspaceIds[1]

    let (t1, _) = insertTestWindow(tree, parent: ws1Id, windowId: 1)
    let (t2, win2) = insertTestWindow(t1, parent: ws1Id, windowId: 2)
    let t3 = t2.insertWindowBSP(
        windowId: 3, appPid: 1, appName: "App", title: "W3",
        nearWindowId: win2
    )

    // Move W3 to workspace2 — container should collapse
    let win3 = t3.allWindows.first { $0.windowId == 3 }!.id
    let t4 = t3.moveNode(win3, toParent: ws2Id, atIndex: 0)

    let ws1 = t4.workspaceNode(ws1Id)!
    #expect(ws1.childIds.count == 2)
    #expect(t4.windowNode(ws1.childIds[0])!.windowId == 1)
    #expect(t4.windowNode(ws1.childIds[1])!.windowId == 2)
}
