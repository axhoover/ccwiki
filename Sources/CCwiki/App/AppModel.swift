import Foundation
import Observation
import SwiftUI

/// App-wide state.
///
/// One `@Observable @MainActor` object owns everything the windows share:
/// the wiki, the search index, jobs, sync, updates and settings. What one
/// reader window shows is its `ReaderSession`'s. The expensive parts —
/// walking the clone, parsing 297 files, rebuilding the FTS index — happen
/// off the main actor and land here as one assignment, so the UI never sees
/// a half-built library.
@Observable
@MainActor
final class AppModel {

    // MARK: Configuration

    let paths: AppPaths
    private(set) var tools = ToolLocator()
    private(set) var toolOverrides: [ToolLocator.Tool: String] = [:]
    /// True until the ingestion tools have been looked for. Reading never
    /// waits on this; Settings and the ingest sheet say "looking" meanwhile.
    private(set) var isDiscoveringTools = true
    /// `/usr/bin/git` is on every Mac, but is only Apple's install-the-tools
    /// stub until the Command Line Tools are there. When this is set, `git`
    /// counts as missing and the reader's empty state says what to install.
    private(set) var needsDeveloperTools = false
    private var discoveryGeneration = 0
    private(set) var isGitHubAuthenticated = false
    /// gh is there, but GitHub could not be asked whether it is signed in:
    /// offline, no answer before the deadline, or an error from GitHub
    /// other than a refused token. Settings and the ingest sheet say
    /// offline, not "not signed in" (plans/corrections.md §7.1).
    private(set) var isGitHubUnreachable = false
    private(set) var canPushToRemote = false
    /// True while gh is asked whether it is signed in, and the clone whether
    /// it can push (`askGitHub`). Settings and the ingest sheet say
    /// "checking" meanwhile, not "not signed in": both answers start false.
    private(set) var isCheckingGitHub = false
    /// Which `askGitHub` is the latest; an earlier one's answer is dropped.
    @ObservationIgnored private var gitHubAsk = 0
    private(set) var vendorManifest: String?

    /// Fast-forward the clone at launch. Persisted; see `CCwikiSettings`.
    var syncsAtLaunch: Bool = CCwikiSettings.syncsAtLaunch {
        didSet { CCwikiSettings.syncsAtLaunch = syncsAtLaunch }
    }

    /// The broken-link banner on a page. Persisted; off for readers.
    var showsMaintenanceNotices: Bool = CCwikiSettings.showsMaintenanceNotices {
        didSet {
            guard showsMaintenanceNotices != oldValue else { return }
            CCwikiSettings.showsMaintenanceNotices = showsMaintenanceNotices
            preferencesDidChange()
        }
    }

    /// The card shown when the pointer rests on a link to another page.
    /// Persisted, on by default. Off, the render payload carries no cards.
    var showsLinkPreviews: Bool = CCwikiSettings.showsLinkPreviews {
        didSet {
            guard showsLinkPreviews != oldValue else { return }
            CCwikiSettings.showsLinkPreviews = showsLinkPreviews
            preferencesDidChange()
        }
    }

    /// Hide stub pages in the sidebar and on folder listings. Persisted.
    var hidesStubs: Bool = CCwikiSettings.hidesStubs {
        didSet {
            guard hidesStubs != oldValue else { return }
            CCwikiSettings.hidesStubs = hidesStubs
            rebuildBrowseState()
            // The rendered folder page does not follow the preference by itself.
            preferencesDidChange()
        }
    }

    /// A preference that changes what a page renders to changed: every
    /// reader window renders its own page again (§1.2: the model never
    /// renders; each session decides).
    private func preferencesDidChange() {
        for session in sessions.values { session.preferencesDidChange() }
    }

    // MARK: Library

    /// The parsed wiki. `nil` until the first load finishes.
    private(set) var index: WikiIndex?
    private(set) var macros = MacroTable.empty
    private(set) var backlinks: [String: [WikiIndex.Backlink]] = [:]
    /// The wiki's relationship hypergraph, read from `.reductions/relations.json`
    /// in the clone. Empty until the first load, and empty *after* it whenever
    /// the clone predates the reductions migration — see `RelationsManifest`.
    private(set) var relations = RelationsManifest.empty
    /// Display names for manifest nodes, which need the parsed wiki: every
    /// variant's `title` is just its id, so its name comes from the host page's
    /// heading.
    private(set) var relationLabels = RelationLabels.empty
    /// Every page's hover card, built with the labels; see `LinkPreviews`.
    private(set) var linkPreviews = LinkPreviews.empty
    /// Pages the manifest marks `unlisted`. Real nodes — they take part in
    /// relations and in the closure — kept out of browse and navigation only.
    private(set) var unlistedPaths: Set<String> = []
    private(set) var modifiedDates: [String: Date] = [:]
    private(set) var headRevision: String?
    /// When the checked-out commit was made: "the wiki as of".
    private(set) var headDate: Date?

    // MARK: Derivations

    /// What CCwiki may conclude by chaining the recorded reductions
    /// (plans/derivations.md). Built with the manifest, in the same detached
    /// task, and assigned beside it, so nothing ever sees a manifest and
    /// closures from different commits (SWIFTUI-RULES §3.1: rebuilt from
    /// source, never patched).
    private(set) var derivation = Derivation.empty
    /// Bumped whenever the library is replaced, so a view keyed on it
    /// recomputes: the explorer's answer is computed off the main actor and
    /// held in view state, which would otherwise outlive a sync.
    private(set) var libraryGeneration = 0

    // MARK: Relations explorer

    /// The explorer's question. Persisted, and restored at launch with the
    /// models toggle off (relations-explorer.md §2.4): nobody comes back
    /// days later to idealised results without having asked for them.
    var explorerQuery: ExplorerQuery =
        CCwikiSettings.explorerQuery.map { $0.launching() } ?? ExplorerQuery() {
        didSet {
            guard explorerQuery != oldValue else { return }
            CCwikiSettings.explorerQuery = explorerQuery
        }
    }
    /// Earlier questions, newest first, each with its toggle.
    private(set) var explorerRecents: [ExplorerQuery] = CCwikiSettings.explorerRecents
    static let explorerRecentsLimit = 10
    /// Bumped to ask a reader window to open the explorer: `openWindow` is an
    /// environment action, so only a view can call it, and the reader's
    /// context menu is AppKit. The same pattern as `jobsWindowRequests`.
    private(set) var explorerWindowRequests = 0
    /// Reader windows on screen, one per tab: the live sessions. At 0 a page
    /// the explorer opens would be shown nowhere, so it opens a reader
    /// window first.
    private(set) var mainWindowCount = 0
    /// The inspector's derived sections left open, by role.
    private(set) var derivedSectionsExpanded: Set<String> =
        Set(CCwikiSettings.derivedSectionsExpanded) {
        didSet { CCwikiSettings.derivedSectionsExpanded = derivedSectionsExpanded.sorted() }
    }

    // MARK: Navigation

    // Where a reader is, and how it got there, is its window's: see
    // `ReaderSession`. The types that describe it stay here, where
    // `Location`'s coding is synthesized.

    /// A page that ships with the app rather than with the wiki.
    enum Document: String, Hashable, Codable, Sendable {
        case welcome
        case whatsNew

        var title: String {
            switch self {
            case .welcome: "Welcome to CCwiki"
            case .whatsNew: "What's New in CCwiki"
            }
        }
    }

    /// What the reader is showing.
    ///
    /// `Codable` so a window's Back and Forward can be saved and restored
    /// with it (plans/reader-comforts.md §1.7). The coding is synthesized,
    /// which only this file can do: renaming a case or its labels changes
    /// what a saved history decodes to.
    enum Location: Hashable, Codable, Sendable {
        case page(path: String, anchor: String?)
        case folder(slug: String)
        case document(Document)
        case empty

        /// Reading one of the app's own pages needs no wiki, so it can be
        /// shown while the first download is still under way.
        var isDocument: Bool {
            if case .document = self { return true }
            return false
        }

        var path: String? {
            if case .page(let path, _) = self { return path }
            return nil
        }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case outline = "Outline"
        case backlinks = "Backlinks"
        /// The typed relationships from `relations.json`.
        ///
        /// Its own tab rather than a section under the page, because the wiki
        /// now generates a `## Participates in` block into the markdown itself
        /// — the reader already renders that. Repeating it inline would be
        /// duplication; the tab earns its place by carrying what the generated
        /// block does not: kind, class, model, status and source.
        case relations = "Relations"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .outline: "list.bullet.indent"
            case .backlinks: "arrow.turn.up.left"
            case .relations: "arrow.triangle.branch"
            }
        }
    }

    // MARK: Reader windows

    /// Every reader window's session, by its window's id: its page, history,
    /// web view, sidebar, inspector and sheets (plans/reader-comforts.md
    /// §1.2). Not observed: a view in a reader window reads its own session
    /// from the environment, never this, and a window that is not a reader
    /// goes through `activeSession`.
    @ObservationIgnored private var sessions: [UUID: ReaderSession] = [:]
    /// The windows of this process that have closed. A closed id never comes
    /// back: a window that turns up with one is given a new id.
    @ObservationIgnored private var closedSessionIDs: Set<UUID> = []
    /// The reader windows, most recently key first. Observed, unlike the
    /// registry, so what follows the active reader updates with it: the
    /// explorer's Explore From This Page follows the key reader.
    private var sessionOrder = SessionOrder<UUID>()
    /// How the windows the app is opening itself join the others: as a tab
    /// of which window, in front or behind. Taken by the new window when it
    /// first sees its `NSWindow`, inside a view update, so not observed.
    @ObservationIgnored private var windowRequests = ReaderWindowRequests()

    /// The session for the reader window `id`, created the first time the
    /// window asks (§1.3). `windowNumber` is its `NSWindow`'s, 0 or less
    /// until the window is first shown; `window` is the window itself,
    /// which the session keeps whether it has a number yet or not.
    ///
    /// Nil when `id` is live in another window, which a restoration can
    /// produce, or closed earlier in this process: one web view is never in
    /// two windows, and a closed window never comes back. The caller then
    /// takes a fresh id.
    func claimSession(
        for id: UUID, windowNumber: Int, window: NSWindow? = nil
    ) -> ReaderSession? {
        guard !closedSessionIDs.contains(id) else { return nil }
        if let existing = sessions[id] {
            // The same window asking again keeps its session.
            let isSameWindow = (window != nil && existing.hostWindow === window)
                || (windowNumber > 0 && existing.windowNumber == windowNumber)
            return isSameWindow ? existing : nil
        }
        let session = ReaderSession(id: id, model: self)
        session.windowNumber = windowNumber > 0 ? windowNumber : nil
        session.hostWindow = window
        sessions[id] = session
        sessionOrder.opened(id)
        mainWindowCount = sessions.count
        // An ingest sheet asked for while no reader was open appears here.
        _ = ingestTarget.claim(by: id)
        return session
    }

    /// The reader window `id` became key: it is the active reader now.
    func sessionBecameKey(_ id: UUID) {
        guard sessions[id] != nil else { return }
        sessionOrder.becameKey(id)
    }

    /// The reader window `id` is closing: its session and web view go, and
    /// the id is not handed out again. From the window's
    /// `willCloseNotification`, never `onDisappear`, which SwiftUI may send
    /// for a tab that is only deselected (§1.3).
    ///
    /// With the last reader closed, the next one starts as the first of a
    /// launch does, on the page read last: a reader who closes the window
    /// and clicks the Dock icon is back where they were, as before there
    /// were tabs (§1.7).
    func sessionDidClose(_ id: UUID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        closedSessionIDs.insert(id)
        sessionOrder.closed(id)
        mainWindowCount = sessions.count
        ingestTarget.windowClosed(id)
        if sessions.isEmpty { hasColdStarted = false }
    }

    /// The reader that windows which are not readers act on: the reader
    /// window that was key most recently (§1.8). Nil with no reader open.
    var activeSession: ReaderSession? {
        sessionOrder.mostRecent.flatMap { sessions[$0] }
    }

    /// The caller is about to open `request.window`: the request says which
    /// window it joins as a tab, if any (§1.4).
    func expectReaderWindow(_ request: ReaderWindowRequest) {
        windowRequests.expect(request)
    }

    /// The tabbing a new window was opened with, once, by that window.
    func takeTabbing(for windowID: UUID) -> ReaderWindowRequest? {
        windowRequests.takeTabbing(for: windowID)
    }

    /// The window `session` is in: the window itself, which its view hands
    /// over when it claims the session, else the one its number names. A
    /// tab that has never been key may have no number yet.
    private func hostWindow(of session: ReaderSession) -> NSWindow? {
        session.hostWindow ?? session.windowNumber.flatMap { NSApp.window(withWindowNumber: $0) }
    }

    /// Brings the reader window `session` forward, selecting its tab.
    private func bringForward(_ session: ReaderSession) {
        hostWindow(of: session)?.makeKeyAndOrderFront(nil)
    }

    // MARK: For windows that are not readers

    // The explorer, Jobs and a paper window have no session, so they open
    // pages through these, in the active reader (§1.8). With no reader open,
    // the location waits for the next one to start. A view inside a reader
    // window never calls them; it opens pages in its own window's session.

    /// A location asked for while no reader was open, taken by the next
    /// session to start.
    @ObservationIgnored private var pendingReaderLocation: Location?

    /// Taken once: the next session to start opens it (§1.7).
    func takePendingReaderLocation() -> Location? {
        defer { pendingReaderLocation = nil }
        return pendingReaderLocation
    }

    /// Shows `location` in the active reader without bringing it forward, so
    /// the explorer stays key while a proof's pages open beside it.
    func open(_ location: Location) {
        guard let session = activeSession else {
            pendingReaderLocation = location
            return
        }
        session.open(location)
    }

    func openPage(_ path: String, anchor: String? = nil) {
        open(.page(path: path, anchor: anchor))
    }

    func openRelationObject(_ objectID: String) {
        if let session = activeSession {
            session.openRelationObject(objectID)
        } else if let destination = relationLabels.destination(objectID) {
            open(.page(path: destination.path, anchor: destination.anchor))
        }
    }

    func navigate(to destination: CCwikiURL.Destination) {
        if let session = activeSession {
            session.navigate(to: destination)
            return
        }
        switch destination {
        case .page(let path, let anchor): open(.page(path: path, anchor: anchor))
        case .folder(let slug): open(.folder(slug: slug))
        case .asset(let path):
            if let file = CCwikiURL.assetFile(path, in: paths.content) {
                NSWorkspace.shared.open(file)
            }
        case .shell: break
        }
    }

    /// Opens `location` in a reader and brings that window forward: for an
    /// explicit Show, such as a paper window's Show Reference Page, which
    /// must be seen. A reader tab already showing the page is preferred,
    /// else the active reader. False with no reader open, or none whose
    /// window can be brought forward, and the caller opens one.
    func revealInReader(_ location: Location) -> Bool {
        let showing = location.path.flatMap { path in
            sessions.values.first { $0.location.path == path && hostWindow(of: $0) != nil }
        }
        guard let session = showing ?? activeSession, let window = hostWindow(of: session) else {
            return false
        }
        session.open(location)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// The explorer's own Explore From This Page, about the active reader's
    /// page.
    var currentPageExplorerQuery: ExplorerQuery? { activeSession?.currentPageExplorerQuery }
    var canExploreCurrentPage: Bool { activeSession?.canExploreCurrentPage ?? false }

    // MARK: Sync

    enum SyncState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)

        /// A network outage is not a fault: the reader works entirely from the
        /// clone, so it earns a quiet icon rather than a warning triangle.
        var isOffline: Bool {
            if case .failed(let message) = self { return message.hasPrefix("Offline") }
            return false
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private(set) var syncState: SyncState = .idle
    private(set) var syncLog: [String] = []
    private var syncTask: Task<Void, Never>?

    // MARK: Search

    private let searchIndex: SearchIndex
    var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    private(set) var searchResults: [SearchHit] = []
    /// The query `searchResults` are for. The search runs once typing
    /// pauses, so until it lands this is the last query, and the palette's
    /// Return waits for it to be `searchQuery` (`PaletteReturn`).
    private(set) var searchResultsQuery = ""
    /// Set when nothing matched as typed and the results are for this
    /// corrected query instead.
    private(set) var searchCorrection: String?
    private(set) var searchError: String?
    private var searchTask: Task<Void, Never>?

    /// ⇧⌘R, the reference search: the same shape as ⌘S, kept separate so
    /// each sheet reopens on its own last query.
    var referenceQuery = "" {
        didSet { scheduleReferenceSearch() }
    }
    private(set) var referenceResults: [ReferenceHit] = []
    /// The query `referenceResults` are for, as `searchResultsQuery`.
    private(set) var referenceResultsQuery = ""
    private(set) var referenceError: String?
    private var referenceTask: Task<Void, Never>?

    /// ⇧⌘F, literal text across every page. The pages, split into lines,
    /// are rebuilt with the library; a query scans them off the main actor.
    var grepQuery = "" {
        didSet { scheduleGrep() }
    }
    private(set) var grepResults: [TextGrep.Hit] = []
    /// The query `grepResults` are for, as `searchResultsQuery`.
    private(set) var grepResultsQuery = ""
    private var grepTask: Task<Void, Never>?
    @ObservationIgnored private var textGrep = TextGrep.empty
    /// Setting the query recomputes the results, so the two can never drift —
    /// whether the change came from the text field, a menu command, or the
    /// screenshot harness.
    var quickSwitcherQuery = "" {
        didSet { refreshQuickSwitcher() }
    }
    private(set) var quickSwitcherResults: [QuickSwitchItem] = []
    /// How many of `quickSwitcherResults` are recent pages, so the view can
    /// head them. Zero whenever there is a query.
    private(set) var quickSwitcherRecentCount = 0
    /// Most recent first, persisted. The page on screen is left out of the
    /// switcher's list, so ⌘O then Return goes back to the page before it.
    private var recentPages: [String] = CCwikiSettings.recentPages
    static let recentPagesLimit = 12
    /// The page on screen in the window that presented the quick switcher,
    /// which its list leaves out. Set by `resetQuickSwitcher`, through
    /// `ReaderSession.presentQuickSwitcher`.
    @ObservationIgnored private(set) var quickSwitcherExcludedPath: String?

    // MARK: Jobs

    /// Every job, and everything that moves one along (plans/corrections.md
    /// §4, §11.6). Made in `init`, so the history is loaded before any window
    /// is restored.
    let jobCenter: JobCenter
    /// Where pull requests and issues go, resolved once (corrections §10).
    let publishTarget: PublishTarget

    /// The jobs, newest first: the job center's, for the views that read
    /// them here.
    var jobs: [Job] { jobCenter.jobs }
    /// Worktrees git still knows about that no live job owns — the residue of
    /// a crash or a force-quit mid-job.
    var orphanedWorktrees: [String] { jobCenter.orphanedWorktrees }
    /// Which reader window shows the ingest sheet: fixed when the sheet is
    /// asked for, so its link, notes and dropped PDF stay on one window
    /// when another becomes key (§1.3).
    private var ingestTarget = IngestSheetTarget()
    /// The reader window showing the ingest sheet, if one is.
    var ingestSheetTarget: UUID? { ingestTarget.window }
    /// A PDF dropped on the reader, waiting for the sheet to pick it up.
    var pendingDroppedPDF: URL?

    /// Ingest a Paper: the sheet, on the window that asked (the one a PDF
    /// was dropped on, or whose menu or link asked), else on the active
    /// reader. With no reader open it waits for the next one. While it is
    /// up, another request only brings its window forward, as one from
    /// outside a reader (the Jobs window) always does.
    ///
    /// A window that closed after it asked, as one a PDF was dropped on can
    /// while the drop loads, is no window to pin to: the sheet goes to the
    /// active reader instead, so it never waits on a window that is gone.
    func requestIngestSheet(in session: UUID?) {
        let live = session.flatMap { sessions[$0]?.id }
        ingestTarget.request(in: live, active: activeSession?.id)
        if let target = ingestTarget.window, target != live, let shown = sessions[target] {
            bringForward(shown)
        }
    }

    func dismissIngestSheet() {
        ingestTarget.dismiss()
    }

    /// Bumped to ask the root view to open the jobs window. `openWindow` is an
    /// environment action, so only a view can call it; the model can only ask.
    private(set) var jobsWindowRequests = 0
    /// The job the last request asked the Jobs window to show, if any, until
    /// the window takes it.
    private(set) var jobsWindowSelection: String?

    /// Opens the Jobs window, on `jobID` when given: a job just started, or
    /// the review a status-bar count leads to.
    func requestJobsWindow(selecting jobID: String? = nil) {
        jobsWindowSelection = jobID
        jobsWindowRequests += 1
    }

    /// The job asked for, once: taking it clears it, so a Jobs window
    /// reopened later without a request opens on the newest job, as before.
    func takeJobsWindowSelection() -> String? {
        defer { jobsWindowSelection = nil }
        return jobsWindowSelection
    }

    // MARK: Editor windows

    /// Bumped to ask a reader window to open an editor (corrections §7.2):
    /// for AppKit and async callers, which have no `openWindow`. Every
    /// reader window's root view observes it; the first to take the request
    /// opens the window, and the others find nil.
    private(set) var editorWindowRequestCount = 0
    @ObservationIgnored private var editorWindowRequest: EditorTarget?

    /// Asks for the editor of `target`, at `lines`. A view that has
    /// `openWindow` calls `showEditor(_:at:using:)` instead.
    func requestEditor(_ target: EditorTarget, at lines: LineRange?) {
        editorSession(for: target).reveal(lines)
        editorWindowRequest = target
        editorWindowRequestCount += 1
    }

    /// The editor asked for, once: taking it clears it.
    func takeEditorRequest() -> EditorTarget? {
        defer { editorWindowRequest = nil }
        return editorWindowRequest
    }

    /// Each open editor's text and preview, by window (corrections §7.5).
    /// Observed, so Open Draft PR's gate, which asks each of a job's
    /// editors whether it is settled, sees one that opens after it was
    /// drawn. Changed only from actions and closing tasks, never in a body.
    var editorSessions: [EditorTarget: EditorSession] = [:]

    // MARK: Review

    /// The review's Changes pane shows Source rather than Rendered.
    var reviewShowsSource = false

    /// The review's own web view: the reader's shell, pipeline and macros,
    /// rendering changed blocks (corrections §6.3). Made on first use; it
    /// shares the readers' data store, and a WebContent restart checks the
    /// staged pipeline first, as a reader's does.
    @ObservationIgnored private(set) lazy var reviewWeb: WebController = {
        let web = WebController(paths: self.paths, webRoot: self.webRoot, pageZoom: self.pageZoom)
        web.onRendererRestart = { [weak self] in self?.checkWebRoot() }
        return web
    }()

    /// The model a described correction runs with: a `claude --model`
    /// alias, or "" for the CLI's default. Persisted; see `CCwikiSettings`.
    var correctionModel: String = CCwikiSettings.correctionModel {
        didSet { CCwikiSettings.correctionModel = correctionModel }
    }

    /// Same pattern for Settings. `openSettings` is an environment action, and
    /// the `showSettingsWindow:` selector that worked before macOS 13 does
    /// nothing for a SwiftUI `Settings` scene (SWIFTUI-RULES §6.4).
    private(set) var settingsRequests = 0

    func requestSettings() { settingsRequests += 1 }

    /// Preparing, running or publishing.
    var activeJobCount: Int { jobCenter.activeJobCount }

    // MARK: Updates

    var checksForUpdates: Bool = CCwikiSettings.checksForUpdates {
        didSet { CCwikiSettings.checksForUpdates = checksForUpdates }
    }
    var installsUpdatesAutomatically: Bool = CCwikiSettings.installsUpdatesAutomatically {
        didSet { CCwikiSettings.installsUpdatesAutomatically = installsUpdatesAutomatically }
    }
    private(set) var availableUpdate: ReleaseInfo?
    /// Downloaded, verified and swapped into place; waiting for a relaunch.
    private(set) var installedUpdate: ReleaseInfo?
    private(set) var lastUpdateCheck: Date? = CCwikiSettings.lastUpdateCheck
    private(set) var isCheckingForUpdates = false
    private(set) var isInstallingUpdate = false
    /// What the installer is doing right now, for the status bar.
    private(set) var updateInstallProgress: String?
    /// Whether this build may replace itself: only the release, and only
    /// when it can verify a download at all. See `BuildIdentity`, `ReleaseKey`.
    var canInstallUpdates: Bool { BuildIdentity.isRelease && ReleaseKey.isConfigured }
    nonisolated static let updateInterval: TimeInterval = 24 * 60 * 60
    /// "X is available": replaced on every check.
    static let updateWarningPrefix = "Update: "
    /// "X is installed, relaunch": survives checks; cleared by the relaunch.
    static let updateInstalledPrefix = "Update installed: "

    var appVersion: String { Bundle.main.shortVersion }

    // MARK: Reader

    /// The render pipeline every web view serves: a per-build copy in
    /// Caches, staged once at launch, not the bundle's `paths.webRoot`. The
    /// updater swaps the bundle under the running app, and a WebContent
    /// restart after that must not load the new release's JavaScript
    /// against this release's Swift.
    ///
    /// Read as each web view is made, so the copy is checked first
    /// (`checkWebRoot`): one cleared from Caches since launch would leave
    /// the new view blank.
    var webRoot: URL {
        checkWebRoot()
        return stagedWebCopy
    }
    /// What `paths.stagedWebRoot()` gave at launch. Staging it again gives
    /// the same path.
    private let stagedWebCopy: URL
    /// Said when the staged copy is gone and only a relaunch can bring it
    /// back.
    static let webRootWarning = "CCwiki's page renderer was removed from Caches while it was "
        + "open. Relaunch CCwiki to read pages in new tabs and windows."
    /// The papers behind reference pages, fetched when asked (§2).
    let papers: PaperLibrary

    // MARK: Diagnostics

    /// Things the user should know but that must not stop them reading:
    /// a failed pull, a macro table that would not parse, missing tooling.
    private(set) var warnings: [String] = []

    /// Append once. A warning that repeats on every sync is noise, and a
    /// duplicate could not be dismissed on its own.
    func warn(_ message: String) {
        guard !warnings.contains(message) else { return }
        warnings.append(message)
    }

    func dismissWarning(_ message: String) {
        warnings.removeAll { $0 == message }
    }

    func dismissAllWarnings() {
        warnings.removeAll()
    }

    /// Marks the macro warning so a reload replaces it. On a fresh install it
    /// is raised before the clone exists and has to go away once it does.
    static let macrosWarningPrefix = "Custom LaTeX macros unavailable — "
    /// Same for the leftover-worktree count, which changes as they are pruned.
    static let orphansWarningPrefix = "Leftover worktrees: "
    /// And for the missing-tool warning, which discovery re-derives.
    static let toolsWarningPrefix = "Tools: "

    // MARK: Init

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.searchIndex = SearchIndex(path: paths.searchDatabase)
        // On a fresh install this is empty: the clone does not exist yet. The
        // table travels with every render request, so the web view picks up
        // the real one as soon as the clone lands.
        let macros = MacroTable.load(cloneRoot: paths.clone)
        self.macros = macros
        self.stagedWebCopy = paths.stagedWebRoot()
        self.storedPageZoom = AppModel.clampedZoom(CCwikiSettings.pageZoom)
        self.papers = PaperLibrary(paths: paths)
        let publishTarget = PublishTarget.resolve(
            channel: BuildIdentity.current, environment: ProcessInfo.processInfo.environment)
        self.publishTarget = publishTarget
        // Made with the model, so the job history is loaded before SwiftUI
        // restores a window: a restored editor or review finds its job
        // (corrections §4.3). Until the end of `init` the job center cannot
        // read the model, and nothing asks it to; it is given the model's
        // environment below.
        self.jobCenter = JobCenter(paths: paths) {
            JobCenter.Environment(
                tools: ToolLocator(), git: nil, index: nil, relations: .empty,
                labels: .empty, appVersion: Bundle.main.shortVersion, correctionModel: "",
                target: publishTarget, privatePaths: [])
        }

        try? paths.createDirectories()
        // Tools are looked for in `discoverTools()`, after the first frame:
        // the login-shell fallback costs up to three seconds per tool that is
        // not installed, and `init` runs on the main thread before any window.
        toolOverrides = CCwikiSettings.toolOverrides()
        tools = ToolLocator(overrides: toolOverrides)
        vendorManifest = try? String(
            contentsOf: paths.webRoot.appending(path: "vendor/VENDOR.txt"), encoding: .utf8)

        refreshMacrosWarning()

        // The job center reads the model, and calls back into it, through
        // these. Unowned: the model owns the job center and outlives it.
        jobCenter.environment = { [unowned self] in self.jobEnvironment }
        jobCenter.flushEdits = { [unowned self] job in await self.flushEdits(for: job) }
        jobCenter.unsettledEdits = { [unowned self] job in
            JobReview.unsettledEditor(of: job, in: self).map { JobReview.unsettledReason(path: $0) }
        }
        jobCenter.onFilesChanged = { [unowned self] job, changed in
            self.filesChanged(in: job, paths: changed)
        }
        jobCenter.onOrphanedWorktreesChanged = { [unowned self] worktrees in
            self.orphanedWorktreesChanged(worktrees)
        }

        // A Dev build pointed at a fork with a value that is not owner/name
        // goes on targeting the wiki, and says so (corrections §10). The
        // value's shape decides, by the test `resolve` makes, not
        // `isOverridden` alone: a valid value naming the wiki itself is
        // neither honoured nor wrong.
        if publishTarget.isDevBuild, !publishTarget.isOverridden,
           let requested = ProcessInfo.processInfo.environment["CCWIKI_TARGET_REPO"],
           !requested.isEmpty, !PublishTarget.isRepositorySlug(requested) {
            warn("CCWIKI_TARGET_REPO is ignored: “\(requested)” is not owner/name. "
                + "Pull requests and issues go to \(publishTarget.repository).")
        }

        // Coming back to CCwiki, from Terminal or Apple's installer, is when
        // a tool someone was sent to install turns up (`appDidBecomeActive`).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidBecomeActive() }
        }
    }

    /// What the job center reads at each call: the tools, git, the wiki and
    /// the settings as they are now (SWIFTUI-RULES §3.5).
    private var jobEnvironment: JobCenter.Environment {
        JobCenter.Environment(
            tools: tools, git: gitService, index: index, relations: relations,
            labels: relationLabels, appVersion: appVersion, correctionModel: correctionModel,
            target: publishTarget, privatePaths: privatePaths)
    }

    /// The local paths that must never reach a pull request or an issue
    /// (`PrivateText`, corrections §6.4): the home folder, and the roots of
    /// the worktrees, the library and Application Support.
    private var privatePaths: [String] {
        [paths.worktrees, paths.library, paths.support].map { $0.path(percentEncoded: false) }
            + [NSHomeDirectory()]
    }

    // MARK: Launch

    /// The launch, which runs once per process however many windows ask.
    @ObservationIgnored private var launchTask: Task<Void, Never>?

    /// Find git (one stat), read what is already on disk, and only then
    /// touch the network, so the app is usable at once and offline. The
    /// ingestion tools are looked for in the background.
    ///
    /// Every reader window calls it when it starts, and so does a paper
    /// window, so a window macOS restores alone still loads the wiki. The
    /// first caller runs the launch; later callers wait for the same run
    /// (plans/reader-comforts.md §1.7).
    func launchIfNeeded() async {
        if let launchTask {
            await launchTask.value
            return
        }
        let task = Task { await launch() }
        launchTask = task
        await task.value
    }

    private func launch() async {
        await discoverTools()
        // The job history is not a step: `JobCenter.init` loaded it with the
        // model, before any window (corrections §4.3).
        await loadLibrary(reason: .launch)
        // Which copy this is goes to the log on every launch; the other
        // copies are looked for in a release, and not under the harness.
        // Before the sync: a copy that hands over to another and quits must
        // not leave a fetch running on the clone the two share
        // (update-integrity §2.3).
        await checkInstallation()
        // A launch fetch keeps the wiki current for someone who never
        // presses ⌘R. Not under the screenshot harness, whose captures must
        // not depend on the network.
        let launchFetch = syncsAtLaunch && ScreenshotRunner.directory == nil
        if index == nil || launchFetch { sync() }
        if ScreenshotRunner.directory == nil { await checkForUpdatesIfDue() }
        startHourlyChores()
    }

    /// The hourly chores, from the end of the launch until the app quits.
    @ObservationIgnored private var hourlyChores: Task<Void, Never>?
    nonisolated static let choresInterval: Duration = .seconds(60 * 60)

    /// What a copy left open for days, across sleeps, still owes: the daily
    /// update check, which the launch alone would make once per launch
    /// rather than once a day, and a mark on the staged web copy, which
    /// another build prunes after a week without one (`checkWebRoot`).
    /// Cheap each hour: `checkForUpdatesIfDue` asks GitHub only once a day
    /// has passed since its last answer, so a launch that was offline is
    /// retried within the hour, and a check turned back on in Settings runs
    /// within the hour too.
    private func startHourlyChores() {
        guard hourlyChores == nil else { return }
        hourlyChores = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.choresInterval)
                guard let self else { return }
                checkWebRoot()
                if ScreenshotRunner.directory == nil { await checkForUpdatesIfDue() }
            }
        }
    }

    /// Keeps the staged web copy fit to serve (`AppPaths.keepStagedWebRoot`):
    /// marked in use, or staged again if Caches lost it. When it is gone
    /// and the bundle is no longer this build, only a relaunch helps, and
    /// the status bar says so. Before each web view is made, on coming back
    /// to the app, and hourly.
    func checkWebRoot() {
        guard !paths.keepStagedWebRoot(stagedWebCopy, bundleBuild: AppPaths.bundleBuildOnDisk)
        else { return }
        // Not inside the update that may be making a web view.
        Task { @MainActor [weak self] in self?.warn(AppModel.webRootWarning) }
    }

    /// Whether a session has taken the cold start since the process began,
    /// or since the last reader window closed (`sessionDidClose`).
    @ObservationIgnored private var hasColdStarted = false

    /// True for the first session of the process, and for the first after
    /// every reader window has closed: those open the page read last, and
    /// every other window opens Home (§1.7).
    func takeColdStart() -> Bool {
        defer { hasColdStarted = true }
        return !hasColdStarted
    }

    // MARK: Tools

    /// Find `git`, then everything else.
    ///
    /// Two phases because they cost differently. `git` is one `stat` in the
    /// common case and is all the reader needs, so the caller can `await` it
    /// and go on to load the library. The ingestion tools may each fall
    /// through to a login shell; they are found in the background and nothing
    /// the reader does waits on them.
    func discoverTools() async {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        isDiscoveringTools = true
        // Until this discovery's own ask has answered (`askGitHub`).
        isCheckingGitHub = true
        let overrides = toolOverrides

        let reading = await Task.detached(priority: .userInitiated) { () -> (ToolLocator, Bool) in
            var located = ToolLocator(overrides: overrides)
            located.locate([.git])
            let stub = located.path(for: .git).map(ToolLocator.isAppleStub) ?? false
            let needsTools = stub && !ToolLocator.developerToolsInstalled()
            if needsTools { located.forget(.git) }
            return (located, needsTools)
        }.value
        guard generation == discoveryGeneration else { return }
        tools = reading.0
        needsDeveloperTools = reading.1
        refreshToolWarnings()
        // A review a restored window showed before git was found has no
        // snapshot yet. In the background: the library loads meanwhile.
        Task { await jobCenter.refreshMissingReviews() }

        Task { await discoverIngestionTools(generation: generation, from: reading.0) }
    }

    private func discoverIngestionTools(generation: Int, from base: ToolLocator) async {
        let all = await Task.detached(priority: .utility) { () -> ToolLocator in
            var located = base
            located.locate([.gh, .claude, .node])
            return located
        }.value
        guard generation == discoveryGeneration else { return }
        tools = all
        isDiscoveringTools = false
        // GitHub, if it was asked before gh was found, and any review still
        // without a snapshot, asked again now (corrections §7.1).
        Task { await jobCenter.toolsDidChange() }
        await askGitHub(generation: generation)
    }

    /// Ask whether gh is signed in, then whether the clone can push, with
    /// `isCheckingGitHub` set until both are known: a signed-in user is not
    /// told "not signed in" while gh answers, for up to its deadline. An
    /// answer a later ask or discovery has overtaken is dropped; that one
    /// answers instead.
    private func askGitHub(generation: Int) async {
        gitHubAsk += 1
        let ask = gitHubAsk
        isCheckingGitHub = true
        let answer = await GitHubAuth.isAuthenticated(tools: tools)
        guard generation == discoveryGeneration, ask == gitHubAsk else { return }
        isGitHubAuthenticated = answer == true
        isGitHubUnreachable = answer == nil && tools.path(for: .gh) != nil
        await refreshPushCapability()
        guard generation == discoveryGeneration, ask == gitHubAsk else { return }
        isCheckingGitHub = false
    }

    /// Ask gh again when it gave no answer: a launch offline, or one with
    /// no answer before the deadline, leaves `isGitHubUnreachable` set with
    /// nothing cached (`GitHubAuth.isAuthenticated`). On coming back to the
    /// app and when the ingest sheet opens, so a network that has returned
    /// is noticed without Settings ▸ Re-check. A "no" that was an answer is
    /// kept, and costs nothing: after `gh auth login`, Re-check, as the
    /// advice says. An answer a correction's ask has cached since is taken:
    /// a "yes", or a "no" in place of offline.
    func refreshGitHubIfUnanswered() {
        guard !isDiscoveringTools, !isCheckingGitHub, !isGitHubAuthenticated,
              tools.path(for: .gh) != nil,
              isGitHubUnreachable || GitHubAuth.cachedAnswer != false
        else { return }
        let generation = discoveryGeneration
        Task { await askGitHub(generation: generation) }
    }

    /// Nothing to warn about any more: reading works without git (the wiki
    /// arrives as a snapshot), and the ingest sheet lists what a job needs.
    private func refreshToolWarnings() {
        warnings.removeAll { $0.hasPrefix(Self.toolsWarningPrefix) }
    }

    /// Ask macOS to install the Command Line Tools. `xcode-select --install`
    /// only opens the system's own installer dialog and returns; the download
    /// and the licence are the OS's, not ours.
    func installDeveloperTools() {
        Task.detached(priority: .userInitiated) {
            _ = await Subprocess.run(
                executable: "/usr/bin/xcode-select", arguments: ["--install"],
                environment: ProcessInfo.processInfo.environment)
        }
    }

    /// Something a job needs was not there at the last look.
    private var isMissingTools: Bool {
        needsDeveloperTools || !tools.missingForIngestion.isEmpty
    }

    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// CCwiki is the active app again. A tool missing at the last look may
    /// have been installed meanwhile: the blockers send the person to
    /// Terminal or to Apple's installer, and coming back, not a relaunch,
    /// should be what makes it count. Only the cheap stages are asked here,
    /// a `stat` per directory (`toolArrived`) and `xcode-select -p`, never a
    /// login shell. When something has turned up, every tool is looked for
    /// again, which asks GitHub and the clone afresh too. The staged web
    /// copy is checked as well, in case Caches was cleared meanwhile, and
    /// gh is asked again if its last "no" was not an answer.
    private func appDidBecomeActive() {
        checkWebRoot()
        guard !isDiscoveringTools else { return }
        refreshGitHubIfUnanswered()
        guard isMissingTools else { return }
        let missing = tools.missingForIngestion
        let stubbedGit = needsDeveloperTools
        Task {
            let arrived = await Task.detached(priority: .utility) { () -> Bool in
                if stubbedGit, ToolLocator.developerToolsInstalled() { return true }
                let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .components(separatedBy: ":").filter { !$0.isEmpty }
                return AppModel.toolArrived(
                    missing, stubbedGit: stubbedGit,
                    in: inherited + ToolLocator.commonDirectories)
            }.value
            guard arrived, !isDiscoveringTools else { return }
            GitHubAuth.invalidate()
            await discoverTools()
        }
    }

    /// Whether one of `missing` is in `directories` now, as the first two
    /// stages of `ToolLocator.locate` would find it: the first executable
    /// in the order given. While git is only Apple's stub (`stubbedGit`),
    /// finding that stub first again is no news; the Command Line Tools
    /// arriving behind it is, and the caller asks `xcode-select` for that.
    nonisolated static func toolArrived(
        _ missing: [ToolLocator.Tool], stubbedGit: Bool, in directories: [String]
    ) -> Bool {
        missing.contains { tool in
            let found = directories.lazy
                .map { $0 + "/" + tool.rawValue }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let found else { return false }
            return !(tool == .git && stubbedGit && ToolLocator.isAppleStub(found))
        }
    }

    /// Why a job could not start right now, in the order the sheet shows them.
    /// Empty means the pre-flight checks that concern tooling would pass.
    var ingestionBlockers: [String] {
        Self.ingestionBlockers(
            store: index == nil ? nil : paths.wikiStore,
            missing: tools.missingForIngestion, needsDeveloperTools: needsDeveloperTools,
            ghPresent: tools.path(for: .gh) != nil,
            isGitHubAuthenticated: isGitHubAuthenticated, canPushToRemote: canPushToRemote,
            isGitHubUnreachable: isGitHubUnreachable)
    }

    /// The blocker while GitHub could not be asked, in the words of the
    /// editor's offline banner (plans/corrections.md §7.1). The sheet shows
    /// it without the warning triangle: offline is not a fault.
    nonisolated static let gitHubUnreachableBlocker =
        "Offline. A job needs a connection to GitHub; CCwiki asks again when you come back to it."

    /// `ingestionBlockers`, pure. `store` is nil while no wiki is loaded.
    ///
    /// A snapshot blocks a job as it blocks a correction (`CorrectionBlockers`):
    /// the job's worktree is made from the clone's git, which a snapshot has
    /// not got. The push blocker is about a clone, so a snapshot leaves it
    /// to that one. A GitHub that could not be asked is offline, never
    /// "not signed in": `gh auth login` cannot bring a network back.
    nonisolated static func ingestionBlockers(
        store: AppPaths.WikiStore?, missing: [ToolLocator.Tool], needsDeveloperTools: Bool,
        ghPresent: Bool, isGitHubAuthenticated: Bool, canPushToRemote: Bool,
        isGitHubUnreachable: Bool = false
    ) -> [String] {
        var blockers: [String] = []
        if store == nil {
            blockers.append(CorrectionJobRunner.notCloned)
        }
        if needsDeveloperTools {
            blockers.append("git needs Apple's Command Line Tools (reading does not; "
                + "jobs do). Settings > Jobs has the installer.")
        }
        for tool in missing where !(tool == .git && needsDeveloperTools) {
            blockers.append("\(tool.rawValue) was not found. It is needed for \(tool.purpose).")
        }
        if store == .snapshot {
            blockers.append(CorrectionBlockers.snapshot)
        }
        if ghPresent, isGitHubUnreachable {
            blockers.append(Self.gitHubUnreachableBlocker)
        } else if ghPresent, !isGitHubAuthenticated {
            blockers.append("The GitHub CLI is not signed in. Run `gh auth login` in Terminal.")
        }
        if ghPresent, isGitHubAuthenticated, !canPushToRemote, store != .snapshot {
            blockers.append("CCwiki's clone cannot authenticate a push. Sync again (⌘R) to configure it.")
        }
        return blockers
    }

    /// Replace the macro warning with whatever is true now.
    private func refreshMacrosWarning() {
        warnings.removeAll { $0.hasPrefix(Self.macrosWarningPrefix) }
        if macros.isEmpty, let diagnostic = macros.diagnostic {
            warn(Self.macrosWarningPrefix + diagnostic.message
                + " Math will render, but site-specific commands will show as errors.")
        }
    }

    // MARK: Loading

    /// The library on screen, kept for the next load to build on. Not
    /// observed: views read the parts `apply` hands out, never this.
    @ObservationIgnored private var loaded: LoadedLibrary?
    /// The commit `loaded` was read at, when nothing moved it during the
    /// read; nil when it may have, so the next sync reloads.
    @ObservationIgnored private var loadedRevision: String?
    /// The load running now, which the next one waits for.
    @ObservationIgnored private var loadTask: Task<LibraryUpdate?, Never>?

    /// Read the clone and bring everything built from it up to date: the
    /// parsed wiki and the dates, then the page on screen while the search
    /// index is written (plans/reader-comforts.md §3.2). Returns once the
    /// index is written.
    ///
    /// Serialized: a load waits for the one before it, so ⌘R during the
    /// launch load cannot finish first and be overwritten by the older one.
    /// Nil when there is no wiki to read yet.
    @discardableResult
    func loadLibrary(reason: LibraryLoadReason) async -> LibraryUpdate? {
        await loadLibrary(reason: reason, after: nil)
    }

    /// `loadLibrary(reason:)` for a sync, whose outcome says which commit it
    /// left the clone at.
    @discardableResult
    private func loadLibrary(
        reason: LibraryLoadReason, after outcome: GitService.SyncOutcome?
    ) async -> LibraryUpdate? {
        let previous = loadTask
        let task = Task { () async -> LibraryUpdate? in
            _ = await previous?.value
            return await performLoad(reason: reason, after: outcome)
        }
        loadTask = task
        let update = await task.value
        if loadTask == task { loadTask = nil }
        return update
    }

    private func performLoad(
        reason: LibraryLoadReason, after outcome: GitService.SyncOutcome?
    ) async -> LibraryUpdate? {
        guard FileManager.default.fileExists(
            atPath: paths.content.path(percentEncoded: false)) else { return nil }

        // Rebuild reads every page again and writes the search index from
        // nothing, whatever the last load left.
        if reason == .rebuild {
            loaded = nil
            await searchIndex.reset()
        }

        let cloneRoot = paths.clone
        let git = gitService
        let revisionBefore = await LibraryRefresh.currentRevision(
            store: paths.wikiStore, git: git, clone: cloneRoot)
        let previous = loaded
        // The pages are read while git answers for the commit: neither needs
        // the other.
        let reading = Task.detached(priority: .userInitiated) { () -> LibraryUpdate in
            guard let previous else {
                return LibraryUpdate(building: LoadedLibrary.build(cloneRoot: cloneRoot))
            }
            return LoadedLibrary.update(previous, cloneRoot: cloneRoot)
        }

        // Git answers for a clone and the marker for a snapshot. When neither
        // can (a clone whose git has gone, or content with no marker), the
        // commit and dates already shown stay, as they always have.
        let store = paths.wikiStore
        let facts = await LibraryRefresh.revisionFacts(
            store: store, git: git, paths: paths, after: outcome)
        let update = await reading.value

        // The library and its commit in one main-actor step, with no await
        // between them: a page rendered in between would pair the new
        // markdown with the old revision, and a correction made from it
        // would read the wrong lines (corrections §3.5).
        apply(update.library)
        if (git != nil && store == .git) || store == .snapshot {
            modifiedDates = facts.modifiedDates
            headRevision = facts.head
            headDate = facts.date
        }

        // The search index is written while git is asked whether the commit
        // moved meanwhile. The page on screen renders once git has answered,
        // with everything the load knows settled, but not after the index:
        // nothing a render reads is in it. Until plans/efficiency.md's U1 it
        // waited for both (reader-comforts §3.2).
        async let searched = syncSearchIndex(with: update.library)
        let revisionAfter = await LibraryRefresh.currentRevision(
            store: paths.wikiStore, git: git, clone: cloneRoot)
        loadedRevision = revisionBefore == revisionAfter ? revisionAfter : nil

        sessionsDidLoad(update)
        _ = await searched
        searchDidSync()

        if LibraryRefresh.runsJobHousekeeping(reason) {
            await refreshJobHousekeeping()
        }
        return update
    }

    /// Put a new library on screen in one main-actor step, so no view sees
    /// a manifest and closures from different commits (SWIFTUI-RULES §3.1:
    /// rebuilt from source, never patched).
    private func apply(_ library: LoadedLibrary) {
        loaded = library
        index = library.index
        backlinks = library.backlinks
        relations = library.manifest
        relationLabels = library.labels
        derivation = library.derivation
        linkPreviews = library.linkPreviews
        textGrep = library.textGrep
        libraryGeneration += 1
        unlistedPaths = library.manifest.unlistedPaths
        rebuildBrowseState()
        macros = MacroTable.load(cloneRoot: paths.clone)
        refreshMacrosWarning()

        // Replaced rather than appended: a load follows every pull, and a
        // warning that stacks up once per sync is noise.
        warnings.removeAll { $0.hasPrefix(Self.relationsWarningPrefix) }
        if let diagnostic = relations.diagnostic {
            warn(Self.relationsWarningPrefix + diagnostic.message)
        }
    }

    /// What the search index is stamped with: the build that wrote its rows,
    /// so a build that writes them differently rewrites them all (§3.4).
    private static var searchIndexBuilder: String {
        "\(Bundle.main.buildNumber) schema \(SearchIndex.schemaVersion)"
    }

    /// Write `library` to the search index, and say so when it cannot.
    private func syncSearchIndex(with library: LoadedLibrary) async -> SyncReport? {
        do {
            return try await searchIndex.sync(
                pages: library.index.allPages, backlinks: library.backlinks,
                fingerprints: library.fingerprints, builder: Self.searchIndexBuilder)
        } catch {
            warn("Search index could not be updated: \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-register moved worktrees and look for strays. A crash or
    /// force-quit mid-job leaves a worktree behind, and `git worktree add`
    /// will refuse to reuse the path. Finding them here is cheaper than
    /// making the user learn `git worktree prune`.
    private func refreshJobHousekeeping() async {
        if let git = gitService {
            await git.repairWorktrees(clone: paths.clone, worktreeRoot: paths.worktrees)
        }
        await refreshOrphanedWorktrees()
    }

    /// What a load means for the readers, as soon as the library and its
    /// revision are in place: each window's session decides what to render
    /// again (`ReaderSession.libraryDidLoad`), and a quick switcher that is
    /// up follows the new wiki. One that is not is left alone: opening it
    /// works its list out anyway (`resetQuickSwitcher`). ⇧⌘F's open query
    /// runs again too: it reads the pages `apply` just replaced, not the
    /// search index.
    private func sessionsDidLoad(_ update: LibraryUpdate) {
        for session in sessions.values { session.libraryDidLoad(update) }
        if sessions.values.contains(where: { $0.quickSwitcherPresented }) {
            refreshQuickSwitcher()
        }
        scheduleGrep()
    }

    /// The search index now holds the load: the open queries of ⌘S and ⇧⌘R
    /// run again. One typed during the launch load was answered by an index
    /// with nothing in it yet, and one answered before a pull lists the
    /// pages as they were.
    private func searchDidSync() {
        scheduleSearch()
        scheduleReferenceSearch()
    }

    var gitService: GitService? {
        guard let git = tools.path(for: .git) else { return nil }
        return GitService(executable: git, environment: tools.childEnvironment())
    }

    // MARK: Sync

    /// Fast-forward the clone, then reload. Single-flight: pressing ⌘R twice
    /// does not start two clones.
    func sync() {
        sync(afterReset: false)
    }

    /// `afterReset`: the clone was just deleted by Reset Clone, so what this
    /// sync downloads replaces it rather than arriving for the first time.
    private func sync(afterReset: Bool) {
        guard syncTask == nil else { return }
        let store = paths.wikiStore
        let git = gitService

        // With git: clone or fast-forward; a snapshot left by a git-less
        // launch is replaced by a real clone (the clone lands beside it and
        // is moved in only on success). Without git: a tarball snapshot,
        // which is all the reader needs. A clone with no git to update it is
        // the one dead end, and it says so.
        if git == nil, store == .git {
            syncState = .failed("This wiki copy is a git clone, and git is no longer available "
                + "to update it. Reset Clone in Settings > Storage downloads a snapshot instead.")
            return
        }

        syncLog = []
        syncState = .running(
            store == .none ? (git != nil ? "Cloning the wiki…" : "Downloading the wiki…")
                : (git != nil ? "Fetching…" : "Checking for a newer snapshot…"))

        syncTask = Task { [weak self] in
            guard let self else { return }
            let onLine: @Sendable (ProcessLine) -> Void = { line in
                Task { @MainActor [weak self] in self?.appendSyncLine(line) }
            }
            let outcome: GitService.SyncOutcome
            if let git {
                outcome = await git.sync(clone: paths.clone, remote: AppPaths.remoteURL, onLine: onLine)
            } else {
                let snapshots = SnapshotService(
                    repository: AppPaths.repositorySlug, branch: AppPaths.defaultBranch)
                outcome = await snapshots.sync(destination: paths.clone, onLine: onLine)
            }
            let reloads = LibraryRefresh.needsReload(
                after: outcome, loadedRevision: loadedRevision, isLoaded: loaded != nil)
            switch outcome {
            case .offline:
                // Reading is unaffected — the whole point of a local clone —
                // so this is a note, not an alarm. Still reload when asked
                // to, in case this is the first launch after a manual pull.
                if reloads { await loadLibrary(reason: .offline, after: outcome) }
                await refreshPushCapability()
                syncState = .failed(outcome.summary)
            case .failed(let message):
                syncState = .failed(message)
                warn(message)
            default:
                var update: LibraryUpdate?
                if reloads {
                    syncState = .running("Indexing…")
                    update = await loadLibrary(
                        reason: Self.loadReason(after: outcome, afterReset: afterReset),
                        after: outcome)
                }
                // After every outcome that reached the clone, reloading or
                // not: the ingest sheet's push blocker says "Sync again (⌘R)
                // to configure it", and that has to stay true.
                await refreshPushCapability()
                let summary = await LibraryRefresh.summary(
                    after: outcome, changes: update?.changes,
                    store: paths.wikiStore, git: git, clone: paths.clone)
                syncState = .succeeded(summary)
                warnings.removeAll { $0.contains("Fast-forward failed") }
                scheduleStatusReset()
            }
            syncTask = nil
        }
    }

    /// What a sync's outcome makes of the load after it. A failure loads
    /// nothing, so its answer is never used.
    private static func loadReason(
        after outcome: GitService.SyncOutcome, afterReset: Bool
    ) -> LibraryLoadReason {
        switch outcome {
        case .cloned: afterReset ? .reset : .cloned
        case .offline: .offline
        case .updated, .alreadyCurrent, .failed: .pulled
        }
    }

    /// "Already up to date" has been read after a few seconds; the resting
    /// state — the wiki as of when — is the more useful thing to leave up.
    private func scheduleStatusReset() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, case .succeeded = self.syncState else { return }
            self.syncState = .idle
        }
    }

    /// Delete the clone and fetch it again. The clone is the app's own
    /// artifact and CCwiki never writes into it, so nothing of the user's
    /// is lost; the loaded index stays on screen until the new clone lands.
    func resetClone() {
        // A job's worktree keeps its metadata inside the clone's `.git`, so
        // deleting the clone under a job that is not finished — running, or
        // waiting for review — breaks every git step it has left
        // (corrections §4.3). Settings disables the button; this is the
        // backstop.
        guard syncTask == nil, unfinishedJobCount == 0 else { return }
        try? FileManager.default.removeItem(at: paths.clone)
        headRevision = nil
        headDate = nil
        sync(afterReset: true)
    }

    private func appendSyncLine(_ line: ProcessLine) {
        if line.isProgress, !syncLog.isEmpty, syncLog[syncLog.count - 1].hasSuffix("%") {
            syncLog[syncLog.count - 1] = line.text
        } else {
            syncLog.append(line.text)
        }
        if syncLog.count > 400 { syncLog.removeFirst(200) }
        if case .running = syncState, !line.text.isEmpty {
            syncState = .running(line.text)
        }
    }

    // MARK: The app's own pages

    /// The release notes shipped in this build.
    @ObservationIgnored private(set) lazy var changelog =
        Changelog.parse(paths.bundledDocument("CHANGELOG.md") ?? "")
    /// Which releases What's New lists: those after this version, or all of
    /// them when nil (from the Help menu, through `ReaderSession.showWhatsNew`).
    @ObservationIgnored var whatsNewSince: String?

    /// What to open before anything else this launch, if anything. Pure, so
    /// it can be tested: a first launch shows Welcome; the first launch of
    /// a newer version shows what changed since the last one, when the
    /// changelog has anything to say about it.
    nonisolated static func launchDocument(
        lastSeen: String?, current: String, changelog: Changelog
    ) -> (document: Document, since: String?)? {
        guard let lastSeen else { return (.welcome, nil) }
        guard !UpdateChecker.isDevelopmentVersion(current),
              UpdateChecker.isNewer(current, than: lastSeen),
              !changelog.entries(after: lastSeen, upTo: current).isEmpty
        else { return nil }
        return (.whatsNew, lastSeen)
    }

    @ObservationIgnored private var hasTakenLaunchDocument = false

    /// Welcome or What's New, once per process: the first reader window to
    /// start shows it at once, before the library loads, so Welcome can be
    /// read while the wiki downloads (§1.7). Records this version as seen,
    /// unless a newer one already was. Nil for every later window, and under
    /// the screenshot harness.
    func takeLaunchDocument() -> Document? {
        guard !hasTakenLaunchDocument else { return nil }
        hasTakenLaunchDocument = true
        guard ScreenshotRunner.directory == nil else { return nil }
        let current = appVersion
        // Two records, because a copy from before this check still writes
        // its own version to `lastSeenVersion` when it runs, however old.
        let lastSeen = InstallationCheck.seenVersion(
            recorded: CCwikiSettings.lastSeenVersion,
            highest: CCwikiSettings.highestSeenVersion)
        let decision = Self.launchDocument(lastSeen: lastSeen, current: current, changelog: changelog)
        // Forward only: an older copy opened by mistake must not bring What's
        // New back at the next launch of this one.
        let seen = InstallationCheck.nextSeenVersion(lastSeen: lastSeen, current: current)
        CCwikiSettings.lastSeenVersion = seen
        if !UpdateChecker.isDevelopmentVersion(seen) { CCwikiSettings.highestSeenVersion = seen }
        guard let decision else { return nil }
        if decision.document == .whatsNew { whatsNewSince = decision.since }
        return decision.document
    }

    /// One of the app's own pages, ready to render in any reader.
    func documentRequest(_ document: Document) -> RenderRequest {
        let markdown: String
        switch document {
        case .welcome:
            markdown = paths.bundledDocument("welcome.md") ?? "# Welcome to CCwiki\n"
        case .whatsNew:
            let entries = changelog.entries(after: whatsNewSince, upTo: appVersion)
            markdown = Changelog.whatsNewMarkdown(
                entries.isEmpty ? changelog.entries : entries, since: whatsNewSince)
        }

        // A synthetic page, so the markdown goes through the reader's own
        // pipeline and its wikilinks resolve like any page's. The path is
        // one no wiki page can have.
        let page = WikiPage(path: "ccwiki:/\(document.rawValue).md", text: markdown)
        var notices: [RenderRequest.Notice] = []
        guard let index else {
            if document == .welcome {
                notices.append(RenderRequest.Notice(
                    level: "info",
                    text: "The wiki is downloading. The links on this page come alive as soon "
                        + "as it lands."))
            }
            return RenderRequest(
                path: page.path, title: document.title, markdown: page.body, html: nil,
                links: [:], anchor: nil, notices: notices)
        }
        var renderer = PageRenderer(index: index, hiddenPaths: unlistedPaths)
        renderer.reportsBrokenLinks = false
        renderer.linkPreviews = linkPreviews
        renderer.buildsPreviews = showsLinkPreviews
        return renderer.request(for: page, anchor: nil, notices: notices)
    }

    // MARK: Search hits

    /// What to look for on the page, best first: the query as typed, then
    /// its words longest first. Full-text search matches words anywhere on
    /// the page, so the phrase itself may not occur.
    nonisolated static func findCandidates(for query: String) -> [String] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        let words = phrase.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
        var seen: Set<String> = []
        return ([phrase] + words).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Text size

    /// The reader's text size, as `WKWebView.pageZoom`, where 1 is the CSS
    /// size. One preference, not a property of a page, so every reader's web
    /// view follows it (plans/reader-comforts.md Decision 7). Persisted, and
    /// kept inside `WebController.zoomRange` however it is set.
    var pageZoom: Double {
        get { storedPageZoom }
        set {
            let zoom = AppModel.clampedZoom(newValue)
            guard zoom != storedPageZoom else { return }
            storedPageZoom = zoom
            CCwikiSettings.pageZoom = zoom
            for session in sessions.values { session.webController.setPageZoom(zoom) }
        }
    }

    /// What `pageZoom` reads, stored and observed, so the menus follow it.
    private var storedPageZoom: Double = 1

    private static func clampedZoom(_ zoom: Double) -> Double {
        min(max(zoom, WebController.zoomRange.lowerBound), WebController.zoomRange.upperBound)
    }

    func makeTextBigger() {
        pageZoom *= WebController.zoomStep
    }

    func makeTextSmaller() {
        pageZoom /= WebController.zoomStep
    }

    func resetTextSize() {
        pageZoom = 1
    }

    // MARK: The published site

    /// The same page on cryptology.city, for "Open on the website" and
    /// "Copy Link". A Quartz page's URL is its simplified slug.
    nonisolated static func siteURL(slug: String, anchor: String? = nil) -> URL? {
        let simple = QuartzSlug.simplifySlug(slug)
        let path = simple == "/" ? "" : simple
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: AppPaths.siteURL + "/" + encoded)
        else { return nil }
        components.fragment = anchor
        return components.url
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Derived sections

    func isDerivedSectionExpanded(_ role: PageDerivations.Role) -> Bool {
        derivedSectionsExpanded.contains(role.rawValue)
    }

    func toggleDerivedSection(_ role: PageDerivations.Role) {
        if derivedSectionsExpanded.contains(role.rawValue) {
            derivedSectionsExpanded.remove(role.rawValue)
        } else {
            derivedSectionsExpanded.insert(role.rawValue)
        }
    }

    // MARK: Relations explorer

    /// Every way into the explorer ends here: the menu commands, the reader's
    /// context menu, the inspector's rows and the explorer's own. The current
    /// question goes onto Recent when the new one differs, the new one is
    /// set with its toggle as given, and a reader window is asked to open
    /// the explorer, which is the one path that works from AppKit as well as
    /// from SwiftUI.
    func explore(_ query: ExplorerQuery) {
        if !query.isSameQuestion(as: explorerQuery) {
            rememberExplorerQuery()
        }
        explorerQuery = query
        explorerWindowRequests += 1
    }

    /// `explore(_:)` with the explorer's own models toggle, so a click from
    /// the inspector or a context menu never turns it on or off. Under R4's
    /// phases a fact derivable in the default models keeps its default proof
    /// either way.
    func explore(from: [String], to: String? = nil) {
        explore(ExplorerQuery(from: from, to: to,
                              includesIdealisedModels: explorerQuery.includesIdealisedModels))
    }

    /// A question the explorer can ask about these objects, or `nil` when it
    /// would only be turned away: a complexity class is related by
    /// containment, never derived (R2), and an id the manifest does not have
    /// is no question at all. Nor is any question when nothing can be
    /// derived, as without the bundled curation. For "Explore From Here…" on
    /// recorded rows.
    func explorerQuestion(from: [String], to: String? = nil) -> ExplorerQuery? {
        let named = from + (to.map { [$0] } ?? [])
        guard !named.isEmpty, !derivation.participants(.all).isEmpty, named.allSatisfy({ id in
            relations.object(id).map { $0.type != Derivation.excludedType } ?? false
        }) else { return nil }
        return ExplorerQuery(from: from, to: to,
                             includesIdealisedModels: explorerQuery.includesIdealisedModels)
    }

    /// Put the current question on Recent, newest first, once. Called when a
    /// question is replaced and when the explorer closes: two clear moments,
    /// rather than a debounce on every edit.
    func rememberExplorerQuery() {
        let current = explorerQuery
        guard current.mode != .empty else { return }
        var recents = explorerRecents.filter { !$0.isSameQuestion(as: current) }
        recents.insert(current, at: 0)
        if recents.count > Self.explorerRecentsLimit {
            recents.removeLast(recents.count - Self.explorerRecentsLimit)
        }
        explorerRecents = recents
        CCwikiSettings.explorerRecents = recents
    }

    func title(forPath path: String) -> String {
        index?.pages[path]?.title ?? path
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            searchResultsQuery = query
            searchCorrection = nil
            searchError = nil
            return
        }
        searchTask = Task { [weak self] in
            // Debounce: the index is fast but re-querying on every keystroke
            // still makes the list flicker.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await searchIndex.conceptSearch(query)
                guard !Task.isCancelled else { return }
                searchResults = results.hits
                searchResultsQuery = query
                searchCorrection = results.correction
                searchError = nil
            } catch {
                searchResults = []
                searchResultsQuery = query
                searchCorrection = nil
                searchError = error.localizedDescription
            }
        }
    }

    private func scheduleReferenceSearch() {
        referenceTask?.cancel()
        let query = referenceQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            referenceResults = []
            referenceResultsQuery = query
            referenceError = nil
            return
        }
        referenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            do {
                let hits = try await searchIndex.referenceSearch(query)
                guard !Task.isCancelled else { return }
                referenceResults = hits
                referenceResultsQuery = query
                referenceError = nil
            } catch {
                referenceResults = []
                referenceResultsQuery = query
                referenceError = error.localizedDescription
            }
        }
    }

    private func scheduleGrep() {
        grepTask?.cancel()
        let query = grepQuery
        let grep = textGrep
        guard query.trimmingCharacters(in: .whitespaces).count >= TextGrep.minimumLength else {
            grepResults = []
            grepResultsQuery = query
            return
        }
        grepTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                grep.search(query)
            }.value
            guard !Task.isCancelled, let self else { return }
            grepResults = hits
            grepResultsQuery = query
        }
    }

    /// "12 pages, 40 matches".
    var grepSummary: String {
        let matches = grepResults.reduce(0) { $0 + $1.count }
        let pages = grepResults.count
        return "\(pages) page\(pages == 1 ? "" : "s"), \(matches) match\(matches == 1 ? "" : "es")"
    }

    func refreshQuickSwitcher() {
        guard let index else {
            quickSwitcherResults = []
            quickSwitcherRecentCount = 0
            return
        }
        let recent = recentPages.filter {
            $0 != quickSwitcherExcludedPath && index.pages[$0] != nil
        }
        quickSwitcherResults = index.quickSwitch(
            quickSwitcherQuery, excluding: unlistedPaths, recent: recent)
        let isEmptyQuery = quickSwitcherQuery.trimmingCharacters(in: .whitespaces).isEmpty
        quickSwitcherRecentCount = isEmptyQuery
            ? quickSwitcherResults.prefix(recent.count).count { recent.contains($0.path) }
            : 0
    }

    /// ⌘O from a window reading `path`: the switcher opens on an empty
    /// query, its list without `path`. The list is worked out once either
    /// way, which with an empty query is a sort of every page: clearing a
    /// query refreshes it (`didSet`), and an empty one is refreshed here,
    /// since the page left out may have been another window's.
    func resetQuickSwitcher(excluding path: String?) {
        quickSwitcherExcludedPath = path
        if quickSwitcherQuery.isEmpty {
            refreshQuickSwitcher()
        } else {
            quickSwitcherQuery = ""
        }
    }

    /// Closes every quick switcher but `id`'s. The query, results and left-out
    /// page are app-wide, so only one switcher is up at a time
    /// (plans/reader-comforts.md §1.6).
    func dismissQuickSwitchers(except id: UUID) {
        for session in sessions.values where session.id != id {
            session.quickSwitcherPresented = false
        }
    }

    /// A reader opened `path`: it is the page read last, for the next cold
    /// start, and the most recent of the recent pages, whichever window
    /// opened it.
    func noteVisited(_ path: String) {
        CCwikiSettings.lastPage = path
        recentPages.removeAll { $0 == path }
        recentPages.insert(path, at: 0)
        if recentPages.count > Self.recentPagesLimit {
            recentPages.removeLast(recentPages.count - Self.recentPagesLimit)
        }
        CCwikiSettings.recentPages = recentPages
    }

    // MARK: Page tree

    /// Kinds the sidebar tree leaves out. Each collapses to a single row that
    /// opens its folder listing in the reading pane instead.
    ///
    /// `.reference` for the reason in `plans/design-system.md` §3a. `.reduction`
    /// for the same reason and more sharply: there are 343 of them, they
    /// arrived in one migration, and a reduction is not somewhere you *browse*
    /// to — you reach one from the relation it states, on the page of one of
    /// its endpoints, which is what the Relations inspector is for. `Barriers/`
    /// stays an ordinary folder: 37 rows is a folder, not a wall.
    static let kindsOutsideTree: Set<PageKind> = [.reference, .reduction]

    /// Marks the warnings this feature owns, so a reload replaces them instead
    /// of stacking a fresh copy once per sync.
    static let relationsWarningPrefix = "Relationships: "

    /// The sidebar's directory tree, and the counts beside it.
    ///
    /// Stored, not computed: the sidebar's `body` reads these on every
    /// navigation, and building the tree walks and sorts every page. They
    /// change only when the index or a browse preference does, which is
    /// where `rebuildBrowseState` is called.
    private(set) var pageTree: [PageTreeNode] = []
    private(set) var referenceCount = 0
    private(set) var reductionCount = 0
    /// Stubs currently being hidden, so the UI can say so rather than quietly
    /// showing a shorter list than the repo has.
    private(set) var hiddenStubCount = 0

    private func rebuildBrowseState() {
        guard let index else {
            pageTree = []
            referenceCount = 0
            reductionCount = 0
            hiddenStubCount = 0
            return
        }
        let pages = index.allPages
        let browsable = pages.filter(isBrowsable)
        pageTree = PageTreeNode.build(pages: browsable, excluding: Self.kindsOutsideTree)
        referenceCount = browsable.count { $0.kind == .reference }
        reductionCount = browsable.count { $0.kind == .reduction }
        hiddenStubCount = hidesStubs ? pages.count { $0.status == .stub } : 0
    }

    /// Should this page appear in browse and navigation?
    ///
    /// Two independent filters that happen to compose. `hidesStubs` is the
    /// reader's preference; `unlisted` is the *wiki's* statement that a node is
    /// real — it takes part in reductions and in the closure — but is not
    /// somewhere to navigate to. Nothing here removes a node from the graph.
    func isBrowsable(_ page: WikiPage) -> Bool {
        (!hidesStubs || page.status != .stub) && !unlistedPaths.contains(page.path)
    }

    // MARK: Settings

    func setToolOverride(_ path: String?, for tool: ToolLocator.Tool) {
        CCwikiSettings.setToolOverride(path, for: tool)
        toolOverrides = CCwikiSettings.toolOverrides()
        GitHubAuth.invalidate()
        Task { await discoverTools() }
    }

    func recheckGitHubAuth() {
        GitHubAuth.invalidate()
        // A tool missing at the last look may have been installed since, as
        // the advice beside it says: every tool is looked for again, and
        // that asks GitHub and the clone afresh too.
        if isMissingTools {
            Task { await discoverTools() }
            return
        }
        let generation = discoveryGeneration
        Task { await askGitHub(generation: generation) }
    }

    /// Only a git clone is asked. Run against a snapshot, which has no
    /// `.git`, git would walk up to any repository enclosing Application
    /// Support (a `~/.git` for dotfiles), write the credential helper into
    /// its config, and answer for the push from the global and system
    /// config: "Configured" with no clone at all.
    private func refreshPushCapability() async {
        guard let git = gitService, paths.wikiStore == .git else {
            canPushToRemote = false
            return
        }
        if let gh = tools.path(for: .gh) {
            await git.configureCredentialHelper(clone: paths.clone, ghPath: gh)
        }
        canPushToRemote = await git.canAuthenticatePush(clone: paths.clone)
    }

    /// Bytes on disk, for the Settings row. The index is derived, so the only
    /// interesting thing about it is how much space it is using.
    var searchIndexSize: String {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: paths.searchDatabase.path(percentEncoded: false))
        guard let bytes = attributes?[.size] as? Int64 else { return "not built" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Settings ▸ Storage ▸ Rebuild: read every page again and write the
    /// search index from nothing. The library on screen is dropped and the
    /// index reset inside the load, behind any load already running, so
    /// neither can be overwritten by one that started earlier.
    func rebuildLibrary() {
        Task { await loadLibrary(reason: .rebuild) }
    }

    // MARK: Ingestion

    /// Copy a dropped PDF into the library.
    ///
    /// Deliberately outside the clone: a PDF is a job *input*, and the
    /// reference page the job produces cites eprint/arXiv/DOI. Nothing here
    /// ever enters the repo.
    func stagePDF(from source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: paths.library, withIntermediateDirectories: true)
        var destination = paths.library.appending(path: source.lastPathComponent)

        // Never silently overwrite a paper someone already staged.
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            let stem = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var counter = 2
            repeat {
                destination = paths.library.appending(path: "\(stem)-\(counter).\(ext)")
                counter += 1
            } while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        }

        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// A new ingestion job, shown in the Jobs window as it starts.
    func submitIngestion(source: IngestSubmission.Source?, pdf: URL?, notes: String) {
        let job = jobCenter.submitIngestion(source: source, pdf: pdf, notes: notes)
        requestJobsWindow(selecting: job.id)
    }

    /// Forget the finished jobs. Their transcripts stay on disk; only the
    /// records that bring them back at launch go.
    func clearFinishedJobs() {
        jobCenter.clearFinishedJobs()
    }

    var hasFinishedJobs: Bool { jobCenter.hasFinishedJobs }

    /// Jobs that are not finished: running, or waiting for review. Their
    /// worktrees live in the clone's `.git`.
    var unfinishedJobCount: Int { jobs.count { !$0.state.isTerminal } }

    /// The same submission again, as a new job. The common case after a
    /// failure that was the machine's fault rather than the paper's.
    func runAgain(_ job: Job) {
        jobCenter.runAgain(job)
        requestJobsWindow(selecting: jobCenter.jobs.first?.id)
    }

    // MARK: Other copies

    /// The check belongs to the launch, which runs once; this keeps it to
    /// once if anything else ever asks.
    @ObservationIgnored private var hasCheckedInstallation = false

    /// The launch check of `plans/update-integrity.md` §2.3, from
    /// `launchIfNeeded`, before the launch sync and the update check: logs which copy
    /// this is, then, in a release, looks for the other copies LaunchServices
    /// could start instead of this one and says at most one thing about them.
    /// The updater can only ever replace this copy; a stale one elsewhere is
    /// dealt with here. Before the sync, so that a copy about to hand over
    /// to another never starts a fetch on the clone they share.
    func checkInstallation() async {
        guard !hasCheckedInstallation else { return }
        hasCheckedInstallation = true
        let bundle = Bundle.main.bundleURL
        let running = InstalledCopy(url: bundle, version: appVersion, build: Bundle.main.buildNumber)
        InstallationCheck.logLaunch(of: running)
        guard BuildIdentity.isRelease, ScreenshotRunner.directory == nil else { return }

        // Off the main actor: LaunchServices, a plist per copy, and perhaps
        // deleting a bundle an older updater left behind.
        let identifier = BuildIdentity.releaseBundleIdentifier
        let others = await Task.detached(priority: .utility) {
            UpdateInstaller.removeLegacyLeftovers(besides: bundle, identifier: identifier)
            return InstallationCheck.otherCopies(of: identifier, besides: bundle)
        }.value
        let advice = InstallationCheck.advice(
            running: running,
            runningInApplicationsFolder: BundleLocation.isInApplicationsFolder(bundle),
            others: others,
            ignoredPaths: Set(CCwikiSettings.ignoredCopies))
        switch advice {
        case .none: break
        case .openNewer(let newer): await offerNewerCopy(newer, running: running)
        case .replaceOlder(let installed): await offerReplacing(installed, running: running)
        case .removeOthers(let copies): offerRemoving(copies)
        }
    }

    /// Another copy is newer: open it and quit this one, or keep going. The
    /// downgrade guard, too: when the Dock starts an older copy that has this
    /// check, it points to the newer one. A newer copy that is already open
    /// is brought forward rather than started a second time.
    private func offerNewerCopy(_ newer: InstalledCopy, running: InstalledCopy) async {
        let (here, there) = InstallationCheck.displayLocations(running.url, newer.url)
        let alert = NSAlert()
        alert.messageText = "A newer version of CCwiki is on this Mac."
        alert.informativeText = "This is CCwiki \(running.version), in \(here). "
            + "CCwiki \(newer.version) is in \(there)."
        alert.addButton(withTitle: "Open CCwiki \(newer.version)")
        alert.addButton(withTitle: "Keep Using This Version").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn,
              mayStopJobs(then: "open CCwiki \(newer.version)", button: "Open")
        else { return }
        if let existing = runningInstance(of: newer.url) {
            stopJobsBeforeQuitting()
            _ = existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        stopJobsBeforeQuitting()
        do {
            try await UpdateInstaller.relaunch(newer.url)
        } catch {
            showInstallationFailure(
                "CCwiki \(newer.version) could not be started.",
                detail: "\(error.localizedDescription)\n\nThis window keeps running the version "
                    + "you have.")
            return
        }
        NSApp.terminate(nil)
    }

    /// This copy runs from outside Applications, and an older one sits in
    /// Applications, where the Dock and Spotlight find it: put this one in its
    /// place, trash this one, and start the one in Applications. The LetsMove
    /// idiom, kept to the case that causes the confusion.
    ///
    /// Every step before the relaunch either completes or leaves things as
    /// they were. The copy in Applications is quit first if it is open, so
    /// it is never swapped out from under its own process. This window quits
    /// only once the new one has started, and if it does not start, this
    /// copy comes back out of the Trash.
    private func offerReplacing(_ installed: InstalledCopy, running: InstalledCopy) async {
        // A same-version copy is replaced all the same: what matters is
        // which one the Dock starts. Only the wording changes. An older
        // release updates itself when it runs; only a development version,
        // a build from source, never does.
        let isOlder = InstallationCheck.isOlder(installed.version, than: running.version)
        let (there, here) = InstallationCheck.displayLocations(installed.url, running.url)
        let risk: String
        if UpdateChecker.isDevelopmentVersion(installed.version) {
            risk = "can start that copy, a build from source that won't update itself."
        } else if isOlder {
            risk = "can start the older version instead of this one."
        } else {
            risk = "can start that copy instead of this one."
        }
        let alert = NSAlert()
        alert.messageText = isOlder
            ? "Replace the older CCwiki in Applications?"
            : "Replace the other CCwiki in Applications?"
        alert.informativeText = "CCwiki \(installed.version) is in \(there), and this copy, "
            + "\(running.version), is in \(here). Opening CCwiki from the Dock or Spotlight "
            + risk + " Replace and Relaunch puts this version in \(there), moves this copy "
            + "to the Trash, and opens CCwiki from there."
        alert.addButton(withTitle: "Replace and Relaunch")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        guard alert.runModal() == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on { ignoreCopies([installed]) }
            return
        }
        guard mayStopJobs(then: "replace the CCwiki in \(there)", button: "Replace") else {
            return
        }
        // Open, it would keep running from a bundle that is gone, and the
        // relaunch would start a second process beside it.
        guard await quitRunningInstance(of: installed.url) else {
            showInstallationFailure(
                "The CCwiki in \(there) is still open.",
                detail: "Quit it, then open this copy again to put it in its place. Nothing "
                    + "was changed, and this window keeps running the version you have.")
            return
        }

        let bundle = Bundle.main.bundleURL
        do {
            try await InstallationCheck.installCopy(of: bundle, over: installed.url)
        } catch {
            // The error says what, if anything, changed.
            showInstallationFailure(
                "The CCwiki in \(there) was not replaced.",
                detail: "\(error.localizedDescription)\n\nThis window keeps running the "
                    + "version you have.")
            return
        }
        // LaunchServices does not start an app from the Trash, so this copy
        // goes there, and comes back if the one in Applications won't start.
        // Where it cannot go (a folder that is not yours), the copy in
        // Applications finds it at its launch and offers it again. On a
        // read-only volume (a disk image, App Translocation's mirror) it
        // stays, and is never offered; the folder a mirror was made from is
        // writable, though, so that is offered at the next launch.
        var trashedAt: NSURL?
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: &trashedAt)
        } catch {
            trashedAt = nil
        }
        stopJobsBeforeQuitting()
        do {
            try await UpdateInstaller.relaunch(installed.url)
        } catch {
            let thisCopy: String
            if let trashedAt {
                do {
                    try FileManager.default.moveItem(at: trashedAt as URL, to: bundle)
                    thisCopy = "This copy is back in \(here), and this window keeps running."
                } catch {
                    thisCopy = "This copy is in the Trash, and this window keeps running until "
                        + "you quit it. Put Back in the Finder returns it to \(here)."
                }
            } else {
                thisCopy = "This copy is still in \(here), and this window keeps running."
            }
            showInstallationFailure(
                "CCwiki \(running.version) is in \(there), but could not be started.",
                detail: "\(error.localizedDescription)\n\n\(thisCopy)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Older or same-version copies elsewhere: name each, and offer the
    /// Trash or the Finder.
    private func offerRemoving(_ copies: [InstalledCopy]) {
        let one = copies.count == 1
        let alert = NSAlert()
        alert.messageText = one
            ? "Another copy of CCwiki is on this Mac."
            : "Other copies of CCwiki are on this Mac."
        let list = copies
            .map { "CCwiki \($0.version) — \(InstallationCheck.abbreviatedPath($0.url))" }
            .joined(separator: "\n")
        let which = one ? "it" : "one of these"
        // An older release updates itself when it runs; only a development
        // version, a build from source, never does.
        let stuck: String
        if !copies.allSatisfy({ UpdateChecker.isDevelopmentVersion($0.version) }) {
            stuck = "."
        } else {
            stuck = one ? ", and it won't update itself." : ", and they won't update themselves."
        }
        alert.informativeText = list + "\n\nOpening CCwiki from the Dock, Spotlight or a link "
            + "can start \(which) instead of this copy" + stuck
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let choice = alert.runModal()
        let dontAskAgain = alert.suppressionButton?.state == .on
        switch choice {
        case .alertFirstButtonReturn:
            moveToTrash(copies, ignoringFailures: dontAskAgain)
        case .alertSecondButtonReturn:
            if dontAskAgain { ignoreCopies(copies) }
            NSWorkspace.shared.activateFileViewerSelecting(copies.map(\.url))
        default:
            if dontAskAgain { ignoreCopies(copies) }
        }
    }

    /// Trashes each copy, and names the ones that would not go. Those are
    /// remembered too when the person said not to be asked again; a trashed
    /// path is not, since a later copy at that path is news.
    private func moveToTrash(_ copies: [InstalledCopy], ignoringFailures: Bool) {
        var kept: [InstalledCopy] = []
        var reasons: [String] = []
        for copy in copies {
            do {
                try FileManager.default.trashItem(at: copy.url, resultingItemURL: nil)
            } catch {
                kept.append(copy)
                reasons.append("CCwiki \(copy.version) — "
                    + "\(InstallationCheck.abbreviatedPath(copy.url)): \(error.localizedDescription)")
            }
        }
        guard !kept.isEmpty else { return }
        if ignoringFailures { ignoreCopies(kept) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = kept.count == 1
            ? "A copy of CCwiki could not be moved to the Trash."
            : "\(kept.count) copies of CCwiki could not be moved to the Trash."
        alert.informativeText = reasons.joined(separator: "\n")
            + "\n\nThe Finder can move \(kept.count == 1 ? "it" : "them"), and asks for your "
            + "password where it needs one."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(kept.map(\.url))
        }
    }

    /// "Don't ask again": the launch check never offers to replace or trash
    /// the copies at these paths again. A newer copy at one is still news.
    private func ignoreCopies(_ copies: [InstalledCopy]) {
        var ignored = CCwikiSettings.ignoredCopies
        for copy in copies {
            let path = InstallationCheck.path(of: copy.url)
            if !ignored.contains(path) { ignored.append(path) }
        }
        CCwikiSettings.ignoredCopies = ignored
    }

    private func showInstallationFailure(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Handing over to another copy

    /// Before this window hands over to another copy and quits: when jobs
    /// are running, whether the person agrees to stop them. Asked before
    /// anything changes, as `relaunchToUpdate` does: a "Don't Quit" at the
    /// quit would leave two copies of the app on one clone and one search
    /// index. True when nothing is running.
    private func mayStopJobs(then action: String, button: String) -> Bool {
        let publishing = jobCenter.publishingCount
        guard let wording = StopJobsWording.make(
            agents: activeJobCount - publishing, publishing: publishing,
            action: action, verb: button)
        else { return true }
        return wording.confirm()
    }

    /// Stops the jobs the person agreed to stop (`mayStopJobs`), and any
    /// started since, just before the other copy starts, so the quit that
    /// follows has nothing to ask.
    private func stopJobsBeforeQuitting() {
        if activeJobCount > 0 { cancelActiveJobs() }
    }

    /// The process running the copy at `url`, if there is one: not this one,
    /// and not one that has quit.
    private func runningInstance(of url: URL) -> NSRunningApplication? {
        let target = InstallationCheck.path(of: url.resolvingSymlinksInPath())
        let me = ProcessInfo.processInfo.processIdentifier
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: BuildIdentity.releaseBundleIdentifier)
        return candidates.first { app in
            guard app.processIdentifier != me, !app.isTerminated,
                  let bundle = app.bundleURL
            else { return false }
            return InstallationCheck.path(of: bundle.resolvingSymlinksInPath()) == target
        }
    }

    /// Asks the process running the copy at `url`, if any, to quit, and
    /// gives it ten seconds, since it may ask about its own jobs first. True
    /// when no such process is left.
    private func quitRunningInstance(of url: URL) async -> Bool {
        guard let other = runningInstance(of: url) else { return true }
        _ = other.terminate()
        for _ in 0..<50 {
            if other.isTerminated { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return other.isTerminated
    }

    // MARK: Update check

    /// The daily check, at the end of the launch and then every hour while
    /// the app runs (`startHourlyChores`). Silent whatever happens: an
    /// update is a note in the status bar, and a failure is nothing at all.
    /// CCwiki Dev never checks, whatever its version says.
    func checkForUpdatesIfDue() async {
        guard BuildIdentity.isRelease, checksForUpdates,
              !UpdateChecker.isDevelopmentVersion(appVersion),
              Self.isUpdateCheckDue(lastCheck: lastUpdateCheck, now: Date())
        else { return }
        if case .available(let release) = await performUpdateCheck() {
            await installFoundUpdateIfAllowed(release)
        }
    }

    /// A day has passed since the last answer, or none has come yet.
    nonisolated static func isUpdateCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= updateInterval
    }

    /// `nil` when GitHub could not be reached or understood. The time of the
    /// check is recorded only when an answer came back, and kept for the
    /// next launch only as `persistedUpdateCheck` says.
    private func performUpdateCheck() async -> UpdateChecker.Outcome? {
        guard !isCheckingForUpdates else { return nil }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        guard let outcome = try? await UpdateChecker.check(currentVersion: appVersion) else {
            return nil
        }
        lastUpdateCheck = Date()
        CCwikiSettings.lastUpdateCheck = Self.persistedUpdateCheck(lastUpdateCheck, after: outcome)
        warnings.removeAll { $0.hasPrefix(Self.updateWarningPrefix) }
        if case .available(let release) = outcome {
            availableUpdate = release
            if installedUpdate?.version != release.version {
                warn(Self.updateWarningPrefix + "CCwiki \(release.version) is available. "
                    + "Choose CCwiki > Check for Updates… to install it.")
            }
        } else {
            availableUpdate = nil
        }
        return outcome
    }

    /// The check time the next launch reads. Only an answer that nothing is
    /// newer holds that launch's check off. A release that was found is
    /// asked for again: `availableUpdate`, its status-bar note and a failed
    /// install's note all go with the process, and a launch that skipped
    /// the check would know of no update, say "Up to date" in Settings, and
    /// never retry the install.
    nonisolated static func persistedUpdateCheck(
        _ checked: Date?, after outcome: UpdateChecker.Outcome
    ) -> Date? {
        if case .available = outcome { return nil }
        return checked
    }

    /// The daily check's second half: install what it found, if allowed,
    /// and say so in the status bar. Never relaunches by itself.
    private func installFoundUpdateIfAllowed(_ release: ReleaseInfo) async {
        guard BuildIdentity.isRelease, installsUpdatesAutomatically, canInstallUpdates,
              release.isInstallable, installedUpdate?.version != release.version,
              activeJobCount == 0
        else { return }
        if let error = await installUpdate(release) {
            warn(Self.updateWarningPrefix + "CCwiki \(release.version) could not be installed: "
                + error.localizedDescription)
        }
    }

    /// Download, verify, unpack, check and swap. `nil` on success, in which
    /// case `installedUpdate` is set and a relaunch is all that is left.
    private func installUpdate(_ release: ReleaseInfo) async -> Error? {
        guard !isInstallingUpdate else { return UpdateInstaller.Failure.installInProgress }
        isInstallingUpdate = true
        defer {
            isInstallingUpdate = false
            updateInstallProgress = nil
        }
        do {
            _ = try await UpdateInstaller.install(
                release,
                replacing: Bundle.main.bundleURL,
                expectedIdentifier: Bundle.main.bundleIdentifier ?? "com.axhoover.ccwiki",
                publicKey: ReleaseKey.publicKey
            ) { [weak self] message in
                Task { @MainActor in
                    // A report can land after the install returned; the
                    // defer above has cleared the flag by then.
                    guard let self, self.isInstallingUpdate else { return }
                    self.updateInstallProgress = message
                }
            }
        } catch {
            return error
        }
        installedUpdate = release
        availableUpdate = nil
        warnings.removeAll {
            $0.hasPrefix(Self.updateWarningPrefix) || $0.hasPrefix(Self.updateInstalledPrefix)
        }
        warn(Self.updateInstalledPrefix + "CCwiki \(release.version) is installed. "
            + "Choose CCwiki > Relaunch to Update when convenient.")
        return nil
    }

    /// Quit and start the bundle that is now at this app's path.
    ///
    /// Jobs first: the new instance must not be started until it is settled
    /// that this one will quit, or "Don't Quit" would leave two copies of
    /// the app on one clone and one search index. And the quit comes only
    /// after the launch succeeded, so a bundle that will not start leaves
    /// this window where it is.
    func relaunchToUpdate() {
        Task { @MainActor in
            let publishing = jobCenter.publishingCount
            if let wording = StopJobsWording.make(
                agents: activeJobCount - publishing, publishing: publishing,
                action: "relaunch", verb: "Relaunch") {
                guard wording.confirm() else { return }
                cancelActiveJobs()
            }
            do {
                try await UpdateInstaller.relaunch(Bundle.main.bundleURL)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "The new version could not be started."
                alert.informativeText = "\(error.localizedDescription) This window keeps "
                    + "running the version you have, and the releases page has the download."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Releases Page")
                if alert.runModal() == .alertSecondButtonReturn,
                   let url = URL(string: UpdateChecker.releasesPage) {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            NSApp.terminate(nil)
        }
    }

    /// The menu item and the Settings button. The person asked, so this one
    /// answers with an alert either way.
    func checkForUpdates() {
        Task { @MainActor in
            let alert = NSAlert()
            let version = appVersion

            // CCwiki Dev never checks, whatever its version says. A release id
            // with a development version is an older build from source.
            if !BuildIdentity.isRelease || UpdateChecker.isDevelopmentVersion(version) {
                if BuildIdentity.isRelease {
                    alert.messageText = "This is a local build."
                    alert.informativeText = "Version \(version) was built from source rather "
                        + "than downloaded as a release, so CCwiki does not replace it. The "
                        + "latest release is always on the releases page."
                } else {
                    alert.messageText = "CCwiki Dev does not update itself."
                    alert.informativeText = "Version \(version) was built from source. It keeps "
                        + "its own settings and wiki apart from CCwiki, and never checks for or "
                        + "installs a release; build it again for a newer one. The latest "
                        + "release is always on the releases page."
                }
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Releases Page")
                if alert.runModal() == .alertSecondButtonReturn,
                   let url = URL(string: UpdateChecker.releasesPage) {
                    NSWorkspace.shared.open(url)
                }
                return
            }

            guard let outcome = await performUpdateCheck() else {
                alert.messageText = "CCwiki could not check for updates."
                alert.informativeText = "GitHub could not be reached. Try again later, or look "
                    + "at the releases page directly."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Releases Page")
                if alert.runModal() == .alertSecondButtonReturn,
                   let url = URL(string: UpdateChecker.releasesPage) {
                    NSWorkspace.shared.open(url)
                }
                return
            }

            switch outcome {
            case .available(let release):
                if let installed = installedUpdate, installed.version == release.version {
                    offerRelaunch(for: installed)
                    return
                }
                alert.messageText = "CCwiki \(release.version) is available."
                let installable = canInstallUpdates && release.isInstallable && activeJobCount == 0
                if installable {
                    alert.informativeText = "You have \(version). CCwiki will download the "
                        + "release, verify its signature, and put it in place of this copy."
                    alert.addButton(withTitle: "Install and Relaunch")
                    alert.addButton(withTitle: "Open Release Page")
                    alert.addButton(withTitle: "Later")
                } else {
                    alert.informativeText = "You have \(version). "
                        + (activeJobCount > 0
                            ? "A job is running, so it will not be installed now; "
                            : canInstallUpdates
                                ? "The release has no signed archive attached, so it cannot "
                                    + "be installed from here; "
                                : "This build cannot verify a download, so it cannot install "
                                    + "one; ")
                        + "the release page has the zip."
                    alert.addButton(withTitle: "Open Release Page")
                    alert.addButton(withTitle: "Later")
                }
                let choice = alert.runModal()
                if installable, choice == .alertFirstButtonReturn {
                    if let error = await installUpdate(release) {
                        let failed = NSAlert()
                        failed.alertStyle = .warning
                        failed.messageText = "CCwiki \(release.version) was not installed."
                        failed.informativeText = error.localizedDescription
                        failed.addButton(withTitle: "OK")
                        failed.addButton(withTitle: "Open Release Page")
                        if failed.runModal() == .alertSecondButtonReturn {
                            NSWorkspace.shared.open(release.url)
                        }
                    } else {
                        // The button said "and Relaunch": no second question.
                        // `relaunchToUpdate` still asks about running jobs.
                        relaunchToUpdate()
                    }
                } else if (installable && choice == .alertSecondButtonReturn)
                    || (!installable && choice == .alertFirstButtonReturn) {
                    NSWorkspace.shared.open(release.url)
                }
            case .upToDate:
                alert.messageText = "You're up to date."
                alert.informativeText = "CCwiki \(version) is the newest release."
                alert.runModal()
            case .noReleases:
                alert.messageText = "No releases yet."
                alert.informativeText = "Nothing has been published on GitHub to compare "
                    + "\(version) against."
                alert.runModal()
            }
        }
    }

    private func offerRelaunch(for release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "CCwiki \(release.version) is installed."
        alert.informativeText = "Relaunch to start using it. Until then this window keeps "
            + "running the version you have."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { relaunchToUpdate() }
    }

    /// Stop what is running. Called on quit, so no agent outlives the window
    /// it was reporting to: left alone it would keep working in the worktree.
    /// A review is left as it is, and a publish goes back to review
    /// (corrections §4.1).
    func cancelActiveJobs() {
        jobCenter.cancelActiveJobs()
    }

    /// Look for strays. The job center calls `orphanedWorktreesChanged`
    /// with what it found, which rebuilds the warning.
    func refreshOrphanedWorktrees() async {
        await jobCenter.refreshOrphanedWorktrees()
    }

    func pruneOrphan(_ path: String) {
        jobCenter.pruneOrphan(path)
    }

    /// The warning is rebuilt with the list wherever that is refreshed (at
    /// launch, after a clone or a reset, after a job and after a prune), so
    /// it never names worktrees already pruned (SWIFTUI-RULES §3.1).
    private func orphanedWorktreesChanged(_ worktrees: [String]) {
        warnings.removeAll { $0.hasPrefix(Self.orphansWarningPrefix) }
        guard !worktrees.isEmpty else { return }
        let count = worktrees.count
        warn(Self.orphansWarningPrefix
            + "\(count) left over from an interrupted job. "
            + "Open the jobs window (⇧⌘J) to prune \(count == 1 ? "it" : "them").")
    }

    /// Open a worktree in Terminal — the escape hatch for a failed job.
    ///
    /// `NSWorkspace.open(_:withApplicationAt:)` rather than an `osascript`
    /// shim, because UI scripting Terminal would need the Accessibility
    /// permission and this needs none.
    func openInTerminal(_ directory: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [directory], withApplicationAt: terminal, configuration: configuration)
    }
}

/// What an alert says before the app stops jobs: at a quit, a relaunch to
/// update, or a hand-over to another copy (plans/corrections.md §11.1).
/// Agents, preparing or running, are stopped; a publishing job is
/// interrupted and goes back to review. Counted apart, because the two lose
/// different things.
struct StopJobsWording: Equatable, Sendable {
    let message: String
    let informative: String
    let confirmTitle: String
    let cancelTitle: String

    static let agentDetail = "The agent will be stopped. Its worktree and transcript are kept."
    static let publishingDetail = "Quitting stops it. The job returns to review, and CCwiki "
        + "checks GitHub before opening the pull request again."

    /// Nil when there is nothing to stop. `action` ends the message, "quit"
    /// or "open CCwiki 0.3.1"; `verb` is the buttons', "Quit" or "Open".
    /// `agentsMessage` replaces the message about agents where an alert has
    /// always put it its own way.
    static func make(
        agents: Int, publishing: Int, action: String, verb: String,
        agentsMessage: String? = nil
    ) -> StopJobsWording? {
        guard agents > 0 || publishing > 0 else { return nil }
        let message: String
        var detail: [String] = []
        if agents > 0 {
            message = agentsMessage ?? (agents == 1
                ? "Stop the running job and \(action)?"
                : "Stop \(agents) running jobs and \(action)?")
            detail.append(agentDetail)
            if publishing > 0 {
                detail.append("A pull request is being opened too. " + publishingDetail)
            }
        } else {
            message = action.prefix(1).uppercased() + action.dropFirst()
                + " while a pull request is being opened?"
            detail.append(publishingDetail)
        }
        let confirm = agents == 0
            ? verb
            : (agents == 1 ? "Stop Job and " : "Stop Jobs and ") + verb
        return StopJobsWording(
            message: message, informative: detail.joined(separator: " "),
            confirmTitle: confirm, cancelTitle: "Don't \(verb)")
    }

    /// Asks, and says whether the person agreed.
    @MainActor
    func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
