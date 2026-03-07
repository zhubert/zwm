import CoreGraphics
import Testing
@testable import ZWMServer

private let testMonitor = MonitorInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
)

private func makeEngine(
    windows: [DiscoveredWindow] = [],
    monitors: [MonitorInfo] = [testMonitor],
    config: EngineConfig = EngineConfig(workspaceNames: ["1", "2", "3"])
) async throws -> (ServerEngine, MockBackend) {
    let backend = MockBackend()
    backend.setMonitors(monitors)
    for w in windows { backend.addWindow(w) }

    let engine = ServerEngine(backend: backend, config: config)
    try await engine.start()
    return (engine, backend)
}

private func window(_ id: UInt32, app: String = "App", title: String = "", frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800)) -> DiscoveredWindow {
    DiscoveredWindow(
        windowId: id, pid: Int32(id), appName: app, title: title.isEmpty ? "W\(id)" : title,
        frame: frame
    )
}

// MARK: - Startup

@Test func engineStartCreatesWorkspaces() async throws {
    let (engine, _) = try await makeEngine()
    let tree = engine.currentTree
    #expect(tree.workspaceIds.count == 3)
    #expect(tree.workspace("1") != nil)
    #expect(tree.workspace("2") != nil)
    #expect(tree.workspace("3") != nil)
}

@Test func engineStartDiscoversWindows() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1), window(2)])
    let tree = engine.currentTree
    #expect(tree.allWindows.count == 2)

    // Should have issued setFrame calls for both windows
    #expect(backend.setFrameCalls.count >= 2)
}

@Test func engineStartFocusesFirstWindow() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1), window(2)])
    let tree = engine.currentTree
    #expect(tree.focusedWindowId != nil)

    // The first window in the workspace should be focused
    let ws = tree.workspace("1")!
    let firstWindowNodeId = ws.childIds.first!
    #expect(tree.focusedWindowId == firstWindowNodeId)
}

// MARK: - list-windows command

@Test func listWindowsShowsAllWindows() async throws {
    let (engine, _) = try await makeEngine(windows: [
        window(1, app: "Safari", title: "Tab 1"),
        window(2, app: "Terminal", title: "zsh"),
    ])
    let response = await engine.execute(CommandRequest(command: "list-windows", args: []))
    #expect(response.exitCode == 0)
    #expect(response.stdout.contains("Safari"))
    #expect(response.stdout.contains("Terminal"))
}

@Test func listWindowsEmptyTree() async throws {
    let (engine, _) = try await makeEngine()
    let response = await engine.execute(CommandRequest(command: "list-windows", args: []))
    #expect(response.exitCode == 0)
    #expect(response.stdout == "")
}

// MARK: - list-workspaces command

@Test func listWorkspacesShowsAll() async throws {
    let (engine, _) = try await makeEngine()
    let response = await engine.execute(CommandRequest(command: "list-workspaces", args: []))
    #expect(response.exitCode == 0)
    #expect(response.stdout.contains("1"))
    #expect(response.stdout.contains("2"))
    #expect(response.stdout.contains("3"))
}

// MARK: - focus command

@Test func focusRightMovesToNextWindow() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1), window(2)])

    // Both windows are in workspace 1 (horizontal layout by default via workspace children)
    let response = await engine.execute(CommandRequest(command: "focus", args: ["right"]))
    #expect(response.exitCode == 0)
}

@Test func focusWithNoArgsReturnsError() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])
    let response = await engine.execute(CommandRequest(command: "focus", args: []))
    #expect(response.exitCode == 1)
    #expect(response.stderr.contains("Usage"))
}

// MARK: - workspace command

@Test func switchWorkspace() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])
    let response = await engine.execute(CommandRequest(command: "workspace", args: ["2"]))
    #expect(response.exitCode == 0)
    // MRU should now have workspace 2 first
    let tree = engine.currentTree
    #expect(tree.workspaceMRU.first == "2")
}

// MARK: - move-to-workspace command

@Test func moveWindowToWorkspace() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])
    let response = await engine.execute(CommandRequest(command: "move-to-workspace", args: ["2"]))
    #expect(response.exitCode == 0)

    let tree = engine.currentTree
    let ws2 = tree.workspace("2")!
    #expect(ws2.childIds.count == 1)

    let ws1 = tree.workspace("1")!
    #expect(ws1.childIds.isEmpty)
}

@Test func moveToNonexistentWorkspaceReturnsError() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])
    let response = await engine.execute(CommandRequest(command: "move-to-workspace", args: ["99"]))
    #expect(response.exitCode == 1)
    #expect(response.stderr.contains("not found"))
}

// MARK: - close command

@Test func closeRemovesWindowAndCallsBackend() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1)])
    backend.resetRecordedCalls()

    let response = await engine.execute(CommandRequest(command: "close", args: []))
    #expect(response.exitCode == 0)

    let tree = engine.currentTree
    #expect(tree.allWindows.isEmpty)
    #expect(backend.closeCalls == [1])
}

// MARK: - layout command

@Test func layoutChangesWorkspaceLayout() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1), window(2)])
    backend.resetRecordedCalls()

    let response = await engine.execute(CommandRequest(command: "layout", args: ["vertical"]))
    #expect(response.exitCode == 0)

    // Workspace layout should now be vertical
    let tree = engine.currentTree
    let ws = tree.workspace("1")!
    #expect(ws.layout == .vertical)

    // Windows should have been re-laid out (setFrame calls issued)
    #expect(backend.setFrameCalls.count >= 2)
}

@Test func layoutCyclesThrough() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1), window(2)])

    // Default is horizontal, cycling toggles h -> v -> h
    var response = await engine.execute(CommandRequest(command: "layout", args: []))
    #expect(response.exitCode == 0)
    #expect(engine.currentTree.workspace("1")!.layout == .vertical)

    response = await engine.execute(CommandRequest(command: "layout", args: []))
    #expect(engine.currentTree.workspace("1")!.layout == .horizontal)
}

// MARK: - Unknown command

@Test func unknownCommandReturnsError() async throws {
    let (engine, _) = try await makeEngine()
    let response = await engine.execute(CommandRequest(command: "bogus", args: []))
    #expect(response.exitCode == 1)
    #expect(response.stderr.contains("Unknown command"))
}

// MARK: - Event processing

@Test func windowCreatedEventAddsToTree() async throws {
    let (engine, backend) = try await makeEngine()
    // Add window to mock OS state, then emit event as trigger
    let newWin = DiscoveredWindow(windowId: 42, pid: 100, appName: "App", title: "W42",
                                   frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    backend.addWindow(newWin)
    backend.emit(.windowCreated(pid: 100, windowId: 42, appName: "App", title: "W42", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))

    await engine.processEvents()

    let tree = engine.currentTree
    let windows = tree.allWindows
    #expect(windows.contains { $0.windowId == 42 })
}

@Test func windowDestroyedEventRemovesFromTree() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1)])
    #expect(engine.currentTree.allWindows.count == 1)

    // Remove window from mock OS state, then emit event as trigger
    backend.removeWindow(1)
    backend.emit(.windowDestroyed(windowId: 1))
    await engine.processEvents()

    #expect(engine.currentTree.allWindows.isEmpty)
}

@Test func appTerminatedRemovesAllAppWindows() async throws {
    let w1 = DiscoveredWindow(windowId: 1, pid: 100, appName: "App", title: "W1",
                               frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let w2 = DiscoveredWindow(windowId: 2, pid: 100, appName: "App", title: "W2",
                               frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let w3 = DiscoveredWindow(windowId: 3, pid: 200, appName: "Other", title: "W3",
                               frame: CGRect(x: 0, y: 0, width: 1000, height: 800))

    let (engine, backend) = try await makeEngine(windows: [w1, w2, w3])
    #expect(engine.currentTree.allWindows.count == 3)

    // Remove terminated app's windows from mock OS state
    backend.removeWindow(1)
    backend.removeWindow(2)
    backend.emit(.appTerminated(pid: 100))
    await engine.processEvents()

    let windows = engine.currentTree.allWindows
    #expect(windows.count == 1)
    #expect(windows[0].windowId == 3)
}

// MARK: - Fullscreen command

@Test func fullscreenTogglesToFullscreen() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1), window(2)])
    let tree = engine.currentTree
    let focusedId = tree.focusedWindowId!
    let win = tree.windowNode(focusedId)!
    #expect(win.state == .tiling)

    let response = await engine.execute(CommandRequest(command: "fullscreen", args: []))
    #expect(response.exitCode == 0)

    let updatedWin = engine.currentTree.windowNode(focusedId)!
    #expect(updatedWin.state == .fullscreen)
}

@Test func fullscreenTogglesBackToTiling() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])

    // Toggle to fullscreen
    _ = await engine.execute(CommandRequest(command: "fullscreen", args: []))
    let focusedId = engine.currentTree.focusedWindowId!
    #expect(engine.currentTree.windowNode(focusedId)!.state == .fullscreen)

    // Toggle back to tiling
    _ = await engine.execute(CommandRequest(command: "fullscreen", args: []))
    #expect(engine.currentTree.windowNode(focusedId)!.state == .tiling)
}

@Test func fullscreenWindowGetsFullMonitorFrame() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1), window(2)])
    backend.resetRecordedCalls()

    _ = await engine.execute(CommandRequest(command: "fullscreen", args: []))

    // The fullscreen window should get the full visible frame (no gaps)
    let focusedId = engine.currentTree.focusedWindowId!
    let layout = engine.currentLayout
    let frame = layout.frames[focusedId]!
    #expect(frame == testMonitor.visibleFrame)
}

// MARK: - Layout floating command

@Test func layoutFloatingChangesWindowState() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])

    let response = await engine.execute(CommandRequest(command: "layout", args: ["floating"]))
    #expect(response.exitCode == 0)

    let focusedId = engine.currentTree.focusedWindowId!
    let win = engine.currentTree.windowNode(focusedId)!
    if case .floating = win.state {
        // ok
    } else {
        #expect(Bool(false), "Expected floating state, got \(win.state)")
    }
}

@Test func layoutTilingChangesBackToTiling() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])

    _ = await engine.execute(CommandRequest(command: "layout", args: ["floating"]))
    _ = await engine.execute(CommandRequest(command: "layout", args: ["tiling"]))

    let focusedId = engine.currentTree.focusedWindowId!
    let win = engine.currentTree.windowNode(focusedId)!
    #expect(win.state == .tiling)
}

@Test func layoutFloatingMovesToFloatingList() async throws {
    let (engine, _) = try await makeEngine(windows: [window(1)])

    _ = await engine.execute(CommandRequest(command: "layout", args: ["floating"]))

    let tree = engine.currentTree
    let ws = tree.workspace("1")!
    #expect(ws.floatingWindowIds.count == 1)
    #expect(ws.childIds.isEmpty)
}

// MARK: - Window rules

@Test func windowRuleAppliedAtStartup() async throws {
    let rule = WindowRule(matchAppName: "Safari", command: "layout floating")
    let config = EngineConfig(workspaceNames: ["1", "2"], windowRules: [rule])
    let (engine, _) = try await makeEngine(
        windows: [window(1, app: "Safari", title: "Tab 1"), window(2, app: "Terminal", title: "zsh")],
        config: config
    )

    let tree = engine.currentTree
    let safariNode = tree.allWindows.first { $0.appName == "Safari" }!
    let terminalNode = tree.allWindows.first { $0.appName == "Terminal" }!

    if case .floating = safariNode.state {
        // ok
    } else {
        #expect(Bool(false), "Expected Safari to be floating, got \(safariNode.state)")
    }
    #expect(terminalNode.state == .tiling)
}

@Test func windowRuleAppliedOnCreation() async throws {
    let rule = WindowRule(matchAppName: "Safari", command: "layout floating")
    let config = EngineConfig(workspaceNames: ["1", "2"], windowRules: [rule])
    let (engine, backend) = try await makeEngine(config: config)

    let newWin = DiscoveredWindow(windowId: 42, pid: 100, appName: "Safari", title: "New Tab",
                                   frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                   subrole: "AXStandardWindow")
    backend.addWindow(newWin)
    backend.emit(.windowCreated(pid: 100, windowId: 42, appName: "Safari", title: "New Tab", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
    await engine.processEvents()

    let tree = engine.currentTree
    let win = tree.allWindows.first { $0.windowId == 42 }!
    if case .floating = win.state {
        // ok
    } else {
        #expect(Bool(false), "Expected floating state, got \(win.state)")
    }
}

@Test func windowRuleMoveToWorkspace() async throws {
    let rule = WindowRule(matchAppName: "Slack", command: "move-to-workspace 2")
    let config = EngineConfig(workspaceNames: ["1", "2"], windowRules: [rule])
    let (engine, _) = try await makeEngine(
        windows: [window(1, app: "Slack", title: "Chat")],
        config: config
    )

    let tree = engine.currentTree
    let ws2 = tree.workspace("2")!
    let slackNode = tree.allWindows.first { $0.appName == "Slack" }!
    #expect(ws2.childIds.contains(slackNode.id))
}

@Test func windowRuleMatchesTitleOnly() async throws {
    let rule = WindowRule(matchTitle: "Preferences", command: "layout floating")
    let config = EngineConfig(workspaceNames: ["1"], windowRules: [rule])
    let (engine, _) = try await makeEngine(
        windows: [
            window(1, app: "App", title: "Preferences"),
            window(2, app: "App", title: "Main Window"),
        ],
        config: config
    )

    let tree = engine.currentTree
    let prefsNode = tree.allWindows.first { $0.title == "Preferences" }!
    let mainNode = tree.allWindows.first { $0.title == "Main Window" }!

    if case .floating = prefsNode.state {
        // ok
    } else {
        #expect(Bool(false), "Expected Preferences to be floating")
    }
    #expect(mainNode.state == .tiling)
}

// MARK: - Frame readback and retry

@Test func constrainedWindowGetsCentered() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1), window(2)])
    backend.resetRecordedCalls()

    // Simulate window 1 constraining itself to be smaller than requested
    backend.setFrameOverride(1, CGRect(x: 0, y: 0, width: 940, height: 1060))

    // Trigger a layout change so diff engine produces setFrame calls
    _ = await engine.execute(CommandRequest(command: "layout", args: ["vertical"]))

    // Should have issued at least 2 setFrame calls for window 1: initial + centering
    let calls = backend.setFrameCalls.filter { $0.windowId == 1 }
    #expect(calls.count >= 2)
    backend.clearFrameOverrides()
}

@Test func positionMismatchTriggersRetry() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1), window(2)])
    backend.resetRecordedCalls()

    // Simulate window 1 reporting a different position than requested
    backend.setFrameOverride(1, CGRect(x: 50, y: 50, width: 1920, height: 540))

    _ = await engine.execute(CommandRequest(command: "layout", args: ["vertical"]))

    // Should have retried: initial setFrame + retry setFrame
    let calls = backend.setFrameCalls.filter { $0.windowId == 1 }
    #expect(calls.count >= 2)
    backend.clearFrameOverrides()
}

// MARK: - Periodic validation

@Test func periodicValidationRemovesGoneWindows() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1), window(2)])
    #expect(engine.currentTree.allWindows.count == 2)

    // Remove window from OS state without emitting any event (simulates missed event)
    backend.removeWindow(1)

    // Periodic validation should detect the missing window
    await engine.periodicValidation()
    #expect(engine.currentTree.allWindows.count == 1)
    #expect(engine.currentTree.allWindows[0].windowId == 2)
}

@Test func periodicValidationAddsNewWindows() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1)])
    #expect(engine.currentTree.allWindows.count == 1)

    // Add window to OS state without emitting any event (simulates missed event)
    backend.addWindow(window(2))

    await engine.periodicValidation()
    #expect(engine.currentTree.allWindows.count == 2)
}

@Test func periodicValidationNoOpWhenSynced() async throws {
    let (engine, backend) = try await makeEngine(windows: [window(1)])
    backend.resetRecordedCalls()

    // Nothing changed — validation should be a no-op (no setFrame calls)
    await engine.periodicValidation()
    #expect(engine.currentTree.allWindows.count == 1)
}

// MARK: - Window filtering (subrole + size)

@Test func discoveredDialogWindowIsSkipped() async throws {
    let dialog = DiscoveredWindow(
        windowId: 1, pid: 100, appName: "Zoom", title: "Toast",
        frame: CGRect(x: 0, y: 0, width: 300, height: 100),
        subrole: "AXDialog"
    )
    let standard = DiscoveredWindow(
        windowId: 2, pid: 200, appName: "Safari", title: "Tab 1",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        subrole: "AXStandardWindow"
    )
    let (engine, _) = try await makeEngine(windows: [dialog, standard])
    let tree = engine.currentTree
    #expect(tree.allWindows.count == 1)
    #expect(tree.allWindows[0].windowId == 2)
}

@Test func windowCreatedWithDialogSubroleIsNotInserted() async throws {
    let (engine, backend) = try await makeEngine()
    // Add dialog window to OS state — it should be filtered out by isStandardWindow
    let dialog = DiscoveredWindow(windowId: 42, pid: 100, appName: "Zoom", title: "Toast",
                                   frame: CGRect(x: 0, y: 0, width: 300, height: 100),
                                   subrole: "AXDialog")
    backend.addWindow(dialog)
    backend.emit(.windowCreated(pid: 100, windowId: 42, appName: "Zoom", title: "Toast", subrole: "AXDialog", frame: CGRect(x: 0, y: 0, width: 300, height: 100)))
    await engine.processEvents()

    let tree = engine.currentTree
    #expect(tree.allWindows.isEmpty)
}

@Test func windowCreatedWithEmptySubroleIsInserted() async throws {
    let (engine, backend) = try await makeEngine()
    let newWin = DiscoveredWindow(windowId: 42, pid: 100, appName: "App", title: "Win",
                                   frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    backend.addWindow(newWin)
    backend.emit(.windowCreated(pid: 100, windowId: 42, appName: "App", title: "Win", subrole: "", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
    await engine.processEvents()

    let tree = engine.currentTree
    #expect(tree.allWindows.count == 1)
    #expect(tree.allWindows[0].windowId == 42)
}

@Test func discoveredTinyWindowIsSkipped() async throws {
    let tiny = DiscoveredWindow(
        windowId: 1, pid: 100, appName: "App", title: "Tiny",
        frame: CGRect(x: 0, y: 0, width: 20, height: 20)
    )
    let normal = DiscoveredWindow(
        windowId: 2, pid: 200, appName: "App", title: "Normal",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )
    let (engine, _) = try await makeEngine(windows: [tiny, normal])
    let tree = engine.currentTree
    #expect(tree.allWindows.count == 1)
    #expect(tree.allWindows[0].windowId == 2)
}

@Test func windowCreatedWithTinyFrameIsNotInserted() async throws {
    let (engine, backend) = try await makeEngine()
    // Add tiny window to OS state — it should be filtered out by isStandardWindow
    let tiny = DiscoveredWindow(windowId: 42, pid: 100, appName: "App", title: "Tiny",
                                 frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 subrole: "AXStandardWindow")
    backend.addWindow(tiny)
    backend.emit(.windowCreated(pid: 100, windowId: 42, appName: "App", title: "Tiny", subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
    await engine.processEvents()

    let tree = engine.currentTree
    #expect(tree.allWindows.isEmpty)
}

// MARK: - Auto-float small windows

@Test func smallWindowAutoFloatsAtStartup() async throws {
    let small = DiscoveredWindow(
        windowId: 1, pid: 100, appName: "1Password", title: "Mini",
        frame: CGRect(x: 200, y: 200, width: 400, height: 300)
    )
    let large = DiscoveredWindow(
        windowId: 2, pid: 200, appName: "Safari", title: "Tab",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )
    let (engine, _) = try await makeEngine(windows: [small, large])
    let tree = engine.currentTree
    #expect(tree.allWindows.count == 2)

    let smallNode = tree.allWindows.first { $0.windowId == 1 }!
    let largeNode = tree.allWindows.first { $0.windowId == 2 }!
    if case .floating = smallNode.state { } else {
        #expect(Bool(false), "Expected small window to be auto-floated")
    }
    #expect(largeNode.state == .tiling)
}

@Test func smallWindowAutoFloatsOnCreation() async throws {
    let (engine, backend) = try await makeEngine()
    let small = DiscoveredWindow(
        windowId: 42, pid: 100, appName: "1Password", title: "Mini",
        frame: CGRect(x: 200, y: 200, width: 400, height: 300)
    )
    backend.addWindow(small)
    backend.emit(.windowCreated(pid: 100, windowId: 42, appName: "1Password", title: "Mini",
                                subrole: "AXStandardWindow", frame: CGRect(x: 200, y: 200, width: 400, height: 300)))
    await engine.processEvents()

    let tree = engine.currentTree
    #expect(tree.allWindows.count == 1)
    if case .floating = tree.allWindows[0].state { } else {
        #expect(Bool(false), "Expected small window to be auto-floated")
    }
}

// MARK: - Overflow to next workspace

@Test func fifthWindowOverflowsToNextWorkspace() async throws {
    let config = EngineConfig(workspaceNames: ["1", "2", "3"], maxTilingWindows: 4)
    let (engine, _) = try await makeEngine(
        windows: [window(1), window(2), window(3), window(4), window(5)],
        config: config
    )
    let tree = engine.currentTree
    let ws1 = tree.workspace("1")!
    let ws2 = tree.workspace("2")!

    // 4 windows in workspace 1, 1 overflows to workspace 2
    #expect(tree.tilingWindowCount(in: ws1.id) == 4)
    #expect(tree.tilingWindowCount(in: ws2.id) == 1)
}

@Test func overflowFillsMultipleWorkspaces() async throws {
    let config = EngineConfig(workspaceNames: ["1", "2", "3"], maxTilingWindows: 2)
    let (engine, _) = try await makeEngine(
        windows: [window(1), window(2), window(3), window(4), window(5)],
        config: config
    )
    let tree = engine.currentTree
    let ws1 = tree.workspace("1")!
    let ws2 = tree.workspace("2")!
    let ws3 = tree.workspace("3")!

    #expect(tree.tilingWindowCount(in: ws1.id) == 2)
    #expect(tree.tilingWindowCount(in: ws2.id) == 2)
    #expect(tree.tilingWindowCount(in: ws3.id) == 1)
}

@Test func newWindowOverflowsOnCreation() async throws {
    let config = EngineConfig(workspaceNames: ["1", "2", "3"], maxTilingWindows: 2)
    let (engine, backend) = try await makeEngine(
        windows: [window(1), window(2)],
        config: config
    )
    #expect(engine.currentTree.tilingWindowCount(in: engine.currentTree.workspace("1")!.id) == 2)

    // Add a 3rd window via event — should overflow to workspace 2
    let newWin = DiscoveredWindow(windowId: 3, pid: 3, appName: "App", title: "W3",
                                   frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    backend.addWindow(newWin)
    backend.emit(.windowCreated(pid: 3, windowId: 3, appName: "App", title: "W3",
                                subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
    await engine.processEvents()

    let tree = engine.currentTree
    #expect(tree.tilingWindowCount(in: tree.workspace("1")!.id) == 2)
    #expect(tree.tilingWindowCount(in: tree.workspace("2")!.id) == 1)
    #expect(tree.allWindows.first { $0.windowId == 3 }.map { tree.workspaceContaining($0.id)?.name } == "2")
}

@Test func underMaxDoesNotOverflow() async throws {
    let config = EngineConfig(workspaceNames: ["1", "2", "3"], maxTilingWindows: 4)
    let (engine, _) = try await makeEngine(
        windows: [window(1), window(2), window(3)],
        config: config
    )
    let tree = engine.currentTree
    let ws1 = tree.workspace("1")!

    // 3 windows fit in workspace 1 (max is 4)
    #expect(tree.tilingWindowCount(in: ws1.id) == 3)
    #expect(tree.tilingWindowCount(in: tree.workspace("2")!.id) == 0)
}

@Test func smallWindowDoesNotAffectTilingLayout() async throws {
    let (engine, backend) = try await makeEngine(windows: [
        window(1, app: "Safari"),
        window(2, app: "Terminal")
    ])
    backend.resetRecordedCalls()

    // Add a small window — should auto-float and not cause tiling windows to move
    let small = DiscoveredWindow(
        windowId: 3, pid: 300, appName: "1Password", title: "Mini",
        frame: CGRect(x: 200, y: 200, width: 400, height: 300)
    )
    backend.addWindow(small)
    backend.emit(.windowCreated(pid: 300, windowId: 3, appName: "1Password", title: "Mini",
                                subrole: "AXStandardWindow", frame: CGRect(x: 200, y: 200, width: 400, height: 300)))
    await engine.processEvents()

    // The two tiling windows should not have been re-laid out
    let tilingSetFrames = backend.setFrameCalls.filter { $0.windowId == 1 || $0.windowId == 2 }
    #expect(tilingSetFrames.isEmpty)
}
