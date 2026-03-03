import CoreGraphics

/// Command implementations. All called under lock in ServerEngine.
extension ServerEngine {

    // MARK: - Query commands

    func listWindows() -> CommandResponse {
        let windows = currentTree.allWindows
        if windows.isEmpty {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }
        let tree = currentTree
        var lines: [String] = []
        for w in windows {
            let focused = (tree.focusedWindowId == w.id) ? "*" : " "
            let ws = tree.workspaceContaining(w.id)?.name ?? "?"
            lines.append("\(focused) \(w.windowId)\t\(ws)\t\(w.appName)\t\(w.title)")
        }
        return CommandResponse(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    func listWorkspaces() -> CommandResponse {
        let tree = currentTree
        var lines: [String] = []
        for wsId in tree.workspaceIds {
            guard let ws = tree.workspaceNode(wsId) else { continue }
            let windowCount = ws.childIds.count
            let focused = tree.workspaceMRU.first == ws.name ? "*" : " "
            lines.append("\(focused) \(ws.name)\t\(windowCount) windows")
        }
        return CommandResponse(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    // MARK: - Focus

    func focusCommand(_ args: [String]) -> CommandResponse {
        guard let direction = parseDirection(args) else {
            return CommandResponse(exitCode: 1, stdout: "", stderr: "Usage: focus <left|right|up|down>\n")
        }
        var tree = currentTree
        guard let focusedId = tree.focusedWindowId,
              let win = tree.windowNode(focusedId),
              let parentNode = tree.node(win.parentId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let siblings = parentNode.childIds
        guard let idx = siblings.firstIndex(of: focusedId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let targetIdx: Int?
        let layout = containerLayout(parentNode)

        switch (direction, layout) {
        case (.left, .horizontal), (.up, .vertical):
            targetIdx = idx > 0 ? idx - 1 : nil
        case (.right, .horizontal), (.down, .vertical):
            targetIdx = idx < siblings.count - 1 ? idx + 1 : nil
        default:
            targetIdx = nil
        }

        if let ti = targetIdx {
            let targetId = siblings[ti]
            if let windowId = firstWindow(in: targetId, tree: tree) {
                tree = tree.setFocus(windowId)
                setTree(tree)
            }
        }

        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    // MARK: - Move

    func moveCommand(_ args: [String]) -> CommandResponse {
        guard let direction = parseDirection(args) else {
            return CommandResponse(exitCode: 1, stdout: "", stderr: "Usage: move <left|right|up|down>\n")
        }
        var tree = currentTree
        guard let focusedId = tree.focusedWindowId,
              let win = tree.windowNode(focusedId),
              let parentNode = tree.node(win.parentId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let siblings = parentNode.childIds
        guard let idx = siblings.firstIndex(of: focusedId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let layout = containerLayout(parentNode)

        switch (direction, layout) {
        case (.left, .horizontal), (.up, .vertical):
            if idx > 0 {
                tree = tree.moveNode(focusedId, toParent: win.parentId, atIndex: idx - 1)
                setTree(tree)
            }
        case (.right, .horizontal), (.down, .vertical):
            if idx < siblings.count - 1 {
                tree = tree.moveNode(focusedId, toParent: win.parentId, atIndex: idx + 1)
                setTree(tree)
            }
        default:
            break
        }

        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    // MARK: - Workspace

    func workspaceCommand(_ args: [String]) -> CommandResponse {
        guard let name = args.first else {
            return CommandResponse(exitCode: 1, stdout: "", stderr: "Usage: workspace <name>\n")
        }
        var tree = currentTree

        if let ws = tree.workspace(name) {
            if let firstChild = ws.childIds.first,
               let winId = firstWindow(in: firstChild, tree: tree) {
                tree = tree.setFocus(winId)
            } else {
                var mru = tree.workspaceMRU
                mru = [name] + mru.filter { $0 != name }
                tree = TreeState(
                    nodes: tree.nodes, workspaceIds: tree.workspaceIds,
                    focusedWindowId: tree.focusedWindowId,
                    workspaceMRU: mru, idGenerator: tree.idGenerator
                )
            }
            setTree(tree)
        }

        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    // MARK: - Move to workspace

    func moveToWorkspaceCommand(_ args: [String]) -> CommandResponse {
        guard let name = args.first else {
            return CommandResponse(exitCode: 1, stdout: "", stderr: "Usage: move-to-workspace <name>\n")
        }
        var tree = currentTree
        guard let focusedId = tree.focusedWindowId else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }
        guard let ws = tree.workspace(name) else {
            return CommandResponse(exitCode: 1, stdout: "", stderr: "Workspace '\(name)' not found\n")
        }

        tree = tree.moveNode(focusedId, toParent: ws.id, atIndex: ws.childIds.count)
        setTree(tree)
        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    // MARK: - Layout

    func layoutCommand(_ args: [String]) -> CommandResponse {
        var tree = currentTree
        guard let focusedId = tree.focusedWindowId,
              let win = tree.windowNode(focusedId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let parentNode = tree.node(win.parentId)
        let currentLayout: Layout
        switch parentNode {
        case .tilingContainer(let tc): currentLayout = tc.layout
        case .workspace(let ws): currentLayout = ws.layout
        default: return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let newLayout: Layout
        if let arg = args.first {
            switch arg {
            case "horizontal", "h": newLayout = .horizontal
            case "vertical", "v": newLayout = .vertical
            case "floating", "f":
                // Transition focused window to floating at its current frame
                let lastResult = self.currentLayout
                let currentFrame = lastResult.frames[focusedId]
                    ?? CGRect(x: 100, y: 100, width: 800, height: 600)
                tree = tree.setWindowState(focusedId, .floating(currentFrame))
                setTree(tree)
                return CommandResponse(exitCode: 0, stdout: "", stderr: "")
            case "tiling", "t":
                // Transition focused window back to tiling
                tree = tree.setWindowState(focusedId, .tiling)
                setTree(tree)
                return CommandResponse(exitCode: 0, stdout: "", stderr: "")
            default:
                return CommandResponse(exitCode: 1, stdout: "", stderr: "Unknown layout: \(arg)\n")
            }
        } else {
            switch currentLayout {
            case .horizontal: newLayout = .vertical
            case .vertical: newLayout = .horizontal
            }
        }

        switch parentNode {
        case .tilingContainer(let tc):
            tree = tree.setLayout(tc.id, newLayout)
        case .workspace(let ws):
            tree = tree.setWorkspaceLayout(ws.id, newLayout)
        default:
            break
        }
        setTree(tree)
        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    // MARK: - Close / Fullscreen

    func closeCommand() -> CommandResponse {
        let tree = currentTree
        guard let focusedId = tree.focusedWindowId,
              let win = tree.windowNode(focusedId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }
        setTree(tree.removeNode(focusedId))
        pendingClose = win.windowId
        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    func fullscreenCommand() -> CommandResponse {
        var tree = currentTree
        guard let focusedId = tree.focusedWindowId,
              let win = tree.windowNode(focusedId) else {
            return CommandResponse(exitCode: 0, stdout: "", stderr: "")
        }

        let newState: WindowState
        switch win.state {
        case .fullscreen:
            newState = .tiling
        default:
            newState = .fullscreen
        }

        tree = tree.setWindowState(focusedId, newState)
        setTree(tree)
        return CommandResponse(exitCode: 0, stdout: "", stderr: "")
    }

    // MARK: - Config

    func reloadConfigCommand() -> CommandResponse {
        let newConfig = loadConfigFromFile()
        setConfig(newConfig)
        return CommandResponse(exitCode: 0, stdout: "Config reloaded\n", stderr: "")
    }

    // MARK: - Internal helpers

    private func firstWindow(in nodeId: NodeId, tree: TreeState) -> NodeId? {
        guard let node = tree.node(nodeId) else { return nil }
        switch node {
        case .window: return nodeId
        case .tilingContainer(let tc):
            for child in tc.childIds {
                if let w = firstWindow(in: child, tree: tree) { return w }
            }
            return nil
        case .workspace(let ws):
            for child in ws.childIds {
                if let w = firstWindow(in: child, tree: tree) { return w }
            }
            return nil
        }
    }

    private func containerLayout(_ node: Node) -> Layout {
        if case .tilingContainer(let tc) = node { return tc.layout }
        return .horizontal
    }
}

// MARK: - Direction parsing

enum Direction {
    case left, right, up, down
}

func parseDirection(_ args: [String]) -> Direction? {
    guard let arg = args.first else { return nil }
    switch arg {
    case "left": return .left
    case "right": return .right
    case "up": return .up
    case "down": return .down
    default: return nil
    }
}
