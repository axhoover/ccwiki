import Foundation
import Testing
@testable import CCwiki

/// What the curation did to a proof (plans/relations-followups.md §2.5,
/// §6.4): each effect of §2.5's table on a fixture, the entries in the
/// curation's order and each once, and the quotes as the chrome shows them.
///
/// Every proof and refusal here is the reference engine's on the same
/// fixture (`scripts/derivations_reference.py`, imported as a library): the
/// trace only reads an answer, so the answer has to be the engine's.
struct CurationTraceTests {

    private typealias Fx = AdjustmentsFixture
    private typealias Effect = CurationTrace.Effect

    /// The trace of `start ⇒ target`'s shortest proof.
    private static func trace(_ start: [String], _ target: String,
                              over derivation: Derivation) throws -> CurationTrace {
        let answer = derivation.answer(from: Set(start), to: target, options: .standard)
        let derived = try #require(answer.derivedAnswer, "\(start) ⇒ \(target) is not derived")
        return CurationTrace.derived(
            derived.proof, other: derived.stronger?.proof,
            closure: derivation.closure(from: Set(start), options: .standard),
            start: start, derivation: derivation)
    }

    private static func ids(_ trace: CurationTrace) -> [String] { trace.items.map { $0.id } }

    /// The effects of a trace with exactly one item.
    private static func effects(_ trace: CurationTrace) throws -> [Effect] {
        #expect(trace.items.count == 1)
        return try #require(trace.items.first).effects
    }

    // MARK: Each effect

    @Test("a precondition assumed of a given is traced to its entry")
    func assumed() throws {
        let trace = try Self.trace(["ot"], "mpc", over: try Fx.derivation())
        #expect(Self.ids(trace) == ["requires:red-ot-to-mpc-kil88:ot"])
        let expected: [Effect] = [
            .assumed(relationID: "red-ot-to-mpc-kil88", isReverse: false, hypothesis: "ot"),
        ]
        #expect(try Self.effects(trace) == expected)
    }

    @Test("a precondition met on the proof names the step that establishes it")
    func establishedBy() throws {
        // DDH ⇒ MPC rests on DMO00 giving the malicious OT that Kil88 needs.
        let trace = try Self.trace(["ddh"], "mpc", over: try Fx.derivation())
        #expect(Self.ids(trace) == ["requires:red-ot-to-mpc-kil88:ot"])
        let expected: [Effect] = [
            .establishedBy(relationID: "red-ot-to-mpc-kil88", isReverse: false, hypothesis: "ot",
                           producer: "red-cpir-to-ot-dmo00"),
        ]
        #expect(try Self.effects(trace) == expected)
    }

    @Test("a step refused on the way that would have concluded an object on the proof is not used here")
    func notUsedHere() throws {
        // DDH ⇒ PRG takes three steps through PKE because BM84 was refused:
        // the DLOG here comes from CDH, not from Z_p^*.
        let trace = try Self.trace(["ddh"], "prg", over: try Fx.derivation())
        #expect(Self.ids(trace) == ["requires:red-dlog-to-prg-bm84:dlog"])
        let expected: [Effect] = [
            .notUsedHere(relationID: "red-dlog-to-prg-bm84", isReverse: false, hypothesis: "dlog",
                         producer: "red-cdh-to-dlog"),
        ]
        #expect(try Self.effects(trace) == expected)
    }

    @Test("a refusal is not used here only when it would have concluded an object on the proof")
    func notUsedHereNeedsTheProof() throws {
        let derivation = try Fx.derivation()
        // The closure from DDH refuses BM84, but PRG is on neither proof.
        let refused = derivation.closure(from: ["ddh"], options: .standard).refused
        #expect(refused.map { $0.step.relationID } == ["red-dlog-to-prg-bm84"])
        let pke = try Self.trace(["ddh"], "pke", over: derivation)
        #expect(pke.isEmpty)
        let mpc = try Self.trace(["ddh"], "mpc", over: derivation)
        #expect(Self.ids(mpc) == ["requires:red-ot-to-mpc-kil88:ot"])
    }

    @Test("a step first refused on a weak input that later fires on the proof is not 'not used here'")
    func refusedThenFired() throws {
        // H ⇒ T needs H in full. S gives only a weak H, so H ⇒ T is refused
        // at layer 2; R ⇒ H gives the full H at layer 2, and H ⇒ T fires at
        // layer 3. The engine keeps the first refusal.
        let objects: [[String: Any]] = [
            ExplorerFixture.object("s", title: "Sigma"), ExplorerFixture.object("h", title: "Eta"),
            ExplorerFixture.object("t", title: "Tau"), ExplorerFixture.object("q", title: "Kappa"),
            ExplorerFixture.object("r", title: "Rho"),
        ]
        let reductions: [[String: Any]] = [
            ExplorerFixture.reduction("red-s-to-h", ["s"], "h", title: "S ⇒ H", source: "SH01"),
            ExplorerFixture.reduction("red-h-to-t", ["h"], "t", title: "H ⇒ T", source: "HT02"),
            ExplorerFixture.reduction("red-q-to-r", ["q"], "r", title: "Q ⇒ R", source: "QR03"),
            ExplorerFixture.reduction("red-r-to-h", ["r"], "h", title: "R ⇒ H", source: "RH04"),
        ]
        let requirement = DerivationCuration.Requirement(
            relationID: "red-h-to-t", isReverse: false, hypothesis: "h", notion: "h in full",
            metBy: ["red-r-to-h"])
        let weakening = DerivationCuration.Weakening(
            relationID: "red-s-to-h", notion: "a weak h", acceptedBy: ["red-h-to-t"])
        let curation = DerivationCuration(requires: [requirement], weakens: [weakening])
        let manifest = try ExplorerFixture.manifest(objects: objects, reductions: reductions)
        let derivation = Derivation(manifest: manifest, curation: curation)

        let refused = derivation.closure(from: ["s", "q"], options: .standard).refused
        #expect(refused.map { $0.step.relationID } == ["red-h-to-t"])
        let trace = try Self.trace(["s", "q"], "t", over: derivation)
        #expect(Self.ids(trace) == ["requires:red-h-to-t:h"])
        let expected: [Effect] = [
            .establishedBy(relationID: "red-h-to-t", isReverse: false, hypothesis: "h",
                           producer: "red-r-to-h"),
        ]
        #expect(try Self.effects(trace) == expected)
    }

    @Test("a weaker result is kept apart, and the step that accepts it is named, in one item")
    func weakening() throws {
        let derivation = try Fx.derivation()
        let accepted = try Self.trace(["prp"], "prf", over: derivation)
        #expect(Self.ids(accepted) == ["weakens:red-prp-to-invertible-prf"])
        let both: [Effect] = [
            .keptApart(relationID: "red-prp-to-invertible-prf"),
            .accepted(producer: "red-prp-to-invertible-prf", consumer: "red-invertible-prfs-to-prf"),
        ]
        #expect(try Self.effects(accepted) == both)

        let alone = try Self.trace(["prp"], "invertible-prfs", over: derivation)
        let keptApart: [Effect] = [.keptApart(relationID: "red-prp-to-invertible-prf")]
        #expect(try Self.effects(alone) == keptApart)
    }

    @Test("an equivalence used in a direction its record's class does not cover is traced")
    func unstatedDirection() throws {
        let derivation = try Fx.derivation()
        let forward = try Self.trace(["isis"], "crhf", over: derivation)
        #expect(Self.ids(forward) == ["equivalences:red-isis-inhomogeneous-sis-to-sis"])
        let expected: [Effect] = [
            .unstatedDirection(relationID: "red-isis-inhomogeneous-sis-to-sis", isReverse: false),
        ]
        #expect(try Self.effects(forward) == expected)

        // SIS ⇒ ISIS is the direction the record's class covers.
        let reverse = try Self.trace(["sis"], "isis", over: derivation)
        #expect(reverse.isEmpty)
    }

    @Test("a refuted start and a setting are traced, with a derivation and without one")
    func startItems() throws {
        let derivation = try Fx.derivation()
        let vacuous = try Self.trace(["fake"], "pke", over: derivation)
        let refuted: [Effect] = [.vacuous(objectID: "fake")]
        #expect(try Self.effects(vacuous) == refuted)
        let setting = try Self.trace(["hm"], "mpc", over: derivation)
        let corruption: [Effect] = [.setting(objectID: "hm")]
        #expect(try Self.effects(setting) == corruption)

        let noPath = CurationTrace.starts(["fake"], derivation: derivation)
        #expect(Self.ids(noPath) == ["refuted:fake"])
        #expect(CurationTrace.starts(["cdh"], derivation: derivation).isEmpty)
    }

    @Test("a refutation the manifest records is the wiki's own, and makes no item")
    func manifestRefutation() throws {
        // A manifest's `refutedBy` reaches the engine through
        // `adding(refutations:)`, which keeps the file's entry.
        let manifestRefutation = DerivationCuration.Refutation(
            objectID: "fake", source: "XY99", text: "Its page records the attack.",
            evidence: "[[XY99 - An attack on the fake assumption|XY99]]")
        let merged = Fx.curation.adding(refutations: [manifestRefutation])
        let derivation = try Fx.derivation(curation: merged)

        let answer = derivation.answer(from: ["fake"], to: "pke", options: .standard)
        let derived = try #require(answer.derivedAnswer)
        #expect(derived.isVacuous)
        let trace = try Self.trace(["fake"], "pke", over: derivation)
        #expect(trace.isEmpty)
        #expect(CurationTrace.starts(["fake"], derivation: derivation).isEmpty)
    }

    @Test("a proof that touches no entry has an empty trace")
    func untouched() throws {
        let derivation = try Fx.derivation()
        let pke = try Self.trace(["ddh"], "pke", over: derivation)
        #expect(pke.isEmpty)
        let crhf = try Self.trace(["sis"], "crhf", over: derivation)
        #expect(crhf.isEmpty)
    }

    // MARK: Order

    @Test("one item per entry, with all its effects, in the curation's order")
    func curationOrder() throws {
        // Z needs CRHF from ISIS (unstated), MPC from cPIR (DMO00 establishes
        // malicious OT) and PRF from PRP (the weak iPRF, accepted); the
        // refuted start makes the whole implication vacuous.
        let trace = try Self.trace(["fake", "isis", "cpir", "prp"], "z", over: try Fx.derivation())
        #expect(Self.ids(trace) == ["refuted:fake", "equivalences:red-isis-inhomogeneous-sis-to-sis",
                                    "requires:red-ot-to-mpc-kil88:ot",
                                    "weakens:red-prp-to-invertible-prf"])
        let counts = trace.items.map { $0.effects.count }
        #expect(counts == [1, 1, 1, 2])
    }

    @Test("two proofs of one answer that use different entries give different traces")
    func perProof() throws {
        let derivation = try Fx.strongerDerivation()
        let answer = derivation.answer(from: ["a"], to: "t", options: .standard)
        let derived = try #require(answer.derivedAnswer)
        let stronger = try #require(derived.stronger)
        let closure = derivation.closure(from: ["a"], options: .standard)

        let shortest = CurationTrace.derived(derived.proof, other: stronger.proof, closure: closure,
                                             start: ["a"], derivation: derivation)
        let reverse: [Effect] = [.unstatedDirection(relationID: "red-t-eq-a", isReverse: true)]
        #expect(try Self.effects(shortest) == reverse)

        let strong = CurationTrace.derived(stronger.proof, other: derived.proof, closure: closure,
                                           start: ["a"], derivation: derivation)
        let established: [Effect] = [
            .establishedBy(relationID: "red-y-to-t", isReverse: false, hypothesis: "y",
                           producer: "red-a-to-y"),
        ]
        #expect(try Self.effects(strong) == established)
    }

    // MARK: Quotes

    @Test("a quote reads as plain text: links as their text, no emphasis, math made plain")
    func plainQuote() {
        let bm84 = CurationTrace.plainQuote(Fx.bm84Statement.quote)
        #expect(bm84 == "If DLOG is hard in ℤ_p^* (p prime, g a generator)")
        let ot = CurationTrace.plainQuote(Fx.otMalicious.quote)
        #expect(ot == "The definitions above are semi-honest")
    }
}

// MARK: - Fixture

/// The curated corners of the real manifest in miniature, on
/// `ExplorerFixture`'s builders, with a curation that cites the wiki the way
/// the shipped file does. `ExplorerResultTests` reads it too.
///
/// ```
/// ddh ⇒ cdh ⇒ dlog ⇒ prg (BM84: needs DLOG in Z_p^*);  ddh ⇒ pke ⇒ owf ⇒ prg
/// ddh ⇒ cpir ⇒ ot (DMO00) ⇒ mpc (Kil88: needs malicious OT, which DMO00 gives)
/// prp ⇒ invertible-prfs (the forward game only) ⇒ prf;  invertible-prfs ⇒ ske
/// isis ⇔ sis (its class holds for SIS ⇒ ISIS only);  sis ⇒ crhf
/// bdh ⇒ hve (quarantined);  fake ⇒ pke (fake is refuted);  hm ⇒ mpc (a setting)
/// crhf ∧ mpc ∧ prf ⇒ z
/// ```
enum AdjustmentsFixture {

    typealias Key = DerivationCuration.Entry.Key
    typealias Citation = DerivationCuration.Citation

    static let reviewedCommit = "ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157"

    static let bm84: Key = .requirement(relationID: "red-dlog-to-prg-bm84", isReverse: false,
                                        hypothesis: "dlog")
    static let kil88: Key = .requirement(relationID: "red-ot-to-mpc-kil88", isReverse: false,
                                         hypothesis: "ot")

    static let bm84Statement = Citation(
        page: "content/Reductions/red-dlog-to-prg-bm84.md", section: "Statement",
        quote: "If [[discrete-logarithm|DLOG]] is hard in $\\ZZ_p^*$ ($p$ prime, $g$ a generator)")
    static let kil88Statement = Citation(
        page: "content/Reductions/red-ot-to-mpc-kil88.md", section: "Statement",
        quote: "every two-party functionality can be computed with unconditional security "
            + "against malicious parties")
    static let otMalicious = Citation(
        page: "content/Primitives/ot.md", section: "Malicious Security",
        quote: "The definitions above are **semi-honest**")
    static let dmo00Statement = Citation(
        page: "content/Reductions/red-cpir-to-ot-dmo00.md", section: "Statement",
        quote: "Non-trivial single-server PIR is therefore complete for secure two-party and "
            + "multi-party computation")
    static let fakeAttack = Citation(
        page: "content/Assumptions/fake.md", section: nil,
        quote: "broken by [[XY99 - An attack on the fake assumption|XY99]]")
    static let honestMajority = Citation(
        page: "content/Primitives/mpc.md", section: "Honest Majority",
        quote: "exists unconditionally when $t < n/2$")
    static let bw07Statement = Citation(
        page: "content/Reductions/red-bdh-to-hve-bw07.md", section: "Statement",
        quote: "in composite-order bilinear groups")
    static let isisProof = Citation(
        page: "content/Reductions/red-isis-inhomogeneous-sis-to-sis.md", section: "Proof",
        quote: "SIS ⇒ ISIS is immediate")
    static let prpStatement = Citation(
        page: "content/Reductions/red-prp-to-invertible-prf.md", section: "Statement",
        quote: "is an invertible PRF for the traditional (forward-oracle) game")

    static let citations: [Key: [Citation]] = [
        .refuted(objectID: "fake"): [fakeAttack],
        .setting(objectID: "hm"): [honestMajority],
        .quarantine(relationID: "red-bdh-to-hve-bw07"): [bw07Statement],
        .equivalence(relationID: "red-isis-inhomogeneous-sis-to-sis"): [isisProof],
        bm84: [bm84Statement],
        kil88: [kil88Statement, otMalicious, dmo00Statement],
        .weakening(relationID: "red-prp-to-invertible-prf"): [prpStatement],
    ]

    static let requires: [DerivationCuration.Requirement] = [
        .init(relationID: "red-dlog-to-prg-bm84", isReverse: false, hypothesis: "dlog",
              notion: "DLOG hard in Z_p^* (p prime, g a generator)", metBy: []),
        .init(relationID: "red-ot-to-mpc-kil88", isReverse: false, hypothesis: "ot",
              notion: "OT secure against malicious parties (it instantiates Kil88's ideal OT)",
              metBy: ["red-cpir-to-ot-dmo00"]),
    ]

    static let weakens: [DerivationCuration.Weakening] = [
        .init(relationID: "red-prp-to-invertible-prf",
              notion: "an invertible PRF for the forward-oracle game only, over a "
                  + "super-polynomial domain",
              acceptedBy: ["red-invertible-prfs-to-prf"]),
    ]

    static let curation = DerivationCuration(
        refuted: [.init(objectID: "fake", source: "XY99", text: "XY99 breaks the fake assumption.",
                        evidence: "The attack, on its page.")],
        settings: [.init(objectID: "hm", text: "Honest majority is a corruption setting.",
                         evidence: "The MPC page.")],
        quarantine: ["red-bdh-to-hve-bw07": "Its Statement is in composite-order groups."],
        equivalences: [
            "red-isis-inhomogeneous-sis-to-sis": .init(forward: "unstated", reverse: "record"),
        ],
        requires: requires,
        weakens: weakens,
        citations: citations,
        reviewedCommit: reviewedCommit)

    static func manifest() throws -> RelationsManifest {
        typealias E = ExplorerFixture
        let objects: [[String: Any]] = [
            E.object("ddh", title: "Decisional Diffie-Hellman", type: "assumption"),
            E.object("cdh", title: "Computational Diffie-Hellman", type: "assumption"),
            E.object("dlog", title: "Discrete logarithm", type: "assumption"),
            E.object("pke", title: "Public key encryption"),
            E.object("owf", title: "One-way function"),
            E.object("prg", title: "Pseudorandom generator"),
            E.object("cpir", title: "Private Information Retrieval"),
            E.object("ot", title: "Oblivious transfer"),
            E.object("mpc", title: "Secure multi-party computation"),
            E.object("prp", title: "Pseudorandom permutation"),
            E.object("prf", title: "Pseudorandom function"),
            E.object("invertible-prfs", title: "Invertible PRFs", of: "prf"),
            E.object("ske", title: "Symmetric key encryption"),
            E.object("sis", title: "Shortest Integer Solution", type: "assumption"),
            E.object("isis", title: "ISIS (Inhomogeneous SIS)", type: "assumption", of: "sis",
                     anchor: "isis-inhomogeneous-sis"),
            E.object("crhf", title: "Collision-resistant hash function"),
            E.object("bdh", title: "Bilinear Diffie-Hellman", type: "assumption"),
            E.object("hve", title: "Hidden vector encryption"),
            E.object("fake", title: "Fake assumption", type: "assumption"),
            E.object("hm", title: "Honest majority"),
            E.object("z", title: "Zeta"),
        ]
        var kilian = E.reduction("red-ot-to-mpc-kil88", ["ot"], "mpc", title: "OT ⇒ MPC",
                                 source: "Kil88")
        kilian["source"] = ["Kil88", "GMW87"]
        let reductions: [[String: Any]] = [
            E.reduction("red-ddh-to-cdh", ["ddh"], "cdh", title: "DDH ⇒ CDH", source: "folklore"),
            E.reduction("red-cdh-to-dlog", ["cdh"], "dlog", title: "CDH ⇒ DLOG", source: "folklore"),
            E.reduction("red-dlog-to-prg-bm84", ["dlog"], "prg", title: "DLOG ⇒ PRG", source: "BM84"),
            E.reduction("red-ddh-to-pke", ["ddh"], "pke", title: "DDH ⇒ PKE (ElGamal)", source: "ElG85"),
            E.reduction("red-pke-to-owf", ["pke"], "owf", title: "PKE ⇒ OWF", source: "folklore"),
            E.reduction("red-owf-to-prg", ["owf"], "prg", title: "OWF ⇒ PRG", source: "HILL99"),
            E.reduction("red-ddh-to-cpir", ["ddh"], "cpir", title: "DDH ⇒ cPIR", source: "KO97"),
            E.reduction("red-cpir-to-ot-dmo00", ["cpir"], "ot", title: "cPIR ⇒ OT", source: "DMO00"),
            kilian,
            E.reduction("red-prp-to-invertible-prf", ["prp"], "invertible-prfs", title: "PRP ⇒ iPRF",
                        source: "folklore"),
            E.reduction("red-invertible-prfs-to-prf", ["invertible-prfs"], "prf", title: "iPRF ⇒ PRF",
                        source: "folklore"),
            E.reduction("red-invertible-prfs-to-ske", ["invertible-prfs"], "ske", title: "iPRF ⇒ SKE",
                        source: "folklore"),
            E.reduction("red-isis-inhomogeneous-sis-to-sis", ["isis"], "sis", title: "ISIS ⇔ SIS",
                        source: "folklore", kind: "equivalence"),
            E.reduction("red-sis-to-crhf", ["sis"], "crhf", title: "SIS ⇒ CRHF", source: "Ajt96"),
            E.reduction("red-bdh-to-hve-bw07", ["bdh"], "hve", title: "BDH ⇒ HVE", source: "BW07"),
            E.reduction("red-fake-to-pke", ["fake"], "pke", title: "Fake ⇒ PKE", source: "XY99"),
            E.reduction("red-hm-to-mpc", ["hm"], "mpc", title: "Honest majority ⇒ MPC", source: "BGW88"),
            E.reduction("red-crhf-mpc-prf-to-z", ["crhf", "mpc", "prf"], "z",
                        title: "CRHF + MPC + PRF ⇒ Z", source: "Z26"),
        ]
        return try E.manifest(objects: objects, reductions: reductions)
    }

    static func derivation(
        curation: DerivationCuration = AdjustmentsFixture.curation
    ) throws -> Derivation {
        Derivation(manifest: try manifest(), curation: curation)
    }

    /// A one-step answer beside a stronger chain, each shaped by its own
    /// entry. A ⇒ T is the reverse of T ⇔ A, whose record's class covers the
    /// other direction only; the fully black-box A ⇒ Y ⇒ T needs Y in full,
    /// which A ⇒ Y gives. Either entry can be left out.
    static func strongerDerivation(equivalence: Bool = true,
                                   requirement: Bool = true) throws -> Derivation {
        typealias E = ExplorerFixture
        let objects: [[String: Any]] = [
            E.object("a", title: "Alpha"), E.object("t", title: "Tau"), E.object("y", title: "Upsilon"),
        ]
        let reductions: [[String: Any]] = [
            E.reduction("red-t-eq-a", ["t"], "a", title: "T ⇔ A", source: "TA05", kind: "equivalence"),
            E.reduction("red-a-to-y", ["a"], "y", title: "A ⇒ Y", source: "AY06"),
            E.reduction("red-y-to-t", ["y"], "t", title: "Y ⇒ T", source: "YT07"),
        ]
        var equivalences: [String: DerivationCuration.Directions] = [:]
        if equivalence {
            equivalences["red-t-eq-a"] = DerivationCuration.Directions(forward: "record",
                                                                       reverse: "unstated")
        }
        var requires: [DerivationCuration.Requirement] = []
        if requirement {
            requires.append(DerivationCuration.Requirement(
                relationID: "red-y-to-t", isReverse: false, hypothesis: "y", notion: "y in full",
                metBy: ["red-a-to-y"]))
        }
        let curation = DerivationCuration(equivalences: equivalences, requires: requires)
        return Derivation(manifest: try E.manifest(objects: objects, reductions: reductions),
                          curation: curation)
    }
}

extension Derivation.Answer {
    /// The derived answer, if this is one.
    var derivedAnswer: Derivation.DerivedAnswer? {
        if case .derived(let answer) = self { return answer }
        return nil
    }
}
