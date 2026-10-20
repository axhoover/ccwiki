import Foundation

// "Does A imply B?" (R8–R10, R13, R14): the explorer's question mode.
//
// The answer carries data, not sentences. The UI words it, under the rules of
// derivations.md §7 and relations-explorer.md §6.7; the only text fixed here
// is what the specs fix verbatim (R8's qualifiers, R10's footer).

extension Derivation {

    enum Unsupported: Hashable, Sendable {
        case unknownObject(String)
        /// R2: classes are related by containment, not derived.
        case complexityClass(String)
    }

    enum Answer: Sendable {
        case unsupported(Unsupported)
        /// A target in the start comes back here too, at depth 0.
        case derived(DerivedAnswer)
        case notDerived(NoPathAnswer)
    }

    /// R10.0: a reduction the wiki records on exactly this hyperedge (or its
    /// reverse), and what CCwiki did with it.
    struct RecordedOnPair: Hashable, Sendable {
        enum Status: Hashable, Sendable {
            case used
            /// Derivable, through another derivation.
            case notOnShownDerivation
            /// Not derivable; see `needs`.
            case unused
            /// R3: used only with the toggle.
            case stub
            /// R4: used only with the toggle.
            case idealisedModel
            /// R1, R2, R4 or R13: never used.
            case excluded(Exclusion)

            /// The reference engine's word.
            var rawValue: String {
                switch self {
                case .used: "used"
                case .notOnShownDerivation: "not-on-shown-derivation"
                case .unused: "unused"
                case .stub: "stub"
                case .idealisedModel: "idealised-model"
                case .excluded(let exclusion): exclusion.rawValue
                }
            }
        }

        let relationID: String
        let isReverse: Bool
        let status: Status
        /// The quarantine's reason (R13).
        let detail: String?
        /// The notions an unused step requires of its hypotheses (R13).
        let needs: [String]
    }

    /// R8: a derivation that is not standard-model, assumes a precondition
    /// or concludes a weakened notion is never in conflict with a barrier,
    /// which concerns standard-model reductions from the node as the wiki
    /// defines it. Beside one, the answer says so.
    struct ScopeNote: Hashable, Sendable {
        /// The non-standard models, sorted.
        let models: [String]
        let assumesPrecondition: Bool
        let isWeakened: Bool

        /// The reference engine's list: the models, then `assumption`, then
        /// `weakened`.
        var reasons: [String] {
            var reasons = models
            if assumesPrecondition { reasons.append("assumption") }
            if isWeakened { reasons.append("weakened") }
            return reasons
        }
    }

    /// R9: related by the page, not by a recorded reduction.
    struct Hint: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// A section of the target is derived.
            case targetSection
            /// The target's host is derived.
            case targetHost
            /// A section of a start derives the target.
            case startSection
            /// The host of a start derives the target.
            case startHost
        }

        let kind: Kind
        /// The section or host.
        let objectID: String
        /// The start or target it is related to.
        let standsFor: String
        let depth: Int
    }

    /// R10.6: an object with which the recorded reductions reach the target.
    /// Never a claim that it is needed: it may suffice on its own, and the
    /// record is incomplete.
    struct Completion: Hashable, Sendable {
        let objectID: String
        /// The target's, from start ∪ {objectID}.
        let fact: Fact
        let relationIDs: [String]
    }

    struct DerivedAnswer: Sendable {
        /// Sorted.
        let start: [String]
        let target: String
        let options: Options
        /// The target's. Depth 0 when the target is a start.
        let fact: Fact
        let proof: ProofTree
        /// R6: only when it differs from `fact.chainClass`.
        let stronger: StrongerChain?
        /// R8: the exact hyperedge.
        let recordedBarriers: [Barrier]
        /// R8: the reverse pair; one start only.
        let reverseBarriers: [Barrier]
        /// R12 on the pair, as context, redundant ones included and flagged.
        let derivedBarriers: [DerivedBarrier]
        let derivedReverseBarriers: [DerivedBarrier]
        let recordedOnPair: [RecordedOnPair]
        /// R8: barriers some clean standard-model derivation meets. Never
        /// expected; a non-empty list means the record is inconsistent.
        let conflicts: [BarrierConflict]
        /// R8: believed-true propositions some derivation would prove.
        let majorResults: [BarrierConflict]
        let scopeNote: ScopeNote?
        /// R14: the refuted starts. Non-empty means the implication is
        /// vacuous.
        let refutedStarts: [DerivationCuration.Refutation]
        /// R14: starts that are corruption settings, not assumptions.
        let settingStarts: [String]
        /// R4: model nodes given with the toggle off.
        let modelStarts: [String]

        var isGiven: Bool { fact.step == nil }
        var isVacuous: Bool { !refutedStarts.isEmpty }
        /// One step: the wiki states this result itself, so it reads as
        /// recorded, never as derived (the lead's resolution of
        /// relations-explorer.md §6.7). Two or more steps are CCwiki's
        /// composition.
        var isRecordedResult: Bool { fact.depth == 1 }
    }

    struct NoPathAnswer: Sendable {
        /// Sorted.
        let start: [String]
        let target: String
        let options: Options
        let recordedBarriers: [Barrier]
        let reverseBarriers: [Barrier]
        /// R12; redundant ones included, flagged.
        let derivedBarriers: [DerivedBarrier]
        let derivedReverseBarriers: [DerivedBarrier]
        let recordedOnPair: [RecordedOnPair]
        /// R10.3: toggle off, and turning it on would derive the target.
        let withIdealisedModels: Fact?
        let withIdealisedModelsProof: ProofTree?
        /// That derivation uses a stub: say "uses a stub reduction, whose
        /// class and model are not evidence", never "idealised".
        let withIdealisedModelsUsesStub: Bool
        /// R4: model nodes given with the toggle off.
        let modelStarts: [String]
        let refutedStarts: [DerivationCuration.Refutation]
        let settingStarts: [String]
        /// R10.4: the steps R5 or R13 refused on the derivation plain closure
        /// would have used, in either mode.
        let refused: [RefusedStep]
        let hints: [Hint]
        /// At most `completionCap`, best first.
        let completions: [Completion]
        let completionCount: Int
        /// Completions the target itself gives back: adding one only restates
        /// the target, so the question becomes start ⇒ it.
        let questionBecomes: [Completion]

        /// R10.7, fixed text, always shown and never collapsible.
        static let footer = "CCwiki found no derivation from the reductions the wiki records. "
            + "This is not a separation: the record is incomplete, and only the "
            + "barriers listed here are results, each for the class of reduction it names."
    }

    // MARK: - The question

    func answer(from start: Set<String>, to target: String, options: Options) -> Answer {
        let starts = start.sorted(by: Self.precedes)
        for id in starts + [target] {
            guard let object = manifest.object(id) else { return .unsupported(.unknownObject(id)) }
            if object.type == Self.excludedType { return .unsupported(.complexityClass(id)) }
        }

        let closure = self.closure(from: start, options: options)
        let refutedStarts = starts.compactMap { curation.refuted[$0] }
        let settingStarts = starts.filter { curation.settings[$0] != nil }
        let modelStarts = options.includesIdealisedModels ? [] : starts.filter { isModelNode($0) }
        let recorded = recordedBarriers(on: starts, target)
        let reverse = starts.count == 1 ? recordedBarriers(on: [target], starts[0]) : []
        let derived = derivedBarriers(from: start, to: target)
        let derivedReverse = starts.count == 1 ? derivedBarriers(from: [target], to: starts[0]) : []

        if let fact = closure.fact(target), let proof = closure.proof(of: target) {
            let onPair = recordedOnPair(start: starts, target: target, options: options,
                                        used: Set(proof.relationIDs), derivable: true)
            var stronger: StrongerChain?
            var conflicts: [BarrierConflict] = []
            var majorResults: [BarrierConflict] = []
            var scopeNote: ScopeNote?
            if fact.step != nil {
                if let found = self.strongest(from: start, to: target, options: options, shown: fact),
                   found.chainClass != fact.chainClass {
                    stronger = found
                }
                // R8: a barrier on the pair against a class that ANY clean,
                // standard-model derivation has would make the record
                // inconsistent.
                for barrier in recorded where barrier.status != .stub {
                    for rule in Self.consequenceRules(of: barrier, in: manifest) {
                        guard let effect = rule.effect,
                              let chain = chainExists(from: starts, to: target, against: rule.reductionClass)
                        else { continue }
                        let conflict = BarrierConflict(barrierID: barrier.id, isDerived: false,
                                                       consequenceIndex: rule.index, chainClass: chain)
                        switch effect {
                        case .rulesOut: conflicts.append(conflict)
                        case .majorResult: majorResults.append(conflict)
                        }
                    }
                }
                for barrier in derived {
                    guard let chain = chainExists(from: starts, to: target,
                                                  against: barrier.reductionClass.rawValue)
                    else { continue }
                    conflicts.append(BarrierConflict(
                        barrierID: barrier.barrier.id, isDerived: true,
                        consequenceIndex: barrier.consequence.index, chainClass: chain))
                }
                let note = ScopeNote(models: fact.models.sorted(by: Self.precedes),
                                     assumesPrecondition: !fact.assumes.isEmpty,
                                     isWeakened: fact.weakening != nil)
                // The note says the barriers concern standard-model
                // reductions, so a barrier proved in another model, whose own
                // row names its model, does not call for it. A stub's model is
                // not evidence, and every derived barrier is standard-model.
                let barrierBeside = recorded.contains { $0.status == .stub || $0.model == Self.standardModel }
                    || derived.contains { !$0.isRedundant }
                if !note.reasons.isEmpty && barrierBeside {
                    scopeNote = note
                }
            }
            return .derived(DerivedAnswer(
                start: starts, target: target, options: options, fact: fact, proof: proof,
                stronger: stronger, recordedBarriers: recorded, reverseBarriers: reverse,
                derivedBarriers: derived, derivedReverseBarriers: derivedReverse,
                recordedOnPair: onPair, conflicts: conflicts, majorResults: majorResults,
                scopeNote: scopeNote, refutedStarts: refutedStarts, settingStarts: settingStarts,
                modelStarts: modelStarts))
        }

        let onPair = recordedOnPair(start: starts, target: target, options: options,
                                    used: [], derivable: false)
        // R10.3: would the toggle find it?
        var withIdealised: Fact?
        var withIdealisedProof: ProofTree?
        if !options.includesIdealisedModels {
            let alternative = self.closure(from: start, options: .all)
            withIdealised = alternative.fact(target)
            withIdealisedProof = alternative.proof(of: target)
        }
        let refused = refusedSteps(from: starts, to: target, options: options)
        let barrierOnPair = recorded.contains { $0.status != .stub } || derived.contains { !$0.isRedundant }
        let hints = self.hints(start: starts, closure: closure, target: target, options: options,
                               barrierOnPair: barrierOnPair)
        let completions = self.completions(start: starts, target: target, closure: closure,
                                           options: options)
        return .notDerived(NoPathAnswer(
            start: starts, target: target, options: options, recordedBarriers: recorded,
            reverseBarriers: reverse, derivedBarriers: derived,
            derivedReverseBarriers: derivedReverse, recordedOnPair: onPair,
            withIdealisedModels: withIdealised, withIdealisedModelsProof: withIdealisedProof,
            withIdealisedModelsUsesStub: withIdealisedProof?.usesStub ?? false,
            modelStarts: modelStarts, refutedStarts: refutedStarts, settingStarts: settingStarts,
            refused: refused, hints: hints, completions: completions.offered,
            completionCount: completions.count, questionBecomes: completions.restating))
    }

    // MARK: R10.0

    /// Every reduction on exactly this hyperedge, or its reverse, with what
    /// CCwiki did with it.
    func recordedOnPair(start: [String], target: String, options: Options,
                        used: Set<String>, derivable: Bool) -> [RecordedOnPair] {
        let starts = Set(start)
        var reasons: [String: Exclusion] = [:]
        for (exclusion, ids) in excluded {
            for id in ids { reasons[id] = exclusion }
        }
        var rows: [RecordedOnPair] = []
        for id in Set(manifest.reductions.map { $0.id }).sorted(by: Self.precedes) {
            guard let relation = manifest.reduction(id) else { continue }
            let forward = Set(relation.hypotheses) == starts && relation.conclusion == target
            let reverse = relation.kind == .equivalence && starts.count == 1
                && relation.hypotheses == [target] && starts.contains(relation.conclusion)
            guard forward || reverse else { continue }
            let step = stepsByKey[StepKey(relationID: id, isReverse: !forward)]
            let status: RecordedOnPair.Status
            var detail: String?
            var needs: [String] = []
            // A quarantine of one direction leaves the reduction eligible, so
            // it is not in `excluded`; its row says so all the same.
            let held = curation.quarantineReason(id, isReverse: !forward)
            var exclusionOnPair = reasons[id]
            if exclusionOnPair == nil, held != nil { exclusionOnPair = .quarantined }
            if let exclusion = exclusionOnPair {
                status = .excluded(exclusion)
                detail = held
            } else if let step, step.isStub, !options.includesIdealisedModels {
                status = .stub
            } else if let step, !step.isDefault, !options.includesIdealisedModels {
                status = .idealisedModel
            } else if used.contains(id) {
                status = .used
            } else {
                status = derivable ? .notOnShownDerivation : .unused
                if let step { needs = step.requirements.map { $0.notion } }
            }
            rows.append(RecordedOnPair(relationID: id, isReverse: !forward, status: status,
                                       detail: detail, needs: needs))
        }
        return rows
    }

    // MARK: R6

    /// The strongest class of any derivation of the same notion of `target`
    /// that uses no model or assumption the shown one does not, found by
    /// rerunning the closure over only the steps of each composable class in
    /// turn.
    func strongest(from start: Set<String>, to target: String, options: Options,
                   shown: Fact) -> StrongerChain? {
        for (index, chain) in ChainClass.composable.enumerated() {
            let closure = restrictedEngines[index].closure(from: start, options: options)
            let found = shown.weakening == nil ? closure.facts[target] : closure.weakFacts[target]
            guard let candidate = found, candidate.step != nil else { continue }
            if let shownWeakening = shown.weakening {
                guard let weakening = candidate.weakening,
                      weakening.relationID == shownWeakening.relationID
                else { continue }
            }
            guard candidate.models.isSubset(of: shown.models),
                  candidate.assumes.isSubset(of: shown.assumes),
                  let proof = closure.proof(of: target)
            else { continue }
            return StrongerChain(chainClass: chain, depth: candidate.depth, proof: proof)
        }
        return nil
    }

    // MARK: R10.4

    /// The steps R5 or R13 refused on the derivation plain Horn closure would
    /// give, each with every reason and the recorded barriers on its own pair
    /// or on (start, its conclusion).
    func refusedSteps(from start: [String], to target: String, options: Options) -> [RefusedStep] {
        let relaxed = relaxedEngine.closure(from: Set(start), options: options)
        guard relaxed.facts[target] != nil, let proof = relaxed.proof(of: target) else { return [] }
        var keys: Set<StepKey> = []
        for row in proof.rows {
            if let step = row.step { keys.insert(step.key) }
        }
        let ordered = keys.compactMap { stepsByKey[$0] }.sorted(by: Self.stepPrecedes)

        var refused: [RefusedStep] = []
        for step in ordered {
            var inputs: [(id: String, fact: Fact)] = []
            for hypothesis in step.hypotheses where !inputs.contains(where: { $0.id == hypothesis }) {
                if let fact = relaxed.facts[hypothesis] { inputs.append((id: hypothesis, fact: fact)) }
            }
            var reasons: [Refusal] = []
            if let reason = curation.quarantineReason(step.relationID, isReverse: step.isReverse) {
                reasons.append(.quarantined(reason: reason))
            }
            for input in inputs {
                guard let producer = input.fact.step, let weakening = producer.weakening,
                      !weakening.acceptedBy.contains(step.relationID)
                else { continue }
                reasons.append(.weakened(hypothesis: input.id, producedBy: producer.relationID,
                                         notion: weakening.notion))
            }
            for requirement in step.requirements {
                guard let input = inputs.first(where: { $0.id == requirement.hypothesis }),
                      let producer = input.fact.step,
                      !requirement.metBy.contains(producer.relationID)
                else { continue }
                reasons.append(.requires(hypothesis: requirement.hypothesis,
                                         notion: requirement.notion,
                                         producedBy: producer.relationID))
            }
            if !implies(step.reductionClass, Self.relativizing)
                && inputs.contains(where: { $0.fact.isModelScoped }) {
                let scoped = inputs.filter { $0.fact.isModelScoped }.map { $0.id }
                reasons.append(.idealisedComposition(reductionClass: step.reductionClass,
                                                     scopedHypotheses: scoped.sorted(by: Self.precedes)))
            }
            guard !reasons.isEmpty else { continue }
            var barrierIDs = Set(recordedBarriers(on: step.hypotheses, step.conclusion).map { $0.id })
            barrierIDs.formUnion(recordedBarriers(on: start, step.conclusion).map { $0.id })
            refused.append(RefusedStep(step: step, reasons: reasons,
                                       barrierIDs: barrierIDs.sorted(by: Self.precedes)))
        }
        return refused
    }

    // MARK: R9

    /// Sections of `host`, sorted by id.
    func variants(of host: String) -> [String] {
        manifest.objectsByID.values
            .filter { $0.isVariant && $0.of == host }
            .map { $0.id }
            .sorted(by: Self.precedes)
    }

    /// Hosts and variants are related by page structure, never by an edge, so
    /// none of this is a derivation.
    func hints(start: [String], closure: Closure, target: String, options: Options,
               barrierOnPair: Bool) -> [Hint] {
        let starts = Set(start)
        var hints: [Hint] = []
        for variant in variants(of: target) where !starts.contains(variant) {
            if let fact = closure.facts[variant] {
                hints.append(Hint(kind: .targetSection, objectID: variant, standsFor: target,
                                  depth: fact.depth))
            }
        }
        // Never a host that is the premise itself, and never beside a
        // barrier, since a section is usually the stronger notion.
        if let object = manifest.object(target), object.isVariant, let host = object.of,
           !starts.contains(host), !barrierOnPair, let fact = closure.facts[host] {
            hints.append(Hint(kind: .targetHost, objectID: host, standsFor: target, depth: fact.depth))
        }
        for member in start {
            for variant in variants(of: member) where variant != target {
                var alternative = starts
                alternative.remove(member)
                alternative.insert(variant)
                if let fact = self.closure(from: alternative, options: options).facts[target] {
                    hints.append(Hint(kind: .startSection, objectID: variant, standsFor: member,
                                      depth: fact.depth))
                }
            }
        }
        for member in start {
            guard let object = manifest.object(member), object.isVariant, let host = object.of,
                  manifest.object(host) != nil, host != target
            else { continue }
            var alternative = starts
            alternative.remove(member)
            alternative.insert(host)
            if let fact = self.closure(from: alternative, options: options).facts[target] {
                hints.append(Hint(kind: .startHost, objectID: host, standsFor: member, depth: fact.depth))
            }
        }
        return hints
    }

    // MARK: R10.6

    /// Single objects with which the recorded reductions reach the target:
    /// a primitive or assumption, not a model node, a setting or a refuted
    /// object, not already derived, that does not reach the target alone.
    /// Only the weakest are kept, before those the target gives back are set
    /// aside, so a stronger object never stands in for one set aside.
    ///
    /// A candidate whose plain Horn closure with the start misses the target
    /// is passed over without a closure of its own (`Engine.mayReach`), which
    /// on the real manifest is nearly every candidate of a no-path answer.
    /// `prefilter: false` closes every candidate, for the test that holds
    /// the two equal.
    func completions(start: [String], target: String, closure: Closure, options: Options,
                     prefilter: Bool = true)
        -> (offered: [Completion], count: Int, restating: [Completion]) {
        let starts = Set(start)
        let givesBack = self.closure(from: starts.union([target]), options: options).facts

        var found: [Completion] = []
        for candidate in manifest.objectsByID.keys.sorted(by: Self.precedes) {
            guard candidate != target, closure.facts[candidate] == nil,
                  Self.completionTypes.contains(nodeType(candidate)), !isModelNode(candidate),
                  curation.refuted[candidate] == nil, curation.settings[candidate] == nil
            else { continue }
            // Alone it suffices: that is R11's business, not a completion.
            if self.closure(from: [candidate], options: options).fact(target) != nil { continue }
            let union = starts.union([candidate])
            if prefilter, !mainEngine.mayReach(target, from: union, options: options) { continue }
            let extended = self.closure(from: union, options: options)
            guard let fact = extended.facts[target], let proof = extended.proof(of: target) else {
                continue
            }
            found.append(Completion(objectID: candidate, fact: fact, relationIDs: proof.relationIDs))
        }

        // Drop a candidate when another follows from it and it does not
        // follow from that other.
        let ids = found.map { $0.objectID }
        var kept: [Completion] = []
        for completion in found {
            let reached = self.closure(from: [completion.objectID], options: options).facts
            let dominated = ids.contains { other in
                other != completion.objectID && reached[other] != nil
                    && self.closure(from: [other], options: options).facts[completion.objectID] == nil
            }
            if !dominated { kept.append(completion) }
        }
        kept.sort(by: Self.completionPrecedes)
        let offered = kept.filter { givesBack[$0.objectID] == nil }
        let restating = kept.filter { givesBack[$0.objectID] != nil }
        return (offered: Array(offered.prefix(Self.completionCap)), count: offered.count,
                restating: Array(restating.prefix(Self.completionCap)))
    }

    /// Depth, then non-standard models, assumptions, chain class, tree size
    /// and id.
    private static func completionPrecedes(_ a: Completion, _ b: Completion) -> Bool {
        if a.fact.depth != b.fact.depth { return a.fact.depth < b.fact.depth }
        if a.fact.models.count != b.fact.models.count { return a.fact.models.count < b.fact.models.count }
        if a.fact.assumes.count != b.fact.assumes.count {
            return a.fact.assumes.count < b.fact.assumes.count
        }
        if a.fact.chainClass != b.fact.chainClass { return a.fact.chainClass < b.fact.chainClass }
        if a.relationIDs.count != b.relationIDs.count { return a.relationIDs.count < b.relationIDs.count }
        return precedes(a.objectID, b.objectID)
    }
}
