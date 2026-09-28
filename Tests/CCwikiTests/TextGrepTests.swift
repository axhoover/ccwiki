import Foundation
import Testing
@testable import CCwiki

/// ⇧⌘F: literal, exhaustive, unranked.
struct TextGrepTests {

    static let grep = TextGrep(pages: [
        WikiPage(path: "Primitives/ot.md", text: """
            ---
            title: Oblivious transfer
            ---
            OT is not a toy. OT again.
            Empty here.
            Built from $\\classNP$ hardness? No.
            """),
        WikiPage(path: "Assumptions/ddh.md", text: """
            ---
            title: Decisional Diffie-Hellman
            ---
            Implies OT, via PKE.
            """),
        WikiPage(path: "References/Kil88 - Founding cryptography on oblivious transfer.md", text: """
            ---
            title: Kil88
            ---
            ## Abstract

            Oblivious transfer suffices.
            """),
    ])

    @Test("pages in path order, references included, every occurrence counted")
    func order() {
        let hits = Self.grep.search("OT")
        #expect(hits.map(\.path) == ["Assumptions/ddh.md", "Primitives/ot.md"])
        #expect(hits.map(\.count) == [1, 2])
        #expect(hits.map(\.lineCount) == [1, 1])
        let references = Self.grep.search("suffices")
        #expect(references.map(\.title) == ["Founding cryptography on oblivious transfer"])
    }

    @Test("smart case: a capital makes it case-sensitive")
    func smartCase() {
        // `ot` also finds "not"; `OT` does not.
        let lower = Self.grep.search("ot").first { $0.path == "Primitives/ot.md" }
        let upper = Self.grep.search("OT").first { $0.path == "Primitives/ot.md" }
        #expect(lower?.count == 3)
        #expect(upper?.count == 2)
        #expect(TextGrep.options(for: "abc") == [.caseInsensitive])
        #expect(TextGrep.options(for: "aBc") == [])
    }

    @Test("TeX is searched as written")
    func tex() {
        #expect(Self.grep.search("\\classNP").map(\.path) == ["Primitives/ot.md"])
    }

    @Test("occurrences are marked, and a long line is cut around the first")
    func excerpts() {
        let hit = Self.grep.search("OT").first { $0.path == "Primitives/ot.md" }
        #expect(hit?.excerpts == ["«OT» is not a toy. «OT» again."])

        let line = String(repeating: "a", count: 100) + " needle " + String(repeating: "b", count: 300)
        let occurrences = TextGrep.ranges(of: "needle", in: line, options: [])
        let excerpt = TextGrep.excerpt(line, around: occurrences[0], marking: occurrences)
        #expect(excerpt.hasPrefix("…"))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.contains("«needle»"))
        #expect(excerpt.count < line.count)
    }

    @Test("too short, or several lines, finds nothing")
    func limits() {
        #expect(Self.grep.search("O").isEmpty)
        #expect(Self.grep.search("  ").isEmpty)
        #expect(Self.grep.search("OT\nagain").isEmpty)
    }

    @Test("guillemets in the text cannot fake a match marker")
    func markersEscaped() {
        let grep = TextGrep(pages: [
            WikiPage(path: "x.md", text: "---\ntitle: X\n---\nsay «hello» world\n"),
        ])
        #expect(grep.search("world").first?.excerpts == ["say \"hello\" «world»"])
    }
}
