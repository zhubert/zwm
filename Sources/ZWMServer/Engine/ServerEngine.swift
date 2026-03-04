import CoreGraphics
import Foundation

/// The central coordinator that owns all state and wires together:
/// events → tree mutation → layout → diff → backend calls.
public final class ServerEngine: @unchecked Sendable {
    private let backend: any WindowBackend
    private let eventQueue: EventQueue
    private var lock = os_unfair_lock()

    // Mutable state — always accessed under lock via withLock
    private var tree: TreeState
    private var lastLayout: LayoutResult
    private var _config: EngineConfig
    var pendingClose: UInt32?

    /// Metadata cache for window info (populated during start/windowCreated, used on unminimize).
    private var windowMetadata: [UInt32: (appName: String, title: String, pid: Int32)] = [:]

    /// Window IDs we recently positioned — ignore move/resize events from these to suppress feedback loops.
    private var recentlySetWindowIds: Set<UInt32> = []

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
                        nodes[wsId] = .workspace(WorkspaceNode(
                            id: ws.id, name: ws.name, childIds: ws.childIds,
                            floatingWindowIds: ws.floatingWindowIds, monitorId: monitorId,
                            layout: ws.layout
                        ))
                        tree = TreeState(
                            nodes: nodes, workspaceIds: tree.workspaceIds,
                            focusedWindowId: tree.focusedWindowId,
                            workspaceMRU: tree.workspaceMRU, idGenerator: tree.idGenerator
                        )
                    }
                }
            }

            // Populate metadata cache for all discovered windows
            for window in windows {
                windowMetadata[window.windowId] = (appName: window.appName, title: window.title, pid: window.pid)
            }

            // Add discovered windows to the first workspace using BSP
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

        await reconcile(tree: snapshot, monitors: monitors)

        try await backend.observe { [weak self] event in
            self?.eventQueue.enqueue(event)
        }
    }

    // MARK: - Event processing

    /// Process all pending events.
    public func processEvents() async {
        let events = eventQueue.drain()
        guard !events.isEmpty else { return }

        print("zwm: processing \(events.count) events: \(events)")
        let monitors = await backend.monitors()

        let snapshot = withLock { () -> TreeState in
            for event in events {
                applyEvent(event)
            }
            return tree
        }

        print("zwm: tree has \(snapshot.allWindows.count) windows after events")
        await reconcile(tree: snapshot, monitors: monitors)
    }

    private func applyEvent(_ event: WindowEvent) {
        switch event {
        case .windowCreated(let pid, let windowId, let appName, let title, let subrole, let frame):
            let validSubrole = subrole.isEmpty || subrole == "AXStandardWindow"
            let largeEnough = frame.width >= DiscoveredWindow.minManagedSize && frame.height >= DiscoveredWindow.minManagedSize
            guard validSubrole && largeEnough else { break }
            // Deduplicate: skip if already in tree
            guard findNodeByWindowId(windowId) == nil else { break }
            // Cache metadata
            windowMetadata[windowId] = (appName: appName, title: title, pid: pid)
            if let wsId = activeWorkspaceId() {
                // BSP: split the focused window if one exists and is tiling
                if let focusedId = tree.focusedWindowId,
                   tree.workspaceContaining(focusedId)?.id == wsId,
                   let focusedWin = tree.windowNode(focusedId),
                   focusedWin.state == .tiling {
                    tree = tree.insertWindowBSP(
                        windowId: windowId, appPid: pid,
                        appName: appName, title: title,
                        nearWindowId: focusedId
                    )
                } else {
                    tree = tree.insertWindow(
                        windowId: windowId, appPid: pid,
                        appName: appName, title: title,
                        inParent: wsId
                    )
                }
                // Set focus on new window
                if let nodeId = tree.allWindows.first(where: { $0.windowId == windowId })?.id {
                    tree = tree.setFocus(nodeId)
                    // Apply window rules to newly created window
                    applyWindowRules(nodeId: nodeId, appName: appName, title: title)
                }
            }
        case .windowDestroyed(let windowId):
            windowMetadata.removeValue(forKey: windowId)
            if let nodeId = findNodeByWindowId(windowId) {
                tree = tree.removeNode(nodeId)
            }
        case .windowFocused(let windowId):
            if let nodeId = findNodeByWindowId(windowId) {
                tree = tree.setFocus(nodeId)
            }
        case .windowMoved(let windowId), .windowResized(let windowId):
            // Suppress feedback loop: ignore events for windows we just repositioned
            if recentlySetWindowIds.contains(windowId) { break }
            // Otherwise no tree mutation needed
        case .windowMinimized(let windowId):
            if let nodeId = findNodeByWindowId(windowId) {
                tree = tree.removeNode(nodeId)
            }
        case .windowUnminimized(let windowId):
            // Deduplicate: skip if already in tree
            guard findNodeByWindowId(windowId) == nil else { break }
            let meta = windowMetadata[windowId]
            let appPid = meta?.pid ?? 0
            let appName = meta?.appName ?? ""
            let title = meta?.title ?? ""
            if let wsId = activeWorkspaceId() {
                if let focusedId = tree.focusedWindowId,
                   tree.workspaceContaining(focusedId)?.id == wsId,
                   let focusedWin = tree.windowNode(focusedId),
                   focusedWin.state == .tiling {
                    tree = tree.insertWindowBSP(
                        windowId: windowId, appPid: appPid,
                        appName: appName, title: title,
                        nearWindowId: focusedId
                    )
                } else {
                    tree = tree.insertWindow(
                        windowId: windowId, appPid: appPid,
                        appName: appName, title: title,
                        inParent: wsId
                    )
                }
                // Set focus on unminimized window
                if let nodeId = tree.allWindows.first(where: { $0.windowId == windowId })?.id {
                    tree = tree.setFocus(nodeId)
                }
            }
        case .appTerminated(let pid):
            let toRemove = tree.allWindows.filter { $0.appPid == pid }
            for w in toRemove {
                windowMetadata.removeValue(forKey: w.windowId)
                tree = tree.removeNode(w.id)
            }
        default:
            break
        }
    }

    // MARK: - Command execution

    /// Execute a command and return the response.
    public func execute(_ request: CommandRequest) async -> CommandResponse {
        let monitors = await backend.monitors()
        let response = executeCommand(request)
        let snapshot = currentTree

        await reconcile(tree: snapshot, monitors: monitors)

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

    // MARK: - Reconciliation

    private func reconcile(tree: TreeState, monitors: [MonitorInfo]) async {
        // Validate all windows in the tree still exist; remove stale ones
        var validatedTree = tree
        let allWindows = tree.allWindows
        var removedAny = false
        for win in allWindows {
            let exists = await backend.windowExists(win.windowId)
            if !exists {
                if let nodeId = validatedTree.allWindows.first(where: { $0.windowId == win.windowId })?.id {
                    validatedTree = validatedTree.removeNode(nodeId)
                    removedAny = true
                    print("zwm: reconcile: removed stale window \(win.windowId)")
                }
            }
        }
        if removedAny {
            withLock { self.tree = validatedTree }
        }

        let gaps = withLock { _config.gaps }
        let newLayout = layoutTree(validatedTree, monitors: monitors, gaps: gaps)

        let (oldLayout, oldFocus, newFocus) = withLock { () -> (LayoutResult, UInt32?, UInt32?) in
            let old = lastLayout
            let oldF = focusedMacWindowId(self.tree)
            let newF = focusedMacWindowId(validatedTree)
            lastLayout = newLayout
            return (old, oldF, newF)
        }

        let diff = diffLayouts(
            old: oldLayout, new: newLayout,
            oldFocusedWindowId: oldFocus, newFocusedWindowId: newFocus,
            tree: validatedTree
        )

        if !diff.isEmpty {
            print("zwm: reconcile diff: \(diff.toSet.count) frame changes, focus=\(String(describing: diff.toFocus))")
        }

        guard !diff.isEmpty else {
            // Clear feedback suppression set even when no diff
            withLock { recentlySetWindowIds.removeAll() }
            return
        }

        // Track which windows we're about to reposition (for feedback suppression)
        let setIds = Set(diff.toSet.map(\.windowId))
        withLock { recentlySetWindowIds = setIds }

        for change in diff.toSet {
            print("zwm: setFrame(\(change.windowId), \(change.frame))")
            try? await backend.setFrame(change.windowId, change.frame)
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

    // MARK: - Helpers (called under lock from applyEvent)

    func activeWorkspaceId() -> NodeId? {
        if let focusedId = tree.focusedWindowId,
           let ws = tree.workspaceContaining(focusedId) {
            return ws.id
        }
        return tree.workspaceIds.first
    }

    func findNodeByWindowId(_ windowId: UInt32) -> NodeId? {
        tree.allWindows.first { $0.windowId == windowId }?.id
    }

    private func focusedMacWindowId(_ tree: TreeState) -> UInt32? {
        guard let focusedNodeId = tree.focusedWindowId,
              let win = tree.windowNode(focusedNodeId) else { return nil }
        return win.windowId
    }
}
