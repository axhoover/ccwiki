import Foundation

/// What kind of page this is. Mirrors the wiki's `type:` frontmatter key and
/// the directory it lives in — the repo's lint enforces that the two agree
/// (`scripts/lint.mjs` rule `schema-type-dir`), so where they disagree the
/// directory wins and the mismatch becomes a warning.
enum PageKind: String, CaseIterable, Sendable {
    case primitive
    case assumption
    case complexityClass = "complexity-class"
    case glossary
    case folklore
    case reference
    case note
    case reduction
    case separation

    /// The `content/` subdirectory this kind lives in; `note` lives at the root.
    var directory: String? {
        switch self {
        case .primitive: "Primitives"
        case .assumption: "Assumptions"
        case .complexityClass: "Complexity"
        case .glossary: "Glossary"
        case .folklore: "Folklore"
        case .reference: "References"
        case .note, .reduction, .separation: nil
        }
    }

    static func forDirectory(_ directory: String) -> PageKind {
        allCases.first { $0.directory == directory } ?? .note
    }

    var symbolName: String {
        switch self {
        case .primitive: "cube"
        case .assumption: "questionmark.diamond"
        case .complexityClass: "chart.bar"
        case .glossary: "character.book.closed"
        case .folklore: "quote.bubble"
        case .reference: "doc.text"
        case .note, .reduction, .separation: "note.text"
        }
    }
}

/// Editorial state, shown as a per-page badge in the sidebar.
///
/// `complete` is a human judgement the lint then holds to a stricter contract
/// (no TODO markers, mandated sections present), which is why an ingestion job
/// must never set it. No page in the wiki carries it today; the badge exists
/// because the schema does.
enum PageStatus: String, CaseIterable, Sendable {
    case stub, draft, complete

    var label: String { rawValue.capitalized }

    /// Sorted least-finished first, which is the useful order when you are
    /// looking for something to work on.
    var rank: Int {
        switch self {
        case .stub: 0
        case .draft: 1
        case .complete: 2
        }
    }
}

/// One markdown page in the clone.
///
/// Cheap to build — the body is kept as a slice of the file text rather than
/// re-parsed — so the whole 297-page corpus can be loaded eagerly on launch.
struct WikiPage: Identifiable, Sendable {
    /// Path relative to `content/`, e.g. `Primitives/pseudorandom-function.md`.
    /// This is the identity: the wiki treats a filename as a live URL and never
    /// renames one.
    let path: String
    /// The Quartz `FullSlug`, e.g. `Primitives/pseudorandom-function`.
    let slug: String
    let title: String
    let aliases: [String]
    let kind: PageKind
    let status: PageStatus
    let frontmatter: Frontmatter
    /// Markdown after the closing `---`.
    let body: String

    var id: String { path }

    /// The filename without its extension — the fallback title, and for a
    /// reference page the `KEY - Full Title` string that carries the real
    /// paper title.
    var stem: String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }

    /// For references the frontmatter `title` is the *citation key*, so the
    /// paper title has to come from the filename.
    var displayTitle: String {
        guard kind == .reference else { return title }
        let stem = stem
        guard let separator = stem.range(of: " - ") else { return stem }
        return String(stem[separator.upperBound...])
    }

    /// The short label for the sidebar and the quick switcher: the citation key
    /// for references, the title everywhere else.
    var shortTitle: String { kind == .reference ? title : title }

    var authors: String? { frontmatter.string("authors") }
    var venue: String? { frontmatter.string("venue") }
    var source: String? { frontmatter.string("source") }
    var published: String? { frontmatter.string("published") }

    /// `2025-01-01` almost always means "only the year is known" in this
    /// corpus, so show the year alone; the full string is kept for sorting.
    var publishedDisplay: String? {
        guard let published else { return nil }
        return published.hasSuffix("-01-01") ? String(published.prefix(4)) : published
    }

    // MARK: Loading

    static func load(path: String, in contentRoot: URL) -> WikiPage? {
        let url = contentRoot.appending(path: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WikiPage(path: path, text: text)
    }

    init(path: String, text: String) {
        let frontmatter = Frontmatter.parse(text)
        self.path = path
        self.slug = QuartzSlug.slugifyFilePath(path)
        self.frontmatter = frontmatter
        self.body = String(text[frontmatter.bodyStart...])
        self.aliases = frontmatter.list("aliases")

        let stem = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".md", with: "")
        self.title = frontmatter.string("title") ?? stem

        let directory = (path as NSString).deletingLastPathComponent
        self.kind = PageKind.forDirectory(directory)

        self.status = frontmatter.string("status")
            .flatMap { PageStatus(rawValue: $0.lowercased()) } ?? .draft
    }

    // MARK: Outline

    /// Headings with the ids Quartz would assign them: `rehype-slug` uses a
    /// per-document *deduplicating* `GithubSlugger`, so a second `## Syntax`
    /// becomes `syntax-1`.
    ///
    /// The webview computes the same ids independently when it renders; this
    /// copy exists so the outline can be shown before (and without) a render.
    func headings() -> [Heading] {
        var slugger = GithubSlugger()
        var result: [Heading] = []
        let inert = CodeMask.inertRanges(in: body)

        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: "\n") ?? body.endIndex
            defer {
                lineStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
            }

            let line = body[lineStart..<lineEnd]
            guard line.hasPrefix("#") else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { continue }
            // A `#` inside a fenced block is a comment, not a heading.
            guard !inert.contains(where: { $0.contains(lineStart) }) else { continue }

            let text = Heading.plainText(
                String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }
            result.append(Heading(level: hashes, text: text, id: slugger.slug(text)))
        }
        return result
    }

    struct Heading: Identifiable, Hashable, Sendable {
        let level: Int
        let text: String
        let id: String
    }
}

extension WikiPage.Heading {
    /// Strips the inline markup that `rehype-slug` never sees, so the anchor is
    /// computed from the same text Quartz uses: `$…$` loses its delimiters but
    /// keeps its source, wikilinks collapse to their display text, and
    /// emphasis markers disappear.
    static func plainText(_ markdown: String) -> String {
        var out = markdown

        // [[target|display]] → display; [[target]] → target
        out = out.replacingOccurrences(
            of: #"\[\[([^\[\]\|]*)\|([^\[\]]*)\]\]"#,
            with: "$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"\[\[([^\[\]]*)\]\]"#, with: "$1", options: .regularExpression)
        // [text](url) → text
        out = out.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Delimiters only — github-slugger deletes `$` anyway, but leaving them
        // in would also leave the space they sometimes carry.
        out = out.replacingOccurrences(of: "$", with: "")
        out = out.replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(
            of: #"\*\*|__|\*|(?<![A-Za-z0-9])_"#, with: "", options: .regularExpression)

        return out.trimmingCharacters(in: .whitespaces)
    }
}
