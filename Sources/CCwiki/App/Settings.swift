import Foundation

/// Preferences that outlive a launch.
///
/// Deliberately tiny. Everything CCwiki needs it discovers — the clone is at
/// a fixed path, tools are found by searching, the macro table is parsed. The
/// only thing worth persisting is the handful of overrides for when discovery
/// gets it wrong, which on a developer's Mac is mostly "my `node` is in a
/// version manager".
struct CCwikiSettings: Sendable {

    private static let toolOverrideKey = "ccwiki.toolOverrides"

    /// `ToolLocator.Tool.rawValue` → an absolute path the user picked.
    static func toolOverrides() -> [ToolLocator.Tool: String] {
        guard let stored = UserDefaults.standard.dictionary(forKey: toolOverrideKey)
            as? [String: String]
        else { return [:] }

        var result: [ToolLocator.Tool: String] = [:]
        for (name, path) in stored {
            guard let tool = ToolLocator.Tool(rawValue: name) else { continue }
            result[tool] = path
        }
        return result
    }

    static func setToolOverride(_ path: String?, for tool: ToolLocator.Tool) {
        var stored = UserDefaults.standard.dictionary(forKey: toolOverrideKey)
            as? [String: String] ?? [:]
        if let path, !path.isEmpty {
            stored[tool.rawValue] = path
        } else {
            stored.removeValue(forKey: tool.rawValue)
        }
        UserDefaults.standard.set(stored, forKey: toolOverrideKey)
    }
}
