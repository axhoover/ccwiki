import Foundation

/// What a reader window keeps when macOS restores it: where it has been, and
/// how its inspector and sidebar were left (plans/reader-comforts.md §1.3).
///
/// Saved as JSON in the window's `@SceneStorage`. The reading position is
/// saved apart from it, so scrolling does not encode the history again.
struct ReaderSessionState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = ReaderSessionState.currentVersion
    var history: NavigationHistory
    /// `AppModel.InspectorTab.rawValue`.
    var inspectorTab: String
    var showsInspector: Bool
    /// Sorted, so the same folders always save the same bytes.
    var expandedFolders: [String]

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    /// nil for nil, for bytes that do not decode, and for another version.
    ///
    /// Whole or not at all: a window restored from state it cannot read
    /// starts as a new one rather than with half of it.
    static func decoded(from data: Data?) -> ReaderSessionState? {
        guard let data,
              let stamp = try? JSONDecoder().decode(VersionStamp.self, from: data),
              stamp.version == currentVersion
        else { return nil }
        return try? JSONDecoder().decode(ReaderSessionState.self, from: data)
    }

    /// Read first, so a version this build does not know is refused whatever
    /// shape the rest of it has.
    private struct VersionStamp: Decodable {
        let version: Int
    }
}

/// How a session starts (§1.7). Pure.
///
/// The one decision of Part 1 that is easiest to get wrong and impossible to
/// see without several windows, so it is made here, where a test can make
/// it, from everything a starting session is handed.
struct SessionStartPlan: Equatable, Sendable {
    typealias Location = AppModel.Location

    /// Restored, else empty.
    var history: NavigationHistory
    /// The launch document, shown before the wiki loads. A restored page
    /// goes onto Back behind it.
    var showsAtOnce: Location?
    /// Opened once the wiki is loaded: the pending location, else the
    /// window's opening, else the cold start's last page.
    var opensOnLoad: Location?
    /// Found on the page `opensOnLoad` renders.
    var find: [String]?
    /// Nothing else to show: Home, once the wiki is loaded.
    var opensHomeOnLoad: Bool

    /// - Parameters:
    ///   - restored: the window's saved state. It wins, and the window
    ///     value's `opening` and `find` are ignored: macOS restores the value
    ///     too, and a tab first opened by ⌘-click must not reopen its first
    ///     page over its history.
    ///   - pending: a location asked for while no reader was open. It opens
    ///     in any session, over whatever it restored.
    ///   - launchDocument: Welcome or What's New, which the model hands to
    ///     the first session of the process only.
    ///   - isColdStart: true for the first session of the process only.
    ///   - lastPage: the page read last, nil under the screenshot harness.
    static func plan(
        restored: ReaderSessionState?, window: ReaderWindow,
        pending: Location?, launchDocument: AppModel.Document?,
        isColdStart: Bool, lastPage: String?
    ) -> SessionStartPlan {
        let history = restored?.history ?? NavigationHistory()
        let showsAtOnce = launchDocument.map { Location.document($0) }
        var plan = SessionStartPlan(
            history: history, showsAtOnce: showsAtOnce,
            opensOnLoad: nil, find: nil, opensHomeOnLoad: false)

        if let pending {
            plan.opensOnLoad = pending
            return plan
        }
        // A restored page, or the launch document, is something to read
        // already; neither is opened over.
        guard history.current == .empty, showsAtOnce == nil else { return plan }

        if restored == nil, let opening = window.opening {
            plan.opensOnLoad = opening
            plan.find = window.find
        } else if isColdStart, let lastPage {
            plan.opensOnLoad = .page(path: lastPage, anchor: nil)
        } else {
            plan.opensHomeOnLoad = true
        }
        return plan
    }
}
