import Testing
@testable import ZWMServer

@Test func parseEmptyConfig() throws {
    let config = try parseConfig("")
    // Should return defaults
    #expect(config.gaps.inner == 0)
    #expect(config.gaps.outer == 0)
    #expect(config.workspaceNames == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
    #expect(config.keybindings.isEmpty)
    #expect(config.windowRules.isEmpty)
}

@Test func parseGaps() throws {
    let toml = """
    [gaps]
    inner = 8
    outer = 12
    """
    let config = try parseConfig(toml)
    #expect(config.gaps.inner == 8)
    #expect(config.gaps.outer == 12)
}

@Test func parseWorkspaces() throws {
    let toml = """
    workspaces = ["code", "web", "chat"]
    """
    let config = try parseConfig(toml)
    #expect(config.workspaceNames == ["code", "web", "chat"])
}

@Test func parseKeybindings() throws {
    let toml = """
    [keybindings.main]
    alt-h = "focus left"
    alt-l = "focus right"
    alt-enter = "layout horizontal"

    [keybindings.resize]
    h = "resize shrink width 50"
    l = "resize grow width 50"
    """
    let config = try parseConfig(toml)
    #expect(config.keybindings.count == 2)

    let main = config.keybindings["main"]!
    #expect(main["alt-h"] == "focus left")
    #expect(main["alt-l"] == "focus right")
    #expect(main["alt-enter"] == "layout horizontal")

    let resize = config.keybindings["resize"]!
    #expect(resize["h"] == "resize shrink width 50")
}

@Test func parseWindowRules() throws {
    let toml = """
    [[on-window-detected]]
    match-app-name = "Finder"
    run = "layout floating"

    [[on-window-detected]]
    match-title = "Settings"
    run = "layout floating"
    """
    let config = try parseConfig(toml)
    #expect(config.windowRules.count == 2)
    #expect(config.windowRules[0].matchAppName == "Finder")
    #expect(config.windowRules[0].command == "layout floating")
    #expect(config.windowRules[1].matchTitle == "Settings")
}

@Test func parseFullConfig() throws {
    let toml = """
    workspaces = ["1", "2", "3"]

    [gaps]
    inner = 4
    outer = 8

    [keybindings.main]
    alt-h = "focus left"
    alt-j = "focus down"
    alt-k = "focus up"
    alt-l = "focus right"
    alt-1 = "workspace 1"
    alt-2 = "workspace 2"
    alt-3 = "workspace 3"

    [[on-window-detected]]
    match-app-name = "Finder"
    run = "layout floating"
    """
    let config = try parseConfig(toml)
    #expect(config.gaps.inner == 4)
    #expect(config.gaps.outer == 8)
    #expect(config.workspaceNames == ["1", "2", "3"])
    #expect(config.keybindings["main"]?.count == 7)
    #expect(config.windowRules.count == 1)
}
