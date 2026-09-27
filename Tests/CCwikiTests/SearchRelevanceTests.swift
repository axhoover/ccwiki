import Foundation
import Testing
@testable import CCwiki

/// How good is search, in numbers, against the real wiki.
///
/// The judgment list is generated from the wiki itself (plans/search-v2.md
/// §6.3), so it grows as the wiki does and nobody has to write it. Skipped
/// unless `CCWIKI_WIKI` points at a clone; CI clones the wiki for it.
///
/// Every run prints a report — success@1, success@5, mean reciprocal rank,
/// zero-result rate, and the queries that missed — because a missed query is
/// most often a page missing an alias, and the report is where that shows.
/// The assertions are floors, set from an honest measurement, not targets:
/// the wiki changes daily and this must not go red on an ordinary edit.
struct SearchRelevanceTests {

    /// The sections ⌘S exists to find, which the navigational set covers.
    static let conceptKinds: Set<PageKind> = [.primitive, .assumption, .complexityClass]

    struct Judgment: Sendable {
        let query: String
        let expected: String
    }

    struct Report: CustomStringConvertible {
        let name: String
        /// 1-based rank of the expected page, nil when it did not appear.
        var ranks: [(Judgment, Int?, [String])] = []

        var count: Int { ranks.count }
        func successAt(_ k: Int) -> Double {
            Double(ranks.count { ($0.1 ?? .max) <= k }) / Double(max(count, 1))
        }
        var meanReciprocalRank: Double {
            var total = 0.0
            for (_, rank, _) in ranks {
                if let rank { total += 1 / Double(rank) }
            }
            return total / Double(max(count, 1))
        }
        var zeroResultRate: Double {
            Double(ranks.count { $0.2.isEmpty }) / Double(max(count, 1))
        }

        /// The numbers alone.
        var summary: String {
            func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
            return """
                \(name): \(count) queries
                  success@1 \(pct(successAt(1)))   success@5 \(pct(successAt(5)))   \
                MRR \(String(format: "%.3f", meanReciprocalRank))   zero results \(pct(zeroResultRate))
                """
        }

        /// The numbers, and every query that missed.
        var description: String {
            var text = summary
            let misses = ranks.filter { ($0.1 ?? .max) > 1 }
            if !misses.isEmpty {
                text += "\n  not first (\(misses.count)):"
                for (judgment, rank, top) in misses.prefix(40) {
                    let where_ = rank.map { "#\($0)" } ?? "absent"
                    text += "\n    \(judgment.query.debugDescription) → \(judgment.expected) is \(where_); "
                        + "first: \(top.first ?? "nothing")"
                }
            }
            return text
        }
    }

    /// Every concept page by its title, and by each alias no other page
    /// claims: the page must come first for its own name.
    static func navigationalJudgments(_ index: WikiIndex) -> [Judgment] {
        var owners: [String: Set<String>] = [:]
        for page in index.pages.values {
            for name in [page.title] + page.aliases {
                owners[name.lowercased(), default: []].insert(page.path)
            }
        }
        var judgments: [Judgment] = []
        for page in index.pages.values.sorted(by: { $0.path < $1.path })
        where conceptKinds.contains(page.kind) {
            var seen: Set<String> = []
            for name in [page.title] + page.aliases {
                let key = name.lowercased()
                guard owners[key] == [page.path], seen.insert(key).inserted,
                      name.trimmingCharacters(in: .whitespaces).count >= 2
                else { continue }
                judgments.append(Judgment(query: name, expected: page.path))
            }
        }
        return judgments
    }

    /// Every variant the relations manifest names, by the heading it lives
    /// under, when no other page has that heading or name: the host page must
    /// come first, opened at that heading. Results are `path#anchor`.
    static func sectionJudgments(_ index: WikiIndex, manifest: RelationsManifest) -> [Judgment] {
        let pages = index.pages.values.filter { $0.kind != .reference }
        var owners: [String: Set<String>] = [:]
        var names: [String: Set<String>] = [:]
        for page in pages {
            for name in [page.title] + page.aliases {
                owners[name.lowercased(), default: []].insert(page.path)
                names[page.path, default: []].insert(name.lowercased())
            }
            for heading in page.headings() {
                owners[RelationText.plain(heading.text).lowercased(), default: []]
                    .insert(page.path)
            }
        }
        var judgments: [Judgment] = []
        for object in manifest.objectsByID.values.sorted(by: { $0.id < $1.id })
        where object.isVariant {
            guard let anchor = object.anchor, let page = index.pages[object.path],
                  let heading = page.headings().first(where: { $0.id == anchor })
            else { continue }
            let text = RelationText.plain(heading.text)
            let key = text.lowercased()
            // A heading that repeats a page name is found as the name.
            guard owners[key] == [page.path], !(names[page.path]?.contains(key) ?? false)
            else { continue }
            judgments.append(Judgment(query: text, expected: "\(page.path)#\(anchor)"))
        }
        return judgments
    }

    static func evaluate(
        _ name: String, _ judgments: [Judgment], search: (String) async throws -> [String]
    ) async throws -> Report {
        var report = Report(name: name)
        for judgment in judgments {
            let results = try await search(judgment.query)
            let rank = results.firstIndex(of: judgment.expected).map { $0 + 1 }
            report.ranks.append((judgment, rank, Array(results.prefix(3))))
        }
        return report
    }

    static func buildIndex(_ index: WikiIndex, in directory: URL) async throws -> SearchIndex {
        let searchIndex = SearchIndex(path: directory.appending(path: "search.sqlite3"))
        try await searchIndex.rebuild(pages: index.allPages, backlinks: index.backlinkMap())
        return searchIndex
    }

    @Test("⌘S navigational queries: a concept page comes first for its own name")
    func conceptNavigation() async throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-relevance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchIndex = try await Self.buildIndex(index, in: directory)

        let judgments = Self.navigationalJudgments(index)
        #expect(judgments.count > 100, "expected the full set of concept pages")

        // BM25 alone, as ⌘S was before its rules: printed for comparison.
        let baseline = try await Self.evaluate("BM25 alone (the old ⌘S)", judgments) { query in
            try await searchIndex.search(query).map(\.path)
        }
        print(baseline.summary)

        let report = try await Self.evaluate("⌘S navigational", judgments) { query in
            try await searchIndex.conceptSearch(query).hits.map(\.path)
        }
        print(report)

        // Floors, not targets: the first measurement with the rules was 100%
        // on both, and the wiki changes daily. See plans/search-v2.md §6.3.
        #expect(report.successAt(1) >= 0.95, "\(report)")
        #expect(report.successAt(5) >= 0.98, "\(report)")
    }

    @Test("⌘S section queries: a variant's heading opens its page at that heading")
    func sectionLanding() async throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let manifest = RelationsManifest.load(cloneRoot: contentRoot.deletingLastPathComponent())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-relevance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchIndex = try await Self.buildIndex(index, in: directory)

        let judgments = Self.sectionJudgments(index, manifest: manifest)
        #expect(judgments.count > 50, "expected most of the manifest's variants")

        let report = try await Self.evaluate("⌘S sections", judgments) { query in
            try await searchIndex.conceptSearch(query).hits.map { hit in
                hit.anchor.map { "\(hit.path)#\($0)" } ?? hit.path
            }
        }
        print(report)
        #expect(report.successAt(1) >= 0.9, "\(report)")
    }

    /// Every paper by its citation key and by its title, which must come
    /// first, and by its first author's surname and year, which must be in
    /// the top three: a surname and a year can belong to more than one paper.
    static func referenceJudgments(_ index: WikiIndex)
        -> (key: [Judgment], title: [Judgment], authorYear: [Judgment]) {
        let references = index.allPages.filter { $0.kind == .reference }
            .sorted { $0.path < $1.path }
        var titleCounts: [String: Int] = [:]
        for page in references { titleCounts[page.displayTitle.lowercased(), default: 0] += 1 }

        let byKey = references.map { Judgment(query: $0.title, expected: $0.path) }
        let byTitle = references
            .filter { titleCounts[$0.displayTitle.lowercased()] == 1 && $0.displayTitle != $0.title }
            .map { Judgment(query: $0.displayTitle, expected: $0.path) }
        let byAuthorYear = references.compactMap { page -> Judgment? in
            let authors = ReferenceRanker.authorNames(page.frontmatter.string("authors") ?? "")
            guard let surname = authors.first?.split(separator: " ").last,
                  let year = ReferenceRanker.year(page.frontmatter.string("published"))
            else { return nil }
            return Judgment(query: "\(surname) \(year)", expected: page.path)
        }
        return (byKey, byTitle, byAuthorYear)
    }

    @Test("⇧⌘R: a paper by its key or title comes first, by author and year in the top three")
    func referenceNavigation() async throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-relevance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchIndex = try await Self.buildIndex(index, in: directory)

        let judgments = Self.referenceJudgments(index)
        #expect(judgments.key.count > 100, "expected the full set of references")

        let byKey = try await Self.evaluate("⇧⌘R by key", judgments.key) { query in
            try await searchIndex.referenceSearch(query).map(\.path)
        }
        let byTitle = try await Self.evaluate("⇧⌘R by title", judgments.title) { query in
            try await searchIndex.referenceSearch(query).map(\.path)
        }
        let byAuthorYear = try await Self.evaluate(
            "⇧⌘R by first author and year", judgments.authorYear
        ) { query in
            try await searchIndex.referenceSearch(query).map(\.path)
        }
        print(byKey)
        print(byTitle)
        print(byAuthorYear)

        // Floors; the first measurement was 100% on all three.
        #expect(byKey.successAt(1) >= 0.95, "\(byKey)")
        #expect(byTitle.successAt(1) >= 0.9, "\(byTitle)")
        #expect(byAuthorYear.successAt(3) >= 0.9, "\(byAuthorYear)")
    }

    /// Every navigational query with one typo: the middle letter of its
    /// longest word, when that word has six letters or more, deleted.
    /// Deterministic, so the number moves only when search or the wiki does.
    static func typoJudgments(_ index: WikiIndex) -> [Judgment] {
        navigationalJudgments(index).compactMap { judgment in
            var words = judgment.query.split(separator: " ").map(String.init)
            guard let longest = words.indices.max(by: { words[$0].count < words[$1].count }),
                  words[longest].count >= 6
            else { return nil }
            var letters = Array(words[longest])
            letters.remove(at: letters.count / 2)
            words[longest] = String(letters)
            return Judgment(query: words.joined(separator: " "), expected: judgment.expected)
        }
    }

    @Test("⌘S with a typo: the correction still finds the page")
    func typos() async throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-relevance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchIndex = try await Self.buildIndex(index, in: directory)

        let judgments = Self.typoJudgments(index)
        #expect(judgments.count > 100)
        let report = try await Self.evaluate("⌘S one typo", judgments) { query in
            try await searchIndex.conceptSearch(query).hits.map(\.path)
        }
        print(report)
        // Without correction this was 0% (99% returned nothing); the Python
        // replica measured 87.6% with it. See plans/search-v2.md §6.7.
        #expect(report.successAt(1) >= 0.75, "\(report)")
    }

    /// Every navigational query spelled the other way: with its hyphens
    /// removed (`ArthurMerlin`), and with its first two words run together
    /// (`Securemulti-party computation`), the way names get typed.
    static func joinedJudgments(_ index: WikiIndex) -> (hyphens: [Judgment], joined: [Judgment]) {
        let judgments = navigationalJudgments(index)
        let hyphens = judgments.filter { $0.query.contains("-") }.map {
            Judgment(query: $0.query.replacingOccurrences(of: "-", with: ""), expected: $0.expected)
        }
        let joined = judgments.compactMap { judgment -> Judgment? in
            var words = judgment.query.split(separator: " ").map(String.init)
            guard words.count >= 2, words[0].count >= 3, words[1].count >= 3 else { return nil }
            words.replaceSubrange(0...1, with: [words[0] + words[1]])
            return Judgment(query: words.joined(separator: " "), expected: judgment.expected)
        }
        return (hyphens, joined)
    }

    @Test("⌘S with words joined or split differently from the name")
    func joinedWords() async throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-relevance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchIndex = try await Self.buildIndex(index, in: directory)

        let judgments = Self.joinedJudgments(index)
        #expect(judgments.hyphens.count > 30)
        #expect(judgments.joined.count > 100)
        let hyphens = try await Self.evaluate("⌘S hyphens removed", judgments.hyphens) { query in
            try await searchIndex.conceptSearch(query).hits.map(\.path)
        }
        let joined = try await Self.evaluate("⌘S first two words joined", judgments.joined) { query in
            try await searchIndex.conceptSearch(query).hits.map(\.path)
        }
        print(hyphens)
        print(joined)
        // Before names were also compared without their word breaks: 1.4% and
        // 2.0%. The Python replica measured 100% on both after.
        #expect(hyphens.successAt(1) >= 0.9, "\(hyphens)")
        #expect(joined.successAt(1) >= 0.9, "\(joined)")
    }
}
