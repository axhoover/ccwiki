import Foundation
import Testing
@testable import CCwiki

/// The derivation engine's rules (plans/derivations.md R1–R14), each on a
/// miniature manifest. Every expected value here was first computed by the
/// reference engine, `scripts/derivations_reference.py`, on the same fixture,
/// so these tests pin the port to it rule by rule; the corpus suite
/// (`DerivationCorpusTests`) then pins it on the real manifest.
struct DerivationTests {

    // MARK: R1, R7: the conjunction

    @Test("a conjunction fires only once every hypothesis is derived")
    func conjunctionIsNeverSplit() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b"), Fx.object("c"), Fx.object("d")],
            reductions: [Fx.reduction("red-ab-to-c", ["a", "b"], "c"),
                         Fx.reduction("red-d-to-c", ["d"], "c")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let alone = derivation.closure(from: ["a"], options: .standard)
        #expect(alone.facts["c"] == nil)

        let both = try #require(derivation.answer(from: ["a", "b"], to: "c", options: .standard).derived)
        #expect(both.fact.depth == 1)
        #expect(both.proof.relationIDs == ["red-ab-to-c"])
        #expect(both.isRecordedResult)
        let rowIDs = both.proof.rows.map { $0.objectID }
        let rowLevels = both.proof.rows.map { $0.level }
        let givens = both.proof.rows.map { $0.isGiven }
        #expect(rowIDs == ["c", "a", "b"])
        #expect(rowLevels == [0, 1, 1])
        #expect(givens == [false, true, true])
    }

    @Test("a completion is offered only when it does not suffice alone, and never as a need")
    func completionsAreNotNeeds() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b"), Fx.object("c"), Fx.object("d")],
            reductions: [Fx.reduction("red-ab-to-c", ["a", "b"], "c"),
                         Fx.reduction("red-d-to-c", ["d"], "c")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let answer = try #require(derivation.answer(from: ["a"], to: "c", options: .standard).noPath)
        // D alone reaches C, so it belongs to "everything implying C", not
        // here: a completion says nothing about what is needed.
        let offered = answer.completions.map { $0.objectID }
        #expect(offered == ["b"])
        #expect(answer.completionCount == 1)
        #expect(answer.questionBecomes.isEmpty)
        #expect(Derivation.NoPathAnswer.footer.contains("This is not a separation"))

        let backward = derivation.implying("c", options: .standard)
        let singles = backward.singles.map { $0.objectID }
        #expect(singles == ["d"])
        #expect(backward.pairCount == 1)
        let group = try #require(backward.groups.first)
        #expect(group.relationID == "red-ab-to-c")
        #expect(group.pairs == [["a", "b"]])
    }

    // MARK: R1: equivalences

    @Test("each direction of an equivalence has its own class, and the reverse is marked")
    func equivalenceDirections() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("x"), Fx.object("y"), Fx.object("z"), Fx.object("w")],
            reductions: [Fx.reduction("red-x-eq-y", ["x"], "y", kind: "equivalence"),
                         Fx.reduction("red-y-to-z", ["y"], "z"),
                         Fx.reduction("red-w-eq-z", ["w"], "z", kind: "equivalence")])
        let curation = DerivationCuration(equivalences: [
            "red-x-eq-y": .init(forward: "record", reverse: "unstated"),
        ])
        let derivation = Derivation(manifest: manifest, curation: curation)

        let steps = derivation.steps.map { "\($0.id):\($0.reductionClass)" }
        #expect(steps == ["red-w-eq-z:unstated", "red-w-eq-z~reverse:unstated",
                          "red-x-eq-y:fully-black-box", "red-x-eq-y~reverse:unstated",
                          "red-y-to-z:fully-black-box"])
        // An equivalence nobody reviewed is unstated both ways, and listed.
        #expect(derivation.unreviewedEquivalences == ["red-w-eq-z"])

        let backwards = try #require(derivation.answer(from: ["y"], to: "x", options: .standard).derived)
        #expect(backwards.fact.chainClass == .unstated)
        #expect(backwards.proof.reverseRelationIDs == ["red-x-eq-y"])
        #expect(backwards.proof.rows.first?.step?.isReverse == true)
        let onPair = backwards.recordedOnPair.map { "\($0.relationID):\($0.isReverse):\($0.status.rawValue)" }
        #expect(onPair == ["red-x-eq-y:true:used"])

        let forwards = try #require(derivation.answer(from: ["x"], to: "y", options: .standard).derived)
        #expect(forwards.fact.chainClass == .fullyBlackBox)

        let far = try #require(derivation.answer(from: ["x"], to: "w", options: .standard).derived)
        #expect(far.fact.depth == 3)
        #expect(far.fact.chainClass == .unstated)
        #expect(far.proof.relationIDs == ["red-w-eq-z", "red-x-eq-y", "red-y-to-z"])
        #expect(far.proof.reverseRelationIDs == ["red-w-eq-z"])
    }

    // MARK: R1, R2: what never fires

    @Test("inclusions, heuristic edges and class endpoints never fire")
    func ineligibleEdgesNeverFire() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a", type: "assumption"), Fx.object("p"), Fx.object("q"),
                      Fx.object("k", type: "complexity-class")],
            reductions: [
                Fx.reduction("red-a-in-k", ["a"], "k", reductionClass: "free", kind: "inclusion"),
                Fx.reduction("red-a-to-p-heuristic", ["a"], "p", reductionClass: "unstated",
                             heuristic: true),
                Fx.reduction("red-k-to-q", ["k"], "q"),
                Fx.reduction("red-ghost-to-q", ["ghost"], "q"),
            ])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        #expect(derivation.steps.isEmpty)
        #expect(derivation.excluded[.inclusion] == ["red-a-in-k"])
        #expect(derivation.excluded[.heuristic] == ["red-a-to-p-heuristic"])
        #expect(derivation.excluded[.complexityClassEndpoint] == ["red-k-to-q"])
        #expect(derivation.excluded[.unresolvedEndpoint] == ["red-ghost-to-q"])
        #expect(derivation.closure(from: ["a"], options: .all).facts.count == 1)

        // The heuristic edge on the pair is named, with why it was not used.
        let answer = try #require(derivation.answer(from: ["a"], to: "p", options: .standard).noPath)
        let statuses = answer.recordedOnPair.map { "\($0.relationID):\($0.status.rawValue)" }
        #expect(statuses == ["red-a-to-p-heuristic:heuristic"])

        let toClass = derivation.answer(from: ["a"], to: "k", options: .standard).unsupported
        #expect(toClass == .complexityClass("k"))
        let unknown = derivation.answer(from: ["a"], to: "nowhere", options: .standard).unsupported
        #expect(unknown == .unknownObject("nowhere"))
    }

    // MARK: R4, R5: models

    @Test("an edge from a model node is in that model, whatever its record says")
    func modelNodeEdges() throws {
        let derivation = try Self.romWorld()
        let romStep = derivation.steps.first { $0.relationID == "red-rom-to-oihf" }
        #expect(romStep?.model == "rom")
        let defaults = derivation.defaultSteps.map { $0.relationID }
        #expect(defaults == ["red-oihf-to-ke", "red-oihf-to-ot"])
        #expect(derivation.isModelNode("rom"))
        #expect(!derivation.participants(.standard).contains("rom"))
        #expect(derivation.participants(.all).contains("rom"))

        // Toggle off: a model start derives nothing, and the answer says why
        // and what the toggle would find.
        let off = try #require(derivation.answer(from: ["rom"], to: "oihf", options: .standard).noPath)
        #expect(off.modelStarts == ["rom"])
        #expect(off.withIdealisedModels?.depth == 1)
        #expect(off.withIdealisedModels?.models == ["rom"])
        #expect(!off.withIdealisedModelsUsesStub)
        let statuses = off.recordedOnPair.map { $0.status.rawValue }
        #expect(statuses == ["idealised-model"])

        let on = try #require(derivation.answer(from: ["rom"], to: "oihf", options: .all).derived)
        #expect(on.fact.isModelScoped)
        #expect(on.fact.models == ["rom"])
        #expect(on.modelStarts.isEmpty)
    }

    @Test("a free step after a ROM step is refused; a relativizing one fires")
    func idealisedComposition() throws {
        let derivation = try Self.romWorld()

        let refused = try #require(derivation.answer(from: ["rom"], to: "ot", options: .all).noPath)
        let refusedIDs = refused.refused.map { $0.step.relationID }
        #expect(refusedIDs == ["red-oihf-to-ot"])
        let first = try #require(refused.refused.first)
        let kinds = first.reasons.map { $0.kind }
        #expect(kinds == ["idealised-composition"])
        #expect(first.scopedHypotheses == ["oihf"])

        let closure = derivation.closure(from: ["rom"], options: .all)
        let blocked = closure.refused.map { $0.step.relationID }
        #expect(blocked == ["red-oihf-to-ot"])
        #expect(closure.refused.first?.scopedHypotheses == ["oihf"])

        let relativizing = try #require(derivation.answer(from: ["rom"], to: "ke", options: .all).derived)
        #expect(relativizing.fact.depth == 2)
        #expect(relativizing.fact.chainClass == .relativizing)
        #expect(relativizing.fact.isModelScoped)

        // Outside the model the free step is an ordinary implication.
        let standard = try #require(derivation.answer(from: ["oihf"], to: "ot", options: .standard).derived)
        #expect(standard.fact.chainClass == .free)
        #expect(!standard.fact.isModelScoped)
    }

    /// `{rom} ⇒ oihf` recorded fully black-box and, wrongly, standard-model;
    /// `oihf ⇒ ot` free, `oihf ⇒ ke` relativizing. BH26's shape.
    private static func romWorld() throws -> Derivation {
        let manifest = try Fx.manifest(
            objects: [Fx.object("rom", type: "glossary"), Fx.object("oihf"), Fx.object("ot"),
                      Fx.object("ke")],
            reductions: [Fx.reduction("red-rom-to-oihf", ["rom"], "oihf"),
                         Fx.reduction("red-oihf-to-ot", ["oihf"], "ot", reductionClass: "free"),
                         Fx.reduction("red-oihf-to-ke", ["oihf"], "ke", reductionClass: "relativizing")])
        return Derivation(manifest: manifest, curation: .empty)
    }

    @Test("a stub step is used only with the toggle, in an unknown model")
    func stubOnlyWithToggle() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("h", type: "assumption"), Fx.object("k")],
            reductions: [Fx.reduction("red-h-to-k", ["h"], "k", status: "stub")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let off = try #require(derivation.answer(from: ["h"], to: "k", options: .standard).noPath)
        let statuses = off.recordedOnPair.map { $0.status.rawValue }
        #expect(statuses == ["stub"])
        #expect(off.withIdealisedModelsUsesStub)
        #expect(off.withIdealisedModels?.models == ["unknown"])

        let on = try #require(derivation.answer(from: ["h"], to: "k", options: .all).derived)
        #expect(on.fact.models == ["unknown"])
        #expect(on.fact.chainClass == .unstated)
        #expect(on.fact.isModelScoped)
        #expect(on.proof.usesStub)
    }

    // MARK: R6, R7

    @Test("the chain class is the weakest step's, and a stronger chain is reported")
    func chainClassComposition() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b"), Fx.object("c"), Fx.object("d")],
            reductions: [Fx.reduction("red-a-to-b", ["a"], "b"),
                         Fx.reduction("red-b-to-c", ["b"], "c", reductionClass: "relativizing"),
                         Fx.reduction("red-c-to-d", ["c"], "d", reductionClass: "free"),
                         Fx.reduction("red-a-to-d", ["a"], "d", reductionClass: "unstated")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let toC = try #require(derivation.answer(from: ["a"], to: "c", options: .standard).derived)
        #expect(toC.fact.chainClass == .relativizing)
        #expect(toC.stronger == nil)

        // The shortest derivation is one unstated step; a free one exists in
        // three.
        let toD = try #require(derivation.answer(from: ["a"], to: "d", options: .standard).derived)
        #expect(toD.fact.depth == 1)
        #expect(toD.fact.chainClass == .unstated)
        let stronger = try #require(toD.stronger)
        #expect(stronger.chainClass == .free)
        #expect(stronger.depth == 3)
        #expect(stronger.proof.relationIDs == ["red-a-to-b", "red-b-to-c", "red-c-to-d"])

        let fromB = try #require(derivation.answer(from: ["b"], to: "d", options: .standard).derived)
        #expect(fromB.fact.chainClass == .free)
    }

    @Test("ties go to the stronger class, then to the reduction id by bytes")
    func deterministicTieBreak() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b")],
            reductions: [Fx.reduction("red-a-to-b-2", ["a"], "b"),
                         Fx.reduction("red-a-to-b-1", ["a"], "b"),
                         Fx.reduction("red-a-to-b-0", ["a"], "b", reductionClass: "free")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let answer = try #require(derivation.answer(from: ["a"], to: "b", options: .standard).derived)
        #expect(answer.proof.relationIDs == ["red-a-to-b-1"])
        let statuses = answer.recordedOnPair.map { "\($0.relationID):\($0.status.rawValue)" }
        #expect(statuses == ["red-a-to-b-0:not-on-shown-derivation", "red-a-to-b-1:used",
                             "red-a-to-b-2:not-on-shown-derivation"])
    }

    // MARK: R13: preconditions, weakenings, quarantine

    @Test("a precondition is assumed of a given, met by its producer, or refused")
    func preconditions() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("g", type: "assumption"), Fx.object("h"), Fx.object("j"),
                      Fx.object("m"), Fx.object("t"), Fx.object("u")],
            reductions: [Fx.reduction("red-g-to-h", ["g"], "h"), Fx.reduction("red-j-to-g", ["j"], "g"),
                         Fx.reduction("red-m-to-g", ["m"], "g"), Fx.reduction("red-g-to-t", ["g"], "t"),
                         Fx.reduction("red-g-to-u", ["g"], "u"), Fx.reduction("red-u-to-t", ["u"], "t")])
        let curation = DerivationCuration(requires: [
            .init(relationID: "red-g-to-h", isReverse: false, hypothesis: "g",
                  notion: "g in its strong regime", metBy: ["red-m-to-g"]),
            .init(relationID: "red-g-to-t", isReverse: false, hypothesis: "g",
                  notion: "g over a large field", metBy: []),
        ])
        let derivation = Derivation(manifest: manifest, curation: curation)

        // Given: assumed, and the assumption is part of the claim.
        let given = try #require(derivation.answer(from: ["g"], to: "h", options: .standard).derived)
        let assumed = given.fact.assumes.map { $0.notion }
        #expect(assumed == ["g in its strong regime"])
        #expect(given.proof.rows.first?.assumed.count == 1)

        // Produced by a reduction whose Statement establishes it.
        let met = try #require(derivation.answer(from: ["m"], to: "h", options: .standard).derived)
        #expect(met.fact.depth == 2)
        #expect(met.fact.assumes.isEmpty)

        // Produced by anything else: refused, and named.
        let refused = try #require(derivation.answer(from: ["j"], to: "h", options: .standard).noPath)
        let refusal = try #require(refused.refused.first?.reasons.first)
        #expect(refusal == .requires(hypothesis: "g", notion: "g in its strong regime",
                                     producedBy: "red-j-to-g"))
        let blocked = derivation.closure(from: ["j"], options: .standard).refused.map { $0.step.relationID }
        #expect(blocked == ["red-g-to-h", "red-g-to-t"])

        // Clean facts first: a longer derivation that assumes nothing beats a
        // shorter one that would assume.
        let clean = try #require(derivation.answer(from: ["g"], to: "t", options: .standard).derived)
        #expect(clean.fact.depth == 2)
        #expect(clean.fact.assumes.isEmpty)
        #expect(clean.proof.relationIDs == ["red-g-to-u", "red-u-to-t"])
        let unused = try #require(clean.recordedOnPair.first)
        #expect(unused.status == .notOnShownDerivation)
        #expect(unused.needs == ["g over a large field"])
    }

    @Test("a precondition on the reverse direction of an equivalence is assumed of a given, in its model only")
    func reverseDirectionPrecondition() throws {
        // DLO24's shape: an equivalence in a non-standard model whose reverse
        // direction needs more of its hypothesis than the node states.
        let manifest = try Fx.manifest(
            objects: [Fx.object("r", type: "assumption"), Fx.object("f", type: "assumption"),
                      Fx.object("d", type: "assumption")],
            reductions: [Fx.reduction("red-r-eq-f", ["r"], "f", reductionClass: "free", model: "other",
                                      kind: "equivalence"),
                         Fx.reduction("red-d-to-f", ["d"], "f")])
        let notion = "f against adversaries whose advice is fixed before the instance is sampled"
        let curation = DerivationCuration(
            equivalences: ["red-r-eq-f": .init(forward: "record", reverse: "record")],
            requires: [.init(relationID: "red-r-eq-f", isReverse: true, hypothesis: "f",
                             notion: notion, metBy: [])])
        let derivation = Derivation(manifest: manifest, curation: curation)

        // Given, with idealised models included: assumed, and scoped.
        let given = try #require(derivation.answer(from: ["f"], to: "r", options: .all).derived)
        let assumed = given.fact.assumes.map { $0.notion }
        #expect(assumed == [notion])
        #expect(given.fact.models == ["other"])
        #expect(given.fact.isModelScoped)
        #expect(given.fact.chainClass == .free)
        #expect(given.proof.reverseRelationIDs == ["red-r-eq-f"])
        #expect(derivation.answer(from: ["f"], to: "r", options: .standard).derived == nil)

        // Derived by another step: refused, and named.
        let refused = try #require(derivation.answer(from: ["d"], to: "r", options: .all).noPath)
        let step = try #require(refused.refused.first?.step)
        #expect(step.isReverse)
        let reasons = refused.refused.first?.reasons ?? []
        let expectedReasons = [Derivation.Refusal.requires(hypothesis: "f", notion: notion,
                                                           producedBy: "red-d-to-f")]
        #expect(reasons == expectedReasons)

        // The forward direction needs nothing.
        let forward = try #require(derivation.answer(from: ["r"], to: "f", options: .all).derived)
        #expect(forward.fact.assumes.isEmpty)
    }

    @Test("a weakened fact feeds only the steps that accept it, and blocks no full fact")
    func weakenedFacts() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("s", type: "assumption"), Fx.object("w"), Fx.object("v"),
                      Fx.object("y"), Fx.object("q"), Fx.object("r")],
            reductions: [Fx.reduction("red-s-to-w", ["s"], "w"), Fx.reduction("red-w-to-v", ["w"], "v"),
                         Fx.reduction("red-w-to-y", ["w"], "y"), Fx.reduction("red-q-to-r", ["q"], "r"),
                         Fx.reduction("red-r-to-w", ["r"], "w")])
        let curation = DerivationCuration(weakens: [
            .init(relationID: "red-s-to-w", notion: "selective w only", acceptedBy: ["red-w-to-v"]),
        ])
        let derivation = Derivation(manifest: manifest, curation: curation)

        let weak = try #require(derivation.answer(from: ["s"], to: "w", options: .standard).derived)
        #expect(weak.fact.weakening?.notion == "selective w only")

        let accepted = try #require(derivation.answer(from: ["s"], to: "v", options: .standard).derived)
        #expect(accepted.fact.depth == 2)
        #expect(accepted.fact.weakening == nil)
        let weakRows = accepted.proof.rows.map { $0.isWeakened }
        #expect(weakRows == [false, true, false])

        let refused = try #require(derivation.answer(from: ["s"], to: "y", options: .standard).noPath)
        let refusal = try #require(refused.refused.first?.reasons.first)
        #expect(refusal == .weakened(hypothesis: "w", producedBy: "red-s-to-w", notion: "selective w only"))

        // The full notion, found a layer later, is kept beside the weak one.
        let both = derivation.closure(from: ["q", "s"], options: .standard)
        #expect(both.facts["w"]?.step?.relationID == "red-r-to-w")
        #expect(both.weakFacts["w"]?.step?.relationID == "red-s-to-w")
        #expect(both.facts["y"]?.depth == 3)
    }

    @Test("a quarantined reduction is never used, and says why")
    func quarantine() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("e", type: "assumption"), Fx.object("f")],
            reductions: [Fx.reduction("red-e-to-f", ["e"], "f")])
        let reason = "The Statement has a second hypothesis."
        let derivation = Derivation(manifest: manifest,
                                    curation: DerivationCuration(quarantine: ["red-e-to-f": reason]))

        let quarantined = derivation.quarantinedSteps.map { $0.relationID }
        #expect(quarantined == ["red-e-to-f"])
        #expect(derivation.excluded[.quarantined] == ["red-e-to-f"])
        let answer = try #require(derivation.answer(from: ["e"], to: "f", options: .all).noPath)
        let row = try #require(answer.recordedOnPair.first)
        let quarantinedStatus = Derivation.RecordedOnPair.Status.excluded(.quarantined)
        #expect(row.status == quarantinedStatus)
        #expect(row.detail == reason)
        let reasons = answer.refused.first?.reasons ?? []
        let expectedReasons = [Derivation.Refusal.quarantined(reason: reason)]
        #expect(reasons == expectedReasons)
    }

    @Test("a quarantine of one direction holds back that direction of an equivalence only")
    func quarantineOneDirection() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("e", type: "assumption"), Fx.object("f"), Fx.object("g")],
            reductions: [Fx.reduction("red-e-eq-f", ["e"], "f", kind: "equivalence"),
                         Fx.reduction("red-f-to-g", ["f"], "g")])
        let reason = "The Statement does not establish this direction."
        let json = """
            { "quarantine": [{ "edge": "red-e-eq-f", "direction": "forward", "reason": "\(reason)" }],
              "equivalences": { "red-e-eq-f": { "forward": "record", "reverse": "record" } } }
            """
        let curation = try DerivationCuration.decode(Data(json.utf8))
        #expect(curation.quarantineReason("red-e-eq-f", isReverse: false) == reason)
        #expect(curation.quarantineReason("red-e-eq-f", isReverse: true) == nil)
        let derivation = Derivation(manifest: manifest, curation: curation)

        // Only the held direction is quarantined, and the reduction is not
        // excluded: its other direction is still a step.
        let held = derivation.quarantinedSteps.map { $0.id }
        #expect(held == ["red-e-eq-f"])
        #expect(derivation.excluded[.quarantined] == nil)
        let steps = derivation.steps.map { "\($0.id):\($0.reductionClass)" }
        #expect(steps == ["red-e-eq-f~reverse:fully-black-box", "red-f-to-g:fully-black-box"])

        // The held direction is named on its pair, with the reason, and
        // refused on the way.
        let forward = try #require(derivation.answer(from: ["e"], to: "f", options: .standard).noPath)
        let rows = forward.recordedOnPair.map { "\($0.relationID):\($0.isReverse):\($0.status.rawValue)" }
        #expect(rows == ["red-e-eq-f:false:quarantined"])
        #expect(forward.recordedOnPair.first?.detail == reason)
        let far = try #require(derivation.answer(from: ["e"], to: "g", options: .standard).noPath)
        let refused = far.refused.map { $0.step.id }
        #expect(refused == ["red-e-eq-f"])
        let reasons = far.refused.first?.reasons ?? []
        let expectedReasons = [Derivation.Refusal.quarantined(reason: reason)]
        #expect(reasons == expectedReasons)

        // The other direction takes the record's class.
        let backward = try #require(derivation.answer(from: ["f"], to: "e", options: .standard).derived)
        #expect(backward.fact.chainClass == .fullyBlackBox)
        #expect(backward.proof.reverseRelationIDs == ["red-e-eq-f"])
        let used = backward.recordedOnPair.map { "\($0.relationID):\($0.isReverse):\($0.status.rawValue)" }
        #expect(used == ["red-e-eq-f:true:used"])
        #expect(derivation.invariants().noIneligibleEdges)

        // An implication has one direction: scoping its quarantine to the
        // other does not resolve.
        let implication = DerivationCuration(quarantine: ["red-f-to-g": reason],
                                             quarantineDirections: ["red-f-to-g": true])
        #expect(implication.unresolved(in: manifest) == ["not an equivalence red-f-to-g"])
    }

    // MARK: R14

    @Test("a refuted start is vacuous, and neither it nor a setting is a source or completion")
    func refutedAndSettings() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("fake", type: "assumption"), Fx.object("p"), Fx.object("q"),
                      Fx.object("hm", of: "q"), Fx.object("r"), Fx.object("t"), Fx.object("s1"),
                      Fx.object("s2"), Fx.object("s3")],
            reductions: [Fx.reduction("red-fake-to-p", ["fake"], "p"), Fx.reduction("red-p-to-q", ["p"], "q"),
                         Fx.reduction("red-hm-to-q", ["hm"], "q"),
                         Fx.reduction("red-r-and-fake-to-s1", ["r", "fake"], "s1"),
                         Fx.reduction("red-r-and-hm-to-s2", ["r", "hm"], "s2"),
                         Fx.reduction("red-r-and-t-to-s3", ["r", "t"], "s3")])
        let curation = DerivationCuration(
            refuted: [.init(objectID: "fake", source: "XY99", text: "Fake is false (XY99).", evidence: "")],
            settings: [.init(objectID: "hm", text: "A setting.", evidence: "")])
        let derivation = Derivation(manifest: manifest, curation: curation)

        let vacuous = try #require(derivation.answer(from: ["fake"], to: "q", options: .standard).derived)
        #expect(vacuous.isVacuous)
        #expect(vacuous.refutedStarts.first?.source == "XY99")

        for target in ["s1", "s2"] {
            let answer = try #require(derivation.answer(from: ["r"], to: target, options: .standard).noPath)
            #expect(answer.completions.isEmpty, "\(target)")
        }
        let control = try #require(derivation.answer(from: ["r"], to: "s3", options: .standard).noPath)
        let offered = control.completions.map { $0.objectID }
        #expect(offered == ["t"])

        let backward = derivation.implying("q", options: .standard)
        let singles = backward.singles.map { $0.objectID }
        let settings = backward.settings.map { $0.objectID }
        #expect(singles == ["p"])
        #expect(settings == ["hm"])
        #expect(backward.refutedExcluded == ["fake"])
    }

    // MARK: R8, R12

    @Test("a derived barrier propagates only through clean, standard, primitive side edges")
    func derivedBarrierSoundness() throws {
        let derivation = try Self.barrierWorld()

        let derived = derivation.derivedBarriers(from: ["a"], to: "y")
        #expect(derived.count == 1)
        let first = try #require(derived.first)
        #expect(first.barrier.id == "bar-x-to-y")
        #expect(first.reductionClass == .fullyBlackBox)
        let up = first.up.map { $0.relationID }
        #expect(up == ["red-x-to-a"])
        #expect(first.down.isEmpty)
        #expect(!first.isRedundant)
        // BH26's shape: the barrier's circumvention reaches its own pair only.
        #expect(first.circumventedBy.isEmpty)
        #expect(first.circumventsOriginalOnly == ["red-x-to-y-free"])

        // A quantum side edge, one with a precondition, an unstated one
        // against a fully black-box barrier, and a non-primitive end: none.
        for start in ["b", "c", "d", "q"] {
            #expect(derivation.derivedBarriers(from: [start], to: "y").isEmpty, "\(start)")
        }
        // A believed-true consequence and a stub barrier never propagate.
        #expect(derivation.derivedBarriers(from: ["a"], to: "y2").isEmpty)
        #expect(derivation.derivedBarriers(from: ["a"], to: "y3").isEmpty)

        let down = try #require(derivation.derivedBarriers(from: ["x"], to: "e").first)
        let downIDs = down.down.map { $0.relationID }
        #expect(downIDs == ["red-e-to-y"])

        // A recorded relativizing barrier on the pair already says more.
        let redundant = try #require(derivation.derivedBarriers(from: ["a"], to: "e").first)
        #expect(redundant.redundantWith == ["bar-a-to-e"])

        // Against `free`, an unstated side edge is a proved implication.
        let free = try #require(derivation.derivedBarriers(from: ["d"], to: "z").first)
        #expect(free.reductionClass == .free)

        #expect(derivation.derivedBarriers.count == 6)
        let invariants = derivation.invariants().byName
        let failing = invariants.filter { !$0.value }.map { $0.key }
        #expect(failing.isEmpty)

        let answer = try #require(derivation.answer(from: ["a"], to: "y", options: .standard).noPath)
        #expect(answer.derivedBarriers.count == 1)
    }

    /// `{x} ⇏ y` fully black-box, circumvented by a free `x ⇒ y`, with one of
    /// each kind of side edge from `x`, and the barriers R12 must not
    /// propagate.
    private static func barrierWorld() throws -> Derivation {
        let primitives = ["x", "y", "a", "b", "c", "d", "e", "z", "y2", "y3"]
        let consequence: [[String: Any]] = [
            ["kind": "complexity", "target": "p-neq-np", "class": "fully-black-box"],
        ]
        let manifest = try Fx.manifest(
            objects: primitives.map { Fx.object($0) } + [Fx.object("q", type: "assumption")],
            reductions: [
                Fx.reduction("red-x-to-a", ["x"], "a"),
                Fx.reduction("red-x-to-b-quantum", ["x"], "b", model: "quantum"),
                Fx.reduction("red-x-to-c-pre", ["x"], "c"),
                Fx.reduction("red-x-to-d-unstated", ["x"], "d", reductionClass: "unstated"),
                Fx.reduction("red-x-to-q", ["x"], "q"),
                Fx.reduction("red-e-to-y", ["e"], "y"),
                Fx.reduction("red-x-to-y-free", ["x"], "y", reductionClass: "free"),
            ],
            barriers: [
                Fx.barrier("bar-x-to-y", ["x"], "y", circumventedBy: ["red-x-to-y-free"]),
                Fx.barrier("bar-x-to-y2", ["x"], "y2", consequences: consequence),
                Fx.barrier("bar-x-to-y3", ["x"], "y3", status: "stub"),
                Fx.barrier("bar-x-to-z", ["x"], "z", reductionClass: "free"),
                Fx.barrier("bar-a-to-e", ["a"], "e", reductionClass: "relativizing"),
            ])
        let curation = DerivationCuration(requires: [
            .init(relationID: "red-x-to-c-pre", isReverse: false, hypothesis: "x",
                  notion: "x, strong", metBy: []),
        ])
        return Derivation(manifest: manifest, curation: curation)
    }

    @Test("a barrier some clean chain meets is a conflict; a quantum chain beside one is context")
    func conflictsAndScopeNotes() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("p"), Fx.object("u"), Fx.object("t"), Fx.object("v")],
            reductions: [Fx.reduction("red-p-to-u", ["p"], "u"), Fx.reduction("red-u-to-t", ["u"], "t"),
                         Fx.reduction("red-p-to-v-quantum", ["p"], "v", model: "quantum")],
            barriers: [Fx.barrier("bar-p-to-t", ["p"], "t"), Fx.barrier("bar-p-to-v", ["p"], "v")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let conflicting = try #require(derivation.answer(from: ["p"], to: "t", options: .standard).derived)
        #expect(conflicting.conflicts == [Derivation.BarrierConflict(
            barrierID: "bar-p-to-t", isDerived: false, consequenceIndex: 0, chainClass: .fullyBlackBox)])
        #expect(conflicting.scopeNote == nil)

        let quantum = try #require(derivation.answer(from: ["p"], to: "v", options: .standard).derived)
        #expect(quantum.conflicts.isEmpty)
        #expect(quantum.scopeNote?.reasons == ["quantum"])

        let invariants = derivation.invariants()
        #expect(!invariants.noChainContradictsRecordedBarrier)
        #expect(!invariants.noChainContradictsDerivedBarrier)
        #expect(!invariants.noDerivedBarrierContradictsRecordedReduction)
        #expect(invariants.noIneligibleEdges)
    }

    @Test("a barrier's qualifier follows its status and class")
    func barrierQualifiers() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b")],
            reductions: [],
            barriers: [Fx.barrier("bar-1", ["a"], "b", reductionClass: "unstated"),
                       Fx.barrier("bar-2", ["a"], "b", reductionClass: "fixed-construction"),
                       Fx.barrier("bar-3", ["a"], "b", status: "stub"),
                       Fx.barrier("bar-4", ["a"], "b")])
        let qualifiers = manifest.barriers
            .sorted { $0.id < $1.id }
            .map { Derivation.qualifier(of: $0, in: manifest)?.rawValue ?? "-" }
        #expect(qualifiers == ["unclassified", "fixed-construction", "stub", "-"])
    }

    // MARK: R9

    @Test("hosts and sections are hints, never derivations")
    func hints() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("lpn", type: "assumption"), Fx.object("lpn-low", type: "assumption", of: "lpn"),
                      Fx.object("pke"), Fx.object("lwe", type: "assumption"),
                      Fx.object("ring", type: "assumption", of: "lwe"), Fx.object("sis", type: "assumption")],
            reductions: [Fx.reduction("red-lpn-low-to-pke", ["lpn-low"], "pke"),
                         Fx.reduction("red-sis-to-lwe", ["sis"], "lwe"),
                         Fx.reduction("red-sis-to-lpn-low", ["sis"], "lpn-low")])
        let derivation = Derivation(manifest: manifest, curation: .empty)

        let startSection = try #require(derivation.answer(from: ["lpn"], to: "pke", options: .standard).noPath)
        let expectedStart = [Derivation.Hint(kind: .startSection, objectID: "lpn-low", standsFor: "lpn", depth: 1)]
        #expect(startSection.hints == expectedStart)

        let targetHost = try #require(derivation.answer(from: ["sis"], to: "ring", options: .standard).noPath)
        let expectedHost = [Derivation.Hint(kind: .targetHost, objectID: "lwe", standsFor: "ring", depth: 1)]
        #expect(targetHost.hints == expectedHost)

        let targetSection = try #require(derivation.answer(from: ["sis"], to: "lpn", options: .standard).noPath)
        let expectedSection = [
            Derivation.Hint(kind: .targetSection, objectID: "lpn-low", standsFor: "lpn", depth: 1),
        ]
        #expect(targetSection.hints == expectedSection)
    }

    // MARK: The inspector's lookups

    @Test("derived rows are depth two or more, sorted, and never from a refuted source")
    func inspectorLookups() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b"), Fx.object("c"), Fx.object("d"),
                      Fx.object("z", type: "assumption")],
            reductions: [Fx.reduction("red-a-to-b", ["a"], "b"), Fx.reduction("red-b-to-c", ["b"], "c"),
                         Fx.reduction("red-c-to-d", ["c"], "d"), Fx.reduction("red-z-to-b", ["z"], "b")])
        let curation = DerivationCuration(
            refuted: [.init(objectID: "z", source: "Z1", text: "z is false.", evidence: "")])
        let derivation = Derivation(manifest: manifest, curation: curation)

        let implied = derivation.derivedImplications(of: "a", options: .standard)
        let impliedIDs = implied.map { $0.objectID }
        let impliedDepths = implied.map { $0.fact.depth }
        let impliedCounts = implied.map { $0.relationCount }
        #expect(impliedIDs == ["c", "d"])
        #expect(impliedDepths == [2, 3])
        #expect(impliedCounts == [2, 3])

        let sourcesOfD = derivation.derivedSources(of: "d", options: .standard).map { $0.objectID }
        #expect(sourcesOfD == ["b", "a"])
        let sourcesOfC = derivation.derivedSources(of: "c", options: .standard).map { $0.objectID }
        #expect(sourcesOfC == ["a"])
        // A refuted object still has its own (vacuous) consequences.
        let fromZ = derivation.derivedImplications(of: "z", options: .standard).map { $0.objectID }
        #expect(fromZ == ["c", "d"])
    }

    // MARK: The upstream fields (relations-followups.md §4.4)

    @Test("an equivalence whose record states its reverse class needs no review, and the record wins")
    func recordedReverseClass() throws {
        let manifest = try Fx.manifest(
            objects: ["x", "y", "u", "v", "s", "t"].map { Fx.object($0) },
            reductions: [
                Fx.reduction("red-x-eq-y", ["x"], "y", kind: "equivalence", reverseClass: "unstated"),
                Fx.reduction("red-u-eq-v", ["u"], "v", kind: "equivalence", reverseClass: "relativizing"),
                Fx.reduction("red-s-eq-t", ["s"], "t", kind: "equivalence", status: "stub",
                             reverseClass: "fully-black-box"),
            ])
        // The curation says both directions of x ⇔ y take the record's
        // class; the record itself says the reverse one is unstated.
        let curation = DerivationCuration(equivalences: [
            "red-x-eq-y": .init(forward: "record", reverse: "record"),
        ])
        let derivation = Derivation(manifest: manifest, curation: curation)

        // R3 still makes a stub unstated both ways.
        let steps = derivation.steps.map { "\($0.id):\($0.reductionClass)" }
        #expect(steps == ["red-s-eq-t:unstated", "red-s-eq-t~reverse:unstated",
                          "red-u-eq-v:fully-black-box", "red-u-eq-v~reverse:relativizing",
                          "red-x-eq-y:fully-black-box", "red-x-eq-y~reverse:unstated"])
        #expect(derivation.unreviewedEquivalences.isEmpty)

        let backwards = try #require(derivation.answer(from: ["y"], to: "x", options: .standard).derived)
        #expect(backwards.fact.chainClass == .unstated)
        let relativizing = try #require(derivation.answer(from: ["v"], to: "u", options: .standard).derived)
        #expect(relativizing.fact.chainClass == .relativizing)

        // The entry the record now supersedes is named, as a warning.
        let sentinels = derivation.sentinels()
        #expect(sentinels.superseded == ["equivalences:red-x-eq-y"])
        #expect(sentinels.byName["curationSuperseded"] == false)
        #expect(sentinels.equivalencesReviewed)
    }

    @Test("an object the record marks refuted is vacuous, by its own key, and never a source or completion")
    func recordedRefutation() throws {
        let manifest = try Fx.manifest(
            objects: [
                Fx.object("fake", type: "assumption", refutedBy: ["[[XY99 - An attack on Fake|XY99]]"]),
                Fx.object("old", type: "assumption",
                          refutedBy: ["[[ZW01 - Another attack|ZW01]]", "[[AB02 - A third|AB02]]"]),
                Fx.object("p"), Fx.object("q"), Fx.object("r"), Fx.object("s"),
            ],
            reductions: [Fx.reduction("red-fake-to-p", ["fake"], "p"), Fx.reduction("red-p-to-q", ["p"], "q"),
                         Fx.reduction("red-old-to-q", ["old"], "q"),
                         Fx.reduction("red-r-and-fake-to-s", ["r", "fake"], "s")])
        // The file refutes `old` too. The record's refutation replaces the
        // file's in the engine; the file's entry stays an entry, superseded.
        let curation = DerivationCuration(
            refuted: [.init(objectID: "old", source: "OLD", text: "Old is false (OLD).", evidence: "")])
        let derivation = Derivation(manifest: manifest, curation: curation)

        let vacuous = try #require(derivation.answer(from: ["fake"], to: "q", options: .standard).derived)
        #expect(vacuous.isVacuous)
        let refutation = try #require(vacuous.refutedStarts.first)
        #expect(refutation.source == "XY99")
        #expect(refutation.text == "Its page records the attack.")
        #expect(derivation.curation.refuted["old"]?.source == "ZW01, AB02")

        // R11 and R10 read the same table, so neither lists it.
        let backward = derivation.implying("q", options: .standard)
        let singles = backward.singles.map { $0.objectID }
        #expect(singles == ["p"])
        #expect(backward.refutedExcluded == ["fake", "old"])
        #expect(derivation.derivedSources(of: "q", options: .standard).isEmpty)
        let noPath = try #require(derivation.answer(from: ["r"], to: "s", options: .standard).noPath)
        #expect(noPath.completions.isEmpty)

        // A manifest refutation is the wiki's record, never a curation entry.
        let entries = derivation.curation.entries.map { $0.id }
        #expect(entries == ["refuted:old"])
        let sentinels = derivation.sentinels()
        #expect(sentinels.superseded == ["refuted:old"])
        #expect(sentinels.curationResolves)
    }

    @Test("a barrier proved outside the standard model is not propagated, still checked, and takes no scope note")
    func barrierModel() throws {
        let objects = ["x", "a", "y", "u", "t"].map { Fx.object($0) }
        let reductions = [Fx.reduction("red-x-to-a", ["x"], "a"), Fx.reduction("red-u-to-t", ["u"], "t")]
        func world(_ model: String?) throws -> Derivation {
            let manifest = try Fx.manifest(objects: objects, reductions: reductions, barriers: [
                Fx.barrier("bar-x-to-y", ["x"], "y", model: model),
                Fx.barrier("bar-u-to-t", ["u"], "t", model: "rom"),
            ])
            return Derivation(manifest: manifest, curation: .empty)
        }

        // In the standard model the barrier composes with x ⇒ a.
        let standard = try world(nil)
        let derived = standard.derivedBarriers.map { "\($0.barrier.id):\($0.hypothesis)⇒\($0.conclusion)" }
        #expect(derived == ["bar-x-to-y:a⇒y"])

        let rom = try world("rom")
        #expect(rom.derivedBarriers.isEmpty)
        #expect(rom.derivedBarriers(from: ["a"], to: "y").isEmpty)
        // It is still a recorded barrier on its own pair, and R8 still
        // checks it: the recorded u ⇒ t meets the ROM barrier on u ⇒ t.
        let onPair = try #require(rom.answer(from: ["x"], to: "y", options: .standard).noPath)
        let recorded = onPair.recordedBarriers.map { $0.id }
        #expect(recorded == ["bar-x-to-y"])
        let conflicting = try #require(rom.answer(from: ["u"], to: "t", options: .standard).derived)
        #expect(conflicting.conflicts == [Derivation.BarrierConflict(
            barrierID: "bar-u-to-t", isDerived: false, consequenceIndex: 0, chainClass: .fullyBlackBox)])
        #expect(!rom.invariants().noChainContradictsRecordedBarrier)

        // R8's scope note says the barriers concern standard-model
        // reductions: a ROM chain gets it beside a standard-model barrier,
        // not beside a ROM barrier, whose row names its model.
        func scopeNote(besideBarrierIn model: String?) throws -> Derivation.ScopeNote? {
            let manifest = try Fx.manifest(
                objects: [Fx.object("v"), Fx.object("w")],
                reductions: [Fx.reduction("red-v-to-w-rom", ["v"], "w", model: "rom")],
                barriers: [Fx.barrier("bar-v-to-w", ["v"], "w", model: model)])
            let derivation = Derivation(manifest: manifest, curation: .empty)
            return try #require(derivation.answer(from: ["v"], to: "w", options: .all).derived).scopeNote
        }
        #expect(try scopeNote(besideBarrierIn: nil)?.reasons == ["rom"])
        #expect(try scopeNote(besideBarrierIn: "rom") == nil)
    }

    @Test("curationSuperseded lists a setting no eligible step takes alone")
    func supersededSetting() throws {
        let manifest = try Fx.manifest(
            objects: ["hm", "hm3", "r", "q", "s"].map { Fx.object($0) },
            reductions: [Fx.reduction("red-hm-to-q", ["hm"], "q"),
                         Fx.reduction("red-r-and-hm3-to-s", ["r", "hm3"], "s")])
        let curation = DerivationCuration(settings: [
            .init(objectID: "hm", text: "A setting.", evidence: ""),
            .init(objectID: "hm3", text: "Another.", evidence: ""),
        ])
        let sentinels = Derivation(manifest: manifest, curation: curation).sentinels()
        #expect(sentinels.superseded == ["settings:hm3"])
        #expect(!sentinels.curationSuperseded)
        // A warning: the two that fail the corpus test still hold.
        #expect(sentinels.curationResolves)
        #expect(sentinels.regimeLossCurated)
    }

    @Test("a curated edge that changes under its id fails, and a class change off an equivalence warns")
    func curatedEdges() throws {
        let curation = DerivationCuration(
            quarantine: ["red-e-to-f": "The Statement has a second hypothesis."],
            equivalences: ["red-x-eq-y": .init(forward: "record", reverse: "record")],
            requires: [.init(relationID: "red-a-to-b", isReverse: false, hypothesis: "a",
                             notion: "a, strong", metBy: ["red-m-to-a"])],
            weakens: [.init(relationID: "red-p-to-w", notion: "w, selective", acceptedBy: ["red-w-to-z"])])
        let objects = ["a", "b", "m", "e", "f", "g", "x", "y", "p", "w", "z"].map { Fx.object($0) }
        let reviewed = Derivation(manifest: try Fx.manifest(objects: objects, reductions: [
            Fx.reduction("red-a-to-b", ["a"], "b"),
            Fx.reduction("red-m-to-a", ["m"], "a"),
            Fx.reduction("red-e-to-f", ["e"], "f"),
            Fx.reduction("red-x-eq-y", ["x"], "y", kind: "equivalence"),
            Fx.reduction("red-p-to-w", ["p"], "w"),
            Fx.reduction("red-w-to-z", ["w"], "z"),
        ]), curation: curation)

        // Each entry's edge, its producers and its consumers: what the golden
        // file's `curatedEdges` snapshots.
        let naming = reviewed.curatedRelations()
        #expect(naming.keys.sorted() == ["red-a-to-b", "red-e-to-f", "red-m-to-a", "red-p-to-w",
                                         "red-w-to-z", "red-x-eq-y"])
        #expect(naming["red-m-to-a"] == ["requires:red-a-to-b:a"])
        #expect(naming["red-w-to-z"] == ["weakens:red-p-to-w"])
        var snapshot: [String: Derivation.CuratedEdge] = [:]
        for relationID in naming.keys { snapshot[relationID] = reviewed.curatedEdge(relationID) }
        #expect(reviewed.changedCuratedEdges(since: snapshot).isEmpty)

        // The wiki moves: a model on the curated step, a producer's
        // conclusion, the quarantined edge's hypotheses, the equivalence's
        // class, a consumer's class, and the weakened step gone.
        let moved = Derivation(manifest: try Fx.manifest(objects: objects, reductions: [
            Fx.reduction("red-a-to-b", ["a"], "b", model: "rom"),
            Fx.reduction("red-m-to-a", ["m"], "g"),
            Fx.reduction("red-e-to-f", ["e", "g"], "f"),
            Fx.reduction("red-x-eq-y", ["x"], "y", reductionClass: "free", kind: "equivalence"),
            Fx.reduction("red-w-to-z", ["w"], "z", reductionClass: "unstated"),
        ]), curation: curation)
        let changed = moved.changedCuratedEdges(since: snapshot)
        let verdicts = changed.map { "\($0.relationID):\($0.fails ? "fails" : "warns")" }
        #expect(verdicts == ["red-a-to-b:warns", "red-e-to-f:fails", "red-m-to-a:fails", "red-p-to-w:fails",
                             "red-w-to-z:warns", "red-x-eq-y:fails"])
        let gone = try #require(changed.first { $0.relationID == "red-p-to-w" })
        #expect(gone.now == nil)
        #expect(gone.entryIDs == ["weakens:red-p-to-w"])
    }

    @Test("a curated conjunction whose page reorders its hypotheses is the same theorem")
    func curatedConjunctionReordered() throws {
        let curation = DerivationCuration(quarantine: ["red-a-and-b-to-c": "The Statement needs one group."])
        let objects = ["a", "b", "c", "d"].map { Fx.object($0) }
        func world(_ hypotheses: [String], reductionClass: String = "fully-black-box") throws -> Derivation {
            let manifest = try Fx.manifest(objects: objects, reductions: [
                Fx.reduction("red-a-and-b-to-c", hypotheses, "c", reductionClass: reductionClass),
            ])
            return Derivation(manifest: manifest, curation: curation)
        }
        // Reviewed out of sorted order, as JLS21's conjunction is recorded.
        let reviewed = try #require(try world(["b", "a"]).curatedEdge("red-a-and-b-to-c"))
        let snapshot = ["red-a-and-b-to-c": reviewed]

        #expect(try world(["a", "b"]).changedCuratedEdges(since: snapshot).isEmpty)
        // Reordered and retyped off an equivalence: the retyping alone warns.
        let retyped = try world(["a", "b"], reductionClass: "unstated").changedCuratedEdges(since: snapshot)
        #expect(retyped.map(\.fails) == [false])
        // A different conjunct is a different theorem.
        let other = try world(["d", "b"]).changedCuratedEdges(since: snapshot)
        #expect(other.map(\.fails) == [true])
    }

    // MARK: The Statement lint (§2a)

    @Test("the Statement lint reads a page whatever its line endings")
    func statementLintLineEndings() throws {
        let manifest = try Fx.manifest(
            objects: [Fx.object("a"), Fx.object("b"), Fx.object("lwe", type: "assumption")],
            reductions: [Fx.reduction("red-a-to-b", ["a"], "b")])
        let derivation = Derivation(manifest: manifest, curation: .empty)
        let page = "## Statement\nIf [[a]] and [[lwe]] hold, so does [[b]] \u{2014} [@X].\n\n"
            + "## Proof\nOmitted.\n"

        // The reference engine reports LWE on all three, since Python's text
        // mode reads "\r\n" and "\r" as "\n".
        for ending in ["\n", "\r\n", "\r"] {
            let text = page.replacingOccurrences(of: "\n", with: ending)
            let hits = derivation.statementLint { _ in text }
            let relationIDs = hits.map { $0.relationID }
            let unlisted = hits.map { $0.unlisted }
            #expect(relationIDs == ["red-a-to-b"], "line ending \(ending.debugDescription)")
            #expect(unlisted == [["lwe"]], "line ending \(ending.debugDescription)")
        }
    }

    // MARK: The curation file

    @Test("the shipped curation decodes, with every table the spec lists")
    func shippedCuration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/derivation-curation.json"))
        let curation = try DerivationCuration.decode(data)

        #expect(curation.refuted.count == 3)
        #expect(curation.settings.count == 2)
        #expect(curation.quarantine.count == 4)
        #expect(curation.equivalences.count == 7)
        #expect(curation.requires.count == 26)
        #expect(curation.weakens.count == 3)
        #expect(curation.statementLint.count == 2)

        // ISIS ⇒ SIS is quarantined left to right only; SIS ⇒ ISIS keeps the
        // record's class.
        let isis = try #require(curation.equivalences["red-isis-inhomogeneous-sis-to-sis"])
        #expect(!isis.isForwardRecorded)
        #expect(isis.isReverseRecorded)
        #expect(curation.quarantineDirections["red-isis-inhomogeneous-sis-to-sis"] == false)
        #expect(curation.quarantineReason("red-isis-inhomogeneous-sis-to-sis", isReverse: false) != nil)
        #expect(curation.quarantineReason("red-isis-inhomogeneous-sis-to-sis", isReverse: true) == nil)
        #expect(curation.requirements(on: "red-isis-inhomogeneous-sis-to-sis", isReverse: false).isEmpty)
        // DLO24's FAC ⇒ RSA is conditional on its preprocessing experiment;
        // RSA ⇒ FAC is not.
        let dlo24 = curation.requirements(on: "red-rsa-to-fac-dlo24", isReverse: true).map { $0.hypothesis }
        #expect(dlo24 == ["fac"])
        #expect(curation.requirements(on: "red-rsa-to-fac-dlo24", isReverse: false).isEmpty)
        // GPSW06 needs DBDH; the PRP conversions a superpolynomial domain,
        // which LR88's PRP has.
        let gpsw06 = curation.requirements(on: "red-bdh-to-abe-gpsw06", isReverse: false).map { $0.hypothesis }
        #expect(gpsw06 == ["bdh"])
        let lr88: Set<String> = ["red-prf-to-prp-lr88"]
        for relationID in ["red-prp-to-prf", "red-prp-to-invertible-prf"] {
            let prp = curation.requirements(on: relationID, isReverse: false)
            #expect(prp.count == 1, "\(relationID)")
            #expect(prp.first?.hypothesis == "prp", "\(relationID)")
            #expect(prp.first?.metBy == lr88, "\(relationID)")
        }
        // Kil88 concludes static malicious MPC with abort, which nothing
        // consumes; GPSW06's selective KP-ABE feeds nothing either.
        #expect(curation.weakens["red-ot-to-mpc-kil88"]?.acceptedBy.isEmpty == true)
        #expect(curation.weakens["red-bdh-to-abe-gpsw06"]?.acceptedBy.isEmpty == true)
        let kil88 = curation.requirements(on: "red-ot-to-mpc-kil88", isReverse: false)
        #expect(kil88.count == 1)
        #expect(kil88.first?.metBy == ["red-cpir-to-ot-dmo00"])
        #expect(curation.requirements(on: "red-ddh-and-lpn-and-lwe-and-nc1-prg-to-io-jls21",
                                      isReverse: false).count == 4)
        #expect(curation.weakens["red-prp-to-invertible-prf"]?.acceptedBy == ["red-invertible-prfs-to-prf"])
        #expect(curation.refuted["circular-evasive-lwe"]?.source == "AMYY25")
    }

    @Test("optional curation keys cost a default")
    func curationDefaults() throws {
        let json = #"""
            { "requires": [{ "edge": "red-e", "hypothesis": "h", "notion": "n" }],
              "equivalences": { "red-q": { "forward": "record" } } }
            """#
        let curation = try DerivationCuration.decode(Data(json.utf8))
        let requirement = try #require(curation.requires.first)
        #expect(!requirement.isReverse)
        #expect(requirement.metBy.isEmpty)
        #expect(curation.equivalences["red-q"]?.isForwardRecorded == true)
        #expect(curation.equivalences["red-q"]?.isReverseRecorded == false)
        #expect(curation.refuted.isEmpty)
    }

    @Test("the empty derivation derives nothing")
    func emptyDerivation() {
        let empty = Derivation.empty
        #expect(empty.steps.isEmpty)
        #expect(empty.derivedBarriers.isEmpty)
        #expect(empty.derivedImplications(of: "owf", options: .standard).isEmpty)
        #expect(empty.answer(from: ["owf"], to: "pke", options: .standard).unsupported
            == .unknownObject("owf"))
    }
}

// MARK: - Fixture

/// Miniature manifests in the shape of the reference engine's own patch
/// helpers (`_obj`, `_red`, `_bar`), over the wiki's real class graph.
private enum Fx {

    static func manifest(objects: [[String: Any]], reductions: [[String: Any]],
                         barriers: [[String: Any]] = []) throws -> RelationsManifest {
        let propositions: [String: Any] = [
            "p-neq-np": ["title": "P ≠ NP", "believed": true] as [String: Any],
            "p-eq-np": ["title": "P = NP", "believed": false] as [String: Any],
        ]
        let root: [String: Any] = [
            "version": 1,
            "classes": classes,
            "classSentinels": ["unstated"],
            "propositions": propositions,
            "objects": objects,
            "reductions": reductions,
            "barriers": barriers,
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return RelationsManifest.decode(data)
    }

    /// The wiki's class graph: `implies` points narrower → broader.
    static var classes: [String: Any] {
        let implies: [String: [String]] = [
            "fully-black-box": ["semi-black-box", "relativizing"],
            "semi-black-box": ["weakly-black-box", "forall-exists-semi-black-box"],
            "forall-exists-semi-black-box": ["forall-exists-weakly-black-box"],
            "weakly-black-box": ["forall-exists-weakly-black-box", "free"],
            "forall-exists-weakly-black-box": ["free"],
            "relativizing": ["forall-exists-semi-black-box"],
            "free": [],
            "fixed-construction": ["free"],
        ]
        var classes: [String: Any] = [:]
        for (name, broader) in implies {
            let entry: [String: Any] = ["title": name, "implies": broader]
            classes[name] = entry
        }
        return classes
    }

    static func object(_ id: String, type: String = "primitive", of host: String? = nil,
                       refutedBy: [String]? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "kind": host == nil ? "object" : "variant",
            "type": type,
            "page": "content/Primitives/\(host ?? id).md",
            "slug": host ?? id,
            "title": id,
            "aliases": [String](),
            "unlisted": false,
        ]
        if let host {
            object["of"] = host
            object["anchor"] = "#" + id
        }
        if let refutedBy { object["refutedBy"] = refutedBy }
        return object
    }

    static func reduction(_ id: String, _ hypotheses: [String], _ conclusion: String,
                          reductionClass: String = "fully-black-box", model: String = "standard",
                          kind: String = "implication", heuristic: Bool = false,
                          status: String = "draft", reverseClass: String? = nil) -> [String: Any] {
        var reduction: [String: Any] = [
            "id": id,
            "kind": kind,
            "hypotheses": hypotheses,
            "conclusion": conclusion,
            "class": reductionClass,
            "model": model,
            "source": ["folklore"],
            "via": [String](),
            "heuristic": heuristic,
            "securityLoss": "",
            "status": status,
            "page": "content/Reductions/\(id).md",
            "slug": id,
            "title": id,
        ]
        if let reverseClass { reduction["reverseClass"] = reverseClass }
        return reduction
    }

    static func barrier(_ id: String, _ hypotheses: [String], _ conclusion: String,
                        reductionClass: String = "fully-black-box",
                        consequences: [[String: Any]]? = nil, strength: String = "unconditional",
                        circumventedBy: [String] = [], status: String = "draft",
                        model: String? = nil) -> [String: Any] {
        let contradiction: [[String: Any]] = [
            ["kind": "contradiction", "target": "", "class": reductionClass],
        ]
        var barrier: [String: Any] = [
            "id": id,
            "hypotheses": hypotheses,
            "conclusion": conclusion,
            "class": reductionClass,
            "consequences": consequences ?? contradiction,
            "strength": strength,
            "conditionalOn": [String](),
            "circumventedBy": circumventedBy,
            "source": ["folklore"],
            "status": status,
            "page": "content/Barriers/\(id).md",
            "slug": id,
            "title": id,
        ]
        if let model { barrier["model"] = model }
        return barrier
    }
}

fileprivate extension Derivation.Answer {
    var derived: Derivation.DerivedAnswer? {
        if case .derived(let answer) = self { return answer }
        return nil
    }

    var noPath: Derivation.NoPathAnswer? {
        if case .notDerived(let answer) = self { return answer }
        return nil
    }

    var unsupported: Derivation.Unsupported? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}
