import Foundation

// Everything implying X (R11): the explorer's backward mode.
//
// Single objects are exact, read off the precomputed single-object closures.
// Pairs are the ones the recorded reductions use jointly, which says nothing
// about need: either half may suffice on its own, and the record does not
// know it. The UI never writes "minimal", "needs both" or "neither alone".

extension Derivation {

    struct BackwardClosure: Equatable, Sendable {
        struct Single: Hashable, Sendable {
            let objectID: String
            /// The target's, from `objectID` alone. Weakened when only a weaker
            /// notion of the target is derived.
            let fact: Fact
        }

        /// Two objects the recorded reductions use together.
        struct Pair: Hashable, Sendable {
            /// Sorted.
            let objectIDs: [String]
            let fact: Fact
        }

        /// The pairs that meet at one conjunctive reduction.
        struct Group: Hashable, Sendable {
            /// Where the two halves meet: the conjunctive step nearest the
            /// root whose hypotheses neither half derives alone.
            let relationID: String
            let hypotheses: [String]
            /// At most `impliedByGroupCap`.
            let pairRows: [Pair]
            let pairCount: Int
            /// The union of the pairs' non-standard models, sorted.
            let models: [String]
            /// The union of the pairs' assumed notions, sorted.
            let assumes: [String]

            /// Each sorted; at most `impliedByGroupCap`.
            var pairs: [[String]] { pairRows.map { $0.objectIDs } }
        }

        /// A conjunction of three or more hypotheses, shown as the edge
        /// itself rather than enumerated.
        struct Conjunction: Hashable, Sendable {
            let relationID: String
            let hypotheses: [String]
            let fact: Fact
        }

        let target: String
        let options: Options
        /// At most `impliedBySingleCap`, by depth, models, assumptions, id.
        let singles: [Single]
        let singleCount: Int
        /// R14: corruption settings that reach the target, listed apart.
        let settings: [Single]
        /// R14: refuted objects that reach it. Never listed; counted for
        /// *Show reasoning*.
        let refutedExcluded: [String]
        /// Most pairs first.
        let groups: [Group]
        let pairCount: Int
        let largerConjunctions: [Conjunction]
    }

    /// Everything implying `target` (R11). A candidate pair whose plain Horn
    /// closure misses the target is passed over without a closure of its own
    /// (`Engine.mayReach`), which on the real manifest is nearly every pair.
    func implying(_ target: String, options: Options) -> BackwardClosure {
        let base = manifest.objectsByID.keys
            .filter { nodeType($0) != Self.excludedType && !isModelNode($0) && $0 != target }
            .sorted(by: Self.precedes)
        let sources = base.filter { curation.refuted[$0] == nil && curation.settings[$0] == nil }

        var singles: [BackwardClosure.Single] = []
        var settings: [BackwardClosure.Single] = []
        var refuted: [String] = []
        for objectID in base {
            guard let fact = closure(from: [objectID], options: options).fact(target) else { continue }
            if curation.refuted[objectID] != nil {
                refuted.append(objectID)
            } else if curation.settings[objectID] != nil {
                settings.append(BackwardClosure.Single(objectID: objectID, fact: fact))
            } else {
                singles.append(BackwardClosure.Single(objectID: objectID, fact: fact))
            }
        }

        // A pair derives more than its halves only if some conjunctive step
        // has every hypothesis in the union of their closures and neither
        // closure alone covers it. Those pairs are the candidates; each is
        // then checked with a real closure.
        var alone = Set(singles.map { $0.objectID })
        alone.insert(target)
        let conjunctive = (options.includesIdealisedModels ? steps : defaultSteps)
            .filter { $0.hypotheses.count > 1 }
        var cover: [String: Set<String>] = [:]
        var derivingAlone: [String: Set<String>] = [:]
        for objectID in sources {
            let reached = Set(closure(from: [objectID], options: options).facts.keys)
            cover[objectID] = reached
            for id in reached { derivingAlone[id, default: []].insert(objectID) }
        }

        var candidates: Set<[String]> = []
        for step in conjunctive {
            let hypotheses = Set(step.hypotheses)
            var halves: Set<String> = []
            for hypothesis in hypotheses { halves.formUnion(derivingAlone[hypothesis] ?? []) }
            for first in halves.sorted(by: Self.precedes) where !alone.contains(first) {
                let need = hypotheses.subtracting(cover[first] ?? [])
                guard !need.isEmpty else { continue }
                var others: Set<String>?
                for hypothesis in need {
                    let deriving = derivingAlone[hypothesis] ?? []
                    others = others.map { $0.intersection(deriving) } ?? deriving
                }
                for second in others ?? [] where second != first && !alone.contains(second) {
                    candidates.insert(Self.precedes(first, second) ? [first, second] : [second, first])
                }
            }
        }

        var groupedPairs: [String: [BackwardClosure.Pair]] = [:]
        let orderedCandidates = candidates.sorted { left, right in
            if left[0] != right[0] { return Self.precedes(left[0], right[0]) }
            return Self.precedes(left[1], right[1])
        }
        for pair in orderedCandidates {
            if !mainEngine.mayReach(target, from: Set(pair), options: options) { continue }
            let pairClosure = closure(from: Set(pair), options: options)
            guard let fact = pairClosure.fact(target) else { continue }
            let meeting = joiningRelation(pairClosure, target: target,
                                          first: cover[pair[0]] ?? [], second: cover[pair[1]] ?? [])
            groupedPairs[meeting, default: []].append(BackwardClosure.Pair(objectIDs: pair, fact: fact))
        }

        var groups: [BackwardClosure.Group] = []
        for (relationID, pairs) in groupedPairs {
            var models: Set<String> = []
            var assumes: Set<String> = []
            for pair in pairs {
                models.formUnion(pair.fact.models)
                assumes.formUnion(pair.fact.assumes.map { $0.notion })
            }
            groups.append(BackwardClosure.Group(
                relationID: relationID,
                hypotheses: manifest.reduction(relationID)?.hypotheses ?? [],
                pairRows: Array(pairs.prefix(Self.impliedByGroupCap)),
                pairCount: pairs.count,
                models: models.sorted(by: Self.precedes),
                assumes: assumes.sorted(by: Self.precedes)))
        }
        groups.sort { left, right in
            if left.pairCount != right.pairCount { return left.pairCount > right.pairCount }
            return Self.precedes(left.relationID, right.relationID)
        }

        // Conjunctions of three or more are shown as the edge, not enumerated.
        var larger: [BackwardClosure.Conjunction] = []
        for step in conjunctive where step.hypotheses.count >= 3 && groupedPairs[step.relationID] == nil {
            let someAlone = step.hypotheses.contains {
                closure(from: [$0], options: options).fact(target) != nil
            }
            if someAlone { continue }
            if let fact = closure(from: Set(step.hypotheses), options: options).fact(target) {
                larger.append(BackwardClosure.Conjunction(
                    relationID: step.relationID, hypotheses: step.hypotheses, fact: fact))
            }
        }

        singles.sort { left, right in
            if left.fact.depth != right.fact.depth { return left.fact.depth < right.fact.depth }
            if left.fact.models.count != right.fact.models.count {
                return left.fact.models.count < right.fact.models.count
            }
            if left.fact.assumes.count != right.fact.assumes.count {
                return left.fact.assumes.count < right.fact.assumes.count
            }
            return Self.precedes(left.objectID, right.objectID)
        }
        let pairCount = groupedPairs.values.reduce(0) { $0 + $1.count }
        return BackwardClosure(
            target: target, options: options,
            singles: Array(singles.prefix(Self.impliedBySingleCap)), singleCount: singles.count,
            settings: settings, refutedExcluded: refuted, groups: groups, pairCount: pairCount,
            largerConjunctions: larger)
    }

    /// The conjunctive step nearest the root whose hypotheses neither half
    /// derives alone: where the two halves of the pair meet. Breadth-first
    /// from the target, hypotheses in the edge's order.
    private func joiningRelation(_ closure: Closure, target: String,
                                 first: Set<String>, second: Set<String>) -> String {
        var queue = [target]
        var seen: Set<String> = []
        var position = 0
        while position < queue.count {
            let id = queue[position]
            position += 1
            guard seen.insert(id).inserted else { continue }
            guard let fact = closure.fact(id), let step = fact.step else { continue }
            let hypotheses = Set(step.hypotheses)
            if hypotheses.count > 1 && !hypotheses.isSubset(of: first) && !hypotheses.isSubset(of: second) {
                return step.relationID
            }
            queue.append(contentsOf: step.hypotheses)
        }
        return "?"
    }
}
