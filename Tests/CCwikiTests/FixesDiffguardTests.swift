import Foundation
import Testing
@testable import CCwiki

/// DiffGuard's second round of fixes: what a regenerated `relations.json`
/// still leaves stale, regions laid out otherwise than the generator writes
/// them, regions removed from pages the generator still relates, frontmatter
/// read as js-yaml reads it, and math in wikilinks counted as the lint
/// counts it. Every expectation that names the wiki's scripts follows them
/// at the wiki's `ab81f02`.
@Suite("DiffGuard fixes")
struct FixesDiffguardTests {

    // MARK: relations.json as the generator writes it

    static let relationsPath = ".reductions/relations.json"
    static let reductionPath = "content/Reductions/owf-to-prg-hill99.md"

    /// A `relations.json` with the arrays DiffGuard reads.
    static func manifest(
        objects: [[String: Any]] = [], reductions: [[String: Any]] = [], barriers: [[String: Any]] = []
    ) throws -> String {
        let root: [String: Any] = [
            "version": 1, "objects": objects, "reductions": reductions, "barriers": barriers,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// `relations.json` changed, from no records to `new`.
    static func relations(_ new: String) throws -> ChangedFile {
        DiffGuardTests.modified(relationsPath, old: try manifest(), new: new)
    }

    /// The record generate-relations.mjs (152–172) writes for
    /// `DiffGuardTests.reduction`, which has no title, status or rationale.
    static func reductionRecord(class reductionClass: String = "fully-black-box") -> [String: Any] {
        [
            "id": "red-owf-to-prg-hill99", "kind": "construction", "hypotheses": ["owf"],
            "conclusion": "prg", "class": reductionClass, "model": "standard",
            "source": ["[[HILL99]]"], "via": [String](), "heuristic": false, "securityLoss": "",
            "page": reductionPath, "slug": "owf-to-prg-hill99", "graphSlug": "Reductions/owf-to-prg-hill99",
        ]
    }

    /// The records of the fixture `pseudorandom-function.md`, as the wiki's
    /// `relations.json` holds them at `ab81f02`.
    static func prfRecords(title: String = "Pseudorandom function", weakTitle: String = "Weak PRFs")
        -> [[String: Any]] {
        let page = DiffGuardTests.pagePath
        let common: [String: Any] = [
            "type": "primitive", "page": page, "slug": "pseudorandom-function",
            "graphSlug": "Primitives/pseudorandom-function", "unlisted": false,
        ]
        return [
            common.merging([
                "id": "prf", "kind": "object", "title": title,
                "aliases": ["PRF", "iPRF", "Pseudorandom function"],
            ]) { $1 },
            common.merging([
                "id": "invertible-prf", "kind": "variant", "anchor": "#invertible-prfs", "of": "prf",
                "title": "Invertible PRFs", "aliases": [String](),
            ]) { $1 },
            common.merging([
                "id": "weak-prf", "kind": "variant", "anchor": "#weak-prfs", "of": "prf",
                "title": weakTitle, "aliases": [String](),
            ]) { $1 },
        ]
    }

    static func stale(_ findings: [DiffFinding], at path: String) -> Bool {
        findings.contains { $0.rule == .derivedFilesStale && $0.path == path }
    }

    // MARK: derivedFilesStale with relations.json regenerated

    @Test("derivedFilesStale: a reduction page edited after the generator ran warns, though relations.json changed")
    func editedAfterTheGenerator() throws {
        let path = Self.reductionPath
        let changed = DiffGuardTests.reduction.replacingOccurrences(
            of: "class: fully-black-box", with: "class: semi-black-box")
        let page = DiffGuardTests.modified(path, old: DiffGuardTests.reduction, new: changed)

        // relations.json was regenerated before the class changed: its record
        // still says fully-black-box, so `--check` fails.
        let before = try Self.relations(try Self.manifest(reductions: [Self.reductionRecord()]))
        let warning = try #require(DiffGuardTests.finding(.derivedFilesStale, in: DiffGuardTests.ingest([page, before])))
        #expect(warning.severity == .warning)
        #expect(warning.path == path)
        #expect(warning.lines == nil)

        // Regenerated after it: the record agrees, and nothing is stale.
        let after = try Self.relations(try Self.manifest(reductions: [Self.reductionRecord(class: "semi-black-box")]))
        #expect(!Self.stale(DiffGuardTests.ingest([page, after]), at: path))

        // A relations.json that does not read as the generator's proves nothing.
        let unread = DiffGuardTests.modified(Self.relationsPath, old: "{}\n", new: "{\"edges\": 1}\n")
        #expect(Self.stale(DiffGuardTests.ingest([page, unread]), at: path))
    }

    @Test("derivedFilesStale: a new reduction is compared with its record, its comments dropped as js-yaml drops them")
    func newReductionAgainstItsRecord() throws {
        // The wiki's Templates/Reduction.md comments its keys, and a flow list.
        let commented = DiffGuardTests.reduction
            .replacingOccurrences(of: "hypotheses:\n  - owf\n", with: "hypotheses: [owf] # object ids\n")
            .replacingOccurrences(of: "kind: construction", with: "kind: construction # implication | construction")
            .replacingOccurrences(of: "class: fully-black-box", with: "\"class\": fully-black-box # from the schema")
        #expect(commented != DiffGuardTests.reduction)
        let added = DiffGuardTests.added(Self.reductionPath, commented)
        let written = try Self.relations(try Self.manifest(reductions: [Self.reductionRecord()]))
        #expect(!Self.stale(DiffGuardTests.ingest([added, written]), at: Self.reductionPath))

        // No record for it at all: the generator ran before the page existed.
        let without = try Self.relations(try Self.manifest())
        #expect(Self.stale(DiffGuardTests.ingest([added, without]), at: Self.reductionPath))
    }

    @Test("derivedFilesStale: an object page's title or a variant's heading changed after the generator ran warns")
    func objectEditedAfterTheGenerator() throws {
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
        func stale(_ old: String, _ new: String, records: [[String: Any]]) throws -> Bool {
            let changed = page.replacingOccurrences(of: old, with: new)
            #expect(changed != page)
            let files = [
                DiffGuardTests.modified(old: page, new: changed),
                try Self.relations(try Self.manifest(objects: records)),
            ]
            return Self.stale(DiffGuardTests.check(files), at: DiffGuardTests.pagePath)
        }
        let title = ("title: Pseudorandom function\n", "title: Pseudorandom functions\n")
        #expect(try stale(title.0, title.1, records: Self.prfRecords()))
        #expect(try !stale(title.0, title.1, records: Self.prfRecords(title: "Pseudorandom functions")))

        // A variant is titled by its heading (generate-relations.mjs 107).
        let heading = ("## Weak PRFs\n", "## Weak prfs\n")
        #expect(try stale(heading.0, heading.1, records: Self.prfRecords()))
        #expect(try !stale(heading.0, heading.1, records: Self.prfRecords(weakTitle: "Weak prfs")))

        // A variant dropped from `variants` drops its record.
        #expect(try stale("  weak-prf: \"#weak-prfs\"\n", "", records: Self.prfRecords()))
    }

    // MARK: Regions as the generator writes them

    @Test("a region whose blank lines were changed by hand blocks, though its checksum matches")
    func regionShape() throws {
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
        let begin = DiffGuardTests.beginMarker
        let end = DiffGuardTests.endMarker
        for (old, new) in [(begin + "\n\n", begin + "\n"), ("\n\n" + end, "\n" + end), ("PRF]]\n\n" + end, "PRF]]  \n\n" + end)] {
            let changed = page.replacingOccurrences(of: old, with: new)
            #expect(changed != page)
            let file = DiffGuardTests.modified(old: page, new: changed)
            let json = try Self.relations(try Self.manifest(objects: Self.prfRecords()))
            for files in [[file], [file, json]] {
                let findings = DiffGuardTests.check(files)
                let blocked = try #require(DiffGuardTests.finding(.generatedRegionEdited, in: findings), "\(new)")
                #expect(blocked.severity == .blocking)
                #expect(blocked.lines?.first == 153)
                #expect(blocked.message.hasPrefix("The whitespace in the “Participates in” section on lines 153–"))
                #expect(blocked.message.contains("`generate-relations.mjs --check` fails"))
                #expect(DiffGuardTests.finding(.regionRegenerated, in: findings) == nil)
            }
        }
    }

    @Test("a region rewritten as the script writes it warns without relations.json, and is a note with it")
    func regionWithoutRelations() throws {
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
        let file = DiffGuardTests.modified(old: page, new: try DiffGuardTests.regenerated(page))

        let alone = DiffGuardTests.check([file])
        #expect(alone.map(\.rule) == [.derivedFilesStale])
        let warning = try #require(alone.first)
        #expect(warning.severity == .warning)
        #expect(warning.lines == LineRange(first: 153, last: 177))
        #expect(warning.message.hasPrefix(
            "The “Participates in” section on lines 153–177 changed, but `relations.json` did not"))

        let json = DiffGuardTests.modified(Self.relationsPath, old: "{}\n", new: "{\"edges\": 1}\n")
        #expect(DiffGuardTests.check([file, json]).map(\.rule) == [.regionRegenerated])
    }

    // MARK: A region removed while relations.json changed

    /// The fixture with its region dropped as the generator drops one
    /// (generate-relations.mjs 330).
    static func dropped(_ page: String) throws -> String {
        let begin = try #require(page.range(of: DiffGuardTests.beginMarker))
        return String(page[..<begin.lowerBound].dropLast())
    }

    @Test("a region removed while relations.json changed blocks when the new records still relate the page")
    func regionRemovedThoughRelated() throws {
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
        let file = DiffGuardTests.modified(old: page, new: try Self.dropped(page))
        let other: [String: Any] = [
            "id": "red-a-to-b", "kind": "implication", "hypotheses": ["owf"], "conclusion": "prg",
            "model": "standard", "via": [String](), "page": "content/Reductions/a-to-b.md",
        ]
        // An edge on its id, on one of its variants, or a `via` link to it by
        // an alias (participates-in.mjs 91–131).
        let related: [[String: Any]] = [
            other.merging(["hypotheses": ["prf"]]) { $1 },
            other.merging(["conclusion": "weak-prf"]) { $1 },
            other.merging(["via": ["[[iPRF|an invertible PRF]]"]]) { $1 },
        ]
        for reduction in related {
            let json = try Self.relations(try Self.manifest(objects: Self.prfRecords(), reductions: [reduction]))
            let findings = DiffGuardTests.ingest([file, json])
            let blocked = try #require(DiffGuardTests.finding(.generatedRegionEdited, in: findings))
            #expect(blocked.message.hasPrefix("The “Participates in” section was removed by hand."))
            #expect(DiffGuardTests.finding(.regionRegenerated, in: findings) == nil)
            // Its lines were the hand's, so they count.
            #expect(findings.filter { $0.rule == .ingestionScope }.map(\.message) == [
                "This changes 18 lines of `pseudorandom-function.md` by hand. "
                    + "An ingestion normally changes at most five lines of an existing page.",
            ])
        }

        // Nothing relates to it: the generator dropped it.
        let unrelated = try Self.relations(try Self.manifest(objects: Self.prfRecords(), reductions: [other]))
        #expect(DiffGuardTests.ingest([file, unrelated]).map(\.rule) == [.regionRegenerated])

        // A relations.json that does not read proves nothing.
        let unread = DiffGuardTests.modified(Self.relationsPath, old: "{}\n", new: "{\"edges\": []}\n")
        #expect(DiffGuardTests.finding(.generatedRegionEdited, in: DiffGuardTests.ingest([file, unread])) != nil)
    }

    // MARK: Frontmatter as js-yaml reads it

    @Test("relationFieldOnObjectPage: a quoted key, and a type: with a comment after it")
    func relationFieldAsYAMLReadsIt() throws {
        for key in [#""implies": [owf]"#, "'from': owf"] {
            let new = DiffGuardTests.edited("id: prf\n", "id: prf\n\(key)\n")
            let finding = try #require(DiffGuardTests.finding(
                .relationFieldOnObjectPage,
                in: DiffGuardTests.check([DiffGuardTests.modified(old: DiffGuardTests.page, new: new)])), "\(key)")
            #expect(finding.severity == .blocking)
            #expect(finding.lines == LineRange(first: 6, last: 6))
        }

        let commented = DiffGuardTests.edited("type: primitive\n", "type: primitive # an object page\n")
        let added = DiffGuardTests.edited("id: prf\n", "id: prf\nimplies: [owf]\n", in: commented)
        #expect(DiffGuardTests.finding(
            .relationFieldOnObjectPage,
            in: DiffGuardTests.check([DiffGuardTests.modified(old: commented, new: added)])) != nil)

        // The same type: still makes it an object page whose identity counts.
        let renamed = DiffGuardTests.edited("id: prf\n", "id: prf2\n", in: commented)
        #expect(Self.stale(
            DiffGuardTests.check([DiffGuardTests.modified(old: commented, new: renamed)]), at: DiffGuardTests.pagePath))
    }

    @Test("relationFieldOnObjectPage: a reduction page turned into an object page keeps keys the lint now rejects")
    func reductionTurnedObject() {
        let path = "content/Reductions/owf-to-prg-hill99.md"
        let object = DiffGuardTests.reduction.replacingOccurrences(of: "type: reduction", with: "type: primitive")
        let findings = DiffGuardTests.ingest([DiffGuardTests.modified(path, old: DiffGuardTests.reduction, new: object)])
        let fields = findings.filter { $0.rule == .relationFieldOnObjectPage }
        #expect(fields.compactMap(\.lines?.first) == [5, 7])
        #expect(fields.map(\.message).allSatisfy { $0.hasSuffix("(lint: `object-relation-field`)") })
    }

    @Test("derivedFilesStale: an alias in a flush-left list counts")
    func flushLeftAliases() {
        let old = DiffGuardTests.edited("id: prf\n", "id: prf\naliases:\n- PRF\n- PRFs\n")
        let alias = DiffGuardTests.edited("- PRFs\n", "- PRF family\n", in: old)
        #expect(Self.stale(
            DiffGuardTests.check([DiffGuardTests.modified(old: old, new: alias)]), at: DiffGuardTests.pagePath))
        let status = DiffGuardTests.edited("status: draft", "status: stub", in: old)
        #expect(!Self.stale(
            DiffGuardTests.check([DiffGuardTests.modified(old: old, new: status)]), at: DiffGuardTests.pagePath))
    }

    @Test("derivedFilesStale: a variant anchor is slugged before its heading is looked up")
    func sluggedVariantAnchor() throws {
        // lint.mjs accepts `#Weak-PRFs`: headingAt slugs it (markdown-text.mjs 172).
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
            .replacingOccurrences(of: "weak-prf: \"#weak-prfs\"", with: "weak-prf: \"#Weak-PRFs\"")
        func stale(_ old: String, _ new: String) -> Bool {
            let changed = page.replacingOccurrences(of: old, with: new)
            return Self.stale(
                DiffGuardTests.check([DiffGuardTests.modified(old: page, new: changed)]), at: DiffGuardTests.pagePath)
        }
        #expect(stale("## Weak PRFs\n", "## Weak prfs\n"))
        #expect(!stale("## Puncturable PRFs\n", "## Puncturable pseudorandom functions\n"))
    }

    // MARK: wikilinkMath as the lint counts it

    @Test("wikilinkMath: a link after a region's END marker, on its line, blocks")
    func wikilinkMathAfterTheEndMarker() throws {
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
        let end = DiffGuardTests.endMarker
        let link = " See also [[bilinear-map-assumptions#k-linear-assumption|$k$-Linear]]."
        let findings = DiffGuardTests.check([
            DiffGuardTests.modified(old: page, new: page.replacingOccurrences(of: end + "\n", with: end + link + "\n")),
        ])
        #expect(findings.map(\.rule) == [.wikilinkMath])
        #expect(findings.first?.lines == LineRange(first: 176, last: 176))

        // Inside the region, the hand edit is the finding (lint.mjs 1255).
        let inside = page.replacingOccurrences(
            of: "- [[prp-to-prf|PRP ⇒ PRF]]", with: "- [[prp-to-prf|$\\mathsf{PRP}$ ⇒ PRF]]")
        #expect(DiffGuardTests.finding(.wikilinkMath, in: DiffGuardTests.check([DiffGuardTests.modified(old: page, new: inside)])) == nil)
    }

    /// A link with math, inside a code fence: not a hit, its lines 9–11.
    static let fenced = """
        ---
        type: primitive
        id: prf
        ---

        # PRF

        Some prose.

        ```text
        see [[pseudorandom-function#weak-prfs|weak $\\mathsf{PRF}$]]
        ```

        More prose.

        """

    @Test("wikilinkMath: an unchanged link an edit elsewhere takes out of a code fence blocks")
    func wikilinkMathOutOfAFence() throws {
        let closer = Self.fenced.replacingOccurrences(of: "}$]]\n```\n", with: "}$]]\n~~~\n")
        let opener = Self.fenced.replacingOccurrences(of: "```text\n", with: "")
        for (new, line) in [(closer, 11), (opener, 10)] {
            #expect(new != Self.fenced)
            let finding = try #require(DiffGuardTests.finding(
                .wikilinkMath, in: DiffGuardTests.check([DiffGuardTests.modified(old: Self.fenced, new: new)])))
            #expect(finding.severity == .blocking)
            #expect(finding.lines == LineRange(first: line, last: line))
        }
        // The fence left as it was: the link is code.
        let prose = Self.fenced.replacingOccurrences(of: "More prose.", with: "More prose, edited.")
        #expect(DiffGuardTests.check([DiffGuardTests.modified(old: Self.fenced, new: prose)]).isEmpty)
    }

    @Test("wikilinkMath: the base's own hits are spent by its unchanged lines, so the added copy is the one reported")
    func wikilinkMathBudget() throws {
        let link = "[[x|$y$]]"
        let before = DiffGuardTests.edited("looks random.", "looks random, as \(link) does.")
        let after = DiffGuardTests.edited("is negligible.", "is negligible, as \(link) is.", in: before)
        let finding = try #require(DiffGuardTests.finding(
            .wikilinkMath, in: DiffGuardTests.check([DiffGuardTests.modified(old: before, new: after)])))
        #expect(finding.lines == LineRange(first: 14, last: 14))
    }
}
