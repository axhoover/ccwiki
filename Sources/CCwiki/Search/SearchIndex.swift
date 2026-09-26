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
    func rebuild(pages: [WikiPage]) throws {
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
                snippet: statement.string(5)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces),
                score: statement.double(6)))
        }
        return hits
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
