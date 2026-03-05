import CoreGraphics
import Foundation

/// The central coordinator that owns all state and wires together:
/// events → discover → tree sync → layout → diff → backend calls.
public final class ServerEngine: @unchecked Sendable {
    private let backend: any WindowBackend
    private let eventQueue: EventQueue
    private var lock = os_unfair_lock()

    // Mutable state — always accessed under lock via withLock
    private var tree: TreeState
    private var lastLayout: LayoutResult
    private var _config: EngineConfig
    var pendingClose: UInt32?

    public init(backend: any WindowBackend, config: EngineConfig = EngineConfig()) {
        self.backend = backend
        self.eventQueue = EventQueue()
        self.tree = TreeState()
        self.lastLayout = LayoutResult()
        self._config = config
    }

    // MARK: - Thread-safe state access

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }

    public var currentTree: TreeState { withLock { tree } }
    public var currentLayout: LayoutResult { withLock { lastLayout } }
    public var currentConfig: EngineConfig { withLock { _config } }

    func setTree(_ newTree: TreeState) {
        withLock { tree = newTree }
    }

    /// Update the engine configuration (e.g. after config reload).
    public func setConfig(_ newConfig: EngineConfig) {
        withLock { _config = newConfig }
    }

    // MARK: - Startup

    /// Initial discovery: enumerate all windows and build the tree.
    public func start() async throws {
        let monitors = await backend.monitors()
        let windows = try await backend.discoverWindows()

        let snapshot = withLock { () -> TreeState in
            for name in _config.workspaceNames {
                tree = tree.addWorkspace(name: name)
            }

            // Assign monitors to workspaces
            if !monitors.isEmpty && !tree.workspaceIds.isEmpty {
                for (i, wsId) in tree.workspaceIds.enumerated() {
                    let monitorId = monitors[i % monitors.count].id
                    if let ws = tree.workspaceNode(wsId) {
                        var nodes = tree.nodes
                        nodes[wsId] = .workspace(ws.with(monitorId: monitorId))
                        tree = tree.with(nodes: nodes)
                    }
                }
            }

            // Add discovered windows to the first workspace
            if let firstWsId = tree.workspaceIds.first {
                for window in windows where window.windowLevel == 0 && !window.isMinimized && window.isStandardWindow {
                    if let focusedId = tree.focusedWindowId,
                       tree.workspaceContaining(focusedId)?.id == firstWsId,
                       let focusedWin = tree.windowNode(focusedId),
                       focusedWin.state == .tiling {
                        tree = tree.insertWindowBSP(
                            windowId: window.windowId, appPid: window.pid,
                            appName: window.appName, title: window.title,
                            nearWindowId: focusedId
                        )
                    } else {
                        tree = tree.insertWindow(
                            windowId: window.windowId, appPid: window.pid,
                            appName: window.appName, title: window.title,
                            inParent: firstWsId
                        )
                    }
                    // Set focus to last inserted so next window BSP-splits from it
                    if let nodeId = tree.allWindows.first(where: { $0.windowId == window.windowId })?.id {
                        tree = tree.setFocus(nodeId)
                    }
                }

                // Apply window rules to discovered windows
                for window in windows where window.windowLevel == 0 && !window.isMinimized && window.isStandardWindow {
                    if let nodeId = tree.allWindows.first(where: { $0.windowId == window.windowId })?.id {
                        applyWindowRules(nodeId: nodeId, appName: window.appName, title: window.title)
                    }
                }

                // Focus the first window in the workspace
                if let firstChild = tree.workspaceNode(firstWsId)?.childIds.first,
                   let winId = tree.firstWindowId(in: firstChild) {
                    tree = tree.setFocus(winId)
                }
            }

            return tree
        }

        await applyLayout(tree: snapshot, monitors: monitors)

        try await backend.observe { [weak self] event in
            self?.eventQueue.enqueue(event)
        }
    }

    // MARK: - Event processing

    /// Process all pending events.
    /// Events are used only as triggers — the OS is the source of truth for which windows exist.
    public func processEvents() async {
        let events = eventQueue.drain()
        guard !events.isEmpty else { return }

        print("zwm: processing \(events.count) events: \(events)")

        // Extract the last focus event — we'll apply it after syncing the tree
        let lastFocusedWindowId = events.reversed().compactMap { event -> UInt32? in
            if case .windowFocused(let wid) = event { return wid }
            return nil
        }.first

        // Discover reality and sync the tree
        await syncTreeWithOS(focusWindowId: lastFocusedWindowId)
    }

    /// Force a full sync with the OS, regardless of whether events are pending.
    /// Called by the periodic validation timer to catch missed events,
    /// dead observers, or state drift after sleep/wake.
    public func periodicValidation() async {
        // Check for stale or dead AX observers and re-register them
        let reregistered = await backend.checkObserverHealth()
        if reregistered > 0 {
            print("zwm: periodic validation re-registered \(reregistered) observer(s)")
        }

        let windowCountBefore = withLock { tree.allWindows.count }
        await syncTreeWithOS()
        let windowCountAfter = withLock { tree.allWindows.count }
        if windowCountBefore != windowCountAfter {
            print("zwm: periodic validation corrected window count: \(windowCountBefore) → \(windowCountAfter)")
        }
    }

    // MARK: - Sync tree with OS

    /// Discover all current windows from the OS and sync the tree to match reality.
    /// - Removes windows that no longer exist
    /// - Adds windows that are new
    /// - Swaps window IDs for recycled windows (same app, different ID)
    /// - Applies focus from the most recent focus event (after sync, so IDs are current)
    private func syncTreeWithOS(focusWindowId: UInt32? = nil) async {
        let monitors = await backend.monitors()
        let discovered = (try? await backend.discoverWindows()) ?? []

        let manageable = discovered.filter {
            $0.windowLevel == 0 && !$0.isMinimized && $0.isStandardWindow
        }
        let osWindowIds = Set(manageable.map(\.windowId))

        let synced = withLock { () -> TreeState in
            let treeWindows = tree.allWindows

            // 1. Find stale windows (in tree but not in OS)
            var stale: [(nodeId: NodeId, windowId: UInt32, appPid: Int32)] = []
            for win in treeWindows {
                if !osWindowIds.contains(win.windowId) {
                    stale.append((nodeId: win.id, windowId: win.windowId, appPid: win.appPid))
                }
            }

            // 2. Find new windows (in OS but not in tree)
            let treeWindowIds = Set(treeWindows.map(\.windowId))
            var newWindows = manageable.filter { !treeWindowIds.contains($0.windowId) }

            // 3. Match stale → new by app PID (in-place ID swap for recycled windows)
            var unmatched: [(nodeId: NodeId, windowId: UInt32)] = []
            for s in stale {
                if let matchIdx = newWindows.firstIndex(where: { $0.pid == s.appPid }) {
                    let match = newWindows.remove(at: matchIdx)
                    print("zwm: sync: window \(s.windowId) → \(match.windowId) (\(match.appName))")
                    tree = tree.replaceWindowId(s.nodeId, newWindowId: match.windowId, newTitle: match.title)
                } else {
                    unmatched.append((nodeId: s.nodeId, windowId: s.windowId))
                }
            }

            // 4. Remove truly gone windows
            for s in unmatched {
                print("zwm: sync: removed \(s.windowId)")
                tree = tree.removeNode(s.nodeId)
            }

            // 5. Add genuinely new windows
            for window in newWindows {
                print("zwm: sync: added \(window.windowId) (\(window.appName))")
                if let wsId = activeWorkspaceId() {
                    if let focusedId = tree.focusedWindowId,
                       tree.workspaceContaining(focusedId)?.id == wsId,
                       let focusedWin = tree.windowNode(focusedId),
                       focusedWin.state == .tiling {
                        tree = tree.insertWindowBSP(
                            windowId: window.windowId, appPid: window.pid,
                            appName: window.appName, title: window.title,
                            nearWindowId: focusedId
                        )
                    } else {
                        tree = tree.insertWindow(
                            windowId: window.windowId, appPid: window.pid,
                            appName: window.appName, title: window.title,
                            inParent: wsId
                        )
                    }
                    if let nodeId = tree.allWindows.first(where: { $0.windowId == window.windowId })?.id {
                        applyWindowRules(nodeId: nodeId, appName: window.appName, title: window.title)
                        // Only auto-focus if no window is currently focused
                        if tree.focusedWindowId == nil {
                            tree = tree.setFocus(nodeId)
                        }
                    }
                }
            }

            // 6. Apply focus from the most recent event (after sync so IDs are current)
            if let focusWid = focusWindowId,
               let nodeId = findNodeByWindowId(focusWid) {
                tree = tree.setFocus(nodeId)
            }

            return tree
        }

        print("zwm: tree has \(synced.allWindows.count) windows after sync")
        await applyLayout(tree: synced, monitors: monitors)
    }

    // MARK: - Command execution

    /// Execute a command and return the response.
    public func execute(_ request: CommandRequest) async -> CommandResponse {
        let monitors = await backend.monitors()
        let response = executeCommand(request)
        let snapshot = currentTree

        await applyLayout(tree: snapshot, monitors: monitors)

        // Handle pending close
        let closeId = withLock { () -> UInt32? in
            let id = pendingClose
            pendingClose = nil
            return id
        }
        if let closeId {
            try? await backend.close(closeId)
        }

        return response
    }

    /// Execute a command. Commands read/write the tree via currentTree/setTree.
    func executeCommand(_ request: CommandRequest) -> CommandResponse {
        switch request.command {
        case "list-windows": return listWindows()
        case "list-workspaces": return listWorkspaces()
        case "focus": return focusCommand(request.args)
        case "move": return moveCommand(request.args)
        case "workspace": return workspaceCommand(request.args)
        case "move-to-workspace": return moveToWorkspaceCommand(request.args)
        case "layout": return layoutCommand(request.args)
        case "debug-tree": return debugTreeCommand()
        case "close": return closeCommand()
        case "fullscreen": return fullscreenCommand()
        case "reload-config": return reloadConfigCommand()
        default:
            return CommandResponse(exitCode: 1, stdout: "", stderr: "Unknown command: \(request.command)\n")
        }
    }

    // MARK: - Layout application

    private func applyLayout(tree: TreeState, monitors: [MonitorInfo]) async {
        let gaps = withLock { _config.gaps }
        let newLayout = layoutTree(tree, monitors: monitors, gaps: gaps)

        let (oldLayout, oldFocus, newFocus) = withLock { () -> (LayoutResult, UInt32?, UInt32?) in
            let old = lastLayout
            let oldF = focusedMacWindowId(self.tree)
            let newF = focusedMacWindowId(tree)
            lastLayout = newLayout
            return (old, oldF, newF)
        }

        let diff = diffLayouts(
            old: oldLayout, new: newLayout,
            oldFocusedWindowId: oldFocus, newFocusedWindowId: newFocus,
            tree: tree
        )

        if !diff.isEmpty {
            print("zwm: reconcile diff: \(diff.toSet.count) frame changes, focus=\(String(describing: diff.toFocus))")
        }

        guard !diff.isEmpty else { return }

        for change in diff.toSet {
            print("zwm: setFrame(\(change.windowId), \(change.frame))")
            do {
                try await backend.setFrame(change.windowId, change.frame)
            } catch {
                print("zwm: setFrame(\(change.windowId)) failed: \(error)")
                continue
            }

            // Read back actual frame to detect constrained windows and validate
            guard let actual = try? await backend.getFrame(change.windowId) else { continue }

            let dx = abs(change.frame.origin.x - actual.origin.x)
            let dy = abs(change.frame.origin.y - actual.origin.y)
            let dw = change.frame.width - actual.width
            let dh = change.frame.height - actual.height

            if dw > 1 || dh > 1 {
                // Window is smaller than requested (e.g. Terminal snaps to character cells) — center it
                let centered = CGRect(
                    x: change.frame.minX + dw / 2,
                    y: change.frame.minY + dh / 2,
                    width: actual.width,
                    height: actual.height
                )
                print("zwm: centering \(change.windowId): requested=\(change.frame.size) actual=\(actual.size) → \(centered)")
                try? await backend.setFrame(change.windowId, centered)
            } else if dx > 2 || dy > 2 {
                // Position is off — retry once
                print("zwm: position mismatch for \(change.windowId): requested=\(change.frame.origin) actual=\(actual.origin), retrying")
                try? await backend.setFrame(change.windowId, change.frame)
            }
        }
        if let focusId = diff.toFocus {
            try? await backend.focus(focusId)
        }
    }

    // MARK: - Window rules (called under lock)

    /// Check all window rules and apply the first match.
    func applyWindowRules(nodeId: NodeId, appName: String, title: String) {
        for rule in _config.windowRules {
            if matchesRule(rule, appName: appName, title: title) {
                applyRuleCommand(rule.command, nodeId: nodeId)
                break
            }
        }
    }

    private func matchesRule(_ rule: WindowRule, appName: String, title: String) -> Bool {
        if let matchApp = rule.matchAppName {
            guard appName.localizedCaseInsensitiveContains(matchApp) else { return false }
        }
        if let matchTitle = rule.matchTitle {
            guard title.localizedCaseInsensitiveContains(matchTitle) else { return false }
        }
        // At least one criterion must be specified
        return rule.matchAppName != nil || rule.matchTitle != nil
    }

    private func applyRuleCommand(_ command: String, nodeId: NodeId) {
        let parts = command.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }

        switch cmd {
        case "layout":
            guard let arg = parts.dropFirst().first else { return }
            switch arg {
            case "floating", "f":
                // Use a default frame for floating since we don't have layout yet
                let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
                tree = tree.setWindowState(nodeId, .floating(frame))
            case "tiling", "t":
                tree = tree.setWindowState(nodeId, .tiling)
            default:
                break
            }
        case "move-to-workspace":
            guard let wsName = parts.dropFirst().first,
                  let ws = tree.workspace(wsName) else { return }
            tree = tree.moveNode(nodeId, toParent: ws.id, atIndex: ws.childIds.count)
        default:
            break
        }
    }

    // MARK: - Helpers (called under lock)

    func activeWorkspaceId() -> NodeId? {
        if let focusedId = tree.focusedWindowId,
           let ws = tree.workspaceContaining(focusedId) {
            return ws.id
        }
        return tree.workspaceIds.first
    }

    func findNodeByWindowId(_ windowId: UInt32, in searchTree: TreeState? = nil) -> NodeId? {
        let t = searchTree ?? tree
        return t.allWindows.first { $0.windowId == windowId }?.id
    }

    private func focusedMacWindowId(_ tree: TreeState) -> UInt32? {
        guard let focusedNodeId = tree.focusedWindowId,
              let win = tree.windowNode(focusedNodeId) else { return nil }
        return win.windowId
    }
}
