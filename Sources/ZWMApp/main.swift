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

// Load configuration
let config = loadConfigFromFile()
print("zwm: loaded config (\(config.workspaceNames.count) workspaces)")

// Use real AX backend
let backend = AXBackend()
let engine = ServerEngine(backend: backend, config: config)

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

// Start event processing loop
Task {
    while true {
        await engine.processEvents()
        try? await Task.sleep(nanoseconds: 16_000_000) // ~60Hz
    }
}

// Set up global keybindings
let hotkeyManager = HotkeyManager { command in
    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let args = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
    let request = CommandRequest(command: cmd, args: args)
    Task {
        _ = await engine.execute(request)
    }
}
hotkeyManager.loadBindings(config.keybindings)
if hotkeyManager.start() {
    print("zwm: keybindings active (mode: main)")
} else {
    fputs("zwm: failed to create event tap — is Accessibility enabled?\n", stderr)
    MainActor.assumeIsolated {
        showAlert(
            title: "zwm Accessibility Error",
            message: "Failed to create event tap. Please enable Accessibility permissions for zwm in System Settings → Privacy & Security → Accessibility, then relaunch zwm."
        )
        NSApplication.shared.terminate(nil)
    }
}

// Watch config files for hot reload
let configPaths = [
    NSString("~/.zwm.toml").expandingTildeInPath,
    NSString("~/.config/zwm/zwm.toml").expandingTildeInPath,
]
let _watcher = FileWatcher(paths: configPaths) {
    let newConfig = loadConfigFromFile()
    engine.setConfig(newConfig)
    hotkeyManager.loadBindings(newConfig.keybindings)
    print("zwm: config reloaded")
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
// - CGEvent tap (global keybindings)
// - NSWorkspace notification delivery
// - MainActor.run blocks from async Tasks
print("zwm: server running (pid \(getpid()))")
NSApplication.shared.run()
