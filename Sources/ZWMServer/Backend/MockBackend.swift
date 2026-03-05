import CoreGraphics
import Foundation

/// In-memory WindowBackend for tests.
/// Records all calls and lets tests inspect what was requested.
public final class MockBackend: WindowBackend, @unchecked Sendable {
    private let lock = UnfairLock()
    private var state = MockState()

    public init() {}

    // MARK: - Test setup

    /// Set a frame override that getFrame will return instead of the last setFrame value.
    /// Simulates a window that constrains itself (e.g. Terminal snapping to character cells).
    public func setFrameOverride(_ windowId: UInt32, _ frame: CGRect) {
        lock.withLock { state.frameOverrides[windowId] = frame }
    }

    public func clearFrameOverrides() {
        lock.withLock { state.frameOverrides.removeAll() }
    }

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

    public func getFrame(_ windowId: UInt32) async throws -> CGRect {
        lock.withLock {
            // If a frame override is set, return that (simulates constrained windows)
            if let override = state.frameOverrides[windowId] {
                return override
            }
            // Otherwise return the last frame that was set, or the discovered window's frame
            if let last = state.setFrameCalls.last(where: { $0.windowId == windowId }) {
                return last.frame
            }
            return state.windows[windowId]?.frame ?? .zero
        }
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

    public func monitors() async -> [MonitorInfo] {
        lock.withLock { state.monitors }
    }

    public func observe(_ handler: @escaping @Sendable (WindowEvent) -> Void) async throws {
        lock.withLock { state.handler = handler }
    }

    public func checkObserverHealth() async -> Int {
        0
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
    var frameOverrides: [UInt32: CGRect] = [:]
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
