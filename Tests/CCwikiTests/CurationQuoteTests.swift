import Foundation
import Testing
@testable import CCwiki

/// The quote-matching rule of plans/relations-followups.md §2.2, and the app's
/// check of every curation citation against the clone's pages.
///
/// The cases are shared: `Fixtures/quote-cases.json` holds every case the
/// rule must pass, and the reference engine's `locate_quote` runs the same
/// file in `make check` (`--selftest-units`). So the two matchers agree by
/// construction, not by inspection. A new case goes in the file, never here.
struct CurationQuoteTests {

    private struct Case: Decodable {
        let name: String
        let page: String
        let section: String?
        let quote: String
        let found: Bool
    }

    private struct Cases: Decodable {
        let cases: [Case]
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/quote-cases.json")
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url)).cases
    }

    @Test("every shared case, as the reference engine's locate_quote answers it")
    func sharedCases() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 10)
        for testCase in cases {
            let found = CurationQuote.contains(testCase.quote, section: testCase.section, in: testCase.page)
            #expect(found == testCase.found, "\(testCase.name)")
        }
    }

    // MARK: The app's check

    /// One reduction page and the entries citing it: one quote on the page,
    /// one in the wrong section, and one on a page the clone does not have.
    private static func curation() -> DerivationCuration {
        let page = "content/Reductions/dlog-to-prg-bm84.md"
        let onPage = DerivationCuration.Citation(
            page: page, section: "Statement",
            quote: "If [[discrete-logarithm|DLOG]] is hard in $\\ZZ_p^*$")
        let elsewhere = DerivationCuration.Citation(
            page: page, section: "Notes", quote: "If [[discrete-logarithm|DLOG]] is hard")
        let gone = DerivationCuration.Citation(
            page: "content/Primitives/gone.md", section: nil, quote: "anything")
        let requirement = DerivationCuration.Requirement(
            relationID: "red-dlog-to-prg-bm84", isReverse: false, hypothesis: "dlog",
            notion: "DLOG hard in Z_p^*", metBy: [])
        return DerivationCuration(
            settings: [.init(objectID: "hm", text: "A setting.", evidence: "")],
            requires: [requirement],
            citations: [
                .requirement(relationID: "red-dlog-to-prg-bm84", isReverse: false, hypothesis: "dlog"):
                    [onPage, elsewhere],
                .setting(objectID: "hm"): [gone],
            ])
    }

    @Test("missingQuotes names each citation not on its page, an unreadable page included")
    func missingQuotes() {
        let derivation = Derivation(manifest: .empty, curation: Self.curation())
        var reads: [String] = []
        let missing = derivation.missingQuotes { path in
            reads.append(path)
            guard path == "Reductions/dlog-to-prg-bm84.md" else { return nil }
            return "---\ntitle: DLOG ⇒ PRG\n---\n\n## Statement\r\n\r\n"
                + "If [[discrete-logarithm|DLOG]] is hard in\r\n$\\ZZ_p^*$ ($p$ prime), a PRG exists.\r\n"
                + "\r\n## Notes\r\n\r\nNone.\r\n"
        }
        let described = missing.map { "\($0.entryID) \($0.citation.contentPath) \($0.citation.section ?? "-")" }
        // In the curation's order: the setting first, then the requirement.
        #expect(described == ["settings:hm Primitives/gone.md -",
                              "requires:red-dlog-to-prg-bm84:dlog Reductions/dlog-to-prg-bm84.md Notes"])
        // Each page is read once, however many citations it carries.
        #expect(reads.sorted() == ["Primitives/gone.md", "Reductions/dlog-to-prg-bm84.md"])
    }

    @Test("the app's check finds every quote on pages that still say what was quoted")
    func everyQuoteFound() {
        let derivation = Derivation(manifest: .empty, curation: Self.curation())
        let missing = derivation.missingQuotes { path in
            switch path {
            case "Reductions/dlog-to-prg-bm84.md":
                return "## Statement\n\nIf [[discrete-logarithm|DLOG]] is hard in $\\ZZ_p^*$, so is…\n\n"
                    + "## Notes\n\nIf [[discrete-logarithm|DLOG]] is hard, see above.\n"
            case "Primitives/gone.md":
                // `section: null` quotes the frontmatter too.
                return "---\nsummary: anything at all\n---\n"
            default:
                return nil
            }
        }
        #expect(missing.isEmpty, "\(missing)")
    }
}
