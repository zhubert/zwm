public struct TreeState: Sendable, Equatable {
    public let nodes: [NodeId: Node]
    public let workspaceIds: [NodeId]
    public let focusedWindowId: NodeId?
    public let workspaceMRU: [String]
    public var idGenerator: NodeIdGenerator

    public init(
        nodes: [NodeId: Node] = [:],
        workspaceIds: [NodeId] = [],
        focusedWindowId: NodeId? = nil,
        workspaceMRU: [String] = [],
        idGenerator: NodeIdGenerator = NodeIdGenerator()
    ) {
        self.nodes = nodes
        self.workspaceIds = workspaceIds
        self.focusedWindowId = focusedWindowId
        self.workspaceMRU = workspaceMRU
        self.idGenerator = idGenerator
    }

    // MARK: - Queries

    public func node(_ id: NodeId) -> Node? {
        nodes[id]
    }

    public func workspace(_ name: String) -> WorkspaceNode? {
        for wsId in workspaceIds {
            if case .workspace(let ws) = nodes[wsId], ws.name == name {
                return ws
            }
        }
        return nil
    }

    public func windowNode(_ id: NodeId) -> WindowNode? {
        if case .window(let w) = nodes[id] { return w }
        return nil
    }

    public func containerNode(_ id: NodeId) -> TilingContainerNode? {
        if case .tilingContainer(let c) = nodes[id] { return c }
        return nil
    }

    public func workspaceNode(_ id: NodeId) -> WorkspaceNode? {
        if case .workspace(let ws) = nodes[id] { return ws }
        return nil
    }

    /// All window nodes in the tree.
    public var allWindows: [WindowNode] {
        nodes.values.compactMap { if case .window(let w) = $0 { w } else { nil } }
    }

    /// Find the first window node within a subtree (depth-first).
    public func firstWindowId(in nodeId: NodeId) -> NodeId? {
        guard let node = nodes[nodeId] else { return nil }
        switch node {
        case .window: return nodeId
        case .tilingContainer(let tc):
            for child in tc.childIds {
                if let w = firstWindowId(in: child) { return w }
            }
            return nil
        case .workspace(let ws):
            for child in ws.childIds {
                if let w = firstWindowId(in: child) { return w }
            }
            return nil
        }
    }

    /// Find the workspace that (transitively) contains the given node.
    public func workspaceContaining(_ nodeId: NodeId) -> WorkspaceNode? {
        var current = nodeId
        while let node = nodes[current] {
            if case .workspace(let ws) = node { return ws }
            guard let pid = node.parentId else { return nil }
            current = pid
        }
        return nil
    }
}
