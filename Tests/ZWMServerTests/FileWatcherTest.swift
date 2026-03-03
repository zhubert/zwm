#if canImport(Darwin)
import Darwin
#endif
import CoreGraphics
import Testing
@testable import ZWMServer

@Test func fileWatcherDetectsChanges() async throws {
    let tmpFile = "/tmp/zwm-watcher-test-\(getpid()).toml"
    try "initial".write(toFile: tmpFile, atomically: true, encoding: .utf8)
    defer { unlink(tmpFile) }

    let flag = AtomicFlag()
    let watcher = FileWatcher(paths: [tmpFile]) {
        flag.set()
    }
    defer { watcher.stop() }

    // Modify the file
    try "modified".write(toFile: tmpFile, atomically: true, encoding: .utf8)

    // Wait for the callback (up to 2 seconds)
    var waited: UInt32 = 0
    while !flag.isSet && waited < 40 {
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        waited += 1
    }
    #expect(flag.isSet)
}

@Test func reloadConfigCommandUpdatesConfig() async throws {
    let backend = MockBackend()
    backend.setMonitors([MonitorInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )])

    let config = EngineConfig(gaps: GapConfig(inner: 0, outer: 0), workspaceNames: ["1", "2"])
    let engine = ServerEngine(backend: backend, config: config)
    try await engine.start()

    #expect(engine.currentConfig.gaps.inner == 0)

    let newConfig = EngineConfig(gaps: GapConfig(inner: 10, outer: 5), workspaceNames: ["1", "2"])
    engine.setConfig(newConfig)

    #expect(engine.currentConfig.gaps.inner == 10)
    #expect(engine.currentConfig.gaps.outer == 5)
}

/// Thread-safe boolean flag.
private final class AtomicFlag: @unchecked Sendable {
    private var _value = false
    private var _lock = os_unfair_lock()

    var isSet: Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _value
    }

    func set() {
        os_unfair_lock_lock(&_lock)
        _value = true
        os_unfair_lock_unlock(&_lock)
    }
}
