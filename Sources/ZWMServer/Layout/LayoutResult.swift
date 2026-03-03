import CoreGraphics

public struct MonitorInfo: Sendable, Equatable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct GapConfig: Sendable, Equatable {
    public let inner: CGFloat
    public let outer: CGFloat

    public init(inner: CGFloat = 0, outer: CGFloat = 0) {
        self.inner = inner
        self.outer = outer
    }
}

public struct LayoutResult: Sendable, Equatable {
    public let frames: [NodeId: CGRect]

    public init(frames: [NodeId: CGRect] = [:]) {
        self.frames = frames
    }
}
