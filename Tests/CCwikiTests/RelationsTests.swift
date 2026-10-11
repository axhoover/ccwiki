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
            "semi-black-box": { "title": "Semi black-box",
                                "implies": ["weakly-black-box", "forall-exists-semi-black-box"] },
            "forall-exists-semi-black-box": { "title": "∀∃ semi black-box",
                                              "implies": ["forall-exists-weakly-black-box"] },
            "weakly-black-box": { "title": "Weakly black-box",
                                  "implies": ["forall-exists-weakly-black-box", "free"] },
            "forall-exists-weakly-black-box": { "title": "∀∃ weakly black-box",
                                                "implies": ["free"] },
            "relativizing": { "title": "Relativizing", "implies": ["forall-exists-semi-black-box"] },
            "free": { "title": "Free", "implies": [] },
            "fixed-construction": { "title": "Fixed construction", "implies": ["free"] }
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
          "of": "prg", "title": "prg-selective", "aliases": [], "unlisted": false },
        { "id": "ske", "kind": "object", "type": "primitive",
          "page": "content/Primitives/symmetric-key-encryption.md",
          "slug": "symmetric-key-encryption", "title": "Symmetric key encryption",
          "aliases": [], "unlisted": false },
        { "id": "pke", "kind": "object", "type": "primitive",
          "page": "content/Primitives/public-key-encryption.md",
          "slug": "public-key-encryption", "title": "Public key encryption",
          "aliases": [], "unlisted": false },
        { "id": "cpa-security", "kind": "variant", "type": "primitive",
          "page": "content/Primitives/symmetric-key-encryption.md",
          "slug": "symmetric-key-encryption", "anchor": "#cpa-security",
          "of": "ske", "title": "CPA Security", "aliases": [], "unlisted": false },
        { "id": "pke-cpa-security", "kind": "variant", "type": "primitive",
          "page": "content/Primitives/public-key-encryption.md",
          "slug": "public-key-encryption", "anchor": "#cpa-security",
          "of": "pke", "title": "CPA Security", "aliases": [], "unlisted": false },
        { "id": "ind-dollar-cpa-security", "kind": "variant", "type": "primitive",
          "page": "content/Primitives/symmetric-key-encryption.md",
          "slug": "symmetric-key-encryption", "anchor": "#ind-cpa-security",
          "of": "ske", "title": "IND$-CPA Security", "aliases": [], "unlisted": false },
        { "id": "pke-hidden-section", "kind": "variant", "type": "primitive",
          "page": "content/Primitives/public-key-encryption.md",
          "slug": "public-key-encryption", "anchor": "#hidden-section",
          "of": "pke", "title": "Hidden section", "aliases": [], "unlisted": true }
        """

    static let defaultReductions = """
        { "id": "red-owf-to-prg", "kind": "implication", "hypotheses": ["owf"],
          "conclusion": "prg", "class": "fully-black-box", "model": "standard",
          "source": ["[[HILL99 - A pseudorandom generator from any one-way function|HILL99]]"],
          "via": ["[[hybrid-argument|Hybrid argument]]"],
          "securityLoss": "$\\\\Adv^{\\\\mathrm{prf}} \\\\le q/|\\\\calD|$",
          "heuristic": false,
          "rationale": { "class": "HILL99 use the OWF only as an oracle.", "bogus": 3,
                         "via": "One hybrid per output block.",
                         "securityLoss": "A union bound over $q$ queries.",
                         "source": "HILL99 give both the construction and the proof." },
          "status": "draft",
          "page": "content/Reductions/owf-to-prg.md", "slug": "owf-to-prg",
          "title": "OWF ⇒ PRG" },
        { "id": "red-ddh-to-pke-candidate", "kind": "implication", "hypotheses": ["ddh"],
          "conclusion": "pke", "class": "unstated", "model": "standard",
          "source": ["[[XY98 - A candidate|XY98]]"], "via": [], "securityLoss": "",
          "heuristic": true,
          "rationale": { "heuristic": "XY98 give no reduction from DDH." },
          "status": "draft", "page": "content/Reductions/ddh-to-pke-candidate.md",
          "slug": "ddh-to-pke-candidate", "title": "DDH ⇒ PKE" },
        { "id": "red-ddh-and-owf-to-ot", "kind": "implication",
          "hypotheses": ["ddh", "owf"], "conclusion": "ot", "class": "unstated",
          "model": "standard", "source": ["folklore"], "via": [], "securityLoss": "",
          "status": "stub", "page": "content/Reductions/ddh-and-owf-to-ot.md",
          "slug": "ddh-and-owf-to-ot", "title": "DDH + OWF ⇒ OT" },
        { "id": "red-free-owf-to-ot", "kind": "implication", "hypotheses": ["owf"],
          "conclusion": "ot", "class": "free", "model": "standard",
          "source": ["folklore"], "via": [], "securityLoss": "",
          "rationale": { "kind": "Only this direction is known.",
                         "class": "It calls $\\\\Gen$ as an oracle on level-$(j-1)$ keys." },
          "status": "draft",
          "page": "content/Reductions/free-owf-to-ot.md", "slug": "free-owf-to-ot",
          "title": "OWF ⇒ OT" },
        { "id": "red-ip-in-pspace", "kind": "inclusion", "hypotheses": ["ip"],
          "conclusion": "pspace", "class": "free", "model": "standard",
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

    /// `bar-fbb-owf-to-ot` and its circumvention mirror the real BH26 pair:
    /// a fully-black-box barrier on {OIHF} ⇒ OT, got around by a `free`
    /// reduction on the very same hyperedge. `bar-ddh-to-ot` is got around by
    /// a reduction on a *different* hyperedge, as BAR01 gets around GK96.
    static let defaultBarriers = """
        { "id": "bar-fbb-owf-to-ot", "hypotheses": ["owf"], "conclusion": "ot",
          "class": "fully-black-box",
          "consequences": [{ "kind": "contradiction", "target": "",
                             "class": "fully-black-box" }],
          "strength": "unconditional", "conditionalOn": [],
          "circumventedBy": ["red-free-owf-to-ot", "red-never-written"],
          "source": ["[[IR89|IR89]]"],
          "rationale": { "class": "It refutes only that every scheme is IND$-CPA-secure; some other IND$-CPA-secure scheme is not ruled out.",
                         "oracle": "A random permutation and a $\\\\classPSPACE$ oracle." },
          "status": "draft", "page": "content/Barriers/no-owf-to-ot.md",
          "slug": "no-owf-to-ot", "title": "No fully black-box reduction from OWF to OT" },
        { "id": "bar-relativizing-owf-to-prg", "hypotheses": ["owf"], "conclusion": "prg",
          "class": "relativizing",
          "consequences": [{ "kind": "complexity", "target": "p-neq-np",
                             "class": "relativizing" },
                           { "kind": "reduction", "target": "does-not-exist",
                             "class": "free" }],
          "strength": "unconditional", "conditionalOn": [], "source": ["folklore"],
          "rationale": "not an object",
          "status": "stub", "page": "content/Barriers/no-owf-to-prg.md",
          "slug": "no-owf-to-prg", "title": "No relativizing reduction from OWF to PRG" },
        { "id": "bar-ddh-to-ot", "hypotheses": ["ddh"], "conclusion": "ot",
          "class": "fixed-construction",
          "consequences": [{ "kind": "complexity", "target": "p-neq-np",
                             "class": "fixed-construction" }],
          "strength": "conditional",
          "conditionalOn": ["owf", "the language has a hard subset-membership problem"],
          "circumventedBy": ["red-ddh-and-owf-to-ot"],
          "source": ["[[XY20 - On DDH and OT|XY20]]", "[[ZW21 - More on OT|ZW21]]"],
          "rationale": { "class": "Only the named construction is refuted.",
                         "strength": "XY20 assume one-way functions exist.",
                         "conditionalOn": "Both are XY20's own assumptions.",
                         "source": "ZW21 repair XY20's proof." },
          "status": "draft", "page": "content/Barriers/no-ddh-to-ot.md",
          "slug": "no-ddh-to-ot", "title": "No fixed-construction reduction from DDH to OT" }
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

        // `fixed-construction` is not an RTV04 class: it implies only `free`,
        // so a barrier refuting one named construction bites no reduction of
        // any other class.
        #expect(m.reductionClass("fixed-construction", implies: "free"))
        #expect(!m.reductionClass("fully-black-box", implies: "fixed-construction"))
        #expect(!m.reductionClass("free", implies: "fixed-construction"))
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
        // Pinned to this barrier, so no other dropped id can stand in for it.
        let dropped = m.anomalies.filter {
            $0.contains("bar-relativizing-owf-to-prg") && $0.contains("does-not-exist")
        }
        #expect(dropped.count == 1, "\(m.anomalies)")
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
        // The fields the final-form manifest added are all optional too.
        #expect(m.reductions[0].heuristic == false)
        #expect(m.reductions[0].rationale.isEmpty)
    }

    @Test("a proposition with no stated belief is unknown, not believed false")
    func unstatedBelief() {
        let json = """
        { "version": 1, "classes": {}, "classSentinels": ["unstated"],
          "propositions": {
            "p-eq-np": { "title": "P = NP", "believed": false },
            "mystery": { "title": "Something open" } },
          "objects": [], "reductions": [], "barriers": [] }
        """
        let m = RelationsManifest.decode(Data(json.utf8))
        #expect(m.propositions["p-eq-np"]?.believed == false)
        #expect(m.propositions["mystery"]?.believed == nil)
        #expect(m.propositions["mystery"]?.title == "Something open")
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

    /// Clones from before the wiki's final-form manifest have `title == id` on
    /// every variant, so the section's name has to come from the host page's
    /// heading text.
    @Test("a legacy variant whose title is its own id is named from its host's heading")
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

    /// The final-form manifest titles every variant with its heading text.
    /// The heading alone is not a name: the corpus has a "CPA Security"
    /// section on both encryption pages.
    @Test("a variant with a real title is still named with its host, so labels stay unique")
    func variantLabelCarriesItsHost() {
        let labels = RelationLabels(manifest: Self.manifest(), index: nil)
        #expect(labels.label("cpa-security") == "Symmetric key encryption § CPA Security")
        #expect(labels.label("pke-cpa-security") == "Public key encryption § CPA Security")
        #expect(labels.label("cpa-security") != labels.label("pke-cpa-security"))
        // A lone `$` in a title is a literal dollar.
        #expect(labels.label("ind-dollar-cpa-security")
            == "Symmetric key encryption § IND$-CPA Security")
    }

    @Test("an unlisted variant never hides its host's page")
    func unlistedVariantDoesNotHideItsHost() throws {
        let m = Self.manifest()
        let hidden = try #require(m.object("pke-hidden-section"))
        #expect(hidden.unlisted)
        #expect(hidden.isVariant)
        // The variant shares the PKE page, which is listed, so the page stays.
        #expect(!m.unlistedPaths.contains("Primitives/public-key-encryption.md"))
        #expect(m.unlistedPaths == ["Primitives/secret.md"])
    }

    // MARK: Additive fields

    @Test("`heuristic` is decoded, and absent means false")
    func heuristicIsDecoded() throws {
        let m = Self.manifest()
        let candidate = try #require(m.reduction("red-ddh-to-pke-candidate"))
        #expect(candidate.heuristic)
        #expect(candidate.rationale["heuristic"] == "XY98 give no reduction from DDH.")
        // Every other fixture edge either says false or does not say.
        let proved = try #require(m.reduction("red-free-owf-to-ot"))
        #expect(!proved.heuristic)
    }

    /// The statement is what a row's tooltip leads with and what Copy
    /// Statement puts on the clipboard, so it must not say `⇒` either.
    @Test("a heuristic edge is stated with a dashed arrow, everywhere")
    func heuristicStatement() throws {
        let m = Self.manifest()
        let labels = RelationLabels(manifest: m, index: nil)
        let candidate = try #require(m.reduction("red-ddh-to-pke-candidate"))
        #expect(candidate.arrow == "⇢")
        #expect(labels.statement(candidate) == "Decisional Diffie-Hellman ⇢ Public key encryption")

        // A proved implication keeps the solid arrow, and the other kinds
        // keep theirs.
        let proved = try #require(m.reduction("red-owf-to-prg"))
        #expect(proved.arrow == "⇒")
        let inclusion = try #require(m.reduction("red-ip-in-pspace"))
        #expect(inclusion.arrow == "⊆")
    }

    @Test("`rationale` is read entry by entry, and a bad one costs nothing else")
    func rationaleIsLenient() throws {
        let m = Self.manifest()
        let relation = try #require(m.reduction("red-owf-to-prg"))
        // The strings survive; the number beside them is dropped, not fatal.
        #expect(relation.rationale == [
            "class": "HILL99 use the OWF only as an oracle.",
            "via": "One hybrid per output block.",
            "securityLoss": "A union bound over $q$ queries.",
            "source": "HILL99 give both the construction and the proof.",
        ])

        // A rationale that is not an object at all costs only itself.
        let stub = m.barrier(onPage: "Barriers/no-owf-to-prg.md")
        let barrier = try #require(stub)
        #expect(barrier.rationale.isEmpty)
        #expect(barrier.consequences.count == 1)
    }

    @Test("`circumventedBy` is decoded, resolved, and indexed both ways")
    func circumventionIsIndexed() throws {
        let m = Self.manifest()
        let barrier = try #require(m.barrier(onPage: "Barriers/no-owf-to-ot.md"))
        // The dangling id is dropped and counted; the barrier survives.
        #expect(barrier.circumventedBy == ["red-free-owf-to-ot"])
        let dangling = m.anomalies.filter { $0.contains("red-never-written") }
        #expect(dangling.count == 1)
        #expect(m.reductions(circumventing: barrier).map(\.id) == ["red-free-owf-to-ot"])

        let free = try #require(m.reduction("red-free-owf-to-ot"))
        #expect(m.barriers(circumventedBy: free).map(\.id) == ["bar-fbb-owf-to-ot"])

        // A circumventing reduction need not share the barrier's hyperedge.
        let crossEdge = try #require(m.barrier(onPage: "Barriers/no-ddh-to-ot.md"))
        let conjunction = try #require(m.reduction("red-ddh-and-owf-to-ot"))
        #expect(m.reductions(circumventing: crossEdge).map(\.id) == ["red-ddh-and-owf-to-ot"])
        #expect(m.barriers(circumventedBy: conjunction).map(\.id) == ["bar-ddh-to-ot"])
    }

    @Test("a barrier page lists what gets around it, and the reduction page says so too")
    func circumventionGroups() throws {
        let m = Self.manifest()

        let barrierPage = PageRelations(path: "Barriers/no-owf-to-ot.md", manifest: m)
        let circumventedBy = barrierPage.groups.first { $0.role == .circumventedBy }
        let rows = try #require(circumventedBy).rows.map(\.id)
        #expect(rows == ["r:red-free-owf-to-ot"])

        // On the reduction's page the barrier is filed once, under the more
        // specific claim, although it also shares the hyperedge.
        let reductionPage = PageRelations(path: "Reductions/free-owf-to-ot.md", manifest: m)
        let roles = reductionPage.groups.map(\.role)
        #expect(roles == [.summary, .hypotheses, .conclusion, .circumvents])
        let circumvents = reductionPage.groups.first { $0.role == .circumvents }
        let circumventsRows = try #require(circumvents).rows.map(\.id)
        #expect(circumventsRows == ["b:bar-fbb-owf-to-ot"])

        // Across hyperedges too.
        let crossPage = PageRelations(path: "Barriers/no-ddh-to-ot.md", manifest: m)
        let cross = crossPage.groups.first { $0.role == .circumventedBy }
        let crossRows = try #require(cross).rows.map(\.id)
        #expect(crossRows == ["r:red-ddh-and-owf-to-ot"])
    }

    // MARK: The page's own record

    @Test("a reduction page leads with its own record, in the site's order")
    func reductionSummary() throws {
        let m = Self.manifest()
        let page = PageRelations(path: "Reductions/owf-to-prg.md", manifest: m)
        #expect(page.groups.first?.role == .summary)

        let relation = try #require(m.reduction("red-owf-to-prg"))
        let facts = PageRelations.facts(for: relation, manifest: m)
        #expect(facts.map(\.field)
            == [.kind, .reductionClass, .model, .via, .source, .securityLoss])
        #expect(facts.map(\.value) == [
            .text("Implication"), .text("Fully black-box"), .text("Standard model"),
            .text("Hybrid argument"), .text("HILL99"), .text("Adv^prf ≤ q/|D|"),
        ])
        #expect(facts.map(\.label)
            == ["Kind", "Class", "Model", "Via", "Source", "Security loss"])

        let kind = facts[0]
        #expect(kind.symbol == "⇒")
        #expect(kind.help == nil)
        // The class carries the wiki's reason, and leads to the glossary.
        let classFact = facts[1]
        #expect(classFact.help == "HILL99 use the OWF only as an oracle.")
        #expect(classFact.link == "[[reduction-classes#fully-black-box]]")
        #expect(!classFact.isTentative)
        // So does every other field the record gives a reason for.
        #expect(facts[3].help == "One hybrid per output block.")
        // A citation leads to its reference, with the paper as its tooltip,
        // then the record's reason for its sources.
        let source = facts[4]
        #expect(source.link == "[[HILL99 - A pseudorandom generator from any one-way function|HILL99]]")
        let sourceHelp = "HILL99 - A pseudorandom generator from any one-way function"
            + "\nHILL99 give both the construction and the proof."
        #expect(source.help == sourceHelp)
        // The loss leads its own tooltip, where a long one can be read whole,
        // and its reason is plain text like any other.
        #expect(facts[5].help == "Adv^prf ≤ q/|D|\nA union bound over q queries.")
        let ids = facts.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    /// Five corpus rationales carry TeX, such as `$\classBPP$` and
    /// `level-$j$`, and a tooltip cannot render it.
    @Test("a rationale reaches the summary as plain text")
    func summaryRationaleIsPlain() throws {
        let m = Self.manifest()
        let free = try #require(m.reduction("red-free-owf-to-ot"))
        #expect(free.why("class") == "It calls Gen as an oracle on level-(j-1) keys.")
        #expect(free.why("model") == nil)

        let facts = PageRelations.facts(for: free, manifest: m)
        #expect(facts.map(\.field) == [.kind, .reductionClass, .model, .source])
        #expect(facts[0].help == "Only this direction is known.")
        #expect(facts[1].help == "It calls Gen as an oracle on level-(j-1) keys.")
        #expect(facts[3].help == "Folklore: the wiki has no attribution for this claim.")
    }

    @Test("a heuristic edge is never summarized as a theorem")
    func heuristicSummary() throws {
        let m = Self.manifest()
        let candidate = try #require(m.reduction("red-ddh-to-pke-candidate"))
        let facts = PageRelations.facts(for: candidate, manifest: m)
        #expect(facts.map(\.field) == [.kind, .heuristic, .reductionClass, .model, .source])
        // The kind's arrow is dashed too, as in the rows, never a solid `⇒`
        // above "Heuristic candidate".
        #expect(facts[0].symbol == "⇢")

        let heuristic = facts[1]
        #expect(heuristic.value == .text("Heuristic candidate"))
        #expect(heuristic.help
            == Relation.heuristicExplanation + "\nXY98 give no reduction from DDH.")
        // `unstated` is shown as itself, de-emphasized, and still links to
        // the glossary's section explaining it.
        let unstated = facts[2]
        #expect(unstated.value == .text("unstated"))
        #expect(unstated.isTentative)
        #expect(unstated.link == "[[reduction-classes#unstated]]")
    }

    @Test("a stub shows no class or model, and a containment no class or standard model")
    func summaryOmissions() throws {
        let m = Self.manifest()

        let stub = try #require(m.reduction("red-ddh-and-owf-to-ot"))
        let stubFields = PageRelations.facts(for: stub, manifest: m).map(\.field)
        #expect(stubFields == [.kind, .source])

        // IP ⊆ PSPACE: class `free`, into a complexity class.
        let containment = try #require(m.reduction("red-ip-in-pspace"))
        #expect(m.isComplexityContainment(containment))
        let facts = PageRelations.facts(for: containment, manifest: m)
        #expect(facts.map(\.field) == [.kind, .source])
        #expect(facts.first?.value == .text("Inclusion"))
        #expect(facts.first?.symbol == "⊆")

        // An implication is never a containment, whatever its class.
        let free = try #require(m.reduction("red-free-owf-to-ot"))
        #expect(!m.isComplexityContainment(free))
    }

    @Test("a barrier page leads with its strength, class, assumptions and consequences")
    func barrierSummary() throws {
        let m = Self.manifest()
        let barrier = try #require(m.barrier(onPage: "Barriers/no-ddh-to-ot.md"))
        let page = PageRelations(path: barrier.path, manifest: m)
        #expect(page.groups.first?.role == .summary)

        let facts = PageRelations.facts(for: barrier, manifest: m)
        #expect(facts.map(\.field)
            == [.strength, .against, .assuming, .assuming, .consequence, .source, .source])
        #expect(facts.map(\.label) == [
            "Strength", "Against", "Assuming", "Assuming", "Would imply", "Sources", "Sources",
        ])

        let strength = facts[0]
        #expect(strength.value == .text("Conditional"))
        #expect(strength.help
            == "The barrier rests on an unproven assumption.\nXY20 assume one-way functions exist.")
        let against = facts[1]
        #expect(against.value == .text("Fixed construction reductions"))
        #expect(against.help == "Only the named construction is refuted.")

        // An object id opens the object; free text is kept as written. The
        // record's reason for its assumptions is on each of them.
        #expect(facts[2].value == .object("owf"))
        #expect(facts[3].value == .text("the language has a hard subset-membership problem"))
        #expect(facts[2].help == "Both are XY20's own assumptions.")
        #expect(facts[3].help == "Both are XY20's own assumptions.")
        #expect(facts[5].help == "XY20 - On DDH and OT\nZW21 repair XY20's proof.")
        #expect(facts[6].help == "ZW21 - More on OT\nZW21 repair XY20's proof.")

        // The consequence is shown with the community's belief about it, and
        // leads to the proposition's page.
        let consequence = facts[4]
        #expect(consequence.believed == true)
        #expect(consequence.link == "[[Complexity/nondeterministic-polynomial-time]]")
        let labels = RelationLabels(manifest: m, index: nil)
        #expect(labels.assumption("owf") == "One-way function")
        #expect(labels.assumption("the language has a hard subset-membership problem")
            == "the language has a hard subset-membership problem")
    }

    @Test("a barrier's contradiction and folklore source read plainly")
    func barrierSummaryPlainCases() throws {
        let m = Self.manifest()
        let barrier = try #require(m.barrier(onPage: "Barriers/no-owf-to-ot.md"))
        let facts = PageRelations.facts(for: barrier, manifest: m)
        #expect(facts.map(\.field) == [.strength, .against, .consequence, .source])
        #expect(facts[1].value == .text("Fully black-box reductions"))
        #expect(facts[2].believed == nil)
        // The class's reason, then the oracle's, which has no field of its
        // own. A sentence keeps its literal dollars (IND$-CPA, twice) but
        // loses its TeX.
        let againstHelp = "It refutes only that every scheme is IND$-CPA-secure; some other "
            + "IND$-CPA-secure scheme is not ruled out."
            + "\nA random permutation and a PSPACE oracle."
        #expect(facts[1].help == againstHelp)

        // A stub keeps its strength and sources, never its class.
        let stub = try #require(m.barrier(onPage: "Barriers/no-owf-to-prg.md"))
        let stubFacts = PageRelations.facts(for: stub, manifest: m)
        #expect(stubFacts.map(\.field) == [.strength, .consequence, .source])
        let folklore = stubFacts[2]
        #expect(folklore.value == .text("folklore"))
        #expect(folklore.link == nil)
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
        // A lone `$` is a literal dollar, as the wiki's contract says: this
        // is a real barrier title, and deleting the `$` names a different
        // notion, IND-CPA, and states a false separation.
        #expect(RelationText.plain("No reduction from CPA Security to IND$-CPA Security")
            == "No reduction from CPA Security to IND$-CPA Security")
        // The site's own security-loss macros.
        #expect(RelationText.plain(
            "$\\Adv^{\\mathrm{prf}} \\le \\Adv^{\\mathrm{prp}} + q(q-1)/(2|\\calD|)$")
            == "Adv^prf ≤ Adv^prp + q(q-1)/(2|D|)")
        #expect(RelationText.plain("plus $O(\\ell q^2/2^n)$ for $\\le \\ell$ blocks")
            == "plus O(ℓ q^2/2^n) for ≤ ℓ blocks")
        #expect(RelationText.plain("$\\mathbf{z} \\mapsto \\mathbf{A}\\mathbf{z} \\bmod q$")
            == "z ↦ Az mod q")
        #expect(RelationText.plain("time $\\Omega(\\min(\\sqrt{p}, 1/\\delta))$")
            == "time Ω(min(√p, 1/δ))")
        // A command with no rendering keeps its letters rather than its slash.
        #expect(RelationText.plain("$\\classFOO$") == "FOO")
        #expect(RelationText.plain("$\\someUnknownThing$") == "someUnknownThing")
        #expect(RelationText.plain("") == "")
        // Plain prose is untouched.
        #expect(RelationText.plain("The polynomial hierarchy collapses")
            == "The polynomial hierarchy collapses")
    }

    /// The pairing rule is micromark's, as the site's `escapeOutsideMath`
    /// ports it: a run of n dollars is math only if a later run of exactly n
    /// closes it.
    @Test("a `$` is a delimiter only when it pairs")
    func dollarsPairLikeMicromark() {
        #expect(RelationText.plain("$5 fee") == "$5 fee")
        #expect(RelationText.plain("$a$ and a lone $") == "a and a lone $")
        #expect(RelationText.plain("$$x \\neq y$$") == "x ≠ y")
        // A run of two is not closed by a run of one.
        #expect(RelationText.plain("$$x$") == "$$x$")
        // An escaped dollar is a dollar, and its backslash is markup.
        #expect(RelationText.plain("costs \\$5") == "costs $5")
        // Heading text arrives with every `$` already stripped; without a
        // dollar the reduction is the one it always was, braces and all.
        #expect(RelationText.plain("\\mathrm{NC}^1") == "NC^1")
    }

    /// The corpus's five TeX-bearing rationales, and the one whose literal
    /// dollars would pair under the site's rule.
    @Test("a rationale sentence loses its TeX and keeps its literal dollars")
    func rationaleSentences() {
        #expect(RelationText.sentence("an IPPE key may reveal the coefficients $r_i$.")
            == "an IPPE key may reveal the coefficients r_i.")
        #expect(RelationText.sentence("level-$j$ key material under the level-$(j-1)$ key")
            == "level-j key material under the level-(j-1) key")
        #expect(RelationText.sentence("calls $\\Gen$ and $\\Eval$ only as oracles")
            == "calls Gen and Eval only as oracles")
        #expect(RelationText.sentence(
            "One fixed construction, $\\mathbf{z} \\mapsto \\mathbf{A}\\mathbf{z} \\bmod q$ keyed by")
            == "One fixed construction, z ↦ Az mod q keyed by")
        #expect(RelationText.sentence("a language outside $\\classBPP$, is")
            == "a language outside BPP, is")

        // Two IND$-CPA mentions pair under the site's rule, which `plain`
        // keeps for titles; in a sentence the words between them are not
        // math, so both dollars stay.
        let indDollar = "is itself IND$-CPA-secure; building some other IND$-CPA-secure scheme"
        #expect(RelationText.sentence(indDollar) == indDollar)
        #expect(RelationText.plain(indDollar)
            == "is itself IND-CPA-secure; building some other IND-CPA-secure scheme")
        // A dollar left literal does not swallow a later math span.
        #expect(RelationText.sentence("IND$-CPA and $x$") == "IND$-CPA and x")
        #expect(RelationText.sentence("") == "")
    }

    @Test("a citation reads as its key, as the site's `renderSource` reads it")
    func citationKeys() {
        #expect(RelationText.citationKey("[[HILL99 - A pseudorandom generator|HILL99]]")
            == "HILL99")
        // No display text: the key comes from the filename.
        #expect(RelationText.citationKey("[[GK96 - On the Composition]]") == "GK96")
        #expect(RelationText.citationKey("[[References/BH26 - Steal OT]]") == "BH26")
        #expect(RelationText.citationKey("folklore") == "folklore")
        #expect(RelationText.citationKey("  ") == nil)

        #expect(RelationText.linkText("[[fiat-shamir-heuristic|Fiat–Shamir]]") == "Fiat–Shamir")
        #expect(RelationText.linkText("[[switching-lemma]]") == "switching-lemma")
        #expect(RelationText.linkText("Fiat–Shamir") == "Fiat–Shamir")
    }

    @Test("models are named as the site names them")
    func modelNames() {
        #expect(RelationVocabulary.modelName("standard") == "standard model")
        #expect(RelationVocabulary.modelName("rom") == "random oracle model")
        #expect(RelationVocabulary.modelName("crs") == "CRS model")
        #expect(RelationVocabulary.modelName("generic-group") == "generic group model")
        #expect(RelationVocabulary.modelName("algebraic-group") == "algebraic group model")
        #expect(RelationVocabulary.modelName("quantum") == "quantum setting")
        #expect(RelationVocabulary.modelName("other") == "non-standard model")
        #expect(RelationVocabulary.modelName("bounded-storage") == "bounded-storage model")

        #expect(RelationVocabulary.modelPage("rom") == "random-oracle-model")
        #expect(RelationVocabulary.modelPage("quantum") == nil)
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
        // A floor, not a count: sourcing passes upstream retire and merge
        // reductions (343 at the migration, 283 in the final-form manifest).
        #expect(m.reductions.count > 250, "got \(m.reductions.count) reductions")
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

        // The two candidate constructions are flagged, wherever they still
        // exist: neither may ever be shown as a theorem.
        for id in ["red-mmap-to-io-gghrsw13", "red-ntru-to-pke-hps98"] {
            guard let relation = m.reduction(id) else { continue }
            #expect(relation.heuristic, "\(id) is a candidate construction")
        }
        // Every circumvention resolves. One that did not would already be
        // gone from `circumventedBy`, dropped at decode and counted, so the
        // anomalies are the only place to look.
        let droppedCircumventions = m.anomalies.filter { $0.contains("circumventedBy") }
        #expect(droppedCircumventions.isEmpty, "\(droppedCircumventions)")
        let circumventionCount = m.barriers.reduce(0) { $0 + $1.circumventedBy.count }
        #expect(circumventionCount >= 2, "got \(circumventionCount) circumventions")

        // No rationale reaches the chrome with TeX in it, and the one with
        // two literal dollars keeps them.
        for relation in m.reductions {
            for field in relation.rationale.keys {
                let why = relation.why(field) ?? ""
                #expect(!why.contains("\\"), "\(relation.id) \(field): \(why)")
            }
        }
        for barrier in m.barriers {
            for field in barrier.rationale.keys {
                let why = barrier.why(field) ?? ""
                #expect(!why.contains("\\"), "\(barrier.id) \(field): \(why)")
            }
        }
        let indDollar = m.barriers.first { $0.id == "bar-cpa-security-to-ind-cpa-security" }
        if let why = indDollar?.why("class") {
            #expect(why.contains("IND$-CPA"), "got \(why)")
        }

        print("relations.json: \(m.reductions.count) reductions, \(m.barriers.count) barriers, "
            + "\(m.objectsByID.count) objects, \(m.anomalies.count) anomalies")
        if !m.anomalies.isEmpty { print("  " + m.anomalies.joined(separator: "\n  ")) }
    }

    @Test("every corpus label is non-empty, unique, and names a variant's host")
    func corpusLabels() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)
        let index = WikiIndex.build(contentRoot: cloneRoot.appending(path: "content"))
        let labels = RelationLabels(manifest: m, index: index)

        var owners: [String: [String]] = [:]
        for object in m.objectsByID.values {
            let label = labels.label(object.id)
            owners[label, default: []].append(object.id)
            #expect(!label.isEmpty, "\(object.id) has no label")
            #expect(!label.contains("\\"), "\(object.id) label still has a macro: \(label)")
            // A lone `$` is a literal dollar (IND$-CPA); two would mean a math
            // span survived.
            let dollars = label.filter { $0 == "$" }.count
            #expect(dollars < 2, "\(object.id) label still has math: \(label)")
            if object.isVariant {
                #expect(label.contains(" § "), "\(object.id) is named without its host: \(label)")
            }
        }
        // Two pages have a "CPA Security" section; the label must tell them
        // apart, or a row names the wrong notion.
        let shared = owners.filter { $0.value.count > 1 }
        #expect(shared.isEmpty, "labels shared by several objects: \(shared)")

        if m.object("ind-dollar-cpa-security") != nil {
            let label = labels.label("ind-dollar-cpa-security")
            #expect(label.contains("IND$-CPA"), "got \(label)")
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
            // The page leads with its own record, which always has its kind.
            #expect(page.groups.first?.role == .summary)
            let fields = page.groups.first?.facts.map(\.field) ?? []
            #expect(fields.first == .kind, "\(relation.id)")
            // Neither class nor standard model under IP ⊆ PSPACE.
            let showsClass = fields.contains(.reductionClass)
            if m.isComplexityContainment(relation) {
                #expect(!showsClass, "\(relation.id)")
            }
            let showsHeuristic = fields.contains(.heuristic)
            #expect(showsHeuristic == relation.heuristic, "\(relation.id)")
        }
        for barrier in m.barriers {
            let page = PageRelations(path: barrier.path, manifest: m)
            guard case .barrier(let found) = page.subject else {
                Issue.record("\(barrier.path) did not resolve to its barrier")
                continue
            }
            #expect(found.id == barrier.id)
            #expect(page.groups.first?.role == .summary)

            // The contract: a barrier is not the last word until its
            // circumvention has been read, on both pages.
            guard !barrier.circumventedBy.isEmpty else { continue }
            let listsCircumvention = page.groups.map(\.role).contains(.circumventedBy)
            #expect(listsCircumvention, "\(barrier.id)")
            for relation in m.reductions(circumventing: barrier) {
                let reductionPage = PageRelations(path: relation.path, manifest: m)
                let group = reductionPage.groups.first { $0.role == .circumvents }
                let rows = group?.rows.map(\.id) ?? []
                #expect(rows.contains("b:" + barrier.id), "\(relation.id)")
            }
        }
    }

    @Test("no barrier in the corpus contradicts a reduction under the stated rule")
    func corpusBarrierConflicts() throws {
        guard let cloneRoot = Self.cloneRoot else { return }
        let m = RelationsManifest.load(cloneRoot: cloneRoot)

        // Today this is zero: one hyperedge is shared by a reduction and a
        // barrier, BH26's `free` OIHF ⇒ OT against a `fully-black-box`
        // barrier, which does not bite (the barrier lists that reduction as
        // circumventing it). Recorded so that a change in the wiki — or an
        // inversion of the rule here — shows up as a test failure rather than
        // as a silent new warning in the UI.
        let conflicts = m.reductions.flatMap { relation in
            m.barriers(contradicting: relation).map { "\(relation.id) vs \($0.id)" }
        }
        let shared = m.reductions.filter { !m.barriers(onSameEdgeAs: $0).isEmpty }
        print("hyperedges shared by a reduction and a barrier: \(shared.count); "
            + "contradictions under the class rule: \(conflicts.count)")
        #expect(conflicts.isEmpty, "\(conflicts)")
    }
}
