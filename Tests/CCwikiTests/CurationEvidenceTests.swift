import Foundation
import Testing
@testable import CCwiki

/// The curation's evidence (plans/relations-followups.md §2.2, §6.1): each
/// entry's citations of the wiki, its id, and the one order the review
/// document, the app and the asks all list entries in.
///
/// The checks on the shipped file are all-or-nothing on citations. They pass
/// on a file with none, and bind once any entry is cited: from then on every
/// entry must be.
struct CurationEvidenceTests {

    // MARK: Decoding

    @Test("citations, the notions for the copies and the reviewed commit decode")
    func evidenceDecodes() throws {
        let json = #"""
            { "reviewedAgainst": { "wikiCommit": "ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157",
                                   "manifestSHA256": "b0c3fb65" },
              "refuted": [{ "object": "fake", "source": "XY99", "text": "Fake is false (XY99).",
                            "evidence": "The attack, on the assumption's page.",
                            "cites": [{ "page": "content/Assumptions/fake.md", "section": null,
                                        "quote": "security-loss: none" }] }],
              "settings": [{ "object": "hm", "text": "A setting.", "evidence": "The MPC page.",
                             "cites": [{ "page": "content/Primitives/mpc.md",
                                         "quote": "exists unconditionally" }] }],
              "quarantine": [{ "edge": "red-e-to-f", "reason": "The Statement has a second hypothesis.",
                               "evidence": "the key before citations, ignored",
                               "cites": [{ "page": "content/Reductions/e-to-f.md", "section": "Statement",
                                           "quote": "assume [[e]] and [[lwe|LWE]]" }] }],
              "equivalences": { "red-x-eq-y": { "forward": "record", "note": "One way is folklore.",
                                                "cites": [{ "page": "content/Reductions/x-eq-y.md",
                                                            "section": "Proof", "quote": "is immediate" }] } },
              "requires": [{ "edge": "red-g-to-h", "direction": "reverse", "hypothesis": "h",
                             "notion": "h hard in Z_p^*", "notionMarkdown": "h hard in $\\ZZ_p^*$",
                             "metBy": ["red-m-to-h"], "evidence": "Statement: 'hard in Z_p^*'",
                             "cites": [{ "page": "content/Reductions/g-to-h.md", "section": "Statement",
                                         "quote": "If [[h]] is hard in $\\ZZ_p^*$" },
                                       { "page": "content/Assumptions/h.md", "section": "Malicious Security",
                                         "quote": "The definitions above are **semi-honest**" }] }],
              "weakens": [{ "edge": "red-s-to-w", "notion": "selective w only",
                            "notionMarkdown": "selective $w$ only", "evidence": "Statement: 'selectively'",
                            "cites": [{ "page": "content/Reductions/s-to-w.md", "section": "Statement",
                                        "quote": "that is selectively secure" }] }] }
            """#
        let curation = try DerivationCuration.decode(Data(json.utf8))

        #expect(curation.reviewedCommit == "ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157")
        // The chrome keeps `notion`; the copies read `notionMarkdown`.
        let requirement = try #require(curation.requires.first)
        #expect(requirement.notion == "h hard in Z_p^*")
        #expect(requirement.notionMarkdown == "h hard in $\\ZZ_p^*$")
        let weakening = try #require(curation.weakens["red-s-to-w"])
        #expect(weakening.notionMarkdown == "selective $w$ only")

        let required = try #require(curation.entry(
            .requirement(relationID: "red-g-to-h", isReverse: true, hypothesis: "h")))
        #expect(required.id == "requires:red-g-to-h~reverse:h")
        #expect(required.evidence == "Statement: 'hard in Z_p^*'")
        let quotes = required.cites.map { $0.quote }
        #expect(quotes == ["If [[h]] is hard in $\\ZZ_p^*$", "The definitions above are **semi-honest**"])
        let first = try #require(required.cites.first)
        #expect(first.page == "content/Reductions/g-to-h.md")
        #expect(first.section == "Statement")
        #expect(first.contentPath == "Reductions/g-to-h.md")

        // `section: null` and no `section` both mean the whole file.
        let wholeFile = try #require(curation.entry(.refuted(objectID: "fake"))?.cites.first)
        #expect(wholeFile.section == nil)
        let noSection = try #require(curation.entry(.setting(objectID: "hm"))?.cites.first)
        #expect(noSection.section == nil)

        // Each entry's prose is whatever its table calls it: evidence, a
        // quarantine's reason, an equivalence's note.
        let prose = curation.entries.map { $0.evidence }
        #expect(prose == ["The attack, on the assumption's page.", "The MPC page.",
                          "The Statement has a second hypothesis.", "One way is folklore.",
                          "Statement: 'hard in Z_p^*'", "Statement: 'selectively'"])
        let citationCounts = curation.entries.map { $0.cites.count }
        #expect(citationCounts == [1, 1, 1, 1, 2, 1])
    }

    @Test("a file from before citations still decodes, its entries uncited")
    func uncitedFileDecodes() throws {
        let json = #"""
            { "refuted": [{ "object": "fake", "source": "XY99", "text": "Fake is false (XY99)." }],
              "quarantine": [{ "edge": "red-e-to-f", "reason": "The Statement has a second hypothesis.",
                               "evidence": "content/Reductions/e-to-f.md § Statement" }],
              "equivalences": { "red-x-eq-y": { "forward": "record", "reverse": "record" } },
              "requires": [{ "edge": "red-g-to-h", "hypothesis": "g", "notion": "g in its strong regime" }],
              "weakens": [{ "edge": "red-s-to-w", "notion": "selective w only" }],
              "statementLint": { "red-a-to-b": "Reviewed: named as an example, not a hypothesis." } }
            """#
        let curation = try DerivationCuration.decode(Data(json.utf8))

        #expect(curation.reviewedCommit == nil)
        let requirement = try #require(curation.requires.first)
        #expect(requirement.notionMarkdown == nil)
        let weakening = try #require(curation.weakens["red-s-to-w"])
        #expect(weakening.notionMarkdown == nil)

        let ids = curation.entries.map { $0.id }
        #expect(ids == ["refuted:fake", "quarantine:red-e-to-f", "equivalences:red-x-eq-y",
                        "requires:red-g-to-h:g", "statementLint:red-a-to-b", "weakens:red-s-to-w"])
        let uncited = curation.entries.allSatisfy { $0.cites.isEmpty }
        #expect(uncited)
        let prose = curation.entries.map { $0.evidence }
        #expect(prose == ["", "The Statement has a second hypothesis.", "", "",
                          "Reviewed: named as an example, not a hypothesis.", ""])
    }

    @Test("a Statement-lint note decodes bare and as {note, cites}")
    func statementLintForms() throws {
        let json = #"""
            { "statementLint": {
                "red-bare": "Reviewed: DDH is named as an example.",
                "red-cited": { "note": "Reviewed: the family it belongs to, not a second hypothesis.",
                               "cites": [{ "page": "content/Reductions/cited.md", "section": "Statement",
                                           "quote": "the family [[evasive-lwe]] belongs to" }] } } }
            """#
        let curation = try DerivationCuration.decode(Data(json.utf8))

        // The table holds the note either way, so the lint reads it unchanged.
        #expect(curation.statementLint == [
            "red-bare": "Reviewed: DDH is named as an example.",
            "red-cited": "Reviewed: the family it belongs to, not a second hypothesis.",
        ])
        let ids = curation.entries.map { $0.id }
        #expect(ids == ["statementLint:red-bare", "statementLint:red-cited"])
        let bare = try #require(curation.entry(.statementLint(relationID: "red-bare")))
        #expect(bare.cites.isEmpty)
        let cited = try #require(curation.entry(.statementLint(relationID: "red-cited")))
        #expect(cited.evidence == "Reviewed: the family it belongs to, not a second hypothesis.")
        let pages = cited.cites.map { $0.page }
        #expect(pages == ["content/Reductions/cited.md"])
    }

    // MARK: Ids and order

    @Test("entry ids and their order follow §2.2: the arrays as given, the tables by id in byte order")
    func idsAndOrder() throws {
        let citation = DerivationCuration.Citation(
            page: "content/Reductions/z-to-a.md", section: "Statement", quote: "If [[z]] is hard")
        let curation = DerivationCuration(
            refuted: [.init(objectID: "zeta", source: "Z1", text: "Zeta is false.", evidence: "Z1's attack."),
                      .init(objectID: "alpha", source: "A1", text: "Alpha is false.", evidence: "")],
            settings: [.init(objectID: "hm", text: "A setting.", evidence: "")],
            quarantine: ["red-q9": "Ninth.", "red-q10": "Tenth."],
            equivalences: ["red-e2": .init(forward: "record", reverse: "record"),
                           "red-e1": .init(forward: "record", reverse: "unstated")],
            requires: [
                .init(relationID: "red-z-to-a", isReverse: false, hypothesis: "z",
                      notion: "z, strongly", metBy: []),
                .init(relationID: "red-e1", isReverse: true, hypothesis: "e",
                      notion: "e, strongly", metBy: []),
                .init(relationID: "red-b-and-c-to-d", isReverse: false, hypothesis: "c",
                      notion: "c, strongly", metBy: [], notionMarkdown: "$c$, strongly"),
            ],
            weakens: [.init(relationID: "red-w2", notion: "w only", acceptedBy: []),
                      .init(relationID: "red-w1", notion: "w only", acceptedBy: [])],
            statementLint: ["red-l2": "Reviewed.", "red-l1": "Reviewed."],
            citations: [.requirement(relationID: "red-z-to-a", isReverse: false, hypothesis: "z"): [citation]],
            evidence: [.equivalence(relationID: "red-e1"): "One way only."],
            reviewedCommit: "ab81f02")

        let ids = curation.entries.map { $0.id }
        #expect(ids == [
            "refuted:zeta", "refuted:alpha",
            "settings:hm",
            // Byte order, not numeric: "1" sorts before "9".
            "quarantine:red-q10", "quarantine:red-q9",
            "equivalences:red-e1", "equivalences:red-e2",
            "requires:red-z-to-a:z", "requires:red-e1~reverse:e", "requires:red-b-and-c-to-d:c",
            "statementLint:red-l1", "statementLint:red-l2",
            "weakens:red-w2", "weakens:red-w1",
        ])

        let required = try #require(curation.entry(
            .requirement(relationID: "red-z-to-a", isReverse: false, hypothesis: "z")))
        #expect(required.cites == [citation])
        #expect(required.cites.first?.contentPath == "Reductions/z-to-a.md")
        #expect(curation.entry(.equivalence(relationID: "red-e1"))?.evidence == "One way only.")
        #expect(curation.entry(.refuted(objectID: "zeta"))?.evidence == "Z1's attack.")
        #expect(curation.entry(.quarantine(relationID: "red-q9"))?.evidence == "Ninth.")
        #expect(curation.entry(.statementLint(relationID: "red-l1"))?.evidence == "Reviewed.")
        // The other direction of the same step is another entry, here none.
        #expect(curation.entry(.requirement(relationID: "red-e1", isReverse: false, hypothesis: "e")) == nil)
        #expect(curation.requires.last?.notionMarkdown == "$c$, strongly")
        #expect(curation.reviewedCommit == "ab81f02")
    }

    @Test("a key given twice is one entry, in its first place, with its last content")
    func repeatedKey() throws {
        let curation = DerivationCuration(
            refuted: [.init(objectID: "a", source: "A1", text: "A is false.", evidence: "first"),
                      .init(objectID: "b", source: "B1", text: "B is false.", evidence: "b"),
                      .init(objectID: "a", source: "A2", text: "A is false.", evidence: "last")])

        let ids = curation.entries.map { $0.id }
        #expect(ids == ["refuted:a", "refuted:b"])
        #expect(curation.entry(.refuted(objectID: "a"))?.evidence == "last")
        #expect(curation.refuted["a"]?.source == "A2")
    }

    // MARK: Manifest refutations

    @Test("a merged refutation replaces the file's for its object and adds no entry")
    func mergedRefutation() throws {
        let citation = DerivationCuration.Citation(
            page: "content/Assumptions/supersingular-isogeny-diffie-hellman.md", section: nil,
            quote: "is broken")
        let fromFile = DerivationCuration.Refutation(
            objectID: "sidh", source: "CD22", text: "SIDH is false (CD22).", evidence: "the file's")
        let curation = DerivationCuration(
            refuted: [fromFile], citations: [.refuted(objectID: "sidh"): [citation]],
            reviewedCommit: "ab81f02")
        let recorded = DerivationCuration.Refutation(
            objectID: "sidh", source: "CD22", text: "Its page records the attack.",
            evidence: "[[CD22 - An efficient key recovery attack on SIDH|CD22]]")
        let added = DerivationCuration.Refutation(
            objectID: "ssddh", source: "CD22", text: "Its page records the attack.",
            evidence: "[[CD22 - An efficient key recovery attack on SIDH|CD22]]")

        let merged = curation.adding(refutations: [recorded, added])

        #expect(merged.refuted["sidh"] == recorded)
        #expect(merged.refuted["ssddh"] == added)
        #expect(curation.refuted["sidh"] == fromFile)
        #expect(curation.refuted["ssddh"] == nil)
        // The manifest's record is the wiki's own, not a curation entry.
        #expect(merged.entries == curation.entries)
        let ids = merged.entries.map { $0.id }
        #expect(ids == ["refuted:sidh"])
        #expect(merged.entry(.refuted(objectID: "sidh"))?.evidence == "the file's")
        #expect(merged.entry(.refuted(objectID: "ssddh")) == nil)
        #expect(merged.reviewedCommit == "ab81f02")
    }

    // MARK: The shipped file

    private static func shippedData() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appending(path: "Resources/\(DerivationCuration.resourceName)"))
    }

    @Test("the shipped file has 42 entries, each id once, in §2.2's order")
    func shippedOrder() throws {
        let data = try Self.shippedData()
        let curation = try DerivationCuration.decode(data)
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // §2.2's order, read off the raw file rather than the decoder: the
        // arrays as written, the tables by edge id in UTF-8 byte order.
        func array(_ key: String) -> [[String: Any]] { file[key] as? [[String: Any]] ?? [] }
        func string(_ entry: [String: Any], _ key: String) -> String { entry[key] as? String ?? "" }
        func byteOrder(_ ids: [String]) -> [String] {
            ids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        func tableKeys(_ key: String) -> [String] {
            byteOrder(Array((file[key] as? [String: Any] ?? [:]).keys))
        }
        var expected: [String] = []
        for entry in array("refuted") { expected.append("refuted:\(string(entry, "object"))") }
        for entry in array("settings") { expected.append("settings:\(string(entry, "object"))") }
        for edge in byteOrder(array("quarantine").map { string($0, "edge") }) {
            expected.append("quarantine:\(edge)")
        }
        for edge in tableKeys("equivalences") { expected.append("equivalences:\(edge)") }
        for entry in array("requires") {
            let direction = string(entry, "direction") == "reverse" ? "~reverse" : ""
            expected.append("requires:\(string(entry, "edge"))\(direction):\(string(entry, "hypothesis"))")
        }
        for edge in tableKeys("statementLint") { expected.append("statementLint:\(edge)") }
        for entry in array("weakens") { expected.append("weakens:\(string(entry, "edge"))") }

        let ids = curation.entries.map { $0.id }
        #expect(ids == expected)
        #expect(ids.count == 42)
        #expect(Set(ids).count == ids.count, "an id appears twice")
        #expect(ids.first == "refuted:circular-evasive-lwe")
        #expect(ids.contains("requires:red-dlog-to-prg-bm84:dlog"))
        #expect(ids.contains("requires:red-ot-to-mpc-kil88:ot"))
        #expect(ids.last == "weakens:red-prp-to-invertible-prf")
        for entry in curation.entries {
            #expect(curation.entry(entry.key) == entry, "\(entry.id)")
        }
    }

    @Test("the shipped citations are all or nothing, and each quotes a page's source")
    func shippedCitations() throws {
        let curation = try DerivationCuration.decode(try Self.shippedData())

        // Track A1 cites all 42 entries together, so once one is cited, an
        // uncited entry is one the review missed.
        let isCited = curation.entries.contains { !$0.cites.isEmpty }
        if isCited {
            let uncited = curation.entries.filter { $0.cites.isEmpty }.map { $0.id }
            #expect(uncited.isEmpty, "entries without a citation: \(uncited)")
        }
        for entry in curation.entries {
            for citation in entry.cites {
                let isPage = citation.page.hasPrefix("content/") && citation.page.hasSuffix(".md")
                #expect(isPage, "\(entry.id): \(citation.page)")
                // Quotes are verbatim and contiguous: two passages are two quotes.
                #expect(!citation.quote.contains("…"), "\(entry.id): an ellipsis in \(citation.quote)")
                // An empty quote would be found on any page.
                let isEmpty = citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                #expect(!isEmpty, "\(entry.id): an empty quote")
            }
        }

        // The LaTeX writer only escapes text and expands math, so a notion
        // for the copies carries no wikilinks, links or emphasis.
        let notions = curation.requires.compactMap { $0.notionMarkdown }
            + curation.weakens.values.compactMap { $0.notionMarkdown }
        for notion in notions {
            for markup in ["[[", "](", "**"] {
                #expect(!notion.contains(markup), "notionMarkdown \(notion) contains \(markup)")
            }
        }
    }
}
