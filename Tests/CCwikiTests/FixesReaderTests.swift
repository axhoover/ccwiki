import Foundation
import Testing
@testable import CCwiki

/// The reader's link, load and navigation fixes: a link that climbs out of
/// the wiki, the shell replaced by a page's raw HTML, Back and Forward on
/// one page, a load that takes away a page on Back or on screen, a window
/// opened on a page while the launch document is due, and the link menu's
/// Open Link and its tab items outside a reader.
@Suite struct FixesReaderTests {

    private typealias Location = AppModel.Location

    // MARK: Links out of the wiki

    @Test("a ccwiki:// link with a . or .. segment, encoded or not, is refused")
    func traversalRefused() {
        let links = [
            "ccwiki://wiki/asset/..%2F..%2F..%2F..%2FApplications%2FCalculator.app",
            "ccwiki://wiki/asset/../../System/Applications/Utilities/Terminal.app",
            "ccwiki://wiki/asset/Files%2F..%2F..%2Fsecret.txt",
            "ccwiki://wiki/asset/.%2FFiles%2Fa.png",
            "ccwiki://wiki/page/..%2Fother.md",
            "ccwiki://wiki/folder/Primitives%2F..%2F..",
        ]
        for link in links {
            #expect(CCwikiURL.destination(of: link) == nil, "\(link)")
        }
    }

    @Test("a link the app makes still reads as it did")
    func ordinaryLinksRead() {
        #expect(CCwikiURL.destination(of: CCwikiURL.asset(path: "Files/Minicrypt.png"))
            == .asset(path: "Files/Minicrypt.png"))
        #expect(CCwikiURL.destination(of: CCwikiURL.page(path: "Primitives/prf.md", anchor: "syntax"))
            == .page(path: "Primitives/prf.md", anchor: "syntax"))
        #expect(CCwikiURL.destination(of: CCwikiURL.folder(slug: "Primitives"))
            == .folder(slug: "Primitives"))
        // A file name with dots in it is not a dot segment.
        #expect(CCwikiURL.destination(of: CCwikiURL.asset(path: "Files/a..b.pdf"))
            == .asset(path: "Files/a..b.pdf"))
    }

    @Test("an asset opens only if it is a file in the wiki, symbolic links resolved")
    func assetFileContained() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ccwiki-asset-test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let content = root.appending(path: "content")
        try fileManager.createDirectory(
            at: content.appending(path: "Files"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: content.appending(path: "Files/a.png"))
        let outside = root.appending(path: "outside.txt")
        try Data("secret".utf8).write(to: outside)
        try fileManager.createSymbolicLink(
            at: content.appending(path: "escape.txt"), withDestinationURL: outside)
        try fileManager.createSymbolicLink(
            at: content.appending(path: "alias.png"),
            withDestinationURL: content.appending(path: "Files/a.png"))

        let file = CCwikiURL.assetFile("Files/a.png", in: content)
        #expect(file?.lastPathComponent == "a.png")
        #expect(CCwikiURL.assetFile("alias.png", in: content)?.lastPathComponent == "a.png",
                "a link inside the wiki to a file inside it is followed")
        let slashed = URL(filePath: content.path(percentEncoded: false) + "/")
        #expect(CCwikiURL.assetFile("Files/a.png", in: slashed)?.lastPathComponent == "a.png",
                "a root with a trailing slash")

        #expect(CCwikiURL.assetFile("../outside.txt", in: content) == nil)
        #expect(CCwikiURL.assetFile("Files/../../outside.txt", in: content) == nil)
        #expect(CCwikiURL.assetFile("escape.txt", in: content) == nil,
                "a symbolic link that points out of the wiki")
        #expect(CCwikiURL.assetFile("", in: content) == nil)
        #expect(CCwikiURL.assetFile("/", in: content) == nil)
        #expect(CCwikiURL.assetFile("Files/..", in: content) == nil)
    }

    // MARK: The shell

    @Test("the shell loads while the controller loads it, and then only a place on it")
    func shellNavigation() throws {
        let shell = CCwikiURL.shell
        let place = try #require(URL(string: CCwikiURL.shell.absoluteString + "#syntax"))
        func allows(_ url: URL, ready: Bool, reload: Bool = false) -> Bool {
            CCwikiURL.allowsShellNavigation(to: url, isReady: ready, isReload: reload)
        }

        #expect(allows(shell, ready: false), "the first load, and the one after a crash")
        #expect(!allows(shell, ready: true), "a refresh to the shell would loop")
        #expect(!allows(shell, ready: true, reload: true))
        #expect(allows(place, ready: true), "WebKit's Open Link on a link to a heading")
        #expect(!allows(place, ready: true, reload: true), "a refresh to a place on the shell reloads it")
        #expect(!allows(place, ready: false))

        let others = [
            "ccwiki://wiki/_/app.css",
            "ccwiki://wiki/_/ccwiki.js",
            "ccwiki://wiki/",
            "ccwiki://wiki",
            "ccwiki://wiki/foo",
            "ccwiki://wiki/page/A.md",
            "ccwiki://wiki/asset/Files/a.png",
            "ccwiki://other/_/index.html",
        ]
        for string in others {
            let url = try #require(URL(string: string))
            #expect(!allows(url, ready: false), "\(string)")
            #expect(!allows(url, ready: true), "\(string)")
        }
    }

    // MARK: Back and Forward on one page

    private static func request(
        path: String, anchor: String?, restoresScroll: Bool = false
    ) -> RenderRequest {
        var request = RenderRequest(
            path: path, title: path, markdown: "# A", html: nil, links: [:],
            anchor: anchor, notices: [])
        request.restoresScroll = restoresScroll
        return request
    }

    @Test("Back or Forward to another place on the page on screen scrolls there")
    func backOnOnePage() {
        let restoreTop = Self.request(path: "A.md", anchor: nil, restoresScroll: true)
        #expect(RenderStep(restoreTop, loadedPath: "A.md") == .scroll(anchor: ""))
        let restoreX = Self.request(path: "A.md", anchor: "x", restoresScroll: true)
        #expect(RenderStep(restoreX, loadedPath: "A.md") == .scroll(anchor: "x"))
        // Another page lays out, restoring where it was left.
        #expect(RenderStep(restoreX, loadedPath: "B.md") == .render)
        #expect(RenderStep(restoreX, loadedPath: nil) == .render)
    }

    @Test("an ordinary request for the page on screen is as before")
    func ordinaryRequests() {
        let same = Self.request(path: "A.md", anchor: nil)
        #expect(RenderStep(same, loadedPath: "A.md") == .skip)
        let anchored = Self.request(path: "A.md", anchor: "x")
        #expect(RenderStep(anchored, loadedPath: "A.md") == .render)
        #expect(RenderStep(same, loadedPath: nil) == .render, "after invalidate()")
        #expect(RenderStep(same, loadedPath: "B.md") == .render)
    }

    // MARK: A window opened on a page, with the launch document due

    @Test("a window opened on a page opens it over the launch document")
    func openingOverLaunchDocument() {
        let opening = Location.page(path: "References/goldreich.md", anchor: nil)
        let plan = SessionStartPlan.plan(
            restored: nil, window: ReaderWindow(opening: opening, find: ["GGM"]),
            pending: nil, launchDocument: .whatsNew, isColdStart: true, lastPage: "A.md")
        #expect(plan.showsAtOnce == .document(.whatsNew))
        #expect(plan.opensOnLoad == opening)
        #expect(plan.find == ["GGM"])
        #expect(!plan.opensHomeOnLoad)

        // Without an opening the launch document still stays.
        let plain = SessionStartPlan.plan(
            restored: nil, window: ReaderWindow(), pending: nil, launchDocument: .whatsNew,
            isColdStart: true, lastPage: "A.md")
        #expect(plain.opensOnLoad == nil)
        #expect(!plain.opensHomeOnLoad)
    }

    // MARK: A load after the first

    private static let a = Location.page(path: "A.md", anchor: nil)
    private static let b = Location.page(path: "B.md", anchor: nil)
    private static let c = Location.page(path: "C.md", anchor: "proof")

    /// On C, having come from A through B.
    private static func history() -> NavigationHistory {
        var history = NavigationHistory()
        history.visit(a)
        history.visit(b)
        history.visit(c)
        return history
    }

    private static func reload(
        _ history: NavigationHistory, gone: Set<String>,
        changed: Set<Location> = [], revisionGone: Bool = false
    ) -> SessionReloadPlan {
        SessionReloadPlan.plan(
            history: history, exists: { !gone.contains($0) },
            changed: { changed.contains($0) }, revisionGone: revisionGone)
    }

    @Test("a page a pull took away leaves Back, and the page on screen stays")
    func goneFromBack() {
        let plan = Self.reload(Self.history(), gone: ["B.md"])
        #expect(plan.history.current == Self.c)
        #expect(plan.history.back == [Self.a])
        #expect(plan.render == .unchanged)

        let changed = Self.reload(Self.history(), gone: ["B.md"], changed: [Self.c])
        #expect(changed.render == .inPlace)
    }

    @Test("the page on screen went: the nearest one left on Back shows")
    func goneFromScreen() {
        let plan = Self.reload(Self.history(), gone: ["C.md"])
        #expect(plan.history.current == Self.b)
        #expect(plan.history.back == [Self.a])
        #expect(plan.render == .current)

        let both = Self.reload(Self.history(), gone: ["B.md", "C.md"])
        #expect(both.history.current == Self.a)
        #expect(both.render == .current)
    }

    @Test("nothing left to show, or nothing shown, opens Home")
    func nothingLeft() {
        var only = NavigationHistory()
        only.visit(Self.a)
        let plan = Self.reload(only, gone: ["A.md"])
        #expect(plan.history.current == .empty)
        #expect(plan.render == .home)

        #expect(Self.reload(NavigationHistory(), gone: []).render == .home)
    }

    @Test("nothing gone and nothing changed: nothing to do")
    func nothingToDo() {
        let history = Self.history()
        let plan = Self.reload(history, gone: [])
        #expect(plan.history == history)
        #expect(plan.render == .unchanged)
    }

    @Test("a page rendered at a snapshot's old revision renders again; a folder or document does not")
    func snapshotRevision() {
        #expect(Self.reload(Self.history(), gone: [], revisionGone: true).render == .inPlace)

        var folder = NavigationHistory()
        folder.visit(.folder(slug: "Primitives"))
        #expect(Self.reload(folder, gone: [], revisionGone: true).render == .unchanged)

        var document = NavigationHistory()
        document.visit(.document(.welcome))
        #expect(Self.reload(document, gone: [], revisionGone: true).render == .unchanged)
    }

    @Test("only a snapshot outlives a revision, and only once its marker moved")
    func outlivesRevision() {
        #expect(SessionReloadPlan.outlivesRevision(store: .snapshot, rendered: "a1", head: "b2"))
        #expect(!SessionReloadPlan.outlivesRevision(store: .snapshot, rendered: "b2", head: "b2"))
        #expect(!SessionReloadPlan.outlivesRevision(store: .git, rendered: "a1", head: "b2"),
                "a clone keeps every revision")
        #expect(!SessionReloadPlan.outlivesRevision(store: .none, rendered: "a1", head: "b2"))
    }

    // MARK: The link menu

    private static let pageLink = CCwikiURL.page(path: "Primitives/prf.md", anchor: "syntax")

    @Test("Open Link is the app's own for a page, a folder, a file and the web")
    func openLinkTargets() throws {
        #expect(ReaderContextTarget(link: Self.pageLink).openLink
            == .follow(.page(path: "Primitives/prf.md", anchor: "syntax")))
        #expect(ReaderContextTarget(link: CCwikiURL.folder(slug: "Primitives")).openLink
            == .follow(.folder(slug: "Primitives")))
        #expect(ReaderContextTarget(link: CCwikiURL.asset(path: "Files/Minicrypt.png")).openLink
            == .follow(.asset(path: "Files/Minicrypt.png")))

        let web = "https://eprint.iacr.org/2015/022"
        let webURL = try #require(URL(string: web))
        #expect(ReaderContextTarget(externalLink: web).openLink == .external(webURL))
        let mail = "mailto:someone@example.com"
        let mailURL = try #require(URL(string: mail))
        #expect(ReaderContextTarget(externalLink: mail).openLink == .external(mailURL))
    }

    @Test("a place on the page, the shell, or another scheme keeps WebKit's Open Link")
    func openLinkLeftAlone() {
        #expect(ReaderContextTarget().openLink == nil)
        #expect(ReaderContextTarget(link: "#syntax").openLink == nil)
        #expect(ReaderContextTarget(link: CCwikiURL.shell.absoluteString).openLink == nil)
        #expect(ReaderContextTarget(externalLink: "file:///etc/hosts").openLink == nil)
        #expect(ReaderContextTarget(externalLink: "javascript:alert(1)").openLink == nil)
        #expect(ReaderContextTarget(externalLink: "").externalLink == nil)
    }

    @Test("the bridge message carries the web link")
    func readsExternalLink() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "link": NSNull(),
            "externalLink": "https://eprint.iacr.org/2015/022",
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target.externalLink == "https://eprint.iacr.org/2015/022")
        #expect(target.link == nil)
        #expect(target.linkItems.isEmpty, "a web link gets no tab or window")
    }

    @Test("outside a reader a link offers the site alone, never a tab or a window")
    func linkItemsOutsideReader() {
        let page = ReaderContextTarget(link: Self.pageLink)
        #expect(page.linkItems(inReader: true) == page.linkItems)
        #expect(page.linkItems(inReader: false).map(\.title) == ["Open Link on cryptology.city"])
        #expect(page.linkItems(inReader: false).map(\.disposition) == [.onSite])

        let folder = ReaderContextTarget(link: CCwikiURL.folder(slug: "Primitives"))
        #expect(folder.linkItems(inReader: true).count == 2)
        #expect(folder.linkItems(inReader: false).isEmpty)
    }
}
