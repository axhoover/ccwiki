import Foundation

/// What the curation did to one proof, entry by entry: what the explorer's
/// Adjustments section shows, beside the wiki's own text
/// (plans/relations-followups.md §2.5, §6.4).
///
/// **Why.** The curation changes answers in ways no proof row shows. DDH ⇒
/// MPC rests on DMO00 establishing the malicious OT that Kil88 needs; DDH ⇒
/// PRG takes three steps because BM84 was refused on the way. A reader
/// cannot check what they cannot see, so every entry that shaped a proof is
/// named once, with what it did there.
///
/// A pure reading of the answer the explorer already has, plus the one
/// closure that answer came from: the engine is never rerun. A trace is one
/// proof's, so Show It swaps the stronger proof's in with its proof.
struct CurationTrace: Sendable, Hashable {

    /// What one entry did to the proof: §2.5's table, row by row.
    enum Effect: Sendable, Hashable {
        /// A precondition the derivation assumes of a given. The proof row
        /// already says "assuming …".
        case assumed(relationID: String, isReverse: Bool, hypothesis: String)
        /// A precondition met by the step that gives the hypothesis, whose
        /// own Statement establishes it (`metBy`).
        case establishedBy(relationID: String, isReverse: Bool, hypothesis: String, producer: String)
        /// A step refused on the way for its precondition, which would have
        /// concluded an object on the proof, and which neither proof uses.
        case notUsedHere(relationID: String, isReverse: Bool, hypothesis: String, producer: String)
        /// A weaker result, kept apart from the node's full one. The proof
        /// row already says "gives …".
        case keptApart(relationID: String)
        /// A step that takes a weaker result for its hypothesis, as the
        /// weakening allows (`acceptedBy`).
        case accepted(producer: String, consumer: String)
        /// A direction of an equivalence that the record's class does not
        /// cover, so it is used unstated.
        case unstatedDirection(relationID: String, isReverse: Bool)
        /// A start the wiki says is false. The verdict already says vacuous.
        case vacuous(objectID: String)
        /// A start that is a setting, not an assumption. The verdict says so.
        case setting(objectID: String)

        /// The entry it belongs to.
        var entryKey: DerivationCuration.Entry.Key {
            switch self {
            case .assumed(let relationID, let isReverse, let hypothesis),
                 .establishedBy(let relationID, let isReverse, let hypothesis, _),
                 .notUsedHere(let relationID, let isReverse, let hypothesis, _):
                .requirement(relationID: relationID, isReverse: isReverse, hypothesis: hypothesis)
            case .keptApart(let relationID), .accepted(let relationID, _):
                .weakening(relationID: relationID)
            case .unstatedDirection(let relationID, _):
                .equivalence(relationID: relationID)
            case .vacuous(let objectID):
                .refuted(objectID: objectID)
            case .setting(let objectID):
                .setting(objectID: objectID)
            }
        }

        /// §2.5's table order, which an item's sentences read in.
        fileprivate var rank: Int {
            switch self {
            case .assumed: 0
            case .establishedBy: 1
            case .keptApart: 2
            case .accepted: 3
            case .unstatedDirection: 4
            case .notUsedHere: 5
            case .vacuous: 6
            case .setting: 7
            }
        }
    }

    /// One entry, with everything it did to this proof.
    struct Item: Sendable, Hashable, Identifiable {
        let entry: DerivationCuration.Entry
        /// In §2.5's order, each once.
        let effects: [Effect]
        var id: String { entry.id }
    }

    /// In the curation's order, each entry once. An entry that did nothing
    /// to this proof is not here.
    let items: [Item]
    var isEmpty: Bool { items.isEmpty }

    private typealias Row = Derivation.ProofTree.Row

    // MARK: Tracing

    /// One proof's trace, the starts' items included. `other` is the answer's
    /// other proof, if any: a step refused on the way that lands on it is not
    /// "not used here". `closure` is the answer's own, whose `refused` holds
    /// each step's first refusal.
    static func derived(_ proof: Derivation.ProofTree, other: Derivation.ProofTree?,
                        closure: Derivation.Closure, start: [String],
                        derivation: Derivation) -> CurationTrace {
        let rows = proof.rows
        var effects: [Effect] = []
        for (index, row) in rows.enumerated() {
            guard let step = row.step else { continue }
            let children = Self.children(of: index, in: rows)

            for requirement in step.requirements {
                if row.assumed.contains(requirement) {
                    effects.append(.assumed(relationID: step.relationID, isReverse: step.isReverse,
                                            hypothesis: requirement.hypothesis))
                } else if let input = children.first(where: { $0.objectID == requirement.hypothesis }),
                          let producer = Self.step(of: input, in: rows) {
                    effects.append(.establishedBy(
                        relationID: step.relationID, isReverse: step.isReverse,
                        hypothesis: requirement.hypothesis, producer: producer.relationID))
                }
            }
            if let weakening = row.weakening {
                effects.append(.keptApart(relationID: weakening.relationID))
            }
            for child in children where child.isWeakened {
                guard let weakening = child.weakening else { continue }
                effects.append(.accepted(producer: weakening.relationID, consumer: step.relationID))
            }
            if let effect = Self.unstatedDirection(step, derivation: derivation) {
                effects.append(effect)
            }
        }
        effects += Self.notUsedHere(proof, other: other, closure: closure)
        effects += Self.startEffects(start, derivation: derivation)
        return Self.grouped(effects, curation: derivation.curation)
    }

    /// A no-derivation answer's: only what the starts are. Its refused steps
    /// carry their entries on their own rows.
    static func starts(_ start: [String], derivation: Derivation) -> CurationTrace {
        Self.grouped(Self.startEffects(start, derivation: derivation), curation: derivation.curation)
    }

    /// A quote as the chrome shows it: wikilinks and markdown links reduced
    /// to their text, then emphasis and backticks dropped and math made
    /// plain, so BM84's `$\ZZ_p^*$` reads `ℤ_p^*`.
    static func plainQuote(_ markdown: String) -> String {
        PreviewExcerpt.plainText(PreviewExcerpt.inlineWithoutLinks(markdown))
    }

    // MARK: The table, row by row

    /// The rows directly under `index`: its step's hypotheses, in the edge's
    /// order (`Derivation.Closure.proof(of:)`).
    private static func children(of index: Int, in rows: [Row]) -> [Row] {
        let level = rows[index].level
        var children: [Row] = []
        var position = index + 1
        while position < rows.count, rows[position].level > level {
            if rows[position].level == level + 1 { children.append(rows[position]) }
            position += 1
        }
        return children
    }

    /// The step that concluded a row's fact: its own, or, for "shown
    /// above", the first occurrence's. `nil` for a given.
    private static func step(of row: Row, in rows: [Row]) -> Derivation.Step? {
        if let step = row.step { return step }
        return rows.first {
            $0.objectID == row.objectID && $0.isWeakened == row.isWeakened && $0.step != nil
        }?.step
    }

    /// R1: the curation leaves this direction of an equivalence unstated.
    /// The step's own class settles whether that is what happened here: a
    /// class the manifest records for the direction itself (`reverseClass`,
    /// relations-followups.md §4.4) is the wiki's, and gives the step that
    /// class rather than `unstated`.
    private static func unstatedDirection(_ step: Derivation.Step,
                                          derivation: Derivation) -> Effect? {
        guard derivation.manifest.reduction(step.relationID)?.kind == .equivalence,
              let directions = derivation.curation.equivalences[step.relationID]
        else { return nil }
        let recorded = step.isReverse ? directions.isReverseRecorded : directions.isForwardRecorded
        guard !recorded, step.reductionClass == Derivation.unstatedClass else { return nil }
        return .unstatedDirection(relationID: step.relationID, isReverse: step.isReverse)
    }

    /// R13's refusals that shaped the proof without a row on it: a step
    /// refused for its precondition that would have concluded an object the
    /// proof derives another way. The engine keeps a step's first refusal
    /// even when the step fires later, on a better input, so a step on
    /// either proof is left out.
    private static func notUsedHere(_ proof: Derivation.ProofTree, other: Derivation.ProofTree?,
                                    closure: Derivation.Closure) -> [Effect] {
        let objects = Set(proof.rows.map { $0.objectID })
        var used = Set(proof.rows.compactMap { $0.step?.key })
        for row in other?.rows ?? [] {
            if let step = row.step { used.insert(step.key) }
        }
        var effects: [Effect] = []
        for refused in closure.refused
        where objects.contains(refused.step.conclusion) && !used.contains(refused.step.key) {
            for reason in refused.reasons {
                guard case .requires(let hypothesis, _, let producedBy) = reason else { continue }
                effects.append(.notUsedHere(
                    relationID: refused.step.relationID, isReverse: refused.step.isReverse,
                    hypothesis: hypothesis, producer: producedBy))
            }
        }
        return effects
    }

    /// R14: a refuted start, and a start that is a setting.
    ///
    /// A refutation the manifest records (`refutedBy`, §4.4 ask 2) is the
    /// wiki's own, and makes no item: it stays in the verdict line.
    /// `DerivationCuration.adding(refutations:)` puts the manifest's record in
    /// place of the file's and leaves the file's entry, whose prose is the
    /// file's refutation's evidence; so the refutation in force is CCwiki's
    /// exactly when the two agree.
    private static func startEffects(_ start: [String], derivation: Derivation) -> [Effect] {
        let curation = derivation.curation
        var effects: [Effect] = []
        for id in start {
            if let refutation = curation.refuted[id],
               let entry = curation.entry(.refuted(objectID: id)),
               refutation.evidence == entry.evidence {
                effects.append(.vacuous(objectID: id))
            }
            if curation.settings[id] != nil {
                effects.append(.setting(objectID: id))
            }
        }
        return effects
    }

    /// One item per entry, in the curation's order, each with its effects
    /// once, in the table's order.
    private static func grouped(_ effects: [Effect], curation: DerivationCuration) -> CurationTrace {
        var byEntry: [DerivationCuration.Entry.Key: [Effect]] = [:]
        for effect in effects {
            let found = byEntry[effect.entryKey] ?? []
            if !found.contains(effect) { byEntry[effect.entryKey] = found + [effect] }
        }
        let items = curation.entries.compactMap { (entry) -> Item? in
            guard let found = byEntry[entry.key] else { return nil }
            // By rank, then as found: `sorted` promises no stability.
            let ordered = found.enumerated().sorted {
                ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset)
            }
            return Item(entry: entry, effects: ordered.map { $0.element })
        }
        return CurationTrace(items: items)
    }
}
