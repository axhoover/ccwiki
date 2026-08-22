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

            if path.hasSuffix(".md") {
                if let page = WikiPage.load(path: path, in: contentRoot) { pages[path] = page }
            } else {
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
        // `markdownPaths.sort()` (build.ts:80).
        var aliasOwners: [String: [String]] = [:]
        for path in files.filter({ $0.hasSuffix(".md") }).sorted() {
            guard let page = pages[path] else { continue }
            for alias in page.aliases where !alias.isEmpty {
                let slug = QuartzSlug.slugifyFilePath(
                    QuartzSlug.fileExtension(alias) == ".md" ? alias : alias + ".md")
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

        let matches = basenameIndex[targetCanonical] ?? []
        let slug = matches.count == 1 ? matches[0] : targetCanonical
        let anchorText = targetAnchor.isEmpty ? nil : String(targetAnchor.dropFirst())

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
        return .unresolved(reason: "no page, alias or folder named “\(targetCanonical)”")
    }

    /// Every wikilink on a page, paired with what it resolves to.
    func links(on page: WikiPage) -> [(link: Wikilink, target: Target)] {
        WikilinkParser.links(in: page.body).map { ($0, resolve($0, from: page.path)) }
    }

    // MARK: Backlinks

    /// path → the paths of every page that links to it. Built once per index
    /// because it needs a full sweep; the corpus is 293 pages and 673 links, so
    /// this takes a few milliseconds.
    func backlinkMap() -> [String: [Backlink]] {
        var result: [String: [Backlink]] = [:]
        for page in pages.values.sorted(by: { $0.path < $1.path }) {
            var seen: Set<String> = []
            for link in WikilinkParser.links(in: page.body) {
                guard case .page(let targetPath, _) = resolve(link, from: page.path),
                      targetPath != page.path,
                      seen.insert(targetPath).inserted
                else { continue }
                result[targetPath, default: []].append(
                    Backlink(sourcePath: page.path, context: Self.context(of: link, in: page.body)))
            }
        }
        return result
    }

    struct Backlink: Identifiable, Hashable, Sendable {
        let sourcePath: String
        /// The line the link appeared on, so the pane can show *why* the page
        /// links here rather than just that it does.
        let context: String

        var id: String { sourcePath + context }
    }

    /// The line a link appeared on, reduced to plain text.
    ///
    /// The raw line is full of `[[wikilinks]]`, `$math$` and `_emphasis_`, and
    /// a backlinks pane that shows markup instead of prose is unreadable — the
    /// whole point of the pane is to tell you *why* another page links here.
    private static func context(of link: Wikilink, in body: String) -> String {
        var start = link.range.lowerBound
        while start > body.startIndex {
            let previous = body.index(before: start)
            if body[previous] == "\n" { break }
            start = previous
        }
        let end = body[link.range.upperBound...].firstIndex(of: "\n") ?? body.endIndex
        return plainText(String(body[start..<end]))
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
        text = text.replacingOccurrences(of: "$", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
