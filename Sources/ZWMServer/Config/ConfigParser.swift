import CoreGraphics
import Foundation
import TOMLKit

/// Parse a TOML config string into an EngineConfig.
public func parseConfig(_ toml: String) throws -> EngineConfig {
    let table = try TOMLTable(string: toml)
    var config = EngineConfig()

    // [gaps]
    if let gaps = table["gaps"]?.table {
        let inner = gaps["inner"]?.int.map { CGFloat($0) } ?? 0
        let outer = gaps["outer"]?.int.map { CGFloat($0) } ?? 0
        config.gaps = GapConfig(inner: inner, outer: outer)
    }

    // workspaces = ["1", "2", ...]
    if let wsArray = table["workspaces"]?.array {
        var names: [String] = []
        for item in wsArray {
            if let s = item.string {
                names.append(s)
            }
        }
        if !names.isEmpty {
            config.workspaceNames = names
        }
    }

    // [keybindings.main], [keybindings.resize], etc.
    if let keybindings = table["keybindings"]?.table {
        var modes: [String: [String: String]] = [:]
        for (modeName, modeValue) in keybindings {
            if let modeTable = modeValue.table {
                var bindings: [String: String] = [:]
                for (key, value) in modeTable {
                    if let cmd = value.string {
                        bindings[key] = cmd
                    }
                }
                modes[modeName] = bindings
            }
        }
        config.keybindings = modes
    }

    // [[on-window-detected]]
    if let rules = table["on-window-detected"]?.array {
        var windowRules: [WindowRule] = []
        for item in rules {
            if let ruleTable = item.table {
                let matchApp = ruleTable["match-app-name"]?.string
                let matchTitle = ruleTable["match-title"]?.string
                let run = ruleTable["run"]?.string ?? ""
                windowRules.append(WindowRule(
                    matchAppName: matchApp, matchTitle: matchTitle, command: run
                ))
            }
        }
        config.windowRules = windowRules
    }

    return config
}

/// Load config from the default file path.
public func loadConfigFromFile() -> EngineConfig {
    let paths = [
        NSString("~/.zwm.toml").expandingTildeInPath,
        NSString("~/.config/zwm/zwm.toml").expandingTildeInPath,
    ]
    for path in paths {
        if let contents = try? String(contentsOfFile: path, encoding: .utf8),
           let config = try? parseConfig(contents) {
            return config
        }
    }
    return EngineConfig()
}
