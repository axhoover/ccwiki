import Foundation

/// ⇧⌘R: the order the reference search shows papers in, field by field, the
/// way reference managers and dblp search (plans/search-v2.md §6.1).
///
/// A query is matched against, in order of what it most likely means:
///
/// 1. **A citation key**: the page's key, its aliases, its cryptobib key.
///    `GGM86`, `STOC:AGGM06`, or the start of one.
/// 2. **Authors**: every query word is a word of some author's name,
///    accents folded, so `goldreich micali` finds the paper they wrote
///    together and `Dottling` finds Döttling.
/// 3. **The paper's title**, whole or in part.
/// 4. **Authors, title and venue together**: `goldreich random functions`.
/// 5. **Cited by**: a concept page whose name matches cites the paper, so
///    `oblivious transfer` also finds the papers the OT page is built on,
///    whatever their titles say.
/// 6. **Text**, the abstract most of all, by BM25.
///
/// A four-digit year in the query (`regev 2005`) is a filter, not a word.
/// Within a field: the finer match, then BM25, then the newer paper.
struct ReferenceRanker: Sendable {

    enum Field: Int, Comparable, Sendable {
        case key, author, title, mixed, citedBy, text

        static func < (lhs: Field, rhs: Field) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    typealias Name = ConceptRanker.Name

    struct Entry: Sendable {
        let path: String
        /// The citation key, `GGM86`.
        let key: String
        /// The paper's title, from the filename.
        let title: String
        let status: PageStatus
        /// As written in the frontmatter, for display.
        let authors: String
        let venue: String?
        let year: Int?
        let keys: [Name]
        let titleName: Name
        let authorWords: Set<String>
        let otherWords: Set<String>
        /// The concept pages that link here, with their names.
        let citers: [Citer]
    }

    struct Citer: Sendable {
        let path: String
        let title: String
        let names: [Name]
    }

    struct Ranked: Sendable {
        let entry: Entry
        let field: Field
        /// How well the name matched, for the fields that match a name.
        let match: ConceptRanker.Match
        /// For `.citedBy`: the citing page that matched.
        let citer: Citer?
        let score: Double
    }

    let entries: [Entry]

    static let empty = ReferenceRanker(pages: [], backlinks: [:])

    /// `backlinks` is `WikiIndex.backlinkMap()`: target path → the pages
    /// linking to it. Only concept pages count as citers here; a reference
    /// citing a reference says nothing about what the reader searched for.
    init(pages: [WikiPage], backlinks: [String: [WikiIndex.Backlink]]) {
        let byPath = Dictionary(pages.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        entries = pages.filter { $0.kind == .reference }.map { page in
            let authors = page.frontmatter.string("authors") ?? ""
            let venue = page.frontmatter.string("venue")
            let keys = [page.title] + page.aliases + [page.frontmatter.string("cryptobib_key")]
                .compactMap { $0 }
            let citers = (backlinks[page.path] ?? []).compactMap { link -> Citer? in
                guard let source = byPath[link.sourcePath], source.kind != .reference
                else { return nil }
                return Citer(
                    path: source.path, title: source.title,
                    names: ([source.title] + source.aliases).map(Name.init))
            }
            let titleName = Name(page.displayTitle)
            let authorWords = Set(Self.authorNames(authors).flatMap { Name($0).words })
            return Entry(
                path: page.path,
                key: page.title,
                title: page.displayTitle,
                status: page.status,
                authors: authors,
                venue: venue,
                year: Self.year(page.frontmatter.string("published")),
                keys: keys.map(Name.init),
                titleName: titleName,
                authorWords: authorWords,
                otherWords: authorWords
                    .union(titleName.words)
                    .union(Name(venue ?? "").words),
                citers: citers)
        }
    }

    /// `Alice, Bob, and Carol` or `Alice and Bob`: one name per author.
    static func authorNames(_ authors: String) -> [String] {
        authors
            .replacingOccurrences(
                of: #",\s*(?:and\s+)?|\s+and\s+"#, with: "\n", options: .regularExpression)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The year of `1986` or `2005-05-01`.
    static func year(_ published: String?) -> Int? {
        guard let published, published.count >= 4,
              let year = Int(published.prefix(4))
        else { return nil }
        return year
    }

    /// The query split into its text and the years it names. A year is a
    /// four-digit word from 1900 to 2099; anything else stays text.
    static func parse(_ query: String) -> (text: String, years: Set<Int>) {
        var words: [Substring] = []
        var years: Set<Int> = []
        for word in query.split(whereSeparator: \.isWhitespace) {
            if word.count == 4, word.allSatisfy(\.isASCII), let year = Int(word),
               (1900...2099).contains(year) {
                years.insert(year)
            } else {
                words.append(word)
            }
        }
        return (words.joined(separator: " "), years)
    }

    /// Every query word is a word in `pool`, the last one as a prefix.
    static func allWords(_ query: [String], in pool: Set<String>) -> Bool {
        guard !query.isEmpty else { return false }
        for (i, word) in query.enumerated() {
            if pool.contains(word) { continue }
            guard i == query.count - 1, pool.contains(where: { $0.hasPrefix(word) })
            else { return false }
        }
        return true
    }

    /// `textScores` is BM25 by path over the query's text, lower better.
    func rank(_ query: String, textScores: [String: Double], limit: Int = 60) -> [Ranked] {
        let (text, years) = Self.parse(query)
        let name = Name(text)
        let hasText = !name.exact.isEmpty
        guard hasText || !years.isEmpty else { return [] }

        var ranked: [Ranked] = []
        for entry in entries {
            if !years.isEmpty {
                guard let year = entry.year, years.contains(year) else { continue }
            }
            let score = textScores[entry.path] ?? .greatestFiniteMagnitude
            guard hasText else {
                // A year alone lists that year's papers.
                ranked.append(Ranked(entry: entry, field: .key, match: .exact, citer: nil, score: 0))
                continue
            }
            if let field = Self.field(name, entry, inText: textScores[entry.path] != nil) {
                ranked.append(Ranked(
                    entry: entry, field: field.field, match: field.match,
                    citer: field.citer, score: score))
            }
        }

        ranked.sort { a, b in
            if a.field != b.field { return a.field < b.field }
            if a.match != b.match { return a.match < b.match }
            if a.score != b.score { return a.score < b.score }
            if a.entry.year != b.entry.year { return (a.entry.year ?? 0) > (b.entry.year ?? 0) }
            return a.entry.key.localizedStandardCompare(b.entry.key) == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }

    /// The best field `name` matches on `entry`, or nil.
    private static func field(_ name: Name, _ entry: Entry, inText: Bool)
        -> (field: Field, match: ConceptRanker.Match, citer: Citer?)? {
        let keyMatch = entry.keys.compactMap { ConceptRanker.match(name, $0) }
            .filter { $0 <= .prefix }.min()
        if let keyMatch { return (.key, keyMatch, nil) }
        if allWords(name.words, in: entry.authorWords) { return (.author, .allWords, nil) }
        if let titleMatch = ConceptRanker.match(name, entry.titleName) {
            return (.title, titleMatch, nil)
        }
        if allWords(name.words, in: entry.otherWords) { return (.mixed, .allWords, nil) }

        var best: (match: ConceptRanker.Match, citer: Citer)?
        for citer in entry.citers {
            for citerName in citer.names {
                guard let match = ConceptRanker.match(name, citerName),
                      best.map({ match < $0.match }) ?? true
                else { continue }
                best = (match, citer)
            }
        }
        if let best { return (.citedBy, best.match, best.citer) }
        return inText ? (.text, .text, nil) : nil
    }
}
