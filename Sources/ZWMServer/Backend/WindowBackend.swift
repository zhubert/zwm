import CoreGraphics

/// Abstraction over macOS window management APIs.
/// Business logic uses this protocol — never AX calls directly.
/// AXBackend is the real implementation; MockBackend is for tests.
public protocol WindowBackend: Sendable {
    /// Enumerate all windows for all running apps.
    func discoverWindows() async throws -> [DiscoveredWindow]

    /// Set the frame (position + size) of a window.
    func setFrame(_ windowId: UInt32, _ frame: CGRect) async throws

    /// Focus a window (raise + activate its app).
    func focus(_ windowId: UInt32) async throws

    /// Close a window.
    func close(_ windowId: UInt32) async throws

    /// Minimize or unminimize a window.
    func setMinimized(_ windowId: UInt32, _ minimized: Bool) async throws

    /// Get current monitor info.
    func monitors() async -> [MonitorInfo]

    /// Check if a window still exists on screen (quick CGWindowList check).
    func windowExists(_ windowId: UInt32) async -> Bool

    /// Subscribe to window events. The handler is called for each event.
    func observe(_ handler: @escaping @Sendable (WindowEvent) -> Void) async throws
}

/// A window discovered during enumeration.
public struct DiscoveredWindow: Sendable, Equatable {
    public let windowId: UInt32
    public let pid: Int32
    public let appName: String
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let isFullscreen: Bool
    public let windowLevel: Int
    public let subrole: String

    /// Minimum dimension (width or height) for a window to be managed.
    public static let minManagedSize: CGFloat = 50

    public var isStandardWindow: Bool {
        let validSubrole = subrole.isEmpty || subrole == "AXStandardWindow"
        let largeEnough = frame.width >= Self.minManagedSize && frame.height >= Self.minManagedSize
        return validSubrole && largeEnough
    }

    public init(
        windowId: UInt32,
        pid: Int32,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        windowLevel: Int = 0,
        subrole: String = ""
    ) {
        self.windowId = windowId
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.windowLevel = windowLevel
        self.subrole = subrole
    }
}

/// Events emitted by the backend when windows/apps change.
public enum WindowEvent: Sendable, Equatable {
    case windowCreated(pid: Int32, windowId: UInt32, appName: String, title: String, subrole: String, frame: CGRect)
    case windowDestroyed(windowId: UInt32)
    case windowFocused(windowId: UInt32)
    case windowMoved(windowId: UInt32)
    case windowResized(windowId: UInt32)
    case windowMinimized(windowId: UInt32)
    case windowUnminimized(windowId: UInt32)
    case appLaunched(pid: Int32)
    case appTerminated(pid: Int32)
    case appActivated(pid: Int32)
    case appHidden(pid: Int32)
    case appUnhidden(pid: Int32)
    case spaceChanged
}
