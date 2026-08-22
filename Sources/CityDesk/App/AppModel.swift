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
        tools.locateAll()

        webController.onNavigate = { [weak self] destination, _ in
            self?.navigate(to: destination)
        }

        if let missing = tools.missingForReading.first {
            warnings.append(
                "\(missing.rawValue) was not found. CityDesk needs it for \(missing.purpose).")
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
            expandedFolders.formUnion(PageTreeNode.ancestors(of: path))
        case .folder(let slug):
            expandedFolders.insert(slug)
        case .empty:
            break
        }
    }

    func openPage(_ path: String, anchor: String? = nil) {
        open(.page(path: path, anchor: anchor))
    }

    func navigate(to destination: CityDeskURL.Destination) {
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
            webController.render(renderer.folderRequest(slug: slug, notices: notices))
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

    /// The sidebar's directory tree, mirroring the repo.
    func pageTree() -> [PageTreeNode] {
        guard let index else { return [] }
        return PageTreeNode.build(pages: index.allPages)
    }
}
