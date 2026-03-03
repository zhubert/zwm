import CoreGraphics

/// Configuration for the server engine.
public struct EngineConfig: Sendable, Equatable {
    public var gaps: GapConfig
    public var workspaceNames: [String]
    public var keybindings: [String: [String: String]]  // mode → (key → command)
    public var windowRules: [WindowRule]

    public init(
        gaps: GapConfig = GapConfig(),
        workspaceNames: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"],
        keybindings: [String: [String: String]] = [:],
        windowRules: [WindowRule] = []
    ) {
        self.gaps = gaps
        self.workspaceNames = workspaceNames
        self.keybindings = keybindings
        self.windowRules = windowRules
    }
}

/// A rule for automatically handling detected windows.
public struct WindowRule: Sendable, Equatable {
    public let matchAppName: String?
    public let matchTitle: String?
    public let command: String

    public init(matchAppName: String? = nil, matchTitle: String? = nil, command: String) {
        self.matchAppName = matchAppName
        self.matchTitle = matchTitle
        self.command = command
    }
}
