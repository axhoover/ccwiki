import Foundation

/// The resolution table: every slug the site publishes, and what file each one
/// points at.
///
/// Built exactly the way `quartz/build.ts:75-91` builds `ctx.allSlugs`:
/// glob `**/*.*` under `content/` (so a file with no dot in its name is
/// invisible to the site and must be invisible here too), honour
/// `ignorePatterns`, take `slugifyFilePath` of each, then append one slug per
/// frontmatter alias in sorted-markdown-path order.
struct WikiIndex: Sendable {

    /// Patterns from `quartz.config.ts:18`. `Templates/` is excluded from the
    /// site, so its four files are not pages.
    static let ignoredTopLevel: Set<String> = ["private", "Templates", ".obsidian", "vendor"]

    let contentRoot: URL
    /// Every markdown page, keyed by content-relative path.
    let pages: [String: WikiPage]
    /// Non-markdown assets (`Files/Minicrypt.png`), keyed by slug.
    let assets: [String: String]

    /// In Quartz's insertion order — file slugs first, then alias slugs. Order
    /// matters only for the ambiguity diagnostics; the `shortest` search itself
    /// is order-independent because it requires a *unique* match.
    let allSlugs: [String]
    private let slugToPath: [String: String]
    private let aliasOwners: [String: [String]]
    private let basenameIndex: [String: [String]]
    /// Every directory prefix that has at least one page in it.
    let folders: Set<String>

    /// Slugs claimed by more than one page. Quartz resolves these last-write-wins
    /// and says nothing; surfacing them is more useful in an editing tool.
    let ambiguousAliases: [String: [String]]

    // MARK: Building

    static func build(contentRoot: URL) -> WikiIndex {
        let files = Self.contentFiles(root: contentRoot)
        var pages: [String: WikiPage] = [:]
        for path in files where path.hasSuffix(".md") {
            if let page = WikiPage.load(path: path, in: contentRoot) { pages[path] = page }
        }
        return assemble(contentRoot: contentRoot, files: files, pages: pages)
    }

    /// The second half of `build`: every table, from the sorted file list
    /// (`contentFiles(root:)`, assets included) and the markdown pages that
    /// parsed. `build` is `contentFiles`, a `WikiPage` load per `.md` file,
    /// then this; a library load reads each file once, for its fingerprint
    /// and its page together, and calls this too
    /// (plans/reader-comforts.md §3.5, §4.6).
    static func assemble(contentRoot: URL, files: [String], pages: [String: WikiPage]) -> WikiIndex {
        var assets: [String: String] = [:]
        var slugToPath: [String: String] = [:]
        var allSlugs: [String] = []
        var seen: Set<String> = []
        var folders: Set<String> = []

        func appendSlug(_ slug: String) {
            if seen.insert(slug).inserted { allSlugs.append(slug) }
        }

        for path in files {
            let slug = QuartzSlug.slugifyFilePath(path)
            appendSlug(slug)
            if slugToPath[slug] == nil { slugToPath[slug] = path }

            if !path.hasSuffix(".md") {
                assets[slug] = path
            }

            var segments = slug.components(separatedBy: "/")
            segments.removeLast()
            var prefix: [String] = []
            for segment in segments {
                prefix.append(segment)
                folders.insert(prefix.joined(separator: "/"))
            }
        }

        // Aliases enter `allSlugs` during the markdown parse, which runs over
        // `markdownPaths.sort()` (build.ts:80). Always `alias + ".md"`:
        // `getAliasSlugs` (frontmatter.ts) means to keep an alias already
        // ending in `.md`, but compares `getFileExtension(alias)`, which keeps
        // its dot, with "md", so it never does — `Notes.md` is slug `Notes.md`.
        var aliasOwners: [String: [String]] = [:]
        for path in files.filter({ $0.hasSuffix(".md") }).sorted() {
            guard let page = pages[path] else { continue }
            for alias in page.aliases where !alias.isEmpty {
                let slug = QuartzSlug.slugifyFilePath(alias + ".md")
                appendSlug(slug)
                aliasOwners[slug, default: []].append(path)
            }
        }

        var basenameIndex: [String: [String]] = [:]
        for slug in allSlugs {
            basenameIndex[QuartzSlug.lastSegment(slug), default: []].append(slug)
        }

        var ambiguous: [String: [String]] = [:]
        for (slug, owners) in aliasOwners {
            var claimants = owners
            if let file = slugToPath[slug] { claimants.append(file) }
            if claimants.count > 1 { ambiguous[slug] = claimants.sorted() }
        }

        return WikiIndex(
            contentRoot: contentRoot,
            pages: pages,
            assets: assets,
            allSlugs: allSlugs,
            slugToPath: slugToPath,
            aliasOwners: aliasOwners.mapValues { $0.sorted() },
            basenameIndex: basenameIndex,
            folders: folders,
            ambiguousAliases: ambiguous)
    }

    /// This index with `added` pages added, or replacing the page at the
    /// same path: for links to the pages a change adds, in the review and
    /// the editor's preview (plans/corrections.md §6.3). `assemble` over
    /// this index's markdown and asset paths plus the added ones, so an
    /// added page's slug, aliases and folder resolve as they will once the
    /// change is merged.
    func overlaying(_ added: [WikiPage]) -> WikiIndex {
        guard !added.isEmpty else { return self }
        var merged = pages
        for page in added { merged[page.path] = page }
        let files = Set(merged.keys).union(assets.values).sorted()
        return Self.assemble(contentRoot: contentRoot, files: files, pages: merged)
    }

    /// `glob("**/*.*")` with `ignorePatterns` — note the pattern requires a dot
    /// in the *filename*, so an extensionless file is not part of the site.
    static func contentFiles(root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var result: [String] = []
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)

        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(rootPath) else { continue }
            var relative = String(path.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            let first = relative.components(separatedBy: "/")[0]
            if ignoredTopLevel.contains(first) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard !isDirectory else { continue }
            guard (relative as NSString).lastPathComponent.contains(".") else { continue }
            result.append(relative)
        }
        return result.sorted()
    }

    // MARK: Lookup

    func page(atPath path: String) -> WikiPage? { pages[path] }

    func page(forSlug slug: String) -> WikiPage? {
        slugToPath[slug].flatMap { pages[$0] }
    }

    var allPages: [WikiPage] { Array(pages.values) }

    // MARK: Resolution

    enum Target: Equatable, Sendable {
        /// A markdown page in the clone, plus an optional heading anchor.
        case page(path: String, anchor: String?)
        /// A non-markdown file (`Files/Minicrypt.png`).
        case asset(path: String)
        /// A directory with no index note — Quartz generates a listing page
        /// for these, so CCwiki synthesizes one too.
        case folder(slug: String)
        /// `[[#Heading]]` — stays on the current page.
        case samePage(anchor: String)
        case external(url: String)
        case unresolved(reason: String)

        var isResolved: Bool {
            if case .unresolved = self { return false }
            return true
        }
    }

    /// Resolve one wikilink appearing on the page at `sourcePath`.
    ///
    /// Follows `transformLink` (path.ts:264) under the site's configured
    /// `markdownLinkResolution: "shortest"`: read the target as a bare
    /// basename and take the unique match; on zero *or* two-plus matches, fall
    /// back to treating it as an absolute path from the vault root.
    func resolve(_ link: Wikilink, from sourcePath: String) -> Target {
        let target = link.target

        if target.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .external(url: target)
        }

        // ofm.ts:213 slugifies the anchor in place, before resolution.
        let (fp, anchor) = QuartzSlug.splitAnchor(target + (link.rawAnchor ?? ""))
        let displayAnchor: String
        if anchor.isEmpty {
            displayAnchor = ""
        } else {
            let bare = String(anchor.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            displayAnchor = "#" + (link.isBlockRef ? "^" : "") + bare
        }

        if fp.isEmpty {
            guard !displayAnchor.isEmpty else { return .unresolved(reason: "empty link") }
            return .samePage(anchor: String(displayAnchor.dropFirst()))
        }

        // An embed addresses the file itself; the anchor is not part of the URL.
        let linkText = link.isEmbed ? fp : fp + displayAnchor

        let relative = QuartzSlug.transformInternalLink(linkText)
        let canonical = QuartzSlug.stripSlashes(String(relative.dropFirst()))
        let (targetCanonical, targetAnchor) = QuartzSlug.splitAnchor(canonical)

        // A relative target keeps its `.` and `..` segments at the front
        // (`../Primitives/prf` → `./Primitives/prf`), and no slug starts with
        // one. The site joins it to the path up to the root and lets URL
        // resolution (`CrawlLinks`) drop them, so it names the slug after
        // them. Never by basename: the site matches the target with its dots
        // still on, which no file name equals.
        let segments = targetCanonical.split(separator: "/", omittingEmptySubsequences: false)
        let isRelative = segments.first.map(Self.isDotSegment) ?? false
        let lookup = isRelative
            ? segments.drop(while: Self.isDotSegment).joined(separator: "/")
            : targetCanonical

        let matches = isRelative ? [] : (basenameIndex[lookup] ?? [])
        let slug = matches.count == 1 ? matches[0] : lookup
        let anchorText = targetAnchor.isEmpty ? nil : String(targetAnchor.dropFirst())

        // `[[index]]`, `[[/]]` and `[[./]]` canonicalize to the empty slug,
        // which `transformLink`'s fallback joins to `./`: the home page. So
        // does a relative `..` or `../`, which climbs to the root.
        if slug.isEmpty, let path = slugToPath["index"], path.hasSuffix(".md") {
            return .page(path: path, anchor: anchorText)
        }
        if let path = slugToPath[slug] {
            return path.hasSuffix(".md")
                ? .page(path: path, anchor: anchorText)
                : .asset(path: path)
        }
        if let owners = aliasOwners[slug], let owner = owners.first {
            return .page(path: owner, anchor: anchorText)
        }
        if let path = slugToPath[slug + "/index"] {
            return .page(path: path, anchor: anchorText)
        }
        if folders.contains(slug) {
            return .folder(slug: slug)
        }
        return .unresolved(reason: "no page, alias or folder named “\(lookup)”")
    }

    /// `.` or `..`: a segment URL resolution removes.
    private static func isDotSegment(_ segment: Substring) -> Bool {
        segment == "." || segment == ".."
    }

    /// `resolve` for a sweep over every page, which repeats most links (the
    /// corpus has 3,447 links and 972 distinct ones): each distinct link is
    /// resolved once. `resolve` reads only what `Key` keeps of a link, and
    /// never the page it is on, so a link resolves alike from any page.
    /// Lives as long as the sweep, one `backlinkMap` (plans/efficiency.md, L4).
    struct LinkResolutions {
        private let index: WikiIndex
        private var targets: [Key: Target] = [:]

        init(_ index: WikiIndex) {
            self.index = index
        }

        /// How many distinct links have been resolved.
        var count: Int { targets.count }

        /// `index.resolve(link, from: sourcePath)`.
        mutating func target(of link: Wikilink, from sourcePath: String) -> Target {
            let key = Key(link)
            if let known = targets[key] { return known }
            let target = index.resolve(link, from: sourcePath)
            targets[key] = target
            return target
        }

        /// What `resolve` reads of a link: its target, its raw anchor (which
        /// says whether it is a block reference), and whether it is an embed.
        /// Compared byte for byte: `String`'s `==` is canonical equivalence,
        /// and two spellings of one accented letter need not slug alike.
        private struct Key: Hashable {
            let target: [UInt8]
            let rawAnchor: [UInt8]?
            let isEmbed: Bool

            init(_ link: Wikilink) {
                target = Array(link.target.utf8)
                rawAnchor = link.rawAnchor.map { Array($0.utf8) }
                isEmbed = link.isEmbed
            }
        }
    }

    /// Every link on a page, paired with what it resolves to.
    func links(on page: WikiPage) -> [(link: Wikilink, target: Target)] {
        Self.outgoingLinks(in: page.body).map { ($0, resolve($0, from: page.path)) }
    }

    /// The links in a page body that name a wiki target, in source order: its
    /// `[[wikilinks]]`, and its markdown links to wiki pages as the wikilinks
    /// they stand for. The wiki writes the second kind wherever a link's text
    /// holds math, so a page reached only that way is still linked to.
    static func outgoingLinks(in body: String) -> [Wikilink] {
        let links = LinkParse.links(in: body)
        return (links.wikilinks + links.markdownLinks.map(\.wikilink))
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Backlinks

    /// path → the paths of every page that links to it. Built once per index
    /// because it needs a full sweep; the corpus is 293 pages and 673 links, so
    /// this takes a few milliseconds.
    func backlinkMap() -> [String: [Backlink]] {
        var result: [String: [Backlink]] = [:]
        var resolutions = LinkResolutions(self)
        for page in pages.values.sorted(by: { $0.path < $1.path }) {
            var seen: Set<String> = []
            for link in Self.outgoingLinks(in: page.body) {
                guard case .page(let targetPath, _) = resolutions.target(of: link, from: page.path),
                      targetPath != page.path,
                      seen.insert(targetPath).inserted
                else { continue }
                result[targetPath, default: []].append(
                    Backlink(sourcePath: page.path, line: Self.line(of: link, in: page.body)))
            }
        }
        return result
    }

    struct Backlink: Identifiable, Hashable, Sendable {
        let sourcePath: String
        /// The line the link appeared on, as markdown: a slice of the linking
        /// page's body, so a load copies nothing and reduces nothing for it.
        let line: Substring

        /// The line the link appeared on, reduced to plain text, so the pane
        /// can show *why* the page links here rather than just that it does.
        ///
        /// The raw line is full of `[[wikilinks]]`, `$math$` and `_emphasis_`,
        /// and a backlinks pane that shows markup instead of prose is
        /// unreadable. Worked out when read: a load finds about 2,500
        /// backlinks, and the busiest page shows 44 (plans/efficiency.md, L3).
        var context: String { WikiIndex.plainText(String(line)) }

        /// `backlinkMap` keeps one backlink per linking page for each target,
        /// so the linking page tells a target's backlinks apart.
        var id: String { sourcePath }
    }

    /// The line a link appeared on.
    private static func line(of link: Wikilink, in body: String) -> Substring {
        let start = MarkdownLineEnd.start(in: body, before: link.range.lowerBound)
        let end = MarkdownLineEnd.next(in: body, from: link.range.upperBound).end
        return body[start..<end]
    }

    /// Strip the markdown that carries no meaning once it is out of context.
    static func plainText(_ markdown: String) -> String {
        var text = markdown.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(
            of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
        // [[target|display]] → display, [[target]] → target
        text = text.replacingOccurrences(
            of: #"!?\[\[[^\[\]\|]*\|([^\[\]]*)\]\]"#, with: "$1",
            options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"!?\[\[([^\[\]]*)\]\]"#, with: "$1", options: .regularExpression)
        // [text](url) → text
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Footnote markers carry nothing here.
        text = text.replacingOccurrences(
            of: #"\[\^[^\]]*\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])"#, with: "$1",
            options: .regularExpression)
        text = text.replacingOccurrences(of: "`", with: "")
        text = droppingMathDelimiters(text)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `text` with the delimiters of its math dropped and, outside the math,
    /// its backslash escapes resolved: `$x^2$` reads `x^2`, and `IND\$-CPA`
    /// reads `IND$-CPA` rather than `IND\-CPA`. Inside math a backslash is
    /// TeX (`\,`, `\{`) and stays. A run of n dollars closes at the next run
    /// of exactly n, as `RelationMeta.escapeOutsideMath` reads it; a run that
    /// closes nothing is a literal dollar, which is how the page shows it.
    private static func droppingMathDelimiters(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count,
               MarkdownLinkParser.isASCIIPunctuation(scalars[i + 1].value) {
                out.append(scalars[i + 1])
                i += 2
            } else if c == "$" {
                var end = i
                while end < scalars.count, scalars[end] == "$" { end += 1 }
                let length = end - i
                var close: Int?
                var j = end
                while j < scalars.count, close == nil {
                    guard scalars[j] == "$" else { j += 1; continue }
                    var k = j
                    while k < scalars.count, scalars[k] == "$" { k += 1 }
                    if k - j == length { close = j }
                    j = k
                }
                if let close {
                    out.append(contentsOf: scalars[end..<close])
                    i = close + length
                } else {
                    out.append(contentsOf: scalars[i..<end])
                    i = end
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }
}
