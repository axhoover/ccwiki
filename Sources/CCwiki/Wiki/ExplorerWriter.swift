import Foundation

/// How the explorer names objects, reductions and barriers, and the rows it
/// builds from them.
///
/// Plain text for the chrome: titles go through `RelationText.plain`, ids
/// through `RelationLabels`, so a row never shows raw TeX or an id where a
/// name exists. A conjunction is always written whole, `A ∧ B`.
struct ExplorerWriter: Sendable {
    let derivation: Derivation
    let labels: RelationLabels

    var manifest: RelationsManifest { derivation.manifest }

    // MARK: Names

    func label(_ id: String) -> String { labels.label(id) }

    /// `A ∧ B`, in the order given.
    func conjunction(_ ids: [String]) -> String {
        DerivationWording.conjoined(ids.map { labels.label($0) })
    }

    /// "A and B", for a sentence.
    func listed(_ ids: [String]) -> String {
        DerivationWording.list(ids.map { labels.label($0) })
    }

    /// The citation keys a record is shown by: `CS03`, `folklore`.
    func citations(_ source: [String]) -> [String] {
        var keys: [String] = []
        for entry in source {
            guard let key = RelationText.citationKey(entry), !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    func citations(of relationID: String) -> [String] {
        manifest.reduction(relationID).map { citations($0.source) } ?? []
    }

    /// A reduction's own title, as plain text, or its statement when the
    /// title is empty.
    func reductionTitle(_ relationID: String) -> String {
        guard let relation = manifest.reduction(relationID) else { return relationID }
        let title = RelationText.plain(relation.title)
        return title.isEmpty ? labels.statement(relation) : title
    }

    /// "CS03: KEM + SKE ⇒ PKE": how a menu names a reduction.
    func reductionName(_ relationID: String) -> String {
        let keys = citations(of: relationID)
        let title = reductionTitle(relationID)
        return keys.isEmpty ? title : keys.joined(separator: ", ") + ": " + title
    }

    /// One step as a sentence names it: `OIHF ⇒ OT (BH26)`, the whole
    /// conjunction on the left.
    func stepText(_ step: Derivation.Step) -> String {
        let keys = citations(of: step.relationID)
        let edge = "\(conjunction(step.hypotheses)) \(DerivationWording.recordedArrow) "
            + label(step.conclusion)
        return keys.isEmpty ? edge : edge + " (" + keys.joined(separator: ", ") + ")"
    }

    /// A reduction class as a row names it: "fully black-box", "free",
    /// "unstated". `unstated`, a sentinel, or a class the manifest does not
    /// define is shown as unstated: CCwiki never guesses one.
    func className(_ name: String) -> String {
        if name.isEmpty || manifest.isSentinel(name) || manifest.classes[name] == nil {
            return Derivation.unstatedClass
        }
        return manifest.classTitle(name).lowercased()
    }

    /// Steps of the proof that state no composable class: what makes a
    /// chain `unstated`, for "Class unstated: N steps do not state theirs".
    func unstatedSteps(_ proof: Derivation.ProofTree) -> Int {
        let free = Derivation.ChainClass.free.rawValue
        var count = 0
        for row in proof.rows {
            guard let step = row.step else { continue }
            if !derivation.implies(step.reductionClass, free) { count += 1 }
        }
        return count
    }

    /// "assuming …", for one or more preconditions a derivation assumes of a
    /// given (R13).
    func assuming(_ notions: [String]) -> String? {
        let distinct = Array(Set(notions)).sorted(by: Derivation.precedes)
        guard !distinct.isEmpty else { return nil }
        return "assuming " + distinct.joined(separator: "; ")
    }

    // MARK: Statements

    /// What Copy Statement puts on the pasteboard for a derived or recorded
    /// fact: the claim with its provenance, so a pasted line never passes
    /// for the wiki's own when it is not, and with its `qualifiers`
    /// (`qualifiers(of:)`), so it never passes for an unconditional claim.
    func factStatement(from start: [String], to target: String, depth: Int,
                       relationIDs: [String], qualifiers: [String]) -> String {
        let conditions = qualifiers.map { ", " + $0 }.joined()
        if depth <= 1 {
            let keys = relationIDs.flatMap { citations(of: $0) }
            let source = keys.isEmpty ? "" : ": " + keys.joined(separator: ", ")
            return "\(conjunction(start)) \(DerivationWording.recordedArrow) \(label(target)) "
                + "(recorded in the wiki\(source)\(conditions))"
        }
        return "\(conjunction(start)) \(DerivationWording.derivedArrow) \(label(target)) "
            + "(\(DerivationWording.derivedBy(relationIDs.count).lowercasedFirst)\(conditions))"
    }

    /// A fact's conditions (R13), as its row's notes show them and a copied
    /// statement carries them, a copy leaving the row behind: "assuming …"
    /// for the preconditions assumed of a given, then "only …" for a
    /// weakened fact.
    func qualifiers(of fact: Derivation.Fact) -> [String] {
        [assuming(fact.assumes.map { $0.notion }), fact.weakening.map { "only " + $0.notion }]
            .compactMap { $0 }
    }

    /// The same, read off a proof: what its steps assume, and its root's
    /// weakening. For R6's stronger proof, which may assume less than the
    /// fact shown.
    func qualifiers(of proof: Derivation.ProofTree) -> [String] {
        let assumed = proof.rows.flatMap { row in row.assumed.map { $0.notion } }
        return [assuming(assumed), proof.rows.first?.weakening.map { "only " + $0.notion }]
            .compactMap { $0 }
    }

    // MARK: Proof steps

    /// The meta line of a step: `⇐ KEM + SKE ⇒ PKE · CS03 · fully black-box ·
    /// needs both`.
    func stepDetail(_ step: Derivation.Step) -> String {
        var parts = [DerivationWording.byStep + " " + reductionTitle(step.relationID)]
        if step.isReverse { parts.append("⇔, used right to left") }
        let keys = citations(of: step.relationID)
        if !keys.isEmpty { parts.append(keys.joined(separator: ", ")) }
        parts.append(className(step.reductionClass))
        switch step.hypotheses.count {
        case 0, 1: break
        case 2: parts.append("needs both")
        default: parts.append("needs all \(step.hypotheses.count)")
        }
        return parts.joined(separator: " · ")
    }

    /// The tooltip of a step: the reduction's statement, then the wiki's
    /// reasons for its class and model, then its security loss, as the
    /// inspector's tooltip reads.
    func stepHelp(_ step: Derivation.Step) -> String {
        guard let relation = manifest.reduction(step.relationID) else { return stepText(step) }
        var lines = [labels.statement(relation)]
        if step.isReverse {
            lines.append("An equivalence, used right to left.")
        }
        if step.hypotheses.count > 1 {
            lines.append("A conjunction: the theorem needs every hypothesis, not any one of them.")
        }
        if step.isStub {
            lines.append("A stub: its class and model are not evidence.")
        } else {
            if let why = relation.why("class") {
                lines.append("Why \(className(step.reductionClass)): \(why)")
            }
            if let why = relation.why("model"), !relation.model.isEmpty {
                lines.append("Why \(DerivationWording.modelName(relation.model)): \(why)")
            }
        }
        if !relation.securityLoss.isEmpty {
            lines.append("Security loss: \(RelationText.plain(relation.securityLoss))")
        }
        return lines.joined(separator: "\n")
    }

    /// One proof row. `id` is unique within the whole result.
    func proofRow(_ row: Derivation.ProofTree.Row, id: String, isRoot: Bool, conjunct: Bool,
                  firstOccurrence: String?) -> ExplorerRow {
        let name = label(row.objectID)

        if row.isGiven {
            var made = ExplorerRow(id: id, title: name, accessibilityLabel: "\(name), given")
            made.conjunct = conjunct
            made.badge = "given"
            made.help = "One of your premises."
            made.primary = .object(row.objectID)
            made.objectID = row.objectID
            made.exploreFrom = [row.objectID]
            made.statement = name
            return made
        }

        guard let step = row.step, !row.isReference else {
            var made = ExplorerRow(id: id, title: name, accessibilityLabel: "\(name), shown above")
            made.conjunct = conjunct
            made.detail = "shown above"
            made.help = "Shown once, above, with its proof."
            if let firstOccurrence { made.primary = ExplorerRow.Target.reveal(firstOccurrence) }
            made.objectID = row.objectID
            made.exploreFrom = [row.objectID]
            made.statement = name
            return made
        }

        // R1, R2: the engine never chains an inclusion, a heuristic
        // candidate or a step touching a complexity class. Rendering one as
        // a proof step would present a non-theorem as a step of a proof, so
        // a debug build stops here (relations-explorer.md §1).
        let isTheorem = manifest.reduction(step.relationID)
            .map { $0.kind != .inclusion && !$0.heuristic } ?? true
        assert(isTheorem, "\(step.relationID) is an inclusion or a heuristic candidate")
        assert((step.hypotheses + [step.conclusion]).allSatisfy {
            manifest.object($0)?.type != Derivation.excludedType
        }, "\(step.relationID) touches a complexity class")

        var made = ExplorerRow(id: id, title: name, accessibilityLabel: "")
        made.conjunct = conjunct
        made.emphasis = isRoot ? .strong : .normal
        made.detail = stepDetail(step)
        if let assumed = assuming(row.assumed.map { $0.notion }) { made.notes.append(assumed) }
        if let weakening = row.weakening {
            made.notes.append("gives " + weakening.notion)
        }
        if step.model != Derivation.standardModel { made.models = [step.model] }
        made.isStub = step.isStub
        made.help = stepHelp(step)
        if let relation = manifest.reduction(step.relationID) {
            made.primary = .page(relation.path)
            made.page = ExplorerRow.PageLink(
                kind: "Reduction", title: reductionName(step.relationID), path: relation.path)
        }
        made.objectID = row.objectID
        made.exploreFrom = [row.objectID]
        made.statement = stepText(step)

        let keys = citations(of: step.relationID)
        let by = keys.isEmpty ? reductionTitle(step.relationID) : keys.joined(separator: " and ")
        var sentence = "\(name), by \(by) from \(listed(step.hypotheses)), \(className(step.reductionClass))"
        if step.isReverse { sentence += ", an equivalence used right to left" }
        if step.model != Derivation.standardModel {
            sentence += ", \(DerivationWording.modelName(step.model))"
        }
        made.accessibilityLabel = sentence + "."
        return made
    }

    /// A line of Copy Proof as Text: `[source; class; model]` after a step.
    func proofCopyLine(_ row: Derivation.ProofTree.Row) -> String {
        let indent = String(repeating: "  ", count: row.level)
        let name = label(row.objectID)
        if row.isGiven { return indent + name + " (given)" }
        guard let step = row.step, !row.isReference else { return indent + name + " (shown above)" }
        let source = citations(of: step.relationID).joined(separator: ", ")
        let model = DerivationWording.modelName(step.model)
        let bracket = "[\(source.isEmpty ? "no source" : source); \(className(step.reductionClass)); \(model)]"
        let reverse = step.isReverse ? " (⇔, used right to left)" : ""
        return indent + name + " " + DerivationWording.byStep + " "
            + reductionTitle(step.relationID) + reverse + " " + bracket
    }

    // MARK: Barriers (R8)

    /// "against relativizing reductions · unconditional · IR89 · circumvented
    /// by BH26", with the model after the class when the barrier is proved
    /// outside the standard model. A stub's class and model are not
    /// evidence, so it has neither.
    func barrierMeta(_ barrier: Barrier) -> String {
        var parts: [String] = []
        if barrier.status != .stub {
            let name = className(barrier.reductionClass)
            parts.append(name == Derivation.unstatedClass
                ? "against reductions of a class the wiki does not state"
                : "against \(name) reductions")
            if barrier.model != Derivation.standardModel {
                parts.append(RelationVocabulary.modelName(barrier.model))
            }
        }
        parts.append(barrier.strength.rawValue)
        // A believed-true consequence is a major result, never "rules out".
        for rule in Derivation.consequenceRules(of: barrier, in: manifest)
        where rule.effect == .majorResult {
            parts.append("would imply " + proposition(rule.target))
        }
        parts.append(contentsOf: citations(barrier.source))
        if !barrier.circumventedBy.isEmpty {
            parts.append(circumvention(barrier.circumventedBy))
        }
        return parts.joined(separator: " · ")
    }

    /// "circumvented by BH26": the keys of the reductions that get around a
    /// barrier, which the manifest's contract says must always be shown.
    func circumvention(_ relationIDs: [String]) -> String {
        var found: [String] = []
        for id in relationIDs {
            for key in citations(of: id) where key != "folklore" && !found.contains(key) {
                found.append(key)
            }
        }
        return found.isEmpty ? "circumvented" : "circumvented by " + found.joined(separator: ", ")
    }

    func proposition(_ id: String) -> String {
        guard let proposition = manifest.propositions[id] else { return RelationLabels.humanized(id) }
        let title = RelationText.plain(proposition.title)
        return title.isEmpty ? RelationLabels.humanized(id) : title
    }

    func barrierTitle(_ barrier: Barrier) -> String {
        let title = RelationText.plain(barrier.title)
        return title.isEmpty ? "No reduction from \(conjunction(barrier.hypotheses)) to "
            + label(barrier.conclusion) : title
    }

    /// R8's qualifier as a sentence, for anywhere a barrier's title is
    /// printed in running text: the wiki writes every title as an
    /// unqualified "No reduction from A to B", and an unclassified,
    /// fixed-construction or stub barrier must never read as more.
    func qualifierSentence(_ barrier: Barrier) -> String? {
        Derivation.qualifier(of: barrier, in: manifest)?.explanation
    }

    func barrierHelp(_ barrier: Barrier) -> String {
        var lines = [barrierTitle(barrier)]
        if let qualifier = qualifierSentence(barrier) { lines.append(qualifier) }
        let name = className(barrier.reductionClass)
        let phrase = name == Derivation.unstatedClass
            ? "a reduction of unstated class" : "a \(name) reduction"
        for consequence in barrier.consequences {
            lines.append("The existence of \(phrase) here would imply "
                + labels.consequence(consequence, manifest: manifest) + ".")
        }
        if !barrier.conditionalOn.isEmpty {
            lines.append("Conditional on: "
                + barrier.conditionalOn.map { labels.assumption($0) }.joined(separator: ", "))
        }
        for relation in manifest.reductions(circumventing: barrier) {
            let keys = citations(relation.source).joined(separator: ", ")
            lines.append("Circumvented by \(labels.statement(relation))"
                + (keys.isEmpty ? "" : " (\(keys))") + ".")
        }
        if barrier.status == .stub {
            lines.append("A stub: its class and consequences are not evidence.")
        }
        return lines.joined(separator: "\n")
    }

    /// A recorded barrier, with the inspector's anatomy but its own title
    /// first: the explorer has no "your end", and the title names the class
    /// it rules out.
    func barrierRow(_ barrier: Barrier, id: String) -> ExplorerRow {
        let title = barrierTitle(barrier)
        var row = ExplorerRow(id: id, title: title, accessibilityLabel: "")
        row.glyph = .barrier
        row.qualifier = Derivation.qualifier(of: barrier, in: manifest)?.explanation
        row.detail = barrierMeta(barrier)
        // The wiki writes every title as an unqualified "No reduction from A
        // to B", so a barrier proved outside the standard model says so in a
        // sentence, as well as in its meta line (wiki-asks.md ask 3).
        if barrier.status != .stub, barrier.model != Derivation.standardModel {
            let model = RelationVocabulary.modelName(barrier.model)
            row.notes.append("This barrier is proved in the \(model).")
        }
        row.isStub = barrier.status == .stub
        row.help = barrierHelp(barrier)
        row.primary = .page(barrier.path)
        row.page = ExplorerRow.PageLink(kind: "Barrier", title: title, path: barrier.path)
        row.exploreFrom = barrier.hypotheses
        row.ask = ExplorerQuery(from: barrier.hypotheses, to: barrier.conclusion)
        row.statement = title
        row.accessibilityLabel = "Recorded barrier: \(title). " + (row.detail ?? "")
        return row
    }

    // MARK: Derived barriers (R12)

    /// A derived barrier shows its argument, not just its conclusion: "A
    /// relativizing reduction from OWF to CRHF would compose with OWP ⇒ OWF
    /// (fully black-box) into one from OWP to CRHF, which Sim98 rules out.
    /// Derived by CCwiki." The barrier and each side reduction are links.
    func derivedBarrierRow(_ derived: Derivation.DerivedBarrier, id: String) -> ExplorerRow {
        let barrier = derived.barrier
        let kind: String = switch derived.reductionClass {
        case .fullyBlackBox: "A fully black-box reduction"
        case .relativizing: "A relativizing reduction"
        case .free, .unstated: "A reduction"
        }
        var sides: [Derivation.Step] = []
        for member in derived.hypotheses {
            for step in derived.upPaths[member] ?? [] where !sides.contains(step) { sides.append(step) }
        }
        for step in derived.down where !sides.contains(step) { sides.append(step) }
        let sideTexts = sides.map { step in
            "\(conjunction(step.hypotheses)) ⇒ \(label(step.conclusion)) "
                + "(\(className(step.reductionClass)))"
        }
        let barrierKeys = citations(barrier.source).joined(separator: ", ")
        let citer = barrierKeys.isEmpty ? "the recorded barrier" : barrierKeys
        let consequence: String = switch derived.consequence.kind {
        case .complexity:
            "which would imply \(proposition(derived.consequence.target)), believed false (\(citer))"
        default:
            "which \(citer) rules out"
        }
        let origin = conjunction(barrier.hypotheses)
        let end = label(barrier.conclusion)
        var sentence = "\(kind) from \(conjunction(derived.hypotheses)) to \(label(derived.conclusion))"
            + " would compose"
        if !sideTexts.isEmpty { sentence += " with " + DerivationWording.list(sideTexts) }
        sentence += " into one from \(origin) to \(end), \(consequence). Derived by CCwiki."

        var notes: [String] = []
        if derived.strength == .conditional {
            let on = derived.conditionalOn.map { labels.assumption($0) }
            notes.append(on.isEmpty ? "conditional" : "conditional on " + on.joined(separator: ", "))
        }
        if !derived.circumventedBy.isEmpty {
            notes.append(circumvention(derived.circumventedBy))
        }
        if !derived.circumventsOriginalOnly.isEmpty {
            let who = circumvention(derived.circumventsOriginalOnly)
                .replacingOccurrences(of: "circumvented by ", with: "")
            notes.append("\(who) circumvents the barrier's own pair, \(origin) ⇒ \(end); "
                + "that does not reach \(label(derived.conclusion)).")
        }

        var row = ExplorerRow(id: id, title: sentence, accessibilityLabel: "Derived barrier. " + sentence)
        row.glyph = .derivedBarrier
        row.wraps = true
        row.notes = notes
        let qualifier = qualifierSentence(barrier).map { "\n" + $0 } ?? ""
        row.help = barrierTitle(barrier) + qualifier + "\nDerived by CCwiki from this barrier and "
            + "the side reductions it names, each of its class, standard-model and clean."
        row.primary = .page(barrier.path)
        row.page = ExplorerRow.PageLink(kind: "Barrier", title: barrierTitle(barrier), path: barrier.path)
        row.statement = sentence
        var links = [ExplorerRow.Link(
            id: id + "/barrier", title: barrierKeys.isEmpty ? "Barrier" : barrierKeys + " barrier",
            target: .page(barrier.path))]
        for step in sides {
            guard let relation = manifest.reduction(step.relationID) else { continue }
            let keys = citations(relation.source)
            links.append(ExplorerRow.Link(
                id: id + "/" + step.id,
                title: keys.isEmpty ? reductionTitle(step.relationID) : keys.joined(separator: ", "),
                target: .page(relation.path)))
        }
        row.links = links
        return row
    }

    // MARK: Refused steps (R5, R13)

    /// "Not derived: OIHF holds here only in the random oracle model, and
    /// OIHF ⇒ OT (BH26) is a free (non-black-box) step, which need not carry
    /// over into that model." One sentence per reason, with the recorded
    /// barriers on the step's pair, which often say more.
    ///
    /// A reason the curation gives (R13, not R5) carries the wiki's own text
    /// for it: the entry's quotes as notes, and links to where they are
    /// (relations-followups.md §2.5).
    func refusalRow(_ refused: Derivation.RefusedStep, closure: Derivation.Closure,
                    id: String) -> ExplorerRow {
        let step = refused.step
        let text = stepText(step)
        var sentences: [String] = []
        var entries: [DerivationCuration.Entry.Key] = []
        for reason in refused.reasons {
            if let key = curationKey(of: reason, on: step), !entries.contains(key) {
                entries.append(key)
            }
            switch reason {
            case .quarantined(let why):
                sentences.append("Not used: the wiki's record of \(text) does not match its "
                    + "Statement. \(why)")
            case .weakened(let hypothesis, let producedBy, let notion):
                sentences.append("Not derived: \(text) needs \(label(hypothesis)) as the wiki "
                    + "defines it, and \(producer(producedBy)) gives only \(notion).")
            case .requires(let hypothesis, let notion, let producedBy):
                sentences.append("Not derived: \(text) needs \(notion); the \(label(hypothesis)) "
                    + "here comes from \(producer(producedBy)), whose Statement the wiki does not "
                    + "record as establishing that.")
            case .idealisedComposition(let reductionClass, let scoped):
                sentences.append(idealisedRefusal(text: text, reductionClass: reductionClass,
                                                  scoped: scoped, closure: closure))
            }
        }

        var links: [ExplorerRow.Link] = []
        if let relation = manifest.reduction(step.relationID) {
            links.append(ExplorerRow.Link(
                id: id + "/step", title: reductionName(step.relationID), target: .page(relation.path)))
        }
        for barrierID in refused.barrierIDs {
            guard let barrier = manifest.barriers.first(where: { $0.id == barrierID }) else { continue }
            let title = barrierTitle(barrier)
            let keys = citations(barrier.source).joined(separator: ", ")
            var sentence = "The wiki records a barrier here: \(title)"
                + (keys.isEmpty ? "." : " (\(keys)).")
            // R8: the qualifier wherever the title appears. The link is
            // named by its citation, as a derived barrier's is, so the title
            // is never shown without it.
            if let qualifier = qualifierSentence(barrier) { sentence += " " + qualifier }
            sentences.append(sentence)
            links.append(ExplorerRow.Link(
                id: id + "/" + barrierID, title: keys.isEmpty ? "Barrier" : keys + " barrier",
                target: .page(barrier.path)))
        }

        // The entries on one step often quote the same sentence of its page,
        // as JLS21's four hypotheses do: each line once.
        var notes: [String] = []
        for key in entries {
            let evidence = curationEvidence(key, rowID: id + "/" + key.id)
            for note in evidence.notes where !notes.contains(note) { notes.append(note) }
            links = Self.merging(evidence.links, into: links)
        }

        let sentence = sentences.joined(separator: " ")
        var row = ExplorerRow(id: id, title: sentence, accessibilityLabel: sentence)
        row.wraps = true
        row.notes = notes
        row.help = stepHelp(step)
        row.links = links
        if let relation = manifest.reduction(step.relationID) {
            row.primary = .page(relation.path)
            row.page = ExplorerRow.PageLink(
                kind: "Reduction", title: reductionName(step.relationID), path: relation.path)
        }
        row.statement = sentence
        return row
    }

    /// The curation entry behind a refusal: the step's own precondition or
    /// quarantine, or the weakening of the step that produced its input. R5
    /// is CCwiki's own rule, not a curation entry, and has none.
    private func curationKey(of reason: Derivation.Refusal,
                             on step: Derivation.Step) -> DerivationCuration.Entry.Key? {
        switch reason {
        case .quarantined:
            return .quarantine(relationID: step.relationID)
        case .weakened(_, let producedBy, _):
            return .weakening(relationID: producedBy)
        case .requires(let hypothesis, _, _):
            return .requirement(relationID: step.relationID, isReverse: step.isReverse,
                                hypothesis: hypothesis)
        case .idealisedComposition:
            return nil
        }
    }

    /// The producer of a hypothesis, named as a step: `GapSVP ⇒ LWE (Reg05)`.
    /// An equivalence reads `⇔`, whichever way it was used.
    func producer(_ relationID: String) -> String {
        guard let relation = manifest.reduction(relationID) else { return relationID }
        let keys = citations(relation.source)
        let statement = labels.statement(relation)
        return keys.isEmpty ? statement : statement + " (" + keys.joined(separator: ", ") + ")"
    }

    private func idealisedRefusal(text: String, reductionClass: String, scoped: [String],
                                  closure: Derivation.Closure) -> String {
        var models: Set<String> = []
        for id in scoped {
            for model in closure.fact(id)?.models ?? []
            where Derivation.idealisedModels.contains(model) || model == Derivation.unknownModel {
                models.insert(model)
            }
        }
        let modelText: String = models.isEmpty
            ? "an idealised model"
            : "the " + DerivationWording.list(models.sorted(by: Derivation.precedes)
                .map { DerivationWording.modelName($0) })
        let holds = scoped.count == 1 ? "holds" : "hold"
        let opening = "Not derived: \(listed(scoped)) \(holds) here only in \(modelText), and \(text) is "
        let name = className(reductionClass)
        if name == Derivation.unstatedClass {
            return opening + "a step whose class the wiki does not state, so CCwiki cannot tell "
                + "whether it carries over into that model."
        }
        let kind = name == Derivation.ChainClass.free.rawValue ? "a free (non-black-box) step" : "a \(name) step"
        return opening + kind + ", which need not carry over into that model."
    }

    // MARK: Hints (R9)

    /// Related by the page, not by a recorded reduction: a section or a host
    /// that the wiki's structure suggests, never an inferred edge.
    func hintRow(_ hint: Derivation.Hint, id: String) -> ExplorerRow {
        let object = label(hint.objectID)
        let standsFor = label(hint.standsFor)
        let reach: String = hint.depth <= 1
            ? "by a recorded reduction"
            : "in \(DerivationWording.steps(hint.depth)), derived by CCwiki"
        let sentence: String
        let command: ExplorerRow.Command
        switch hint.kind {
        case .targetSection:
            sentence = "\(object), a section of \(standsFor), is reached \(reach)."
            command = .replaceTarget(with: hint.objectID)
        case .targetHost:
            sentence = "\(standsFor) is a section of \(object), which is reached \(reach)."
            command = .replaceTarget(with: hint.objectID)
        case .startSection:
            sentence = "\(standsFor) derives nothing here; its section \(object) reaches the target \(reach)."
            command = .replaceStart(hint.standsFor, with: hint.objectID)
        case .startHost:
            sentence = "\(standsFor) is a section of \(object), which reaches the target \(reach)."
            command = .replaceStart(hint.standsFor, with: hint.objectID)
        }
        var row = ExplorerRow(id: id, title: sentence, accessibilityLabel: sentence)
        row.wraps = true
        row.help = DerivationWording.hintsTitle + "."
        row.action = ExplorerRow.Action(title: "Use Instead", command: command)
        row.primary = .object(hint.objectID)
        row.objectID = hint.objectID
        row.exploreFrom = [hint.objectID]
        row.statement = sentence
        return row
    }
}

extension String {
    /// "Derived by …" → "derived by …", for a clause in parentheses.
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}
