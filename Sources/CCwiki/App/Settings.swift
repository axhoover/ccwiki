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
    private static let hidesStubsKey = "ccwiki.hidesStubs"

    /// Hide `status: stub` pages in the sidebar and on folder listings.
    ///
    /// Worth a preference because the ratio is lopsided and uneven: 19 of 38
    /// Primitives are stubs, against 4 of 200 References. Someone reading
    /// wants the pages with something on them; someone looking for work to do
    /// wants the opposite, which is why this is a toggle and not a default.
    static var hidesStubs: Bool {
        get { UserDefaults.standard.bool(forKey: hidesStubsKey) }
        set { UserDefaults.standard.set(newValue, forKey: hidesStubsKey) }
    }

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
