import Foundation

/// Everything the web view needs to draw one page.
///
/// The division of labour: **Swift resolves, JavaScript renders.** Link
/// resolution is the part with a hundred and fifty test vectors behind it, so
/// it stays in Swift; markdown, KaTeX and pseudocode.js only exist in
/// JavaScript, so rendering stays there. The bridge between them is this
/// `links` map, keyed by the exact raw `[[…]]` text — both sides parse
/// wikilinks with the same regex, so the keys line up by construction.
///
/// Notably, the markdown is *not* rewritten before it crosses. Splicing
/// `[text](url)` into the source would mean editing a string that also contains
/// `$…$` and fenced TeX, which is where escaping bugs live.
struct RenderRequest: Sendable {

    struct ResolvedLink: Sendable {
        let href: String
        /// `page`, `folder`, `asset`, `anchor` or `external` — the CSS hook.
        let kind: String
        let external: Bool
        /// For `![[image.png]]`.
        let isImage: Bool
    }

    let path: String
    let title: String
    /// The page body, frontmatter already stripped.
    let markdown: String
    /// Pre-built HTML, used instead of `markdown` for synthetic pages.
    let html: String?
    let links: [String: ResolvedLink]
    /// A heading id to scroll to once rendering finishes.
    let anchor: String?
    /// Shown above the page — a macro-parse failure, a broken-link count.
    let notices: [Notice]

    struct Notice: Sendable {
        let level: String  // "info" | "warning"
        let text: String
    }

    /// The JSON payload handed to `CityDesk.render`.
    func jsonPayload() -> String {
        var linkObject: [String: Any] = [:]
        for (raw, link) in links {
            linkObject[raw] = [
                "href": link.href,
                "kind": link.kind,
                "external": link.external,
                "isImage": link.isImage,
            ]
        }
        var payload: [String: Any] = [
            "path": path,
            "title": title,
            "markdown": markdown,
            "links": linkObject,
            "notices": notices.map { ["level": $0.level, "text": $0.text] },
        ]
        if let html { payload["html"] = html }
        if let anchor { payload["anchor"] = anchor }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

/// Turns a `WikiPage` (or a folder) into a `RenderRequest`.
struct PageRenderer: Sendable {

    let index: WikiIndex

    /// Image extensions the reader inlines for `![[…]]` embeds.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg",
    ]

    func request(for page: WikiPage, anchor: String? = nil, notices: [RenderRequest.Notice] = [])
        -> RenderRequest {
        var links: [String: RenderRequest.ResolvedLink] = [:]
        var brokenCount = 0

        for link in WikilinkParser.links(in: page.body) {
            let raw = String(page.body[link.range])
            guard links[raw] == nil else { continue }

            switch index.resolve(link, from: page.path) {
            case .page(let path, let anchor):
                links[raw] = RenderRequest.ResolvedLink(
                    href: CityDeskURL.page(path: path, anchor: anchor),
                    kind: "page", external: false, isImage: false)
            case .asset(let path):
                let ext = (path as NSString).pathExtension.lowercased()
                links[raw] = RenderRequest.ResolvedLink(
                    href: CityDeskURL.asset(path: path),
                    kind: "asset", external: false,
                    isImage: Self.imageExtensions.contains(ext))
            case .folder(let slug):
                links[raw] = RenderRequest.ResolvedLink(
                    href: CityDeskURL.folder(slug: slug),
                    kind: "folder", external: false, isImage: false)
            case .samePage(let anchor):
                links[raw] = RenderRequest.ResolvedLink(
                    href: "#\(anchor)", kind: "anchor", external: false, isImage: false)
            case .external(let url):
                links[raw] = RenderRequest.ResolvedLink(
                    href: url, kind: "external", external: true, isImage: false)
            case .unresolved:
                brokenCount += 1
            }
        }

        var allNotices = notices
        if brokenCount > 0 {
            allNotices.append(RenderRequest.Notice(
                level: "info",
                text: brokenCount == 1
                    ? "1 link on this page has no target."
                    : "\(brokenCount) links on this page have no target."))
        }

        return RenderRequest(
            path: page.path,
            title: page.displayTitle,
            markdown: page.body,
            html: nil,
            links: links,
            anchor: anchor,
            notices: allNotices)
    }

    /// A synthetic listing for `[[Primitives]]`-style links.
    ///
    /// Quartz generates one of these per directory with its `FolderPage`
    /// emitter, sorted by `frontmatter.title` lower-cased (`quartz.config.ts`
    /// configures exactly that comparator). Since the site publishes them, the
    /// reader has to have them too, or six links on the front page go nowhere.
    func folderRequest(slug: String, notices: [RenderRequest.Notice] = []) -> RenderRequest {
        let children = index.pages.values
            .filter { $0.slug.hasPrefix(slug + "/") }
            .sorted {
                $0.title.lowercased().compare($1.title.lowercased(), options: [], range: nil,
                                              locale: .current) == .orderedAscending
            }

        var html = "<h1>\(Self.escape(slug))</h1>\n"
        html += "<p class=\"folder-count\">\(children.count) page"
        html += children.count == 1 ? "" : "s"
        html += "</p>\n<ul class=\"folder-list\">\n"
        for page in children {
            let href = CityDeskURL.page(path: page.path)
            html += "<li><span class=\"folder-title\"><a class=\"internal\" href=\""
            html += Self.escape(href) + "\">" + Self.escape(page.title) + "</a></span>"
            if page.kind == .reference {
                html += "<span class=\"folder-meta\">" + Self.escape(page.displayTitle) + "</span>"
            } else {
                html += "<span class=\"folder-meta\">" + page.status.label + "</span>"
            }
            html += "</li>\n"
        }
        html += "</ul>\n"

        return RenderRequest(
            path: slug,
            title: slug,
            markdown: "",
            html: html,
            links: [:],
            anchor: nil,
            notices: notices)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
