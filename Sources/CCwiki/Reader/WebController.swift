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

    /// Set by the owner to act on a link click.
    var onNavigate: ((CCwikiURL.Destination, _ modified: Bool) -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var pendingRequest: RenderRequest?
    @ObservationIgnored private var loadedPath: String?

    init(paths: AppPaths, macros: MacroTable) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            CCwikiSchemeHandler(bundleRoot: paths.webRoot, contentRoot: paths.content),
            forURLScheme: CCwikiURL.scheme)
        // An offline reader has nothing worth persisting, and a non-persistent
        // store means nothing about the wiki lands in a WebKit cache directory.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        // The macro table has to exist before any script runs. A user script at
        // documentStart is also the only way to inject it under
        // `script-src 'self'` — an inline <script> would be blocked.
        controller.addUserScript(WKUserScript(
            source: "window.__CCWIKI__ = { macros: \(macros.katexJSON()) };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        controller.add(Bridge(controller: self), name: "ccwiki")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Without this the web view paints its own white backdrop before the
        // first frame, which reads as a flash on every navigation in dark mode.
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        webView.load(URLRequest(url: CCwikiURL.shell))
    }

    // MARK: Rendering

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
            isReady = true
            if let pending = pendingRequest {
                pendingRequest = nil
                render(pending)
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
            if let errors = message["pseudocodeErrors"] as? Int, errors > 0 {
                lastRenderError = "\(errors) pseudocode block(s) failed to render."
            }

        case "scrolled":
            activeHeadingID = message["heading"] as? String

        case "navigate":
            guard let href = message["href"] as? String,
                  let destination = CCwikiURL.destination(of: href)
            else { return }
            onNavigate?(destination, message["modified"] as? Bool ?? false)

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
                onNavigate?(destination, false)
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
