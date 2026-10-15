import CryptoKit
import Foundation
import Testing
@testable import CCwiki

/// `plans/curation-review.md` is current (plans/relations-followups.md §2.3,
/// §2.4). The review puts each curation entry beside the wiki text it quotes
/// and what it does to the answers. It is generated against a wiki clone at
/// the golden file's commit and committed, because CI has no such clone and
/// cannot commit; so CI checks it instead, with no clone at all.
///
/// When a test here fails, regenerate it: `make curation-review WIKI=…`, with
/// a separate clone at the golden file's `wikiCommit`, then commit the result.
struct CurationReviewTests {

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let regenerate = "regenerate it with make curation-review WIKI=<a clone at the golden file's commit>"

    private static func review() throws -> String {
        try String(contentsOf: repository.appending(path: "plans/curation-review.md"), encoding: .utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The first line's fields, which the generator writes for this test:
    /// `<!-- curation-review: curation=… manifest=… wiki=… entries=47 quotesMissing=0 -->`.
    /// `nil` when the first line is not that comment.
    private static func header(of review: String) -> [String: String]? {
        let opening = "<!-- curation-review: "
        let closing = " -->"
        guard let line = review.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              line.hasPrefix(opening), line.hasSuffix(closing)
        else { return nil }
        var fields: [String: String] = [:]
        for token in line.dropFirst(opening.count).dropLast(closing.count).split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }

    /// One entry's heading, `### 30. \`requires:red-dlog-to-prg-bm84:dlog\``.
    private struct EntryHeading: Equatable {
        let number: Int
        let id: String
    }

    private static func entryHeadings(of review: String) -> [EntryHeading] {
        var headings: [EntryHeading] = []
        for line in review.split(separator: "\n") where line.hasPrefix("### ") {
            let rest = line.dropFirst(4)
            guard let dot = rest.firstIndex(of: "."), let number = Int(rest[..<dot]) else { continue }
            let title = rest[rest.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard title.count > 2, title.hasPrefix("`"), title.hasSuffix("`") else { continue }
            headings.append(EntryHeading(number: number, id: String(title.dropFirst().dropLast())))
        }
        return headings
    }

    @Test("the review was generated from today's curation and the golden file's manifest, every quote found")
    func reviewIsCurrent() throws {
        let review = try Self.review()
        let header = try #require(Self.header(of: review), "plans/curation-review.md has lost its first line")

        let curation = try Data(contentsOf: Self.repository.appending(
            path: "Resources/\(DerivationCuration.resourceName)"))
        #expect(header["curation"] == Self.sha256(curation),
                "the curation changed after the review was generated: \(Self.regenerate)")

        // The review measures each entry on the golden file's manifest, the
        // one the curation was reviewed against.
        let goldenData = try Data(contentsOf: Self.repository.appending(
            path: "Tests/CCwikiTests/Fixtures/derivations-golden.json"))
        let golden = try #require(try JSONSerialization.jsonObject(with: goldenData) as? [String: Any])
        let manifest = try #require(golden["manifestSHA256"] as? String)
        #expect(header["manifest"] == manifest,
                "the review was generated from another relations.json than the golden file's: \(Self.regenerate)")

        // A missing quote is an entry whose wiki text has moved: re-review the
        // entry, then regenerate.
        #expect(header["quotesMissing"] == "0", "a cited quote was not on its page when the review was generated")
    }

    @Test("the review lists every entry of the curation once, in its order")
    func reviewListsEveryEntry() throws {
        let review = try Self.review()
        // The shipped file, read through #filePath as the other curation tests
        // read it; `bundled` is the same file wherever it finds one.
        let curation = try DerivationCuration.decode(Data(contentsOf: Self.repository.appending(
            path: "Resources/\(DerivationCuration.resourceName)")))
        let ids = curation.entries.map { $0.id }

        let headings = Self.entryHeadings(of: review)
        let headingIDs = headings.map { $0.id }
        #expect(headingIDs == ids, "the review's entries are not the curation's: \(Self.regenerate)")
        let numbers = headings.map { $0.number }
        #expect(numbers == (0..<headings.count).map { $0 + 1 }, "the review's entries are not numbered 1, 2, …")
        if let bundled = DerivationCuration.bundled {
            #expect(bundled.entries.map { $0.id } == headingIDs)
        }

        let header = try #require(Self.header(of: review))
        #expect(header["entries"] == String(ids.count))
    }
}
