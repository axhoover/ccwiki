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
    /// The line of its body revealed on the page `opensOnLoad` renders.
    var revealing: Int? = nil
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
    ///   - isColdStart: true for the first session of the process, and for
    ///     the first after every reader window has closed.
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
        // A window opened on a page was asked for it, as a paper window's
        // Show Reference Page asks with no reader open: it opens over the
        // launch document, as a pending location does, which leaves the
        // document one Back away.
        if restored == nil, let opening = window.opening {
            plan.opensOnLoad = opening
            plan.find = window.find
            plan.revealing = window.revealing
            return plan
        }
        // A restored page, or the launch document, is something to read
        // already; neither is opened over.
        guard history.current == .empty, showsAtOnce == nil else { return plan }

        if isColdStart, let lastPage {
            plan.opensOnLoad = .page(path: lastPage, anchor: nil)
        } else {
            plan.opensHomeOnLoad = true
        }
        return plan
    }
}

/// What a load after a session's first does to it (§3.6). Pure.
///
/// A pull can take pages away. Back and Forward forget them, as a restored
/// history does at the first load, and a page on screen that went gives
/// way to the nearest one left on Back. Without this the chrome moved to a
/// page the wiki no longer has, or stayed on one, while the web view kept
/// showing the last page it rendered.
struct SessionReloadPlan: Equatable, Sendable {
    typealias Location = AppModel.Location

    enum Render: Equatable, Sendable {
        /// The page on screen stays as it is.
        case unchanged
        /// The page on screen again, keeping the reader's place.
        case inPlace
        /// The page on screen went: the one Back now holds, where it was left.
        case current
        /// Nothing is left to show.
        case home
    }

    var history: NavigationHistory
    var render: Render

    /// - Parameters:
    ///   - exists: whether the wiki has a page at a path.
    ///   - changed: whether the load changed what a location shows,
    ///     `LibraryUpdate.requiresRerender(of:)`.
    ///   - revisionGone: whether the page on screen was rendered at a
    ///     revision the copy can no longer read (`outlivesRevision`).
    static func plan(
        history: NavigationHistory, exists: (String) -> Bool,
        changed: (Location) -> Bool, revisionGone: Bool
    ) -> SessionReloadPlan {
        let pruned = history.pruned { $0.path.map(exists) ?? true }
        let render: Render
        if pruned.current == .empty {
            render = .home
        } else if pruned.current != history.current {
            render = .current
        } else if changed(pruned.current) || (revisionGone && pruned.current.path != nil) {
            render = .inPlace
        } else {
            render = .unchanged
        }
        return SessionReloadPlan(history: pruned, render: render)
    }

    /// Whether a page rendered at `rendered` outlives its revision now that
    /// the copy is at `head`. A snapshot has no history: once a sync moves
    /// its marker, the file the page was rendered from cannot be read, and
    /// a correction about a passage of it would fall back to the whole page
    /// with a notice that the page changed, though it may not have
    /// (corrections §3.5). A clone keeps every revision.
    static func outlivesRevision(
        store: AppPaths.WikiStore, rendered: String?, head: String?
    ) -> Bool {
        store == .snapshot && rendered != head
    }
}
