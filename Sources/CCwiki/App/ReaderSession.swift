import AppKit
import Foundation
import Observation

/// What one reader window shows: where it is and how it got there, its web
/// view, its sidebar and inspector, and its sheets
/// (plans/reader-comforts.md §1.2).
///
/// Everything the windows share — the wiki, the search index and its
/// queries, jobs, sync, settings — stays in `AppModel`, which the session
/// reads through `model`. A view inside a reader window reads its own
/// window's session, never "the active one": two windows side by side show
/// different pages, and each inspector follows its own.
///
/// One per reader window or tab. The model keeps them by window, and the
/// window's `ReaderWindowView` claims its own, installs it and starts it
/// (§1.3). The views of a reader window find it in the environment,
/// `@Environment(ReaderSession.self)`, and the menu bar as
/// `FocusedValues.readerSession`.
@MainActor
@Observable
final class ReaderSession: Identifiable {

    typealias Location = AppModel.Location

    let id: UUID
    /// App-wide state. It owns the sessions and outlives every one of them.
    unowned let model: AppModel
    /// This window's web view and what it reported. One per session: two
    /// windows never share a page.
    let webController: WebController

    // MARK: Navigation

    /// Where the reader is and how it got there. The rules live in
    /// `NavigationHistory` so they can be tested without a web view.
    private(set) var history = NavigationHistory()

    var location: Location { history.current }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// The directory the sidebar has expanded to, so selection survives a reload.
    var sidebarSelection: String?
    /// Which sidebar folders are open. Opening a page from a link, the quick
    /// switcher or search reveals its folder, so the sidebar always shows where
    /// you are rather than silently disagreeing with the reader.
    var expandedFolders: Set<String> = Set(CCwikiSettings.expandedFolders) {
        didSet {
            guard expandedFolders != oldValue else { return }
            CCwikiSettings.expandedFolders = expandedFolders.sorted()
        }
    }
    /// Both persisted: the inspector comes back as it was left.
    var inspectorTab: AppModel.InspectorTab =
        CCwikiSettings.inspectorTab.flatMap(AppModel.InspectorTab.init(rawValue:)) ?? .outline {
        didSet { CCwikiSettings.inspectorTab = inspectorTab.rawValue }
    }
    var showInspector: Bool = CCwikiSettings.showsInspector {
        didSet { CCwikiSettings.showsInspector = showInspector }
    }

    /// ⌥⌘1–3: straight to a tab, opening the inspector if it was closed.
    func showInspectorTab(_ tab: AppModel.InspectorTab) {
        inspectorTab = tab
        showInspector = true
    }

    // MARK: Sheets

    /// The sheets this window shows. Their queries are the model's, so each
    /// palette reopens on the last search whichever window it is in.
    var quickSwitcherPresented = false
    var searchPresented = false
    var referenceSearchPresented = false
    var grepPresented = false
    /// The sync log sheet. Every failure message ends "see the sync log", so
    /// there has to be somewhere to see it.
    var syncLogPresented = false

    /// Set by `openSearchResult` for the render it triggers, then cleared.
    @ObservationIgnored private var pendingFind: [String]?
    /// Set for the render that shows a restored page where it was being
    /// read, then cleared: the heading it scrolls to in place of the
    /// location's own anchor.
    @ObservationIgnored private var renderAnchor: String?

    // MARK: Window

    /// Its `NSWindow`'s number, for bringing it forward from elsewhere and
    /// for joining a new tab to it. Set by its view, which knows the window.
    @ObservationIgnored var windowNumber: Int?

    // MARK: Starting

    /// Whether `start` has run. A window's view may run its task again, when
    /// a tab is shown again, and must not start the session twice.
    @ObservationIgnored private(set) var isStarted = false
    /// From `start` until the wiki is first there for this session: what the
    /// plan left for the wiki is still to do.
    @ObservationIgnored private var awaitsLibrary = false
    /// Opened once the wiki is there: the plan's choice, or what was asked
    /// for before the session could open it, the latest winning.
    @ObservationIgnored private var pendingLocation: Location?
    /// Found on `pendingLocation` when it opens: the window's `find`.
    @ObservationIgnored private var pendingLocationFind: [String]?
    /// The heading a restored page was being read at, for its first render.
    @ObservationIgnored private var readingPosition: (location: Location, heading: String)?

    // MARK: Init

    init(id: UUID, model: AppModel) {
        self.id = id
        self.model = model
        webController = WebController(
            paths: model.paths, webRoot: model.webRoot, pageZoom: model.pageZoom)

        // Each closure reads the model through `self`, never the `model`
        // parameter: the web view keeps its closures, and the model keeps
        // the session, so capturing the parameter would make a cycle.
        webController.onNavigate = { [weak self] destination, disposition in
            guard let self else { return }
            // ⌘-click: the same page on cryptology.city, in the browser. The
            // app has one reader window, so anywhere but here means the site,
            // until tabs give the other dispositions somewhere to go.
            if disposition != .here, case .page(let path, let anchor) = destination,
               let page = self.model.index?.pages[path],
               let url = AppModel.siteURL(slug: page.slug, anchor: anchor) {
                NSWorkspace.shared.open(url)
                return
            }
            navigate(to: destination)
        }
        webController.onReady = { [weak self] in
            self?.renderCurrent()
        }
        webController.siteURLProvider = { [weak self] in
            self?.currentSiteURL
        }
        // "Explore From This Page…" in the reader's context menu, which is
        // AppKit: it asks for the question, and hands it back to `explore`.
        webController.exploreHere = { [weak self] in
            self?.currentPageExplorerQuery
        }
        webController.onExplore = { [weak self] query in
            self?.model.explore(query)
        }
    }

    // MARK: Starting

    /// Begin as `plan` says (§1.7). Idempotent: a second call does nothing.
    ///
    /// A restored history is put back at once, and the launch document is
    /// shown over it, since neither needs the wiki. The rest waits for the
    /// wiki to load (`libraryDidLoad`), or happens now if it already has.
    /// `readingAnchor` is the heading the restored page was being read at.
    func start(_ plan: SessionStartPlan, readingAnchor: String?) {
        guard !isStarted else { return }
        isStarted = true
        history = plan.history
        if let path = location.path { sidebarSelection = path }
        if let readingAnchor, plan.showsAtOnce == nil, location != .empty {
            readingPosition = (location: location, heading: readingAnchor)
        }
        // Asked for before the session started, so after everything the
        // plan knows of: it wins.
        if pendingLocation == nil, let opening = plan.opensOnLoad {
            pendingLocation = opening
            pendingLocationFind = plan.find
        }
        awaitsLibrary = true
        if let document = plan.showsAtOnce { open(document) }
        if model.index != nil { openWhatWaited() }
    }

    /// What the plan left for the wiki, done the first time it is there. A
    /// restored history forgets the pages the wiki no longer has and shows
    /// its page where it was being read. A location asked for meanwhile then
    /// opens, and with nothing on screen, Home.
    private func openWhatWaited() {
        guard awaitsLibrary, let index = model.index else { return }
        awaitsLibrary = false
        history = history.pruned { location in
            location.path.map { index.pages[$0] != nil } ?? true
        }
        if let path = location.path { sidebarSelection = path }

        let shown = location
        if let pending = pendingLocation {
            pendingLocation = nil
            pendingFind = pendingLocationFind
            pendingLocationFind = nil
            open(pending)
            // Consumed by the render `open` did; if it did not render (a
            // page the wiki no longer has), it must not linger.
            pendingFind = nil
        }
        if location == .empty {
            // What the plan asks for when it has nothing else
            // (`opensHomeOnLoad`), and where an opening or a last page the
            // wiki no longer has falls back to.
            openHome()
        } else if location == shown {
            // Nothing new opened: render what was restored, or shown before
            // the wiki was there, now that its links resolve.
            webController.invalidate()
            if let position = readingPosition, position.location == location {
                renderAnchor = position.heading
            }
            renderCurrent(preservingScroll: location.isDocument)
            renderAnchor = nil
        }
        readingPosition = nil
    }

    // MARK: What the model tells it

    /// What a load means for the reader: re-render what is on screen, since
    /// the file may have changed, keeping the reader's place, since it
    /// usually has not. The first load also does what the session's start
    /// left for the wiki. A session that has not started waits for its
    /// start, which does the same.
    func libraryDidLoad(_ update: LibraryUpdate) {
        guard isStarted else { return }
        if awaitsLibrary {
            openWhatWaited()
        } else if case .empty = location {
            openHome()
        } else if update.requiresRerender(of: location) {
            webController.invalidate()
            renderCurrent(preservingScroll: true)
        }
    }

    /// A preference that changes what a page renders to changed: render it
    /// again where the reader is.
    func preferencesDidChange() {
        webController.invalidate()
        renderCurrent(preservingScroll: true)
    }

    // MARK: The app's own pages

    func showWelcome() {
        open(.document(.welcome))
    }

    /// Every release's notes, from the Help menu.
    func showWhatsNew() {
        model.whatsNewSince = nil
        webController.invalidate()
        if location == .document(.whatsNew) { renderCurrent() } else { open(.document(.whatsNew)) }
    }

    // MARK: Opening pages

    func openHome() {
        guard let index = model.index else { return }
        if index.pages["index.md"] != nil {
            open(.page(path: "index.md", anchor: nil))
        } else if let first = index.allPages.sorted(by: { $0.path < $1.path }).first {
            open(.page(path: first.path, anchor: nil))
        }
    }

    func open(_ newLocation: Location, recordHistory: Bool = true) {
        // Before the session starts, what it is asked to open waits, and
        // opens over the plan's own choice (§1.7).
        guard isStarted else {
            pendingLocation = newLocation
            pendingLocationFind = nil
            return
        }
        // A page the clone does not have is not somewhere the reader can be.
        // Without this the chrome moved — title, selection, history — while
        // the web view kept the previous page.
        if case .page(let path, _) = newLocation, model.index?.pages[path] == nil { return }

        guard history.visit(newLocation, recording: recordHistory) else {
            // Not a move. The one case worth acting on: the same page, same
            // anchor, asked for again — jump back to the anchor.
            if newLocation == location, case .page(_, let anchor) = newLocation, let anchor {
                webController.scrollTo(anchor: anchor)
            }
            return
        }
        if case .page(let path, _) = newLocation {
            model.noteVisited(path)
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
                PageTreeNode.ancestors(of: path, excluding: AppModel.kindsOutsideTree))
        case .folder(let slug):
            expandedFolders.insert(slug)
            // A folder listing is not one of the tree's rows, so leaving the
            // previous page highlighted claims you are somewhere you are not.
            sidebarSelection = nil
        case .document, .empty:
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
            NSWorkspace.shared.open(model.paths.content.appending(path: path))
        case .shell:
            break
        }
    }

    func goBack() {
        guard let previous = history.goBack() else { return }
        reveal(previous)
        renderCurrent(restoringScroll: true)
    }

    func goForward() {
        guard let next = history.goForward() else { return }
        reveal(next)
        renderCurrent(restoringScroll: true)
    }

    /// Open a search hit where it matched: at the heading when a section was
    /// the match, otherwise finding the query on the page, so the reader
    /// lands on the match rather than the top of a long page.
    func openSearchResult(_ hit: SearchHit, query: String) {
        // A find would scroll away from the heading the hit is about.
        pendingFind = hit.anchor == nil ? AppModel.findCandidates(for: query) : nil
        openPage(hit.path, anchor: hit.anchor)
        // Consumed by the render `openPage` just did; if it did not render
        // (a page the index lacks), it must not linger for the next one.
        pendingFind = nil
    }

    /// Open a ⇧⌘F hit and find the text on it.
    func openGrepResult(_ hit: TextGrep.Hit, query: String) {
        pendingFind = [query]
        openPage(hit.path)
        pendingFind = nil
    }

    /// Open a reference hit. A paper found by its text is opened with the
    /// query found on it, as ⌘S does; one found by its key, authors, title
    /// or a citing page is opened at the top, where those are.
    func openReferenceResult(_ hit: ReferenceHit, query: String) {
        pendingFind = hit.field == .text
            ? AppModel.findCandidates(for: ReferenceRanker.parse(query).text) : nil
        openPage(hit.path)
        pendingFind = nil
    }

    /// Navigate to a manifest node. A variant is a *section*, so this resolves
    /// to its host page plus an anchor rather than to a page of its own.
    func openRelationObject(_ objectID: String) {
        guard let destination = model.relationLabels.destination(objectID),
              model.index?.pages[destination.path] != nil
        else { return }
        openPage(destination.path, anchor: destination.anchor)
    }

    /// A concept page picked at random: not a stub, not a reference or a
    /// reduction (they are reached through the pages that use them), not
    /// the one on screen. For wandering.
    func openRandomPage() {
        guard let index = model.index else { return }
        let candidates = index.allPages.filter {
            model.isBrowsable($0) && !AppModel.kindsOutsideTree.contains($0.kind)
                && $0.status != .stub && $0.path != location.path
        }
        guard let page = candidates.randomElement() else { return }
        openPage(page.path)
    }

    /// ⌘O. The query is app-wide; the page left out of the list is this
    /// window's (§1.6).
    func presentQuickSwitcher() {
        model.quickSwitcherExcludedPath = location.path
        model.quickSwitcherQuery = ""
        model.refreshQuickSwitcher()
        quickSwitcherPresented = true
    }

    func printCurrentPage() {
        guard location != .empty else { return }
        webController.printPage(title: currentTitle)
    }

    // MARK: Rendering

    func renderCurrent(preservingScroll: Bool = false, restoringScroll: Bool = false) {
        if case .document(let document) = location {
            var request = model.documentRequest(document)
            request.macros = model.macros.macros
            request.preservesScroll = preservingScroll
            request.restoresScroll = restoringScroll
            webController.render(request)
            return
        }
        guard let index = model.index else { return }
        var renderer = PageRenderer(index: index, hiddenPaths: model.unlistedPaths)
        renderer.reportsBrokenLinks = model.showsMaintenanceNotices
        renderer.relations = model.relations
        renderer.relationLabels = model.relationLabels
        renderer.linkPreviews = model.linkPreviews
        renderer.buildsPreviews = model.showsLinkPreviews
        var notices: [RenderRequest.Notice] = []
        if model.macros.isEmpty {
            notices.append(RenderRequest.Notice(
                level: "warning",
                text: "Custom LaTeX macros could not be loaded, so site-specific commands "
                    + "such as \\calA will not render."))
        }

        var request: RenderRequest
        switch location {
        case .page(let path, let anchor):
            guard let page = index.pages[path] else { return }
            request = renderer.request(
                for: page, anchor: renderAnchor ?? anchor, notices: notices)
        case .folder(let slug):
            request = renderer.folderRequest(
                slug: slug, hidingStubs: model.hidesStubs, notices: notices)
        case .document, .empty:
            return
        }
        // The table rides along on every render, so a clone that arrived
        // after launch, or a pull that changed `macros.ts`, takes effect on
        // the next page rather than the next launch.
        request.macros = model.macros.macros
        request.preservesScroll = preservingScroll
        request.restoresScroll = restoringScroll
        webController.render(request, thenFind: pendingFind)
        pendingFind = nil
    }

    // MARK: The page on screen

    var currentPage: WikiPage? {
        guard let path = location.path else { return nil }
        return model.index?.pages[path]
    }

    var currentBacklinks: [WikiIndex.Backlink] {
        guard let path = location.path else { return [] }
        return model.backlinks[path] ?? []
    }

    /// What the Relations inspector shows for the page being read.
    ///
    /// Computed rather than cached: the busiest node in the corpus has 32
    /// relations, so this is trivial work, and a cache holding a snapshot of
    /// the manifest is exactly the shape `SWIFTUI-RULES.md` §3.1 warns about.
    var currentRelations: PageRelations {
        guard let path = location.path else { return .empty }
        return PageRelations(path: path, manifest: model.relations)
    }

    /// The inspector's derived sections for the page being read: what each
    /// of its objects implies, and what implies it, in two or more steps.
    ///
    /// Computed rather than cached, for the reason `currentRelations` gives:
    /// every row is a lookup into closures `Derivation` built at load.
    var currentDerivations: PageDerivations {
        guard let path = location.path else { return .empty }
        return PageDerivations(path: path, manifest: model.relations,
                               derivation: model.derivation, labels: model.relationLabels)
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

    /// The same page on cryptology.city, for "Open on the website" and
    /// "Copy Link".
    var currentSiteURL: URL? {
        switch location {
        case .page(let path, let anchor):
            guard let page = model.index?.pages[path] else { return nil }
            return AppModel.siteURL(slug: page.slug, anchor: anchor)
        case .folder(let slug):
            return AppModel.siteURL(slug: slug + "/")
        case .document, .empty:
            return nil
        }
    }

    /// What the window is showing, as a title: for printing, and anything
    /// else that needs to name the current page.
    var currentTitle: String {
        switch location {
        case .page: currentPage?.displayTitle ?? "CCwiki"
        case .folder(let slug): slug
        case .document(let document): document.title
        case .empty: "CCwiki"
        }
    }

    /// What "Explore From This Page" asks on the page being read: the
    /// section being read when it is an object, so scrolling to *Collision
    /// resistance* and pressing ⌥⇧⌘E asks about CRHF. `nil` disables it.
    var currentPageExplorerQuery: ExplorerQuery? {
        guard case .page(_, let anchor) = location else { return nil }
        let reading = webController.activeHeadingID ?? anchor
        guard var query = ExplorerQuery.seed(
            for: currentRelations.subject, activeAnchor: reading,
            manifest: model.relations, derivation: model.derivation)
        else { return nil }
        query.includesIdealisedModels = model.explorerQuery.includesIdealisedModels
        return query
    }

    /// Whether the page being read has anything to explore. The same test
    /// without the section being read, so a menu's enabled state does not
    /// re-evaluate on every scroll.
    var canExploreCurrentPage: Bool {
        guard location.path != nil else { return false }
        return ExplorerQuery.seed(
            for: currentRelations.subject, activeAnchor: nil,
            manifest: model.relations, derivation: model.derivation) != nil
    }
}
