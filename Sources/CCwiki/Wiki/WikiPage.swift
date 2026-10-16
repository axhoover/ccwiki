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
    /// The webview computes the same ids independently when it renders, and
    /// the outline takes its headings from that render. This copy is for
    /// what reads a page without rendering it: search and relation labels.
    /// Only ATX lines outside fences and `%%` comments count (see
    /// plans/render-pipeline.md, "Still different from the site").
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
    /// the site: a wikilink is its alias, decoded (`IND\$-CPA` reads
    /// `IND$-CPA`), or its target without the anchor; a markdown link is its
    /// text; math and code keep their source, losing only their delimiters;
    /// a link markdown-it makes of a URL or an address (`https://…`,
    /// `<https://…>`, `name@host`) is that text, educated on its own; a
    /// backslash escape or a character reference is the character it stands
    /// for; and emphasis loses its markers.
    ///
    /// Underscores need the care, because github-slugger keeps `_`: only a
    /// pair markdown-it reads as emphasis goes, so `_k_` reads `k` while
    /// `snake_case` and the `_` in `$\mathsf{Enc}_k$` stay.
    ///
    /// The rest of the text is educated as the page educates it before the
    /// ids are made (`educated`): `## A -> B` reads `A → B`, and its id is
    /// `a--b`, not `a---b`. A URL's or an address's text is educated too, as
    /// the site's smartypants educates a link's text, but by itself, as the
    /// page educates its token: `## See https://x.org/a--b` reads
    /// `See https://x.org/a—b`, and `<https://x.org/a->-b` keeps its `--`.
    static func plainText(_ markdown: String) -> String {
        // Text that is already final (a link's display text, a math or code
        // span, an escape) stands in as one private-use scalar while the
        // emphasis around it is undone, so nothing inside changes.
        var literals: [String] = []
        // The markdown each wikilink's placeholder stands for. markdown-it
        // reads whichever starts first, so a link inside math is that
        // span's source, `$[[a]]$` reading `[[a]]`, as the renderer has it.
        var linkSources: [Int: String] = [:]
        // The placeholders of escapes and character references, markdown-it's
        // `text_special` tokens; what each joins the text around it with
        // before the page educates it; and those that stand for the `\` of
        // an escape that keeps it (`\a`), whose next character is theirs.
        var specials: Set<Int> = []
        var joined: [Int: Unicode.Scalar] = [:]
        var keptBackslashes: Set<Int> = []
        func protect(_ text: String, wordLike: Bool = false) -> String {
            let base = wordLike ? Self.wordLiteralBase : Self.literalBase
            guard let marker = Unicode.Scalar(base + UInt32(literals.count))
            else { return text }
            literals.append(text)
            return String(Character(marker))
        }
        // The index in `literals` a placeholder stands for.
        func slot(_ scalar: Unicode.Scalar) -> Int {
            let base = scalar.value >= Self.wordLiteralBase ? Self.wordLiteralBase : Self.literalBase
            return Int(scalar.value) - Int(base)
        }

        // markdown-it reads a wikilink before anything inside it.
        var linked = ""
        var cursor = markdown.startIndex
        for link in WikilinkParser.links(in: markdown) {
            linked.append(contentsOf: markdown[cursor..<link.range.lowerBound])
            // Decoded, then trimmed, as the page reads an alias.
            let alias = MarkdownLinkParser.unescape(link.alias ?? "")
                .trimmingCharacters(in: .whitespaces)
            linkSources[literals.count] = String(markdown[link.range])
            linked.append(protect(alias.isEmpty ? link.target : alias))
            cursor = link.range.upperBound
        }
        linked.append(contentsOf: markdown[cursor...])

        // [text](url) → text, between two marks where markdown-it has its
        // link_open and link_close. The `](url)` each closing mark stands
        // for is kept, for a URL or an autolink that runs on over it.
        var linkEnds: [String] = []
        var reduced = ""
        let linkedText = linked as NSString
        var copied = 0
        for match in Self.markdownLink.matches(
            in: linked, range: NSRange(location: 0, length: linkedText.length)) {
            let label = match.range(at: 1)
            reduced += linkedText.substring(
                with: NSRange(location: copied, length: match.range.location - copied))
            reduced += String(Character(Self.linkOpen)) + linkedText.substring(with: label)
                + String(Character(Self.linkClose))
            linkEnds.append(linkedText.substring(with: NSRange(
                location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label))))
            copied = NSMaxRange(match.range)
        }
        reduced += linkedText.substring(from: copied)

        let scalars = Array(reduced.unicodeScalars)
        var linkEndAt: [Int: String] = [:]
        var ordinal = 0
        for (index, scalar) in scalars.enumerated() where scalar == Self.linkClose {
            if linkEnds.indices.contains(ordinal) { linkEndAt[index] = linkEnds[ordinal] }
            ordinal += 1
        }
        // The markdown `scalars[index]` stands for.
        func sourceOf(_ index: Int) -> String {
            let scalar = scalars[index]
            if scalar == Self.linkOpen { return "[" }
            if scalar == Self.linkClose { return linkEndAt[index] ?? "" }
            return linkSources[slot(scalar)] ?? String(Character(scalar))
        }
        func source(_ range: Range<Int>) -> String {
            range.map(sourceOf).joined()
        }
        // How many scalars from `start` stand for exactly the first `length`
        // UTF-16 units of `source(start..<scalars.count)`, if a whole number
        // of them does.
        func scalarCount(from start: Int, utf16Length length: Int) -> Int? {
            var index = start
            var size = 0
            while size < length, index < scalars.count {
                size += sourceOf(index).utf16.count
                index += 1
            }
            return size == length ? index - start : nil
        }

        var masked = String.UnicodeScalarView()
        // Where the text markdown-it holds as pending starts: after the last
        // token that is not text.
        var runStart = 0
        var inLinkText = false
        // An escape or a character reference markdown-it decodes. ASCII
        // punctuation but `_` and `*` joins the text before the page
        // educates it (`\->` is an arrow); the emphasis rules read each one
        // as punctuation, as they read the `\` or `;` in the source.
        func appendSpecial(_ text: String) {
            let index = literals.count
            masked.append(contentsOf: protect(text).unicodeScalars)
            specials.insert(index)
            let decoded = text.unicodeScalars
            if decoded.count == 1, let scalar = decoded.first, scalar != "_", scalar != "*",
               MarkdownLinkParser.isASCIIPunctuation(scalar.value) {
                joined[index] = scalar
            }
        }
        // A span, a URL or an autolink can take in an end of a link's text;
        // the marks in `masked` follow, so the link's text stays known.
        func consume(_ range: Range<Int>) {
            guard let mark = scalars[range].last(where: { $0 == Self.linkOpen || $0 == Self.linkClose }),
                  (mark == Self.linkOpen) != inLinkText
            else { return }
            inLinkText = mark == Self.linkOpen
            masked.append(mark)
        }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == Self.linkOpen || c == Self.linkClose {
                inLinkText = c == Self.linkOpen
                masked.append(c)
                i += 1
                runStart = i
                continue
            }
            if c == "\\", i + 1 < scalars.count {
                let next = scalars[i + 1]
                if MarkdownLinkParser.isASCIIPunctuation(next.value) {
                    appendSpecial(String(Character(next)))
                    i += 2
                    runStart = i
                    continue
                }
                // markdown-it 15 reads `\` and any other character as one
                // token too, which keeps both: `\a` ends a run of text.
                if next.value < Self.literalBase {
                    let index = literals.count
                    masked.append(contentsOf: protect("\\").unicodeScalars)
                    specials.insert(index)
                    joined[index] = "\\"
                    keptBackslashes.insert(index)
                    masked.append(next)
                    i += 2
                    runStart = i
                    continue
                }
            }
            // markdown-it's entity rule: `&amp;` reads `&`. Only the
            // references `MarkdownLinkParser.unescape` knows are decoded;
            // any other stays as written.
            if c == "&", let semicolon = scalars[(i + 1)...].prefix(33).firstIndex(of: ";") {
                let reference = String(String.UnicodeScalarView(scalars[i...semicolon]))
                let decoded = MarkdownLinkParser.unescape(reference)
                if decoded != reference,
                   reference.range(of: Self.entityPattern, options: .regularExpression) != nil {
                    appendSpecial(decoded)
                    i = semicolon + 1
                    runStart = i
                    continue
                }
            }
            // markdown-it's autolink rule: `<https://…>` or `<name@host>`, up
            // to the next `<` or `>` in the markdown. A link's text, which
            // the page educates by itself.
            if c == "<" {
                let rest = source(i..<scalars.count) as NSString
                let close = rest.length > 1
                    ? rest.rangeOfCharacter(
                        from: Self.angleBrackets, options: [],
                        range: NSRange(location: 1, length: rest.length - 1)).location
                    : NSNotFound
                if close != NSNotFound, rest.character(at: close) == 0x3E {
                    let url = rest.substring(with: NSRange(location: 1, length: close - 1))
                    if Linkify.isAutolink(url), let count = scalarCount(from: i, utf16Length: close + 1) {
                        masked.append(contentsOf: protect(Self.educatedLinkText(url)).unicodeScalars)
                        consume(i..<(i + count))
                        i += count
                        runStart = i
                        continue
                    }
                }
            }
            // markdown-it's linkify rule, at the `://` after a scheme's name
            // that ends the pending text: the URL linkify-it reads there in
            // the markdown, less its last `*`s. It starts with a letter, and
            // the emphasis rules read its placeholder as one.
            if c == ":", !inLinkText, i + 2 < scalars.count, scalars[i + 1] == "/", scalars[i + 2] == "/" {
                var start = i
                while start > runStart, Self.isSchemeCharacter(scalars[start - 1]) { start -= 1 }
                if start < i, Self.isASCIILetter(scalars[start]),
                   let url = Linkify.url(
                    atStartOf: source(start..<scalars.count),
                    scheme: String(String.UnicodeScalarView(scalars[start..<i]))),
                   let count = scalarCount(from: start, utf16Length: url.utf16.count) {
                    masked.removeLast(i - start)
                    masked.append(contentsOf: protect(Self.educatedLinkText(url), wordLike: true).unicodeScalars)
                    consume(start..<(start + count))
                    i = start + count
                    runStart = i
                    continue
                }
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
            masked.append(contentsOf: protect(source(content.indices)).unicodeScalars)
            consume(i..<(close + (end - i)))
            i = close + (end - i)
            runStart = i
        }

        // `__strong__` and `_emphasis_` lose their markers to a mark each,
        // which ends the text either side, as markdown-it's tokens end it.
        let boundary = String(Character(Self.emphasisMark))
        var plain = String(masked)
        for pattern in Self.emphasisPatterns {
            plain = plain.replacingOccurrences(
                of: pattern, with: boundary + "$1" + boundary, options: .regularExpression)
        }

        // markdown-it's linkify core rule: in a heading linkify-it finds a
        // link in, each run of text between tokens (not a link's text) takes
        // the links linkify-it finds in it, save one at its start right after
        // an escape. Each link's text is educated by itself.
        if !Linkify.links(in: markdown).isEmpty {
            var linkified = String.UnicodeScalarView()
            var run = String.UnicodeScalarView()
            var inLink = false
            var afterSpecial = false
            var backslashKept = false
            func flush() {
                defer { run.removeAll() }
                guard !inLink, !run.isEmpty else {
                    linkified.append(contentsOf: run)
                    return
                }
                let text = String(run)
                let ns = text as NSString
                var links = Linkify.links(in: text)
                if afterSpecial, links.first?.location == 0 { links.removeFirst() }
                var taken = 0
                for link in links {
                    linkified.append(contentsOf: ns.substring(
                        with: NSRange(location: taken, length: link.location - taken)).unicodeScalars)
                    linkified.append(
                        contentsOf: protect(Self.educatedLinkText(ns.substring(with: link))).unicodeScalars)
                    taken = NSMaxRange(link)
                }
                linkified.append(contentsOf: ns.substring(from: taken).unicodeScalars)
            }
            for scalar in plain.unicodeScalars {
                guard scalar.value >= Self.literalBase else {
                    if backslashKept {
                        linkified.append(scalar)
                        backslashKept = false
                    } else {
                        run.append(scalar)
                    }
                    continue
                }
                flush()
                linkified.append(scalar)
                if scalar == Self.linkOpen { inLink = true }
                if scalar == Self.linkClose { inLink = false }
                afterSpecial = specials.contains(slot(scalar))
                backslashKept = keptBackslashes.contains(slot(scalar))
            }
            flush()
            plain = String(linkified)
        }

        // ccwiki_backticks, on the text between tokens before they join.
        plain = Self.latexQuotes(plain)

        // markdown-it joins an escape or a reference to the text either side
        // (`text_join`) before the page educates it: `\->` is an arrow.
        var joinedText = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars {
            if scalar.value >= Self.literalBase, let character = joined[slot(scalar)] {
                joinedText.append(character)
            } else {
                joinedText.append(scalar)
            }
        }
        plain = Self.educated(String(joinedText))
        // github-slugger deletes `*` anyway; an escaped one is protected.
        plain = plain.replacingOccurrences(of: "*", with: "")

        var out = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars {
            guard scalar.value >= Self.literalBase else {
                out.append(scalar)
                continue
            }
            guard scalar != Self.linkOpen, scalar != Self.linkClose, scalar != Self.emphasisMark
            else { continue }
            let index = slot(scalar)
            if literals.indices.contains(index) {
                out.append(contentsOf: literals[index].unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// The first of `plainText`'s placeholders, in plane 15's private use
    /// area, which no heading holds.
    private static let literalBase: UInt32 = 0xF0000

    /// The first placeholder the emphasis rules read as a letter: a URL's,
    /// which starts with one. In plane 16's private use area.
    private static let wordLiteralBase: UInt32 = 0x100000

    /// Where markdown-it has a token and `plainText` no placeholder: the two
    /// ends of a markdown link's text, and an emphasis marker. The last
    /// scalars of plane 15's private use area, which the emphasis rules read
    /// as punctuation, as they read the `[`, `]` and `_` these stand for.
    private static let linkOpen: Unicode.Scalar = "\u{FFFFB}"
    private static let linkClose: Unicode.Scalar = "\u{FFFFC}"
    private static let emphasisMark: Unicode.Scalar = "\u{FFFFD}"

    /// `[text](url)`, as `plainText` reads a markdown link.
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let angleBrackets = CharacterSet(charactersIn: "<>")

    /// `[A-Za-z0-9+.-]`: what a scheme's name is made of.
    private static func isSchemeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2B, 0x2D, 0x2E: true
        default: false
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }

    /// A character reference as markdown-it's entity rule reads one.
    private static let entityPattern =
        #"^&(?:[A-Za-z][A-Za-z0-9]{1,31}|#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7});$"#

    /// `ccwiki-markdown.js`'s `educated`, which `ccwiki_typography` runs on
    /// a heading's text before `ccwiki_heading_ids` makes its id: OFM's
    /// arrows (`->` → →, `<--` → ⇐), then smartypants' `--` (only two) as
    /// an em dash and three or more dots as an ellipsis. github-slugger
    /// deletes all of those, and keeps `-`. The quotes `smartquotes` curls
    /// change no id, so they stay as written; LaTeX's do, before a final
    /// `Σ`, and `plainText` curls those (`ccwiki_backticks`).
    static func educated(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in arrowPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let arrow = ns.substring(with: match.range)
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += arrows[arrow] ?? arrow
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
            .replacingOccurrences(of: #"(^|[^-])--(?!-)"#, with: "$1—", options: .regularExpression)
            .replacingOccurrences(of: #"\.{3,}"#, with: "…", options: .regularExpression)
    }

    /// `ccwiki_backticks`: LaTeX's quotes, ``this'' reading “this”.
    private static func latexQuotes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "(^|[^`])``(?!`)", with: "$1\u{201C}", options: .regularExpression)
            .replacingOccurrences(of: "(^|[^'])''(?!')", with: "$1\u{201D}", options: .regularExpression)
    }

    /// The text of a link markdown-it makes of a URL or an address, as the
    /// page shows it: a `text` token of its own, which `ccwiki_backticks`
    /// and then `ccwiki_typography` edit as they edit any other.
    private static func educatedLinkText(_ text: String) -> String {
        educated(latexQuotes(text))
    }

    /// ofm.ts:121, and what each arrow becomes.
    private static let arrowPattern = try! NSRegularExpression(
        pattern: "(-{1,2}>|={1,2}>|<-{1,2}|<={1,2})")
    private static let arrows: [String: String] = [
        "->": "→", "-->": "⇒", "=>": "⇒", "==>": "⇒",
        "<-": "←", "<--": "⇐", "<=": "⇐", "<==": "⇐",
    ]

    /// `__strong__`, then `_emphasis_`, where markdown-it reads them as such:
    /// the opening run not after a letter or digit and not before a space,
    /// the closing run the reverse. A placeholder stands for a span whose
    /// delimiters are punctuation, so it counts as punctuation here; a
    /// URL's, from plane 16, as the letter it starts with.
    private static let emphasisPatterns: [String] = ["__", "_"].map { run in
        let word = #"[^\s\p{P}\p{S}\x{F0000}-\x{FFFFD}]"#
        return #"(?<!\#(word))(?<!_)\#(run)(?![\s_])(.+?)(?<![\s_])\#(run)(?!_)(?!\#(word))"#
    }
}

// MARK: - Links in a heading

extension WikiPage.Heading {
    /// linkify-it as markdown-it 15 bundles it, which `ccwiki-markdown.js`
    /// turns on: the URLs and addresses markdown-it makes links of, so that
    /// `plainText` reads each one's text as the page does, as a token of its
    /// own: educated by itself, and out of reach of the emphasis, spans and
    /// escapes around it. Its schemes `http:`, `https:`, `ftp:`, `//` and
    /// `mailto:`, and a bare `name@host`; no `www.` or bare-domain links,
    /// and no `user@` in a URL. Its patterns are linkify-it's, in ICU's
    /// syntax; one is nil only if ICU rejected it. Offsets are UTF-16, as
    /// linkify-it's are.
    enum Linkify {
        /// linkify-it's `match`: the links it finds in `text`, in order.
        static func links(in text: String) -> [NSRange] {
            guard let schemes = schemaSearch, let hosts = mailHostSearch, let names = mailName
            else { return [] }
            let ns = text as NSString
            let length = ns.length
            // As a JavaScript regex searches from its `lastIndex`: `^` only at
            // the start of the text.
            func search(_ regex: NSRegularExpression, from start: Int) -> NSTextCheckingResult? {
                regex.firstMatch(
                    in: text, options: .withoutAnchoringBounds,
                    range: NSRange(location: start, length: length - start))
            }
            var links: [NSRange] = []
            var last = 0
            var schemaFrom = 0
            var mailFrom = 0
            var schemasDone = false
            var mailsDone = false
            var mail: NSRange?
            var candidate: (schema: String, start: Int, end: Int)?
            while true {
                let floor = max(last - 1, 0)
                // The next address: a host after an `@`, and the name before it.
                if !mailsDone, mail.map({ $0.location < last }) ?? true {
                    mailFrom = max(mailFrom, floor)
                    while true {
                        guard let host = search(hosts, from: mailFrom) else {
                            mailsDone = true
                            mail = nil
                            break
                        }
                        mailFrom = NSMaxRange(host.range)
                        let nameStart = max(0, host.range.location - 65)
                        let before = ns.substring(
                            with: NSRange(location: nameStart, length: host.range.location - nameStart))
                        guard let name = names.firstMatch(
                            in: before, range: NSRange(location: 0, length: (before as NSString).length))
                        else { continue }
                        let nameLength = name.range(at: 1).length
                        mail = NSRange(
                            location: host.range.location - nameLength, length: nameLength + host.range.length)
                        if host.range.location - nameLength >= last { break }
                        mailFrom = max(mailFrom, floor)
                    }
                }
                // The next scheme that starts a link, if before the address.
                var found: NSRange?
                while !schemasDone {
                    if candidate == nil {
                        schemaFrom = max(schemaFrom, floor)
                        guard let match = search(schemes, from: schemaFrom) else {
                            schemasDone = true
                            break
                        }
                        schemaFrom = NSMaxRange(match.range)
                        candidate = (
                            ns.substring(with: match.range(at: 2)).lowercased(),
                            match.range(at: 2).location, NSMaxRange(match.range))
                    }
                    guard let current = candidate else { break }
                    if current.start < last {
                        candidate = nil
                        continue
                    }
                    if let mail, current.start > mail.location { break }
                    candidate = nil
                    let size = validated(text, schema: current.schema, at: current.end)
                    if size > 0 {
                        found = NSRange(location: current.start, length: current.end + size - current.start)
                        break
                    }
                }
                // Whichever starts first; at the same place, the longer
                // address.
                var chosen = found
                var tookMail = false
                if let address = mail, found.map({ address.location < $0.location
                    || (address.location == $0.location && NSMaxRange(address) > NSMaxRange($0)) }) ?? true {
                    chosen = address
                    tookMail = true
                }
                guard let link = chosen else { break }
                if tookMail { mail = nil }
                links.append(link)
                last = NSMaxRange(link)
            }
            return links
        }

        /// The URL linkify-it reads at the start of `text`, which starts with
        /// `scheme` and `://`, less its last `*`s: markdown-it's linkify rule.
        static func url(atStartOf text: String, scheme: String) -> String? {
            let name = scheme.lowercased()
            guard ["http", "https", "ftp", "mailto"].contains(name) else { return nil }
            let position = scheme.utf16.count + 1
            let size = validated(text, schema: name + ":", at: position)
            guard size > 0 else { return nil }
            var url = (text as NSString).substring(to: position + size)
            while url.hasSuffix("*") { url.removeLast() }
            return url
        }

        /// Whether markdown-it's autolink rule makes a link of `<url>`: a
        /// scheme and no space, or an address; never `javascript:` and the
        /// like (its `validateLink`).
        static func isAutolink(_ url: String) -> Bool {
            let range = NSRange(location: 0, length: (url as NSString).length)
            if autolinkURL?.firstMatch(in: url, range: range) != nil {
                let lowered = url.lowercased()
                return lowered.range(of: "^(?:vbscript|javascript|file|data):", options: .regularExpression) == nil
                    || lowered.range(of: "^data:image/(?:gif|png|jpeg|webp);", options: .regularExpression) != nil
            }
            return autolinkEmail?.firstMatch(in: url, range: range) != nil
        }

        /// How far the link a scheme starts runs on after it, at `position`,
        /// or 0: the scheme's `validate`. `//` after a `:` or a `/` is none.
        private static func validated(_ text: String, schema: String, at position: Int) -> Int {
            let ns = text as NSString
            let validator = schema == "mailto:" ? mailto : schema == "//" ? relative : http
            guard let validator, position <= ns.length,
                  let match = validator.firstMatch(
                    in: text, options: .anchored, range: NSRange(location: position, length: ns.length - position))
            else { return 0 }
            if schema == "//", position >= 3 {
                let before = ns.character(at: position - 3)
                if before == 0x3A || before == 0x2F { return 0 }
            }
            return match.range.length
        }

        private static func compile(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }

        // linkify-it's pieces (its `re.mjs`, with `---` and `urlAuth` off).
        /// `src_pseudo_letter`: not a space, punctuation, a control, `<`,
        /// `>` or `｜`.
        private static let letter = #"[^><\x{FF5C}\p{Z}\p{P}\p{Cc}]"#
        private static let ipv4 =
            #"(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])[.]){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])"#
        private static let hex = "[0-9A-Fa-f]{1,4}"
        private static let ls32 = #"(?:(?:\#(hex):\#(hex))|\#(ipv4))"#
        private static let ipv6: String =
            #"(?:(?:\#(hex):){6}\#(ls32)|::(?:\#(hex):){5}\#(ls32)|(?:\#(hex))?::(?:\#(hex):){4}\#(ls32)"#
            + #"|(?:(?:\#(hex):){0,1}\#(hex))?::(?:\#(hex):){3}\#(ls32)|(?:(?:\#(hex):){0,2}\#(hex))?::(?:\#(hex):){2}\#(ls32)"#
            + #"|(?:(?:\#(hex):){0,3}\#(hex))?::\#(hex):\#(ls32)|(?:(?:\#(hex):){0,4}\#(hex))?::\#(ls32)"#
            + #"|(?:(?:\#(hex):){0,5}\#(hex))?::\#(hex)|(?:(?:\#(hex):){0,6}\#(hex))?::)"#
        private static let port =
            #"(?::(?:6(?:[0-4][0-9]{3}|5(?:[0-4][0-9]{2}|5(?:[0-2][0-9]|3[0-5])))|[1-5]?[0-9]{1,4}))?"#
        private static let hostEnd =
            #"(?=$|[><\x{FF5C}\p{Z}\p{P}\p{Cc}])(?!-|_|:[0-9]|\.-|\.(?!$|[\p{Z}\p{P}\p{Cc}]))"#
        private static let punycode = #"xn--[a-z0-9\-]{1,59}"#
        private static let domain = #"(?:\#(punycode)|(?:\#(letter))|(?:\#(letter)(?:-|\#(letter)){0,61}\#(letter)))"#
        private static let domainRoot = #"(?:\#(punycode)|\#(letter){1,63})"#
        /// `[…]`, `(…)` or `{…}`, nested up to four deep, no space inside.
        private static func nestedPair(_ open: String, _ close: String) -> String {
            let other = #"[^\p{Z}\p{Cc}\#(open)\#(close)]"#
            var pair = "\(open)\(other){0,1000}\(close)"
            for _ in 2...4 {
                pair = "\(open)(?:\(other)|\(pair)){0,1000}\(close)"
            }
            return pair
        }
        private static let brackets = nestedPair(#"\["#, #"\]"#)
        private static let parentheses = nestedPair(#"\("#, #"\)"#)
        private static let braces = nestedPair(#"\{"#, #"\}"#)
        private static let path: String =
            #"(?:[/?#](?:\#(brackets)|\#(parentheses)|\#(braces)|"[^\p{Z}\p{Cc}"]{1,100}"|'[^\p{Z}\p{Cc}']{1,100}'"#
            + #"|'(?=\#(letter)|-)|\.{2,20}:?[a-zA-Z0-9%/&]|\.(?![\p{Z}\p{Cc}.]|$)|-{1,20}|,(?![\p{Z}\p{Cc}]|$)"#
            + #"|;(?![\p{Z}\p{Cc}]|$)|!{1,20}(?![\p{Z}\p{Cc}!]|$)|\?(?![\p{Z}\p{Cc}?]|$)|[\\/:%@#&=_~*]"#
            + #"|[^><\x{FF5C}\p{Z}\p{P}\p{Cc}]){1,10000}|/)?"#
        private static let mailCharacter = #"[\-!#$%&'*+/=?^_`{|}~a-zA-Z0-9]"#
        private static let mailNamePattern =
            #"\#(mailCharacter)(?:\#(mailCharacter)|[.](?=\#(mailCharacter))){0,63}"#
        private static let urlHost =
            #"(?:\[\#(ipv6)\]|(?:(?:(?:\#(domain))\.){0,10}\#(domain)))\#(port)\#(hostEnd)"#
        private static let mailHost =
            #"(?:\[IPv6:\#(ipv6)\]|(?:(?:(?:\#(domain))\.){0,4}\#(domain)))\#(hostEnd)"#
        private static let fuzzyMailHost =
            #"(?:\[IPv6:\#(ipv6)\]|(?:(?:(?:\#(domain))[.]){1,4}\#(domainRoot)))\#(hostEnd)"#

        /// After `http:`, `https:` or `ftp:`.
        private static let http = compile(#"//\#(urlHost)\#(path)"#)
        /// After `//`.
        private static let relative = compile(
            #"(?:localhost|\[\#(ipv6)\]|(?:(?:\#(domain))[.]){1,10}\#(domainRoot))\#(port)\#(hostEnd)\#(path)"#)
        /// After `mailto:`.
        private static let mailto = compile(#"\#(mailNamePattern)@\#(mailHost)"#)
        /// A scheme, at the start or after a space, punctuation or `<`, `>`
        /// or `｜`, but not after `_`.
        private static let schemaSearch = compile(
            #"(^|(?!_)[><\x{FF5C}\p{Z}\p{P}\p{Cc}])(http:|https:|ftp:|//|mailto:)"#)
        private static let mailHostSearch = compile(#"@\#(fuzzyMailHost)"#)
        /// An address's name, at the end of the text before its `@`.
        private static let mailName = compile(
            #"(?:^|[><\x{FF5C}"\(\p{Z}\p{Cc}])(\#(mailNamePattern))$"#, caseInsensitive: false)

        // markdown-it's autolink rule.
        private static let autolinkURL = compile(
            #"^[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\x{0}-\x{20}]*$"#, caseInsensitive: false)
        private static let autolinkEmail = compile(
            #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*$"#,
            caseInsensitive: false)
    }
}
