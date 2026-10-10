import Foundation

// Everything from, everything to (relations-explorer.md §2.8).
//
// Both are lists of facts, each disclosable to its proof. A depth-1 row is a
// recorded result and is labelled so; the rest are derived by CCwiki, and
// the footer says that something missing here is not evidence of anything.

extension ExplorerResult {

    // MARK: Forward: everything From derives

    static func forward(_ query: ExplorerQuery, writer: ExplorerWriter) -> ExplorerResult {
        let start = query.from
        let derivation = writer.derivation
        let closure = derivation.closure(from: Set(start), options: query.options)

        // The full facts, then the objects derived only in a weaker notion
        // (R13), which are kept apart and say so.
        var facts = closure.facts.values.filter { $0.step != nil }
        let weakOnly = closure.weakFacts.values.filter { closure.facts[$0.objectID] == nil }
        facts += weakOnly
        let from = writer.conjunction(start)

        guard !facts.isEmpty else {
            let description: String
            let modelStart: String? = start.count == 1
                ? Derivation.modelOfNode(start[0], in: writer.manifest) : nil
            if let model = modelStart, !query.includesIdealisedModels {
                description = DerivationWording.modelStart(model)
            } else {
                // An empty list has no footer to say it, so it says so here.
                description = "CCwiki derives nothing from \(from) "
                    + DerivationWording.modelPhrase(includesIdealisedModels: query.includesIdealisedModels)
                    + " with the reductions the wiki records. "
                    + DerivationWording.nothingDerivedCaveat
            }
            var result = ExplorerResult(query: query, state: .nothing(title: "Nothing Derived",
                                                                     description: description))
            result.offersIdealisedModels = !query.includesIdealisedModels
            result.announcement = "Nothing derived"
            return result
        }

        var byDepth: [Int: [ExplorerRow]] = [:]
        let ordered = facts.sorted { left, right in
            if left.depth != right.depth { return left.depth < right.depth }
            let leftLabel = writer.label(left.objectID)
            let rightLabel = writer.label(right.objectID)
            if leftLabel != rightLabel {
                return leftLabel.localizedStandardCompare(rightLabel) == .orderedAscending
            }
            return Derivation.precedes(left.objectID, right.objectID)
        }
        for fact in ordered {
            guard let row = factRow(fact, closure: closure, start: start, target: fact.objectID,
                                    title: writer.label(fact.objectID),
                                    id: "forward/\(fact.objectID)", query: query, writer: writer)
            else { continue }
            byDepth[fact.depth, default: []].append(row)
        }

        var result = ExplorerResult(query: query, state: .answer)
        for depth in byDepth.keys.sorted() {
            result.sections.append(ExplorerSection(
                id: "depth/\(depth)",
                title: depth == 1 ? "Recorded (1 step)" : DerivationWording.steps(depth),
                help: depth == 1
                    ? "Results the wiki records: one reduction from what you gave."
                    : "Derived by CCwiki: chains of recorded reductions, \(depth) layers deep.",
                rows: byDepth[depth] ?? []))
        }

        let count = closure.facts.values.filter { $0.step != nil }.count
        var lines = [Verdict.Line(
            id: "count",
            text: "\(count) object\(count == 1 ? "" : "s") · 1-step rows are recorded results; "
                + "the rest are derived by CCwiki.")]
        if !weakOnly.isEmpty {
            lines.append(Verdict.Line(
                id: "weak", text: "\(weakOnly.count) more only in a weaker notion, as marked."))
        }
        lines += forwardStartLines(query, writer: writer)
        result.verdict = Verdict(
            symbol: "arrow.triangle.branch", tone: .derived, title: "Derivable from \(from)",
            statement: "\(from) \(DerivationWording.derivedArrow) \(DerivationWording.anything)",
            lines: lines)
        result.footer = DerivationWording.listFooter
        result.explainsRules = true
        result.announcement = "\(count) objects derivable"
        result.initiallyCollapsed = collapsedByDefault(result.sections)
        return result
    }

    /// R14 and R4 for a forward question.
    private static func forwardStartLines(_ query: ExplorerQuery,
                                          writer: ExplorerWriter) -> [Verdict.Line] {
        var lines: [Verdict.Line] = []
        let curation = writer.derivation.curation
        for id in query.from {
            if let refutation = curation.refuted[id] {
                lines.append(Verdict.Line(
                    id: "refuted-\(id)",
                    text: "\(writer.label(id)) is known to be false (\(refutation.source)), so "
                        + "everything here follows vacuously. \(refutation.text)",
                    style: .caution))
            }
            if let setting = curation.settings[id] {
                lines.append(Verdict.Line(id: "setting-\(id)", text: setting.text))
            }
            if !query.includesIdealisedModels,
               let model = Derivation.modelOfNode(id, in: writer.manifest) {
                lines.append(Verdict.Line(id: "model-\(id)", text: DerivationWording.modelStart(model)))
            }
        }
        return lines
    }

    // MARK: Backward: everything that derives To

    static func backward(_ query: ExplorerQuery, writer: ExplorerWriter) -> ExplorerResult {
        guard let target = query.to else { return ExplorerResult(query: query, state: .empty) }
        let derivation = writer.derivation
        let backward = derivation.implying(target, options: query.options)
        let name = writer.label(target)

        let isEmpty = backward.singles.isEmpty && backward.groups.isEmpty
            && backward.settings.isEmpty && backward.largerConjunctions.isEmpty
        guard !isEmpty else {
            // Never "from nothing", which reads as unconditional, and never
            // "no recorded sources": the wiki may record one in a model, or
            // in a model the toggle leaves out, which R11 does not list.
            let phrase = DerivationWording.modelPhrase(
                includesIdealisedModels: query.includesIdealisedModels)
            var sentences = ["Through the reductions the wiki records, CCwiki finds no object or "
                + "combination of objects that derives \(name) \(phrase)."]
            if let inModel = modelSourceSentence(target, writer: writer) { sentences.append(inModel) }
            sentences.append(DerivationWording.noSourcesCaveat)
            var result = ExplorerResult(query: query, state: .nothing(
                title: "No Sources Found", description: sentences.joined(separator: " ")))
            result.offersIdealisedModels = !query.includesIdealisedModels
            result.announcement = "No sources found"
            return result
        }

        var result = ExplorerResult(query: query, state: .answer)

        // On its own: the single objects, by depth.
        if !backward.singles.isEmpty {
            var rows: [ExplorerRow] = []
            for single in backward.singles {
                let closure = derivation.closure(from: [single.objectID], options: query.options)
                guard var row = factRow(single.fact, closure: closure, start: [single.objectID],
                                        target: target, title: writer.label(single.objectID),
                                        id: "single/\(single.objectID)", query: query,
                                        writer: writer, nestsTarget: true)
                else { continue }
                row.primary = .object(single.objectID)
                row.objectID = single.objectID
                row.exploreFrom = [single.objectID]
                rows.append(row)
            }
            let more = backward.singleCount - backward.singles.count
            result.sections.append(ExplorerSection(
                id: "singles", title: "On its own",
                help: "Each of these alone derives \(name). Depth-1 rows are recorded results.",
                rows: rows, note: more > 0 ? "and \(more) more" : nil))
        }

        // R14: corruption settings are listed apart, never as assumptions.
        if !backward.settings.isEmpty {
            let rows = backward.settings.map { (single) -> ExplorerRow in
                let text = derivation.curation.settings[single.objectID]?.text
                var row = ExplorerRow(id: "setting/\(single.objectID)",
                                      title: writer.label(single.objectID),
                                      accessibilityLabel: writer.label(single.objectID))
                row.detail = text
                row.badge = single.fact.depth <= 1 ? "recorded" : DerivationWording.steps(single.fact.depth)
                row.primary = .object(single.objectID)
                row.objectID = single.objectID
                row.exploreFrom = [single.objectID]
                row.ask = ExplorerQuery(from: [single.objectID], to: target,
                                        includesIdealisedModels: query.includesIdealisedModels)
                row.statement = writer.label(single.objectID)
                return row
            }
            result.sections.append(ExplorerSection(
                id: "settings", title: "In a corruption setting",
                help: "Settings in which the primitive exists unconditionally: not assumptions.",
                rows: rows))
        }

        // Together with one other: one group per conjunctive edge where the
        // two halves meet. Each pair is one row and one claim, and nothing
        // says either half is needed (R11).
        if !backward.groups.isEmpty {
            var explanation = ExplorerRow(id: "pairs/explanation",
                                          title: DerivationWording.pairsExplanation,
                                          accessibilityLabel: DerivationWording.pairsExplanation)
            explanation.wraps = true
            explanation.isSelectable = false
            result.sections.append(ExplorerSection(
                id: "pairs", title: DerivationWording.pairsTitle, rows: [explanation]))
            for group in backward.groups {
                result.sections.append(pairSection(group, target: target, query: query,
                                                   writer: writer))
            }
        }

        if !backward.largerConjunctions.isEmpty {
            let rows = backward.largerConjunctions.map { (conjunction) -> ExplorerRow in
                largerConjunctionRow(conjunction, target: target, query: query, writer: writer)
            }
            result.sections.append(ExplorerSection(
                id: "larger", title: "Larger conjunctions",
                help: "Recorded reductions with three or more hypotheses, shown as the edge "
                    + "itself. Depth-1 rows are recorded results.",
                rows: rows))
        }

        let singles = backward.singleCount
        let pairs = backward.pairCount
        var lines = [Verdict.Line(
            id: "count",
            text: "\(singles) object\(singles == 1 ? "" : "s") alone · \(pairs) pair\(pairs == 1 ? "" : "s")")]
        if !backward.refutedExcluded.isEmpty {
            let count = backward.refutedExcluded.count
            lines.append(Verdict.Line(
                id: "refuted",
                text: "\(count) refuted object\(count == 1 ? "" : "s") also reach\(count == 1 ? "es" : "") "
                    + "this and \(count == 1 ? "is" : "are") left out: an implication from a false "
                    + "hypothesis is vacuous."))
        }
        result.verdict = Verdict(
            symbol: "arrow.triangle.branch", tone: .derived, title: DerivationWording.backwardTitle,
            statement: "\(DerivationWording.anything) \(DerivationWording.derivedArrow) \(name)",
            lines: lines, help: DerivationWording.backwardHelp)
        result.footer = DerivationWording.listFooter
        result.explainsRules = true
        result.announcement = "\(singles) objects alone, \(pairs) pairs"
        result.initiallyCollapsed = collapsedByDefault(result.sections)
        return result
    }

    /// "The wiki records it in the random oracle model (BH26); models are not
    /// listed as sources." `nil` unless a recorded reduction concludes the
    /// target from a model alone, which R11 never lists as a source.
    private static func modelSourceSentence(_ target: String, writer: ExplorerWriter) -> String? {
        var models: [String] = []
        var keys: [String] = []
        for relation in writer.manifest.relations(touching: target).asConclusion
        where relation.hypotheses.count == 1 && relation.kind != .inclusion && !relation.heuristic {
            guard let model = Derivation.modelOfNode(relation.hypotheses[0], in: writer.manifest)
            else { continue }
            if !models.contains(model) { models.append(model) }
            for key in writer.citations(relation.source) where !keys.contains(key) { keys.append(key) }
        }
        guard !models.isEmpty else { return nil }
        let names = DerivationWording.list(models.map { DerivationWording.modelName($0) })
        let cited = keys.isEmpty ? "" : " (" + keys.joined(separator: ", ") + ")"
        return "The wiki records it in the \(names)\(cited); models are not listed as sources."
    }

    /// A conjunction of three or more, shown as the edge it starts from, with
    /// the same tags and provenance as any other fact: when the target lies
    /// beyond the edge's own conclusion (JLS21's four hypotheses give iO,
    /// and iO gives FE), the row is CCwiki's chain, drawn `⇒*` and badged
    /// with its depth, never the wiki's `⇒`.
    private static func largerConjunctionRow(
        _ conjunction: Derivation.BackwardClosure.Conjunction, target: String,
        query: ExplorerQuery, writer: ExplorerWriter
    ) -> ExplorerRow {
        let fact = conjunction.fact
        let recorded = fact.depth <= 1
        let arrow = recorded ? DerivationWording.recordedArrow : DerivationWording.derivedArrow
        let title = "\(writer.conjunction(conjunction.hypotheses)) \(arrow) \(writer.label(target))"
        let proof = writer.derivation.closure(from: Set(conjunction.hypotheses), options: query.options)
            .proof(of: target)
        let relationIDs = proof?.relationIDs ?? [conjunction.relationID]

        var row = ExplorerRow(id: "larger/\(conjunction.relationID)", title: title,
                              accessibilityLabel: "")
        row.wraps = true
        row.detail = writer.reductionName(conjunction.relationID)
        row.badge = recorded ? "recorded" : DerivationWording.steps(fact.depth)
        row.models = fact.models.sorted(by: Derivation.precedes)
        if let assumed = writer.assuming(fact.assumes.map { $0.notion }) { row.notes.append(assumed) }
        if let weakening = fact.weakening { row.notes.append("only " + weakening.notion) }
        row.help = recorded
            ? "A result the wiki records: \(writer.reductionName(conjunction.relationID))."
            : DerivationWording.derivedBy(relationIDs.count) + "; "
                + DerivationWording.steps(fact.depth) + "."
        let how: String = recorded
            ? "recorded in the wiki"
            : "derived in \(DerivationWording.steps(fact.depth))"
        let models = row.models.map(DerivationWording.modelName)
        row.accessibilityLabel = ([title, how] + models).joined(separator: ", ")
        if let relation = writer.manifest.reduction(conjunction.relationID) {
            row.page = ExplorerRow.PageLink(
                kind: "Reduction", title: writer.reductionName(conjunction.relationID),
                path: relation.path)
        }
        let ask = ExplorerQuery(from: conjunction.hypotheses, to: target,
                                includesIdealisedModels: query.includesIdealisedModels)
        row.primary = .ask(ask)
        row.ask = ask
        row.exploreFrom = conjunction.hypotheses
        row.statement = writer.factStatement(from: conjunction.hypotheses, to: target,
                                             depth: fact.depth, relationIDs: relationIDs)
        return row
    }

    /// One group of pairs, headed by the edge where they meet: "Through OWF ∧
    /// iO ⇒ PKE · SW14 · 24 pairs".
    private static func pairSection(_ group: Derivation.BackwardClosure.Group, target: String,
                                    query: ExplorerQuery, writer: ExplorerWriter) -> ExplorerSection {
        let derivation = writer.derivation
        let edge = writer.manifest.reduction(group.relationID).map { writer.labels.statement($0) }
            ?? writer.conjunction(group.hypotheses)
        var subtitle = writer.citations(of: group.relationID)
        subtitle.append("\(group.pairCount) pair\(group.pairCount == 1 ? "" : "s")")
        subtitle += group.models.map(DerivationWording.modelName)
        if let assumed = writer.assuming(group.assumes) { subtitle.append(assumed) }

        let rows = group.pairRows.map { (pair) -> ExplorerRow in
            let statementLeft = writer.conjunction(pair.objectIDs)
            let proof = derivation.closure(from: Set(pair.objectIDs), options: query.options)
                .proof(of: target)
            let ask = ExplorerQuery(from: pair.objectIDs, to: target,
                                    includesIdealisedModels: query.includesIdealisedModels)
            var row = ExplorerRow(id: "pair/\(group.relationID)/\(pair.objectIDs.joined(separator: "+"))",
                                  title: statementLeft, accessibilityLabel: "")
            row.badge = pair.fact.depth <= 1 ? "recorded" : DerivationWording.steps(pair.fact.depth)
            row.models = pair.fact.models.sorted(by: Derivation.precedes)
            if let assumed = writer.assuming(pair.fact.assumes.map { $0.notion }) {
                row.notes = [assumed]
            }
            if let weakening = pair.fact.weakening { row.notes.append("only " + weakening.notion) }
            row.help = "Used together by the recorded reductions. Either may suffice on its own; "
                + "the record does not say."
            row.accessibilityLabel = "\(statementLeft), \(row.badge ?? "")"
            row.primary = .ask(ask)
            row.ask = ask
            row.exploreFrom = pair.objectIDs
            row.statement = writer.factStatement(
                from: pair.objectIDs, to: target, depth: pair.fact.depth,
                relationIDs: proof?.relationIDs ?? [])
            return row
        }
        let more = group.pairCount - group.pairRows.count
        return ExplorerSection(
            id: "group/\(group.relationID)", title: "Through \(edge)",
            subtitle: subtitle.joined(separator: " · "),
            help: "The recorded reduction where the two halves of each pair meet.",
            rows: rows, note: more > 0 ? "and \(more) more" : nil)
    }

    // MARK: A fact as a list row

    /// A forward or backward row: the object, its tags and how far, and a
    /// disclosure, collapsed, holding its proof. In forward mode the row is
    /// the proof's root; in backward mode it names the source, and the proof
    /// (rooted at the target) is its one child.
    private static func factRow(
        _ fact: Derivation.Fact, closure: Derivation.Closure, start: [String], target: String,
        title: String, id: String, query: ExplorerQuery, writer: ExplorerWriter,
        nestsTarget: Bool = false
    ) -> ExplorerRow? {
        guard let proof = closure.proof(of: target) else { return nil }
        let recorded = fact.depth <= 1
        let statement = "\(writer.conjunction(start)) "
            + (recorded ? DerivationWording.recordedArrow : DerivationWording.derivedArrow)
            + " \(writer.label(target))"
        // Copy Proof as Text on the row and on every step of its proof.
        let copy = ProofCopy(statement: statement, relationCount: proof.relationIDs.count,
                             depth: fact.depth, lines: ProofOutline.copyLines(proof, writer: writer))
        let outline = ProofOutline.attaching(
            copy, to: ProofOutline.rows(proof, idPrefix: id + "/proof", writer: writer))
        guard let root = outline.first else { return nil }

        var row: ExplorerRow
        if nestsTarget {
            row = ExplorerRow(id: id, title: title, accessibilityLabel: "")
            row.children = outline
        } else {
            row = root
            row.emphasis = .normal
        }
        row.badge = recorded ? "recorded" : DerivationWording.steps(fact.depth)
        row.models = fact.models.sorted(by: Derivation.precedes)
        var notes: [String] = []
        if let assumed = writer.assuming(fact.assumes.map { $0.notion }) { notes.append(assumed) }
        if let weakening = fact.weakening { notes.append("only " + weakening.notion) }
        row.notes = notes
        row.startsCollapsed = true
        row.primary = .object(target)
        row.objectID = target
        row.exploreFrom = [target]
        row.ask = ExplorerQuery(from: start, to: target,
                                includesIdealisedModels: query.includesIdealisedModels)
        row.statement = writer.factStatement(from: start, to: target, depth: fact.depth,
                                             relationIDs: proof.relationIDs)
        row.proof = copy
        let how: String = recorded
            ? "recorded in the wiki"
            : "derived in \(DerivationWording.steps(fact.depth))"
        let models = row.models.map(DerivationWording.modelName)
        row.accessibilityLabel = ([title, how] + models).joined(separator: ", ")
        row.help = recorded
            ? "A result the wiki records: \(writer.reductionName(proof.relationIDs.first ?? ""))."
            : DerivationWording.derivedBy(proof.relationIDs.count) + "; "
                + DerivationWording.steps(fact.depth) + "."
        return row
    }
}
