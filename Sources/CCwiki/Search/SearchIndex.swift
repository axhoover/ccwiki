import Foundation
import OSLog

/// One full-text hit.
struct SearchHit: Identifiable, Sendable {
    let path: String
    let slug: String
    let title: String
    let kind: PageKind
    let status: PageStatus
    /// The matching passage, with `«` … `»` around matched terms. Markers
    /// rather than HTML because this renders in SwiftUI, not the web view.
    let snippet: String
    let score: Double
    /// The heading that matched, when a section rather than the page is the
    /// best answer. Plain text, for the result row.
    var section: String? = nil
    /// That heading's anchor, so the reader opens the page there.
    var anchor: String? = nil

    var id: String { path }
}

/// What ⌘S found, and the corrected query it found it for when nothing
/// matched the query as typed.
struct ConceptResults: Sendable {
    var hits: [SearchHit]
    var correction: String?
}

/// One ⇧⌘R hit: a paper, and why it matched.
struct ReferenceHit: Identifiable, Sendable {
    let path: String
    let key: String
    let title: String
    let authors: String
    let venue: String?
    let year: Int?
    let status: PageStatus
    let field: ReferenceRanker.Field
    /// For a paper found through a page that cites it: that page's title,
    /// and the reduction or barrier it cites the paper through, if any.
    let citedBy: String?
    let citedVia: String?
    /// The matching passage, marked as `SearchHit.snippet` is.
    let snippet: String

    var id: String { path }
}

/// What one `SearchIndex.sync` wrote, for the log.
struct SyncReport: Equatable, Sendable {
    var inserted = 0, updated = 0, deleted = 0, unchanged = 0
    var rebuiltFromScratch = false

    /// Rows written, of any kind.
    var writes: Int { inserted + updated + deleted }

    /// "3 updated, 874 unchanged", or "rebuilt, 877 rows".
    var summary: String {
        if rebuiltFromScratch { return "rebuilt, \(inserted) rows" }
        return "\(inserted) inserted, \(updated) updated, \(deleted) deleted, \(unchanged) unchanged"
    }
}

/// The derived search index: SQLite FTS5, brought in line with the library
/// after every load, safe to delete at any time.
///
/// Nothing else in the app reads from it, and nothing in it is authoritative —
/// if the file is missing or corrupt the app deletes it and rebuilds, and the
/// only cost is that global search is briefly unavailable.
///
/// An `actor` because the system SQLite is built `SQLITE_THREADSAFE=2`, where a
/// single connection may not be touched from two threads at once. The actor is
/// the serialization, so the connection opens `NOMUTEX` and pays no lock.
actor SearchIndex {

    private let path: URL
    private var database: SQLiteDatabase?
    private(set) var indexedCount = 0
    /// ⌘S's ordering rules, over the pages of the last rebuild. Held here
    /// rather than on the main actor because it is read on every keystroke,
    /// next to the query it combines with. Readable so the tests can hold
    /// both rankers against ones built from the pages.
    private(set) var ranker = ConceptRanker.empty
    /// ⇧⌘R's, over the references.
    private(set) var referenceRanker = ReferenceRanker.empty

    init(path: URL) {
        self.path = path
    }

    // MARK: Schema

    /// External-content FTS5: the text lives once in `doc`, and `doc_fts`
    /// indexes it. Contentless would be smaller but `snippet()` needs the
    /// original text, and a search result without context is barely a result.
    ///
    /// `doc.hash` is the fingerprint of the file each row was built from, and
    /// `meta` holds `builder`, the build that wrote the rows, so a load
    /// rewrites only the rows whose file changed (plans/reader-comforts.md
    /// §3.4).
    private static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA busy_timeout = 5000;

        CREATE TABLE IF NOT EXISTS doc(
          id       INTEGER PRIMARY KEY,
          path     TEXT NOT NULL UNIQUE,
          slug     TEXT NOT NULL,
          kind     TEXT NOT NULL,
          status   TEXT NOT NULL,
          title    TEXT NOT NULL,
          aliases  TEXT NOT NULL DEFAULT '',
          headings TEXT NOT NULL DEFAULT '',
          body     TEXT NOT NULL,
          -- '' when the file's fingerprint was not known: it never matches.
          hash     TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS doc_slug ON doc(slug);

        CREATE TABLE IF NOT EXISTS meta(
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS doc_fts USING fts5(
          title, aliases, headings, body,
          content='doc', content_rowid='id',
          -- `remove_diacritics 2` is what makes `vigenere` find `Vigenère`.
          -- No `tokenchars '-_'`: this wiki is full of hyphenated slugs, and
          -- with hyphens as token characters `rsa` stops matching
          -- `rsa-assumption`. Default separators give both behaviours, because
          -- `"one-time"` still works as an implicit phrase.
          tokenize = "unicode61 remove_diacritics 2",
          prefix = '2 3'
        );

        \(insertDeleteTriggers)
        CREATE TRIGGER IF NOT EXISTS doc_au AFTER UPDATE ON doc BEGIN
          INSERT INTO doc_fts(doc_fts, rowid, title, aliases, headings, body)
            VALUES ('delete', old.id, old.title, old.aliases, old.headings, old.body);
          INSERT INTO doc_fts(rowid, title, aliases, headings, body)
            VALUES (new.id, new.title, new.aliases, new.headings, new.body);
        END;
        """

    /// The triggers that keep `doc_fts` in step with an insert into `doc` and
    /// a delete from it. `writeAll` drops them while it writes every row,
    /// builds the full-text index once from the rows, and makes them again
    /// from this same text.
    private static let insertDeleteTriggers = """
        CREATE TRIGGER IF NOT EXISTS doc_ai AFTER INSERT ON doc BEGIN
          INSERT INTO doc_fts(rowid, title, aliases, headings, body)
            VALUES (new.id, new.title, new.aliases, new.headings, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS doc_ad AFTER DELETE ON doc BEGIN
          INSERT INTO doc_fts(doc_fts, rowid, title, aliases, headings, body)
            VALUES ('delete', old.id, old.title, old.aliases, old.headings, old.body);
        END;
        """

    /// Bump when the tables, tokenizer or weights change. `IF NOT EXISTS`
    /// would otherwise keep an old index behind the same file name. The
    /// index is derived, so a mismatch is answered by throwing it away.
    /// Version 3 added `doc.hash` and `meta`.
    static let schemaVersion = 3

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = path.path(percentEncoded: false)
        var opened = try SQLiteDatabase(path: file)
        if try Self.userVersion(of: opened) != Self.schemaVersion {
            reset()
            opened = try SQLiteDatabase(path: file)
            try opened.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
        try opened.execute(Self.schema)
        database = opened
        return opened
    }

    private static func userVersion(of database: SQLiteDatabase) throws -> Int {
        let statement = try database.prepare("PRAGMA user_version")
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// Throw the index away and start over. The index is derived, so this is
    /// always a safe answer to corruption.
    func reset() {
        database = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                atPath: path.path(percentEncoded: false) + suffix)
        }
    }

    // MARK: Writing

    /// Rebuild from scratch: every row written again, and no `builder`
    /// recorded, so the next `sync` rebuilds too.
    ///
    /// `backlinks` is `WikiIndex.backlinkMap()`, for the concept pages that
    /// cite each reference.
    func rebuild(pages: [WikiPage], backlinks: [String: [WikiIndex.Backlink]] = [:]) throws {
        let pages = Self.sortedByPath(pages)
        var outlines: [String: ConceptRanker.Outline] = [:]
        defer { rank(pages, outlines: outlines, backlinks: backlinks) }
        let database = try openOrReset()
        _ = try writeAll(pages, digests: [:], builder: nil, outlines: &outlines, in: database)
    }

    /// Bring the index in line with a library load: what `AppModel` calls
    /// after every one (plans/reader-comforts.md §3.4).
    ///
    /// The rows are kept by the fingerprint of the file each was built from,
    /// and stamped with `builder`, the build that wrote them:
    ///
    /// - A `builder` that differs from the stamp (another app build, or a
    ///   fresh file) rewrites every row, so a change to how rows are built
    ///   rebuilds once with no one having to remember a version bump.
    /// - Otherwise only the rows whose fingerprint differs are rewritten, new
    ///   pages inserted and gone ones deleted, in one transaction. A load
    ///   whose index already matches, as at most launches, writes nothing.
    ///
    /// The stamp is written in the same transaction as the rows, so a crash
    /// never leaves it over rows it does not describe. Any doubt (a read that
    /// fails, `CCWIKI_FULL_RELOAD=1`) is answered with the full rewrite.
    @discardableResult
    func sync(
        pages: [WikiPage], backlinks: [String: [WikiIndex.Backlink]],
        fingerprints: ContentFingerprints, builder: String
    ) throws -> SyncReport {
        let clock = ContinuousClock()
        let start = clock.now
        let pages = Self.sortedByPath(pages)

        // Each page's outline as this sync comes to know it: parsed for a row
        // it writes. The rankers are built from it when the writing ends,
        // however it ends, and parse only the pages it lacks, so no page is
        // parsed twice (`rank`).
        var outlines: [String: ConceptRanker.Outline] = [:]
        let report: SyncReport
        do {
            defer { rank(pages, outlines: outlines, backlinks: backlinks) }
            var database = try openOrReset()
            do {
                let stamped = try Self.builder(in: database)
                if stamped != builder || LibraryChanges.areIgnored {
                    report = try writeAll(
                        pages, digests: fingerprints.pages, builder: builder,
                        outlines: &outlines, in: database)
                } else {
                    report = try writeChanges(
                        pages, digests: fingerprints.pages, builder: builder,
                        outlines: &outlines, in: database)
                }
            } catch {
                reset()
                database = try open()
                report = try writeAll(
                    pages, digests: fingerprints.pages, builder: builder,
                    outlines: &outlines, in: database)
            }
        }

        let message = "Search index: \(report.summary) in \(start.duration(to: clock.now))"
        Logger.library.notice("\(message, privacy: .public)")
        return report
    }

    /// The rankers, from pages sorted by path: their ties then fall the same
    /// way whichever build made the rows. `outlines` holds the headings
    /// already parsed for the rows, by path, which are not parsed again.
    private func rank(
        _ pages: [WikiPage], outlines: [String: ConceptRanker.Outline],
        backlinks: [String: [WikiIndex.Backlink]]
    ) {
        ranker = ConceptRanker(pages: pages, headings: outlines)
        referenceRanker = ReferenceRanker(pages: pages, backlinks: backlinks)
    }

    private static func sortedByPath(_ pages: [WikiPage]) -> [WikiPage] {
        pages.sorted { $0.path < $1.path }
    }

    private func openOrReset() throws -> SQLiteDatabase {
        do {
            return try open()
        } catch {
            reset()
            return try open()
        }
    }

    /// Every row deleted and written again, then the index optimized and
    /// the log folded into the file. Each page's outline goes to `outlines`.
    ///
    /// The full-text index is built once from the new rows, by FTS5's
    /// `'rebuild'`, rather than kept in step row by row: through the
    /// triggers every old row was tokenized out of the index and every new
    /// one into it, which over a populated index (the launch after an app
    /// update) cost about four times as much. The triggers are dropped and
    /// made again in the same transaction, so a failure leaves them as it
    /// leaves the rows.
    private func writeAll(
        _ pages: [WikiPage], digests: [String: String], builder: String?,
        outlines: inout [String: ConceptRanker.Outline], in database: SQLiteDatabase
    ) throws -> SyncReport {
        try database.transaction {
            try database.execute("DROP TRIGGER IF EXISTS doc_ai; DROP TRIGGER IF EXISTS doc_ad;")
            try database.execute("DELETE FROM doc")
            let insert = try database.prepare(Self.insertRow)
            for page in pages {
                outlines[page.path] = try Self.write(page, digest: digests[page.path], with: insert)
            }
            try database.execute("INSERT INTO doc_fts(doc_fts) VALUES('rebuild')")
            try database.execute(Self.insertDeleteTriggers)
            try Self.stamp(builder, in: database)
        }
        try database.execute("INSERT INTO doc_fts(doc_fts) VALUES('optimize')")
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        indexedCount = pages.count
        return SyncReport(inserted: pages.count, rebuiltFromScratch: true)
    }

    /// Only the rows whose file changed, came or went. FTS5's automerge keeps
    /// the index in shape after a few writes; a pull that touched many pages
    /// is optimized as a rebuild is. The outline of each page written goes
    /// to `outlines`.
    private func writeChanges(
        _ pages: [WikiPage], digests: [String: String], builder: String,
        outlines: inout [String: ConceptRanker.Outline], in database: SQLiteDatabase
    ) throws -> SyncReport {
        var stored = try Self.storedHashes(in: database)
        var report = SyncReport()
        var inserts: [WikiPage] = []
        var updates: [WikiPage] = []
        for page in pages {
            guard let hash = stored.removeValue(forKey: page.path) else {
                inserts.append(page)
                continue
            }
            // A page with no fingerprint is always rewritten: nothing says
            // its row still describes it.
            if let digest = digests[page.path], digest == hash {
                report.unchanged += 1
            } else {
                updates.append(page)
            }
        }
        let deletions = stored.keys.sorted()
        report.inserted = inserts.count
        report.updated = updates.count
        report.deleted = deletions.count
        indexedCount = pages.count
        guard report.writes > 0 else { return report }

        try database.transaction {
            let delete = try database.prepare("DELETE FROM doc WHERE path = ?")
            for path in deletions {
                delete.reset()
                delete.bind(1, path)
                _ = try delete.step()
            }
            // The `doc_au` trigger keeps the full-text index in step.
            let update = try database.prepare(Self.updateRow)
            for page in updates {
                outlines[page.path] = try Self.write(page, digest: digests[page.path], with: update)
            }
            let insert = try database.prepare(Self.insertRow)
            for page in inserts {
                outlines[page.path] = try Self.write(page, digest: digests[page.path], with: insert)
            }
            try Self.stamp(builder, in: database)
        }
        if report.writes > Self.optimizeAfterWrites {
            try database.execute("INSERT INTO doc_fts(doc_fts) VALUES('optimize')")
        }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return report
    }

    /// More writes than this, and a sync optimizes the index as a rebuild
    /// does; fewer are left to FTS5's automerge.
    static let optimizeAfterWrites = 100

    private static let insertRow = """
        INSERT INTO doc(path, slug, kind, status, title, aliases, headings, body, hash)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        """

    private static let updateRow = """
        UPDATE doc SET slug = ?2, kind = ?3, status = ?4, title = ?5, aliases = ?6,
          headings = ?7, body = ?8, hash = ?9
        WHERE path = ?1
        """

    /// Binds `page`'s row to `statement`, one of the two above, and runs it.
    /// Returns the page's outline, parsed for the row, which the concept
    /// ranker then reads rather than parse the page a second time.
    private static func write(
        _ page: WikiPage, digest: String?, with statement: SQLiteDatabase.Statement
    ) throws -> ConceptRanker.Outline {
        let headings = page.headings()
        statement.reset()
        statement.bind(1, page.path)
        statement.bind(2, page.slug)
        statement.bind(3, page.kind.rawValue)
        statement.bind(4, page.status.rawValue)
        // References are filed under a citation key, so index the paper
        // title too — nobody searches for "AGGM06" when they mean
        // "one-way functions on NP-hardness".
        statement.bind(5, page.kind == .reference
            ? "\(page.title) \(page.displayTitle)" : page.title)
        statement.bind(6, page.aliases.joined(separator: "\n"))
        statement.bind(7, headings.map(\.text).joined(separator: "\n"))
        statement.bind(8, indexableBody(page.body))
        statement.bind(9, digest ?? "")
        _ = try statement.step()
        return ConceptRanker.outline(headings)
    }

    /// Each row's path and the fingerprint it was built from.
    private static func storedHashes(in database: SQLiteDatabase) throws -> [String: String] {
        var stored: [String: String] = [:]
        let select = try database.prepare("SELECT path, hash FROM doc")
        while try select.step() {
            stored[select.string(0)] = select.string(1)
        }
        return stored
    }

    /// The build that wrote the rows, if one is recorded.
    private static func builder(in database: SQLiteDatabase) throws -> String? {
        let statement = try database.prepare("SELECT value FROM meta WHERE key = 'builder'")
        return try statement.step() ? statement.string(0) : nil
    }

    /// Records `builder` as the build that wrote the rows; nil records none.
    private static func stamp(_ builder: String?, in database: SQLiteDatabase) throws {
        guard let builder else {
            try database.execute("DELETE FROM meta WHERE key = 'builder'")
            return
        }
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO meta(key, value) VALUES ('builder', ?)")
        statement.bind(1, builder)
        _ = try statement.step()
    }

    /// Strip the markup that makes search results unreadable while keeping the
    /// words. `$…$` delimiters go but the TeX inside stays, so `NC^0` remains
    /// findable on a page whose heading is `Cryptography in $NC^0$`.
    static func indexableBody(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(
            of: #"\[\[([^\[\]\|]*)\|([^\[\]]*)\]\]"#, with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\[\[([^\[\]]*)\]\]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "$", with: " ")
        text = text.replacingOccurrences(of: "`", with: " ")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        // Block markers and emphasis, which otherwise turn up in snippets as
        // `## Syntax` and `**key**`. Underscores inside identifiers stay:
        // an emphasis delimiter has a non-word character on one side.
        text = text.replacingOccurrences(
            of: #"(?m)^[ \t]*#{1,6}[ \t]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?m)^[ \t]*(?:[-*+]|\d+\.)[ \t]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?m)^[ \t]*>[ \t]?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(
            of: #"(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)"#, with: "", options: .regularExpression)
        return text.precomposedStringWithCanonicalMapping
    }

    // MARK: Query

    /// ⌘S: concept pages, references left out, in `ConceptRanker`'s order.
    ///
    /// Every non-reference page the full text matches is scored, not a top
    /// few: the ranker's first rules outrank BM25, so the page that belongs
    /// first can sit anywhere in BM25's order. That is at most a few hundred
    /// rows.
    ///
    /// When nothing matches as typed, each word no name contains is corrected
    /// to the nearest one that does, and the search runs again: a one-letter
    /// typo otherwise returned nothing 99% of the time (plans/search-v2.md
    /// §6.7).
    func conceptSearch(_ query: String, limit: Int = 60) throws -> ConceptResults {
        let hits = try conceptHits(query, limit: limit)
        guard hits.isEmpty, let corrected = ranker.correction(for: query) else {
            return ConceptResults(hits: hits, correction: nil)
        }
        return ConceptResults(hits: try conceptHits(corrected, limit: limit), correction: corrected)
    }

    private func conceptHits(_ query: String, limit: Int) throws -> [SearchHit] {
        let (scores, snippets) = try textMatches(query, kindClause: "d.kind != 'reference'")

        return ranker.rank(query, textScores: scores, limit: limit).map { ranked in
            let entry = ranked.entry
            return SearchHit(
                path: entry.path,
                slug: entry.slug,
                title: entry.title,
                kind: entry.kind,
                status: entry.status,
                snippet: snippets[entry.path] ?? "",
                score: scores[entry.path] ?? 0,
                section: ranked.section?.name.text,
                anchor: ranked.section?.id)
        }
    }

    /// ⇧⌘R: references only, in `ReferenceRanker`'s order.
    func referenceSearch(_ query: String, limit: Int = 60) throws -> [ReferenceHit] {
        let text = ReferenceRanker.parse(query).text
        let (scores, snippets) = try textMatches(text, kindClause: "d.kind = 'reference'")
        return referenceRanker.rank(query, textScores: scores, limit: limit).map { ranked in
            let entry = ranked.entry
            return ReferenceHit(
                path: entry.path, key: entry.key, title: entry.title,
                authors: entry.authors, venue: entry.venue, year: entry.year,
                status: entry.status, field: ranked.field,
                citedBy: ranked.citer?.title,
                citedVia: ranked.citer?.via,
                snippet: snippets[entry.path] ?? "")
        }
    }

    /// BM25 and a snippet for every page of the given kinds the text matches.
    /// `kindClause` is a fixed SQL condition on `d.kind`, never user input.
    private func textMatches(_ query: String, kindClause: String) throws
        -> (scores: [String: Double], snippets: [String: String]) {
        var scores: [String: Double] = [:]
        var snippets: [String: String] = [:]
        guard let expression = Self.matchExpression(query) else { return (scores, snippets) }
        let statement = try open().prepare("""
            SELECT d.path,
                   snippet(doc_fts, -1, '«', '»', '…', 14),
                   bm25(doc_fts, 14.0, 10.0, 4.0, 1.0)
            FROM doc_fts
            JOIN doc d ON d.id = doc_fts.rowid
            WHERE doc_fts MATCH ? AND \(kindClause)
            """)
        statement.bind(1, expression)
        while try statement.step() {
            let path = statement.string(0)
            snippets[path] = Self.oneLine(statement.string(1))
            scores[path] = statement.double(2)
        }
        return (scores, snippets)
    }

    /// Every page, in BM25 order alone: ⌘S before it had rules, kept as the
    /// baseline the relevance report compares against.
    func search(_ query: String, limit: Int = 60) throws -> [SearchHit] {
        guard let expression = Self.matchExpression(query) else { return [] }
        let database = try open()

        let statement = try database.prepare("""
            SELECT d.path, d.slug, d.title, d.kind, d.status,
                   snippet(doc_fts, -1, '«', '»', '…', 14),
                   bm25(doc_fts, 14.0, 10.0, 4.0, 1.0)
            FROM doc_fts
            JOIN doc d ON d.id = doc_fts.rowid
            WHERE doc_fts MATCH ?
            ORDER BY bm25(doc_fts, 14.0, 10.0, 4.0, 1.0), d.path
            LIMIT ?
            """)
        statement.bind(1, expression)
        statement.bind(2, limit)

        var hits: [SearchHit] = []
        while try statement.step() {
            hits.append(SearchHit(
                path: statement.string(0),
                slug: statement.string(1),
                title: statement.string(2),
                kind: PageKind(rawValue: statement.string(3)) ?? .note,
                status: PageStatus(rawValue: statement.string(4)) ?? .draft,
                snippet: Self.oneLine(statement.string(5)),
                score: statement.double(6)))
        }
        return hits
    }

    private static func oneLine(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Turn arbitrary typed text into a safe FTS5 `MATCH` expression.
    ///
    /// `MATCH` takes a query *language*, not a literal: `AND`, `OR`, `NOT`,
    /// `NEAR`, `*`, `^`, `:`, `-`, `(`, `)` and `"` all mean something, so raw
    /// input either errors or quietly searches for something else. Quoting each
    /// whitespace-separated run makes every character literal; the trailing `*`
    /// on the last token is what makes search feel live while typing.
    ///
    /// Returns `nil` when nothing searchable is left, so the caller shows an
    /// empty result rather than running a query that will throw.
    static func matchExpression(_ raw: String, prefixLastToken: Bool = true) -> String? {
        // An embedded NUL truncates the bound text (sqlite3_bind_text uses
        // strlen), leaving an unterminated string literal in the expression.
        let cleaned = raw.replacingOccurrences(of: "\u{0}", with: "")
        let tokens = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var parts: [String] = []
        for token in tokens {
            // A token with no alphanumerics tokenizes to the empty phrase,
            // which FTS5 rejects outright.
            guard token.unicodeScalars.contains(where: {
                CharacterSet.alphanumerics.contains($0)
            }) else { continue }
            parts.append("\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        guard !parts.isEmpty else { return nil }
        if prefixLastToken { parts[parts.count - 1] += "*" }
        return parts.joined(separator: " ")  // space-join is an implicit AND
    }
}
