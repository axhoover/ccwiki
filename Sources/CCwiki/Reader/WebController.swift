import AppKit
import Observation
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
    /// The page's own address on the site, for the page context menu.
    var siteURLProvider: (() -> URL?)?
    /// What "Explore From This Page…" would ask, for the page context menu;
    /// `nil` leaves the item out (relations-explorer.md §2.11).
    var exploreHere: (() -> ExplorerQuery?)?
    /// Asks that question, when the item is chosen.
    var onExplore: ((ExplorerQuery) -> Void)?
    /// What the page reported under the last right-click, for the menu.
    @ObservationIgnored fileprivate var contextTarget: ReaderContextTarget?

    /// Called when the shell has (re)loaded and there is nothing queued: the
    /// owner should render whatever it is showing again. That is how the
    /// reader comes back from a WebContent crash or a stray Reload.
    var onReady: (() -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var pendingRequest: RenderRequest?
    @ObservationIgnored private var loadedPath: String?
    /// Searched for once the next render reports back.
    @ObservationIgnored private var pendingFind: [String]?

    /// An offline reader has nothing worth persisting, and a non-persistent
    /// store means nothing about the wiki lands in a WebKit cache directory.
    /// One for every reader: each store brings a network process of its own
    /// (plans/reader-comforts.md §1.9).
    @MainActor static let sharedDataStore: WKWebsiteDataStore = .nonPersistent()

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
        guard request.path != loadedPath || request.anchor != nil else { return }
        loadedPath = request.path
        outline = []
        lastRenderError = nil

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
    func find(_ needle: String, backwards: Bool) async -> Bool {
        guard !needle.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        guard let result = try? await webView.find(needle, configuration: configuration)
        else { return false }
        return result.matchFound
    }

    /// The first of `candidates` that occurs on the page, found and shown
    /// with the system's find highlight.
    func findFirst(of candidates: [String]) async -> Bool {
        for candidate in candidates where await find(candidate, backwards: false) {
            return true
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
            if let pending = pendingRequest {
                pendingRequest = nil
                render(pending)
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

        case "scrolled":
            // `@Observable` notifies on every assignment, changed or not.
            let heading = message["heading"] as? String
            if heading != activeHeadingID { activeHeadingID = heading }

        case "navigate":
            guard let href = message["href"] as? String,
                  let destination = CCwikiURL.destination(of: href)
            else { return }
            // `ccwiki.js` reports ⌘ or ⇧ as one `modified` flag; the table
            // reads them as it reads every click.
            let modified = message["modified"] as? Bool ?? false
            onNavigate?(destination, LinkDisposition.forClick(
                command: modified, shift: false, option: false, middleButton: false))

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

// MARK: - Navigation

extension WebController: WKNavigationDelegate {

    /// WebKit jettisoned the content process. Without this the view stays
    /// blank: `isReady` would still be true and every render would be
    /// evaluated on a dead page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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

        // The shell and its assets are the only things that may ever load.
        if url.scheme == CCwikiURL.scheme,
           case .shell = CCwikiURL.destination(of: url.absoluteString) ?? .shell {
            decisionHandler(.allow)
            return
        }

        // A click that reached here rather than the JS handler — belt and
        // braces, and the layer that keeps a rogue link from loading anything.
        if navigationAction.navigationType == .linkActivated {
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            } else if let destination = CCwikiURL.destination(of: url.absoluteString) {
                onNavigate?(destination, .here)
            }
        }
        decisionHandler(.cancel)
    }
}

extension WebController: WKUIDelegate {
    /// `target="_blank"` must never spawn a window.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            NSWorkspace.shared.open(url)
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
        let copyItems = controller?.contextTarget?.copyItems ?? []
        if !copyItems.isEmpty {
            for (index, item) in copyItems.enumerated() {
                menu.insertItem(Self.menuItem(for: item), at: index)
            }
            menu.insertItem(.separator(), at: copyItems.count)
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
/// the pseudocode block, both or neither. Reported by `ccwiki.js` just ahead
/// of the menu, and turned into the menu's copy items here, where they can
/// be tested without a menu.
struct ReaderContextTarget: Equatable, Sendable {

    /// One copy entry at the top of the menu.
    struct CopyItem: Equatable, Sendable {
        let title: String
        let text: String
        /// Shown in place of the entry above it while Option is held.
        let isAlternate: Bool
    }

    /// The formula's LaTeX as written on the page, without delimiters.
    let tex: String?
    /// The pseudocode block's source, `\algname{…}` taken out.
    let algorithm: String?
    /// The same with the wiki's macros written out, for a document that
    /// does not have the preamble.
    let algorithmExpanded: String?

    /// An empty string counts as absent: there is nothing to copy.
    init(tex: String? = nil, algorithm: String? = nil, algorithmExpanded: String? = nil) {
        self.tex = tex?.isEmpty == false ? tex : nil
        self.algorithm = algorithm?.isEmpty == false ? algorithm : nil
        self.algorithmExpanded = algorithmExpanded?.isEmpty == false ? algorithmExpanded : nil
    }

    /// The bridge message. A JavaScript `null` arrives as `NSNull`, which
    /// reads as absent like anything else that is not a string.
    init(message: [String: Any]) {
        self.init(
            tex: message["tex"] as? String,
            algorithm: message["algorithm"] as? String,
            algorithmExpanded: message["algorithmExpanded"] as? String)
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
