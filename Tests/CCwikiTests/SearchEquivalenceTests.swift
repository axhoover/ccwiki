import Foundation
import Testing
@testable import CCwiki

/// Track S of the efficiency plan (plans/efficiency.md §2.5): the search sync
/// made cheaper without changing anything it builds. Each change is held to
/// the longer way round it saves: a ranker handed the outlines to one that
/// parses the pages, a ranker handed the citing pages' names to one that
/// names them, a sync's rankers to the ones its pages make, and the full
/// rewrite through FTS5's `'rebuild'` to every row inserted through the
/// triggers. Every row is held to what its page makes, column by column
/// as `SearchIndex.write` binds it. On hand-made pages with the hazards
/// the corpus lacks, and on the real wiki when `CCWIKI_WIKI` points at a
/// clone. Timings are printed, never asserted.
///
/// The copy of the code track S replaced, and the comparisons with it, went
/// after 0.1.4 (efficiency.md §2.1).
struct SearchEquivalenceTests {

    // MARK: Fixtures

    /// What a library load hands the search index, read without the rest of
    /// a load: the pages sorted by path, their backlinks and fingerprints.
    struct Library: Sendable {
        let pages: [WikiPage]
        let backlinks: [String: [WikiIndex.Backlink]]
        let fingerprints: ContentFingerprints

        init(cloneRoot: URL) {
            let index = WikiIndex.build(contentRoot: cloneRoot.appending(path: "content"))
            pages = index.allPages.sorted { $0.path < $1.path }
            backlinks = index.backlinkMap()
            fingerprints = ContentFingerprints.scan(cloneRoot: cloneRoot)
        }

        init(
            pages: [WikiPage], backlinks: [String: [WikiIndex.Backlink]],
            fingerprints: ContentFingerprints
        ) {
            self.pages = pages
            self.backlinks = backlinks
            self.fingerprints = fingerprints
        }

        /// This library with `page` written again as `text`: its file
        /// changed, so its fingerprint too.
        func replacing(_ page: WikiPage, with text: String) -> Library {
            var digests = fingerprints.pages
            digests[page.path] = ContentFingerprints.digest(Data(text.utf8))
            return Library(
                pages: pages.map { $0.path == page.path ? WikiPage(path: page.path, text: text) : $0 },
                backlinks: backlinks,
                fingerprints: ContentFingerprints(
                    pages: digests, manifest: fingerprints.manifest, macros: fingerprints.macros))
        }
    }

    /// The clone `CCWIKI_WIKI` names, when it has a `content/`.
    static var cloneRoot: URL? { CorpusTests.contentRoot?.deletingLastPathComponent() }

    /// The real wiki's library, read once for every test here that uses it.
    static let corpus: Library? = cloneRoot.map { Library(cloneRoot: $0) }

    /// Pages with the hazards a heading walk must get right and the corpus
    /// lacks: CR LF and lone CR line ends, a combining mark after a line
    /// end, fences and a `%%` comment with heading lines inside, a heading
    /// repeated (its ids deduplicated), a character reference for a line
    /// break, headings with no text, and a heading on three pages, which is
    /// the template rather than a name. A reduction cites the reference and
    /// a concept page links to the reduction, so the paper is cited through
    /// it as well as directly.
    static let hazards: [String: String] = [
        "content/Primitives/carriage-returns.md": carriageReturns,
        "content/Primitives/marks.md": marks,
        "content/Reductions/owf-to-prf.md": owfToPRF,
        "content/Glossary/statement.md": FixtureClone.page(
            type: "glossary", title: "Statement", body: "## Statement\n\nWhat a page claims.\n"),
    ]

    static let carriageReturns = """
        ---\r\ntype: primitive\r\nstatus: draft\r\ntitle: Carriage returns\r\naliases: []\r\n\
        ---\r\n\r\n# Carriage returns\r\n\r\n## Syntax\r\n\r\nWords.\r\n\r\n## Syntax\r\n\
        ## Lone\rreturn\r\n```\r\n## Fenced\r\n```\r\n## Statement\r\n
        """

    static let marks = FixtureClone.page(
        type: "primitive", title: "Marks", aliases: ["Diacritics", "Vigenère"], body: """
            # Marks
            \u{301}## After a mark
            ## Café
            %%
            ## Hidden in a comment
            %%
            ## Shown
            ~~~
            # Tilde fence
            ~~~
            ## Line&#10;break
            ## Security of $\\mathsf{Enc}_k$
            ## From [[one-way-function|OWF]]
            ## A "quoted" \\\\ backslash, P/poly and 𝒜
            ##\t
            ##
            ## Statement

            Built through [[owf-to-prf]].

            """)

    static let owfToPRF = FixtureClone.page(
        type: "reduction", title: "OWF $\\Rightarrow$ PRF", body: """
            # OWF ⇒ PRF

            By [[GGM86 - How to construct random functions|GGM86]].

            ## Statement

            A PRF from any one-way function.

            """)

    /// The standard miniature wiki with the hazards added.
    static func hazardClone() throws -> FixtureClone {
        try FixtureClone(FixtureClone.standard.merging(hazards) { $1 })
    }

    /// Edits of every kind to the hazard clone: a concept page and the
    /// reference changed, a page removed and one added.
    static func edit(_ clone: FixtureClone) throws {
        let marks = "content/Primitives/marks.md"
        try clone.write(marks, try clone.read(marks)
            .replacingOccurrences(of: "## Café\n", with: "## Café again\n## Shown\n"))
        try clone.write(FixtureClone.ggm, try clone.read(FixtureClone.ggm)
            + "\n## Abstract\n\nA tree of generators.\n")
        try clone.remove("content/Primitives/carriage-returns.md")
        try clone.write("content/Assumptions/decisional.md", FixtureClone.page(
            type: "assumption", title: "Decisional assumption", aliases: ["DA"],
            body: "# Decisional assumption\n\n## Syntax\n\n## Statement\n\nSee [[marks]].\n"))
    }

    /// A database file in a directory of its own, removed by `delete`.
    struct Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-search-equivalence-\(UUID().uuidString)")

        func file(_ name: String) -> URL {
            directory.appending(path: name)
        }

        func delete() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @discardableResult
    static func sync(
        _ index: SearchIndex, _ library: Library, builder: String = "tests"
    ) async throws -> SyncReport {
        try await index.sync(
            pages: library.pages, backlinks: library.backlinks,
            fingerprints: library.fingerprints, builder: builder)
    }

    // MARK: Rows

    /// A row as the file holds it.
    struct Row: Equatable {
        let path, slug, kind, status, title, aliases, headings, body, hash: String
    }

    /// Every row of the file in path order, read on a connection of the
    /// test's own.
    static func rows(of file: URL) throws -> [Row] {
        let database = try SQLiteDatabase(path: file.path(percentEncoded: false))
        let statement = try database.prepare("""
            SELECT path, slug, kind, status, title, aliases, headings, body, hash FROM doc
            """)
        var rows: [Row] = []
        while try statement.step() {
            rows.append(Row(
                path: statement.string(0), slug: statement.string(1),
                kind: statement.string(2), status: statement.string(3),
                title: statement.string(4), aliases: statement.string(5),
                headings: statement.string(6), body: statement.string(7),
                hash: statement.string(8)))
        }
        // The statement holds its connection unowned.
        withExtendedLifetime(database) {}
        return rows.sorted { $0.path < $1.path }
    }

    /// Every row `library`'s pages make, each column as `SearchIndex.write`
    /// binds it. `rebuild` writes no fingerprints.
    static func expectedRows(_ library: Library, fingerprinted: Bool = true) -> [Row] {
        library.pages.map { page -> Row in
            Row(
                path: page.path, slug: page.slug, kind: page.kind.rawValue, status: page.status.rawValue,
                title: page.kind == .reference ? "\(page.title) \(page.displayTitle)" : page.title,
                aliases: page.aliases.joined(separator: "\n"),
                headings: page.headings().map(\.text).joined(separator: "\n"),
                body: SearchIndex.indexableBody(page.body),
                hash: fingerprinted ? library.fingerprints.pages[page.path] ?? "" : "")
        }.sorted { $0.path < $1.path }
    }

    /// Every row's outline, by path: the column track S added.
    static func outlines(of file: URL) throws -> [String: String] {
        let database = try SQLiteDatabase(path: file.path(percentEncoded: false))
        let statement = try database.prepare("SELECT path, outline FROM doc")
        var outlines: [String: String] = [:]
        while try statement.step() {
            outlines[statement.string(0)] = statement.string(1)
        }
        withExtendedLifetime(database) {}
        return outlines
    }

    /// An outline as arrays, which compare.
    static func pairs(_ outline: ConceptRanker.Outline?) -> [[String]]? {
        outline?.map { [$0.text, $0.id] }
    }

    /// The first path whose entries differ, for a failure that reads in a
    /// line rather than a dump of the corpus.
    static func firstDifference<T: Equatable>(
        _ actual: [T], _ expected: [T], path: (T) -> String
    ) -> String {
        guard actual.count == expected.count else {
            return "\(actual.count) entries against \(expected.count)"
        }
        for (a, b) in zip(actual, expected) where a != b {
            return "first difference at \(path(b))"
        }
        return "no difference"
    }

    /// Asserts that every row of `index`, synced with `library`, holds what
    /// its page makes, column by column (`expectedRows`); that its outline
    /// reads back as the page's headings; and that `index` holds the
    /// rankers the pages make when each is parsed and named afresh.
    static func expectBuilt(
        _ index: SearchIndex, file: URL, _ library: Library, fingerprinted: Bool = true,
        after step: String
    ) async throws {
        let rows = try Self.rows(of: file)
        let expectedRows = Self.expectedRows(library, fingerprinted: fingerprinted)
        let sameRows = rows == expectedRows
        #expect(sameRows, "\(step): rows, \(Self.firstDifference(rows, expectedRows, path: \.path))")

        let stored = try Self.outlines(of: file)
        let unread = library.pages.filter { page in
            Self.pairs(SearchIndex.outline(decoding: stored[page.path] ?? ""))
                != Self.pairs(ConceptRanker.outline(page.headings()))
        }
        #expect(unread.isEmpty, "\(step): outlines read back wrong, \(unread.prefix(3).map(\.path))")

        let ranker = await index.ranker
        let parsed = ConceptRanker(pages: library.pages)
        let sameEntries = ranker.entries == parsed.entries
        #expect(sameEntries, """
            \(step): concept entries, \
            \(Self.firstDifference(ranker.entries, parsed.entries, path: \.path))
            """)
        let sameVocabulary = ranker.vocabulary == parsed.vocabulary
        #expect(sameVocabulary, "\(step): concept vocabulary")

        let referenceRanker = await index.referenceRanker
        let references = referenceRanker.entries
        let named = ReferenceRanker(pages: library.pages, backlinks: library.backlinks).entries
        let sameReferences = references == named
        #expect(sameReferences, """
            \(step): reference entries, \
            \(Self.firstDifference(references, named, path: \.path))
            """)
    }

    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f ms", Double(seconds) * 1e3 + Double(attoseconds) / 1e15)
    }

    // MARK: S1. Headings parsed once per page

    @Test("a ranker handed the outlines already parsed equals one that parses the pages")
    func rankerFromOutlines() throws {
        let clone = try Self.hazardClone()
        defer { clone.delete() }
        let pages = Library(cloneRoot: clone.root).pages
        let parsed = ConceptRanker(pages: pages)
        #expect(parsed.entries.contains { $0.headings.count > 3 }, "the hazards have headings")

        let outlines = Dictionary(
            pages.map { ($0.path, ConceptRanker.outline($0.headings())) },
            uniquingKeysWith: { first, _ in first })
        let handed = ConceptRanker(pages: pages, headings: outlines)
        #expect(handed.entries == parsed.entries)
        #expect(handed.vocabulary == parsed.vocabulary)
        // Only some outlines handed over: the rest are parsed.
        let some = outlines.filter { $0.key.hasPrefix("Primitives/") }
        #expect(ConceptRanker(pages: pages, headings: some).entries == parsed.entries)
    }

    @Test("every sync, full, partial, a no-op or a rebuild, builds the rows and rankers its pages make")
    func syncBuildsRankers() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try Self.hazardClone()
        defer { clone.delete() }
        let file = scratch.file("search.sqlite3")

        let first = Library(cloneRoot: clone.root)
        let index = SearchIndex(path: file)
        let full = try await Self.sync(index, first)
        #expect(full.rebuiltFromScratch)
        try await Self.expectBuilt(index, file: file, first, after: "a full sync")

        try Self.edit(clone)
        let second = Library(cloneRoot: clone.root)
        let partial = try await Self.sync(index, second)
        #expect(partial == SyncReport(
            inserted: 1, updated: 2, deleted: 1, unchanged: second.pages.count - 3))
        try await Self.expectBuilt(index, file: file, second, after: "a partial sync")

        let relaunched = SearchIndex(path: file)
        let noOp = try await Self.sync(relaunched, second)
        #expect(noOp == SyncReport(unchanged: second.pages.count))
        try await Self.expectBuilt(relaunched, file: file, second, after: "a no-op after a relaunch")

        let rebuiltFile = scratch.file("rebuilt.sqlite3")
        let rebuilt = SearchIndex(path: rebuiltFile)
        try await rebuilt.rebuild(pages: second.pages, backlinks: second.backlinks)
        try await Self.expectBuilt(
            rebuilt, file: rebuiltFile, second, fingerprinted: false, after: "a rebuild")
    }

    @Test("on the real wiki: the ranker from the sync's outlines is the one that parses the pages")
    func corpusHeadingsOnce() async throws {
        guard let library = Self.corpus else { return }
        let scratch = Scratch()
        defer { scratch.delete() }
        let clock = ContinuousClock()

        var start = clock.now
        let parsed = ConceptRanker(pages: library.pages)
        let parsedTime = start.duration(to: clock.now)
        start = clock.now
        let outlines = Dictionary(
            library.pages.map { ($0.path, ConceptRanker.outline($0.headings())) },
            uniquingKeysWith: { first, _ in first })
        let headingsTime = start.duration(to: clock.now)
        start = clock.now
        let handed = ConceptRanker(pages: library.pages, headings: outlines)
        let handedTime = start.duration(to: clock.now)
        let sameEntries = handed.entries == parsed.entries
        #expect(sameEntries, "\(Self.firstDifference(handed.entries, parsed.entries, path: \.path))")
        let sameVocabulary = handed.vocabulary == parsed.vocabulary
        #expect(sameVocabulary)

        let file = scratch.file("search.sqlite3")
        let index = SearchIndex(path: file)
        start = clock.now
        let full = try await Self.sync(index, library)
        let syncTime = start.duration(to: clock.now)
        #expect(full.rebuiltFromScratch)
        #expect(full.inserted == library.pages.count)
        try await Self.expectBuilt(index, file: file, library, after: "a full sync")

        print("""
            Search sync, headings parsed once (S1), on \(library.pages.count) pages:
              ConceptRanker parsing the pages \(Self.milliseconds(parsedTime)); \
            headings() on every page \(Self.milliseconds(headingsTime)); \
            ConceptRanker from those outlines \(Self.milliseconds(handedTime))
              full sync \(Self.milliseconds(syncTime)) (\(full.summary))
            """)
    }

    // MARK: S2. The full rewrite through FTS5's 'rebuild'

    /// One query's answer from one kind of search, flattened for exact
    /// comparison: the order, the snippets, the sections, the fields and
    /// the scores.
    struct Answer: Equatable {
        let query: String
        let lines: [String]
        let scores: [Double]
    }

    /// Words of the fixtures and of the real wiki, single letters (the
    /// widest prefixes) and words nothing contains.
    static let queries = [
        "o", "p", "th", "pseudorandom", "function", "one-way", "invert", "GGM86",
        "random functions", "LWE", "learning with errors", "noisy linear", "tree construction",
        "garbled", "Goldreich", "goldwasser micali", "regev 2005", "statement", "syntax",
        "carriage", "vigenere", "line break", "zero knowledge", "oblivious transfer",
        "lattice", "NC^0", "\\classNP", "zzqx", "qqqqqqqq",
    ]

    /// What every kind of search answers for every query.
    static func answers(_ index: SearchIndex) async throws -> [Answer] {
        var answers: [Answer] = []
        for query in queries {
            let hits = try await index.search(query)
            answers.append(Answer(
                query: "search " + query,
                lines: hits.map {
                    "\($0.path) \($0.slug) \($0.title) \($0.kind) \($0.status) \($0.snippet)"
                },
                scores: hits.map(\.score)))
            let concepts = try await index.conceptSearch(query)
            var lines = concepts.hits.map {
                "\($0.path)#\($0.anchor ?? "") \($0.section ?? "") \($0.snippet)"
            }
            lines.append("corrected to \(concepts.correction ?? "nothing")")
            answers.append(Answer(
                query: "concepts " + query, lines: lines, scores: concepts.hits.map(\.score)))
            let references = try await index.referenceSearch(query)
            answers.append(Answer(
                query: "references " + query,
                lines: references.map {
                    "\($0.path) \($0.field) \($0.citedBy ?? "") \($0.citedVia ?? "") \($0.snippet)"
                },
                scores: []))
        }
        return answers
    }

    /// The triggers in the file, by name.
    static func triggers(in file: URL) throws -> [String] {
        let database = try SQLiteDatabase(path: file.path(percentEncoded: false))
        let statement = try database.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        var names: [String] = []
        while try statement.step() { names.append(statement.string(0)) }
        withExtendedLifetime(database) {}
        return names
    }

    /// FTS5's own check that the index and its rows agree; throws if not.
    static func checkIntegrity(of file: URL) throws {
        let database = try SQLiteDatabase(path: file.path(percentEncoded: false))
        try database.execute("INSERT INTO doc_fts(doc_fts) VALUES('integrity-check')")
    }

    @Test("a rewrite over a populated index, then rows changed through the triggers, answers as before")
    func populatedRewrite() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try Self.hazardClone()
        defer { clone.delete() }

        // Another build's rows, rewritten in full over the old ones.
        let populated = SearchIndex(path: scratch.file("populated.sqlite3"))
        try await Self.sync(populated, Library(cloneRoot: clone.root), builder: "one")
        try Self.edit(clone)
        let rewrite = try await Self.sync(populated, Library(cloneRoot: clone.root), builder: "two")
        #expect(rewrite.rebuiltFromScratch)
        let triggers = try Self.triggers(in: scratch.file("populated.sqlite3"))
        #expect(triggers == ["doc_ad", "doc_ai", "doc_au"], "the rewrite made the triggers again")

        // Then a row updated, one deleted and one inserted, through them.
        try clone.write(FixtureClone.owf, try clone.read(FixtureClone.owf)
            + "\nInverting it is as hard as noisy linear algebra. zzqx\n")
        try clone.remove(FixtureClone.lwe)
        try clone.write("content/Primitives/garbled-circuits.md", FixtureClone.page(
            type: "primitive", title: "Garbled circuits", aliases: ["GC"],
            body: "# Garbled circuits\n\nA garbled function, built from a [[PRF]].\n"))
        let library = Library(cloneRoot: clone.root)
        let changes = try await Self.sync(populated, library, builder: "two")
        #expect(changes == SyncReport(
            inserted: 1, updated: 1, deleted: 1, unchanged: library.pages.count - 2))

        // A fresh file, and the rewrite as it was: every row an insert
        // through `doc_ai`, into an index with no rows.
        let fresh = SearchIndex(path: scratch.file("fresh.sqlite3"))
        let built = try await Self.sync(fresh, library, builder: "two")
        #expect(built.rebuiltFromScratch)
        let oldWay = SearchIndex(path: scratch.file("triggers.sqlite3"))
        try await oldWay.sync(pages: [], backlinks: [:], fingerprints: .empty, builder: "two")
        let inserted = try await Self.sync(oldWay, library, builder: "two")
        #expect(inserted == SyncReport(inserted: library.pages.count))

        let expected = try await Self.answers(oldWay)
        #expect(expected.contains { $0.query.hasPrefix("search") && !$0.lines.isEmpty })
        for (name, index) in [("populated", populated), ("fresh", fresh)] {
            let actual = try await Self.answers(index)
            #expect(actual == expected,
                    "\(name): \(Self.firstDifference(actual, expected, path: \.query))")
        }
        let expectedRows = try Self.rows(of: scratch.file("triggers.sqlite3"))
        #expect(expectedRows == Self.expectedRows(library))
        for name in ["populated", "fresh"] {
            let rows = try Self.rows(of: scratch.file("\(name).sqlite3"))
            #expect(rows == expectedRows, "\(name)")
        }
        for name in ["populated", "fresh", "triggers"] {
            try Self.checkIntegrity(of: scratch.file("\(name).sqlite3"))
        }
    }

    @Test("on the real wiki: the rewrite through 'rebuild' answers as the triggers did")
    func corpusRebuild() async throws {
        guard let library = Self.corpus, let contentRoot = CorpusTests.contentRoot else { return }
        let scratch = Scratch()
        defer { scratch.delete() }
        let clock = ContinuousClock()

        // The rewrite as it was: every row an insert through `doc_ai`, into
        // an index with no rows.
        let oldWay = SearchIndex(path: scratch.file("triggers.sqlite3"))
        try await oldWay.sync(pages: [], backlinks: [:], fingerprints: .empty, builder: "S2")
        var start = clock.now
        let inserted = try await Self.sync(oldWay, library, builder: "S2")
        let oldWayTime = start.duration(to: clock.now)
        #expect(inserted == SyncReport(inserted: library.pages.count))

        let fresh = SearchIndex(path: scratch.file("fresh.sqlite3"))
        start = clock.now
        let built = try await Self.sync(fresh, library, builder: "S2")
        let freshTime = start.duration(to: clock.now)
        #expect(built.rebuiltFromScratch)

        // Over an older wiki's rows: a hundred pages fewer, and one that has
        // since gone, whose words must leave the index with it.
        let populated = SearchIndex(path: scratch.file("populated.sqlite3"))
        let gone = WikiPage(path: "Glossary/gone.md", text: FixtureClone.page(
            type: "glossary", title: "Gone",
            body: "A pseudorandom function from lattices and learning with errors.\n"))
        try await populated.sync(
            pages: Array(library.pages.dropFirst(100)) + [gone], backlinks: library.backlinks,
            fingerprints: library.fingerprints, builder: "older")
        start = clock.now
        let rewrite = try await Self.sync(populated, library, builder: "S2")
        let rewriteTime = start.duration(to: clock.now)
        #expect(rewrite.rebuiltFromScratch)

        let indexes = [("fresh", fresh), ("populated", populated)]
        let expected = try await Self.answers(oldWay)
        for (name, index) in indexes {
            let actual = try await Self.answers(index)
            #expect(actual == expected,
                    "\(name): \(Self.firstDifference(actual, expected, path: \.query))")
        }
        let expectedRows = try Self.rows(of: scratch.file("triggers.sqlite3"))
        let made = Self.expectedRows(library)
        let triggersMade = expectedRows == made
        #expect(triggersMade, "triggers: \(Self.firstDifference(expectedRows, made, path: \.path))")
        for name in ["fresh", "populated"] {
            let rows = try Self.rows(of: scratch.file("\(name).sqlite3"))
            let sameRows = rows == expectedRows
            #expect(sameRows, "\(name): \(Self.firstDifference(rows, expectedRows, path: \.path))")
        }
        for name in ["triggers", "fresh", "populated"] {
            try Self.checkIntegrity(of: scratch.file("\(name).sqlite3"))
        }

        // Then one concept page changed, through `doc_au`, on each.
        let page = try #require(library.pages.first { $0.kind == .primitive })
        let text = try String(contentsOf: contentRoot.appending(path: page.path), encoding: .utf8)
        let edited = library.replacing(page, with: text + "\nzzqx, a word no page has.\n")
        for (_, index) in [("triggers", oldWay)] + indexes {
            let report = try await Self.sync(index, edited, builder: "S2")
            #expect(report == SyncReport(updated: 1, unchanged: library.pages.count - 1))
        }
        let expectedAfter = try await Self.answers(oldWay)
        #expect(expectedAfter.contains { $0.query == "search zzqx" && $0.lines.count == 1 })
        for (name, index) in indexes {
            let actual = try await Self.answers(index)
            #expect(actual == expectedAfter, """
                \(name), after an update: \
                \(Self.firstDifference(actual, expectedAfter, path: \.query))
                """)
        }

        print("""
            Search sync, the full rewrite through 'rebuild' (S2), on \(library.pages.count) pages, \
            each with the rankers and rows:
              every row through the triggers \(Self.milliseconds(oldWayTime)); \
            a fresh file \(Self.milliseconds(freshTime)); \
            over an older index \(Self.milliseconds(rewriteTime))
            """)
    }

    // MARK: S3. Citing pages named once

    @Test("the reference ranker, naming citers with the concept ranker's names, is the one that names them")
    func citerNames() throws {
        let clone = try Self.hazardClone()
        defer { clone.delete() }
        let library = Library(cloneRoot: clone.root)
        let named = ReferenceRanker(pages: library.pages, backlinks: library.backlinks)
        let citers = named.entries.flatMap(\.citers)
        #expect(citers.contains { $0.via == nil }, "a page cites the paper")
        #expect(citers.contains { $0.via != nil }, "and one cites it through a reduction")

        let names = ConceptRanker(pages: library.pages).citerNames
        let handed = ReferenceRanker(
            pages: library.pages, backlinks: library.backlinks, citerNames: names)
        #expect(handed.entries == named.entries)
        // Every page that cites a paper has the concept ranker's names.
        #expect(citers.allSatisfy { names[$0.path] == $0.names })
    }

    @Test("on the real wiki: the reference ranker from the concept ranker's names is the one that names them")
    func corpusCiterNames() async throws {
        guard let library = Self.corpus else { return }
        let clock = ContinuousClock()

        let concepts = ConceptRanker(pages: library.pages)
        var start = clock.now
        let citerNames = concepts.citerNames
        let handed = ReferenceRanker(
            pages: library.pages, backlinks: library.backlinks, citerNames: citerNames)
        let handedTime = start.duration(to: clock.now)
        start = clock.now
        let named = ReferenceRanker(pages: library.pages, backlinks: library.backlinks)
        let namedTime = start.duration(to: clock.now)

        let same = handed.entries == named.entries
        #expect(same, "\(Self.firstDifference(handed.entries, named.entries, path: \.path))")
        let citers = named.entries.flatMap(\.citers)
        let allNamed = citers.allSatisfy { citerNames[$0.path] == $0.names }
        #expect(allNamed, "every citing page is a concept page the concept ranker named")

        print("""
            Search sync, citing pages named once (S3), on \(library.pages.count) pages, \
            \(citers.count) citers from \(Set(citers.map(\.path)).count) pages:
              ReferenceRanker handed the concept ranker's names \(Self.milliseconds(handedTime)); \
            naming each page once itself \(Self.milliseconds(namedTime))
            """)
    }

    // MARK: S4. The concept ranker from the outlines the rows keep

    @Test("an outline survives every hazard as JSON, the line break of a character reference too")
    func outlineRoundTrip() throws {
        let clone = try Self.hazardClone()
        defer { clone.delete() }
        let pages = Library(cloneRoot: clone.root).pages
        let texts = pages.flatMap { $0.headings().map(\.text) }
        #expect(texts.contains { $0.contains("\n") }, "a heading holds a line break")
        #expect(texts.contains { $0.contains("\"") && $0.contains("\\") && $0.contains("/") })
        for page in pages {
            let outline = ConceptRanker.outline(page.headings())
            let read = SearchIndex.outline(decoding: SearchIndex.encoded(outline))
            #expect(Self.pairs(read) == Self.pairs(outline), "\(page.path)")
        }
        #expect(SearchIndex.outline(decoding: "[]")?.isEmpty == true, "a page with no headings")
    }

    @Test("a kept row's outline is what the ranker reads, and one that cannot be read is parsed")
    func storedOutlines() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try Self.hazardClone()
        defer { clone.delete() }
        let library = Library(cloneRoot: clone.root)
        let file = scratch.file("search.sqlite3")
        try await Self.sync(SearchIndex(path: file), library)
        let fromPages = ConceptRanker(pages: library.pages)
        let marks = "Primitives/marks.md"

        /// The concept ranker of a no-op sync after a relaunch, with the
        /// outline of `marks` as `outline` in its row.
        func noOp(withOutline outline: String) async throws -> ConceptRanker {
            let database = try SQLiteDatabase(path: file.path(percentEncoded: false))
            let update = try database.prepare("UPDATE doc SET outline = ? WHERE path = ?")
            update.bind(1, outline)
            update.bind(2, marks)
            _ = try update.step()
            withExtendedLifetime(database) {}
            let relaunched = SearchIndex(path: file)
            let report = try await Self.sync(relaunched, library)
            #expect(report == SyncReport(unchanged: library.pages.count))
            return await relaunched.ranker
        }

        for unreadable in ["", "not json", "{}", "[[\"one\"]]", "[[1, 2]]"] {
            let ranker = try await noOp(withOutline: unreadable)
            #expect(ranker.entries == fromPages.entries, "\(unreadable.debugDescription) is parsed")
            #expect(ranker.vocabulary == fromPages.vocabulary)
        }
        // One that reads is taken as it is: the page is not parsed.
        let trusted = try await noOp(withOutline: "[]")
        let read = trusted.entries.first { $0.path == marks }
        let parsed = fromPages.entries.first { $0.path == marks }
        #expect(read?.headings.isEmpty == true)
        #expect(parsed?.headings.isEmpty == false)
    }

    @Test("on the real wiki: a sync that keeps rows reads their outlines; its rankers are the pages'")
    func corpusStoredOutlines() async throws {
        guard let library = Self.corpus, let contentRoot = CorpusTests.contentRoot else { return }
        let scratch = Scratch()
        defer { scratch.delete() }
        let clock = ContinuousClock()
        let file = scratch.file("search.sqlite3")
        try await Self.sync(SearchIndex(path: file), library)

        // What a no-op sync built before S4 besides reading the hashes:
        // both rankers, from the pages.
        var start = clock.now
        _ = ConceptRanker(pages: library.pages)
        _ = ReferenceRanker(pages: library.pages, backlinks: library.backlinks)
        let before = start.duration(to: clock.now)

        var noOps: [Duration] = []
        for _ in 0..<3 {
            let relaunched = SearchIndex(path: file)
            start = clock.now
            let report = try await Self.sync(relaunched, library)
            noOps.append(start.duration(to: clock.now))
            #expect(report == SyncReport(unchanged: library.pages.count))
        }
        let relaunched = SearchIndex(path: file)
        try await Self.sync(relaunched, library)
        try await Self.expectBuilt(relaunched, file: file, library, after: "a no-op after a relaunch")

        // One page changed, a heading added: only it is parsed.
        let page = try #require(library.pages.first { $0.kind == .assumption })
        let text = try String(contentsOf: contentRoot.appending(path: page.path), encoding: .utf8)
        let edited = library.replacing(page, with: text + "\n## A heading added\n\nzzqx.\n")
        start = clock.now
        let changed = try await Self.sync(relaunched, edited)
        let changedTime = start.duration(to: clock.now)
        #expect(changed == SyncReport(updated: 1, unchanged: library.pages.count - 1))
        try await Self.expectBuilt(relaunched, file: file, edited, after: "one page changed")

        print("""
            Search sync, the concept ranker from stored outlines (S4), on \(library.pages.count) pages:
              both rankers from the pages, as a no-op built them before S4 \(Self.milliseconds(before)); \
            a no-op sync after a relaunch now, fastest of 3 \
            \(Self.milliseconds(noOps.min() ?? .zero)); \
            after one page changed \(Self.milliseconds(changedTime))
            """)
    }
}
