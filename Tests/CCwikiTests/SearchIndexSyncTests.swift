import Foundation
import Testing
@testable import CCwiki

/// The search index brought in line with a library by its rows' fingerprints
/// rather than rewritten after every load (plans/reader-comforts.md §3.4).
/// The definition is a fresh build: an index synced from one version of the
/// wiki to the next must hold the same rows and answer every query the same.
struct SearchIndexSyncTests {

    /// A database file in a directory of its own, removed by `delete`.
    struct Scratch {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-search-sync-\(UUID().uuidString)")

        func file(_ name: String = "search.sqlite3") -> URL {
            directory.appending(path: name)
        }

        func delete() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    struct Row: Equatable {
        let path, slug, kind, status, title, aliases, headings, body, hash: String
    }

    /// Every row of the file, read on a connection of the test's own.
    static func rows(of file: URL) throws -> [Row] {
        let database = try SQLiteDatabase(path: file.path(percentEncoded: false))
        let statement = try database.prepare("""
            SELECT path, slug, kind, status, title, aliases, headings, body, hash
            FROM doc ORDER BY path
            """)
        var rows: [Row] = []
        while try statement.step() {
            rows.append(Row(
                path: statement.string(0), slug: statement.string(1), kind: statement.string(2),
                status: statement.string(3), title: statement.string(4),
                aliases: statement.string(5), headings: statement.string(6),
                body: statement.string(7), hash: statement.string(8)))
        }
        return rows
    }

    static func sync(
        _ index: SearchIndex, _ library: LoadedLibrary, builder: String = "tests"
    ) async throws -> SyncReport {
        try await index.sync(
            pages: library.index.allPages, backlinks: library.backlinks,
            fingerprints: library.fingerprints, builder: builder)
    }

    static let queries = [
        "pseudorandom", "function", "one-way", "invert", "GGM86", "random functions",
        "LWE", "noisy linear", "tree construction", "garbled", "PRF", "Goldreich",
    ]

    /// What every kind of search answers, flattened for comparison: the
    /// order, the snippets and the scores.
    static func answers(_ index: SearchIndex) async throws -> [(String, [String], [Double])] {
        var answers: [(String, [String], [Double])] = []
        for query in queries {
            let hits = try await index.search(query)
            answers.append(("search " + query, hits.map { "\($0.path) \($0.snippet)" },
                            hits.map(\.score)))
            let concepts = try await index.conceptSearch(query).hits
            answers.append(("concepts " + query,
                            concepts.map { "\($0.path)#\($0.anchor ?? "") \($0.snippet)" },
                            concepts.map(\.score)))
            let references = try await index.referenceSearch(query)
            answers.append(("references " + query,
                            references.map { "\($0.path) \($0.field) \($0.snippet)" }, []))
        }
        return answers
    }

    // MARK: The definition

    @Test("syncing from one version of the wiki to the next equals a fresh build of the second")
    func syncEqualsFreshBuild() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try FixtureClone()
        defer { clone.delete() }

        let synced = SearchIndex(path: scratch.file("synced.sqlite3"))
        let first = try await Self.sync(synced, LoadedLibrary.build(cloneRoot: clone.root))
        #expect(first.rebuiltFromScratch)
        #expect(first.inserted == 5)

        try clone.write(FixtureClone.owf, try clone.read(FixtureClone.owf)
            + "\nInverting it is as hard as noisy linear algebra.\n")
        try clone.write(FixtureClone.prf, FixtureClone.page(
            type: "primitive", title: "Pseudorandom function", aliases: ["PRF", "PRFs"],
            body: "# Pseudorandom function\n\nThe GGM tree construction.\n"))
        try clone.remove(FixtureClone.ggm)
        try clone.write("content/Primitives/garbled-circuits.md", FixtureClone.page(
            type: "primitive", title: "Garbled circuits", aliases: ["GC"],
            body: "# Garbled circuits\n\nA garbled function, built from a [[PRF]].\n"))
        try clone.write(FixtureClone.diagram, "an asset has no row")
        let second = LoadedLibrary.build(cloneRoot: clone.root)

        let report = try await Self.sync(synced, second)
        #expect(report == SyncReport(inserted: 1, updated: 2, deleted: 1, unchanged: 2))

        let fresh = SearchIndex(path: scratch.file("fresh.sqlite3"))
        let built = try await Self.sync(fresh, second)
        #expect(built.rebuiltFromScratch)

        let syncedRows = try Self.rows(of: scratch.file("synced.sqlite3"))
        let freshRows = try Self.rows(of: scratch.file("fresh.sqlite3"))
        #expect(syncedRows.count == 5)
        #expect(syncedRows == freshRows)
        let expected = try await Self.answers(fresh)
        let actual = try await Self.answers(synced)
        #expect(actual.count == expected.count)
        for (got, want) in zip(actual, expected) {
            #expect(got.0 == want.0)
            #expect(got.1 == want.1, "\(want.0)")
            #expect(got.2.count == want.2.count, "\(want.0)")
            for (a, b) in zip(got.2, want.2) {
                #expect(abs(a - b) < 1e-9, "\(want.0): \(a) against \(b)")
            }
        }
        #expect(expected.contains { !$0.1.isEmpty }, "the queries find something")

        // FTS5's own check that the index and its rows agree.
        let check = try SQLiteDatabase(path: scratch.file("synced.sqlite3").path(percentEncoded: false))
        try check.execute("INSERT INTO doc_fts(doc_fts) VALUES('integrity-check')")
    }

    // MARK: Writing nothing

    @Test("a sync that finds nothing changed writes nothing, also after a relaunch")
    func unchangedWritesNothing() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try FixtureClone()
        defer { clone.delete() }
        let library = LoadedLibrary.build(cloneRoot: clone.root)
        let file = scratch.file()

        let index = SearchIndex(path: file)
        let first = try await Self.sync(index, library)
        #expect(first.rebuiltFromScratch)
        let bytes = try Data(contentsOf: file)
        let wal = try? Data(contentsOf: scratch.file("search.sqlite3-wal"))

        let again = try await Self.sync(index, library)
        #expect(again == SyncReport(unchanged: 5))
        let relaunched = SearchIndex(path: file)
        let afterRelaunch = try await Self.sync(relaunched, library)
        #expect(afterRelaunch == SyncReport(unchanged: 5))
        let bytesAfter = try Data(contentsOf: file)
        let walAfter = try? Data(contentsOf: scratch.file("search.sqlite3-wal"))
        #expect(bytesAfter == bytes, "the database file is untouched")
        #expect(walAfter == wal, "and nothing went to its log")
        let count = await relaunched.indexedCount
        #expect(count == 5)
    }

    @Test("another build's stamp rewrites every row, once")
    func builderChangeRebuilds() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try FixtureClone()
        defer { clone.delete() }
        let library = LoadedLibrary.build(cloneRoot: clone.root)
        let index = SearchIndex(path: scratch.file())

        let first = try await Self.sync(index, library, builder: "1 schema 3")
        #expect(first.rebuiltFromScratch)
        let another = try await Self.sync(index, library, builder: "2 schema 3")
        #expect(another.rebuiltFromScratch)
        let again = try await Self.sync(index, library, builder: "2 schema 3")
        #expect(again == SyncReport(unchanged: 5))
    }

    @Test("a rebuild records no stamp, so the next sync rewrites every row")
    func rebuildLeavesNoStamp() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try FixtureClone()
        defer { clone.delete() }
        let library = LoadedLibrary.build(cloneRoot: clone.root)
        let index = SearchIndex(path: scratch.file())

        let first = try await Self.sync(index, library)
        #expect(first.rebuiltFromScratch)
        try await index.rebuild(pages: library.index.allPages, backlinks: library.backlinks)
        let afterRebuild = try await Self.sync(index, library)
        #expect(afterRebuild.rebuiltFromScratch)
    }

    @Test("a version 2 database is thrown away and built again")
    func version2Resets() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try FixtureClone()
        defer { clone.delete() }
        let file = scratch.file()
        try FileManager.default.createDirectory(at: scratch.directory, withIntermediateDirectories: true)
        do {
            let old = try SQLiteDatabase(path: file.path(percentEncoded: false))
            try old.execute("""
                CREATE TABLE doc(
                  id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, slug TEXT NOT NULL,
                  kind TEXT NOT NULL, status TEXT NOT NULL, title TEXT NOT NULL,
                  aliases TEXT NOT NULL DEFAULT '', headings TEXT NOT NULL DEFAULT '',
                  body TEXT NOT NULL);
                INSERT INTO doc(path, slug, kind, status, title, body)
                  VALUES ('Gone.md', 'Gone', 'note', 'draft', 'Gone', 'A page from long ago.');
                PRAGMA user_version = 2;
                """)
        }

        let index = SearchIndex(path: file)
        let report = try await Self.sync(index, LoadedLibrary.build(cloneRoot: clone.root))
        #expect(report.rebuiltFromScratch)
        let rows = try Self.rows(of: file)
        #expect(rows.count == 5)
        #expect(!rows.contains { $0.path == "Gone.md" })
        #expect(rows.allSatisfy { !$0.hash.isEmpty }, "every row knows its file")

        let check = try SQLiteDatabase(path: file.path(percentEncoded: false))
        let version = try check.prepare("PRAGMA user_version")
        #expect(try version.step())
        #expect(version.int(0) == SearchIndex.schemaVersion)
    }

    @Test("a page with no fingerprint is rewritten on every sync")
    func missingFingerprintRewrites() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        let clone = try FixtureClone()
        defer { clone.delete() }
        let library = LoadedLibrary.build(cloneRoot: clone.root)
        let index = SearchIndex(path: scratch.file())
        let pages = library.index.allPages

        let first = try await index.sync(
            pages: pages, backlinks: library.backlinks, fingerprints: .empty, builder: "tests")
        #expect(first.rebuiltFromScratch)
        let second = try await index.sync(
            pages: pages, backlinks: library.backlinks, fingerprints: .empty, builder: "tests")
        #expect(second == SyncReport(updated: 5))
    }

    // MARK: Ties

    @Test("pages that score the same come in path order, whichever was written first")
    func tiesBreakByPath() async throws {
        let scratch = Scratch()
        defer { scratch.delete() }
        func twin(_ name: String) -> WikiPage {
            WikiPage(path: "Glossary/\(name).md", text: FixtureClone.page(
                type: "glossary", title: "Twin", body: "Twin pages say the same thing.\n"))
        }
        let (alpha, beta) = (twin("alpha"), twin("beta"))
        let digests = ContentFingerprints(
            pages: ["Glossary/alpha.md": "a", "Glossary/beta.md": "b"], manifest: nil, macros: nil)
        let index = SearchIndex(path: scratch.file())

        // Beta's row is written first, so it has the lower rowid.
        try await index.sync(pages: [beta], backlinks: [:], fingerprints: digests, builder: "tests")
        let report = try await index.sync(
            pages: [beta, alpha], backlinks: [:], fingerprints: digests, builder: "tests")
        #expect(report == SyncReport(inserted: 1, unchanged: 1))

        let hits = try await index.search("twin")
        #expect(hits.map(\.path) == ["Glossary/alpha.md", "Glossary/beta.md"])
        #expect(Set(hits.map(\.score)).count == 1, "a tie, which the path breaks")
    }
}
