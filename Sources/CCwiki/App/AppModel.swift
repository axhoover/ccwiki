import Foundation
import Observation
import SwiftUI

/// App-wide state.
///
/// One `@Observable @MainActor` object owns everything the views read. The
/// expensive parts — walking the clone, parsing 297 files, rebuilding the FTS
/// index — happen off the main actor and land here as one assignment, so the
/// UI never sees a half-built library.
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
    private(set) var canPushToRemote = false
    private(set) var vendorManifest: String?

    /// Fast-forward the clone at launch. Persisted; see `CCwikiSettings`.
    var syncsAtLaunch: Bool = CCwikiSettings.syncsAtLaunch {
        didSet { CCwikiSettings.syncsAtLaunch = syncsAtLaunch }
    }

    /// Hide stub pages in the sidebar and on folder listings. Persisted.
    var hidesStubs: Bool = CCwikiSettings.hidesStubs {
        didSet {
            guard hidesStubs != oldValue else { return }
            CCwikiSettings.hidesStubs = hidesStubs
            rebuildBrowseState()
            // The rendered folder page does not follow the preference by itself.
            webController.invalidate()
            renderCurrent(preservingScroll: true)
        }
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
    /// Pages the manifest marks `unlisted`. Real nodes — they take part in
    /// relations and in the closure — kept out of browse and navigation only.
    private(set) var unlistedPaths: Set<String> = []
    private(set) var modifiedDates: [String: Date] = [:]
    private(set) var headRevision: String?
    /// When the checked-out commit was made: "the wiki as of".
    private(set) var headDate: Date?

    // MARK: Navigation

    /// What the reader is showing.
    enum Location: Equatable, Sendable {
        case page(path: String, anchor: String?)
        case folder(slug: String)
        case empty

        var path: String? {
            if case .page(let path, _) = self { return path }
            return nil
        }
    }

    /// Where the reader is and how it got there. The rules live in
    /// `NavigationHistory` so they can be tested without a web view.
    private var history = NavigationHistory()

    var location: Location { history.current }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// The directory the sidebar has expanded to, so selection survives a reload.
    var sidebarSelection: String?
    /// Which sidebar folders are open. Opening a page from a link, the quick
    /// switcher or search reveals its folder, so the sidebar always shows where
    /// you are rather than silently disagreeing with the reader.
    var expandedFolders: Set<String> = []
    var inspectorTab: InspectorTab = .outline
    var showInspector = true

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
    /// The sync log sheet. Every failure message ends "see the sync log", so
    /// there has to be somewhere to see it.
    var syncLogPresented = false

    // MARK: Search

    private let searchIndex: SearchIndex
    var searchQuery = "" {
        didSet { scheduleSearch() }
    }
    private(set) var searchResults: [SearchHit] = []
    private(set) var searchError: String?
    private var searchTask: Task<Void, Never>?

    var searchPresented = false
    var quickSwitcherPresented = false
    /// Setting the query recomputes the results, so the two can never drift —
    /// whether the change came from the text field, a menu command, or the
    /// screenshot harness.
    var quickSwitcherQuery = "" {
        didSet { refreshQuickSwitcher() }
    }
    private(set) var quickSwitcherResults: [QuickSwitchItem] = []

    // MARK: Jobs

    private(set) var jobs: [IngestJob] = []
    /// Worktrees git still knows about that no live job owns — the residue of
    /// a crash or a force-quit mid-job.
    private(set) var orphanedWorktrees: [String] = []
    var ingestSheetPresented = false
    /// A PDF dropped on the reader, waiting for the sheet to pick it up.
    var pendingDroppedPDF: URL?
    /// Bumped to ask the root view to open the jobs window. `openWindow` is an
    /// environment action, so only a view can call it; the model can only ask.
    private(set) var jobsWindowRequests = 0

    func requestJobsWindow() { jobsWindowRequests += 1 }

    /// Same pattern for Settings. `openSettings` is an environment action, and
    /// the `showSettingsWindow:` selector that worked before macOS 13 does
    /// nothing for a SwiftUI `Settings` scene (SWIFTUI-RULES §6.4).
    private(set) var settingsRequests = 0

    func requestSettings() { settingsRequests += 1 }

    var activeJobCount: Int { jobs.filter { $0.state.isActive }.count }

    // MARK: Updates

    var checksForUpdates: Bool = CCwikiSettings.checksForUpdates {
        didSet { CCwikiSettings.checksForUpdates = checksForUpdates }
    }
    private(set) var availableUpdate: ReleaseInfo?
    private(set) var lastUpdateCheck: Date? = CCwikiSettings.lastUpdateCheck
    private(set) var isCheckingForUpdates = false
    static let updateInterval: TimeInterval = 24 * 60 * 60
    static let updateWarningPrefix = "Update: "

    var appVersion: String { Bundle.main.shortVersion }

    // MARK: Reader

    let webController: WebController

    // MARK: Diagnostics

    /// Things the user should know but that must not stop them reading:
    /// a failed pull, a macro table that would not parse, missing tooling.
    private(set) var warnings: [String] = []

    /// Append once. A warning that repeats on every sync is noise, and a
    /// duplicate could not be dismissed on its own.
    private func warn(_ message: String) {
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
        self.webController = WebController(paths: paths)

        try? paths.createDirectories()
        // Tools are looked for in `discoverTools()`, after the first frame:
        // the login-shell fallback costs up to three seconds per tool that is
        // not installed, and `init` runs on the main thread before any window.
        toolOverrides = CCwikiSettings.toolOverrides()
        tools = ToolLocator(overrides: toolOverrides)
        vendorManifest = try? String(
            contentsOf: paths.webRoot.appending(path: "vendor/VENDOR.txt"), encoding: .utf8)

        webController.onNavigate = { [weak self] destination, _ in
            self?.navigate(to: destination)
        }
        webController.onReady = { [weak self] in
            self?.renderCurrent()
        }

        refreshMacrosWarning()
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
        isGitHubAuthenticated = await GitHubAuth.isAuthenticated(tools: all)
        guard generation == discoveryGeneration else { return }
        await refreshPushCapability()
    }

    private func refreshToolWarnings() {
        warnings.removeAll { $0.hasPrefix(Self.toolsWarningPrefix) }
        if needsDeveloperTools {
            warn(Self.toolsWarningPrefix
                + "git needs Apple's Command Line Tools. Install them to fetch the wiki.")
        } else if let missing = tools.missingForReading.first {
            warn(Self.toolsWarningPrefix
                + "\(missing.rawValue) was not found. CCwiki needs it for \(missing.purpose).")
        }
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

    /// Why a job could not start right now, in the order the sheet shows them.
    /// Empty means the pre-flight checks that concern tooling would pass.
    var ingestionBlockers: [String] {
        var blockers: [String] = []
        if index == nil {
            blockers.append("The wiki has not been cloned yet. Sync first (⌘R).")
        }
        if needsDeveloperTools {
            blockers.append("git needs Apple's Command Line Tools.")
        }
        for tool in tools.missingForIngestion where !(tool == .git && needsDeveloperTools) {
            blockers.append("\(tool.rawValue) was not found. It is needed for \(tool.purpose).")
        }
        if tools.path(for: .gh) != nil, !isGitHubAuthenticated {
            blockers.append("The GitHub CLI is not signed in. Run `gh auth login` in Terminal.")
        }
        if tools.path(for: .gh) != nil, isGitHubAuthenticated, !canPushToRemote {
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

    /// Parse the clone and rebuild the search index. Cheap enough (a few
    /// hundred milliseconds for the whole corpus) to do unconditionally after
    /// every pull rather than trying to work out what changed.
    func loadLibrary() async {
        guard FileManager.default.fileExists(
            atPath: paths.content.path(percentEncoded: false)) else { return }

        let contentRoot = paths.content
        let cloneRoot = paths.clone
        let loaded = await Task.detached(priority: .userInitiated) {
            let index = WikiIndex.build(contentRoot: contentRoot)
            // 303 KB of JSON, and the labels need every hosting page's
            // headings — both cheap, but neither belongs on the main actor.
            let manifest = RelationsManifest.load(cloneRoot: cloneRoot)
            return (
                index,
                index.backlinkMap(),
                manifest,
                RelationLabels(manifest: manifest, index: index))
        }.value

        index = loaded.0
        backlinks = loaded.1
        relations = loaded.2
        relationLabels = loaded.3
        unlistedPaths = loaded.2.unlistedPaths
        rebuildBrowseState()
        macros = MacroTable.load(cloneRoot: paths.clone)
        refreshMacrosWarning()

        // Replaced rather than appended: `loadLibrary` runs after every pull,
        // and a warning that stacks up once per sync is noise.
        warnings.removeAll { $0.hasPrefix(Self.relationsWarningPrefix) }
        if let diagnostic = relations.diagnostic {
            warn(Self.relationsWarningPrefix + diagnostic.message)
        }

        let git = gitService
        if let git {
            modifiedDates = await git.modifiedDates(in: paths.clone)
            headRevision = await git.head(in: paths.clone)
            headDate = await git.headDate(in: paths.clone)
            if let gh = tools.path(for: .gh) {
                await git.configureCredentialHelper(clone: paths.clone, ghPath: gh)
            }
        }

        let pages = loaded.0.allPages
        let searchIndex = self.searchIndex
        Task.detached(priority: .utility) {
            do {
                try await searchIndex.rebuild(pages: pages)
            } catch {
                await MainActor.run {
                    self.warn("Search index could not be rebuilt: \(error.localizedDescription)")
                }
            }
        }

        await refreshPushCapability()
        if let git = gitService {
            await git.repairWorktrees(clone: paths.clone, worktreeRoot: paths.worktrees)
        }
        // A crash or force-quit mid-job leaves a worktree behind, and
        // `git worktree add` will refuse to reuse the path. Finding them at
        // launch is cheaper than making the user learn `git worktree prune`.
        await refreshOrphanedWorktrees()
        warnings.removeAll { $0.hasPrefix(Self.orphansWarningPrefix) }
        if !orphanedWorktrees.isEmpty {
            let count = orphanedWorktrees.count
            warn(Self.orphansWarningPrefix
                + "\(count) left over from an interrupted job. "
                + "Open the jobs window (⇧⌘J) to prune \(count == 1 ? "it" : "them").")
        }

        // Re-render whatever is on screen, since the file may have changed —
        // keeping the reader's place, since it usually has not.
        webController.invalidate()
        if case .empty = location { openHome() } else { renderCurrent(preservingScroll: true) }
        refreshQuickSwitcher()
    }

    private var gitService: GitService? {
        guard let git = tools.path(for: .git) else { return nil }
        return GitService(executable: git, environment: tools.childEnvironment())
    }

    // MARK: Sync

    /// Fast-forward the clone, then reload. Single-flight: pressing ⌘R twice
    /// does not start two clones.
    func sync() {
        guard syncTask == nil else { return }
        guard let git = gitService else {
            syncState = .failed(needsDeveloperTools
                ? "git needs Apple's Command Line Tools — install them, then sync again."
                : "git was not found — see Settings.")
            return
        }

        syncLog = []
        syncState = .running(paths.cloneExists ? "Fetching…" : "Cloning the wiki…")

        syncTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await git.sync(clone: paths.clone, remote: AppPaths.remoteURL) { line in
                Task { @MainActor [weak self] in self?.appendSyncLine(line) }
            }
            switch outcome {
            case .offline:
                // Reading is unaffected — the whole point of a local clone —
                // so this is a note, not an alarm. Still reload, in case this
                // is the first launch after a manual pull.
                await loadLibrary()
                syncState = .failed(outcome.summary)
            case .failed(let message):
                syncState = .failed(message)
                warn(message)
            default:
                syncState = .running("Indexing…")
                await loadLibrary()
                syncState = .succeeded(outcome.summary)
                warnings.removeAll { $0.contains("Fast-forward failed") }
                scheduleStatusReset()
            }
            syncTask = nil
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

    // MARK: Navigation

    func openHome() {
        guard let index else { return }
        if index.pages["index.md"] != nil {
            open(.page(path: "index.md", anchor: nil))
        } else if let first = index.allPages.sorted(by: { $0.path < $1.path }).first {
            open(.page(path: first.path, anchor: nil))
        }
    }

    func open(_ newLocation: Location, recordHistory: Bool = true) {
        // A page the clone does not have is not somewhere the reader can be.
        // Without this the chrome moved — title, selection, history — while
        // the web view kept the previous page.
        if case .page(let path, _) = newLocation, index?.pages[path] == nil { return }

        guard history.visit(newLocation, recording: recordHistory) else {
            // Not a move. The one case worth acting on: the same page, same
            // anchor, asked for again — jump back to the anchor.
            if newLocation == location, case .page(_, let anchor) = newLocation, let anchor {
                webController.scrollTo(anchor: anchor)
            }
            return
        }
        reveal(newLocation)
        renderCurrent()
    }

    /// Select the page in the sidebar and open the folder that holds it.
    private func reveal(_ location: Location) {
        switch location {
        case .page(let path, _):
            sidebarSelection = path
            expandedFolders.formUnion(
                PageTreeNode.ancestors(of: path, excluding: Self.kindsOutsideTree))
        case .folder(let slug):
            expandedFolders.insert(slug)
            // A folder listing is not one of the tree's rows, so leaving the
            // previous page highlighted claims you are somewhere you are not.
            sidebarSelection = nil
        case .empty:
            sidebarSelection = nil
        }
    }

    func openPage(_ path: String, anchor: String? = nil) {
        open(.page(path: path, anchor: anchor))
    }

    func navigate(to destination: CCwikiURL.Destination) {
        switch destination {
        case .page(let path, let anchor): open(.page(path: path, anchor: anchor))
        case .folder(let slug): open(.folder(slug: slug))
        case .asset(let path):
            NSWorkspace.shared.open(paths.content.appending(path: path))
        case .shell:
            break
        }
    }

    func goBack() {
        guard let previous = history.goBack() else { return }
        reveal(previous)
        renderCurrent()
    }

    func goForward() {
        guard let next = history.goForward() else { return }
        reveal(next)
        renderCurrent()
    }

    private func renderCurrent(preservingScroll: Bool = false) {
        guard let index else { return }
        let renderer = PageRenderer(index: index, hiddenPaths: unlistedPaths)
        var notices: [RenderRequest.Notice] = []
        if macros.isEmpty {
            notices.append(RenderRequest.Notice(
                level: "warning",
                text: "Custom LaTeX macros could not be loaded, so site-specific commands "
                    + "such as \\calA will not render."))
        }

        var request: RenderRequest
        switch location {
        case .page(let path, let anchor):
            guard let page = index.pages[path] else { return }
            request = renderer.request(for: page, anchor: anchor, notices: notices)
        case .folder(let slug):
            request = renderer.folderRequest(
                slug: slug, hidingStubs: hidesStubs, notices: notices)
        case .empty:
            return
        }
        // The table rides along on every render, so a clone that arrived
        // after launch, or a pull that changed `macros.ts`, takes effect on
        // the next page rather than the next launch.
        request.macros = macros.macros
        request.preservesScroll = preservingScroll
        webController.render(request)
    }

    // MARK: Text size

    func makeTextBigger() {
        webController.setPageZoom(webController.pageZoom * WebController.zoomStep)
    }

    func makeTextSmaller() {
        webController.setPageZoom(webController.pageZoom / WebController.zoomStep)
    }

    func resetTextSize() {
        webController.setPageZoom(1)
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

    var currentSiteURL: URL? {
        switch location {
        case .page(let path, let anchor):
            guard let page = index?.pages[path] else { return nil }
            return Self.siteURL(slug: page.slug, anchor: anchor)
        case .folder(let slug):
            return Self.siteURL(slug: slug + "/")
        case .empty:
            return nil
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Current page accessors

    var currentPage: WikiPage? {
        guard let path = location.path else { return nil }
        return index?.pages[path]
    }

    var currentBacklinks: [WikiIndex.Backlink] {
        guard let path = location.path else { return [] }
        return backlinks[path] ?? []
    }

    /// What the Relations inspector shows for the page being read.
    ///
    /// Computed rather than cached: the busiest node in the corpus has 32
    /// relations, so this is trivial work, and a cache holding a snapshot of
    /// the manifest is exactly the shape `SWIFTUI-RULES.md` §3.1 warns about.
    var currentRelations: PageRelations {
        guard let path = location.path else { return .empty }
        return PageRelations(path: path, manifest: relations)
    }

    /// Navigate to a manifest node. A variant is a *section*, so this resolves
    /// to its host page plus an anchor rather than to a page of its own.
    func openRelationObject(_ objectID: String) {
        guard let destination = relationLabels.destination(objectID),
              index?.pages[destination.path] != nil
        else { return }
        openPage(destination.path, anchor: destination.anchor)
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
            searchError = nil
            return
        }
        searchTask = Task { [weak self] in
            // Debounce: the index is fast but re-querying on every keystroke
            // still makes the list flicker.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            do {
                let hits = try await searchIndex.search(query)
                guard !Task.isCancelled else { return }
                searchResults = hits
                searchError = nil
            } catch {
                searchResults = []
                searchError = error.localizedDescription
            }
        }
    }

    func refreshQuickSwitcher() {
        guard let index else {
            quickSwitcherResults = []
            return
        }
        quickSwitcherResults = index.quickSwitch(
            quickSwitcherQuery, excluding: unlistedPaths)
    }

    func presentQuickSwitcher() {
        quickSwitcherQuery = ""
        refreshQuickSwitcher()
        quickSwitcherPresented = true
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

    /// The pages that cite the page being read.
    ///
    /// Shown at the top of the sidebar for a reference, where the tree has
    /// nothing to say: a citation is reached by following a link, and the
    /// question you have on arriving is "what brought me here, and what else
    /// uses this".
    var citingPages: [WikiIndex.Backlink] {
        guard let page = currentPage, page.kind == .reference else { return [] }
        return currentBacklinks
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
        let tools = tools
        Task { @MainActor in
            isGitHubAuthenticated = await GitHubAuth.isAuthenticated(tools: tools)
            await refreshPushCapability()
        }
    }

    private func refreshPushCapability() async {
        guard let git = gitService else {
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

    func rebuildSearchIndex() {
        guard let index else { return }
        let pages = index.allPages
        let searchIndex = self.searchIndex
        Task.detached(priority: .userInitiated) {
            await searchIndex.reset()
            try? await searchIndex.rebuild(pages: pages)
        }
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

    func submitIngestion(source: IngestSubmission.Source?, pdf: URL?, notes: String) {
        let submission = IngestSubmission(
            kind: pdf != nil ? .pdf : .url,
            source: source,
            localPDF: pdf,
            notes: notes,
            submittedAt: Date())

        let job = IngestJob(submission: submission, paths: paths)
        jobs.insert(job, at: 0)
        requestJobsWindow()
        start(job)
    }

    /// Jobs from earlier launches, from the records beside their transcripts.
    ///
    /// A job that was running when the app last quit comes back as failed
    /// and says why; its worktree, if any, shows up under "Left Behind".
    func loadJobHistory() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: paths.logs, includingPropertiesForKeys: nil)
        else { return }
        let decoder = JSONDecoder()
        let known = Set(jobs.map(\.id))
        var restored: [IngestJob] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(JobRecord.self, from: data),
                  !known.contains(record.id)
            else { continue }
            restored.append(IngestJob(restoring: record, paths: paths))
        }
        restored.sort { $0.submission.submittedAt > $1.submission.submittedAt }
        jobs.append(contentsOf: restored)
    }

    /// Forget the finished jobs. Their transcripts stay on disk; only the
    /// records that bring them back at launch go.
    func clearFinishedJobs() {
        for job in jobs where job.state.isTerminal {
            try? FileManager.default.removeItem(at: job.recordFile)
        }
        jobs.removeAll { $0.state.isTerminal }
    }

    var hasFinishedJobs: Bool { jobs.contains { $0.state.isTerminal } }

    /// The same submission again, as a new job. The common case after a
    /// failure that was the machine's fault rather than the paper's.
    func runAgain(_ job: IngestJob) {
        submitIngestion(
            source: job.submission.source,
            pdf: job.submission.localPDF,
            notes: job.submission.notes)
    }

    private func start(_ job: IngestJob) {
        guard let git = gitService else {
            job.setState(.failed("git was not found."))
            return
        }
        let runner = IngestJobRunner(paths: paths, tools: tools, git: git, index: index)
        job.task = Task { @MainActor in
            await runner.run(job)
            // A job that changed the wiki has changed nothing locally — the PR
            // lives on GitHub — but the branch and worktree bookkeeping moved,
            // so refresh what we know about strays. In a fresh task: a
            // cancelled job's task would kill the `git worktree list` it
            // needs and report no strays at all.
            await Task { @MainActor in await self.refreshOrphanedWorktrees() }.value
        }
    }

    // MARK: Update check

    /// The daily check, from the launch task. Silent whatever happens: an
    /// update is a note in the status bar, and a failure is nothing at all.
    func checkForUpdatesIfDue() async {
        guard checksForUpdates, !UpdateChecker.isDevelopmentVersion(appVersion) else { return }
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < Self.updateInterval {
            return
        }
        _ = await performUpdateCheck()
    }

    /// `nil` when GitHub could not be reached or understood. The time of the
    /// check is recorded only when an answer came back.
    private func performUpdateCheck() async -> UpdateChecker.Outcome? {
        guard !isCheckingForUpdates else { return nil }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        guard let outcome = try? await UpdateChecker.check(currentVersion: appVersion) else {
            return nil
        }
        lastUpdateCheck = Date()
        CCwikiSettings.lastUpdateCheck = lastUpdateCheck
        warnings.removeAll { $0.hasPrefix(Self.updateWarningPrefix) }
        if case .available(let release) = outcome {
            availableUpdate = release
            warn(Self.updateWarningPrefix + "CCwiki \(release.version) is available. "
                + "Choose CCwiki > Check for Updates… to get it.")
        } else {
            availableUpdate = nil
        }
        return outcome
    }

    /// The menu item and the Settings button. The person asked, so this one
    /// answers with an alert either way.
    func checkForUpdates() {
        Task { @MainActor in
            let alert = NSAlert()
            let version = appVersion

            if UpdateChecker.isDevelopmentVersion(version) {
                alert.messageText = "This is a development build."
                alert.informativeText = "Version \(version) was not made by make dist, so there "
                    + "is no release to compare it against."
                alert.runModal()
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
                alert.messageText = "CCwiki \(release.version) is available."
                alert.informativeText = "You have \(version). The download is on the release "
                    + "page; replace the app in your Applications folder with the new one."
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
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

    /// Stop every job that has not finished. Called on quit, so no agent
    /// outlives the window it was reporting to: left alone it would keep
    /// working in the worktree and could open a PR nobody is watching.
    func cancelActiveJobs() {
        for job in jobs where !job.state.isTerminal { job.cancel() }
        Subprocess.terminateAll()
    }

    func refreshOrphanedWorktrees() async {
        guard let git = gitService else { return }
        let runner = IngestJobRunner(paths: paths, tools: tools, git: git, index: index)
        let known = Set(jobs.filter { !$0.state.isTerminal }.map(\.id))
        orphanedWorktrees = await runner.orphanedWorktrees(knownJobIDs: known).map(\.path)
    }

    func pruneOrphan(_ path: String) {
        guard let git = gitService else { return }
        let runner = IngestJobRunner(paths: paths, tools: tools, git: git, index: index)
        Task { @MainActor in
            await runner.prune(worktreeAt: path)
            await refreshOrphanedWorktrees()
        }
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
