import CoreGraphics

// MARK: - Layout direction

public enum Layout: Sendable, Equatable {
    case horizontal
    case vertical
}

// MARK: - Window state

public enum WindowState: Sendable, Equatable {
    case tiling
    case floating(CGRect)
    case fullscreen
    case minimized
}

// MARK: - Node types

public struct WorkspaceNode: Sendable, Equatable {
    public let id: NodeId
    public let name: String
    public let childIds: [NodeId]
    public let floatingWindowIds: [NodeId]
    public let monitorId: UInt32?
    public let layout: Layout

    public init(
        id: NodeId,
        name: String,
        childIds: [NodeId] = [],
        floatingWindowIds: [NodeId] = [],
        monitorId: UInt32? = nil,
        layout: Layout = .horizontal
    ) {
        self.id = id
        self.name = name
        self.childIds = childIds
        self.floatingWindowIds = floatingWindowIds
        self.monitorId = monitorId
        self.layout = layout
    }

    public func with(
        childIds: [NodeId]? = nil,
        floatingWindowIds: [NodeId]? = nil,
        monitorId: UInt32?? = nil,
        layout: Layout? = nil
    ) -> WorkspaceNode {
        WorkspaceNode(
            id: id, name: name,
            childIds: childIds ?? self.childIds,
            floatingWindowIds: floatingWindowIds ?? self.floatingWindowIds,
            monitorId: monitorId ?? self.monitorId,
            layout: layout ?? self.layout
        )
    }
}

public struct TilingContainerNode: Sendable, Equatable {
    public let id: NodeId
    public let parentId: NodeId
    public let childIds: [NodeId]
    public let layout: Layout
    public let weight: Double

    public init(
        id: NodeId,
        parentId: NodeId,
        childIds: [NodeId] = [],
        layout: Layout = .horizontal,
        weight: Double = 1.0
    ) {
        self.id = id
        self.parentId = parentId
        self.childIds = childIds
        self.layout = layout
        self.weight = weight
    }

    public func with(
        parentId: NodeId? = nil,
        childIds: [NodeId]? = nil,
        layout: Layout? = nil,
        weight: Double? = nil
    ) -> TilingContainerNode {
        TilingContainerNode(
            id: id,
            parentId: parentId ?? self.parentId,
            childIds: childIds ?? self.childIds,
            layout: layout ?? self.layout,
            weight: weight ?? self.weight
        )
    }
}

public struct WindowNode: Sendable, Equatable {
    public let id: NodeId
    public let parentId: NodeId
    public let windowId: UInt32
    public let appPid: Int32
    public let appName: String
    public let title: String
    public let state: WindowState
    public let weight: Double

    public init(
        id: NodeId,
        parentId: NodeId,
        windowId: UInt32,
        appPid: Int32,
        appName: String,
        title: String,
        state: WindowState = .tiling,
        weight: Double = 1.0
    ) {
        self.id = id
        self.parentId = parentId
        self.windowId = windowId
        self.appPid = appPid
        self.appName = appName
        self.title = title
        self.state = state
        self.weight = weight
    }

    public func with(
        parentId: NodeId? = nil,
        windowId: UInt32? = nil,
        title: String? = nil,
        state: WindowState? = nil,
        weight: Double? = nil
    ) -> WindowNode {
        WindowNode(
            id: id,
            parentId: parentId ?? self.parentId,
            windowId: windowId ?? self.windowId,
            appPid: appPid, appName: appName,
            title: title ?? self.title,
            state: state ?? self.state,
            weight: weight ?? self.weight
        )
    }
}

// MARK: - Node enum

public enum Node: Sendable, Equatable {
    case workspace(WorkspaceNode)
    case tilingContainer(TilingContainerNode)
    case window(WindowNode)

    public var id: NodeId {
        switch self {
        case .workspace(let n): n.id
        case .tilingContainer(let n): n.id
        case .window(let n): n.id
        }
    }

    public var childIds: [NodeId] {
        switch self {
        case .workspace(let n): n.childIds
        case .tilingContainer(let n): n.childIds
        case .window: []
        }
    }

    public var parentId: NodeId? {
        switch self {
        case .workspace: nil
        case .tilingContainer(let n): n.parentId
        case .window(let n): n.parentId
        }
    }

    // MARK: - Child-list helpers

    func replacingChildren(_ transform: ([NodeId]) -> [NodeId]) -> Node {
        switch self {
        case .workspace(let ws):
            .workspace(ws.with(childIds: transform(ws.childIds)))
        case .tilingContainer(let tc):
            .tilingContainer(tc.with(childIds: transform(tc.childIds)))
        case .window:
            self
        }
    }

    func removingChild(_ id: NodeId) -> Node {
        switch self {
        case .workspace(let ws):
            .workspace(ws.with(
                childIds: ws.childIds.filter { $0 != id },
                floatingWindowIds: ws.floatingWindowIds.filter { $0 != id }
            ))
        case .tilingContainer(let tc):
            .tilingContainer(tc.with(childIds: tc.childIds.filter { $0 != id }))
        case .window:
            self
        }
    }

    func insertingChild(_ id: NodeId, after afterId: NodeId?) -> Node {
        replacingChildren { children in
            var result = children
            if let after = afterId, let idx = result.firstIndex(of: after) {
                result.insert(id, at: idx + 1)
            } else {
                result.append(id)
            }
            return result
        }
    }

    func insertingChild(_ id: NodeId, at index: Int) -> Node {
        replacingChildren { children in
            var result = children
            let clamped = min(index, result.count)
            result.insert(id, at: clamped)
            return result
        }
    }

    var layout: Layout {
        switch self {
        case .workspace(let ws): ws.layout
        case .tilingContainer(let tc): tc.layout
        default: .horizontal
        }
    }
}
