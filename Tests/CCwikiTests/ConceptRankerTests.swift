import Foundation
import Testing
@testable import CCwiki

/// ⌘S's ordering rules, on hand-made pages: which field matched, then the
/// section, then BM25 (plans/search-v2.md §6.1).
struct ConceptRankerTests {

    static func page(_ path: String, title: String, aliases: [String] = [], body: String = "")
        -> WikiPage {
        let aliasLines = aliases.isEmpty ? "" : "aliases:\n" + aliases.map { "  - \($0)\n" }.joined()
        return WikiPage(path: path, text: "---\ntitle: \(title)\n\(aliasLines)---\n\(body)")
    }

    static func paths(_ ranked: [ConceptRanker.Ranked]) -> [String] { ranked.map(\.entry.path) }

    @Test("a name match outranks any amount of text, whatever BM25 says")
    func nameBeatsText() {
        let ranker = ConceptRanker(pages: [
            Self.page("Assumptions/learning-with-errors.md", title: "Learning with errors",
                      aliases: ["LWE"]),
            Self.page("Reductions/lwe-to-pke.md", title: "LWE-based encryption",
                      body: "LWE LWE LWE"),
            Self.page("Primitives/fhe.md", title: "Fully homomorphic encryption",
                      body: "from LWE"),
        ])
        // BM25 as FTS5 gives it, lower better: the reduction is the "best" text.
        let ranked = ranker.rank("LWE", textScores: [
            "Reductions/lwe-to-pke.md": -9, "Primitives/fhe.md": -2,
            "Assumptions/learning-with-errors.md": -1,
        ])
        #expect(Self.paths(ranked) == [
            "Assumptions/learning-with-errors.md",  // exact alias
            "Reductions/lwe-to-pke.md",             // prefix of a reduction's name
            "Primitives/fhe.md",                    // text only
        ])
    }

    @Test("match quality: exact, then folded, then prefix, then every word")
    func matchQuality() {
        func match(_ query: String, _ name: String) -> ConceptRanker.Match? {
            ConceptRanker.match(ConceptRanker.Name(query), ConceptRanker.Name(name))
        }
        #expect(match("#P", "#P") == .exact)
        #expect(match("#p", "#P") == .exact)
        #expect(match("#P", "P") == .folded)
        #expect(match("one way function", "One-way function") == .folded)
        #expect(match("vigenere", "Vigenère cipher") == .prefix)
        #expect(match("one-wa", "One-way function") == .prefix)
        #expect(match("function one", "One-way function") == .allWords)
        #expect(match("commitments", "Commitment scheme") == .allWords)
        #expect(match("hashes", "Hash function") == .allWords)
        #expect(match("lattice", "Learning with errors") == nil)
        #expect(match("  ", "anything") == nil)
    }

    @Test("a partial match on a concept outranks one on a reduction; then the section decides")
    func sectionPriority() {
        let ranker = ConceptRanker(pages: [
            Self.page("Reductions/zk-x.md", title: "Zero knowledge from X"),
            Self.page("Complexity/szk.md", title: "Statistical zero knowledge"),
            Self.page("Glossary/zk-glossary.md", title: "Zero knowledge simulator"),
            Self.page("Primitives/zkp.md", title: "Zero-knowledge proof"),
        ])
        // Every title matches in part, so BM25 (which here prefers the
        // reverse order) never gets a say.
        let ranked = ranker.rank("zero knowledge", textScores: [
            "Reductions/zk-x.md": -4, "Complexity/szk.md": -3,
            "Glossary/zk-glossary.md": -2, "Primitives/zkp.md": -1,
        ])
        // Concept pages before the reduction; among them, a prefix before
        // every-word; among the prefixes, the primitive before the glossary.
        #expect(Self.paths(ranked) == [
            "Primitives/zkp.md", "Glossary/zk-glossary.md",
            "Complexity/szk.md", "Reductions/zk-x.md",
        ])
    }

    @Test("a heading match opens at the heading, and outranks a reduction's name")
    func headingLanding() {
        let ranker = ConceptRanker(pages: [
            Self.page("Assumptions/learning-with-errors.md", title: "Learning with errors",
                      body: "# Variations\n\n## Ring-LWE\n\ntext\n"),
            Self.page("Reductions/ring-lwe-to-ntru.md", title: "Ring-LWE to NTRU"),
        ])
        let ranked = ranker.rank("ring lwe", textScores: [:])
        #expect(Self.paths(ranked) == [
            "Assumptions/learning-with-errors.md", "Reductions/ring-lwe-to-ntru.md",
        ])
        #expect(ranked.first?.section?.id == "ring-lwe")
        #expect(ranked.first?.section?.name.text == "Ring-LWE")
        #expect(ranked.last?.section == nil)
    }

    @Test("the page's own name beats one of its headings, and lands at the top")
    func nameBeatsOwnHeading() {
        let ranker = ConceptRanker(pages: [
            Self.page("Primitives/prf.md", title: "Pseudorandom function", aliases: ["PRF"],
                      body: "## PRF\n\ntext\n"),
        ])
        let ranked = ranker.rank("PRF", textScores: [:])
        #expect(ranked.first?.field == .name)
        #expect(ranked.first?.section == nil)
    }

    @Test("a heading on many pages is the template, not a name")
    func structuralHeadings() {
        let pages = (1...ConceptRanker.structuralHeadingPages).map {
            Self.page("Primitives/p\($0).md", title: "Primitive \($0)",
                      body: "## Participates in\n\ntext\n")
        }
        let ranker = ConceptRanker(pages: pages)
        #expect(ranker.entries.allSatisfy(\.headings.isEmpty))
        // Found through the text, if at all, never as a section.
        let ranked = ranker.rank("participates in", textScores: ["Primitives/p1.md": -1])
        #expect(ranked.map(\.match) == [.text])
    }

    @Test("references are not concept search's to show")
    func referencesExcluded() {
        let ranker = ConceptRanker(pages: [
            Self.page("References/GGM86 - How to construct random functions.md", title: "GGM86"),
            Self.page("Primitives/prf.md", title: "Pseudorandom function"),
        ])
        #expect(ranker.entries.map(\.path) == ["Primitives/prf.md"])
        #expect(ranker.rank("GGM86", textScores: [:]).isEmpty)
    }

    @Test("a page only the text matched sorts after every name match, by BM25")
    func textOnlyOrder() {
        let ranker = ConceptRanker(pages: [
            Self.page("Reductions/a.md", title: "A"),
            Self.page("Primitives/b.md", title: "B"),
            Self.page("Primitives/c.md", title: "C"),
        ])
        let ranked = ranker.rank("xyz", textScores: [
            "Reductions/a.md": -5, "Primitives/b.md": -1, "Primitives/c.md": -3,
        ])
        // All text-only: section first, then BM25.
        #expect(Self.paths(ranked) == ["Primitives/c.md", "Primitives/b.md", "Reductions/a.md"])
    }

    @Test("folding: case, accents, width and punctuation")
    func folding() {
        #expect(ConceptRanker.fold("Vigenère") == "vigenere")
        #expect(ConceptRanker.fold("One-way  function") == "one way function")
        #expect(ConceptRanker.fold("P/poly") == "p poly")
        #expect(ConceptRanker.fold("  --  ") == "")
        #expect(ConceptRanker.collapse("  Ring   LWE ") == "ring lwe")
    }
}
