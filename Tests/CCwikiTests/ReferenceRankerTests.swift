import Foundation
import Testing
@testable import CCwiki

/// ⇧⌘R's ordering: key, authors, title, all three, cited by, text.
struct ReferenceRankerTests {

    static func reference(
        _ key: String, _ title: String, authors: String, venue: String = "", year: String = "",
        cryptobib: String? = nil
    ) -> WikiPage {
        var front = "title: \(key)\naliases:\n  - \(key)\nauthors: \(authors)\n"
        if !venue.isEmpty { front += "venue: \(venue)\n" }
        if !year.isEmpty { front += "published: \(year)\n" }
        if let cryptobib { front += "cryptobib_key: \(cryptobib)\n" }
        return WikiPage(
            path: "References/\(key) - \(title).md",
            text: "---\ntype: reference\n\(front)---\n\n## Abstract\n\nAbout \(title.lowercased()).\n")
    }

    static let ggm = reference(
        "GGM86", "How to Construct Random Functions",
        authors: "Oded Goldreich, Shafi Goldwasser, and Silvio Micali",
        venue: "J. ACM", year: "1986", cryptobib: "JACM:GolGolMic86")
    static let reg = reference(
        "Reg05", "On Lattices, Learning with Errors, Random Linear Codes, and Cryptography",
        authors: "Oded Regev", venue: "STOC", year: "2005-05-22")
    static let dot = reference(
        "DGI+19", "Trapdoor Hash Functions and Their Applications",
        authors: "Nico Döttling, Sanjam Garg, Yuval Ishai", venue: "CRYPTO", year: "2019")
    static let prf = WikiPage(
        path: "Primitives/pseudorandom-function.md",
        text: "---\ntitle: Pseudorandom function\naliases:\n  - PRF\n---\n\nSee [[GGM86]].\n")

    static func ranker() -> ReferenceRanker {
        ReferenceRanker(
            pages: [ggm, reg, dot, prf],
            backlinks: [ggm.path: [WikiIndex.Backlink(sourcePath: prf.path, context: "See GGM86.")]])
    }

    static func keys(_ ranked: [ReferenceRanker.Ranked]) -> [String] { ranked.map(\.entry.key) }

    @Test("the frontmatter is read into a bibliography entry")
    func entries() throws {
        let ranker = Self.ranker()
        #expect(ranker.entries.count == 3, "the concept page is not a reference")
        let ggmEntry = ranker.entries.first { $0.key == "GGM86" }
        let ggm = try #require(ggmEntry)
        #expect(ggm.title == "How to Construct Random Functions")
        #expect(ggm.year == 1986)
        #expect(ggm.venue == "J. ACM")
        #expect(ggm.citers.map(\.title) == ["Pseudorandom function"])
        let regEntry = ranker.entries.first { $0.key == "Reg05" }
        let reg = try #require(regEntry)
        #expect(reg.year == 2005)
    }

    @Test("author lists split on commas and a final and")
    func authorNames() {
        #expect(ReferenceRanker.authorNames("Oded Goldreich, Shafi Goldwasser, and Silvio Micali")
            == ["Oded Goldreich", "Shafi Goldwasser", "Silvio Micali"])
        #expect(ReferenceRanker.authorNames("Moni Naor and Omer Reingold")
            == ["Moni Naor", "Omer Reingold"])
        #expect(ReferenceRanker.authorNames("Oded Regev") == ["Oded Regev"])
        #expect(ReferenceRanker.authorNames("") == [])
    }

    @Test("a four-digit year is a filter; other numbers are words")
    func parse() {
        #expect(ReferenceRanker.parse("regev 2005").text == "regev")
        #expect(ReferenceRanker.parse("regev 2005").years == [2005])
        #expect(ReferenceRanker.parse("GGM86").years.isEmpty)
        #expect(ReferenceRanker.parse("NC 1").text == "NC 1")
        #expect(ReferenceRanker.parse("1234").years.isEmpty)
        #expect(ReferenceRanker.year("2005-05-22") == 2005)
        #expect(ReferenceRanker.year("n.d.") == nil)
    }

    @Test("a citation key, or its cryptobib key, or the start of one")
    func key() {
        let ranker = Self.ranker()
        #expect(Self.keys(ranker.rank("GGM86", textScores: [:])) == ["GGM86"])
        #expect(Self.keys(ranker.rank("ggm", textScores: [:])).first == "GGM86")
        #expect(Self.keys(ranker.rank("JACM:GolGolMic86", textScores: [:])) == ["GGM86"])
        #expect(ranker.rank("DGI+19", textScores: [:]).first?.field == .key)
    }

    @Test("authors match by name, with accents folded, before titles")
    func authors() {
        let ranker = Self.ranker()
        // "Oded" is an author of two papers; "regev" narrows it to one.
        #expect(Set(Self.keys(ranker.rank("oded", textScores: [:]))) == ["GGM86", "Reg05"])
        #expect(Self.keys(ranker.rank("oded regev", textScores: [:])) == ["Reg05"])
        #expect(Self.keys(ranker.rank("Dottling", textScores: [:])) == ["DGI+19"])
        #expect(ranker.rank("goldreich micali", textScores: [:]).first?.field == .author)
    }

    @Test("a year narrows, and alone lists the year")
    func years() {
        let ranker = Self.ranker()
        #expect(Self.keys(ranker.rank("oded 2005", textScores: [:])) == ["Reg05"])
        #expect(Self.keys(ranker.rank("1986", textScores: [:])) == ["GGM86"])
        #expect(ranker.rank("oded 1999", textScores: [:]).isEmpty)
    }

    @Test("title, then authors and title together")
    func titleAndMixed() {
        let ranker = Self.ranker()
        let byTitle = ranker.rank("random functions", textScores: [:])
        #expect(Self.keys(byTitle) == ["GGM86"])
        #expect(byTitle.first?.field == .title)
        let mixed = ranker.rank("goldreich random", textScores: [:])
        #expect(Self.keys(mixed) == ["GGM86"])
        #expect(mixed.first?.field == .mixed)
    }

    @Test("a concept page's name finds the papers it cites")
    func citedBy() {
        let ranked = Self.ranker().rank("PRF", textScores: [:])
        #expect(Self.keys(ranked) == ["GGM86"])
        #expect(ranked.first?.field == .citedBy)
        #expect(ranked.first?.citer?.title == "Pseudorandom function")
    }

    @Test("the text comes last, and only what it matched")
    func text() {
        let ranker = Self.ranker()
        let ranked = ranker.rank("errors", textScores: [
            Self.dot.path: -3, Self.reg.path: -1,
        ])
        // Reg05's title has the word; DGI+19 only the text.
        #expect(Self.keys(ranked) == ["Reg05", "DGI+19"])
        #expect(ranked.map(\.field) == [.title, .text])
    }
}
