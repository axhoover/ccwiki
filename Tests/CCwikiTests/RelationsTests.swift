import Foundation
import Testing
@testable import CCwiki

/// `relations.json` — decoding, the class partial order, and the rules that
/// stop the app asserting something the wiki does not.
///
/// The synthetic fixtures always run. The corpus checks at the bottom are gated
/// on `CCWIKI_WIKI`, the same way `CorpusTests` is.
struct RelationsTests {

    // MARK: Fixture

    /// A miniature manifest with the real class graph and one of each hazard.
    ///
    /// The class shape is copied from the wiki verbatim, because the direction
    /// of `implies` is the thing most worth pinning: it is invisible in the
    /// data and inverting it inverts every barrier in the corpus.
    static func manifest(
        version: Int = 1,
        reductions: String = Self.defaultReductions,
        barriers: String = Self.defaultBarriers,
        objects: String = Self.defaultObjects
    ) -> RelationsManifest {
        let json = """
        {
          "version": \(version),
          "schema": "https://cryptology.city/docs/relations-json",
          "classes": {
            "fully-black-box": { "title": "Fully black-box",
                                 "implies": ["semi-black-box", "relativizing"] },
            "semi-black-box": { "title": "Semi black-box", "implies": ["weakly-black-box"] },
            "weakly-black-box": { "title": "Weakly black-box", "implies": ["free"] },
            "relativizing": { "title": "Relativizing", "implies": ["forall-exists-semi-black-box"] },
            "forall-exists-semi-black-box": { "title": "∀∃ semi black-box", "implies": ["free"] },
            "free": { "title": "Free", "implies": [] }
          },
          "classSentinels": ["unstated"],
          "propositions": {
            "p-neq-np": { "title": "$\\\\classP \\\\neq \\\\classNP$", "believed": true,
                          "page": "Complexity/nondeterministic-polynomial-time" },
            "no-title": { "title": "", "believed": true, "page": null }
          },
          "objects": [\(objects)],
          "reductions": [\(reductions)],
          "barriers": [\(barriers)]
        }
        """
        return RelationsManifest.decode(Data(json.utf8))
    }

    static let defaultObjects = """
        { "id": "owf", "kind": "object", "type": "primitive",
          "page": "content/Primitives/one-way-function.md", "slug": "one-way-function",
          "title": "One-way function", "aliases": ["OWF"], "unlisted": false },
        { "id": "prg", "kind": "object", "type": "primitive",
          "page": "content/Primitives/pseudorandom-generator.md",
          "slug": "pseudorandom-generator", "title": "Pseudorandom generator",
          "aliases": [], "unlisted": false },
        { "id": "ot", "kind": "object", "type": "primitive",
          "page": "content/Primitives/oblivious-transfer.md", "slug": "oblivious-transfer",
          "title": "Oblivious transfer", "aliases": [], "unlisted": false },
        { "id": "ddh", "kind": "object", "type": "assumption",
          "page": "content/Assumptions/decisional-diffie-hellman.md",
          "slug": "decisional-diffie-hellman", "title": "Decisional Diffie-Hellman",
          "aliases": [], "unlisted": false },
        { "id": "secret-owf", "kind": "object", "type": "primitive",
          "page": "content/Primitives/secret.md", "slug": "secret",
          "title": "Secret", "aliases": [], "unlisted": true },
        { "id": "ip", "kind": "object", "type": "complexity-class",
          "page": "content/Complexity/interactive-polynomial-time.md",
          "slug": "interactive-polynomial-time", "title": "IP",
          "aliases": [], "unlisted": false },
        { "id": "pspace", "kind": "object", "type": "complexity-class",
          "page": "content/Complexity/pspace.md", "slug": "pspace", "title": "PSPACE",
          "aliases": [], "unlisted": false },
        { "id": "prg-selective", "kind": "variant", "type": "primitive",
          "page": "content/Primitives/pseudorandom-generator.md",
          "slug": "pseudorandom-generator", "anchor": "#selective-security",
          "of": "prg", "title": "prg-selective", "aliases": [], "unlisted": false }
        """

    static let defaultReductions = """
        { "id": "red-owf-to-prg", "kind": "implication", "hypotheses": ["owf"],
          "conclusion": "prg", "class": "fully-black-box", "model": "standard",
          "source": ["[[HILL99|HILL99]]"], "via": [], "securityLoss": "", "status": "draft",
          "page": "content/Reductions/owf-to-prg.md", "slug": "owf-to-prg",
          "title": "OWF ⇒ PRG" },
        { "id": "red-ddh-and-owf-to-ot", "kind": "implication",
          "hypotheses": ["ddh", "owf"], "conclusion": "ot", "class": "unstated",
          "model": "standard", "source": ["folklore"], "via": [], "securityLoss": "",
          "status": "stub", "page": "content/Reductions/ddh-and-owf-to-ot.md",
          "slug": "ddh-and-owf-to-ot", "title": "DDH + OWF ⇒ OT" },
        { "id": "red-free-owf-to-ot", "kind": "implication", "hypotheses": ["owf"],
          "conclusion": "ot", "class": "free", "model": "standard",
          "source": ["folklore"], "via": [], "securityLoss": "", "status": "draft",
          "page": "content/Reductions/free-owf-to-ot.md", "slug": "free-owf-to-ot",
          "title": "OWF ⇒ OT" },
        { "id": "red-ip-in-pspace", "kind": "inclusion", "hypotheses": ["ip"],
          "conclusion": "pspace", "class": "unstated", "model": "standard",
          "source": ["[[Sha92|Sha92]]"], "via": [], "securityLoss": "", "status": "draft",
          "page": "content/Reductions/ip-in-pspace.md", "slug": "ip-in-pspace",
          "title": "IP ⊆ PSPACE" },
        { "id": "red-prg-eq-owf", "kind": "equivalence", "hypotheses": ["prg"],
          "conclusion": "owf", "class": "unstated", "model": "standard",
          "source": ["folklore"], "via": [], "securityLoss": "", "status": "draft",
          "page": "content/Reductions/prg-eq-owf.md", "slug": "prg-eq-owf",
          "title": "PRG ⇔ OWF" },
        { "id": "red-bad-kind", "kind": "somethingelse", "hypotheses": ["owf"],
          "conclusion": "prg", "class": "unstated", "model": "standard",
          "source": [], "via": [], "securityLoss": "", "status": "draft",
          "page": "content/Reductions/bad-kind.md", "slug": "bad-kind", "title": "bad" },
        { "id": "red-bad-arity", "kind": "inclusion", "hypotheses": ["ip", "owf"],
          "conclusion": "pspace", "class": "unstated", "model": "standard",
          "source": [], "via": [], "securityLoss": "", "status": "draft",
          "page": "content/Reductions/bad-arity.md", "slug": "bad-arity", "title": "bad" }
        """

    static let defaultBarriers = """
        { "id": "bar-fbb-owf-to-ot", "hypotheses": ["owf"], "conclusion": "ot",
          "class": "fully-black-box",
          "consequences": [{ "kind": "contradiction", "target": "",
                             "class": "fully-black-box" }],
          "strength": "unconditional", "conditionalOn": [], "source": ["[[IR89|IR89]]"],
          "status": "draft", "page": "content/Barriers/no-owf-to-ot.md",
          "slug": "no-owf-to-ot", "title": "No fully black-box reduction from OWF to OT" },
        { "id": "bar-relativizing-owf-to-prg", "hypotheses": ["owf"], "conclusion": "prg",
          "class": "relativizing",
          "consequences": [{ "kind": "complexity", "target": "p-neq-np",
                             "class": "relativizing" },
                           { "kind": "reduction", "target": "does-not-exist",
                             "class": "free" }],
          "strength": "unconditional", "conditionalOn": [], "source": ["folklore"],
          "status": "stub", "page": "content/Barriers/no-owf-to-prg.md",
          "slug": "no-owf-to-prg", "title": "No relativizing reduction from OWF to PRG" }
        """

    // MARK: The class partial order

    @Test("`implies` points narrower → broader, transitively")
    func classClosureDirection() {
        let m = Self.manifest()
        // Stated directly in the file.
        #expect(m.reductionClass("fully-black-box", implies: "relativizing"))
        #expect(m.reductionClass("fully-black-box", implies: "semi-black-box"))
        // Reached only through the closure.
        #expect(m.reductionClass("fully-black-box", implies: "free"))
        #expect(m.reductionClass("relativizing", implies: "free"))
        // Reflexive: a class is trivially its own notion.
        #expect(m.reductionClass("free", implies: "free"))
        // And never the other way. `free` is the broadest notion there is.
        #expect(!m.reductionClass("free", implies: "fully-black-box"))
        #expect(!m.reductionClass("free", implies: "relativizing"))
        #expect(!m.reductionClass("relativizing", implies: "fully-black-box"))
    }

    /// The regression that matters most, taken from a real pair in the corpus:
    /// `red-oihf-to-ot-bh26` is class `free` and `bar-oihf-to-ot-bh26` is class
    /// `fully-black-box`, on the same hyperedge.
    ///
    /// The correct answer is **no conflict** — `free` implies nothing, so a
    /// barrier against a strictly narrower notion says nothing about it.
    /// Inverting the rule makes this pair report a contradiction, which is how
    /// you would find out you had inverted it.
    @Test("a barrier against a narrower class does not bite a broader reduction")
    func barrierDirectionIsNotInverted() {
        let m = Self.manifest()
        let free = try! #require(m.reductions.first { $0.id == "red-free-owf-to-ot" })

        // Same hyperedge — {owf} ⇒ ot — and the barrier is fully-black-box.
        #expect(m.barriers(onSameEdgeAs: free).map(\.id) == ["bar-fbb-owf-to-ot"])
        // But `free` does not imply `fully-black-box`, so nothing is ruled out.
        #expect(m.barriers(contradicting: free).isEmpty)
    }

    @Test("a barrier against a broader class does bite a narrower reduction")
    func barrierBitesWhenTheClassIsNarrower() {
        let m = Self.manifest()
        let fbb = try! #require(m.reductions.first { $0.id == "red-owf-to-prg" })

        // fully-black-box implies* relativizing, so a relativizing barrier bites.
        #expect(m.barriers(contradicting: fbb).map(\.id) == ["bar-relativizing-owf-to-prg"])
    }

    @Test("`unstated` is a sentinel, comparable to nothing")
    func sentinelNeverFires() {
        let m = Self.manifest()
        #expect(m.isSentinel("unstated"))
        #expect(!m.reductionClass("unstated", implies: "free"))
        #expect(!m.reductionClass("free", implies: "unstated"))
        #expect(!m.reductionClass("unstated", implies: "unstated"))

        // The multi-hypothesis reduction is `unstated` on the {ddh, owf} edge.
        let unstated = try! #require(m.reductions.first { $0.id == "red-ddh-and-owf-to-ot" })
        #expect(m.barriers(contradicting: unstated).isEmpty)
    }

    // MARK: The hyperedge

    @Test("a multi-hypothesis reduction keeps every hypothesis, as one edge")
    func conjunctionIsNeverFlattened() {
        let m = Self.manifest()
        let edge = try! #require(m.reductions.first { $0.id == "red-ddh-and-owf-to-ot" })
        #expect(edge.hypotheses == ["ddh", "owf"])
        #expect(edge.hasMultipleHypotheses)

        // It appears once under each hypothesis, and it is the *same* edge each
        // time — never two independent implications.
        #expect(m.relations(touching: "ddh").asHypothesis.map(\.id).contains(edge.id))
        #expect(m.relations(touching: "owf").asHypothesis.map(\.id).contains(edge.id))
        #expect(m.relations(touching: "ot").asConclusion.map(\.id).contains(edge.id))

        // And the row it renders as names both hypotheses.
        let labels = RelationLabels(manifest: m, index: nil)
        #expect(labels.statement(edge) == "Decisional Diffie-Hellman ∧ One-way function ⇒ Oblivious transfer")
    }

    @Test("each kind keeps its own arrow")
    func kindsRenderDistinctly() {
        let m = Self.manifest()
        let labels = RelationLabels(manifest: m, index: nil)

        let inclusion = try! #require(m.reductions.first { $0.id == "red-ip-in-pspace" })
        #expect(inclusion.kind == .inclusion)
        // Containment, not implication.
        #expect(labels.statement(inclusion) == "IP ⊆ PSPACE")
        #expect(!inclusion.kind.isSymmetric)

        let equivalence = try! #require(m.reductions.first { $0.id == "red-prg-eq-owf" })
        #expect(equivalence.kind == .equivalence)
        #expect(labels.statement(equivalence) == "Pseudorandom generator ⇔ One-way function")
        // Symmetric relations must not be split across a directional pair.
        #expect(equivalence.kind.isSymmetric)

        let implication = try! #require(m.reductions.first { $0.id == "red-owf-to-prg" })
        #expect(labels.statement(implication) == "One-way function ⇒ Pseudorandom generator")
    }

    @Test("an unrenderable relation is dropped, not guessed at")
    func badRowsAreDroppedWithAnAnomaly() {
        let m = Self.manifest()
        // An unknown kind would otherwise render as an implication.
        #expect(!m.reductions.contains { $0.id == "red-bad-kind" })
        // Inclusion and equivalence take exactly one hypothesis; a conjunction
        // is not a containment claim.
        #expect(!m.reductions.contains { $0.id == "red-bad-arity" })
        #expect(m.anomalies.count(where: { $0.contains("red-bad-kind") }) == 1)
        #expect(m.anomalies.count(where: { $0.contains("red-bad-arity") }) == 1)
    }

    // MARK: Barriers

    @Test("a consequence that does not resolve is dropped; the barrier survives")
    func danglingConsequenceIsTolerated() {
        let m = Self.manifest()
        let barrier = try! #require(m.barriers.first { $0.id == "bar-relativizing-owf-to-prg" })
        // The `reduction` consequence names an id that does not exist — this is
        // the shape of the one real dangling reference upstream today.
        #expect(barrier.consequences.count == 1)
        #expect(barrier.consequences.first?.kind == .complexity)
        #expect(m.anomalies.contains { $0.contains("does-not-exist") })
    }

    @Test("consequence text resolves each kind against the right table")
    func consequenceText() {
        let m = Self.manifest()
        let labels = RelationLabels(manifest: m, index: nil)

        let contradiction = Barrier.Consequence(
            kind: .contradiction, target: "", reductionClass: "free")
        #expect(labels.consequence(contradiction, manifest: m) == "a contradiction")

        let complexity = Barrier.Consequence(
            kind: .complexity, target: "p-neq-np", reductionClass: "relativizing")
        #expect(labels.consequence(complexity, manifest: m) == "P ≠ NP")

        // A proposition with no title falls back to its key rather than to "".
        let untitled = Barrier.Consequence(
            kind: .complexity, target: "no-title", reductionClass: "free")
        #expect(labels.consequence(untitled, manifest: m) == "No title")

        let object = Barrier.Consequence(
            kind: .object, target: "owf", reductionClass: "free")
        #expect(labels.consequence(object, manifest: m) == "One-way function")
    }

    // MARK: Degrading

    @Test("a version we do not know is refused, not parsed optimistically")
    func unsupportedVersion() {
        let m = Self.manifest(version: 2)
        #expect(m.isEmpty)
        #expect(m.reductions.isEmpty)
        #expect(m.diagnostic == .unsupportedVersion(found: 2, supported: 1))
    }

    @Test("a missing file degrades to empty plus a diagnostic")
    func missingFile() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-relations-\(UUID().uuidString)")
        let m = RelationsManifest.load(cloneRoot: root)
        #expect(m.isEmpty)
        #expect(m.diagnostic == .fileMissing(path: ".reductions/relations.json"))
        #expect(m.unlistedPaths.isEmpty)
    }

    @Test("malformed JSON degrades to empty plus a diagnostic")
    func malformed() {
        let m = RelationsManifest.decode(Data("{ not json".utf8))
        #expect(m.isEmpty)
        if case .malformed = m.diagnostic {} else {
            Issue.record("expected .malformed, got \(String(describing: m.diagnostic))")
        }
    }

    @Test("unknown keys are ignored, as the stability contract requires")
    func unknownKeysAreIgnored() {
        // `graphSlug` is a real undocumented field in the live manifest.
        let json = """
        { "version": 1, "somethingNew": 42, "classes": {}, "classSentinels": [],
          "propositions": {}, "objects": [
            { "id": "owf", "kind": "object", "type": "primitive",
              "page": "content/Primitives/one-way-function.md", "slug": "one-way-function",
              "graphSlug": "Primitives/one-way-function", "title": "One-way function",
              "aliases": [], "unlisted": false }],
          "reductions": [], "barriers": [] }
        """
        let m = RelationsManifest.decode(Data(json.utf8))
        #expect(m.diagnostic == nil)
        #expect(m.object("owf")?.title == "One-way function")
    }

    @Test("a missing optional key costs a default, not the manifest")
    func missingKeysDefault() {
        // No `aliases`, no `via`, no `securityLoss`, no `unlisted`.
        let json = """
        { "version": 1, "classes": {}, "classSentinels": ["unstated"], "propositions": {},
          "objects": [
            { "id": "a", "kind": "object", "type": "primitive",
              "page": "content/Primitives/a.md", "slug": "a", "title": "A" },
            { "id": "b", "kind": "object", "type": "primitive",
              "page": "content/Primitives/b.md", "slug": "b", "title": "B" }],
          "reductions": [
            { "id": "r", "kind": "implication", "hypotheses": ["a"], "conclusion": "b",
              "class": "unstated", "model": "standard", "source": ["folklore"],
              "status": "draft", "page": "content/Reductions/r.md", "slug": "r",
              "title": "A ⇒ B" }],
          "barriers": [] }
        """
        let m = RelationsManifest.decode(Data(json.utf8))
        #expect(m.diagnostic == nil)
        #expect(m.reductions.count == 1)
        #expect(m.reductions[0].via.isEmpty)
        #expect(m.object("a")?.unlisted == false)
    }

    // MARK: Nodes

    @Test("`unlisted` hides a page from browse without removing the node")
    func unlistedIsNavigationOnly() {
        let m = Self.manifest()
        let secret = try! #require(m.object("secret-owf"))
        #expect(secret.unlisted)
        #expect(m.unlistedPaths == ["Primitives/secret.md"])
        // Still a real node: it decoded, it has a label, and it would take part
        // in any edge that named it.
        #expect(RelationLabels(manifest: m, index: nil).label("secret-owf") == "Secret")
    }

    @Test("the manifest's `page` joins to `WikiPage.path`")
    func pageJoin() {
        #expect(RelationsManifest.contentRelative("content/Primitives/x.md")
            == "Primitives/x.md")
        // Already relative, or an unexpected shape: left alone rather than
        // mangled.
        #expect(RelationsManifest.contentRelative("Primitives/x.md") == "Primitives/x.md")

        let m = Self.manifest()
        #expect(m.object("owf")?.path == "Primitives/one-way-function.md")
        #expect(m.relation(onPage: "Reductions/owf-to-prg.md")?.id == "red-owf-to-prg")
        #expect(m.barrier(onPage: "Barriers/no-owf-to-ot.md")?.id == "bar-fbb-owf-to-ot")
        #expect(m.relation(onPage: "Primitives/one-way-function.md") == nil)
    }

    @Test("a variant is a section of its host, addressed by slug + anchor")
    func variantsAddressSections() throws {
        let m = Self.manifest()
        let variant = try #require(m.object("prg-selective"))
        #expect(variant.isVariant)
        #expect(variant.of == "prg")
        // The host's page, and the `#` stripped so it can go straight into
        // `AppModel.openPage(_:anchor:)`.
        #expect(variant.path == "Primitives/pseudorandom-generator.md")
        #expect(variant.anchor == "selective-security")

        let labels = RelationLabels(manifest: m, index: nil)
        let destination = try #require(labels.destination("prg-selective"))
        #expect(destination.path == "Primitives/pseudorandom-generator.md")
        #expect(destination.anchor == "selective-security")
    }

    /// Every variant in the corpus has `title == id`, so the label has to come
    /// from the host page's heading text.
    @Test("a variant whose title is its own id is named from its host's heading")
    func variantLabelComesFromTheHostHeading() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-variant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let page = root.appending(path: "Primitives/pseudorandom-generator.md")
        try FileManager.default.createDirectory(
            at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        type: primitive
        status: draft
        title: Pseudorandom generator
        ---

        # Pseudorandom generator

        ## Selective Security

        Text.
        """.write(to: page, atomically: true, encoding: .utf8)

        let index = WikiIndex.build(contentRoot: root)
        let labels = RelationLabels(manifest: Self.manifest(), index: index)
        #expect(labels.label("prg-selective") == "Pseudorandom generator § Selective Security")

        // Without the clone there is no heading to read, so it degrades to the
        // host's title plus the anchor rather than to the raw id.
        let bare = RelationLabels(manifest: Self.manifest(), index: nil)
        #expect(bare.label("prg-selective") == "Pseudorandom generator § Selective security")
    }

    // MARK: Plain text for chrome

    @Test("wiki math reduces to something a SwiftUI Text can show")
    func plainText() {
        #expect(RelationText.plain("$\\classP \\neq \\classNP$") == "P ≠ NP")
        #expect(RelationText.plain("$\\classNP \\subseteq \\classBPP$") == "NP ⊆ BPP")
        #expect(RelationText.plain("$\\classNP \\subseteq \\classPpoly$") == "NP ⊆ P/poly")
        #expect(RelationText.plain("$\\classcoNP \\subseteq \\classAM$") == "coNP ⊆ AM")
        #expect(RelationText.plain("$\\classEXP \\neq \\mathbf{NEXP}$") == "EXP ≠ NEXP")
        #expect(RelationText.plain("$q$-Strong Diffie-Hellman assumption")
            == "q-Strong Diffie-Hellman assumption")
        #expect(RelationText.plain("Pseudorandom generator in $\\mathrm{NC}^1$")
            == "Pseudorandom generator in NC^1")
        #expect(RelationText.plain("Every ORAM incurs $\\Omega(\\log n)$ amortized overhead")
            == "Every ORAM incurs Ω(log n) amortized overhead")
        // The unbalanced `$` in a real barrier title.
        #expect(RelationText.plain("No reduction from CPA Security to IND$-CPA Security")
            == "No reduction from CPA Security to IND-CPA Security")
        // A command with no rendering keeps its letters rather than its slash.
        #expect(RelationText.plain("$\\classFOO$") == "FOO")
        #expect(RelationText.plain("$\\someUnknownThing$") == "someUnknownThing")
        #expect(RelationText.plain("") == "")
        // Plain prose is untouched.
        #expect(RelationText.plain("The polynomial hierarchy collapses")
            == "The polynomial hierarchy collapses")
    }

    // MARK: Grouping — the bipartite invariant

    @Test("a multi-hypothesis edge is one row, not one row per hypothesis")
    func hyperedgeIsOneRow() {
        let m = Self.manifest()
        // `red-ddh-and-owf-to-ot` has hypotheses {ddh, owf}. On the OWF page it
        // must appear exactly once — flattening it would put OWF ⇒ OT and
        // DDH ⇒ OT on the page as independent claims, which the wiki does not
        // make.
        let page = PageRelations(path: "Primitives/one-way-function.md", manifest: m)
        let buildsOn = try! #require(page.groups.first { $0.role == .buildsOn })
        let ids = buildsOn.rows.map(\.id)
        #expect(ids.count == Set(ids).count, "a row was duplicated: \(ids)")
        #expect(ids.count(where: { $0 == "r:red-ddh-and-owf-to-ot" }) == 1)

        // And the row it renders as carries both hypotheses.
        let labels = RelationLabels(manifest: m, index: nil)
        let edge = try! #require(m.reductions.first { $0.id == "red-ddh-and-owf-to-ot" })
        let statement = labels.statement(edge)
        #expect(statement.contains("Decisional Diffie-Hellman"))
        #expect(statement.contains("One-way function"))
        #expect(statement.contains("∧"))
    }

    @Test("each kind lands in a group that describes it")
    func kindsGroupSeparately() {
        let m = Self.manifest()

        // Inclusion: IP ⊆ PSPACE. On the IP page that is containment, not
        // "builds on"; on the PSPACE page it is "contains".
        let ip = PageRelations(path: "Complexity/interactive-polynomial-time.md", manifest: m)
        #expect(ip.groups.map(\.role) == [.containedIn])
        let pspace = PageRelations(path: "Complexity/pspace.md", manifest: m)
        #expect(pspace.groups.map(\.role) == [.contains])
        #expect(!ip.groups.contains { $0.role == .buildsOn })

        // Equivalence is symmetric: it appears in the one group on both
        // endpoints, never split across the directional pair.
        let prg = PageRelations(path: "Primitives/pseudorandom-generator.md", manifest: m)
        let prgRoles = Set(prg.groups.filter { $0.objectID == "prg" }.map(\.role))
        #expect(prgRoles.contains(.equivalentTo))
        let owf = PageRelations(path: "Primitives/one-way-function.md", manifest: m)
        let owfRoles = Set(owf.groups.filter { $0.objectID == "owf" }.map(\.role))
        #expect(owfRoles.contains(.equivalentTo))
        // The equivalence must not also appear as an implication either way.
        for page in [prg, owf] {
            for group in page.groups where group.role == .buildsOn || group.role == .produces {
                #expect(!group.rows.contains { $0.id == "r:red-prg-eq-owf" })
            }
        }
    }

    @Test("a reduction page shows its own hyperedge, and says it is a conjunction")
    func reductionPageSubject() {
        let m = Self.manifest()
        let page = PageRelations(path: "Reductions/ddh-and-owf-to-ot.md", manifest: m)

        guard case .reduction(let relation) = page.subject else {
            Issue.record("expected a reduction subject, got \(page.subject)")
            return
        }
        #expect(relation.id == "red-ddh-and-owf-to-ot")

        // Both hypotheses are listed, under a heading that says they are all
        // required rather than alternatives.
        let hypotheses = try! #require(page.groups.first { $0.role == .hypothesesConjoined })
        #expect(hypotheses.rows.map(\.id) == ["o:ddh", "o:owf"])
        #expect(hypotheses.role.explanation.contains("every one of these"))

        // A single-hypothesis reduction gets the singular heading instead.
        let single = PageRelations(path: "Reductions/owf-to-prg.md", manifest: m)
        #expect(single.groups.contains { $0.role == .hypotheses })
        #expect(!single.groups.contains { $0.role == .hypothesesConjoined })
    }

    @Test("a barrier page lists the reductions it actually rules out")
    func barrierPageSubject() {
        let m = Self.manifest()
        let page = PageRelations(path: "Barriers/no-owf-to-prg.md", manifest: m)

        guard case .barrier(let barrier) = page.subject else {
            Issue.record("expected a barrier subject, got \(page.subject)")
            return
        }
        #expect(barrier.id == "bar-relativizing-owf-to-prg")
        // It is relativizing, and `red-owf-to-prg` is fully-black-box, which
        // implies relativizing — so it bites.
        let ruled = try! #require(page.groups.first { $0.role == .contradicts })
        #expect(ruled.rows.map(\.id) == ["r:red-owf-to-prg"])

        // The fully-black-box barrier on {owf} ⇒ ot rules out nothing: the only
        // reduction there is `free`, which implies nothing.
        let free = PageRelations(path: "Barriers/no-owf-to-ot.md", manifest: m)
        #expect(!free.groups.contains { $0.role == .contradicts })
    }

    @Test("a page the manifest does not know says so, rather than showing nothing")
    func unknownPage() {
        let page = PageRelations(path: "References/GGM86 - Something.md", manifest: Self.manifest())
        #expect(page.subject == .unknown)
        #expect(page.isEmpty)
    }

    @Test("with no manifest, every page is simply unknown")
    func noManifest() {
        let page = PageRelations(path: "Primitives/one-way-function.md",
                                 manifest: .empty)
        #expect(page.subject == .unknown)
        #expect(page.isEmpty)
    }

    // MARK: Corpus

    /// The real manifest, when a clone is available.
    static var cloneRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(
            atPath: root.appending(path: ".reductions/relations.json")
                .path(percentEncoded: false)) ? root : nil
    }

    @Test("the real manifest decodes, and its invariants hold")
    func corpusDecodes() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)

        #expect(m.diagnostic == nil)
        #expect(m.reductions.count > 300, "got \(m.reductions.count) reductions")
        #expect(m.barriers.count > 30, "got \(m.barriers.count) barriers")
        #expect(m.objectsByID.count > 200, "got \(m.objectsByID.count) objects")
        #expect(m.classSentinels.contains("unstated"))

        // Inclusion and equivalence are single-hypothesis by contract.
        for relation in m.reductions where relation.kind != .implication {
            #expect(relation.hypotheses.count == 1,
                    "\(relation.id) is \(relation.kind) with \(relation.hypotheses.count)")
        }
        // Every endpoint resolves to a node.
        for relation in m.reductions {
            for hypothesis in relation.hypotheses {
                #expect(m.object(hypothesis) != nil, "\(relation.id): \(hypothesis)")
            }
            #expect(m.object(relation.conclusion) != nil, "\(relation.id)")
        }
        // The conjunction is real: the corpus has genuine multi-hypothesis edges.
        #expect(m.reductions.count(where: \.hasMultipleHypotheses) > 20)

        print("relations.json: \(m.reductions.count) reductions, \(m.barriers.count) barriers, "
            + "\(m.objectsByID.count) objects, \(m.anomalies.count) anomalies")
        if !m.anomalies.isEmpty { print("  " + m.anomalies.joined(separator: "\n  ")) }
    }

    @Test("every corpus label is non-empty, including all 131 variants")
    func corpusLabels() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)
        let index = WikiIndex.build(contentRoot: cloneRoot.appending(path: "content"))
        let labels = RelationLabels(manifest: m, index: index)

        for object in m.objectsByID.values {
            let label = labels.label(object.id)
            #expect(!label.isEmpty, "\(object.id) has no label")
            #expect(!label.contains("$"), "\(object.id) label still has math: \(label)")
            #expect(!label.contains("\\"), "\(object.id) label still has a macro: \(label)")
        }
        for relation in m.reductions {
            #expect(!labels.statement(relation).isEmpty)
        }
    }

    /// The invariant that separates rendering what the wiki claims from
    /// inventing implications it does not: across the whole corpus, the number
    /// of rows must track the number of *edges*, never the number of endpoint
    /// pairs.
    @Test("across the corpus, one hyperedge is never split into several rows")
    func corpusRowsAreEdges() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)

        var pagesSeen = 0
        var rowsSeen = 0
        var multiHypothesisRows = 0

        for path in Set(m.objectsByID.values.map(\.path)) {
            let page = PageRelations(path: path, manifest: m)
            pagesSeen += 1

            for group in page.groups {
                // No row may repeat inside a group.
                let ids = group.rows.map(\.id)
                #expect(ids.count == Set(ids).count,
                        "\(path) group \(group.id) repeats a row")

                for row in group.rows {
                    rowsSeen += 1
                    guard case .relation(let relation) = row else { continue }
                    if relation.hasMultipleHypotheses { multiHypothesisRows += 1 }

                    // The row's own object must genuinely play the role the
                    // group claims, so nothing is filed under the wrong arrow.
                    guard let objectID = group.objectID else { continue }
                    switch group.role {
                    case .buildsOn:
                        #expect(relation.kind == .implication)
                        #expect(relation.hypotheses.contains(objectID))
                    case .produces:
                        #expect(relation.kind == .implication)
                        #expect(relation.conclusion == objectID)
                    case .containedIn:
                        #expect(relation.kind == .inclusion)
                        #expect(relation.hypotheses.contains(objectID))
                    case .contains:
                        #expect(relation.kind == .inclusion)
                        #expect(relation.conclusion == objectID)
                    case .equivalentTo:
                        #expect(relation.kind == .equivalence)
                    default:
                        break
                    }
                }
            }
        }

        // Every multi-hypothesis edge is reachable, and each one rendered as a
        // single row wherever it appeared.
        #expect(multiHypothesisRows > 0)
        print("page relations: \(pagesSeen) object pages, \(rowsSeen) rows, "
            + "\(multiHypothesisRows) of them multi-hypothesis")
    }

    @Test("every reduction and barrier page finds its own subject")
    func corpusSubjectsResolve() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)

        for relation in m.reductions {
            let page = PageRelations(path: relation.path, manifest: m)
            guard case .reduction(let found) = page.subject else {
                Issue.record("\(relation.path) did not resolve to its reduction")
                continue
            }
            #expect(found.id == relation.id)
            // Hypotheses and conclusion are always listed.
            #expect(page.groups.contains { $0.role == .conclusion })
            #expect(page.groups.contains {
                $0.role == .hypotheses || $0.role == .hypothesesConjoined
            })
        }
        for barrier in m.barriers {
            let page = PageRelations(path: barrier.path, manifest: m)
            guard case .barrier(let found) = page.subject else {
                Issue.record("\(barrier.path) did not resolve to its barrier")
                continue
            }
            #expect(found.id == barrier.id)
        }
    }

    @Test("no barrier in the corpus contradicts a reduction under the stated rule")
    func corpusBarrierConflicts() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)

        // Today this is zero: every barrier that shares a hyperedge with a
        // reduction has `unstated` on one side, or is the `free` reduction
        // against a `fully-black-box` barrier, which does not bite. Recorded so
        // that a change in the wiki — or an inversion of the rule here — shows
        // up as a test failure rather than as a silent new warning in the UI.
        let conflicts = m.reductions.flatMap { relation in
            m.barriers(contradicting: relation).map { "\(relation.id) vs \($0.id)" }
        }
        let shared = m.reductions.filter { !m.barriers(onSameEdgeAs: $0).isEmpty }
        print("hyperedges shared by a reduction and a barrier: \(shared.count); "
            + "contradictions under the class rule: \(conflicts.count)")
        #expect(conflicts.isEmpty, "\(conflicts)")
    }
}
