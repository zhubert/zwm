import CoreGraphics

// MARK: - Layout direction

public enum Layout: Sendable, Equatable {
    case horizontal
    case vertical
}

// MARK: - Window state

public enum WindowState: Sendable {
    case tiling
    case floating(CGRect)
    case fullscreen
    case minimized
}

extension WindowState: Equatable {
    public static func == (lhs: WindowState, rhs: WindowState) -> Bool {
        switch (lhs, rhs) {
        case (.tiling, .tiling), (.fullscreen, .fullscreen), (.minimized, .minimized):
            true
        case (.floating(let a), .floating(let b)):
            a.origin.x == b.origin.x && a.origin.y == b.origin.y
                && a.size.width == b.size.width && a.size.height == b.size.height
        default:
            false
        }
    }
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
}
