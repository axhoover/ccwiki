import Foundation
import WebKit

/// Serves the reader's content over `ccwiki://`, from two roots.
///
/// Two reasons this exists rather than `loadFileURL`:
///
/// 1. **A Content-Security-Policy can only be delivered as a response header.**
///    With a file URL the best available is a `<meta http-equiv>` tag, which
///    takes effect only from where it is parsed and cannot express
///    `frame-ancestors`. The header below is the app's guarantee that reading
///    never touches the network.
/// 2. **Two roots.** The vendored pipeline lives in the app bundle; the wiki
///    lives in Application Support. `allowingReadAccessTo` grants one directory
///    per load.
///
/// `loadHTMLString(_:baseURL:)` is not an option at all: with a `file:` base
/// URL the document cannot load sibling resources, so KaTeX never arrives.
final class CCwikiSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {

    /// `style-src` must keep `'unsafe-inline'`: KaTeX emits hundreds of inline
    /// `style="height:1.19em"` attributes per page and CSP3 governs those —
    /// without it every strut collapses to zero height and the math turns to
    /// overlapping soup. `script-src` stays strict, which is what actually
    /// matters: inline `<script>` cannot run, so wiki markdown cannot execute.
    private static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "font-src 'self'",
        "img-src 'self' data:",
        "media-src 'self'",
        "connect-src 'none'",
        "frame-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    private let bundleRoot: URL
    private let contentRoot: URL

    init(bundleRoot: URL, contentRoot: URL) {
        self.bundleRoot = bundleRoot.standardizedFileURL
        self.contentRoot = contentRoot.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        var path = url.path(percentEncoded: false)
        if path.isEmpty || path == "/" { path = "/_/index.html" }

        let root: URL
        let relative: String
        if path.hasPrefix("/_/") {
            root = bundleRoot
            relative = String(path.dropFirst(3))
        } else if path.hasPrefix("/asset/") {
            root = contentRoot
            relative = String(path.dropFirst("/asset/".count))
        } else {
            // `page/` and `folder/` URLs exist to be intercepted by the click
            // handler; nothing should ever navigate to one.
            respond(task, url: url, status: 404, mime: "text/plain",
                    data: Data("not a loadable resource".utf8))
            return
        }

        let file = root.appending(path: relative).standardizedFileURL
        // Refuse anything that climbs out of its root. Both sides are
        // normalized first: a URL built from a directory carries a trailing
        // slash, and comparing against `root + "/"` would then test for a
        // double slash and reject every legitimate file.
        guard Self.isContained(file, in: root), let data = try? Data(contentsOf: file) else {
            respond(task, url: url, status: 404, mime: "text/plain",
                    data: Data("not found: \(relative)".utf8))
            return
        }

        respond(task, url: url, status: 200,
                mime: Self.mimeType(for: file.pathExtension), data: data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Every response above is synchronous, so there is nothing in flight
        // to cancel. (Calling back into a stopped task raises an ObjC
        // exception, which is why this must stay true.)
    }

    private func respond(
        _ task: any WKURLSchemeTask, url: URL, status: Int, mime: String, data: Data
    ) {
        var headers = [
            "Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if mime == "text/html" { headers["Content-Security-Policy"] = Self.contentSecurityPolicy }

        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// True when `file` is `root` itself or sits underneath it, comparing
    /// slash-normalized paths so a trailing slash on either side is harmless.
    static func isContained(_ file: URL, in root: URL) -> Bool {
        func normalize(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let filePath = normalize(file)
        let rootPath = normalize(root)
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json": "application/json"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }
}
