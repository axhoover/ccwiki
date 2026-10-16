import Testing
@testable import CCwiki

/// The changed words in a changed pair of lines, for the review's Source
/// mode (plans/corrections.md §6.3, §12.1): a formula is one token, and the
/// segments put both lines back together exactly.
struct WordDiffTests {

    typealias Segment = WordDiff.Segment

    /// The old line: every segment that is not added.
    static func old(_ segments: [Segment]) -> String {
        segments.filter { $0.kind != .added }.map(\.text).joined()
    }

    /// The new line: every segment that is not removed.
    static func new(_ segments: [Segment]) -> String {
        segments.filter { $0.kind != .removed }.map(\.text).joined()
    }

    @Test("a one-word change is that word removed and added, the rest the same")
    func oneWord() {
        let segments = WordDiff.segments(
            old: "Secure against every PPT adversary.",
            new: "Secure against every efficient adversary.")
        #expect(segments == [
            Segment(kind: .same, text: "Secure against every "),
            Segment(kind: .removed, text: "PPT"),
            Segment(kind: .added, text: "efficient"),
            Segment(kind: .same, text: " adversary."),
        ])
    }

    @Test("$…$ spans stay one token, spaces and all")
    func formulaIsOneToken() {
        #expect(WordDiff.tokens("Let $x + y$ be fixed.") == ["Let", " ", "$x + y$", " ", "be", " ", "fixed."])
        #expect(WordDiff.tokens("$$a + b$$ and ($c \\cdot d$),")
            == ["$$a + b$$", " ", "and", " ", "($c \\cdot d$),"])

        let segments = WordDiff.segments(old: "Let $x + y$ be fixed.", new: "Let $x + z$ be fixed.")
        #expect(segments == [
            Segment(kind: .same, text: "Let "),
            Segment(kind: .removed, text: "$x + y$"),
            Segment(kind: .added, text: "$x + z$"),
            Segment(kind: .same, text: " be fixed."),
        ])
    }

    @Test("an escaped or unpaired dollar opens no formula")
    func literalDollars() {
        #expect(WordDiff.tokens("IND\\$-CPA costs $5 a month")
            == ["IND\\$-CPA", " ", "costs", " ", "$5", " ", "a", " ", "month"])
        // A run of two closes only at a run of two.
        #expect(WordDiff.tokens("$$x$ y$$ z") == ["$$x$ y$$", " ", "z"])
    }

    @Test("a whitespace change is seen")
    func whitespace() {
        let segments = WordDiff.segments(old: "a  b", new: "a b")
        #expect(segments == [
            Segment(kind: .same, text: "a"),
            Segment(kind: .removed, text: "  "),
            Segment(kind: .added, text: " "),
            Segment(kind: .same, text: "b"),
        ])
    }

    @Test("the segments put both lines back together exactly")
    func rebuilds() {
        let pairs = [
            ("A keyed family that $\\calA$ cannot tell from random.",
             "A keyed family that no PPT $\\calA$ can tell from a random function."),
            ("", "A new line."),
            ("An old line.", ""),
            ("Same.", "Same."),
            ("  indented  twice ", "indented once"),
            ("é and 👍 and e\u{301}", "é or 👍 or e\u{301}"),
        ]
        for (old, new) in pairs {
            let segments = WordDiff.segments(old: old, new: new)
            #expect(Self.old(segments) == old)
            #expect(Self.new(segments) == new)
            // Merged: no two neighbours of one kind.
            #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.kind != $1.kind })
        }
    }

    @Test("identical lines are one same segment; two empty lines are none")
    func identical() {
        #expect(WordDiff.segments(old: "Same line.", new: "Same line.")
            == [Segment(kind: .same, text: "Same line.")])
        #expect(WordDiff.segments(old: "", new: "").isEmpty)
    }
}
