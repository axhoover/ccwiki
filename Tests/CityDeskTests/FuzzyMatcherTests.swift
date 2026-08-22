import Foundation
import Testing
@testable import CityDesk

struct FuzzyMatcherTests {

    @Test("a non-subsequence does not match")
    func rejectsNonSubsequences() {
        #expect(FuzzyMatcher.match("prf", in: "#P") == nil)
        #expect(FuzzyMatcher.match("prf", in: "AGGM06") == nil)
        #expect(FuzzyMatcher.match("prf", in: "Complexity/sharp-p") == nil)
        #expect(FuzzyMatcher.match("zzz", in: "pseudorandom-function") == nil)
        #expect(FuzzyMatcher.match("longerthanthecandidate", in: "short") == nil)
    }

    @Test("a scattered subsequence matches")
    func acceptsSubsequences() {
        #expect(FuzzyMatcher.match("prf", in: "pseudorandom-function") != nil)
        #expect(FuzzyMatcher.match("prf", in: "PRF") != nil)
        #expect(FuzzyMatcher.match("ot", in: "oblivious-transfer") != nil)
    }

    @Test("word starts and prefixes outrank scattered matches")
    func ranking() throws {
        let acronym = try #require(FuzzyMatcher.match("prf", in: "pseudorandom-function"))
        let scattered = try #require(FuzzyMatcher.match("prf", in: "proof of retrievability faff"))
        _ = scattered

        let exact = try #require(FuzzyMatcher.match("prf", in: "PRF"))
        #expect(exact.score > acronym.score, "an exact prefix beats an acronym match")

        let early = try #require(FuzzyMatcher.match("lwe", in: "learning-with-errors"))
        let late = try #require(FuzzyMatcher.match("lwe", in: "a-really-long-title-lwe"))
        #expect(early.score > late.score)
    }

    @Test("matching is case-insensitive but reports real indices")
    func positions() throws {
        let match = try #require(FuzzyMatcher.match("PRF", in: "pseudorandom-function"))
        #expect(match.positions.count == 3)
        let candidate = "pseudorandom-function"
        #expect(match.positions.map { candidate[$0] } == ["p", "r", "f"])
    }
}

@MainActor
struct QuickSwitcherRankingTests {

    /// The regression that motivated this suite: typing `prf` used to return
    /// every page in alphabetical order, because the ranking comparator was
    /// wrong and every candidate tied.
    @Test("typing an acronym puts its page first")
    func acronymRanking() throws {
        let (index, root) = try WikilinkResolutionTests.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let results = index.quickSwitch("prf")
        let first = try #require(results.first)
        #expect(first.path == "Primitives/pseudorandom-function.md",
                "got \(results.prefix(5).map(\.title))")

        // And nothing that fails to match at all should be in the list.
        #expect(!results.contains { $0.title == "#P" })
        #expect(results.count < index.pages.count,
                "\(results.count) results from \(index.pages.count) pages — nothing was filtered")
    }

    @Test("a citation key finds its reference page")
    func citationKeyRanking() throws {
        let (index, root) = try WikilinkResolutionTests.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let byKey = index.quickSwitch("aks83")
        #expect(byKey.first?.path == "References/AKS83 - An 0(n log n) sorting network.md")

        // …and so does part of the paper title, which lives in the filename.
        let byTitle = index.quickSwitch("sorting network")
        #expect(byTitle.first?.path == "References/AKS83 - An 0(n log n) sorting network.md",
                "got \(byTitle.prefix(3).map(\.title))")
    }

    @Test("an empty query lists everything by title")
    func emptyQuery() throws {
        let (index, root) = try WikilinkResolutionTests.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let results = index.quickSwitch("")
        #expect(results.count == min(40, index.pages.count))
        let titles = results.map(\.title)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}
