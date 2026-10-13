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
    /// One hyperedge, as a page: `content/Reductions/owf-to-prg.md`. There are
    /// 343 of them, and they arrived with the wiki's reductions migration —
    /// before it, relationships lived in prose on the endpoint pages.
    case reduction
    /// A statement that some class of reduction cannot exist, 37 of them in
    /// `content/Barriers/`. The wiki calls these barriers rather than
    /// separations, because one type covers both a black-box separation and the
    /// Impagliazzo–Rudich shape where the consequence is `P ≠ NP` instead of a
    /// contradiction.
    case barrier

    /// The `content/` subdirectory this kind lives in; `note` lives at the root.
    var directory: String? {
        switch self {
        case .primitive: "Primitives"
        case .assumption: "Assumptions"
        case .complexityClass: "Complexity"
        case .glossary: "Glossary"
        case .folklore: "Folklore"
        case .reference: "References"
        case .reduction: "Reductions"
        case .barrier: "Barriers"
        case .note: nil
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
        case .reduction: "arrow.right"
        case .barrier: "nosign"
        case .note: "note.text"
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
        Self.stem(of: path)
    }

    /// The filename with a trailing `.md` removed — only a trailing one, as
    /// `path.parse(fp).name` does in Quartz.
    static func stem(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
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
    var shortTitle: String { title }

    /// The `[[…]]` another page would use to link here: the citation key
    /// with the filename for a reference, whose filename is not its key, and
    /// the last slug segment for everything else.
    var wikilink: String {
        kind == .reference
            ? "[[\(stem)|\(title)]]"
            : "[[\(slug.components(separatedBy: "/").last ?? stem)]]"
    }

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
        guard let data = try? Data(contentsOf: contentRoot.appending(path: path)) else { return nil }
        return load(path: path, data: data)
    }

    /// The page in `data`, a file's bytes as read once; nil unless they are
    /// UTF-8. Every load parses with this, and the fingerprint scan hashes the
    /// same `Data` it parses, so a page and its digest can never disagree
    /// about a byte-order mark or a bad byte (plans/reader-comforts.md §3.5).
    static func load(path: String, data: Data) -> WikiPage? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return WikiPage(path: path, text: text)
    }

    init(path: String, text: String) {
        let frontmatter = Frontmatter.parse(text)
        self.path = path
        self.slug = QuartzSlug.slugifyFilePath(path)
        self.frontmatter = frontmatter
        self.body = String(text[frontmatter.bodyStart...])
        self.aliases = frontmatter.list("aliases")

        self.title = frontmatter.string("title") ?? Self.stem(of: path)

        let directory = (path as NSString).deletingLastPathComponent
        self.kind = PageKind.forDirectory(directory)

        self.status = frontmatter.string("status")
            .flatMap { PageStatus(rawValue: $0.lowercased()) } ?? .draft
    }

    // MARK: Outline

    /// A CommonMark ATX heading, as markdown-it reads one — which is what
    /// the web view renders and so what its anchors are built from. Up to
    /// three spaces of indent; one to six `#`; then a space, a tab, or the
    /// end of the line; and an optional closing run of `#` after a space,
    /// which is not part of the text. Returns the level and the raw text.
    static func atxHeading(_ line: Substring) -> (level: Int, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let afterHashes = rest.dropFirst(level)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t"
        else { return nil }

        var text = afterHashes.trimmingCharacters(in: .whitespaces)
        // A closing sequence: `#`s that are the whole text, or that follow a
        // space. `C#` keeps its `#`; `Foo ##` loses them.
        if text.allSatisfy({ $0 == "#" }) {
            text = ""
        } else if let range = text.range(of: #"[ \t]+#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

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
            let lineEnd = body[lineStart...].firstIndex(where: \.isMarkdownLineEnding) ?? body.endIndex
            defer {
                lineStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
            }

            guard let (level, raw) = Self.atxHeading(body[lineStart..<lineEnd]) else { continue }
            // A `#` inside a fenced block is a comment, not a heading.
            guard !inert.contains(where: { $0.contains(lineStart) }) else { continue }

            let text = Heading.plainText(raw)
            guard !text.isEmpty else { continue }
            result.append(Heading(level: level, text: text, id: slugger.slug(text)))
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
    /// The heading's text as `ccwiki-markdown.js`'s `headingPlainText` reads
    /// it from markdown-it's tokens, which is the text `rehype-slug` slugs on
    /// the site: a wikilink is its alias, or its target without the anchor;
    /// a markdown link is its text; math and code keep their source, losing
    /// only their delimiters; a backslash escape is the character escaped;
    /// and emphasis loses its markers.
    ///
    /// Underscores need the care, because github-slugger keeps `_`: only a
    /// pair markdown-it reads as emphasis goes, so `_k_` reads `k` while
    /// `snake_case` and the `_` in `$\mathsf{Enc}_k$` stay.
    static func plainText(_ markdown: String) -> String {
        // Text that is already final (a link's display text, a math or code
        // span, an escaped character) stands in as one private-use scalar
        // while the emphasis around it is undone, so nothing inside changes.
        var literals: [String] = []
        // The markdown each wikilink's placeholder stands for. markdown-it
        // reads whichever starts first, so a link inside math is that
        // span's source, `$[[a]]$` reading `[[a]]`, as the renderer has it.
        var linkSources: [Int: String] = [:]
        func protect(_ text: String) -> String {
            guard let marker = Unicode.Scalar(Self.literalBase + UInt32(literals.count))
            else { return text }
            literals.append(text)
            return String(Character(marker))
        }

        // markdown-it reads a wikilink before anything inside it.
        var linked = ""
        var cursor = markdown.startIndex
        for link in WikilinkParser.links(in: markdown) {
            linked.append(contentsOf: markdown[cursor..<link.range.lowerBound])
            let alias = link.alias ?? ""
            linkSources[literals.count] = String(markdown[link.range])
            linked.append(protect(alias.isEmpty ? link.target : alias))
            cursor = link.range.upperBound
        }
        linked.append(contentsOf: markdown[cursor...])
        // [text](url) → text
        linked = linked.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)

        let scalars = Array(linked.unicodeScalars)
        var masked = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count,
               MarkdownLinkParser.isASCIIPunctuation(scalars[i + 1].value) {
                masked.append(contentsOf: protect(String(Character(scalars[i + 1]))).unicodeScalars)
                i += 2
                continue
            }
            guard c == "$" || c == "`" else {
                masked.append(c)
                i += 1
                continue
            }
            // A span closes at the next run of exactly as many `$` or
            // backticks; a run that closes nothing is literal. As in
            // `ccwiki.js`'s `mathInline`, a `$` right after an unescaped `$`
            // opens nothing.
            var end = i
            while end < scalars.count, scalars[end] == c { end += 1 }
            var opens = true
            if c == "$", i > 0, scalars[i - 1] == "$" {
                var backslashes = 0
                var k = i - 2
                while k >= 0, scalars[k] == "\\" { backslashes += 1; k -= 1 }
                opens = backslashes % 2 == 1
            }
            var closing: Int?
            var j = end
            while opens, closing == nil, j < scalars.count {
                guard scalars[j] == c else { j += 1; continue }
                var k = j
                while k < scalars.count, scalars[k] == c { k += 1 }
                if k - j == end - i { closing = j }
                j = k
            }
            guard let close = closing else {
                masked.append(contentsOf: scalars[i..<end])
                i = end
                continue
            }
            // One space comes off each end when both ends have one: for math
            // unless the span is all spaces, for code as markdown-it's
            // `^ (.+) $` has it.
            var content = scalars[end..<close]
            let isPadding: (Unicode.Scalar) -> Bool = { $0 == " " || (c == "$" && $0 == "\n") }
            if let first = content.first, let last = content.last,
               isPadding(first), isPadding(last),
               c == "$" ? !content.allSatisfy(isPadding) : content.count >= 3 {
                content = content.dropFirst().dropLast()
            }
            var source = String.UnicodeScalarView()
            for scalar in content {
                if let link = linkSources[Int(scalar.value) - Int(Self.literalBase)] {
                    source.append(contentsOf: link.unicodeScalars)
                } else {
                    source.append(scalar)
                }
            }
            masked.append(contentsOf: protect(String(source)).unicodeScalars)
            i = close + (end - i)
        }

        var plain = String(masked)
        for pattern in Self.emphasisPatterns {
            plain = plain.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        // github-slugger deletes `*` anyway; an escaped one is protected.
        plain = plain.replacingOccurrences(of: "*", with: "")

        var out = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars {
            let slot = Int(scalar.value) - Int(Self.literalBase)
            if literals.indices.contains(slot) {
                out.append(contentsOf: literals[slot].unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// The first of `plainText`'s placeholders, in plane 15's private use
    /// area, which no heading holds.
    private static let literalBase: UInt32 = 0xF0000

    /// `__strong__`, then `_emphasis_`, where markdown-it reads them as such:
    /// the opening run not after a letter or digit and not before a space,
    /// the closing run the reverse. A placeholder stands for a span whose
    /// delimiters are punctuation, so it counts as punctuation here.
    private static let emphasisPatterns: [String] = ["__", "_"].map { run in
        let word = #"[^\s\p{P}\p{S}\x{F0000}-\x{FFFFD}]"#
        return #"(?<!\#(word))(?<!_)\#(run)(?![\s_])(.+?)(?<![\s_])\#(run)(?!_)(?!\#(word))"#
    }
}
