import CoreGraphics

/// Configuration for the server engine.
public struct EngineConfig: Sendable, Equatable {
    public var gaps: GapConfig
    public var workspaceNames: [String]
    public var keybindings: [String: [String: String]]  // mode → (key → command)
    public var windowRules: [WindowRule]
    public var maxTilingWindows: Int
    public var focusFollowsMouse: Bool

    public init(
        gaps: GapConfig = GapConfig(),
        workspaceNames: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"],
        keybindings: [String: [String: String]] = [:],
        windowRules: [WindowRule] = [],
        maxTilingWindows: Int = 4,
        focusFollowsMouse: Bool = false
    ) {
        self.gaps = gaps
        self.workspaceNames = workspaceNames
        self.keybindings = keybindings
        self.windowRules = windowRules
        self.maxTilingWindows = maxTilingWindows
        self.focusFollowsMouse = focusFollowsMouse
    }
}

/// A rule for automatically handling detected windows.
public struct WindowRule: Sendable, Equatable {
    public let matchAppName: String?
    public let matchTitle: String?
    public let exact: Bool
    public let command: String

    public init(matchAppName: String? = nil, matchTitle: String? = nil, exact: Bool = false, command: String) {
        self.matchAppName = matchAppName
        self.matchTitle = matchTitle
        self.exact = exact
        self.command = command
    }
}
