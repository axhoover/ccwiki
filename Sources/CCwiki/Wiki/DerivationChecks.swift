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
            // Step by step: a quarantine of one direction of an equivalence
            // leaves the other direction a step.
            return relation.kind == .inclusion || relation.heuristic
                || curation.quarantineReason(step.relationID, isReverse: step.isReverse) != nil
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
        /// No entry is one the manifest now records itself: a `reverseClass`,
        /// a `refutedBy`, or a setting that is no longer the sole hypothesis
        /// of any eligible step (relations-followups.md §4.4). A warning
        /// only: each is an entry to retire, and the engine already reads the
        /// record over the first two.
        var curationSuperseded = true
        var unresolved: [String] = []
        var uncuratedRegime: [String] = []
        var unreviewedEquivalences: [String] = []
        /// The superseded entries' ids, in the curation's order.
        var superseded: [String] = []

        var byName: [String: Bool] {
            [
                "curationResolves": curationResolves,
                "regimeLossCurated": regimeLossCurated,
                "equivalencesReviewed": equivalencesReviewed,
                "curationSuperseded": curationSuperseded,
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

        result.superseded = supersededEntries()
        result.curationSuperseded = result.superseded.isEmpty
        return result
    }

    /// The `curationSuperseded` sentinel's entries, the reference engine's
    /// `superseded`. The curation's `entries` are the file's alone, so a
    /// manifest refutation merged into `curation` is never one of them.
    private func supersededEntries() -> [String] {
        var soleHypotheses: Set<String> = []
        for step in steps where step.hypotheses.count == 1 {
            soleHypotheses.insert(step.hypotheses[0])
        }
        var ids: [String] = []
        for entry in curation.entries {
            switch entry.key {
            case .equivalence(let relationID):
                if let relation = manifest.reduction(relationID), relation.kind == .equivalence,
                   relation.reverseClass != nil {
                    ids.append(entry.id)
                }
            case .refuted(let objectID):
                if let object = manifest.object(objectID), !object.refutedBy.isEmpty {
                    ids.append(entry.id)
                }
            case .setting(let objectID):
                if !soleHypotheses.contains(objectID) { ids.append(entry.id) }
            case .quarantine, .requirement, .statementLint, .weakening:
                break
            }
        }
        return ids
    }

    // MARK: Quotes (relations-followups.md §2.2)

    /// A citation whose quote is not on its page, or whose page could not be
    /// read.
    struct MissingQuote: Hashable, Sendable {
        let entryID: String
        let citation: DerivationCuration.Citation
    }

    /// Every citation of every curation entry that `CurationQuote.contains`
    /// does not find, in the curation's order. `pageText` takes a
    /// content-relative path (`Citation.contentPath`), as
    /// `statementLint(pageText:)` does, so this type stays free of I/O; a
    /// page it cannot read counts as missing. Each page is read once.
    func missingQuotes(pageText: (String) -> String?) -> [MissingQuote] {
        var texts: [String: String] = [:]
        var unreadable: Set<String> = []
        var missing: [MissingQuote] = []
        for entry in curation.entries {
            for citation in entry.cites {
                let path = citation.contentPath
                if texts[path] == nil, !unreadable.contains(path) {
                    if let text = pageText(path) {
                        texts[path] = text
                    } else {
                        unreadable.insert(path)
                    }
                }
                let found = texts[path].map {
                    CurationQuote.contains(citation.quote, section: citation.section, in: $0)
                } ?? false
                if !found {
                    missing.append(MissingQuote(entryID: entry.id, citation: citation))
                }
            }
        }
        return missing
    }

    // MARK: Curated edges (relations-followups.md §2.4, §4.4)

    /// A reduction a curation entry names, as the manifest records it: the
    /// golden file's `curatedEdges` holds one per id, at the reviewed commit.
    struct CuratedEdge: Hashable, Sendable {
        let kind: String
        let hypotheses: [String]
        let conclusion: String
        let reductionClass: String
        let model: String

        /// The same edge with its hypotheses sorted. A conjunction is a set,
        /// but the manifest keeps each in its page's order, so a page that
        /// reorders its `hypotheses` states the same theorem.
        var normalised: CuratedEdge {
            CuratedEdge(
                kind: kind, hypotheses: hypotheses.sorted(by: Derivation.precedes),
                conclusion: conclusion, reductionClass: reductionClass, model: model)
        }
    }

    /// A curated edge the manifest records differently from the snapshot.
    struct ChangedEdge: Hashable, Sendable {
        let relationID: String
        /// The entries that name it, in the curation's order.
        let entryIDs: [String]
        let was: CuratedEdge
        /// `nil`: the edge is gone.
        let now: CuratedEdge?
        /// Kind, hypotheses or conclusion changed, or class or model on an
        /// `equivalences` edge. Otherwise a warning.
        let fails: Bool
    }

    /// `relationID` as the manifest records it now, or `nil`.
    func curatedEdge(_ relationID: String) -> CuratedEdge? {
        guard let relation = manifest.reduction(relationID) else { return nil }
        return CuratedEdge(
            kind: relation.kind.rawValue, hypotheses: relation.hypotheses,
            conclusion: relation.conclusion, reductionClass: relation.reductionClass,
            model: relation.model)
    }

    /// Every reduction the curation names (each entry's edge, every `metBy`
    /// and `acceptedBy` id) → the ids of the entries naming it, in the
    /// curation's order.
    func curatedRelations() -> [String: [String]] {
        var naming: [String: [String]] = [:]
        func add(_ relationID: String, _ entryID: String) {
            if !(naming[relationID]?.contains(entryID) ?? false) {
                naming[relationID, default: []].append(entryID)
            }
        }
        for entry in curation.entries {
            switch entry.key {
            case .refuted, .setting:
                break
            case .quarantine(let relationID), .equivalence(let relationID),
                 .statementLint(let relationID):
                add(relationID, entry.id)
            case .requirement(let relationID, let isReverse, let hypothesis):
                add(relationID, entry.id)
                let requirement = curation.requirements(on: relationID, isReverse: isReverse)
                    .first { $0.hypothesis == hypothesis }
                for producer in (requirement?.metBy ?? []).sorted(by: Self.precedes) {
                    add(producer, entry.id)
                }
            case .weakening(let relationID):
                add(relationID, entry.id)
                let consumers = curation.weakens[relationID]?.acceptedBy ?? []
                for consumer in consumers.sorted(by: Self.precedes) {
                    add(consumer, entry.id)
                }
            }
        }
        return naming
    }

    /// The curated edges whose record has moved since `snapshot`, sorted by
    /// id: the corpus test's `curationEdgesUnchanged`. A changed kind,
    /// hypothesis or conclusion under a kept id means an entry now corrects a
    /// different theorem, and so does a class or model change on an edge
    /// whose directions the curation types; those fail. A class or model
    /// change elsewhere touches no notion requirement, so it is a warning.
    /// Hypotheses compare as a set: reordering them changes nothing.
    func changedCuratedEdges(since snapshot: [String: CuratedEdge]) -> [ChangedEdge] {
        let naming = curatedRelations()
        var equivalenceEdges: Set<String> = []
        for entry in curation.entries {
            if case .equivalence(let relationID) = entry.key { equivalenceEdges.insert(relationID) }
        }
        var changed: [ChangedEdge] = []
        for relationID in snapshot.keys.sorted(by: Self.precedes) {
            guard let was = snapshot[relationID] else { continue }
            let now = curatedEdge(relationID)
            guard now?.normalised != was.normalised else { continue }
            var fails = true
            if let now {
                let sameTheorem = now.kind == was.kind
                    && now.normalised.hypotheses == was.normalised.hypotheses
                    && now.conclusion == was.conclusion
                let sameTyping = now.reductionClass == was.reductionClass && now.model == was.model
                fails = !sameTheorem || (equivalenceEdges.contains(relationID) && !sameTyping)
            }
            changed.append(ChangedEdge(
                relationID: relationID, entryIDs: naming[relationID] ?? [], was: was, now: now,
                fails: fails))
        }
        return changed
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
        // The reference engine reads a page in Python's text mode, which turns
        // "\r\n" and a lone "\r" into "\n". Without the same here the heading
        // would never match on a page saved with other line endings, and the
        // lint would pass it silently where the reference reports a hit.
        let text = page.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = statementPattern.firstMatch(in: text, range: range),
              let body = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[body]).trimmingCharacters(in: .whitespacesAndNewlines)
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
