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
    /// KaTeX's `macros` option, `\calA` → `\mathcal{A}`. Sent with every
    /// request rather than once at startup, because on a fresh install the
    /// clone — and so `macros.ts` — does not exist until after the first sync.
    var macros: [String: String] = [:]
    /// Keep the reader's scroll position across the render. For a re-render
    /// of the page already showing — after a pull, or a listing toggle —
    /// where jumping to the top would lose the reader's place.
    var preservesScroll = false

    struct Notice: Sendable {
        let level: String  // "info" | "warning"
        let text: String
    }

    /// The JSON payload handed to `CCwiki.render`.
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
            "macros": macros,
            "preserveScroll": preservesScroll,
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
    /// Pages the manifest marks `unlisted`. They are real nodes and stay
    /// reachable by link, by search and from a relation row — they are only
    /// kept off the folder listings, which is what "unlisted" means.
    var hiddenPaths: Set<String> = []
    /// Add the "N links have no target" notice. The links are styled as
    /// broken either way; the banner is for someone maintaining the wiki.
    var reportsBrokenLinks = true

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
                    href: CCwikiURL.page(path: path, anchor: anchor),
                    kind: "page", external: false, isImage: false)
            case .asset(let path):
                let ext = (path as NSString).pathExtension.lowercased()
                links[raw] = RenderRequest.ResolvedLink(
                    href: CCwikiURL.asset(path: path),
                    kind: "asset", external: false,
                    isImage: Self.imageExtensions.contains(ext))
            case .folder(let slug):
                links[raw] = RenderRequest.ResolvedLink(
                    href: CCwikiURL.folder(slug: slug),
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
        if reportsBrokenLinks, brokenCount > 0 {
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
    ///
    /// CCwiki adds two things the site's version does not have, because its
    /// version of this page is not asked to hold 200 rows: alphabetical
    /// dividers that stick to the top of the viewport while you scroll their
    /// group, and the option to leave stubs out.
    func folderRequest(
        slug: String, hidingStubs: Bool = false, notices: [RenderRequest.Notice] = []
    ) -> RenderRequest {
        let all = index.pages.values.filter {
            $0.slug.hasPrefix(slug + "/") && !hiddenPaths.contains($0.path)
        }
        let hidden = hidingStubs ? all.count { $0.status == .stub } : 0
        let children = all
            .filter { !hidingStubs || $0.status != .stub }
            .sorted { sortKey($0) < sortKey($1) }

        var html = "<h1>\(Self.escape(slug))</h1>\n"
        html += "<p class=\"folder-count\">\(children.count) page"
        html += children.count == 1 ? "" : "s"
        if hidden > 0 { html += " · \(hidden) stub\(hidden == 1 ? "" : "s") hidden" }
        html += "</p>\n"

        // Group by the first character of the sort key — a citation key in
        // References, a title everywhere else.
        var currentLetter: String?
        var open = false
        for page in children {
            let letter = Self.dividerLetter(sortKey(page))
            if letter != currentLetter {
                if open { html += "</ul>\n</section>\n" }
                currentLetter = letter
                open = true
                html += "<section class=\"folder-group\">\n"
                html += "<h2 class=\"folder-letter\">\(Self.escape(letter))</h2>\n"
                html += "<ul class=\"folder-list\">\n"
            }
            html += row(for: page)
        }
        if open { html += "</ul>\n</section>\n" }

        if children.isEmpty {
            html += "<p class=\"placeholder\">Nothing here"
            html += hidden > 0 ? " but stubs." : "."
            html += "</p>\n"
        }

        return RenderRequest(
            path: slug,
            title: slug,
            markdown: "",
            html: html,
            links: [:],
            anchor: nil,
            notices: notices)
    }

    private func row(for page: WikiPage) -> String {
        var html = "<li><span class=\"folder-title\"><a class=\"internal\" href=\""
        html += Self.escape(CCwikiURL.page(path: page.path)) + "\">"
        html += Self.escape(page.title) + "</a></span>"
        if page.kind == .reference {
            html += "<span class=\"folder-meta\">" + Self.escape(page.displayTitle) + "</span>"
        } else {
            html += "<span class=\"folder-meta folder-status-\(page.status.rawValue)\">"
            html += page.status.label + "</span>"
        }
        return html + "</li>\n"
    }

    /// Quartz sorts folder listings by `frontmatter.title` lower-cased.
    private func sortKey(_ page: WikiPage) -> String { page.title.lowercased() }

    /// The heading a page files under. Anything not starting with a letter —
    /// `#P`, a digit — groups together rather than making a divider of its own.
    static func dividerLetter(_ key: String) -> String {
        guard let first = key.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
