import CoreGraphics
import Testing
@testable import ZWMServer

@Test func mockBackendDiscoverWindows() async throws {
    let backend = MockBackend()
    backend.addWindow(DiscoveredWindow(
        windowId: 1, pid: 100, appName: "Safari", title: "Tab 1",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
    ))
    backend.addWindow(DiscoveredWindow(
        windowId: 2, pid: 100, appName: "Safari", title: "Tab 2",
        frame: CGRect(x: 100, y: 100, width: 800, height: 600)
    ))

    let windows = try await backend.discoverWindows()
    #expect(windows.count == 2)
    let ids = Set(windows.map(\.windowId))
    #expect(ids == [1, 2])
}

@Test func mockBackendRecordsSetFrame() async throws {
    let backend = MockBackend()
    let frame = CGRect(x: 10, y: 20, width: 500, height: 400)
    try await backend.setFrame(42, frame)

    let calls = backend.setFrameCalls
    #expect(calls.count == 1)
    #expect(calls[0].windowId == 42)
    #expect(calls[0].frame == frame)
}

@Test func mockBackendRecordsFocus() async throws {
    let backend = MockBackend()
    try await backend.focus(1)
    try await backend.focus(2)
    #expect(backend.focusCalls == [1, 2])
}

@Test func mockBackendRecordsClose() async throws {
    let backend = MockBackend()
    try await backend.close(5)
    #expect(backend.closeCalls == [5])
}

@Test func mockBackendRecordsMinimize() async throws {
    let backend = MockBackend()
    try await backend.setMinimized(3, true)
    try await backend.setMinimized(3, false)

    let calls = backend.minimizeCalls
    #expect(calls.count == 2)
    #expect(calls[0].minimized == true)
    #expect(calls[1].minimized == false)
}

@Test func mockBackendResetClearsCalls() async throws {
    let backend = MockBackend()
    try await backend.setFrame(1, CGRect(x: 0, y: 0, width: 100, height: 100))
    try await backend.focus(1)
    try await backend.close(2)
    try await backend.setMinimized(3, true)

    backend.resetRecordedCalls()
    #expect(backend.setFrameCalls.isEmpty)
    #expect(backend.focusCalls.isEmpty)
    #expect(backend.closeCalls.isEmpty)
    #expect(backend.minimizeCalls.isEmpty)
}

/// Thread-safe event collector for tests.
private final class EventCollector: @unchecked Sendable {
    private var _events: [WindowEvent] = []
    private var _lock = os_unfair_lock()

    func append(_ event: WindowEvent) {
        os_unfair_lock_lock(&_lock)
        _events.append(event)
        os_unfair_lock_unlock(&_lock)
    }

    var events: [WindowEvent] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _events
    }
}

@Test func mockBackendEmitsEvents() async throws {
    let backend = MockBackend()
    let collector = EventCollector()

    try await backend.observe { event in
        collector.append(event)
    }

    backend.emit(.windowCreated(pid: 100, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)))
    backend.emit(.windowFocused(windowId: 1))
    backend.emit(.appTerminated(pid: 100))

    let received = collector.events
    #expect(received.count == 3)
    #expect(received[0] == .windowCreated(pid: 100, windowId: 1, appName: "App", title: "W1", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600)))
    #expect(received[1] == .windowFocused(windowId: 1))
    #expect(received[2] == .appTerminated(pid: 100))
}

@Test func mockBackendMonitors() async {
    let backend = MockBackend()
    let monitor = MonitorInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)
    )
    backend.setMonitors([monitor])

    let monitors = await backend.monitors()
    #expect(monitors.count == 1)
    #expect(monitors[0].id == 1)
}
