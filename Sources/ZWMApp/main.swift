import AppKit
import Foundation
import ZWMServer

@MainActor func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

// Run as a background agent (no dock icon, no menu bar) even when launched outside .app bundle
NSApplication.shared.setActivationPolicy(.accessory)

// Set up file logging so output is always available regardless of launch method
let logPath = "/tmp/zwm.log"
if !FileManager.default.fileExists(atPath: logPath) {
    FileManager.default.createFile(atPath: logPath, contents: nil)
}
if let logFile = FileHandle(forWritingAtPath: logPath) {
    logFile.seekToEndOfFile()
    dup2(logFile.fileDescriptor, STDOUT_FILENO)
    dup2(logFile.fileDescriptor, STDERR_FILENO)
    // Disable stdout buffering so log lines are written immediately
    setvbuf(stdout, nil, _IONBF, 0)
}

// Use real AX backend
let backend = AXBackend()
let engine = ServerEngine(backend: backend)

// Focus follows mouse — passive mouse tracker. Declared before the event loop
// below, which polls it for tap health.
let mouseTracker = MouseTracker { point in
    Task { await engine.focusWindowAtPoint(point) }
}

// Start the engine (discovers windows, sets up observers).
// Wait for the Accessibility API first: observers registered while AX is still
// untrusted are created successfully but never deliver a single event.
Task {
    do {
        _ = await backend.waitUntilReady()
        try await engine.start()
        print("zwm: engine started (\(engine.currentTree.allWindows.count) windows discovered)")
    } catch {
        fputs("zwm: engine start failed: \(error)\n", stderr)
        await MainActor.run {
            showAlert(title: "zwm Engine Failed", message: "Engine start failed: \(error)")
        }
    }
}

// Event-processing loop — drains queued AX/NSWorkspace events every 500ms
// and runs a full periodic validation (observer health + drift check) every 5s.
Task {
    var tick = 0
    while true {
        try? await Task.sleep(nanoseconds: 500_000_000) // every 500ms
        await engine.processEvents()
        tick += 1
        if tick % 10 == 0 {
            await engine.periodicValidation()
            // Tap creation and run-loop-source changes belong on the main thread,
            // where the tap callback also runs.
            await MainActor.run { mouseTracker.checkHealth() }
        }
    }
}

// Focus follows mouse — passive mouse tracker
if mouseTracker.start() {
    let access = MouseTracker.hasInputMonitoringAccess ? "granted" : "NOT granted"
    print("zwm: focus-follows-mouse active (Input Monitoring \(access))")
} else {
    fputs("zwm: failed to create mouse event tap for focus-follows-mouse\n", stderr)
}

// Start socket server on a GCD background queue
let socketPath = ZWMSocket.defaultPath
print("zwm: listening on \(socketPath)")

let server = SocketServer(socketPath: socketPath, asyncHandler: { request in
    await engine.execute(request)
})

DispatchQueue.global(qos: .userInitiated).async {
    try? server.start()
}

// Run the main run loop — this is what drives:
// - AX observer callbacks (per-app window events)
// - NSWorkspace notification delivery
// - MainActor.run blocks from async Tasks
print("zwm: server running (pid \(getpid()))")
NSApplication.shared.run()
