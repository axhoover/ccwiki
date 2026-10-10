import Foundation

// What the corpus test asserts whatever the wiki commit (derivations.md §8):
// the invariants, which say the record and the engine agree with each other,
// and the sentinels and Statement lint, which say the wiki has not moved
// under the curation. Each is the reference engine's function of the same
// name, so the golden file's booleans can be compared one for one.

extension Derivation {

    struct Invariants: Hashable, Sendable {
        /// No inclusion, heuristic, quarantined or class-endpoint edge is a
        /// step (R1, R2, R13).
        var noIneligibleEdges = true
        /// No default-model fact carries an idealised model or is
        /// model-scoped (R4).
        var defaultHasNoIdealisedModels = true
        /// No clean standard-model derivation of any class meets a recorded
        /// barrier's ruling-out consequence (R8).
        var noChainContradictsRecordedBarrier = true
        /// … nor proves a believed-true proposition (R8).
        var noChainProvesBelievedProposition = true
        /// … nor meets a derived barrier (R12).
        var noChainContradictsDerivedBarrier = true
        /// No recorded standard-model reduction on a derived barrier's own
        /// pair has a class it rules out, even one the engine does not use.
        var noDerivedBarrierContradictsRecordedReduction = true
        /// R5's worked examples.
        var romDoesNotReachOT = true
        var romDoesNotReachKE = true
        /// The first few offenders of each failed check, for the message.
        var details: [String] = []

        /// By the reference engine's names.
        var byName: [String: Bool] {
            [
                "noIneligibleEdges": noIneligibleEdges,
                "defaultHasNoIdealisedModels": defaultHasNoIdealisedModels,
                "noChainContradictsRecordedBarrier": noChainContradictsRecordedBarrier,
                "noChainProvesBelievedProposition": noChainProvesBelievedProposition,
                "noChainContradictsDerivedBarrier": noChainContradictsDerivedBarrier,
                "noDerivedBarrierContradictsRecordedReduction":
                    noDerivedBarrierContradictsRecordedReduction,
                "romDoesNotReachOT": romDoesNotReachOT,
                "romDoesNotReachKE": romDoesNotReachKE,
            ]
        }
    }

    func invariants() -> Invariants {
        var result = Invariants()

        let ineligible = steps.filter { step in
            guard let relation = manifest.reduction(step.relationID) else { return false }
            let ends = relation.hypotheses + [relation.conclusion]
            return relation.kind == .inclusion || relation.heuristic
                || curation.quarantine[step.relationID] != nil
                || ends.contains { nodeType($0) == Self.excludedType }
        }
        result.noIneligibleEdges = ineligible.isEmpty
        if !ineligible.isEmpty {
            result.details.append("ineligible: \(ineligible.prefix(10).map { $0.relationID })")
        }

        var leaks: [String] = []
        for start in manifest.objectsByID.keys.sorted(by: Self.precedes)
        where nodeType(start) != Self.excludedType {
            let closure = self.closure(from: [start], options: .standard)
            for fact in Array(closure.facts.values) + Array(closure.weakFacts.values) {
                let leaksModel = !fact.models.subtracting(Self.defaultModels).isEmpty
                if leaksModel || (fact.isModelScoped && fact.step != nil) {
                    leaks.append("\(start) ⇒ \(fact.objectID)")
                }
            }
        }
        result.defaultHasNoIdealisedModels = leaks.isEmpty
        if !leaks.isEmpty { result.details.append("leaks: \(leaks.prefix(10))") }

        var conflicts: [String] = []
        var majors: [String] = []
        for barrier in manifest.barriers.sorted(by: { Self.precedes($0.id, $1.id) })
        where barrier.status != .stub {
            for rule in Self.consequenceRules(of: barrier, in: manifest) {
                guard let effect = rule.effect,
                      let chain = chainExists(from: barrier.hypotheses, to: barrier.conclusion,
                                              against: rule.reductionClass)
                else { continue }
                let entry = "\(barrier.id)#\(rule.index) by a \(chain.rawValue) chain"
                switch effect {
                case .rulesOut: conflicts.append(entry)
                case .majorResult: majors.append(entry)
                }
            }
        }
        result.noChainContradictsRecordedBarrier = conflicts.isEmpty
        result.noChainProvesBelievedProposition = majors.isEmpty
        if !conflicts.isEmpty { result.details.append("conflicts: \(conflicts.prefix(10))") }
        if !majors.isEmpty { result.details.append("major results: \(majors.prefix(10))") }

        var derivedConflicts: [String] = []
        var recordedAgainstDerived: [String] = []
        for derived in derivedBarriers {
            if let chain = chainExists(from: derived.hypotheses, to: derived.conclusion,
                                       against: derived.reductionClass.rawValue) {
                derivedConflicts.append(
                    "\(derived.barrier.id) on \(derived.hypothesis) ⇒ \(derived.conclusion) "
                        + "by a \(chain.rawValue) chain")
            }
            // Even one the engine does not use: a stub's class is not
            // evidence, and a heuristic edge is not a theorem.
            for relation in manifest.reductions
            where relation.hypotheses == derived.hypotheses && relation.conclusion == derived.conclusion
                && relation.model == Self.standardModel && relation.status != .stub
                && !relation.heuristic
                && implies(relation.reductionClass, derived.reductionClass.rawValue) {
                recordedAgainstDerived.append("\(derived.barrier.id) vs \(relation.id)")
            }
        }
        result.noChainContradictsDerivedBarrier = derivedConflicts.isEmpty
        result.noDerivedBarrierContradictsRecordedReduction = recordedAgainstDerived.isEmpty
        if !derivedConflicts.isEmpty {
            result.details.append("derived conflicts: \(derivedConflicts.prefix(10))")
        }
        if !recordedAgainstDerived.isEmpty {
            result.details.append("recorded vs derived: \(recordedAgainstDerived.prefix(10))")
        }

        let fromROM = [Options.standard, Options.all].map { closure(from: ["rom"], options: $0) }
        result.romDoesNotReachOT = fromROM.allSatisfy { $0.facts["ot"] == nil }
        result.romDoesNotReachKE = fromROM.allSatisfy { $0.facts["ke"] == nil }
        return result
    }

    struct Sentinels: Hashable, Sendable {
        /// Every id in the curation resolves. The corpus test fails on this.
        var curationResolves = true
        /// Every eligible reduction whose `securityLoss` names a regime has a
        /// `requires` entry. The corpus test fails on this.
        var regimeLossCurated = true
        /// Every eligible equivalence is reviewed. A warning only: an
        /// unreviewed one is already unstated both ways.
        var equivalencesReviewed = true
        var unresolved: [String] = []
        var uncuratedRegime: [String] = []
        var unreviewedEquivalences: [String] = []

        var byName: [String: Bool] {
            [
                "curationResolves": curationResolves,
                "regimeLossCurated": regimeLossCurated,
                "equivalencesReviewed": equivalencesReviewed,
            ]
        }
    }

    func sentinels() -> Sentinels {
        var result = Sentinels()
        result.unresolved = curation.unresolved(in: manifest)
        result.curationResolves = result.unresolved.isEmpty

        let curated = Set(curation.requires.map { $0.relationID })
        var regime: Set<String> = []
        for step in steps where !curated.contains(step.relationID) {
            let loss = manifest.reduction(step.relationID)?.securityLoss.lowercased() ?? ""
            if Self.regimeWords.contains(where: { loss.contains($0) }) {
                regime.insert(step.relationID)
            }
        }
        result.uncuratedRegime = regime.sorted(by: Self.precedes)
        result.regimeLossCurated = regime.isEmpty

        result.unreviewedEquivalences = unreviewedEquivalences
        result.equivalencesReviewed = unreviewedEquivalences.isEmpty
        return result
    }

    // MARK: Statement lint (§2a)

    /// A possible dropped conjunct: an assumption a step's Statement names
    /// before its citation that is neither an endpoint nor an endpoint's host.
    struct LintHit: Hashable, Sendable {
        let relationID: String
        let hypotheses: [String]
        let unlisted: [String]
    }

    /// The Statement lint over the clone's reduction pages. `pageText`
    /// returns a page's markdown given its content-relative path
    /// (`Relation.path`), so this type stays free of I/O. Quarantined
    /// reductions are not steps, and those the curation lists under
    /// `statementLint` are skipped as reviewed.
    func statementLint(pageText: (String) -> String?) -> [LintHit] {
        var index: [LintKey: String] = [:]
        for id in manifest.objectsByID.keys.sorted(by: Self.precedes) {
            guard let object = manifest.object(id) else { continue }
            index[LintKey(slug: object.slug, anchor: object.anchor ?? "")] = id
        }

        var hits: [LintHit] = []
        let relationIDs = Set(steps.map { $0.relationID }).sorted(by: Self.precedes)
        for relationID in relationIDs where curation.statementLint[relationID] == nil {
            guard let relation = manifest.reduction(relationID) else { continue }
            let statement = Self.statement(in: pageText(relation.path) ?? "")
            let claim = statement.components(separatedBy: " \u{2014} ").first ?? ""
            var linked: Set<String> = []
            for link in Self.linkTargets(in: claim) {
                let id = index[LintKey(slug: link.slug, anchor: link.anchor)]
                    ?? index[LintKey(slug: link.slug, anchor: "")]
                if let id, nodeType(id) == "assumption" {
                    linked.insert(id)
                }
            }
            var ends = Set(relation.hypotheses)
            ends.insert(relation.conclusion)
            var allowed = ends
            for end in ends {
                if let host = manifest.object(end)?.of { allowed.insert(host) }
            }
            let missing = linked.subtracting(allowed).sorted(by: Self.precedes)
            if !missing.isEmpty {
                hits.append(LintHit(relationID: relationID, hypotheses: relation.hypotheses,
                                    unlisted: missing))
            }
        }
        return hits
    }

    private struct LintKey: Hashable {
        let slug: String
        let anchor: String
    }

    // These patterns are the reference engine's, character for character,
    // except that Python's `\Z` (the very end) is ICU's `\z`. None has a `#`
    // after a backslash, so single-hash raw strings are safe.
    private static let statementPattern = try! NSRegularExpression(
        pattern: #"## Statement\n(.*?)(\n## |\z)"#, options: [.dotMatchesLineSeparators])
    private static let wikilinkPattern = try! NSRegularExpression(
        pattern: #"\[\[([^\]|#]+)(?:#([^\]|]+))?(?:\|[^\]]*)?\]\]"#)
    private static let markdownLinkPattern = try! NSRegularExpression(
        pattern: #"\]\(([^)#\s]+)(?:#([^)\s]+))?\)"#)

    /// The text under the first `## Statement` heading, trimmed.
    static func statement(in page: String) -> String {
        let range = NSRange(page.startIndex..<page.endIndex, in: page)
        guard let match = statementPattern.firstMatch(in: page, range: range),
              let body = Range(match.range(at: 1), in: page)
        else { return "" }
        return String(page[body]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wikilink targets, then markdown-link targets, as (slug, anchor).
    static func linkTargets(in text: String) -> [(slug: String, anchor: String)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var targets: [(slug: String, anchor: String)] = []
        for pattern in [wikilinkPattern, markdownLinkPattern] {
            for match in pattern.matches(in: text, range: range) {
                guard let slug = Range(match.range(at: 1), in: text) else { continue }
                let anchor = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
                targets.append((slug: String(text[slug]), anchor: anchor))
            }
        }
        return targets
    }
}
