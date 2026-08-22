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
    private(set) var isGitHubAuthenticated = false
    private(set) var canPushToRemote = false
    private(set) var vendorManifest: String?

    /// Hide stub pages in the sidebar and on folder listings. Persisted.
    var hidesStubs: Bool = CCwikiSettings.hidesStubs {
        didSet {
            guard hidesStubs != oldValue else { return }
            CCwikiSettings.hidesStubs = hidesStubs
            // The tree recomputes on read; the rendered folder page does not.
            webController.invalidate()
            renderCurrent()
        }
    }

    // MARK: Library

    /// The parsed wiki. `nil` until the first load finishes.
    private(set) var index: WikiIndex?
    private(set) var macros = MacroTable.empty
    private(set) var backlinks: [String: [WikiIndex.Backlink]] = [:]
    private(set) var modifiedDates: [String: Date] = [:]
    private(set) var headRevision: String?

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

    private(set) var location: Location = .empty
    private var back: [Location] = []
    private var forward: [Location] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

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
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .outline: "list.bullet.indent"
            case .backlinks: "arrow.turn.up.left"
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

    // MARK: Reader

    let webController: WebController

    // MARK: Diagnostics

    /// Things the user should know but that must not stop them reading:
    /// a failed pull, a macro table that would not parse, missing tooling.
    private(set) var warnings: [String] = []

    // MARK: Init

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.searchIndex = SearchIndex(path: paths.searchDatabase)
        // The macro table has to be known before the web view is built: the
        // macros go in as a documentStart user script, which cannot be changed
        // afterwards without recreating the configuration.
        let macros = MacroTable.load(cloneRoot: paths.clone)
        self.macros = macros
        self.webController = WebController(paths: paths, macros: macros)

        try? paths.createDirectories()
        toolOverrides = CCwikiSettings.toolOverrides()
        tools = ToolLocator(overrides: toolOverrides)
        tools.locateAll()
        isGitHubAuthenticated = GitHubAuth.isAuthenticated(tools: tools)
        vendorManifest = try? String(
            contentsOf: paths.webRoot.appending(path: "vendor/VENDOR.txt"), encoding: .utf8)

        webController.onNavigate = { [weak self] destination, _ in
            self?.navigate(to: destination)
        }

        if let missing = tools.missingForReading.first {
            warnings.append(
                "\(missing.rawValue) was not found. CCwiki needs it for \(missing.purpose).")
        }
        if macros.isEmpty, let diagnostic = macros.diagnostic {
            warnings.append("Custom LaTeX macros unavailable — \(diagnostic.message) "
                + "Math will render, but site-specific commands will show as errors.")
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
        let loaded = await Task.detached(priority: .userInitiated) {
            let index = WikiIndex.build(contentRoot: contentRoot)
            return (index, index.backlinkMap())
        }.value

        index = loaded.0
        backlinks = loaded.1
        macros = MacroTable.load(cloneRoot: paths.clone)

        let git = gitService
        if let git {
            modifiedDates = await git.modifiedDates(in: paths.clone)
            headRevision = await git.head(in: paths.clone)
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
                    self.warnings.append(
                        "Search index could not be rebuilt: \(error.localizedDescription)")
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
        if !orphanedWorktrees.isEmpty {
            warnings.append(
                "\(orphanedWorktrees.count) worktree(s) left over from an interrupted job. "
                + "Open the jobs window (⇧⌘J) to prune them.")
        }

        // Re-render whatever is on screen, since the file may have changed.
        webController.invalidate()
        if case .empty = location { openHome() } else { renderCurrent() }
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
            syncState = .failed("git was not found — see Settings.")
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
                warnings.append(message)
            default:
                syncState = .running("Indexing…")
                await loadLibrary()
                syncState = .succeeded(outcome.summary)
                warnings.removeAll { $0.contains("Fast-forward failed") }
            }
            syncTask = nil
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
        guard newLocation != location else {
            if case .page(_, let anchor) = newLocation, let anchor {
                webController.scrollTo(anchor: anchor)
            }
            return
        }
        if recordHistory, location != .empty {
            back.append(location)
            forward.removeAll()
            if back.count > 100 { back.removeFirst() }
        }
        location = newLocation
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
        guard let previous = back.popLast() else { return }
        forward.append(location)
        location = previous
        reveal(previous)
        renderCurrent()
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(location)
        location = next
        reveal(next)
        renderCurrent()
    }

    private func renderCurrent() {
        guard let index else { return }
        let renderer = PageRenderer(index: index)
        var notices: [RenderRequest.Notice] = []
        if macros.isEmpty {
            notices.append(RenderRequest.Notice(
                level: "warning",
                text: "Custom LaTeX macros could not be loaded, so site-specific commands "
                    + "such as \\calA will not render."))
        }

        switch location {
        case .page(let path, let anchor):
            guard let page = index.pages[path] else { return }
            webController.render(renderer.request(for: page, anchor: anchor, notices: notices))
        case .folder(let slug):
            webController.render(renderer.folderRequest(
                slug: slug, hidingStubs: hidesStubs, notices: notices))
        case .empty:
            break
        }
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
        quickSwitcherResults = index.quickSwitch(quickSwitcherQuery)
    }

    func presentQuickSwitcher() {
        quickSwitcherQuery = ""
        refreshQuickSwitcher()
        quickSwitcherPresented = true
    }

    // MARK: Page tree

    /// Kinds the sidebar tree leaves out. See `PageTreeNode.build`.
    static let kindsOutsideTree: Set<PageKind> = [.reference]

    /// The sidebar's directory tree, mirroring the repo minus the references.
    func pageTree() -> [PageTreeNode] {
        guard let index else { return [] }
        return PageTreeNode.build(
            pages: index.allPages.filter { !hidesStubs || $0.status != .stub },
            excluding: Self.kindsOutsideTree)
    }

    var referenceCount: Int {
        index?.allPages.count {
            $0.kind == .reference && (!hidesStubs || $0.status != .stub)
        } ?? 0
    }

    /// Stubs currently being hidden, so the UI can say so rather than quietly
    /// showing a shorter list than the repo has.
    var hiddenStubCount: Int {
        guard hidesStubs, let index else { return 0 }
        return index.allPages.count { $0.status == .stub }
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
        tools = ToolLocator(overrides: toolOverrides)
        tools.locateAll()
        recheckGitHubAuth()
        warnings.removeAll { $0.contains("was not found") }
        if let missing = tools.missingForReading.first {
            warnings.append(
                "\(missing.rawValue) was not found. CCwiki needs it for \(missing.purpose).")
        }
    }

    func recheckGitHubAuth() {
        GitHubAuth.invalidate()
        isGitHubAuthenticated = GitHubAuth.isAuthenticated(tools: tools)
        Task { @MainActor in await refreshPushCapability() }
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
            // so refresh what we know about strays.
            await refreshOrphanedWorktrees()
        }
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
