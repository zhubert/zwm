import CoreGraphics
import Foundation

/// In-memory WindowBackend for tests.
/// Records all calls and lets tests inspect what was requested.
public final class MockBackend: WindowBackend, @unchecked Sendable {
    private let lock = UnfairLock()
    private var state = MockState()

    public init() {}

    // MARK: - Test setup

    public func addWindow(_ window: DiscoveredWindow) {
        lock.withLock { state.windows[window.windowId] = window }
    }

    public func removeWindow(_ windowId: UInt32) {
        lock.withLock { _ = state.windows.removeValue(forKey: windowId) }
    }

    public func setMonitors(_ monitors: [MonitorInfo]) {
        lock.withLock { state.monitors = monitors }
    }

    /// Simulate an event from the OS.
    public func emit(_ event: WindowEvent) {
        let h = lock.withLock { state.handler }
        h?(event)
    }

    /// Set which window IDs are considered "live" for windowExists checks.
    /// When nil (default), all windows are considered to exist.
    public func setLiveWindowIds(_ ids: Set<UInt32>?) {
        lock.withLock { state.liveWindowIds = ids }
    }

    // MARK: - Recorded call inspection

    public var setFrameCalls: [(windowId: UInt32, frame: CGRect)] {
        lock.withLock { state.setFrameCalls }
    }

    public var focusCalls: [UInt32] {
        lock.withLock { state.focusCalls }
    }

    public var closeCalls: [UInt32] {
        lock.withLock { state.closeCalls }
    }

    public var minimizeCalls: [(windowId: UInt32, minimized: Bool)] {
        lock.withLock { state.minimizeCalls }
    }

    public func resetRecordedCalls() {
        lock.withLock {
            state.setFrameCalls = []
            state.focusCalls = []
            state.closeCalls = []
            state.minimizeCalls = []
        }
    }

    // MARK: - WindowBackend conformance

    public func discoverWindows() async throws -> [DiscoveredWindow] {
        lock.withLock { Array(state.windows.values) }
    }

    public func setFrame(_ windowId: UInt32, _ frame: CGRect) async throws {
        lock.withLock { state.setFrameCalls.append((windowId: windowId, frame: frame)) }
    }

    public func focus(_ windowId: UInt32) async throws {
        lock.withLock { state.focusCalls.append(windowId) }
    }

    public func close(_ windowId: UInt32) async throws {
        lock.withLock { state.closeCalls.append(windowId) }
    }

    public func setMinimized(_ windowId: UInt32, _ minimized: Bool) async throws {
        lock.withLock { state.minimizeCalls.append((windowId: windowId, minimized: minimized)) }
    }

    public func windowExists(_ windowId: UInt32) async -> Bool {
        lock.withLock {
            if let live = state.liveWindowIds {
                return live.contains(windowId)
            }
            // Default: all windows exist (tests don't need stale window validation unless opted in)
            return true
        }
    }

    public func monitors() async -> [MonitorInfo] {
        lock.withLock { state.monitors }
    }

    public func observe(_ handler: @escaping @Sendable (WindowEvent) -> Void) async throws {
        lock.withLock { state.handler = handler }
    }
}

private struct MockState {
    var windows: [UInt32: DiscoveredWindow] = [:]
    var monitors: [MonitorInfo] = []
    var handler: (@Sendable (WindowEvent) -> Void)?
    var setFrameCalls: [(windowId: UInt32, frame: CGRect)] = []
    var focusCalls: [UInt32] = []
    var closeCalls: [UInt32] = []
    var minimizeCalls: [(windowId: UInt32, minimized: Bool)] = []
    /// When non-nil, windowExists only returns true for IDs in this set.
    var liveWindowIds: Set<UInt32>?
}

/// Lightweight lock wrapper around os_unfair_lock.
private final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock()

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }
}
