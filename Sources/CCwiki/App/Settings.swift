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
    private static let syncsAtLaunchKey = "ccwiki.syncsAtLaunch"
    private static let pageZoomKey = "ccwiki.pageZoom"
    private static let checksForUpdatesKey = "ccwiki.checksForUpdates"
    private static let lastUpdateCheckKey = "ccwiki.lastUpdateCheck"
    private static let installsUpdatesAutomaticallyKey = "ccwiki.installsUpdatesAutomatically"
    private static let showsMaintenanceNoticesKey = "ccwiki.showsMaintenanceNotices"
    private static let lastPageKey = "ccwiki.lastPage"
    private static let recentPagesKey = "ccwiki.recentPages"

    /// Pages opened most recently, newest first, by `content/`-relative path.
    static var recentPages: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentPagesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentPagesKey) }
    }

    /// The "N links on this page have no target" banner. A signal for
    /// someone editing the wiki, noise for someone reading it; off by default.
    static var showsMaintenanceNotices: Bool {
        get { UserDefaults.standard.bool(forKey: showsMaintenanceNoticesKey) }
        set { UserDefaults.standard.set(newValue, forKey: showsMaintenanceNoticesKey) }
    }

    /// When the daily check finds a release, download, verify and install it
    /// without asking, and offer a relaunch. On by default: the point of the
    /// updater is that nobody has to think about it. Never relaunches on its own.
    static var installsUpdatesAutomatically: Bool {
        get {
            UserDefaults.standard.object(forKey: installsUpdatesAutomaticallyKey) == nil
                ? true : UserDefaults.standard.bool(forKey: installsUpdatesAutomaticallyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: installsUpdatesAutomaticallyKey) }
    }
    private static let expandedFoldersKey = "ccwiki.expandedFolders"

    /// The page showing when the app last quit, by `content/`-relative path.
    static var lastPage: String? {
        get { UserDefaults.standard.string(forKey: lastPageKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastPageKey) }
    }

    /// The sidebar folders left open.
    static var expandedFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: expandedFoldersKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: expandedFoldersKey) }
    }

    /// Ask GitHub once a day whether there is a newer release. On by default;
    /// off is honoured absolutely — no request is made at all.
    static var checksForUpdates: Bool {
        get {
            UserDefaults.standard.object(forKey: checksForUpdatesKey) == nil
                ? true : UserDefaults.standard.bool(forKey: checksForUpdatesKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: checksForUpdatesKey) }
    }

    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastUpdateCheckKey) }
    }

    /// Fast-forward the clone when the app opens, so the wiki does not go
    /// quietly stale for someone who never presses ⌘R. On by default; the
    /// reader never waits on it, and offline it is a quiet note.
    static var syncsAtLaunch: Bool {
        get {
            UserDefaults.standard.object(forKey: syncsAtLaunchKey) == nil
                ? true : UserDefaults.standard.bool(forKey: syncsAtLaunchKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: syncsAtLaunchKey) }
    }

    /// The reader's text size, as `WKWebView.pageZoom`. 1 is the CSS size.
    static var pageZoom: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: pageZoomKey)
            return stored > 0 ? stored : 1
        }
        set { UserDefaults.standard.set(newValue, forKey: pageZoomKey) }
    }

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
