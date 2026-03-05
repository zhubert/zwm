import CoreGraphics

extension TreeState {
    // MARK: - Workspace mutations

    public func addWorkspace(name: String, monitorId: UInt32? = nil) -> TreeState {
        var gen = idGenerator
        let wsId = gen.generate()
        let ws = WorkspaceNode(id: wsId, name: name, monitorId: monitorId)
        var nodes = self.nodes
        nodes[wsId] = .workspace(ws)
        return with(
            nodes: nodes,
            workspaceIds: workspaceIds + [wsId],
            workspaceMRU: workspaceMRU + [name],
            idGenerator: gen
        )
    }

    // MARK: - Window mutations (BSP)

    /// Insert a window using BSP (binary space partitioning).
    /// If the focused window's parent has only 0–1 tiling children, the new window is added as a sibling.
    /// Otherwise the focused window is wrapped in a new container (with alternated layout direction)
    /// alongside the new window.
    public func insertWindowBSP(
        windowId: UInt32,
        appPid: Int32,
        appName: String,
        title: String,
        nearWindowId: NodeId
    ) -> TreeState {
        guard let nearWin = windowNode(nearWindowId) else { return self }
        let parentId = nearWin.parentId
        guard let parentNode = node(parentId) else { return self }

        switch parentNode {
        case .workspace, .tilingContainer: break
        case .window: return self
        }

        let parentChildIds = parentNode.childIds

        // Count tiling children (windows in .tiling state + containers)
        let allNodes = self.nodes
        let tilingChildCount = parentChildIds.filter { id in
            if case .window(let w) = allNodes[id] { return w.state == .tiling }
            return allNodes[id] != nil
        }.count

        // If workspace has 0–1 tiling children, just add as sibling (no extra container)
        if case .workspace = parentNode, tilingChildCount <= 1 {
            return insertWindow(
                windowId: windowId, appPid: appPid,
                appName: appName, title: title,
                inParent: parentId, afterNodeId: nearWindowId
            )
        }

        // Wrap nearWindow + newWindow in a container with alternated direction
        let childLayout: Layout = parentNode.layout == .horizontal ? .vertical : .horizontal

        var gen = idGenerator
        let containerId = gen.generate()
        let newWindowNodeId = gen.generate()

        var nodes = self.nodes

        let newWindow = WindowNode(
            id: newWindowNodeId, parentId: containerId,
            windowId: windowId, appPid: appPid, appName: appName, title: title,
            state: .tiling, weight: 1.0
        )
        nodes[newWindowNodeId] = .window(newWindow)

        let container = TilingContainerNode(
            id: containerId, parentId: parentId,
            childIds: [nearWindowId, newWindowNodeId],
            layout: childLayout, weight: nearWin.weight
        )
        nodes[containerId] = .tilingContainer(container)

        // Re-parent nearWindow into the new container (reset weight to 1.0)
        nodes[nearWindowId] = .window(nearWin.with(parentId: containerId, weight: 1.0))

        // Replace nearWindowId with containerId in parent's child list
        nodes[parentId] = parentNode.replacingChildren {
            $0.map { $0 == nearWindowId ? containerId : $0 }
        }

        return with(nodes: nodes, idGenerator: gen)
    }

    // MARK: - Window mutations

    /// Insert a tiling window into a workspace or container.
    public func insertWindow(
        windowId: UInt32,
        appPid: Int32,
        appName: String,
        title: String,
        inParent parentId: NodeId,
        afterNodeId: NodeId? = nil,
        weight: Double = 1.0
    ) -> TreeState {
        guard let parentNode = nodes[parentId] else { return self }
        var gen = idGenerator
        let nodeId = gen.generate()
        let window = WindowNode(
            id: nodeId, parentId: parentId,
            windowId: windowId, appPid: appPid,
            appName: appName, title: title,
            state: .tiling, weight: weight
        )
        var nodes = self.nodes
        nodes[nodeId] = .window(window)
        nodes[parentId] = parentNode.insertingChild(nodeId, after: afterNodeId)

        return with(nodes: nodes, idGenerator: gen)
    }

    /// Remove a node and all its descendants from the tree.
    public func removeNode(_ id: NodeId) -> TreeState {
        guard let node = nodes[id] else { return self }
        var nodes = self.nodes

        // Collect all descendant IDs to remove
        var toRemove: [NodeId] = []
        var stack: [NodeId] = [id]
        while let current = stack.popLast() {
            toRemove.append(current)
            if let n = nodes[current] {
                stack.append(contentsOf: n.childIds)
            }
        }

        for removeId in toRemove {
            nodes.removeValue(forKey: removeId)
        }

        // Remove from parent's child list
        if let parentId = node.parentId, let parentNode = nodes[parentId] {
            nodes[parentId] = parentNode.removingChild(id)
        }

        // Collapse single-child tiling containers up the tree
        if let parentId = node.parentId {
            TreeState.collapseSingleChildContainers(&nodes, startingAt: parentId)
        }

        // If a workspace now has a sole container child, flatten it
        for wsId in workspaceIds {
            TreeState.flattenSoleContainerInWorkspace(&nodes, workspaceId: wsId)
        }

        // Clear focus if the focused window was removed
        let newFocus = toRemove.contains(focusedWindowId ?? NodeId(rawValue: 0))
            ? nil : focusedWindowId

        let newWorkspaceIds = workspaceIds.filter { !toRemove.contains($0) }
        let removedWsNames = toRemove.compactMap { wsId -> String? in
            if case .workspace(let ws) = self.nodes[wsId] { return ws.name }
            return nil
        }
        let newMRU = workspaceMRU.filter { !removedWsNames.contains($0) }

        return TreeState(
            nodes: nodes,
            workspaceIds: newWorkspaceIds,
            focusedWindowId: newFocus,
            workspaceMRU: newMRU,
            idGenerator: idGenerator
        )
    }

    /// Move a node to a new parent at a specific index.
    public func moveNode(_ id: NodeId, toParent newParentId: NodeId, atIndex index: Int) -> TreeState {
        guard let node = nodes[id], let _ = nodes[newParentId] else { return self }

        var nodes = self.nodes

        // Remove from old parent
        if let oldParentId = node.parentId, let oldParent = nodes[oldParentId] {
            nodes[oldParentId] = oldParent.removingChild(id)
            TreeState.collapseSingleChildContainers(&nodes, startingAt: oldParentId)
        }

        // Update the node's parentId
        switch node {
        case .window(let w):
            nodes[id] = .window(w.with(parentId: newParentId))
        case .tilingContainer(let tc):
            nodes[id] = .tilingContainer(tc.with(parentId: newParentId))
        case .workspace:
            return self
        }

        // Add to new parent's child list
        if let newParent = nodes[newParentId] {
            nodes[newParentId] = newParent.insertingChild(id, at: index)
        }

        return with(nodes: nodes)
    }

    // MARK: - Container mutations

    public func insertContainer(
        inParent parentId: NodeId,
        layout: Layout = .horizontal,
        weight: Double = 1.0
    ) -> TreeState {
        guard let parentNode = nodes[parentId] else { return self }
        var gen = idGenerator
        let containerId = gen.generate()
        let container = TilingContainerNode(
            id: containerId, parentId: parentId, layout: layout, weight: weight
        )
        var nodes = self.nodes
        nodes[containerId] = .tilingContainer(container)
        nodes[parentId] = parentNode.insertingChild(containerId, after: nil)

        return with(nodes: nodes, idGenerator: gen)
    }

    public func setLayout(_ id: NodeId, _ layout: Layout) -> TreeState {
        guard case .tilingContainer(let tc) = nodes[id] else { return self }
        var nodes = self.nodes
        nodes[id] = .tilingContainer(tc.with(layout: layout))
        return with(nodes: nodes)
    }

    public func setWorkspaceLayout(_ id: NodeId, _ layout: Layout) -> TreeState {
        guard case .workspace(let ws) = nodes[id] else { return self }
        var nodes = self.nodes
        nodes[id] = .workspace(ws.with(layout: layout))
        return with(nodes: nodes)
    }

    // MARK: - Window state

    public func setWindowState(_ id: NodeId, _ newState: WindowState) -> TreeState {
        guard case .window(let win) = nodes[id] else { return self }
        guard win.state != newState else { return self }

        var nodes = self.nodes
        nodes[id] = .window(win.with(state: newState))

        // Update workspace's floatingWindowIds and childIds
        if let ws = workspaceContaining(id), case .workspace(let wsNode) = nodes[ws.id] {
            var childIds = wsNode.childIds
            var floatingIds = wsNode.floatingWindowIds

            let wasFloating: Bool = if case .floating = win.state { true } else { false }
            let isFloating: Bool = if case .floating = newState { true } else { false }

            if !wasFloating && isFloating {
                childIds = childIds.filter { $0 != id }
                if !floatingIds.contains(id) { floatingIds.append(id) }
            } else if wasFloating && !isFloating {
                floatingIds = floatingIds.filter { $0 != id }
                if !childIds.contains(id) { childIds.append(id) }
            }

            nodes[ws.id] = .workspace(wsNode.with(childIds: childIds, floatingWindowIds: floatingIds))
        }

        return with(nodes: nodes)
    }

    // MARK: - Window ID replacement

    public func replaceWindowId(_ nodeId: NodeId, newWindowId: UInt32, newTitle: String? = nil) -> TreeState {
        guard case .window(let win) = nodes[nodeId] else { return self }
        var nodes = self.nodes
        nodes[nodeId] = .window(win.with(windowId: newWindowId, title: newTitle ?? win.title))
        return with(nodes: nodes)
    }

    // MARK: - Focus

    public func setFocus(_ windowId: NodeId) -> TreeState {
        guard case .window = nodes[windowId] else { return self }
        var mru = workspaceMRU
        if let ws = workspaceContaining(windowId) {
            mru = [ws.name] + mru.filter { $0 != ws.name }
        }
        return with(focusedWindowId: windowId, workspaceMRU: mru)
    }

    // MARK: - Container collapse

    static func flattenSoleContainerInWorkspace(_ nodes: inout [NodeId: Node], workspaceId: NodeId) {
        guard case .workspace(let ws) = nodes[workspaceId],
              ws.childIds.count == 1,
              let onlyChildId = ws.childIds.first,
              case .tilingContainer(let tc) = nodes[onlyChildId] else { return }

        // Re-parent all container children to the workspace
        for childId in tc.childIds {
            switch nodes[childId] {
            case .window(let w):
                nodes[childId] = .window(w.with(parentId: workspaceId))
            case .tilingContainer(let childTc):
                nodes[childId] = .tilingContainer(childTc.with(parentId: workspaceId))
            default:
                break
            }
        }

        nodes[workspaceId] = .workspace(ws.with(childIds: tc.childIds))
        nodes.removeValue(forKey: onlyChildId)
    }

    static func collapseSingleChildContainers(_ nodes: inout [NodeId: Node], startingAt id: NodeId) {
        var current = id
        while case .tilingContainer(let tc) = nodes[current] {
            if tc.childIds.count == 1 {
                let childId = tc.childIds[0]
                let grandparentId = tc.parentId

                // Update child's parentId and inherit container's weight
                switch nodes[childId] {
                case .window(let w):
                    nodes[childId] = .window(w.with(parentId: grandparentId, weight: tc.weight))
                case .tilingContainer(let childTc):
                    nodes[childId] = .tilingContainer(childTc.with(parentId: grandparentId, weight: tc.weight))
                default:
                    break
                }

                // Replace container with child in grandparent's children
                nodes[grandparentId] = nodes[grandparentId]?.replacingChildren {
                    $0.map { $0 == current ? childId : $0 }
                }

                nodes.removeValue(forKey: current)
                current = grandparentId
            } else if tc.childIds.isEmpty {
                let grandparentId = tc.parentId
                nodes[grandparentId] = nodes[grandparentId]?.removingChild(current)
                nodes.removeValue(forKey: current)
                current = grandparentId
            } else {
                break
            }
        }
    }
}
