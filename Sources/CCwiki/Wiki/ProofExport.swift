import Foundation

/// What a copy command puts on the pasteboard (plans/relations-followups.md
/// §3). `bibtex` is the cited works, not the proof.
enum ProofFormat: String, CaseIterable, Sendable {
    case text, latex, wikiMarkdown, bibtex

    /// The forms of the proof itself, in the order "Copy Proof As" lists
    /// them.
    static let proofForms: [ProofFormat] = [.text, .latex, .wikiMarkdown]

    /// How "Copy Proof As" names the form.
    var title: String {
        switch self {
        case .text: "Text"
        case .latex: "LaTeX"
        case .wikiMarkdown: "Wiki Markdown"
        case .bibtex: "BibTeX of Cited Works"
        }
    }
}

/// A proof in the order a paper argues it: every step after the steps that
/// give its hypotheses (§3.2).
///
/// The engine's proof tree is depth-first from the target (R7), which is how
/// the explorer draws it; a copy reads better bottom-up. So this folds the
/// flat rows into a tree, as `ProofOutline` does, and emits each step after
/// its hypotheses' steps, in the edge's order. Givens and "shown above"
/// references give no step, and each (reduction, direction) is kept once. A
/// conjunctive step stays one step with every hypothesis: the conjunction is
/// never split.
///
/// It carries everything the writers need to state where the proof came
/// from, and every one of those is this proof's own: a copy made with Show It
/// on states the stronger proof's N, depth, class and models, never the
/// shortest's.
struct ProofExport: Sendable, Hashable {

    /// One recorded reduction, used in one direction.
    struct Step: Sendable, Hashable {
        let relationID: String
        /// The whole conjunction, in the edge's order.
        let hypotheses: [String]
        let conclusion: String
        /// The backward direction of an equivalence.
        let isReverse: Bool
        /// Effective (R3, R4): `unknown` for a stub.
        let model: String
        /// Effective, per direction (R1, R3).
        let reductionClass: String
        let isStub: Bool
        /// The relation's `source`, as recorded: wikilinks, or `folklore`.
        let source: [String]
        /// R13: preconditions the proof assumes of a given.
        let assumed: [DerivationCuration.Requirement]
        /// R13: preconditions the step that gives the hypothesis establishes.
        let established: [Established]
        /// R13: this step concludes only a weaker notion.
        let weakening: DerivationCuration.Weakening?

        /// A precondition a producer met: the requirement, and the relation
        /// id of the step whose Statement establishes it (`metBy`).
        struct Established: Sendable, Hashable {
            let requirement: DerivationCuration.Requirement
            let producer: String
        }
    }

    let start: [String]
    let target: String
    /// Post-order, each (relation, direction) once.
    let steps: [Step]
    /// The N of "from N recorded reductions": distinct reductions, so an
    /// equivalence used both ways is two steps and one reduction.
    let relationCount: Int
    let depth: Int
    let chainClass: Derivation.ChainClass
    /// How many steps state no composable class, for "Class unstated: N
    /// steps do not state theirs".
    let unstatedSteps: Int
    /// The non-standard models its own steps use, sorted by
    /// `Derivation.precedes`.
    let models: [String]
    /// R14: refuted starts make the implication vacuous, and a copy says so
    /// where a reader of the paper will see it.
    let refutations: [DerivationCuration.Refutation]

    /// One step: the wiki's own result, not CCwiki's composition.
    var isRecordedResult: Bool { depth == 1 }

    /// `depth` and `chainClass` are this proof's own: the fact's for the
    /// shortest proof, `StrongerChain.depth` and `.chainClass` for R6's.
    init(proof: Derivation.ProofTree, start: [String], target: String, depth: Int,
         chainClass: Derivation.ChainClass, unstatedSteps: Int,
         refutations: [DerivationCuration.Refutation], manifest: RelationsManifest) {
        var models: Set<String> = []
        for row in proof.rows {
            guard let step = row.step, step.model != Derivation.standardModel else { continue }
            models.insert(step.model)
        }
        self.start = start
        self.target = target
        self.steps = Self.dependencyOrder(proof, manifest: manifest)
        self.relationCount = proof.relationIDs.count
        self.depth = depth
        self.chainClass = chainClass
        self.unstatedSteps = unstatedSteps
        self.models = models.sorted(by: Derivation.precedes)
        self.refutations = refutations
    }

    /// The fact a proof row stands for. A weakened fact is a different fact
    /// from the full one (R13), and so is a `metBy` producer's fact kept
    /// apart from its node's own, so the key keeps all three apart.
    private struct Occurrence: Hashable {
        let objectID: String
        let isWeakened: Bool
        let establishedBy: Derivation.StepKey?

        init(_ row: Derivation.ProofTree.Row) {
            objectID = row.objectID
            isWeakened = row.isWeakened
            establishedBy = row.establishedBy
        }
    }

    /// The steps, post-order: each step's hypotheses' steps in the edge's
    /// order, then the step.
    private static func dependencyOrder(_ proof: Derivation.ProofTree,
                                        manifest: RelationsManifest) -> [Step] {
        let rows = proof.rows
        // The step that concluded each fact, read off its first occurrence:
        // a "shown above" row has no step of its own, but a precondition met
        // through it was met by the step it refers to.
        var concludedBy: [Occurrence: Derivation.Step] = [:]
        for row in rows where !row.isReference {
            guard let step = row.step else { continue }
            let occurrence = Occurrence(row)
            if concludedBy[occurrence] == nil { concludedBy[occurrence] = step }
        }

        var steps: [Step] = []
        var seen: Set<Derivation.StepKey> = []
        var position = 0

        func visit() {
            let row = rows[position]
            position += 1
            // The hypotheses, in the edge's order, each with its subtree.
            var children: [Derivation.ProofTree.Row] = []
            while position < rows.count, rows[position].level == row.level + 1 {
                children.append(rows[position])
                visit()
            }
            guard let step = row.step, !row.isReference, seen.insert(step.key).inserted else {
                return
            }
            var established: [Step.Established] = []
            for requirement in step.requirements where !row.assumed.contains(requirement) {
                guard let index = step.hypotheses.firstIndex(of: requirement.hypothesis),
                      index < children.count,
                      let producer = concludedBy[Occurrence(children[index])],
                      requirement.metBy.contains(producer.relationID)
                else { continue }
                established.append(Step.Established(requirement: requirement,
                                                    producer: producer.relationID))
            }
            steps.append(Step(
                relationID: step.relationID, hypotheses: step.hypotheses,
                conclusion: step.conclusion, isReverse: step.isReverse, model: step.model,
                reductionClass: step.reductionClass, isStub: step.isStub,
                source: manifest.reduction(step.relationID)?.source ?? [],
                assumed: row.assumed, established: established, weakening: row.weakening))
        }

        while position < rows.count { visit() }
        return steps
    }
}
