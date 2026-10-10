import Foundation
import Testing
@testable import CCwiki

/// What the explorer says for a question: the honesty contract of
/// relations-explorer.md §1, held without a view. Every expected depth and
/// proof here is the reference engine's answer on the same fixture
/// (`scripts/derivations_reference.py --query`).
struct ExplorerResultTests {

    private static func compute(_ query: ExplorerQuery) throws -> ExplorerResult {
        let derivation = try ExplorerFixture.derivation()
        return ExplorerResult.compute(query, derivation: derivation,
                                      labels: ExplorerFixture.labels(derivation.manifest))
    }

    /// Every sentence the result shows or copies, but the footer.
    private static func texts(_ result: ExplorerResult) -> [String] {
        var texts: [String] = []
        if let verdict = result.verdict {
            texts.append(verdict.title)
            if let statement = verdict.statement { texts.append(statement) }
            for line in verdict.lines { texts.append(line.text) }
            if let action = verdict.action { texts.append(action.title) }
        }
        for section in result.sections {
            let parts: [String?] = [section.title, section.subtitle, section.help, section.note]
            texts += parts.compactMap { $0 }
        }
        for row in result.allRows {
            let parts: [String?] = [row.title, row.qualifier, row.detail, row.help,
                                    row.accessibilityLabel, row.statement, row.action?.title]
            texts += parts.compactMap { $0 }
            texts += row.notes
        }
        return texts
    }

    // MARK: A derivation

    @Test("a chain of two or more steps says derived by CCwiki from N recorded reductions, with ⇒*")
    func derivableVerdict() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf", "kem"], to: "pke"))
        let verdict = try #require(result.verdict)
        #expect(result.state == .answer)
        #expect(verdict.title == "Derivable")
        #expect(verdict.statement == "Hash function § Preimage resistance (one-wayness) ∧ "
            + "Key encapsulation mechanism ⇒* Public key encryption")
        let lines = verdict.lines.map { $0.text }
        #expect(lines.first == "Derived by CCwiki from 4 recorded reductions · 4 steps")
        #expect(lines.contains("Fully black-box: every step is"))
        #expect(result.footer == DerivationWording.derivedFooter)
        #expect(result.explainsRules)
        #expect(result.announcement == "Derivable in 4 steps")
    }

    @Test("the proof is an outline of whole steps, expanded, its root the answer's object")
    func proofOutline() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf", "kem"], to: "pke"))
        let proof = try #require(result.sections.first)
        #expect(proof.id == "proof")
        let root = try #require(proof.rows.first)
        #expect(root.title == "Public key encryption")
        #expect(root.emphasis == .strong)
        #expect(root.detail == "⇐ KEM + SKE ⇒ PKE · CS03 · fully black-box · needs both")
        let children = root.children.map { $0.title }
        #expect(children == ["Key encapsulation mechanism", "Symmetric key encryption"])
        let badges = root.children.map { $0.badge }
        #expect(badges == ["given", nil])
        #expect(result.initiallyCollapsed.isEmpty)
    }

    @Test("Copy Proof as Text is headed by the statement and where it came from")
    func proofCopy() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf", "kem"], to: "pke"))
        let root = try #require(result.sections.first?.rows.first)
        let copy = try #require(root.proof)
        let text = copy.text(revision: "0123456789abcdef")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 8)
        #expect(lines[0].hasSuffix("⇒* Public key encryption"))
        #expect(lines[1] == "Derived by CCwiki from 4 recorded reductions (relations.json at 0123456789ab)")
        #expect(lines[2] == "Public key encryption ⇐ KEM + SKE ⇒ PKE [CS03; fully black-box; standard model]")
        #expect(lines[3] == "  Key encapsulation mechanism (given)")
    }

    // MARK: One recorded step

    @Test("one reduction is the wiki's own result: Recorded, ⇒, and never derived")
    func recordedResult() throws {
        let result = try Self.compute(ExplorerQuery(from: ["kem", "ske"], to: "pke"))
        let verdict = try #require(result.verdict)
        #expect(verdict.title == "Recorded in the wiki")
        #expect(verdict.statement == "Key encapsulation mechanism ∧ Symmetric key encryption ⇒ "
            + "Public key encryption")
        let first = verdict.lines.first?.text
        #expect(first == "A result the wiki records: CS03: KEM + SKE ⇒ PKE")
        #expect(result.footer == DerivationWording.recordedFooter)
        #expect(result.announcement == "Recorded in the wiki")

        var shown = Self.texts(result)
        if let footer = result.footer { shown.append(footer) }
        for text in shown {
            #expect(!text.lowercased().contains("derived"), "\(text)")
            #expect(!text.contains("⇒*"), "\(text)")
        }
    }

    @Test("the second and third premises of a three-premise step carry ∧")
    func conjunctionMarkers() throws {
        let result = try Self.compute(ExplorerQuery(from: ["a", "b", "c"], to: "d"))
        let root = try #require(result.sections.first?.rows.first)
        let titles = root.children.map { $0.title }
        let conjuncts = root.children.map { $0.conjunct }
        #expect(titles == ["Alpha", "Beta", "Gamma"])
        #expect(conjuncts == [false, true, true])
        #expect(root.conjunct == false)
        #expect(root.detail?.contains("needs all 3") == true)
    }

    @Test("a target among the premises is given back, with no proof and no footer")
    func givenBack() throws {
        let result = try Self.compute(ExplorerQuery(from: ["kem", "pke"], to: "pke"))
        let verdict = try #require(result.verdict)
        #expect(verdict.title == "One of your premises")
        #expect(result.sections.isEmpty)
        #expect(result.footer == nil)
    }

    // MARK: No derivation

    @Test("no derivation is never worded as a separation, and always carries R10's footer")
    func noDerivationWording() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf"], to: "pke"))
        let verdict = try #require(result.verdict)
        #expect(verdict.title == "No derivation found")
        #expect(verdict.tone == .noDerivation)
        let sentence = verdict.lines.first?.text
        #expect(sentence == "CCwiki finds no chain of the wiki's recorded reductions from Hash "
            + "function § Preimage resistance (one-wayness) to Public key encryption in the "
            + "standard, quantum or CRS models.")
        #expect(result.footer == Derivation.NoPathAnswer.footer)
        #expect(result.footer?.contains("This is not a separation") == true)

        for text in Self.texts(result) {
            let lowered = text.lowercased()
            #expect(!lowered.contains("does not imply"), "\(text)")
            #expect(!text.contains("⇏"), "\(text)")
            #expect(!lowered.contains("separat"), "\(text)")
            #expect(!lowered.contains("impossible"), "\(text)")
        }
    }

    @Test("a no-derivation answer lists the recorded barrier, then what to add, in R10's order")
    func noDerivationSections() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf"], to: "pke"))
        let ids = result.sections.map { $0.id }
        #expect(ids == ["barriers", "completions"])

        let barrier = try #require(result.sections.first?.rows.first)
        #expect(barrier.glyph == .barrier)
        #expect(barrier.title == "No relativizing reduction from OWF to PKE")
        #expect(barrier.detail == "against relativizing reductions · unconditional · IR89")

        let completion = try #require(result.sections.last?.rows.first)
        #expect(completion.title == "Key encapsulation mechanism")
        #expect(completion.action == ExplorerRow.Action(title: "Add", command: .add("kem")))
        #expect(completion.detail?.hasPrefix("4 steps") == true)
    }

    @Test("a model given with the toggle off is explained in R4's words, with the toggle offered")
    func modelStart() throws {
        let result = try Self.compute(ExplorerQuery(from: ["rom"], to: "oihf"))
        let verdict = try #require(result.verdict)
        let first = verdict.lines.first?.text
        #expect(first == "The random oracle model is a model, not an assumption. What the wiki "
            + "proves in it appears with idealised models included.")
        #expect(verdict.action?.command == .includeIdealisedModels)
        let ids = result.sections.map { $0.id }
        #expect(ids == ["onPair", "idealised"])
        let onPair = try #require(result.sections.first?.rows.first)
        #expect(onPair.detail?.contains("used only with idealised models included") == true)
    }

    @Test("a step R5 refuses is explained, never shown as a fact")
    func refusedStep() throws {
        let result = try Self.compute(
            ExplorerQuery(from: ["rom"], to: "ot", includesIdealisedModels: true))
        let found = result.sections.first { $0.id == "refused" }
        let refused = try #require(found)
        let row = try #require(refused.rows.first)
        #expect(row.title == "Not derived: Oblivious interactive hash function holds here only in "
            + "the random oracle model, and Oblivious interactive hash function ⇒ Oblivious "
            + "transfer (BH26) is a free (non-black-box) step, which need not carry over into "
            + "that model.")
    }

    @Test("a complexity class in the question is turned away, never derived")
    func unsupportedClass() throws {
        let result = try Self.compute(ExplorerQuery(from: ["lwe"], to: "bpp"))
        #expect(result.state == .unsupported("Bounded-error probabilistic polynomial time"))
        #expect(result.verdict == nil)
    }

    @Test("an object the wiki no longer has is ignored, and the verdict says so")
    func staleObjectIgnored() throws {
        let result = try Self.compute(ExplorerQuery(from: ["gone", "kem", "ske"], to: "pke"))
        #expect(result.ignored == ["gone"])
        let verdict = try #require(result.verdict)
        #expect(verdict.title == "Recorded in the wiki")
        let last = verdict.lines.last
        #expect(last?.id == "ignored")
        #expect(last?.text == "1 object ignored: not in the wiki any more.")
    }

    // MARK: Everything from, everything to

    @Test("forward: one section per depth, recorded results first, each row collapsed")
    func forward() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf"]))
        let verdict = try #require(result.verdict)
        #expect(verdict.title == "Derivable from Hash function § Preimage resistance (one-wayness)")
        let count = verdict.lines.first?.text
        #expect(count == "3 objects · 1-step rows are recorded results; the rest are derived by CCwiki.")
        let titles = result.sections.map { $0.title }
        #expect(titles == ["Recorded (1 step)", "2 steps", "3 steps"])
        let firstRow = try #require(result.sections.first?.rows.first)
        #expect(firstRow.title == "Pseudorandom generator")
        #expect(firstRow.badge == "recorded")
        #expect(firstRow.startsCollapsed)
        #expect(result.initiallyCollapsed.contains(firstRow.id))
        #expect(result.footer == DerivationWording.listFooter)
    }

    @Test("forward from a model with the toggle off derives nothing, and says why")
    func forwardFromModel() throws {
        let result = try Self.compute(ExplorerQuery(from: ["rom"]))
        guard case .nothing(let title, let description) = result.state else {
            Issue.record("expected an empty state, got \(result.state)")
            return
        }
        #expect(title == "Nothing Derived")
        #expect(description.hasPrefix("The random oracle model is a model, not an assumption."))
        #expect(result.offersIdealisedModels)
    }

    @Test("backward: single sources by depth, the depth-1 one marked recorded")
    func backwardSingles() throws {
        let result = try Self.compute(ExplorerQuery(to: "ske"))
        let verdict = try #require(result.verdict)
        #expect(verdict.title == "Everything the wiki's reductions derive this from")
        #expect(verdict.help == "Derived by CCwiki. The wiki's record is incomplete.")
        let singles = try #require(result.sections.first)
        #expect(singles.title == "On its own")
        let titles = singles.rows.map { $0.title }
        let badges = singles.rows.map { $0.badge }
        #expect(titles == ["Pseudorandom function", "Pseudorandom generator",
                           "Hash function § Preimage resistance (one-wayness)",
                           "Hash function § Collision resistance"])
        #expect(badges == ["recorded", "2 steps", "3 steps", "4 steps"])
        // Each disclosed to its proof, rooted at the target.
        let proofRoot = try #require(singles.rows.last?.children.first)
        #expect(proofRoot.title == "Symmetric key encryption")
    }

    @Test("backward: pairs are grouped by the edge where they meet, one row per pair")
    func backwardPairs() throws {
        let result = try Self.compute(ExplorerQuery(to: "pke"))
        let ids = result.sections.map { $0.id }
        #expect(ids == ["singles", "pairs", "group/red-kem-and-ske-to-pke"])
        let group = try #require(result.sections.last)
        #expect(group.title == "Through Key encapsulation mechanism ∧ Symmetric key encryption ⇒ "
            + "Public key encryption")
        #expect(group.subtitle == "CS03 · 5 pairs")
        let first = try #require(group.rows.first)
        #expect(first.title == "Hash function § Collision resistance ∧ Key encapsulation mechanism")
        #expect(first.ask == ExplorerQuery(from: ["crhf", "kem"], to: "pke"))
        let verdict = try #require(result.verdict)
        let lines = verdict.lines.map { $0.text }
        #expect(lines.first == "1 object alone · 5 pairs")

        // Never "needs both", "minimal" or "neither alone" (R11).
        for text in Self.texts(result) {
            let lowered = text.lowercased()
            #expect(!lowered.contains("needs both"), "\(text)")
            #expect(!lowered.contains("minimal"), "\(text)")
            #expect(!lowered.contains("neither alone"), "\(text)")
        }
    }

    @Test("every outcome but a premise given back carries a footer")
    func footers() throws {
        let queries = [
            ExplorerQuery(from: ["owf", "kem"], to: "pke"),
            ExplorerQuery(from: ["kem", "ske"], to: "pke"),
            ExplorerQuery(from: ["owf"], to: "pke"),
            ExplorerQuery(from: ["owf"]),
            ExplorerQuery(to: "pke"),
        ]
        for query in queries {
            let result = try Self.compute(query)
            #expect(result.footer != nil, "\(query)")
        }
        let given = try Self.compute(ExplorerQuery(from: ["pke"], to: "pke"))
        #expect(given.footer == nil)
    }

    @Test("rows are found by id wherever they are nested, with what encloses them")
    func findingRows() throws {
        let result = try Self.compute(ExplorerQuery(from: ["owf", "kem"], to: "pke"))
        let deepest = try #require(result.allRows.last)
        let found = result.row(withID: deepest.id)
        #expect(found?.title == deepest.title)
        let ancestors = result.ancestors(of: deepest.id)
        #expect(ancestors.first == "proof/0")
        #expect(ancestors.count == 4)
    }
}
