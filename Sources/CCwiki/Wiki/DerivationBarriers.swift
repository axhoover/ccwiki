import Foundation

// Barriers in an answer (R8) and the barriers CCwiki derives from them (R12).
//
// A recorded barrier is the only kind of statement that something *cannot*
// be derived, and it is a statement about one class of reduction. Everything
// here keeps that scope: each consequence is read at its own class, a stub's
// is not evidence, and a derived barrier is emitted only when every condition
// that makes its argument sound holds.

extension Derivation {

    // MARK: Reading a barrier (R8)

    /// One consequence of a barrier, read at its own class (falling back to
    /// the barrier's) and by its kind.
    struct ConsequenceRule: Hashable, Sendable {
        enum Effect: String, Sendable {
            /// A contradiction, or a complexity proposition believed false:
            /// the reduction is ruled out.
            case rulesOut = "rules-out"
            /// A complexity proposition believed true: the reduction "would
            /// imply" a major result. Not a barrier.
            case majorResult = "major-result"
        }

        /// Position in the barrier's `consequences`.
        let index: Int
        let kind: Barrier.Consequence.Kind
        let target: String
        let reductionClass: String
        /// `nil` for an `object` or `reduction` consequence, which is shown
        /// and not interpreted.
        let effect: Effect?
    }

    /// What the UI must print beside a barrier's title wherever it appears,
    /// previews included, because the wiki writes every title as an
    /// unqualified "No reduction from A to B" (R8).
    enum BarrierQualifier: String, Sendable {
        case stub
        case unclassified
        case fixedConstruction = "fixed-construction"

        /// R8's wording.
        var explanation: String {
            switch self {
            case .stub:
                "Stub: its class and consequences are not evidence."
            case .unclassified:
                "Rules out a kind of reduction the wiki does not classify; see its statement."
            case .fixedConstruction:
                "Refutes only the construction named on its page; building the target "
                    + "another way is not ruled out."
            }
        }
    }

    /// R8's qualifier, for any surface that shows a barrier's title. Static,
    /// so a surface without a derivation (a link preview) can ask too.
    static func qualifier(of barrier: Barrier, in manifest: RelationsManifest) -> BarrierQualifier? {
        if barrier.status == .stub { return .stub }
        if manifest.isSentinel(barrier.reductionClass) || manifest.classes[barrier.reductionClass] == nil {
            return .unclassified
        }
        if barrier.reductionClass == fixedConstruction { return .fixedConstruction }
        return nil
    }

    /// Each consequence at its own class, with what it does.
    static func consequenceRules(of barrier: Barrier, in manifest: RelationsManifest) -> [ConsequenceRule] {
        var rules: [ConsequenceRule] = []
        for (index, consequence) in barrier.consequences.enumerated() {
            let reductionClass = consequence.reductionClass.isEmpty
                ? barrier.reductionClass : consequence.reductionClass
            let effect: ConsequenceRule.Effect?
            switch consequence.kind {
            case .contradiction:
                effect = .rulesOut
            case .complexity:
                // A proposition whose belief the manifest does not state has
                // no effect, as in the reference: it neither rules anything
                // out nor counts as a major result.
                switch manifest.propositions[consequence.target]?.believed {
                case true?: effect = .majorResult
                case false?: effect = .rulesOut
                case nil: effect = nil
                }
            case .object, .reduction:
                effect = nil
            }
            rules.append(ConsequenceRule(
                index: index, kind: consequence.kind, target: consequence.target,
                reductionClass: reductionClass, effect: effect))
        }
        return rules
    }

    /// The recorded barriers on exactly this hyperedge, sorted by id.
    func recordedBarriers(on hypotheses: [String], _ conclusion: String) -> [Barrier] {
        let edge = Set(hypotheses)
        return manifest.barriers
            .filter { $0.conclusion == conclusion && Set($0.hypotheses) == edge }
            .sorted { Self.precedes($0.id, $1.id) }
    }

    /// A barrier on the pair that some derivation meets. Either kind would
    /// mean the record is inconsistent; the corpus test asserts neither
    /// happens.
    struct BarrierConflict: Hashable, Sendable {
        let barrierID: String
        /// A derived barrier (R12), named by the recorded one it follows from.
        let isDerived: Bool
        let consequenceIndex: Int
        /// The class of the derivation that meets it: `unstated` when an
        /// unstated chain meets a barrier on `free` reductions.
        let chainClass: ChainClass
    }

    /// R8: does ANY standard-model, non-stub derivation with no assumed
    /// precondition have a class that implies* `reductionClass`? Returns that
    /// class, `unstated` when only an unstated chain meets a barrier on
    /// `free` reductions (an unstated step is still a proved implication), or
    /// `nil`.
    func chainExists(from start: [String], to target: String,
                     against reductionClass: String) -> ChainClass? {
        let starts = Set(start)
        for (index, chain) in ChainClass.composable.enumerated()
        where implies(chain.rawValue, reductionClass) {
            if cleanEngines[index].closure(from: starts, options: .standard).facts[target] != nil {
                return chain
            }
        }
        if reductionClass == ChainClass.free.rawValue,
           cleanAnyEngine.closure(from: starts, options: .standard).facts[target] != nil {
            return .unstated
        }
        return nil
    }

    // MARK: Derived barriers (R12)

    /// A barrier says that a class-C reduction {X} ⇒ Y would imply Q. If X ⇒*
    /// A′ and B′ ⇒* Y by reductions of class C, a class-C reduction A′ ⇒ B′
    /// would compose into one from X to Y, so it implies Q too.
    struct DerivedBarrier: Hashable, Sendable {
        /// The recorded barrier it follows from.
        let barrier: Barrier
        /// A′: the start set, sorted. One object except in a multi-start
        /// answer, where every member is reached from the barrier's
        /// hypothesis.
        let hypotheses: [String]
        /// B′.
        let conclusion: String
        /// The class it rules out: the consequence's class.
        let reductionClass: ChainClass
        /// The consequence carried over, at `reductionClass`.
        let consequence: ConsequenceRule
        /// For each member of `hypotheses`: the side steps from the barrier's
        /// hypothesis to it, in order.
        let upPaths: [String: [Step]]
        /// The side steps from `conclusion` to the barrier's conclusion, in
        /// order.
        let down: [Step]
        /// The barrier's circumventions that reach this pair: B′ is derivable
        /// from A′ through them.
        let circumventedBy: [String]
        /// The barrier's circumventions that reach only its own pair. The
        /// answer says so: "BH26 circumvents the barrier's own pair; that does
        /// not reach ETDP."
        let circumventsOriginalOnly: [String]
        /// A recorded non-stub barrier on the same pair, or a derived one
        /// already kept (prefixed `derived:`), that rules out at least as
        /// much. A redundant one is shown only under *Show reasoning*.
        let redundantWith: [String]

        /// A′ for a single start.
        var hypothesis: String { hypotheses.first ?? "" }
        /// The side steps from the barrier's hypothesis to `hypothesis`.
        var up: [Step] { upPaths[hypothesis] ?? [] }
        var isRedundant: Bool { !redundantWith.isEmpty }
        /// Inherited from the barrier.
        var strength: Barrier.Strength { barrier.strength }
        var conditionalOn: [String] { barrier.conditionalOn }

        /// Side steps on both chains, for R12's sort.
        fileprivate var pathLength: Int {
            upPaths.values.reduce(0) { $0 + $1.count } + down.count
        }

        fileprivate func marked(redundantWith ids: [String]) -> DerivedBarrier {
            DerivedBarrier(
                barrier: barrier, hypotheses: hypotheses, conclusion: conclusion,
                reductionClass: reductionClass, consequence: consequence, upPaths: upPaths,
                down: down, circumventedBy: circumventedBy,
                circumventsOriginalOnly: circumventsOriginalOnly, redundantWith: ids)
        }
    }

    /// One (barrier, consequence) that propagates, with the side chains from
    /// its hypothesis and to its conclusion.
    struct BarrierRule: Sendable {
        let barrier: Barrier
        let consequence: ConsequenceRule
        let reductionClass: ChainClass
        /// X, the barrier's hypothesis.
        let origin: String
        /// Y, the barrier's conclusion.
        let end: String
        /// Node → the side steps from X to it, in order.
        let ups: [String: [Step]]
        /// Node → the side steps from Y back to it, nearest Y first.
        let downs: [String: [Step]]

        /// Only a barrier with one hypothesis, primitives at both ends and not
        /// a stub propagates, and only through a consequence that rules out at
        /// a composable class. A consequence that would only be a major result,
        /// or of kind `object` or `reduction`, never does.
        static func rules(manifest: RelationsManifest, steps: [Step], order: ClassOrder) -> [BarrierRule] {
            let primitive = Derivation.primitiveType
            func nodeType(_ id: String) -> String { manifest.object(id)?.type ?? "" }

            var sideStepsByClass: [ChainClass: [Step]] = [:]
            var rules: [BarrierRule] = []
            for barrier in manifest.barriers.sorted(by: { Derivation.precedes($0.id, $1.id) }) {
                guard barrier.status != .stub, barrier.hypotheses.count == 1,
                      let origin = barrier.hypotheses.first
                else { continue }
                let end = barrier.conclusion
                guard nodeType(origin) == primitive, nodeType(end) == primitive else { continue }
                for consequence in Derivation.consequenceRules(of: barrier, in: manifest) {
                    guard consequence.effect == .rulesOut,
                          let chain = ChainClass(rawValue: consequence.reductionClass),
                          chain != .unstated
                    else { continue }
                    let side: [Step]
                    if let cached = sideStepsByClass[chain] {
                        side = cached
                    } else {
                        side = Self.sideSteps(chain, steps: steps, order: order, nodeType: nodeType)
                        sideStepsByClass[chain] = side
                    }
                    rules.append(BarrierRule(
                        barrier: barrier, consequence: consequence, reductionClass: chain,
                        origin: origin, end: end,
                        ups: reach(from: origin, through: side, forward: true),
                        downs: reach(from: end, through: side, forward: false)))
                }
            }
            return rules
        }

        /// R12's side edges for class C: single-hypothesis, not a stub, not
        /// quarantined (they are not steps at all), standard-model only, no
        /// precondition and no weakened conclusion, a class that implies* C
        /// (or, for C = `free`, unstated: a proved implication), and
        /// primitives at both ends. A quantum or CRS side reduction would give
        /// a quantum or CRS reduction X ⇒ Y, which the barrier does not rule
        /// out.
        private static func sideSteps(_ chain: ChainClass, steps: [Step], order: ClassOrder,
                                      nodeType: (String) -> String) -> [Step] {
            steps.filter { step in
                guard step.hypotheses.count == 1, let hypothesis = step.hypotheses.first,
                      step.isClean, step.model == Derivation.sideEdgeModel,
                      nodeType(hypothesis) == Derivation.primitiveType,
                      nodeType(step.conclusion) == Derivation.primitiveType
                else { return false }
                return order.implies(step.reductionClass, chain.rawValue)
                    || (chain == .free && step.reductionClass == Derivation.unstatedClass)
            }
        }

        /// Breadth-first over single-hypothesis side steps: node → the path
        /// of steps from `origin` (forward) or to it (backward). Neighbours are
        /// tried in step order and each layer in id order, so the path kept
        /// is the reference engine's.
        static func reach(from origin: String, through steps: [Step], forward: Bool) -> [String: [Step]] {
            var next: [String: [(node: String, step: Step)]] = [:]
            for step in steps {
                guard let hypothesis = step.hypotheses.first else { continue }
                let tail = forward ? hypothesis : step.conclusion
                let head = forward ? step.conclusion : hypothesis
                next[tail, default: []].append((node: head, step: step))
            }
            for key in Array(next.keys) {
                next[key]?.sort { Derivation.stepPrecedes($0.step, $1.step) }
            }
            var paths: [String: [Step]] = [origin: []]
            var frontier = [origin]
            while !frontier.isEmpty {
                var found: [String] = []
                for node in frontier {
                    let path = paths[node] ?? []
                    for edge in next[node] ?? [] where paths[edge.node] == nil {
                        paths[edge.node] = path + [edge.step]
                        found.append(edge.node)
                    }
                }
                frontier = found.sorted(by: Derivation.precedes)
            }
            return paths
        }
    }

    /// R12 for a question: every derived barrier whose side chains reach
    /// every start and the target, with the circumventions that apply and
    /// redundancy marked, broadest class first. Empty unless the start and
    /// the target are all primitives and the target is not a start.
    func derivedBarriers(from start: Set<String>, to target: String) -> [DerivedBarrier] {
        let starts = start.sorted(by: Self.precedes)
        // An empty conjunction is no question R12 answers.
        guard !starts.isEmpty, !start.contains(target),
              nodeType(target) == Self.primitiveType,
              starts.allSatisfy({ nodeType($0) == Self.primitiveType })
        else { return [] }

        var drafts: [DerivedBarrier] = []
        for rule in barrierRules {
            guard let downPath = rule.downs[target],
                  starts.allSatisfy({ rule.ups[$0] != nil }),
                  !(starts == [rule.origin] && target == rule.end)
            else { continue }
            var upPaths: [String: [Step]] = [:]
            for member in starts { upPaths[member] = rule.ups[member] ?? [] }
            // A circumvention of X ⇒ Y is listed for A′ ⇒ B′ only if B′ is
            // derivable from A′ through it; it is not inherited blindly.
            let inherited = rule.barrier.circumventedBy
            let reaching = inherited.filter { isDerivable(from: starts, to: target, through: $0) }
            let originalOnly = inherited.filter { !reaching.contains($0) }
            drafts.append(DerivedBarrier(
                barrier: rule.barrier, hypotheses: starts, conclusion: target,
                reductionClass: rule.reductionClass, consequence: rule.consequence,
                upPaths: upPaths, down: Array(downPath.reversed()),
                circumventedBy: reaching, circumventsOriginalOnly: originalOnly,
                redundantWith: []))
        }
        return markRedundant(start: starts, target: target, drafts)
    }

    /// Is `target` derivable from `start` through reduction `relationID`:
    /// are its hypotheses in cl(start), and is `target` in cl(start ∪ {its
    /// conclusion})?
    func isDerivable(from start: [String], to target: String, through relationID: String) -> Bool {
        guard let relation = manifest.reduction(relationID) else { return false }
        let starts = Set(start)
        let base = closure(from: starts, options: .standard)
        guard relation.hypotheses.allSatisfy({ base.facts[$0] != nil }) else { return false }
        let extended = closure(from: starts.union([relation.conclusion]), options: .standard)
        return extended.facts[target] != nil
    }

    /// Every single-object derived barrier, pair by pair, for counts and the
    /// corpus invariants. Built once, at init.
    func allDerivedBarriers() -> [DerivedBarrier] {
        var pairs: Set<[String]> = []
        for rule in barrierRules {
            for hypothesis in rule.ups.keys {
                for conclusion in rule.downs.keys
                where hypothesis != conclusion && !(hypothesis == rule.origin && conclusion == rule.end) {
                    pairs.insert([hypothesis, conclusion])
                }
            }
        }
        let ordered = pairs.sorted { left, right in
            if left[0] != right[0] { return Self.precedes(left[0], right[0]) }
            return Self.precedes(left[1], right[1])
        }
        var all: [DerivedBarrier] = []
        for pair in ordered {
            all += derivedBarriers(from: [pair[0]], to: pair[1])
        }
        return all
    }

    /// A derived barrier is redundant when a recorded non-stub barrier, or a
    /// derived one already kept, on the same pair rules out at least as much:
    /// a class it implies*, a strength no weaker (unconditional over
    /// conditional) and a consequence no weaker (contradiction over
    /// complexity). Candidates are taken broadest class first.
    private func markRedundant(start: [String], target: String,
                               _ drafts: [DerivedBarrier]) -> [DerivedBarrier] {
        struct Dominator {
            let id: String
            let reductionClass: String
            let strength: Int
            let effect: Int
        }
        var dominators: [Dominator] = []
        for barrier in recordedBarriers(on: start, target) where barrier.status != .stub {
            for rule in Self.consequenceRules(of: barrier, in: manifest) where rule.effect == .rulesOut {
                dominators.append(Dominator(
                    id: barrier.id, reductionClass: rule.reductionClass,
                    strength: Self.strengthRank(barrier.strength), effect: Self.effectRank(rule.kind)))
            }
        }

        var marked: [DerivedBarrier] = []
        for draft in drafts.sorted(by: Self.derivedPrecedes) {
            let strength = Self.strengthRank(draft.strength)
            let effect = Self.effectRank(draft.consequence.kind)
            var covering: Set<String> = []
            for dominator in dominators
            where implies(draft.reductionClass.rawValue, dominator.reductionClass)
                && dominator.strength <= strength && dominator.effect <= effect {
                covering.insert(dominator.id)
            }
            if covering.isEmpty {
                dominators.append(Dominator(
                    id: "derived:" + draft.barrier.id, reductionClass: draft.reductionClass.rawValue,
                    strength: strength, effect: effect))
            }
            marked.append(draft.marked(redundantWith: covering.sorted(by: Self.precedes)))
        }
        return marked
    }

    private static func strengthRank(_ strength: Barrier.Strength) -> Int {
        switch strength {
        case .unconditional: 0
        case .conditional: 1
        }
    }

    private static func effectRank(_ kind: Barrier.Consequence.Kind) -> Int {
        kind == .contradiction ? 0 : 1
    }

    /// Broadest class first, then the stronger strength and consequence, then
    /// the shorter side chains, then the barrier id and consequence.
    private static func derivedPrecedes(_ a: DerivedBarrier, _ b: DerivedBarrier) -> Bool {
        if a.reductionClass.rank != b.reductionClass.rank {
            return a.reductionClass.rank > b.reductionClass.rank
        }
        let strengths = (strengthRank(a.strength), strengthRank(b.strength))
        if strengths.0 != strengths.1 { return strengths.0 < strengths.1 }
        let effects = (effectRank(a.consequence.kind), effectRank(b.consequence.kind))
        if effects.0 != effects.1 { return effects.0 < effects.1 }
        if a.pathLength != b.pathLength { return a.pathLength < b.pathLength }
        if precedes(a.barrier.id, b.barrier.id) { return true }
        if precedes(b.barrier.id, a.barrier.id) { return false }
        return a.consequence.index < b.consequence.index
    }
}
