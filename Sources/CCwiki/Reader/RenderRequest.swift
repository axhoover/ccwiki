import Foundation

/// Everything the web view needs to draw one page.
///
/// The division of labour: **Swift resolves, JavaScript renders.** Link
/// resolution is the part with a hundred and fifty test vectors behind it, so
/// it stays in Swift; markdown, KaTeX and pseudocode.js only exist in
/// JavaScript, so rendering stays there. The bridge between them is this
/// `links` map, keyed by the exact raw `[[…]]` text — both sides parse
/// wikilinks with the same regex, so the keys line up by construction. A
/// markdown link `[text](slug#anchor)` is keyed by its destination, which is
/// the string markdown-it hands to `normalizeLink` and `ccwiki.js` recovers.
///
/// Notably, the links are *not* rewritten before they cross. Splicing
/// `[text](url)` into the source would mean editing a string that also contains
/// `$…$` and fenced TeX, which is where escaping bugs live. The one addition is
/// the site's relation-meta line under the H1 of a reduction or barrier page
/// (`RelationMeta`): a whole paragraph inserted between lines, never an edit
/// inside one, and spliced before the links are collected, so its own links
/// go through this map like the body's.
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
    /// The page body, frontmatter already stripped, with the relation-meta
    /// line spliced in on a reduction or barrier page.
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
    /// Return to where this page was last left, if it has been shown before:
    /// set for Back and Forward.
    var restoresScroll = false
    /// A hover card per page link, keyed by the resolved `href` rather than
    /// the raw link text: several links share a target, and the href is the
    /// string `ccwiki.js` reads back from the link it is over. Empty when
    /// previews are off, and then the payload carries no `previews` at all.
    var previews: [String: LinkPreview] = [:]
    /// The commit the page was read from, `headRevision` at render time. It
    /// goes into the payload, and `ccwiki.js` returns it with a selection,
    /// so a correction is built at the revision the reader was shown
    /// (plans/corrections.md §3.5). Nil for the app's own pages.
    var revision: String?

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
            "restoreScroll": restoresScroll,
        ]
        if let html { payload["html"] = html }
        if let anchor { payload["anchor"] = anchor }
        if let revision { payload["revision"] = revision }
        if !previews.isEmpty { payload["previews"] = previews.mapValues(\.jsonObject) }

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
    /// What the relation-meta line under a reduction or barrier page's H1 is
    /// built with: the manifest names the conclusion's type and the objects a
    /// barrier assumes, and the labels name a variant in a clone too old to
    /// title it. Both empty, the line comes from the frontmatter alone.
    var relations = RelationsManifest.empty
    var relationLabels = RelationLabels.empty
    /// The hover cards for the library, and whether to send any: cleared by
    /// Settings → Reading → Show link previews on hover, which leaves the
    /// payload without them, so `ccwiki.js` needs no flag of its own.
    var linkPreviews = LinkPreviews.empty
    var buildsPreviews = true

    /// Image extensions the reader inlines for `![[…]]` embeds.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg",
    ]

    func request(for page: WikiPage, anchor: String? = nil, notices: [RenderRequest.Notice] = [])
        -> RenderRequest {
        // The site's line of relation fields goes in first, so its links are
        // collected and resolved with the body's. Only into a clone that has
        // the reduction-classes page: it arrived in the same wiki commit as the
        // site's line, so a clone without it predates the line. The site built
        // from that clone showed none, and here the line's class links would
        // go nowhere and raise the broken-link notice on every page with one.
        var markdown = page.body
        let classPage = Wikilink(
            target: RelationMeta.classPage, rawAnchor: nil, alias: nil, isEmbed: false,
            range: page.body.startIndex..<page.body.startIndex)
        if index.resolve(classPage, from: page.path).isResolved,
           let line = RelationMeta.line(
               for: page.frontmatter, manifest: relations, labels: relationLabels) {
            markdown = RelationMeta.insertUnderH1(line, into: markdown)
        }

        var links: [String: RenderRequest.ResolvedLink] = [:]
        var previews: [String: LinkPreview] = [:]
        var brokenCount = 0

        for (raw, link) in Self.keyedLinks(in: markdown) {
            guard links[raw] == nil else { continue }

            switch index.resolve(link, from: page.path) {
            case .page(let path, let anchor):
                let href = CCwikiURL.page(path: path, anchor: anchor)
                links[raw] = RenderRequest.ResolvedLink(
                    href: href, kind: "page", external: false, isImage: false)
                // Only a link that leaves the page gets a card: one to the
                // page itself, anchored or not, would describe what is
                // already on screen.
                if buildsPreviews, path != page.path, previews[href] == nil,
                   let preview = linkPreviews.preview(path: path, anchor: anchor) {
                    previews[href] = preview
                }
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

        var request = RenderRequest(
            path: page.path,
            title: page.displayTitle,
            markdown: markdown,
            html: nil,
            links: links,
            anchor: anchor,
            notices: allNotices)
        request.previews = previews
        return request
    }

    /// Every link in `markdown`, keyed by the string `ccwiki.js` looks it up
    /// by: a wikilink by its raw `[[…]]` text, a markdown link by its
    /// destination. The wikilinks, then the markdown links, each in source
    /// order, all from one `LinkParse`.
    static func keyedLinks(in markdown: String) -> [(raw: String, link: Wikilink)] {
        let parsed = LinkParse.links(in: markdown)
        var keyed: [(raw: String, link: Wikilink)] = parsed.wikilinks.map {
            (raw: String(markdown[$0.range]), link: $0)
        }
        keyed += parsed.markdownLinks.map {
            (raw: $0.destination, link: $0.wikilink)
        }
        return keyed
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
        let children = Self.listingOrder(all.filter { !hidingStubs || $0.status != .stub })

        var html = "<h1>\(Self.escape(slug))</h1>\n"
        html += "<p class=\"folder-count\">\(children.count) page"
        html += children.count == 1 ? "" : "s"
        if hidden > 0 { html += " · \(hidden) stub\(hidden == 1 ? "" : "s") hidden" }
        html += "</p>\n"

        // Group by the first letter of the title — a citation key in
        // References — as the site's folder page does: one group per letter,
        // in the order each first appears, so `#` holds a `$k$-…` title that
        // sorts first and a Greek one that sorts last.
        var groups: [(letter: String, pages: [WikiPage])] = []
        for page in children {
            let letter = Self.dividerLetter(page.title)
            if let existing = groups.firstIndex(where: { $0.letter == letter }) {
                groups[existing].pages.append(page)
            } else {
                groups.append((letter: letter, pages: [page]))
            }
        }
        for group in groups {
            html += "<section class=\"folder-group\">\n"
            html += "<h2 class=\"folder-letter\">\(Self.escape(group.letter))</h2>\n"
            html += "<ul class=\"folder-list\">\n"
            for page in group.pages { html += row(for: page) }
            html += "</ul>\n</section>\n"
        }

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

    /// The site's folder order: `frontmatter.title` lower-cased, compared with
    /// `localeCompare` (`quartz.config.ts`), which is ICU collation rather
    /// than code-point order — `CRHF ⇒ PCS` before `CRHF + One-time
    /// signature ⇒ DS`, `IND-CPA ⇔ …` before `IND-CPA PKE ⇒ …`. A fixed
    /// locale, so the order does not follow the reader's region, and the path
    /// breaks a tie, so it is the same every time.
    static func listingOrder(_ pages: [WikiPage]) -> [WikiPage] {
        let keyed = pages.map { (page: $0, key: $0.title.lowercased()) }
        let ordered = keyed.sorted { lhs, rhs in
            let order = lhs.key.compare(rhs.key, locale: Self.collationLocale)
            return order == .orderedSame
                ? lhs.page.path < rhs.page.path
                : order == .orderedAscending
        }
        return ordered.map { $0.page }
    }

    private static let collationLocale = Locale(identifier: "en_US")

    /// The heading a page files under, as `FolderContent.tsx` picks it: the
    /// title's first character upper-cased if that is a letter A–Z, and `#`
    /// for anything else — `#P`, a digit, `$k$`, a Greek letter.
    static func dividerLetter(_ title: String) -> String {
        guard let first = title.unicodeScalars.first else { return "#" }
        let letter = String(first).uppercased()
        return letter.unicodeScalars.contains { (0x41...0x5A).contains($0.value) } ? letter : "#"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
