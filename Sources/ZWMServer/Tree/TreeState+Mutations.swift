import CoreGraphics

extension TreeState {
    // MARK: - Workspace mutations

    /// Add a new workspace to the tree.
    public func addWorkspace(name: String, monitorId: UInt32? = nil) -> TreeState {
        var gen = idGenerator
        let wsId = gen.generate()
        let ws = WorkspaceNode(id: wsId, name: name, monitorId: monitorId)
        var nodes = self.nodes
        nodes[wsId] = .workspace(ws)
        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds + [wsId],
            focusedWindowId: focusedWindowId,
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

        let parentLayout: Layout
        let parentChildIds: [NodeId]
        switch parentNode {
        case .workspace(let ws):
            parentLayout = ws.layout
            parentChildIds = ws.childIds
        case .tilingContainer(let tc):
            parentLayout = tc.layout
            parentChildIds = tc.childIds
        default:
            return self
        }

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
        let childLayout: Layout = parentLayout == .horizontal ? .vertical : .horizontal

        var gen = idGenerator
        let containerId = gen.generate()
        let newWindowNodeId = gen.generate()

        var nodes = self.nodes

        // Create the new window node
        let newWindow = WindowNode(
            id: newWindowNodeId, parentId: containerId,
            windowId: windowId, appPid: appPid, appName: appName, title: title,
            state: .tiling, weight: 1.0
        )
        nodes[newWindowNodeId] = .window(newWindow)

        // Create the container holding [nearWindow, newWindow]
        let container = TilingContainerNode(
            id: containerId, parentId: parentId,
            childIds: [nearWindowId, newWindowNodeId],
            layout: childLayout, weight: nearWin.weight
        )
        nodes[containerId] = .tilingContainer(container)

        // Re-parent nearWindow into the new container (reset weight to 1.0)
        nodes[nearWindowId] = .window(WindowNode(
            id: nearWin.id, parentId: containerId,
            windowId: nearWin.windowId, appPid: nearWin.appPid,
            appName: nearWin.appName, title: nearWin.title,
            state: nearWin.state, weight: 1.0
        ))

        // Replace nearWindowId with containerId in parent's child list
        switch parentNode {
        case .workspace(let ws):
            nodes[parentId] = .workspace(WorkspaceNode(
                id: ws.id, name: ws.name,
                childIds: ws.childIds.map { $0 == nearWindowId ? containerId : $0 },
                floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
                layout: ws.layout
            ))
        case .tilingContainer(let tc):
            nodes[parentId] = .tilingContainer(TilingContainerNode(
                id: tc.id, parentId: tc.parentId,
                childIds: tc.childIds.map { $0 == nearWindowId ? containerId : $0 },
                layout: tc.layout, weight: tc.weight
            ))
        default:
            break
        }

        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: gen
        )
    }

    // MARK: - Window mutations

    /// Insert a tiling window into a workspace or container.
    /// If `afterNodeId` is provided and exists in the parent's children, the window is inserted after it.
    /// Otherwise it is appended to the end.
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
            id: nodeId,
            parentId: parentId,
            windowId: windowId,
            appPid: appPid,
            appName: appName,
            title: title,
            state: .tiling,
            weight: weight
        )
        var nodes = self.nodes
        nodes[nodeId] = .window(window)

        // Add to parent's child list
        switch parentNode {
        case .workspace(var ws):
            var children = ws.childIds
            if let after = afterNodeId, let idx = children.firstIndex(of: after) {
                children.insert(nodeId, at: idx + 1)
            } else {
                children.append(nodeId)
            }
            ws = WorkspaceNode(
                id: ws.id, name: ws.name, childIds: children,
                floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
                layout: ws.layout
            )
            nodes[parentId] = .workspace(ws)
        case .tilingContainer(let tc):
            var children = tc.childIds
            if let after = afterNodeId, let idx = children.firstIndex(of: after) {
                children.insert(nodeId, at: idx + 1)
            } else {
                children.append(nodeId)
            }
            let newTc = TilingContainerNode(
                id: tc.id, parentId: tc.parentId, childIds: children,
                layout: tc.layout, weight: tc.weight
            )
            nodes[parentId] = .tilingContainer(newTc)
        case .window:
            return self // can't insert into a window
        }

        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: gen
        )
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
            switch parentNode {
            case .workspace(let ws):
                let newChildren = ws.childIds.filter { $0 != id }
                let newFloating = ws.floatingWindowIds.filter { $0 != id }
                nodes[parentId] = .workspace(WorkspaceNode(
                    id: ws.id, name: ws.name, childIds: newChildren,
                    floatingWindowIds: newFloating, monitorId: ws.monitorId,
                    layout: ws.layout
                ))
            case .tilingContainer(let tc):
                let newChildren = tc.childIds.filter { $0 != id }
                nodes[parentId] = .tilingContainer(TilingContainerNode(
                    id: tc.id, parentId: tc.parentId, childIds: newChildren,
                    layout: tc.layout, weight: tc.weight
                ))
            case .window:
                break
            }
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

        // Remove workspace if it was one
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

        // First remove from old parent
        var nodes = self.nodes
        if let oldParentId = node.parentId, let oldParent = nodes[oldParentId] {
            switch oldParent {
            case .workspace(let ws):
                nodes[oldParentId] = .workspace(WorkspaceNode(
                    id: ws.id, name: ws.name,
                    childIds: ws.childIds.filter { $0 != id },
                    floatingWindowIds: ws.floatingWindowIds.filter { $0 != id },
                    monitorId: ws.monitorId, layout: ws.layout
                ))
            case .tilingContainer(let tc):
                nodes[oldParentId] = .tilingContainer(TilingContainerNode(
                    id: tc.id, parentId: tc.parentId,
                    childIds: tc.childIds.filter { $0 != id },
                    layout: tc.layout, weight: tc.weight
                ))
            case .window:
                break
            }

            // Collapse single-child containers left behind
            TreeState.collapseSingleChildContainers(&nodes, startingAt: oldParentId)
        }

        // Update the node's parentId
        switch node {
        case .window(let w):
            nodes[id] = .window(WindowNode(
                id: w.id, parentId: newParentId, windowId: w.windowId,
                appPid: w.appPid, appName: w.appName, title: w.title,
                state: w.state, weight: w.weight
            ))
        case .tilingContainer(let tc):
            nodes[id] = .tilingContainer(TilingContainerNode(
                id: tc.id, parentId: newParentId, childIds: tc.childIds,
                layout: tc.layout, weight: tc.weight
            ))
        case .workspace:
            return self // workspaces can't be moved
        }

        // Add to new parent's child list
        if let newParent = nodes[newParentId] {
            switch newParent {
            case .workspace(let ws):
                var children = ws.childIds
                let clampedIndex = min(index, children.count)
                children.insert(id, at: clampedIndex)
                nodes[newParentId] = .workspace(WorkspaceNode(
                    id: ws.id, name: ws.name, childIds: children,
                    floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
                    layout: ws.layout
                ))
            case .tilingContainer(let tc):
                var children = tc.childIds
                let clampedIndex = min(index, children.count)
                children.insert(id, at: clampedIndex)
                nodes[newParentId] = .tilingContainer(TilingContainerNode(
                    id: tc.id, parentId: tc.parentId, childIds: children,
                    layout: tc.layout, weight: tc.weight
                ))
            case .window:
                return self
            }
        }

        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: idGenerator
        )
    }

    // MARK: - Container mutations

    /// Insert a tiling container into a parent.
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

        switch parentNode {
        case .workspace(let ws):
            nodes[parentId] = .workspace(WorkspaceNode(
                id: ws.id, name: ws.name,
                childIds: ws.childIds + [containerId],
                floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
                layout: ws.layout
            ))
        case .tilingContainer(let tc):
            nodes[parentId] = .tilingContainer(TilingContainerNode(
                id: tc.id, parentId: tc.parentId,
                childIds: tc.childIds + [containerId],
                layout: tc.layout, weight: tc.weight
            ))
        case .window:
            return self
        }

        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: gen
        )
    }

    /// Change the layout of a tiling container.
    public func setLayout(_ id: NodeId, _ layout: Layout) -> TreeState {
        guard case .tilingContainer(let tc) = nodes[id] else { return self }
        var nodes = self.nodes
        nodes[id] = .tilingContainer(TilingContainerNode(
            id: tc.id, parentId: tc.parentId, childIds: tc.childIds,
            layout: layout, weight: tc.weight
        ))
        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: idGenerator
        )
    }

    /// Change the layout of a workspace.
    public func setWorkspaceLayout(_ id: NodeId, _ layout: Layout) -> TreeState {
        guard case .workspace(let ws) = nodes[id] else { return self }
        var nodes = self.nodes
        nodes[id] = .workspace(WorkspaceNode(
            id: ws.id, name: ws.name, childIds: ws.childIds,
            floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
            layout: layout
        ))
        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: idGenerator
        )
    }

    // MARK: - Window state

    /// Change a window's state (tiling/fullscreen/floating), updating workspace lists accordingly.
    public func setWindowState(_ id: NodeId, _ newState: WindowState) -> TreeState {
        guard case .window(let win) = nodes[id] else { return self }
        let oldState = win.state
        guard oldState != newState else { return self }

        var nodes = self.nodes

        // Update the window node's state
        nodes[id] = .window(WindowNode(
            id: win.id, parentId: win.parentId, windowId: win.windowId,
            appPid: win.appPid, appName: win.appName, title: win.title,
            state: newState, weight: win.weight
        ))

        // Update workspace's floatingWindowIds and childIds
        if let ws = workspaceContaining(id), case .workspace(let wsNode) = nodes[ws.id] {
            var childIds = wsNode.childIds
            var floatingIds = wsNode.floatingWindowIds

            let wasFloating: Bool
            if case .floating = oldState { wasFloating = true } else { wasFloating = false }
            let isFloating: Bool
            if case .floating = newState { isFloating = true } else { isFloating = false }

            if !wasFloating && isFloating {
                // Moving to floating: remove from childIds, add to floatingWindowIds
                childIds = childIds.filter { $0 != id }
                if !floatingIds.contains(id) { floatingIds.append(id) }
            } else if wasFloating && !isFloating {
                // Moving from floating: remove from floatingWindowIds, add to childIds
                floatingIds = floatingIds.filter { $0 != id }
                if !childIds.contains(id) { childIds.append(id) }
            }

            nodes[ws.id] = .workspace(WorkspaceNode(
                id: wsNode.id, name: wsNode.name, childIds: childIds,
                floatingWindowIds: floatingIds, monitorId: wsNode.monitorId,
                layout: wsNode.layout
            ))
        }

        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: idGenerator
        )
    }

    // MARK: - Window ID replacement

    /// Replace a window's macOS window ID in-place, preserving its position in the tree.
    /// Used when an app (like Ghostty) recycles window IDs on tab close.
    public func replaceWindowId(_ nodeId: NodeId, newWindowId: UInt32, newTitle: String? = nil) -> TreeState {
        guard case .window(let win) = nodes[nodeId] else { return self }
        var nodes = self.nodes
        nodes[nodeId] = .window(WindowNode(
            id: win.id, parentId: win.parentId,
            windowId: newWindowId, appPid: win.appPid,
            appName: win.appName, title: newTitle ?? win.title,
            state: win.state, weight: win.weight
        ))
        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: focusedWindowId,
            workspaceMRU: workspaceMRU,
            idGenerator: idGenerator
        )
    }

    // MARK: - Focus

    /// Set focus to a window, updating workspace MRU.
    public func setFocus(_ windowId: NodeId) -> TreeState {
        guard case .window = nodes[windowId] else { return self }
        var mru = workspaceMRU
        if let ws = workspaceContaining(windowId) {
            mru = [ws.name] + mru.filter { $0 != ws.name }
        }
        return TreeState(
            nodes: nodes,
            workspaceIds: workspaceIds,
            focusedWindowId: windowId,
            workspaceMRU: mru,
            idGenerator: idGenerator
        )
    }

    // MARK: - Container collapse

    /// If a workspace has exactly one child and it's a tiling container, flatten
    /// the container's children into the workspace (so they use the workspace's layout).
    static func flattenSoleContainerInWorkspace(_ nodes: inout [NodeId: Node], workspaceId: NodeId) {
        guard case .workspace(let ws) = nodes[workspaceId],
              ws.childIds.count == 1,
              let onlyChildId = ws.childIds.first,
              case .tilingContainer(let tc) = nodes[onlyChildId] else { return }

        // Re-parent all container children to the workspace
        for childId in tc.childIds {
            switch nodes[childId] {
            case .window(let w):
                nodes[childId] = .window(WindowNode(
                    id: w.id, parentId: workspaceId,
                    windowId: w.windowId, appPid: w.appPid,
                    appName: w.appName, title: w.title,
                    state: w.state, weight: w.weight
                ))
            case .tilingContainer(let childTc):
                nodes[childId] = .tilingContainer(TilingContainerNode(
                    id: childTc.id, parentId: workspaceId,
                    childIds: childTc.childIds,
                    layout: childTc.layout, weight: childTc.weight
                ))
            default:
                break
            }
        }

        // Replace workspace's children with the container's children
        nodes[workspaceId] = .workspace(WorkspaceNode(
            id: ws.id, name: ws.name,
            childIds: tc.childIds,
            floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
            layout: ws.layout
        ))

        // Remove the container
        nodes.removeValue(forKey: onlyChildId)
    }

    /// Walk up the tree from `startingAt`, collapsing any tiling container that has
    /// exactly one child (promoting that child to the grandparent) or zero children (removing it).
    static func collapseSingleChildContainers(_ nodes: inout [NodeId: Node], startingAt id: NodeId) {
        var current = id
        while case .tilingContainer(let tc) = nodes[current] {
            if tc.childIds.count == 1 {
                let childId = tc.childIds[0]
                let grandparentId = tc.parentId

                // Update child's parentId and inherit container's weight
                switch nodes[childId] {
                case .window(let w):
                    nodes[childId] = .window(WindowNode(
                        id: w.id, parentId: grandparentId,
                        windowId: w.windowId, appPid: w.appPid,
                        appName: w.appName, title: w.title,
                        state: w.state, weight: tc.weight
                    ))
                case .tilingContainer(let childTc):
                    nodes[childId] = .tilingContainer(TilingContainerNode(
                        id: childTc.id, parentId: grandparentId,
                        childIds: childTc.childIds,
                        layout: childTc.layout, weight: tc.weight
                    ))
                default:
                    break
                }

                // Replace container with child in grandparent's children
                switch nodes[grandparentId] {
                case .workspace(let ws):
                    nodes[grandparentId] = .workspace(WorkspaceNode(
                        id: ws.id, name: ws.name,
                        childIds: ws.childIds.map { $0 == current ? childId : $0 },
                        floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
                        layout: ws.layout
                    ))
                case .tilingContainer(let grandTc):
                    nodes[grandparentId] = .tilingContainer(TilingContainerNode(
                        id: grandTc.id, parentId: grandTc.parentId,
                        childIds: grandTc.childIds.map { $0 == current ? childId : $0 },
                        layout: grandTc.layout, weight: grandTc.weight
                    ))
                default:
                    break
                }

                nodes.removeValue(forKey: current)
                current = grandparentId
            } else if tc.childIds.isEmpty {
                let grandparentId = tc.parentId
                switch nodes[grandparentId] {
                case .workspace(let ws):
                    nodes[grandparentId] = .workspace(WorkspaceNode(
                        id: ws.id, name: ws.name,
                        childIds: ws.childIds.filter { $0 != current },
                        floatingWindowIds: ws.floatingWindowIds, monitorId: ws.monitorId,
                        layout: ws.layout
                    ))
                case .tilingContainer(let grandTc):
                    nodes[grandparentId] = .tilingContainer(TilingContainerNode(
                        id: grandTc.id, parentId: grandTc.parentId,
                        childIds: grandTc.childIds.filter { $0 != current },
                        layout: grandTc.layout, weight: grandTc.weight
                    ))
                default:
                    break
                }
                nodes.removeValue(forKey: current)
                current = grandparentId
            } else {
                break
            }
        }
    }
}
