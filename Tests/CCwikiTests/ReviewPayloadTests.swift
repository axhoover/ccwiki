import Foundation
import Testing
@testable import CCwiki

/// The review's payload for `CCwiki.renderReview` (plans/corrections.md
/// §6.3, §12.1): its keys, which `ReviewEntriesTests` pins from the other
/// side; hunks and flags in each side's own body lines; the frontmatter as
/// source lines; and links resolved against the reader's index overlaid
/// with the pages the change adds.
///
/// The snapshots are built by hand, hunks included, so these tests read the
/// payload alone and not `LineDiff`.
struct ReviewPayloadTests {

    // MARK: Fixtures

    static let prfPath = "content/Primitives/pseudorandom-function.md"
    static let ggmPath = "content/References/GGM86 - How to construct random functions.md"
    static let ggmLink = "[[GGM86 - How to construct random functions|GGM86]]"

    static func file(
        _ path: String = ReviewPayloadTests.prfPath, status: ChangedFile.Status = .modified,
        old: String?, new: String?, hunks: [LineHunk]
    ) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: status, isBinary: false,
            oldText: old, newText: new, hunks: hunks)
    }

    static func snapshot(_ files: ChangedFile...) -> ReviewSnapshot {
        ReviewSnapshot(baseCommit: "865206d47c53", tree: "4b825dc", files: files, digest: "0123")
    }

    static func hunk(_ old: Range<Int>, _ new: Range<Int>) -> LineHunk {
        LineHunk(old: old, new: new)
    }

    /// The payload for `snapshot`, decoded, with no titles, headers or
    /// links unless given.
    static func payload(
        _ snapshot: ReviewSnapshot, findings: [DiffFinding] = [],
        links: [String: RenderRequest.ResolvedLink] = [:], macros: [String: String] = [:]
    ) throws -> [String: Any] {
        let json = ReviewPayload.json(
            snapshot: snapshot, findings: findings,
            title: { _ in nil }, header: { _ in "" }, links: { _ in links }, macros: macros)
        return try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    static func files(_ payload: [String: Any]) throws -> [[String: Any]] {
        try #require(payload["files"] as? [[String: Any]])
    }

    /// Lines 0–3 are the frontmatter; the body starts on file line 5.
    static let prfOld = """
        ---
        title: Pseudorandom function
        status: draft
        ---
        # Pseudorandom function

        A keyed family that $\\calA$ cannot tell from random.

        ## Security

        Secure against every PPT adversary.

        """

    /// The status changes; nothing else.
    static let prfStub = prfOld.replacingOccurrences(of: "status: draft", with: "status: stub")

    /// One more frontmatter line (an alias, line 2), and the paragraph on
    /// file line 7, body line 2, edited: it is file line 8 after.
    static let prfNew = """
        ---
        title: Pseudorandom function
        aliases: [PRF]
        status: draft
        ---
        # Pseudorandom function

        A keyed family that $\\calA$ cannot tell from a random function.

        ## Security

        Secure against every PPT adversary.

        """

    static let prfNewHunks = [hunk(2..<2, 2..<3), hunk(6..<7, 7..<8)]

    // MARK: The keys

    @Test("the payload has exactly §6.3's keys, at every level")
    func keys() throws {
        let link = RenderRequest.ResolvedLink(
            href: CCwikiURL.page(path: "Primitives/one-way-function.md"),
            kind: "page", external: false, isImage: false)
        let finding = DiffFinding(
            rule: .wikilinkMath, severity: .warning, path: Self.prfPath,
            lines: LineRange(first: 8, last: 8), message: "Math in a wikilink breaks the link.")
        let payload = try Self.payload(
            Self.snapshot(Self.file(old: Self.prfOld, new: Self.prfNew, hunks: Self.prfNewHunks)),
            findings: [finding], links: ["[[one-way-function]]": link],
            macros: ["\\calA": "\\mathcal{A}"])

        #expect(Set(payload.keys) == ["macros", "files"])
        #expect(payload["macros"] as? [String: String] == ["\\calA": "\\mathcal{A}"])

        let file = try #require(try Self.files(payload).first)
        #expect(Set(file.keys) == [
            "id", "path", "title", "status", "summary", "isMarkdown", "header",
            "frontmatter", "old", "new", "bodyLine", "hunks", "flags", "links",
        ])
        #expect(file["id"] as? String == "f0")
        #expect(file["path"] as? String == Self.prfPath)
        #expect(file["title"] as? String == "pseudorandom-function.md")
        #expect(file["status"] as? String == "modified")
        #expect(file["isMarkdown"] as? Bool == true)
        #expect(file["header"] as? String == "")

        let bodyLine = try #require(file["bodyLine"] as? [String: Int])
        #expect(Set(bodyLine.keys) == ["old", "new"])

        let hunk = try #require((file["hunks"] as? [[String: Any]])?.first)
        #expect(Set(hunk.keys) == ["old", "new"])

        let entry = try #require((file["frontmatter"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["kind", "text"])

        let flag = try #require((file["flags"] as? [[String: Any]])?.first)
        #expect(Set(flag.keys) == ["lines", "severity", "text"])
        #expect(flag["severity"] as? String == "warning")
        #expect(flag["text"] as? String == "Math in a wikilink breaks the link.")

        let links = try #require(file["links"] as? [String: [String: Any]])
        let resolved = try #require(links["[[one-way-function]]"])
        #expect(Set(resolved.keys) == ["href", "kind", "external", "isImage"])
        #expect(resolved["kind"] as? String == "page")
        #expect(resolved["external"] as? Bool == false)
    }

    @Test("files are numbered in the snapshot's order, and titled by the closure")
    func identities() throws {
        let snapshot = Self.snapshot(
            Self.file(old: Self.prfOld, new: Self.prfStub, hunks: [Self.hunk(2..<3, 2..<3)]),
            Self.file(".reductions/relations.json", old: "{}\n", new: "{ }\n",
                      hunks: [Self.hunk(0..<1, 0..<1)]))
        let json = ReviewPayload.json(
            snapshot: snapshot, findings: [],
            title: { $0 == Self.prfPath ? "Pseudorandom function" : nil },
            header: { _ in "" }, links: { _ in [:] }, macros: [:])
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let files = try Self.files(payload)
        #expect(files.map { $0["id"] as? String } == ["f0", "f1"])
        #expect(files.map { $0["title"] as? String } == ["Pseudorandom function", "relations.json"])
    }

    // MARK: Frontmatter and body

    @Test("a change only to the frontmatter gives frontmatter lines and no hunks")
    func frontmatterOnly() throws {
        let payload = try Self.payload(Self.snapshot(
            Self.file(old: Self.prfOld, new: Self.prfStub, hunks: [Self.hunk(2..<3, 2..<3)])))
        let file = try #require(try Self.files(payload).first)

        #expect((file["hunks"] as? [Any])?.isEmpty == true)
        #expect(file["old"] as? String == file["new"] as? String)
        #expect((file["old"] as? String)?.hasPrefix("# Pseudorandom function\n") == true)

        // One line of context either side; the opening fence, a run of one,
        // is shown rather than gapped.
        let entries = try #require(file["frontmatter"] as? [[String: String]])
        #expect(entries.map { $0["kind"] } == ["context", "context", "removed", "added", "context"])
        #expect(entries.map { $0["text"] } == [
            "---", "title: Pseudorandom function", "status: draft", "status: stub", "---",
        ])
        #expect(file["summary"] as? String == "1 line changed")
    }

    @Test("hunks and flags are in body lines, each side shifted by its own frontmatter")
    func bodyCoordinates() throws {
        let findings = [
            // File line 8 of the new text: the edited paragraph, body line 2
            // counting from 0.
            DiffFinding(
                rule: .largeEdit, severity: .warning, path: Self.prfPath,
                lines: LineRange(first: 8, last: 8), message: "In the body."),
            // The alias: frontmatter, so no body line.
            DiffFinding(
                rule: .statusComplete, severity: .warning, path: Self.prfPath,
                lines: LineRange(first: 3, last: 3), message: "In the frontmatter."),
            DiffFinding(
                rule: .humanVerified, severity: .warning, path: Self.prfPath,
                lines: nil, message: "On the file."),
            // Another file's finding stays with that file.
            DiffFinding(
                rule: .otherPages, severity: .warning, path: "content/Other.md",
                lines: LineRange(first: 1, last: 1), message: "Elsewhere."),
        ]
        let payload = try Self.payload(
            Self.snapshot(Self.file(old: Self.prfOld, new: Self.prfNew, hunks: Self.prfNewHunks)),
            findings: findings)
        let file = try #require(try Self.files(payload).first)

        #expect(file["bodyLine"] as? [String: Int] == ["old": 5, "new": 6])
        let hunks = try #require(file["hunks"] as? [[String: [Int]]])
        #expect(hunks == [["old": [2, 3], "new": [2, 3]]])

        let flags = try #require(file["flags"] as? [[String: Any]])
        #expect(flags.map { $0["text"] as? String } == ["In the body.", "In the frontmatter.", "On the file."])
        #expect(flags.map { $0["lines"] as? [Int] } == [[2, 3], [], []])

        // The body lines the hunk names are the edited paragraph on both sides.
        let oldBody = try #require(file["old"] as? String)
        let newBody = try #require(file["new"] as? String)
        #expect(ReviewPayload.lines(of: oldBody)[2].contains("from random."))
        #expect(ReviewPayload.lines(of: newBody)[2].contains("from a random function."))

        // The added alias, a line of context either side, and each fence,
        // a run of one, shown rather than gapped.
        let entries = try #require(file["frontmatter"] as? [[String: String]])
        #expect(entries.map { $0["kind"] } == ["context", "context", "added", "context", "context"])
        #expect(entries.map { $0["text"] } == [
            "---", "title: Pseudorandom function", "aliases: [PRF]", "status: draft", "---",
        ])
    }

    @Test("a deleted page's flags are read against its old frontmatter")
    func deletedFlags() throws {
        let finding = DiffFinding(
            rule: .renamedOrDeleted, severity: .blocking, path: Self.prfPath,
            lines: LineRange(first: 5, last: 5), message: "Restore the file.")
        let lines = ReviewPayload.lines(of: Self.prfOld).count
        let payload = try Self.payload(
            Self.snapshot(Self.file(
                status: .deleted, old: Self.prfOld, new: nil, hunks: [Self.hunk(0..<lines, 0..<0)])),
            findings: [finding])
        let file = try #require(try Self.files(payload).first)
        #expect(file["status"] as? String == "deleted")
        #expect(file["new"] as? String == "")
        #expect(file["hunks"] as? [[String: [Int]]] == [["old": [0, lines - 4], "new": [0, 0]]])
        #expect((file["flags"] as? [[String: Any]])?.first?["lines"] as? [Int] == [0, 1])
        #expect(file["summary"] as? String == "Deleted, \(lines) lines")
    }

    @Test("a new page is all added: its frontmatter as added lines, its body as one hunk")
    func newPage() throws {
        let lines = ReviewPayload.lines(of: Self.prfOld).count
        let payload = try Self.payload(Self.snapshot(Self.file(
            status: .added, old: nil, new: Self.prfOld, hunks: [Self.hunk(0..<0, 0..<lines)])))
        let file = try #require(try Self.files(payload).first)
        #expect(file["old"] as? String == "")
        #expect(file["hunks"] as? [[String: [Int]]] == [["old": [0, 0], "new": [0, lines - 4]]])
        let entries = try #require(file["frontmatter"] as? [[String: String]])
        #expect(entries.allSatisfy { $0["kind"] == "added" })
        #expect(entries.count == 4)
        #expect(file["summary"] as? String == "New page, \(lines) lines")
    }

    @Test("a file that is not Markdown is one line: no texts, no frontmatter")
    func notMarkdown() throws {
        let json = String(repeating: "{\"id\": 1}\n", count: 50)
        let payload = try Self.payload(Self.snapshot(Self.file(
            ".reductions/relations.json", old: json, new: json + "{}\n",
            hunks: [Self.hunk(50..<50, 50..<51)])))
        let file = try #require(try Self.files(payload).first)
        #expect(file["isMarkdown"] as? Bool == false)
        #expect(file["old"] as? String == "")
        #expect(file["new"] as? String == "")
        #expect((file["frontmatter"] as? [Any])?.isEmpty == true)
        #expect((file["links"] as? [String: Any])?.isEmpty == true)
        #expect(file["summary"] as? String == "+1 \u{2212}0")
    }

    @Test("adding a closing fence moves the body: the whole of each part is shown changed")
    func fenceMoved() {
        // Old: no frontmatter, three body lines. New: the first two lines
        // fenced into frontmatter. The unchanged lines no longer pair up
        // across the boundary, so nothing is mispaired.
        let old = "title: X\nstatus: stub\n# X\n"
        let new = "---\ntitle: X\nstatus: stub\n---\n# X\n"
        let parts = ReviewPayload.split(
            [Self.hunk(0..<0, 0..<1), Self.hunk(2..<2, 3..<4)],
            oldFrontmatter: ReviewPayload.frontmatterLineCount(old),
            newFrontmatter: ReviewPayload.frontmatterLineCount(new),
            oldLineCount: 3, newLineCount: 5)
        #expect(parts.frontmatter == [Self.hunk(0..<0, 0..<4)])
        #expect(parts.body == [Self.hunk(0..<3, 0..<1)])
    }

    @Test("the frontmatter is counted as git counts lines, fences included")
    func frontmatterLines() {
        #expect(ReviewPayload.frontmatterLineCount("# No frontmatter\n") == 0)
        #expect(ReviewPayload.frontmatterLineCount("") == 0)
        #expect(ReviewPayload.frontmatterLineCount(Self.prfOld) == 4)
        #expect(ReviewPayload.frontmatterLineCount("---\ntitle: X\n---") == 3)
        #expect(ReviewPayload.frontmatterLineCount("\u{FEFF}---\ntitle: X\n---\n# X\n") == 3)
        // An unterminated frontmatter is body, as the reader renders it.
        #expect(ReviewPayload.frontmatterLineCount("---\ntitle: X\n# X\n") == 0)
    }

    @Test("the lines after the frontmatter are the body the reader renders")
    func bodyIsTheReadersBody() {
        let texts = [
            Self.prfOld, Self.prfNew, "", "# No frontmatter\n", "---\ntitle: X\n---",
            "\u{FEFF}---\ntitle: X\n---\n# X\n", "---\ntitle: X\n# X\n",
            "---\r\ntitle: X\r\n---\r\n# X\r\n",
        ]
        for text in texts {
            let count = ReviewPayload.frontmatterLineCount(text)
            let body = ReviewPayload.lines(of: text).dropFirst(count).joined()
            #expect(body == WikiPage(path: "Primitives/x.md", text: text).body)
        }
    }

    @Test("frontmatter entries leave out long unchanged runs as one gap")
    func frontmatterGaps() {
        let lines = ReviewPayload.lines(of: "---\na: 1\nb: 2\nc: 3\nd: 4\ne: 5\n---\n")
        let entries = ReviewPayload.frontmatterEntries(
            [Self.hunk(5..<6, 5..<6)], old: lines, new: lines)
        #expect(entries.map { $0.kind } == ["gap", "context", "removed", "added", "context"])
        #expect(entries.first?.text == "4 unchanged lines")
    }

    @Test("summaries count a removed and an added line as one changed line")
    func summaries() {
        func summary(_ hunks: [LineHunk]) -> String {
            ReviewPayload.summary(for: Self.file(old: "", new: "", hunks: hunks))
        }
        #expect(summary([Self.hunk(41..<42, 41..<42)]) == "1 line changed")
        #expect(summary([Self.hunk(1..<3, 1..<6)]) == "2 lines changed, 3 added")
        #expect(summary([Self.hunk(4..<4, 4..<6)]) == "2 lines added")
        #expect(summary([Self.hunk(4..<5, 4..<4)]) == "1 line removed")
        #expect(summary([]) == "No lines changed")
        let renamed = ChangedFile(
            path: "content/Primitives/b.md", oldPath: "content/Primitives/a.md", status: .renamed,
            isBinary: false, oldText: "", newText: "", hunks: [])
        #expect(ReviewPayload.summary(for: renamed) == "Renamed from a.md")
    }

    // MARK: Links

    /// The reader's index: PRF and OWF, no reference pages.
    static func readerIndex() -> WikiIndex {
        let pages = [
            WikiPage(path: "Primitives/pseudorandom-function.md", text: prfOld),
            WikiPage(path: "Primitives/one-way-function.md", text: FixtureClone.page(
                type: "primitive", title: "One-way function", aliases: ["OWF"],
                body: "# One-way function\n")),
        ]
        return WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"),
            files: pages.map(\.path) + ["Files/diagram.png"],
            pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }))
    }

    /// The edit an ingestion makes: PRF loses its OWF link and gains a
    /// citation of a reference page the same change adds.
    static func ingestion() -> ReviewSnapshot {
        let old = prfOld + "Built from a [[one-way-function|OWF]].\n"
        let new = prfOld + "Built by \(ggmLink).\n"
        let lines = ReviewPayload.lines(of: old).count
        let reference = FixtureClone.page(
            type: "reference", title: "GGM86",
            body: "# How to construct random functions\n\nThe tree construction.\n")
        return snapshot(
            file(old: old, new: new, hunks: [hunk((lines - 1)..<lines, (lines - 1)..<lines)]),
            file(ggmPath, status: .added, old: nil, new: reference,
                 hunks: [hunk(0..<0, 0..<ReviewPayload.lines(of: reference).count)]))
    }

    @Test("a wikilink to a page the change adds resolves, as new, over the old and new texts")
    func linksToAddedPages() throws {
        let index = Self.readerIndex()
        let snapshot = Self.ingestion()
        let added = ReviewPayload.addedPages(in: snapshot)
        #expect(added.map(\.path) == ["References/GGM86 - How to construct random functions.md"])
        let newPages = ReviewPayload.newPagePaths(added, in: index)
        let prf = try #require(snapshot.files.first)

        // Against the reader's index alone, the citation has no target.
        let bare = ReviewPayload.links(for: prf, header: "", index: index, newPages: [])
        #expect(bare[Self.ggmLink] == nil)

        let links = ReviewPayload.links(
            for: prf, header: "", index: index.overlaying(added), newPages: newPages)
        let citation = try #require(links[Self.ggmLink])
        #expect(citation.kind == "new")
        #expect(citation.href == CCwikiURL.page(
            path: "References/GGM86 - How to construct random functions.md"))
        #expect(citation.external == false)
        // The link only the old text has is resolved too, as a page.
        #expect(links["[[one-way-function|OWF]]"]?.kind == "page")

        // And the payload carries them, through the closures AppModel passes.
        let json = ReviewPayload.json(
            snapshot: snapshot, findings: [],
            title: { path in
                snapshot.files.first { $0.path == path }.flatMap(ReviewPayload.pageTitle(for:))
            },
            header: { _ in "" },
            links: {
                ReviewPayload.links(
                    for: $0, header: "", index: index.overlaying(added), newPages: newPages)
            },
            macros: [:])
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let files = try Self.files(payload)
        let map = try #require(files.first?["links"] as? [String: [String: Any]])
        #expect(map[Self.ggmLink]?["kind"] as? String == "new")
        #expect(files.map { $0["title"] as? String }
            == ["Pseudorandom function", "How to construct random functions"])
    }

    @Test("markingNew changes only links to the new pages, anchored or not")
    func markingNew() {
        let newPage = "References/X.md"
        let links: [String: RenderRequest.ResolvedLink] = [
            "[[X]]": .init(href: CCwikiURL.page(path: newPage), kind: "page",
                           external: false, isImage: false),
            "[[X#Intro]]": .init(href: CCwikiURL.page(path: newPage, anchor: "intro"),
                                 kind: "page", external: false, isImage: false),
            "[[X2]]": .init(href: CCwikiURL.page(path: "References/X2.md"), kind: "page",
                            external: false, isImage: false),
            "[[https://x]]": .init(href: "https://x", kind: "external",
                                   external: true, isImage: false),
        ]
        let marked = ReviewPayload.markingNew(links, newPages: [newPage])
        #expect(marked["[[X]]"]?.kind == "new")
        #expect(marked["[[X#Intro]]"]?.kind == "new")
        #expect(marked["[[X2]]"]?.kind == "page")
        #expect(marked["[[https://x]]"]?.kind == "external")
    }

    @Test("only pages the site would list are added: not templates, not hidden files")
    func addedPagesFilter() {
        let page = "---\ntitle: T\n---\n# T\n"
        let snapshot = Self.snapshot(
            Self.file("content/Templates/Reference.md", status: .added, old: nil, new: page, hunks: []),
            Self.file("content/Primitives/.draft.md", status: .added, old: nil, new: page, hunks: []),
            Self.file("CLAUDE.md", status: .added, old: nil, new: page, hunks: []),
            Self.file("content/Primitives/new.md", status: .added, old: nil, new: page, hunks: []),
            Self.file("content/Primitives/old.md", status: .modified, old: page, new: page, hunks: []))
        #expect(ReviewPayload.addedPages(in: snapshot).map(\.path) == ["Primitives/new.md"])
    }

    // MARK: The overlay

    @Test("overlaying adds a page, its aliases and its folder, and keeps the rest")
    func overlay() throws {
        let index = Self.readerIndex()
        #expect(index.overlaying([]).allSlugs == index.allSlugs)

        let added = WikiPage(path: "Folklore/hybrid-argument.md", text: FixtureClone.page(
            type: "folklore", title: "Hybrid argument", aliases: ["hybrids"],
            body: "# Hybrid argument\n"))
        let overlay = index.overlaying([added])
        #expect(overlay.pages.count == index.pages.count + 1)
        #expect(overlay.assets == index.assets)
        #expect(overlay.folders.contains("Folklore"))

        let byAlias = try #require(WikilinkParser.links(in: "[[hybrids]]").first)
        #expect(index.resolve(byAlias, from: "index.md").isResolved == false)
        #expect(overlay.resolve(byAlias, from: "index.md")
            == .page(path: "Folklore/hybrid-argument.md", anchor: nil))
        let owf = try #require(WikilinkParser.links(in: "[[OWF]]").first)
        #expect(overlay.resolve(owf, from: "index.md")
            == .page(path: "Primitives/one-way-function.md", anchor: nil))
    }

    @Test("overlaying a page at an existing path replaces it")
    func overlayReplaces() throws {
        let index = Self.readerIndex()
        let replaced = WikiPage(path: "Primitives/one-way-function.md", text: FixtureClone.page(
            type: "primitive", title: "One-way function", aliases: ["OWF", "one-way"],
            body: "# One-way function\n"))
        let overlay = index.overlaying([replaced])
        #expect(overlay.pages.count == index.pages.count)
        let link = try #require(WikilinkParser.links(in: "[[one-way]]").first)
        #expect(overlay.resolve(link, from: "index.md")
            == .page(path: "Primitives/one-way-function.md", anchor: nil))
    }

    // MARK: The endpoints line

    static func labels() -> RelationLabels {
        RelationLabels(
            manifest: RelationsManifest.decode(Data(FixtureClone.manifest().utf8)), index: nil)
    }

    @Test("a reduction page's header links its hypotheses and conclusion")
    func header() throws {
        let reduction = """
            ---
            type: reduction
            title: "OWF ⇒ PRF"
            hypotheses: [owf]
            conclusion: prf
            ---
            # OWF ⇒ PRF

            """
        let file = Self.file(
            "content/Reductions/owf-to-prf.md", status: .added, old: nil, new: reduction,
            hunks: [Self.hunk(0..<0, 0..<8)])
        let header = ReviewPayload.header(for: file, labels: Self.labels())
        #expect(header == "Hypothesis: [[Primitives/one-way-function|One-way function]]"
            + RelationMeta.separator
            + "Conclusion: [[Primitives/pseudorandom-function|Pseudorandom function]]")

        // Its links resolve to the endpoints' pages, like the body's.
        let links = ReviewPayload.links(
            for: file, header: header, index: Self.readerIndex(), newPages: [])
        #expect(links["[[Primitives/one-way-function|One-way function]]"]?.href
            == CCwikiURL.page(path: "Primitives/one-way-function.md"))
        #expect(links["[[Primitives/pseudorandom-function|Pseudorandom function]]"]?.kind == "page")
    }

    @Test("a header names several hypotheses, and an id the manifest lacks as text")
    func headerHypotheses() {
        let barrier = """
            ---
            type: barrier
            hypotheses: [owf, lwe]
            conclusion: mystery-object
            ---
            # A barrier

            """
        let file = Self.file(
            "content/Barriers/x.md", old: barrier, new: barrier, hunks: [])
        let header = ReviewPayload.header(for: file, labels: Self.labels())
        #expect(header.hasPrefix("Hypotheses: [[Primitives/one-way-function|One-way function]], "
            + "[[Assumptions/learning-with-errors|Learning with errors]]"))
        #expect(header.hasSuffix("Conclusion: Mystery object"))
    }

    @Test("every other page has no header")
    func noHeader() {
        let file = Self.file(old: Self.prfOld, new: Self.prfNew, hunks: Self.prfNewHunks)
        #expect(ReviewPayload.header(for: file, labels: Self.labels()) == "")
    }
}
