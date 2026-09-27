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

        var description: String {
            func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
            var text = """
                \(name): \(count) queries
                  success@1 \(pct(successAt(1)))   success@5 \(pct(successAt(5)))   \
                MRR \(String(format: "%.3f", meanReciprocalRank))   zero results \(pct(zeroResultRate))
                """
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

    @Test("⌘S navigational queries: a concept page comes first for its own name")
    func conceptNavigation() async throws {
        guard let contentRoot = CorpusTests.contentRoot else { return }
        let index = WikiIndex.build(contentRoot: contentRoot)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-relevance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchIndex = SearchIndex(path: directory.appending(path: "search.sqlite3"))
        try await searchIndex.rebuild(pages: index.allPages)

        let judgments = Self.navigationalJudgments(index)
        #expect(judgments.count > 100, "expected the full set of concept pages")

        let report = try await Self.evaluate("⌘S navigational", judgments) { query in
            try await searchIndex.search(query).map(\.path)
        }
        print(report)

        // Baseline floors, from the first measurement on CI. Raised as the
        // ranking improves; see plans/search-v2.md §6.3.
        #expect(report.successAt(5) >= 0.5, "\(report)")
    }
}
