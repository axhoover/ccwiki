import Foundation
import Testing
@testable import CCwiki

/// Fixes to the derivation engine and the text it writes: a requirement met
/// by any `metBy` producer that fires (R13), whole-word TeX commands in the
/// chrome's plain text, the inspector's Copy Statement keeping its
/// condition, and the LaTeX copy's macro line. Every engine expectation here
/// was first computed by the reference engine,
/// `scripts/derivations_reference.py`, on the same fixture.
@Suite struct FixesRelationsTests {

    private typealias E = ExplorerFixture

    // MARK: R13: a requirement met by any metBy producer

    /// `a ⇒ b ⇒ h` by B ⇒ H, which `metBy` names for H ⇒ T; `z ⇒ h` too, by
    /// Z ⇒ H, which it does not. `h ⇒ u`, and `u ∧ t ⇒ w`.
    private static func established() throws -> Derivation {
        let objects = ["a", "b", "h", "z", "t", "u", "w"].map { E.object($0, title: $0.uppercased()) }
        let reductions: [[String: Any]] = [
            E.reduction("red-a-to-b", ["a"], "b", title: "A ⇒ B", source: "AB01"),
            E.reduction("red-b-to-h", ["b"], "h", title: "B ⇒ H", source: "BH02"),
            E.reduction("red-z-to-h", ["z"], "h", title: "Z ⇒ H", source: "ZH03"),
            E.reduction("red-h-to-t", ["h"], "t", title: "H ⇒ T", source: "HT04"),
            E.reduction("red-h-to-u", ["h"], "u", title: "H ⇒ U", source: "HU05"),
            E.reduction("red-u-and-t-to-w", ["u", "t"], "w", title: "U + T ⇒ W", source: "UTW06"),
        ]
        let requirement = DerivationCuration.Requirement(
            relationID: "red-h-to-t", isReverse: false, hypothesis: "h", notion: "h in full",
            metBy: ["red-b-to-h"])
        return Derivation(manifest: try E.manifest(objects: objects, reductions: reductions),
                          curation: DerivationCuration(requires: [requirement]))
    }

    private static let producer = Derivation.StepKey(relationID: "red-b-to-h", isReverse: false)

    @Test("a requirement is met by a metBy producer that fires after another producer gave the fact")
    func metByAnotherProducer() throws {
        let derivation = try Self.established()
        // Z ⇒ H gives H at layer 1 and B ⇒ H only at layer 2; H's one fact
        // is Z ⇒ H's, and B ⇒ H's is kept apart for H ⇒ T.
        let closure = derivation.closure(from: ["a", "z"], options: .standard)
        #expect(closure.facts["h"]?.step?.relationID == "red-z-to-h")
        #expect(closure.established[Self.producer]?.depth == 2)
        let fact = try #require(closure.facts["t"])
        #expect(fact.depth == 3)
        #expect(fact.assumes.isEmpty)
        #expect(fact.establishedInputs == ["h": Self.producer])

        // The proof walks to the fact that met the requirement.
        let proof = try #require(closure.proof(of: "t"))
        #expect(proof.relationIDs == ["red-a-to-b", "red-b-to-h", "red-h-to-t"])
        #expect(proof.rows.map { $0.objectID } == ["t", "h", "b", "a"])
        #expect(proof.rows.map { $0.step?.relationID } == ["red-h-to-t", "red-b-to-h", "red-a-to-b", nil])
        #expect(proof.rows.map { $0.establishedBy } == [nil, Self.producer, nil, nil])

        // Adding a start never takes a derivation away.
        #expect(derivation.closure(from: ["a"], options: .standard).facts["t"] != nil)
        #expect(derivation.closure(from: ["z"], options: .standard).facts["t"] == nil)
    }

    @Test("nothing is assumed of a given whose requirement a metBy producer meets")
    func metByInsteadOfAssumed() throws {
        let derivation = try Self.established()
        let clean = try #require(derivation.closure(from: ["a", "h"], options: .standard).facts["t"])
        #expect(clean.depth == 3)
        #expect(clean.assumes.isEmpty)
        // With nothing to establish it, the given is still assumed.
        let assumed = try #require(derivation.closure(from: ["h"], options: .standard).facts["t"])
        #expect(assumed.depth == 1)
        #expect(assumed.assumes.map { $0.notion } == ["h in full"])
    }

    @Test("a proof with a node's own fact and a producer's established one keeps them apart")
    func bothFactsInOneProof() throws {
        let derivation = try Self.established()
        let closure = derivation.closure(from: ["a", "z"], options: .standard)
        let fact = try #require(closure.facts["w"])
        let proof = try #require(closure.proof(of: "w"))
        let rows = proof.rows.filter { $0.objectID == "h" }
        #expect(rows.map { $0.step?.relationID } == ["red-z-to-h", "red-b-to-h"])
        #expect(rows.map { $0.isReference } == [false, false])

        // The copy names the step that met the precondition, not the one that
        // gave H first in the tree.
        let export = ProofExport(
            proof: proof, start: ["a", "z"], target: "w", depth: fact.depth,
            chainClass: fact.chainClass, unstatedSteps: 0, refutations: [],
            manifest: derivation.manifest)
        #expect(export.steps.map { $0.relationID } == [
            "red-z-to-h", "red-h-to-u", "red-a-to-b", "red-b-to-h", "red-h-to-t", "red-u-and-t-to-w",
        ])
        let consumer = try #require(export.steps.first { $0.relationID == "red-h-to-t" })
        #expect(consumer.established.map { $0.producer } == ["red-b-to-h"])
        #expect(consumer.assumed.isEmpty)
    }

    /// `established()` with a second consumer of B ⇒ H's fact: `h ⇒ v`,
    /// which needs it too, and `u ∧ t ∧ v ⇒ w`.
    private static func establishedTwice() throws -> Derivation {
        let objects = ["a", "b", "h", "z", "t", "u", "v", "w"].map { E.object($0, title: $0.uppercased()) }
        let reductions: [[String: Any]] = [
            E.reduction("red-a-to-b", ["a"], "b", title: "A ⇒ B", source: "AB01"),
            E.reduction("red-b-to-h", ["b"], "h", title: "B ⇒ H", source: "BH02"),
            E.reduction("red-z-to-h", ["z"], "h", title: "Z ⇒ H", source: "ZH03"),
            E.reduction("red-h-to-t", ["h"], "t", title: "H ⇒ T", source: "HT04"),
            E.reduction("red-h-to-u", ["h"], "u", title: "H ⇒ U", source: "HU05"),
            E.reduction("red-h-to-v", ["h"], "v", title: "H ⇒ V", source: "HV06"),
            E.reduction("red-u-t-and-v-to-w", ["u", "t", "v"], "w", title: "U + T + V ⇒ W",
                        source: "UTVW07"),
        ]
        let requirements = ["red-h-to-t", "red-h-to-v"].map {
            DerivationCuration.Requirement(
                relationID: $0, isReverse: false, hypothesis: "h", notion: "h in full",
                metBy: ["red-b-to-h"])
        }
        return Derivation(manifest: try E.manifest(objects: objects, reductions: reductions),
                          curation: DerivationCuration(requires: requirements))
    }

    @Test("a second use of a producer's established fact leads to that fact, not the node's own")
    func establishedFactShownAbove() throws {
        let derivation = try Self.establishedTwice()
        let closure = derivation.closure(from: ["a", "z"], options: .standard)
        let proof = try #require(closure.proof(of: "w"))
        // The reference engine's tree: H ⇒ V's H is "shown above", at B ⇒ H's.
        #expect(proof.rows.map { $0.objectID } == ["w", "u", "h", "z", "t", "h", "b", "a", "v", "h"])
        #expect(proof.rows.map { $0.isReference }
            == [false, false, false, false, false, false, false, false, false, true])
        #expect(proof.rows.map { $0.establishedBy }
            == [nil, nil, nil, nil, nil, Self.producer, nil, nil, nil, Self.producer])

        let writer = ExplorerWriter(derivation: derivation, labels: E.labels(derivation.manifest))
        let outline = ProofOutline.rows(proof, idPrefix: "p", writer: writer)
        let v = try #require(outline.first?.children.last)
        #expect(v.children.first?.primary == .reveal("p/5"), "B ⇒ H's H, not Z ⇒ H's at p/2")

        let trace = CurationTrace.derived(
            proof, other: nil, closure: closure, start: ["a", "z"], derivation: derivation)
        let effects = trace.items.flatMap { $0.effects }
        #expect(effects.contains(.establishedBy(
            relationID: "red-h-to-v", isReverse: false, hypothesis: "h", producer: "red-b-to-h")))
        let producers = effects.compactMap { effect -> String? in
            if case .establishedBy(_, _, _, let producer) = effect { return producer }
            return nil
        }
        #expect(Set(producers) == ["red-b-to-h"], "never Z ⇒ H, which met no precondition")
    }

    // MARK: Plain text: whole-word commands

    @Test("a command is reduced whole, never as a shorter command and some letters")
    func wholeWordCommands() {
        #expect(RelationText.plain("$x^e \\equiv y \\pmod{n}$") == "x^e ≡ y mod n")
        #expect(RelationText.plain("$k \\gets \\KeyGen(1^\\secpar)$") == "k ← KeyGen(1^λ)")
        #expect(RelationText.plain("$x_1, \\cdots, x_n$") == "x_1, …, x_n")
        #expect(RelationText.plain("$\\textit{Enc}$ and $\\textbf{Dec}$") == "Enc and Dec")
        #expect(RelationText.plain("$a \\leftarrow b \\leftrightarrow c \\top \\int$")
            == "a ← b ↔ c top int")
        #expect(RelationText.plain("$\\left( x \\right)$") == "( x )")
        // Unknown commands keep their letters, as the type's doc says.
        #expect(RelationText.plain("$\\indcpa$") == "indcpa")
    }

    @Test("braces that are text survive the pass that deletes grouping braces")
    func literalBraces() {
        #expect(RelationText.plain("$b \\getsr \\bits$") == "b ←$ {0,1}")
        #expect(RelationText.plain("$f: \\{0, 1\\}^n \\rightarrow G$") == "f: {0, 1}^n → G")
        // A preview card reads math through `plain`.
        #expect(PreviewExcerpt.plainText("sample $s \\getsr \\bits^n$ once")
            == "sample s ←$ {0,1}^n once")
        // The symbols the table gained go back into math in a LaTeX copy.
        #expect(TeXText.escape("x ← y ≡ z", macros: .empty) == #"x $\gets$ y $\equiv$ z"#)
    }

    // MARK: The inspector's Copy Statement

    /// `g ⇒ h ⇒ k`, where G ⇒ H needs g in its strong regime, which only
    /// assuming it of the given meets.
    private static func assumedDerivation() throws -> Derivation {
        let objects: [[String: Any]] = [
            E.object("g", title: "Gamma", type: "assumption"),
            E.object("h", title: "Eta"), E.object("k", title: "Kappa"),
        ]
        let reductions: [[String: Any]] = [
            E.reduction("red-g-to-h", ["g"], "h", title: "G ⇒ H", source: "GH01"),
            E.reduction("red-h-to-k", ["h"], "k", title: "H ⇒ K", source: "HK02"),
        ]
        let requirement = DerivationCuration.Requirement(
            relationID: "red-g-to-h", isReverse: false, hypothesis: "g",
            notion: "g in its strong regime", metBy: [])
        return Derivation(manifest: try E.manifest(objects: objects, reductions: reductions),
                          curation: DerivationCuration(requires: [requirement]))
    }

    @Test("an inspector row's statement, tooltip and label keep its assumption")
    func assumedRow() throws {
        let derivation = try Self.assumedDerivation()
        let manifest = derivation.manifest
        let page = PageDerivations(path: "Assumptions/g.md", manifest: manifest,
                                   derivation: derivation, labels: E.labels(manifest))
        let block = try #require(page.blocks(.implies).first)
        #expect(block.groups.map { $0.heading } == ["Assuming g in its strong regime"])
        let row = try #require(block.rows.first)
        #expect(row.statement == "Gamma ⇒* Kappa (derived by CCwiki from 2 recorded reductions, "
            + "assuming g in its strong regime)")
        #expect(row.help.components(separatedBy: "\n") == [
            "Gamma ⇒* Kappa",
            "Derived by CCwiki from 2 recorded reductions; 2 steps.",
            "Assuming g in its strong regime",
            "Fully black-box: every step is",
            "Click to see the proof.",
        ])
        #expect(row.accessibilityLabel == "Kappa, derived in 2 steps, assuming g in its strong regime")
    }

    @Test("the explorer's Copy Statement keeps the assumption, on list rows and on the proof")
    func explorerStatementAssumed() throws {
        let derivation = try Self.assumedDerivation()
        let labels = E.labels(derivation.manifest)
        let assuming = ", assuming g in its strong regime)"

        let forward = ExplorerResult.compute(
            ExplorerQuery(from: ["g"]), derivation: derivation, labels: labels)
        let statements = forward.allRows.compactMap { $0.statement }
        #expect(statements.contains("Gamma ⇒ Eta (recorded in the wiki: GH01" + assuming))
        #expect(statements.contains(
            "Gamma ⇒* Kappa (derived by CCwiki from 2 recorded reductions" + assuming))

        let answer = ExplorerResult.compute(
            ExplorerQuery(from: ["g"], to: "k"), derivation: derivation, labels: labels)
        let root = try #require(answer.sections.first { $0.id == "proof" }?.rows.first)
        #expect(root.statement
            == "Gamma ⇒* Kappa (derived by CCwiki from 2 recorded reductions" + assuming)
    }

    @Test("R6's stronger proof states only what its own steps assume")
    func strongerStatementAssumesLess() throws {
        // Shortest: g ⇒ m, then m ∧ h ⇒ k, unstated, assuming of both
        // givens. Stronger: g ⇒ m ⇒ n ⇒ k, fully black-box, assuming of g
        // only. The reference engine gives the same two.
        let objects: [[String: Any]] = [
            E.object("g", title: "Gamma", type: "assumption"),
            E.object("h", title: "Eta", type: "assumption"),
            E.object("m", title: "Mu"), E.object("n", title: "Nu"), E.object("k", title: "Kappa"),
        ]
        let reductions: [[String: Any]] = [
            E.reduction("red-g-to-m", ["g"], "m", title: "G ⇒ M", source: "GM01"),
            E.reduction("red-mh-to-k", ["m", "h"], "k", title: "M + H ⇒ K", source: "MHK02",
                        reductionClass: "unstated"),
            E.reduction("red-m-to-n", ["m"], "n", title: "M ⇒ N", source: "MN03"),
            E.reduction("red-n-to-k", ["n"], "k", title: "N ⇒ K", source: "NK04"),
        ]
        let requirements = [
            DerivationCuration.Requirement(
                relationID: "red-g-to-m", isReverse: false, hypothesis: "g",
                notion: "g in its strong regime", metBy: []),
            DerivationCuration.Requirement(
                relationID: "red-mh-to-k", isReverse: false, hypothesis: "h",
                notion: "h in its strong regime", metBy: []),
        ]
        let derivation = Derivation(
            manifest: try E.manifest(objects: objects, reductions: reductions),
            curation: DerivationCuration(requires: requirements))
        let result = ExplorerResult.compute(
            ExplorerQuery(from: ["g", "h"], to: "k"), derivation: derivation,
            labels: E.labels(derivation.manifest))

        let shortest = try #require(result.sections.first { $0.id == "proof" }?.rows.first)
        #expect(shortest.statement == "Gamma ∧ Eta ⇒* Kappa (derived by CCwiki from 2 recorded "
            + "reductions, assuming g in its strong regime; h in its strong regime)")
        let stronger = try #require(result.sections(showingStronger: true)
            .first { $0.id == "proof" }?.rows.first)
        #expect(stronger.statement == "Gamma ∧ Eta ⇒* Kappa (derived by CCwiki from 3 recorded "
            + "reductions, assuming g in its strong regime)")
    }

    @Test("an inspector row's statement and tooltip say a weakened conclusion is only that")
    func weakenedRow() throws {
        let objects: [[String: Any]] = [
            E.object("s", title: "Sigma"), E.object("x", title: "Xi"), E.object("w", title: "Omega"),
        ]
        let reductions: [[String: Any]] = [
            E.reduction("red-s-to-x", ["s"], "x", title: "S ⇒ X", source: "SX01"),
            E.reduction("red-x-to-w", ["x"], "w", title: "X ⇒ W", source: "XW02"),
        ]
        let weakening = DerivationCuration.Weakening(
            relationID: "red-x-to-w", notion: "selective w", acceptedBy: [])
        let manifest = try E.manifest(objects: objects, reductions: reductions)
        let derivation = Derivation(manifest: manifest,
                                    curation: DerivationCuration(weakens: [weakening]))
        let page = PageDerivations(path: "Primitives/s.md", manifest: manifest,
                                   derivation: derivation, labels: E.labels(manifest))
        let row = try #require(page.blocks(.implies).first?.rows.first)
        #expect(row.weakening == "only selective w")
        #expect(row.statement == "Sigma ⇒* Omega (derived by CCwiki from 2 recorded reductions, "
            + "only selective w)")
        #expect(row.help.components(separatedBy: "\n").dropFirst(2).first == "Only selective w")
        #expect(row.accessibilityLabel == "Omega, derived in 2 steps, only selective w")
    }

    // MARK: The LaTeX copy's macro line

    @Test("the LaTeX copy says its math has no wiki macros only when the table loaded")
    func latexMacroLine() throws {
        let derivation = try ProofExportTests.derivation()
        let copy = try #require(ProofExportTests.copy(["owf", "kem"], "pke", over: derivation))
        let noMacros = "% Math uses no cryptology.city macros."
        let unavailable = "% Math may use cryptology.city macros, which are not written out: "
            + "CCwiki could not read them from macros.ts."

        let loaded = MacroTable(macros: [#"\ZZ"#: #"\mathbb{Z}"#], diagnostic: nil)
        let read = ProofLaTeX.write(copy.export, context: ProofExportTests.context(
            derivation, index: nil, macros: loaded))
        #expect(read.components(separatedBy: "\n").contains(noMacros))

        // Missing, unreadable and unparsed all leave the table empty.
        for failed in [MacroTable.empty, MacroTable.parse("export const other = 1;")] {
            let latex = ProofLaTeX.write(copy.export, context: ProofExportTests.context(
                derivation, index: nil, macros: failed))
            let lines = latex.components(separatedBy: "\n")
            #expect(!lines.contains(noMacros))
            #expect(lines.contains(unavailable))
        }
    }
}
