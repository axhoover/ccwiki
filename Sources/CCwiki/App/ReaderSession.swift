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
    ///
    /// The folders and the inspector start as the window changed last left
    /// them, and are written back to the settings for the next new window,
    /// except while a restored window puts its own back (`restoreChrome`).
    var expandedFolders: Set<String> = Set(CCwikiSettings.expandedFolders) {
        didSet {
            guard expandedFolders != oldValue, !isRestoringChrome else { return }
            CCwikiSettings.expandedFolders = expandedFolders.sorted()
        }
    }
    /// Both persisted: the inspector comes back as it was left.
    var inspectorTab: AppModel.InspectorTab =
        CCwikiSettings.inspectorTab.flatMap(AppModel.InspectorTab.init(rawValue:)) ?? .outline {
        didSet {
            guard !isRestoringChrome else { return }
            CCwikiSettings.inspectorTab = inspectorTab.rawValue
        }
    }
    var showInspector: Bool = CCwikiSettings.showsInspector {
        didSet {
            guard !isRestoringChrome else { return }
            CCwikiSettings.showsInspector = showInspector
        }
    }
    @ObservationIgnored private var isRestoringChrome = false

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
    /// Describe a Correction or Open an Issue, about this window's page
    /// (plans/corrections.md §8, §17).
    var correctionSheet: CorrectionSheetRequest?

    /// Set for the render a search hit, or a window opened on one, triggers,
    /// then cleared.
    @ObservationIgnored private var pendingFind: [String]?
    /// Set for the render that shows a restored page where it was being
    /// read, then cleared: the heading it scrolls to in place of the
    /// location's own anchor.
    @ObservationIgnored private var renderAnchor: String?

    // MARK: Window

    /// Its `NSWindow`'s number, for bringing it forward from elsewhere and
    /// for joining a new tab to it. Set by its view, which knows the window.
    @ObservationIgnored var windowNumber: Int?
    /// Its `NSWindow` itself, from the moment its view claims it. A window
    /// has a number only once it has been shown, and the session hears it
    /// for certain only when the window is first key, so a tab restored
    /// behind another has a window but may have no number yet. Weak: the
    /// window holds the view that holds the session.
    @ObservationIgnored weak var hostWindow: NSWindow?

    /// Its window's number as of now, for a new tab to join: the window's
    /// own once it has one, else the last one its view saw.
    var hostWindowNumber: Int? {
        guard let number = hostWindow?.windowNumber, number > 0 else { return windowNumber }
        return number
    }

    /// Opens a page in a new tab or window: `openWindow` is an environment
    /// action, so the window's view builds this from its own and sets it
    /// when it claims the session (§1.4).
    @ObservationIgnored var openInReader: OpenInReaderAction = .none

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
        //
        // A link in the page opens where its click says: here, in a new tab
        // or window, or on cryptology.city, for Open Link on cryptology.city
        // (§1.4). A modified click no longer means the site by itself.
        webController.onNavigate = { [weak self] destination, disposition in
            self?.navigate(to: destination, disposition: disposition)
        }
        webController.opensLinksInTabs = true
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
        // The context menu's corrections group (plans/corrections.md §9),
        // which is AppKit too: whether this page offers it, and the route
        // chosen, with what was selected at the right-click.
        webController.correctionAvailable = { [weak self] in
            self?.canCorrectCurrentPage ?? false
        }
        webController.onCorrect = { [weak self] route, selection in
            self?.beginCorrection(route, selection: selection)
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
        if let readingAnchor, plan.showsAtOnce == nil, location != .empty {
            readingPosition = (location: location, heading: readingAnchor)
        }
        // Asked for before the session started, so after everything the
        // plan knows of: it wins.
        if pendingLocation == nil, let opening = plan.opensOnLoad {
            pendingLocation = opening
            pendingLocationFind = plan.find
        }
        // Before the session waits, so the launch document is part of the
        // plan rather than something asked for since, and a pending
        // location still opens over it.
        if let document = plan.showsAtOnce { open(document) }
        awaitsLibrary = true
        if model.index != nil { openWhatWaited() }
    }

    /// What the plan left for the wiki, done the first time it is there. A
    /// restored history forgets the pages the wiki no longer has and shows
    /// its page where it was being read. A location asked for meanwhile then
    /// opens, and with nothing on screen, Home.
    ///
    /// `superseded`: the reader has asked for a page since, which is about
    /// to open, so only the forgetting is left to do.
    private func openWhatWaited(superseded: Bool = false) {
        guard awaitsLibrary, let index = model.index else { return }
        awaitsLibrary = false
        let position = readingPosition
        readingPosition = nil
        history = history.pruned { location in
            location.path.map { index.pages[$0] != nil } ?? true
        }
        guard !superseded else { return }

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
            // the wiki was there, now that its links resolve. The sidebar
            // selects a restored page now that it has a row for it; its
            // echo of the selection is not a move.
            sidebarSelection = location.path
            webController.invalidate()
            if let position, position.location == location {
                renderAnchor = position.heading
            }
            renderCurrent(preservingScroll: location.isDocument)
            renderAnchor = nil
        }
    }

    // MARK: Restoration

    /// What macOS keeps of this window when it restores it: where it has
    /// been, and how its inspector and sidebar were left (§1.3). Its view
    /// saves it whenever it changes; the reading position is saved apart, so
    /// scrolling does not encode the history again.
    var restorationState: ReaderSessionState {
        ReaderSessionState(
            history: history, inspectorTab: inspectorTab.rawValue,
            showsInspector: showInspector, expandedFolders: expandedFolders.sorted())
    }

    /// A restored window's inspector and folders, as it left them, before
    /// it starts. Not written to the settings: restoring a window is not
    /// leaving it, and a new window starts as the window changed last.
    func restoreChrome(_ state: ReaderSessionState) {
        isRestoringChrome = true
        defer { isRestoringChrome = false }
        if let tab = AppModel.InspectorTab(rawValue: state.inspectorTab) { inspectorTab = tab }
        showInspector = state.showsInspector
        expandedFolders = Set(state.expandedFolders)
    }

    // MARK: Links from outside

    /// A URL from outside, given to this window, which SwiftUI chose and
    /// brought forward: a PDF from Finder or the Dock, for an ingestion job
    /// (Info.plist declares the type), or a ccwiki:// link from anywhere
    /// (Info.plist declares the scheme; CCwiki Dev's is ccwiki-dev://, read
    /// here as ccwiki://). A link that arrives before the wiki is loaded,
    /// as one that launches the app does, opens once it is.
    func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "pdf" else { return }
            // While a sheet is up it is not handed another PDF, as a drop
            // on any window is refused (§1.3): its window comes forward. The
            // sheet up now reads no PDF, so one left for it would wait and
            // join the next, unrelated, ingestion.
            guard model.ingestSheetTarget == nil else {
                model.requestIngestSheet(in: id)
                return
            }
            guard let staged = try? model.stagePDF(from: url) else { return }
            model.pendingDroppedPDF = staged
            model.requestIngestSheet(in: id)
            model.requestJobsWindow()
        } else if let destination = CCwikiURL.destination(
            of: CCwikiURL.internalString(for: url)) {
            navigate(to: destination)
        }
    }

    // MARK: What the model tells it

    /// What a load means for this window: its page renders again, keeping
    /// the reader's place, only if the load changed something that page
    /// shows (`LibraryUpdate.requiresRerender`, §3.6), or, in a snapshot,
    /// moved the revision it was rendered at. Its history forgets the pages
    /// the load took away, and a page on screen that went gives way to the
    /// nearest one left on Back (`SessionReloadPlan`). The first load also
    /// does what the session's start left for the wiki; a session that has
    /// not started waits for its start, which does the same.
    func libraryDidLoad(_ update: LibraryUpdate) {
        guard isStarted else { return }
        if awaitsLibrary {
            openWhatWaited()
            return
        }
        let index = model.index
        let plan = SessionReloadPlan.plan(
            history: history,
            exists: { path in index.map { $0.pages[path] != nil } ?? true },
            changed: { update.requiresRerender(of: $0) },
            revisionGone: SessionReloadPlan.outlivesRevision(
                store: model.paths.wikiStore,
                rendered: webController.lastRenderedRevision, head: model.headRevision))
        if plan.history != history { history = plan.history }
        switch plan.render {
        case .unchanged:
            break
        case .home:
            openHome()
        case .current:
            reveal(location)
            webController.invalidate()
            renderCurrent(restoringScroll: true)
        case .inPlace:
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
        // Until the session has started and the wiki is there, a page or a
        // folder waits, the latest asked for winning, and opens over the
        // plan's own choice once it can (§1.7): a ccwiki:// link that
        // launches the app still lands. The app's own pages need no wiki.
        guard isStarted, model.index != nil || newLocation.isDocument else {
            if !isShowing(newLocation) {
                pendingLocation = newLocation
                // A search hit that waits still lands on its match.
                pendingLocationFind = pendingFind
            }
            return
        }
        // Asked for once the window has started, so after everything its
        // plan knows of: the plan's own choice gives way. If the wiki is
        // there and its load has yet to say so, a restored history forgets
        // the pages the wiki no longer has before this joins it.
        if awaitsLibrary, !isShowing(newLocation) {
            pendingLocation = nil
            pendingLocationFind = nil
            openWhatWaited(superseded: true)
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

    /// Whether asking for `location` is not a move: it is what is on
    /// screen, or names the page on screen without an anchor, as the
    /// sidebar does when it selects that page's row. The same test as
    /// `NavigationHistory.visit`.
    private func isShowing(_ location: Location) -> Bool {
        if location == self.location { return true }
        if case .page(let path, nil) = location { return path == self.location.path }
        return false
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

    /// Open `location` where `disposition` says (§1.4): here, on
    /// cryptology.city, or in a new tab or window of its own, which the
    /// window's view opens (`openInReader`). `find` is found on the page once
    /// it renders, so a search hit lands on its match wherever it opens.
    ///
    /// What a SwiftUI row calls with `LinkDisposition.current`, and what a
    /// link in the page comes to through `navigate(to:disposition:)`.
    func open(_ location: Location, _ disposition: LinkDisposition, find: [String]? = nil) {
        switch disposition {
        case .here:
            pendingFind = find
            open(location)
            // Consumed by the render `open` did, or kept with a location
            // that waits for the wiki. If neither (a page the wiki lacks),
            // it must not linger for the next render.
            pendingFind = nil
        case .onSite:
            if let url = siteURL(for: location) { NSWorkspace.shared.open(url) }
        case .newTab, .newWindow:
            openInReader(location, disposition, find: find)
        }
    }

    func openPage(_ path: String, anchor: String? = nil) {
        open(.page(path: path, anchor: anchor))
    }

    /// Follow a link: one in the page, whose click or context menu said
    /// where (`WebController.onNavigate`), or a ccwiki:// link from outside,
    /// which opens here. An asset opens in its own app wherever it was asked
    /// for, if it is a file of the wiki (`CCwikiURL.assetFile`).
    func navigate(to destination: CCwikiURL.Destination, disposition: LinkDisposition = .here) {
        switch destination {
        case .page(let path, let anchor): open(.page(path: path, anchor: anchor), disposition)
        case .folder(let slug): open(.folder(slug: slug), disposition)
        case .asset(let path):
            if let file = CCwikiURL.assetFile(path, in: model.paths.content) {
                NSWorkspace.shared.open(file)
            }
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
    /// lands on the match rather than the top of a long page. In a new tab
    /// too: the tab finds it once its page renders.
    func openSearchResult(
        _ hit: SearchHit, query: String, disposition: LinkDisposition = .here
    ) {
        // A find would scroll away from the heading the hit is about.
        let find = hit.anchor == nil ? AppModel.findCandidates(for: query) : nil
        open(.page(path: hit.path, anchor: hit.anchor), disposition, find: find)
    }

    /// Open a ⇧⌘F hit and find the text on it.
    func openGrepResult(
        _ hit: TextGrep.Hit, query: String, disposition: LinkDisposition = .here
    ) {
        open(.page(path: hit.path, anchor: nil), disposition, find: [query])
    }

    /// Open a reference hit. A paper found by its text is opened with the
    /// query found on it, as ⌘S does; one found by its key, authors, title
    /// or a citing page is opened at the top, where those are.
    func openReferenceResult(
        _ hit: ReferenceHit, query: String, disposition: LinkDisposition = .here
    ) {
        let find = hit.field == .text
            ? AppModel.findCandidates(for: ReferenceRanker.parse(query).text) : nil
        open(.page(path: hit.path, anchor: nil), disposition, find: find)
    }

    /// Navigate to a manifest node. A variant is a *section*, so this resolves
    /// to its host page plus an anchor rather than to a page of its own.
    func openRelationObject(_ objectID: String, disposition: LinkDisposition = .here) {
        guard let destination = model.relationLabels.destination(objectID),
              model.index?.pages[destination.path] != nil
        else { return }
        open(.page(path: destination.path, anchor: destination.anchor), disposition)
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
        // The commit this render shows. A correction is built at it, never
        // at whatever HEAD is by the time someone clicks (corrections §3.5).
        request.revision = model.headRevision
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
    var currentSiteURL: URL? { siteURL(for: location) }

    /// Where `location` is on cryptology.city. The app's own pages are not
    /// there.
    private func siteURL(for location: Location) -> URL? {
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
