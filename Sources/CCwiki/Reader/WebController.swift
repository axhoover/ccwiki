import AppKit
import Observation
import OSLog
import SwiftUI
import WebKit

/// Owns the one `WKWebView` the reader ever creates.
///
/// The web view must outlive the SwiftUI struct that shows it — `makeNSView`
/// returns this instance rather than constructing one, and `updateNSView` is
/// idempotent — or every parent re-render throws the page away and the reader
/// flickers back to the top of the document.
@MainActor
@Observable
final class WebController: NSObject {

    /// What the page reported after its last render.
    private(set) var outline: [WikiPage.Heading] = []
    private(set) var activeHeadingID: String?
    private(set) var lastRenderError: String?
    private(set) var isReady = false

    /// Set by the owner to act on a link click, and on what the click meant.
    var onNavigate: ((CCwikiURL.Destination, LinkDisposition) -> Void)?
    /// Whether a link's context menu offers a new tab and a new window: a
    /// reader's does. The review and an editor's preview follow a link in
    /// the active reader whatever is asked (corrections §17), so theirs
    /// offer the site alone.
    @ObservationIgnored var opensLinksInTabs = false
    /// The page's own address on the site, for the page context menu.
    var siteURLProvider: (() -> URL?)?
    /// What "Explore From This Page…" would ask, for the page context menu;
    /// `nil` leaves the item out (relations-explorer.md §2.11).
    var exploreHere: (() -> ExplorerQuery?)?
    /// Asks that question, when the item is chosen.
    var onExplore: ((ExplorerQuery) -> Void)?
    /// Whether the page context menu offers the corrections group
    /// (plans/corrections.md §9): a wiki page is showing.
    var correctionAvailable: (() -> Bool)?
    /// A correction chosen from the context menu, with what was selected at
    /// the right-click: a passage, the block under the pointer, or nothing.
    var onCorrect: ((CorrectionRoute, ReaderSelection?) -> Void)?
    /// What the page reported under the last right-click, for the menu.
    @ObservationIgnored fileprivate var contextTarget: ReaderContextTarget?

    /// The markdown of the last request sent to the page, and that request's
    /// `revision`: what the reader is showing, which a correction maps its
    /// lines through. Rebuilding it could differ from what was drawn
    /// (corrections §3.5).
    private(set) var lastRenderedMarkdown: String?
    private(set) var lastRenderedRevision: String?

    /// Called when the shell has (re)loaded and there is nothing queued: the
    /// owner should render whatever it is showing again. That is how the
    /// reader comes back from a WebContent crash; any other reload of the
    /// shell is cancelled (`CCwikiURL.allowsShellNavigation`).
    var onReady: (() -> Void)?
    /// Called when WebKit's content process has stopped, before the shell
    /// is loaded again: the owner makes sure the staged pipeline it is
    /// served from is still there (`AppModel.checkWebRoot`), since Caches
    /// may have lost it after this view was made.
    var onRendererRestart: (() -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var pendingRequest: RenderRequest?
    /// The last review asked for (corrections §6.3), kept so the shell is
    /// sent it whenever it says "ready": the first review shown is never
    /// blank, and one comes back after a WebContent crash.
    @ObservationIgnored private var pendingReviewJSON: String?
    /// The review on the page now, so asking for the same one again does
    /// not lay it out again.
    @ObservationIgnored private var shownReviewJSON: String?
    @ObservationIgnored private var loadedPath: String?
    /// Searched for once the next render reports back.
    @ObservationIgnored private var pendingFind: [String]?

    /// An offline reader has nothing worth persisting, and a non-persistent
    /// store means nothing about the wiki lands in a WebKit cache directory.
    /// One for every reader: each store brings a network process of its own
    /// (plans/reader-comforts.md §1.9).
    @MainActor static let sharedDataStore: WKWebsiteDataStore = .nonPersistent()

    /// Category `render`: how long each render took in the page, as the
    /// page measures it, so WebKit's own numbers can be read before and
    /// after a change to the renderer (plans/render-pipeline.md, "The KaTeX
    /// memo"). `debug`, so it is kept only while someone streams it.
    private static let renderLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.axhoover.ccwiki", category: "render")

    /// `webRoot` is the pipeline to serve, staged once per launch
    /// (`AppPaths.stagedWebRoot()`); `pageZoom` the text size to start at.
    init(paths: AppPaths, webRoot: URL, pageZoom: Double) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            CCwikiSchemeHandler(bundleRoot: webRoot, contentRoot: paths.content),
            forURLScheme: CCwikiURL.scheme)
        configuration.websiteDataStore = WebController.sharedDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // The macro table used to be injected here as a documentStart user
        // script, which froze whatever `macros.ts` said at launch — nothing on
        // a fresh install. It now arrives with each `RenderRequest`.
        let controller = WKUserContentController()
        configuration.userContentController = controller

        let readerView = ReaderWebView(frame: .zero, configuration: configuration)
        webView = readerView
        super.init()
        readerView.controller = self

        controller.add(Bridge(controller: self), name: "ccwiki")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Without this the web view paints its own white backdrop before the
        // first frame, which reads as a flash on every navigation in dark mode.
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.allowsMagnification = true
        webView.pageZoom = pageZoom
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        webView.load(URLRequest(url: CCwikiURL.shell))
    }

    // MARK: Rendering

    /// Render, then find `needle` on the result: how a search result lands
    /// on its match instead of the top of the page. If the page is already
    /// showing, only the find runs.
    func render(_ request: RenderRequest, thenFind needle: [String]?) {
        guard let needle, !needle.isEmpty else {
            render(request)
            return
        }
        if isReady, request.path == loadedPath, request.anchor == nil {
            Task { _ = await findFirst(of: needle) }
            return
        }
        pendingFind = needle
        render(request)
    }

    func render(_ request: RenderRequest) {
        guard isReady else {
            pendingRequest = request
            return
        }
        switch RenderStep(request, loadedPath: loadedPath) {
        case .render:
            break
        case .scroll(let anchor):
            scrollTo(anchor: anchor)
            return
        case .skip:
            return
        }
        loadedPath = request.path
        // A page replaces a review: a reload brings back the page.
        pendingReviewJSON = nil
        shownReviewJSON = nil
        outline = []
        lastRenderError = nil
        lastRenderedMarkdown = request.markdown
        lastRenderedRevision = request.revision

        let script = "CCwiki.render(\(request.jsonPayload()));"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            self?.lastRenderError = error.localizedDescription
        }
    }

    /// Force a re-render of the current page (after a pull changed it).
    func invalidate() { loadedPath = nil }

    // MARK: Printing

    /// The standard print panel, whose PDF menu is also Save as PDF. The
    /// page prints on white whatever the appearance: `app.css` has print
    /// rules for that.
    func printPage(title: String) {
        guard let window = webView.window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        for edge in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] {
            info[keyPath: edge] = 42
        }

        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // Without a frame, WebKit's print view is zero-sized and every page
        // comes out blank.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Text size

    static let zoomRange = 0.6...2.4
    static let zoomStep = 1.1

    /// Applies a text size. The size is one preference for every reader, so
    /// `AppModel.pageZoom` clamps it, persists it and hands it here.
    func setPageZoom(_ zoom: Double) {
        webView.pageZoom = zoom
    }

    func scrollTo(anchor: String) {
        let escaped = anchor.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        webView.evaluateJavaScript("CCwiki.scrollToAnchor(\"\(escaped)\");")
    }

    // MARK: Find

    /// `.findNavigator` is macOS 26, so the reader ships its own find bar over
    /// `WKWebView.find`, which has been available since macOS 11.
    func find(_ needle: String, backwards: Bool, caseSensitive: Bool = false) async -> Bool {
        guard !needle.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        guard let result = try? await webView.find(needle, configuration: configuration)
        else { return false }
        return result.matchFound
    }

    /// The first of `candidates` that occurs on the page, found and shown
    /// with the system's find highlight. A candidate with a capital is
    /// looked for in its own case first, as ⇧⌘F matched it (smart case,
    /// search-v2 §6.6), so `OT` lands on OT and not on "not"; then in any
    /// case, for text the rendering changed.
    func findFirst(of candidates: [String]) async -> Bool {
        for candidate in candidates {
            if TextGrep.options(for: candidate).isEmpty,
               await find(candidate, backwards: false, caseSensitive: true) {
                return true
            }
            if await find(candidate, backwards: false) { return true }
        }
        return false
    }

    // MARK: Bridge

    /// A separate object so the controller itself is not retained by
    /// `WKUserContentController`, which would otherwise be a cycle through the
    /// configuration.
    @MainActor
    private final class Bridge: NSObject, WKScriptMessageHandler {
        private weak var controller: WebController?

        init(controller: WebController) { self.controller = controller }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            controller?.handle(body)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            // A fresh document, whether the first or a reload: nothing is on it.
            isReady = true
            loadedPath = nil
            shownReviewJSON = nil
            if let pending = pendingRequest {
                pendingRequest = nil
                render(pending)
            } else if let review = pendingReviewJSON {
                sendReview(review)
            } else {
                onReady?()
            }

        case "rendered":
            if let items = message["toc"] as? [[String: Any]] {
                outline = items.compactMap { item in
                    guard let level = item["level"] as? Int,
                          let text = item["text"] as? String,
                          let id = item["id"] as? String
                    else { return nil }
                    return WikiPage.Heading(level: level, text: text, id: id)
                }
            }
            if message["ok"] as? Bool == false {
                lastRenderError = message["error"] as? String ?? "render failed"
            }
            if let needle = pendingFind {
                pendingFind = nil
                Task { _ = await findFirst(of: needle) }
            }
            if let errors = message["pseudocodeErrors"] as? Int, errors > 0 {
                lastRenderError = "\(errors) pseudocode block(s) failed to render."
            }
            if let milliseconds = message["ms"] as? Int {
                // A page sends its path; a review none.
                let shown = message["path"] as? String ?? "a review"
                Self.renderLog.debug("\(shown, privacy: .public) rendered in \(milliseconds) ms")
            }

        case "scrolled":
            // `@Observable` notifies on every assignment, changed or not.
            let heading = message["heading"] as? String
            if heading != activeHeadingID { activeHeadingID = heading }

        case "navigate":
            guard let href = message["href"] as? String,
                  let destination = CCwikiURL.destination(of: href)
            else { return }
            // The keys held and the button, read as every click is read.
            onNavigate?(destination, LinkDisposition.forClick(message: message))

        case "contextTarget":
            contextTarget = ReaderContextTarget(message: message)

        case "copy":
            // The page's copy buttons. Their text comes here rather than
            // going to navigator.clipboard, which a page on a custom scheme
            // cannot count on having.
            guard let text = message["text"] as? String, !text.isEmpty else { return }
            ReaderWebView.copy(text)

        case "openExternal":
            guard let string = message["url"] as? String,
                  let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { return }
            NSWorkspace.shared.open(url)

        default:
            break
        }
    }
}

/// What a render request asks of a web view that may already show its
/// page. Pure, so the rule is tested without a web view.
enum RenderStep: Equatable, Sendable {
    /// Lay the page out.
    case render
    /// The page is on screen: go to a place on it, "" for the top.
    case scroll(anchor: String)
    /// The page is on screen, and nothing asks to move.
    case skip

    init(_ request: RenderRequest, loadedPath: String?) {
        guard request.path == loadedPath else {
            self = .render
            return
        }
        if request.restoresScroll {
            // Back or Forward between two places on the page on screen
            // goes to the place. Laying the page out again would restore
            // where it is being left, since the page keeps one position
            // per page, and without an anchor it was not laid out at all.
            self = .scroll(anchor: request.anchor ?? "")
        } else {
            self = request.anchor == nil ? .skip : .render
        }
    }
}

// MARK: - Corrections and the review

/// What a correction, the editor's preview and the review ask of the page
/// (plans/corrections.md §3.3, §6.3). Each page function is guarded, so a
/// shell without it does nothing.
extension WebController {

    /// The selection as `CCwiki.selectionSource()` reports it: the passage's
    /// rendered lines, its text, its heading and the revision it was shown
    /// at. Nil with nothing selected on the page, before the page is ready,
    /// or if the page cannot be asked.
    ///
    /// The page always answers with a string, "null" for nothing, and the
    /// completion-handler form is used all the same: the async one traps if
    /// a script's value is ever undefined.
    func selectionSource() async -> ReaderSelection? {
        guard isReady else { return nil }
        let script = "(function () { try { return window.CCwiki && CCwiki.selectionSource "
            + "? CCwiki.selectionSource() : \"null\"; } catch (e) { return \"null\"; } })()"
        let json: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        return json.flatMap(ReaderSelection.init(json:))
    }

    /// Shows a review payload (§6.3) in place of a page. Kept until the
    /// shell is ready, and sent again whenever it reloads.
    func renderReview(json: String) {
        pendingReviewJSON = json
        // The next page asked for renders, whatever was shown before.
        loadedPath = nil
        guard isReady, json != shownReviewJSON else { return }
        sendReview(json)
    }

    private func sendReview(_ json: String) {
        shownReviewJSON = json
        outline = []
        lastRenderError = nil
        webView.evaluateJavaScript(
            "window.CCwiki && CCwiki.renderReview && CCwiki.renderReview(\(json)); true;"
        ) { [weak self] _, error in
            guard let error else { return }
            self?.lastRenderError = error.localizedDescription
        }
    }

    /// Scrolls the first block overlapping the rendered lines, 0-based and
    /// half-open, to the centre; with `mark`, outlines the blocks briefly.
    func revealSourceLines(_ range: Range<Int>, mark: Bool) {
        evaluate("window.CCwiki && CCwiki.revealSourceLines && CCwiki.revealSourceLines("
            + "\(range.lowerBound), \(range.upperBound), \(mark));")
    }

    func scrollToReviewEntry(_ id: String) {
        evaluate("window.CCwiki && CCwiki.scrollToReviewEntry && CCwiki.scrollToReviewEntry("
            + "\(Self.javaScriptString(id)));")
    }

    /// Runs `script` for its effect. The completion-handler form, because the
    /// async one traps when the script's value is undefined.
    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// `text` as a JavaScript string literal.
    private static func javaScriptString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }
}

// MARK: - Navigation

extension WebController: WKNavigationDelegate {

    /// WebKit jettisoned the content process. Without this the view stays
    /// blank: `isReady` would still be true and every render would be
    /// evaluated on a dead page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onRendererRestart?()
        isReady = false
        loadedPath = nil
        outline = []
        activeHeadingID = nil
        lastRenderError = "The page renderer stopped and was restarted."
        webView.load(URLRequest(url: CCwikiURL.shell))
    }

    /// The decision handler's type has to be spelled out in full.
    ///
    /// Writing the obvious `@escaping (WKNavigationActionPolicy) -> Void`
    /// compiles with only a "nearly matches optional requirement" *warning* and
    /// is then never called — every navigation is allowed and the interception
    /// silently does nothing.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // The shell, loaded by this controller, and a place on it are the
        // only documents that may ever load; its assets are not navigations.
        if url.scheme == CCwikiURL.scheme,
           CCwikiURL.allowsShellNavigation(
               to: url, isReady: isReady,
               isReload: navigationAction.navigationType == .reload) {
            decisionHandler(.allow)
            return
        }

        // A click that reached here rather than the JS handler — belt and
        // braces, and the layer that keeps a rogue link from loading anything.
        // WebKit's own record of the button and keys stands in for the
        // page's.
        if navigationAction.navigationType == .linkActivated {
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            } else if let destination = CCwikiURL.destination(of: url.absoluteString) {
                onNavigate?(destination, Self.disposition(of: navigationAction))
            }
        }
        decisionHandler(.cancel)
    }

    /// What WebKit says clicked a link it followed itself.
    fileprivate static func disposition(of action: WKNavigationAction) -> LinkDisposition {
        LinkDisposition.forNavigation(
            buttonNumber: action.buttonNumber, modifierFlags: action.modifierFlags)
    }
}

extension WebController: WKUIDelegate {
    /// `target="_blank"` must never spawn a window: the web goes to the
    /// browser, and the wiki's own pages to the app, as a click would.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            NSWorkspace.shared.open(url)
        } else if let destination = CCwikiURL.destination(of: url.absoluteString),
                  destination != .shell {
            onNavigate?(destination, Self.disposition(of: navigationAction))
        }
        return nil
    }
}

// MARK: - The view

/// `WKWebView` with the parts of its default context menu that make no sense
/// for a page the app renders itself taken out: Back, Forward and Reload act
/// on the shell document, not the wiki page, and Reload used to leave the
/// reader blank. Copy, Look Up and the rest stay.
final class ReaderWebView: WKWebView {

    private static let removedIdentifiers: Set<String> = [
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierDownloadImage",
    ]

    weak var controller: WebController?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.items.removeAll { item in
            item.identifier.map { Self.removedIdentifiers.contains($0.rawValue) } ?? false
        }

        // Copy LaTeX first, when the click was on a formula or an algorithm:
        // the one thing the default menu cannot offer, since the page shows
        // only glyphs.
        let target = controller?.contextTarget
        let copyItems = target?.copyItems ?? []
        if !copyItems.isEmpty {
            for (index, item) in copyItems.enumerated() {
                menu.insertItem(Self.menuItem(for: item), at: index)
            }
            menu.insertItem(.separator(), at: copyItems.count)
        }
        let onNavigate = controller?.onNavigate
        let identifiers = menu.items.map { $0.identifier?.rawValue }
        let afterOpenLink = ReaderContextTarget.indexAfterOpenLink(in: identifiers)
        // WebKit's Open Link loads the link with no click behind it, a
        // navigation the delegate cancels, so the app's own Open Link, under
        // WebKit's title, takes its place for every link the app can open:
        // a page, a folder or a file of the wiki, and the web or mail. A
        // place on this page keeps WebKit's, which scrolls there.
        if let afterOpenLink, let openLink = target?.openLink {
            let action: @MainActor () -> Void
            switch openLink {
            case .follow(let destination): action = { onNavigate?(destination, .here) }
            case .external(let url): action = { NSWorkspace.shared.open(url) }
            }
            let index = afterOpenLink - 1
            let title = menu.items[index].title
            menu.removeItem(at: index)
            menu.insertItem(ClosureMenuItem(title, handler: action), at: index)
        }
        // A link to a page opens in a new tab, a new window or on the site,
        // and a link to a folder in the first two, in place of WebKit's Open
        // Link in New Window: in a reader, as the review and an editor's
        // preview offer the site alone. The items follow WebKit's Open Link,
        // as Safari's do; without it they make a group of their own after
        // the copy items.
        let linkItems = target?.linkItems(inReader: controller?.opensLinksInTabs ?? false) ?? []
        if !linkItems.isEmpty {
            var index = afterOpenLink ?? (copyItems.isEmpty ? 0 : copyItems.count + 1)
            for entry in linkItems {
                menu.insertItem(ClosureMenuItem(entry.title) {
                    onNavigate?(entry.destination, entry.disposition)
                }, at: index)
                index += 1
            }
            if afterOpenLink == nil { menu.insertItem(.separator(), at: index) }
        }
        // The page itself, wherever the click was.
        let siteURL = controller?.siteURLProvider?()
        if let url = siteURL {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Open Page on cryptology.city") {
                NSWorkspace.shared.open(url)
            })
            menu.addItem(ClosureMenuItem("Copy Link to Page") { Self.copy(url.absoluteString) })
        }
        // What this page's objects derive, in the Relations Explorer. Only on
        // a page with something to explore: an object, a reduction or a
        // barrier, never a complexity class. It joins the page's group, and
        // without one it starts its own, apart from WebKit's Copy and Look Up.
        if let query = controller?.exploreHere?() {
            if siteURL == nil { menu.addItem(.separator()) }
            let onExplore = controller?.onExplore
            menu.addItem(ClosureMenuItem("Explore From This Page…") { onExplore?(query) })
        }
        // Correcting the page, a group of its own after the page's
        // (corrections §9): it carries what was selected at the right-click,
        // a passage, or the block under the pointer.
        if let onCorrect = controller?.onCorrect {
            let available = controller?.correctionAvailable?() ?? false
            let selection = target?.selection
            for entry in ReaderContextTarget.correctionGroup(available: available, selection: selection) {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case .item(let title, let route):
                    menu.addItem(ClosureMenuItem(title) { onCorrect(route, selection) })
                }
            }
        }
        // No leading, trailing or doubled separators once the items are gone.
        var cleaned: [NSMenuItem] = []
        for item in menu.items {
            if item.isSeparatorItem, cleaned.last?.isSeparatorItem ?? true { continue }
            cleaned.append(item)
        }
        if cleaned.last?.isSeparatorItem == true { cleaned.removeLast() }
        menu.items = cleaned
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        controller?.contextTarget = nil
    }

    /// The item for one copy entry. The text is captured by value, so the
    /// copy still works if `didCloseMenu` has cleared the target before the
    /// action runs. An alternate replaces the item above it while Option is
    /// held: it must follow that item directly and differ only in its
    /// modifier mask.
    private static func menuItem(for entry: ReaderContextTarget.CopyItem) -> NSMenuItem {
        let text = entry.text
        let item = ClosureMenuItem(entry.title) { Self.copy(text) }
        if entry.isAlternate {
            item.isAlternate = true
            item.keyEquivalentModifierMask = .option
        }
        return item
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// What the page reported under the pointer at a right-click: the formula,
/// the pseudocode block and the link, any or none of them. Reported by
/// `ccwiki.js` just ahead of the menu, and turned into the menu's copy and
/// link items here, where they can be tested without a menu.
struct ReaderContextTarget: Equatable, Sendable {

    /// One copy entry at the top of the menu.
    struct CopyItem: Equatable, Sendable {
        let title: String
        let text: String
        /// Shown in place of the entry above it while Option is held.
        let isAlternate: Bool
    }

    /// One link entry, after WebKit's Open Link: the link's page somewhere
    /// other than here.
    struct LinkItem: Equatable, Sendable {
        let title: String
        let destination: CCwikiURL.Destination
        let disposition: LinkDisposition
    }

    /// The formula's LaTeX as written on the page, without delimiters.
    let tex: String?
    /// The pseudocode block's source, `\algname{…}` taken out.
    let algorithm: String?
    /// The same with the wiki's macros written out, for a document that
    /// does not have the preamble.
    let algorithmExpanded: String?
    /// The `href` of the link under the pointer, when it is one the app
    /// follows itself rather than the web or a place on the page.
    let link: String?
    /// What was selected when the right button went down, or else the block
    /// under the pointer with no text (plans/corrections.md §3.3): what the
    /// corrections group acts on, and whether it says Passage or Page.
    let selection: ReaderSelection?
    /// The `href` of a link to the web or to mail under the pointer, for
    /// the menu's Open Link.
    let externalLink: String?

    /// An empty string counts as absent: there is nothing to copy or open.
    init(
        tex: String? = nil, algorithm: String? = nil, algorithmExpanded: String? = nil,
        link: String? = nil, selection: ReaderSelection? = nil, externalLink: String? = nil
    ) {
        self.tex = tex?.isEmpty == false ? tex : nil
        self.algorithm = algorithm?.isEmpty == false ? algorithm : nil
        self.algorithmExpanded = algorithmExpanded?.isEmpty == false ? algorithmExpanded : nil
        self.link = link?.isEmpty == false ? link : nil
        self.selection = selection
        self.externalLink = externalLink?.isEmpty == false ? externalLink : nil
    }

    /// The bridge message. A JavaScript `null` arrives as `NSNull`, which
    /// reads as absent like anything else that is not a string or an object.
    init(message: [String: Any]) {
        self.init(
            tex: message["tex"] as? String,
            algorithm: message["algorithm"] as? String,
            algorithmExpanded: message["algorithmExpanded"] as? String,
            link: message["link"] as? String,
            selection: (message["selection"] as? [String: Any]).flatMap {
                ReaderSelection(message: $0)
            },
            externalLink: message["externalLink"] as? String)
    }

    /// What the app's own Open Link does, in place of WebKit's.
    enum OpenLink: Equatable, Sendable {
        /// A page, a folder or a file of the wiki, opened here.
        case follow(CCwikiURL.Destination)
        /// The web or mail, in its own app.
        case external(URL)
    }

    /// Nil for no link the app opens, such as a place on this page, which
    /// WebKit's own Open Link scrolls to. WebKit's would load the others
    /// with no click behind them, which the navigation delegate cancels.
    var openLink: OpenLink? {
        if let link, let destination = CCwikiURL.destination(of: link), destination != .shell {
            return .follow(destination)
        }
        if let externalLink, let url = URL(string: externalLink),
           let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return .external(url)
        }
        return nil
    }

    /// In menu order: the formula, then the algorithm, then the algorithm
    /// with its macros written out as the Option-key alternate.
    var copyItems: [CopyItem] {
        var items: [CopyItem] = []
        if let tex {
            items.append(CopyItem(title: "Copy LaTeX", text: tex, isAlternate: false))
        }
        if let algorithm {
            items.append(CopyItem(title: "Copy Algorithm as LaTeX", text: algorithm, isAlternate: false))
            if let algorithmExpanded {
                items.append(CopyItem(
                    title: "Copy Algorithm as LaTeX (No Macros)",
                    text: algorithmExpanded,
                    isAlternate: true))
            }
        }
        return items
    }

    /// For a link to a page of the wiki, in menu order: a new tab, a new
    /// window, the site (reader-comforts §1.1). A link to a folder gets the
    /// tab and the window alone, as a folder label in the sidebar does.
    /// Nothing for a file, which opens in an app of its own, or for anything
    /// that is not a `ccwiki://` link.
    var linkItems: [LinkItem] {
        guard let link, let destination = CCwikiURL.destination(of: link) else { return [] }
        switch destination {
        case .page, .folder:
            break
        case .asset, .shell:
            return []
        }
        var items = [
            LinkItem(title: "Open Link in New Tab", destination: destination,
                     disposition: .newTab(inBackground: true)),
            LinkItem(title: "Open Link in New Window", destination: destination,
                     disposition: .newWindow),
        ]
        if case .page = destination {
            items.append(LinkItem(title: "Open Link on cryptology.city", destination: destination,
                                  disposition: .onSite))
        }
        return items
    }

    /// `linkItems` in a reader, and the site alone elsewhere: the review
    /// and an editor's preview follow a link in the active reader whatever
    /// is asked (corrections §17), so a new tab or window would not be one.
    func linkItems(inReader: Bool) -> [LinkItem] {
        inReader ? linkItems : linkItems.filter { $0.disposition == .onSite }
    }

    /// One entry of the corrections group.
    enum CorrectionEntry: Equatable, Sendable {
        case separator
        case item(title: String, route: CorrectionRoute)
    }

    /// The corrections group, as it ends the menu (corrections §9): a
    /// separator, then Edit, Describe a Correction and Open an Issue. The
    /// titles say Passage for a selection the right-click was on, and Page
    /// for a pointer or nothing, which is about the whole page. Nothing
    /// where the page offers no corrections: a folder, or the app's own
    /// pages.
    static func correctionGroup(available: Bool, selection: ReaderSelection?) -> [CorrectionEntry] {
        guard available else { return [] }
        let isPassage = selection?.isPassage ?? false
        let subject = isPassage ? "Passage" : "Page"
        return [
            .separator,
            .item(title: "Edit This \(subject)…", route: .edit),
            .item(title: "Describe a Correction…", route: .describe),
            .item(title: "Open an Issue About This \(subject)…", route: .issue),
        ]
    }

    /// WebKit's own Open Link, which the link items follow, where Safari
    /// puts its own.
    static let openLinkIdentifier = "WKMenuItemIdentifierOpenLink"

    /// Where the link items go in a menu whose items carry `identifiers`, in
    /// order: directly after WebKit's Open Link. nil when the menu has none;
    /// the items then make a group of their own after the copy items.
    static func indexAfterOpenLink(in identifiers: [String?]) -> Int? {
        identifiers.firstIndex(of: openLinkIdentifier).map { $0 + 1 }
    }
}

/// A menu item that runs a closure, for menus built in code. Menus are
/// main-thread objects, so the item and its action are main-actor isolated.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

// MARK: - SwiftUI

/// Hands the controller's single web view to SwiftUI.
struct WebPane: NSViewRepresentable {
    let controller: WebController

    func makeNSView(context: Context) -> WKWebView { controller.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Deliberately empty: rendering is driven by `controller.render(_:)`,
        // not by view updates. Doing work here would re-render on every parent
        // recomposition and reset the scroll position.
    }
}
