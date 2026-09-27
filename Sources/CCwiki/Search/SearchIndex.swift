import Foundation

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
    /// For a paper found through a page that cites it: that page's title.
    let citedBy: String?
    /// The matching passage, marked as `SearchHit.snippet` is.
    let snippet: String

    var id: String { path }
}

/// The derived search index: SQLite FTS5, rebuilt after every pull, safe to
/// delete at any time.
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
    /// next to the query it combines with.
    private var ranker = ConceptRanker.empty
    /// ⇧⌘R's, over the references.
    private var referenceRanker = ReferenceRanker.empty

    init(path: URL) {
        self.path = path
    }

    // MARK: Schema

    /// External-content FTS5: the text lives once in `doc`, and `doc_fts`
    /// indexes it. Contentless would be smaller but `snippet()` needs the
    /// original text, and a search result without context is barely a result.
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
          body     TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS doc_slug ON doc(slug);

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

        CREATE TRIGGER IF NOT EXISTS doc_ai AFTER INSERT ON doc BEGIN
          INSERT INTO doc_fts(rowid, title, aliases, headings, body)
            VALUES (new.id, new.title, new.aliases, new.headings, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS doc_ad AFTER DELETE ON doc BEGIN
          INSERT INTO doc_fts(doc_fts, rowid, title, aliases, headings, body)
            VALUES ('delete', old.id, old.title, old.aliases, old.headings, old.body);
        END;
        CREATE TRIGGER IF NOT EXISTS doc_au AFTER UPDATE ON doc BEGIN
          INSERT INTO doc_fts(doc_fts, rowid, title, aliases, headings, body)
            VALUES ('delete', old.id, old.title, old.aliases, old.headings, old.body);
          INSERT INTO doc_fts(rowid, title, aliases, headings, body)
            VALUES (new.id, new.title, new.aliases, new.headings, new.body);
        END;
        """

    /// Bump when the tables, tokenizer or weights change. `IF NOT EXISTS`
    /// would otherwise keep an old index behind the same file name. The
    /// index is derived, so a mismatch is answered by throwing it away.
    static let schemaVersion = 2

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

    // MARK: Rebuild

    /// Rebuild from scratch. The corpus is ~300 pages and ~800 KB, so a full
    /// rebuild takes about a tenth of a second — much simpler than tracking
    /// which files a pull changed, and it cannot drift.
    ///
    /// `backlinks` is `WikiIndex.backlinkMap()`, for the concept pages that
    /// cite each reference.
    func rebuild(pages: [WikiPage], backlinks: [String: [WikiIndex.Backlink]] = [:]) throws {
        ranker = ConceptRanker(pages: pages)
        referenceRanker = ReferenceRanker(pages: pages, backlinks: backlinks)
        let database: SQLiteDatabase
        do {
            database = try open()
        } catch {
            reset()
            database = try open()
        }

        try database.transaction {
            try database.execute("DELETE FROM doc")
            let insert = try database.prepare("""
                INSERT INTO doc(path, slug, kind, status, title, aliases, headings, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)

            for page in pages {
                insert.reset()
                insert.bind(1, page.path)
                insert.bind(2, page.slug)
                insert.bind(3, page.kind.rawValue)
                insert.bind(4, page.status.rawValue)
                // References are filed under a citation key, so index the paper
                // title too — nobody searches for "AGGM06" when they mean
                // "one-way functions on NP-hardness".
                insert.bind(5, page.kind == .reference
                    ? "\(page.title) \(page.displayTitle)" : page.title)
                insert.bind(6, page.aliases.joined(separator: "\n"))
                insert.bind(7, page.headings().map(\.text).joined(separator: "\n"))
                insert.bind(8, Self.indexableBody(page.body))
                _ = try insert.step()
            }
        }
        try database.execute("INSERT INTO doc_fts(doc_fts) VALUES('optimize')")
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        indexedCount = pages.count
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
    func conceptSearch(_ query: String, limit: Int = 60) throws -> [SearchHit] {
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
            ORDER BY bm25(doc_fts, 14.0, 10.0, 4.0, 1.0)
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
