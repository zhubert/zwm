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
if FileManager.default.createFile(atPath: logPath, contents: nil),
   let logFile = FileHandle(forWritingAtPath: logPath) {
    logFile.seekToEndOfFile()
    dup2(logFile.fileDescriptor, STDOUT_FILENO)
    dup2(logFile.fileDescriptor, STDERR_FILENO)
    // Disable stdout buffering so log lines are written immediately
    setvbuf(stdout, nil, _IONBF, 0)
}

// Use real AX backend
let backend = AXBackend()
let engine = ServerEngine(backend: backend)

// Start the engine (discovers windows, sets up observers)
Task {
    do {
        try await engine.start()
        print("zwm: engine started (\(engine.currentTree.allWindows.count) windows discovered)")
    } catch {
        fputs("zwm: engine start failed: \(error)\n", stderr)
        await MainActor.run {
            showAlert(title: "zwm Engine Failed", message: "Engine start failed: \(error)")
        }
    }
}

// Periodic validation loop — syncs tree with OS reality
Task {
    while true {
        try? await Task.sleep(nanoseconds: 500_000_000) // every 500ms
        await engine.periodicValidation()
    }
}

// Focus follows mouse — passive mouse tracker
var mouseTracker: MouseTracker? = nil

@MainActor func applyMouseTracker(enabled: Bool) {
    if enabled, mouseTracker == nil {
        let tracker = MouseTracker { point in
            Task { await engine.focusWindowAtPoint(point) }
        }
        if tracker.start() {
            mouseTracker = tracker
            print("zwm: focus-follows-mouse active")
        } else {
            fputs("zwm: failed to create mouse event tap for focus-follows-mouse\n", stderr)
        }
    } else if !enabled, mouseTracker != nil {
        mouseTracker?.stop()
        mouseTracker = nil
        print("zwm: focus-follows-mouse disabled")
    }
}

applyMouseTracker(enabled: true)

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
