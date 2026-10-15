import Foundation

// From a question to what the explorer shows (relations-explorer.md §2.5–2.8).
//
// The engine answers; this decides the words and the order. Every mode reads
// the engine's public API only: `answer(from:to:options:)` for a question,
// `closure(from:options:)` for everything a conjunction derives, and
// `implying(_:options:)` for everything that derives an object.

extension ExplorerResult {

    /// The answer to `query`. Pure and `Sendable`, so the view runs it off
    /// the main actor: a no-derivation answer computes its completions,
    /// which is about a hundred closures.
    static func compute(_ query: ExplorerQuery, derivation: Derivation,
                        labels: RelationLabels) -> ExplorerResult {
        let manifest = derivation.manifest
        let ignored = query.unknownIDs(in: manifest)
        let asked = query.removing(ignored)
        let writer = ExplorerWriter(derivation: derivation, labels: labels)

        // R2: classes are related by containment, never derived.
        let named = asked.from + (asked.to.map { [$0] } ?? [])
        if let classID = named.first(where: { manifest.object($0)?.type == Derivation.excludedType }) {
            var result = ExplorerResult(query: query, state: .unsupported(labels.label(classID)))
            result.ignored = ignored
            result.announcement = DerivationWording.complexityClassTitle
            return result
        }

        var result: ExplorerResult
        switch asked.mode {
        case .empty:
            result = ExplorerResult(query: query, state: .empty)
        case .forward:
            result = forward(asked, writer: writer)
        case .backward:
            result = backward(asked, writer: writer)
        case .question:
            result = question(asked, writer: writer)
        }
        result.query = query
        result.ignored = ignored
        if !ignored.isEmpty, result.verdict != nil {
            let count = ignored.count
            result.verdict?.lines.append(ExplorerResult.Verdict.Line(
                id: "ignored",
                text: "\(count) object\(count == 1 ? "" : "s") ignored: not in the wiki any more.",
                style: .caution))
        }
        return result
    }

    // MARK: Does From imply To?

    private static func question(_ query: ExplorerQuery, writer: ExplorerWriter) -> ExplorerResult {
        guard let target = query.to else { return ExplorerResult(query: query, state: .empty) }
        let answer = writer.derivation.answer(
            from: Set(query.from), to: target, options: query.options)
        switch answer {
        case .unsupported(let reason):
            switch reason {
            case .complexityClass(let id):
                return ExplorerResult(query: query, state: .unsupported(writer.label(id)))
            case .unknownObject(let id):
                return ExplorerResult(query: query, state: .nothing(
                    title: "Not in the Wiki",
                    description: "\(writer.label(id)) is not one of the objects the wiki's "
                        + "relationship graph records."))
            }
        case .derived(let derived):
            if derived.isGiven { return given(derived, query: query, writer: writer) }
            return derivedResult(derived, query: query, writer: writer)
        case .notDerived(let noPath):
            return noPathResult(noPath, query: query, writer: writer)
        }
    }

    /// A target in From comes back at depth 0: no proof, and no footer.
    private static func given(_ answer: Derivation.DerivedAnswer, query: ExplorerQuery,
                              writer: ExplorerWriter) -> ExplorerResult {
        let name = writer.label(answer.target)
        var result = ExplorerResult(query: query, state: .answer)
        result.verdict = Verdict(
            symbol: "equal.circle", tone: .neutral, title: "One of your premises",
            lines: [Verdict.Line(id: "given", text: "\(name) is one of your premises.")])
        result.announcement = "\(name) is one of your premises"
        return result
    }

    private static func derivedResult(_ answer: Derivation.DerivedAnswer, query: ExplorerQuery,
                                      writer: ExplorerWriter) -> ExplorerResult {
        let fact = answer.fact
        let start = query.from
        let recorded = answer.isRecordedResult
        let arrow = recorded ? DerivationWording.recordedArrow : DerivationWording.derivedArrow
        let statement = "\(writer.conjunction(start)) \(arrow) \(writer.label(answer.target))"

        var verdict = Verdict(
            symbol: "arrow.triangle.branch", tone: .derived,
            title: recorded ? DerivationWording.recordedTitle : DerivationWording.derivableTitle,
            statement: statement)
        verdict.models = fact.models.sorted(by: Derivation.precedes)

        // The title of a model-scoped result names the model, never a bare
        // "holds". A recorded one keeps its title and says so on a line.
        if fact.isModelScoped {
            if recorded {
                if let line = DerivationWording.modelScopeLine(fact.models) {
                    verdict.lines.append(Verdict.Line(id: "scope", text: line))
                }
            } else if let scope = DerivationWording.modelScope(fact.models) {
                verdict.title = scope
            }
        }

        if recorded {
            let stepID = answer.proof.relationIDs.first ?? ""
            verdict.lines.append(Verdict.Line(
                id: "provenance", text: "A result the wiki records: \(writer.reductionName(stepID))"))
        } else {
            verdict.lines.append(Verdict.Line(
                id: "provenance",
                text: DerivationWording.provenance(relationCount: answer.proof.relationIDs.count,
                                                   depth: fact.depth)))
            verdict.lines.append(chainClassLine(fact.chainClass, proof: answer.proof, writer: writer))
        }
        verdict.lines += factLines(fact, writer: writer)
        verdict.lines += startLines(refuted: answer.refutedStarts, settings: answer.settingStarts,
                                    models: answer.modelStarts, writer: writer)
        for (index, conflict) in (answer.conflicts + answer.majorResults).enumerated() {
            let barrier = writer.manifest.barriers.first { $0.id == conflict.barrierID }
            let name = barrier.map { writer.barrierTitle($0) } ?? conflict.barrierID
            // R8's qualifier goes wherever the barrier's title does.
            let qualifier = barrier.flatMap { writer.qualifierSentence($0) }.map { " " + $0 } ?? ""
            let kind = DerivationWording.chainClassShort(conflict.chainClass)
            let derivedFrom: String = conflict.isDerived ? "a barrier derived from " : ""
            verdict.lines.append(Verdict.Line(
                id: "conflict-\(index)",
                text: "The record is inconsistent here: a \(kind) derivation meets \(derivedFrom)\(name)."
                    + qualifier,
                style: .caution))
        }
        if let note = answer.scopeNote {
            verdict.lines.append(Verdict.Line(id: "scopeNote", text: scopeNote(note)))
        }

        var result = ExplorerResult(query: query, state: .answer)
        result.verdict = verdict

        // The proof, expanded, with Copy Proof As on every step.
        let copy = ProofCopy(statement: statement, relationCount: answer.proof.relationIDs.count,
                             depth: fact.depth,
                             lines: ProofOutline.copyLines(answer.proof, writer: writer),
                             export: ProofExport(
                                proof: answer.proof, start: start, target: answer.target,
                                depth: fact.depth, chainClass: fact.chainClass,
                                unstatedSteps: writer.unstatedSteps(answer.proof),
                                refutations: answer.refutedStarts, manifest: writer.manifest))
        let proofRows = ProofOutline.rows(answer.proof, idPrefix: "proof", writer: writer)
        result.sections.append(ExplorerSection(
            id: "proof",
            rows: rootStatements(ProofOutline.attaching(copy, to: proofRows), start: start,
                                 target: answer.target, depth: fact.depth,
                                 proof: answer.proof, writer: writer),
            note: stubNote(answer.proof)))

        if let stronger = answer.stronger {
            result.stronger = strongerProof(stronger, start: start, target: answer.target,
                                            refutations: answer.refutedStarts, writer: writer)
        }

        result.sections += recordedOnPairSections(answer.recordedOnPair, start: start,
                                                  target: answer.target, writer: writer,
                                                  showsUsed: false)
        let context = barrierSections(
            recorded: answer.recordedBarriers, reverse: answer.reverseBarriers,
            derived: answer.derivedBarriers + answer.derivedReverseBarriers, writer: writer)
        if !context.isEmpty {
            // A barrier beside a derivation is context: R8's conflict check
            // found no derivation of a class it rules out.
            var sections = context
            if answer.conflicts.isEmpty {
                sections[0].subtitle = recorded
                    ? "Context: none of these rules out this result."
                    : "Context: none of these rules out this derivation."
            }
            result.sections += sections
        }

        // Last: what CCwiki applies that the record does not, for each proof
        // that can be shown. One closure, the answer's own, tells a step
        // refused on the way from one the proof does without.
        let closure = writer.derivation.closure(from: Set(start), options: query.options)
        let shortest = CurationTrace.derived(
            answer.proof, other: answer.stronger?.proof, closure: closure, start: start,
            derivation: writer.derivation)
        if let section = adjustmentsSection(shortest, idPrefix: adjustmentsID, writer: writer) {
            result.sections.append(section)
        }
        if let stronger = answer.stronger {
            let trace = CurationTrace.derived(
                stronger.proof, other: answer.proof, closure: closure, start: start,
                derivation: writer.derivation)
            result.stronger?.adjustments = adjustmentsSection(
                trace, idPrefix: "stronger-" + adjustmentsID, writer: writer)
        }

        result.footer = recorded ? DerivationWording.recordedFooter : DerivationWording.derivedFooter
        result.explainsRules = !recorded
        result.announcement = recorded
            ? DerivationWording.recordedTitle
            : "Derivable in \(DerivationWording.steps(fact.depth))"
        result.initiallyCollapsed = collapsedByDefault(result.sections)
        return result
    }

    /// The proof's root states the whole claim when copied, with where it
    /// came from; the steps under it state their own reductions.
    private static func rootStatements(_ rows: [ExplorerRow], start: [String], target: String,
                                       depth: Int, proof: Derivation.ProofTree,
                                       writer: ExplorerWriter) -> [ExplorerRow] {
        let statement = writer.factStatement(from: start, to: target, depth: depth,
                                             relationIDs: proof.relationIDs)
        return rows.map { (root) -> ExplorerRow in
            var root = root
            root.statement = statement
            return root
        }
    }

    /// R6's stronger proof, with the verdict it reads under. Its own depth
    /// decides its words, as the shortest proof's does: beside a recorded
    /// result it is usually a chain, which is CCwiki's composition and must
    /// never pass for the wiki's own result. Its copies state its own depth
    /// and class too.
    private static func strongerProof(_ stronger: Derivation.StrongerChain, start: [String],
                                      target: String, refutations: [DerivationCuration.Refutation],
                                      writer: ExplorerWriter) -> Stronger {
        let proof = stronger.proof
        let recorded = stronger.depth <= 1
        let arrow = recorded ? DerivationWording.recordedArrow : DerivationWording.derivedArrow
        let statement = "\(writer.conjunction(start)) \(arrow) \(writer.label(target))"

        // The models its own steps use, which may be fewer than the
        // shortest proof's: R6 looks only among those.
        var models: Set<String> = []
        for row in proof.rows {
            guard let step = row.step, step.model != Derivation.standardModel else { continue }
            models.insert(step.model)
        }

        var lines: [Verdict.Line] = []
        let title: String
        if recorded {
            title = DerivationWording.recordedTitle
            if let line = DerivationWording.modelScopeLine(models) {
                lines.append(Verdict.Line(id: "scope", text: line))
            }
            let stepID = proof.relationIDs.first ?? ""
            lines.append(Verdict.Line(
                id: "provenance", text: "A result the wiki records: \(writer.reductionName(stepID))"))
        } else {
            title = DerivationWording.modelScope(models) ?? DerivationWording.derivableTitle
            lines.append(Verdict.Line(
                id: "provenance",
                text: DerivationWording.provenance(relationCount: proof.relationIDs.count,
                                                   depth: stronger.depth)))
            lines.append(chainClassLine(stronger.chainClass, proof: proof, writer: writer))
        }

        let copy = ProofCopy(statement: statement, relationCount: proof.relationIDs.count,
                             depth: stronger.depth,
                             lines: ProofOutline.copyLines(proof, writer: writer),
                             export: ProofExport(
                                proof: proof, start: start, target: target, depth: stronger.depth,
                                chainClass: stronger.chainClass,
                                unstatedSteps: writer.unstatedSteps(proof),
                                refutations: refutations, manifest: writer.manifest))
        let outline = ProofOutline.attaching(
            copy, to: ProofOutline.rows(proof, idPrefix: "stronger", writer: writer))
        let section = ExplorerSection(
            id: "proof",
            rows: rootStatements(outline, start: start, target: target, depth: stronger.depth,
                                 proof: proof, writer: writer),
            note: stubNote(proof))
        return Stronger(
            line: DerivationWording.strongerChain(stronger.chainClass, depth: stronger.depth),
            proof: section, lines: lines, copy: copy, title: title, statement: statement,
            models: models.sorted(by: Derivation.precedes),
            footer: recorded ? DerivationWording.recordedFooter : DerivationWording.derivedFooter,
            explainsRules: !recorded)
    }

    /// The chain class line, muted when unstated, as `unstated` is
    /// everywhere.
    private static func chainClassLine(_ chain: Derivation.ChainClass, proof: Derivation.ProofTree,
                                       writer: ExplorerWriter) -> Verdict.Line {
        Verdict.Line(
            id: "class",
            text: DerivationWording.chainClass(chain, unstatedSteps: writer.unstatedSteps(proof)),
            style: chain == .unstated ? .muted : .secondary)
    }

    /// Assumptions and a weakened notion are part of the claim (§7).
    private static func factLines(_ fact: Derivation.Fact, writer: ExplorerWriter) -> [Verdict.Line] {
        var lines: [Verdict.Line] = []
        let notions = fact.assumes.map { $0.notion }.sorted(by: Derivation.precedes)
        for (index, notion) in notions.enumerated() {
            lines.append(Verdict.Line(id: "assumes-\(index)", text: "Assuming \(notion)"))
        }
        if let weakening = fact.weakening {
            let keys = writer.citations(of: weakening.relationID).joined(separator: ", ")
            lines.append(Verdict.Line(
                id: "weakening",
                text: "Gives only a weaker notion: \(weakening.notion)"
                    + (keys.isEmpty ? "" : " (\(keys))")))
        }
        return lines
    }

    /// R14 and R4: a refuted start makes the implication vacuous; a setting
    /// is not an assumption; a model given with the toggle off is a model.
    private static func startLines(refuted: [DerivationCuration.Refutation], settings: [String],
                                   models: [String], writer: ExplorerWriter) -> [Verdict.Line] {
        var lines: [Verdict.Line] = []
        for refutation in refuted {
            lines.append(Verdict.Line(
                id: "refuted-\(refutation.objectID)",
                text: "The hypothesis is known to be false (\(refutation.source)), so this "
                    + "implication is vacuous. \(refutation.text)",
                style: .caution))
        }
        for id in settings {
            let text = writer.derivation.curation.settings[id]?.text
                ?? "\(writer.label(id)) is a corruption setting, not an assumption."
            lines.append(Verdict.Line(id: "setting-\(id)", text: text))
        }
        for id in models {
            guard let model = Derivation.modelOfNode(id, in: writer.manifest) else { continue }
            lines.append(Verdict.Line(id: "model-\(id)", text: DerivationWording.modelStart(model)))
        }
        return lines
    }

    /// R8's scope note: a barrier is about standard-model reductions from
    /// the objects as the wiki defines them.
    private static func scopeNote(_ note: Derivation.ScopeNote) -> String {
        var uses: [String] = []
        if !note.models.isEmpty {
            uses.append("uses the " + DerivationWording.list(note.models.map(DerivationWording.modelName)))
        }
        if note.assumesPrecondition { uses.append("assumes a precondition") }
        if note.isWeakened { uses.append("concludes a weaker notion") }
        return "The barriers here concern standard-model reductions between the objects as the "
            + "wiki defines them; this derivation " + DerivationWording.list(uses) + "."
    }

    /// R3: a stub step's class and model are not evidence.
    private static func stubNote(_ proof: Derivation.ProofTree) -> String? {
        let stubs = proof.rows.filter { $0.step?.isStub ?? false }.count
        guard stubs > 0 else { return nil }
        return stubs == 1
            ? "1 step is a stub: its class and model are not evidence."
            : "\(stubs) steps are stubs: their class and model are not evidence."
    }

    // MARK: No derivation (R10)

    private static func noPathResult(_ answer: Derivation.NoPathAnswer, query: ExplorerQuery,
                                     writer: ExplorerWriter) -> ExplorerResult {
        let start = query.from
        let target = answer.target
        var verdict = Verdict(symbol: "circle.dashed", tone: .noDerivation,
                              title: DerivationWording.noDerivationTitle)

        let unusable = answer.recordedOnPair.filter { $0.status != .used }
        if !answer.modelStarts.isEmpty {
            // R4's own words replace the sentence.
            for id in answer.modelStarts {
                guard let model = Derivation.modelOfNode(id, in: writer.manifest) else { continue }
                verdict.lines.append(Verdict.Line(id: "model-\(id)",
                                                  text: DerivationWording.modelStart(model)))
            }
            verdict.action = ExplorerRow.Action(title: DerivationWording.includeIdealisedModels,
                                                command: .includeIdealisedModels)
        } else {
            let models = DerivationWording.modelPhrase(
                includesIdealisedModels: query.includesIdealisedModels)
            let from = writer.conjunction(start)
            let to = writer.label(target)
            // Never "no chain of recorded reductions" when the wiki records
            // one on this very pair that CCwiki may not use, or when the
            // recorded reductions do chain here through a step CCwiki
            // refused (R5, R13): ROM ⇒ OIHF ⇒ OT is a chain the wiki
            // records, which CCwiki does not apply inside the model.
            let sentence: String
            if unusable.isEmpty && answer.refused.isEmpty {
                sentence = "CCwiki finds no chain of the wiki's recorded reductions from \(from) "
                    + "to \(to) \(models)."
            } else {
                var parts = ["CCwiki finds no derivation it can use from \(from) to \(to) \(models)."]
                if !unusable.isEmpty {
                    parts.append("The wiki records \(unusable.count == 1 ? "a reduction" : "reductions") "
                        + "on this pair that CCwiki does not use here; see below.")
                }
                if !answer.refused.isEmpty {
                    let steps: String = answer.refused.count == 1 ? "a step" : "steps"
                    parts.append("The wiki's recorded reductions do chain here, through \(steps) "
                        + "CCwiki does not apply in this case; see Refused steps.")
                }
                sentence = parts.joined(separator: " ")
            }
            verdict.lines.append(Verdict.Line(id: "sentence", text: sentence))
        }
        verdict.lines += startLines(refuted: answer.refutedStarts, settings: answer.settingStarts,
                                    models: [], writer: writer)

        var result = ExplorerResult(query: query, state: .answer)
        result.verdict = verdict

        // R10, in its order. Each section is present only when it has rows.
        result.sections += recordedOnPairSections(answer.recordedOnPair, start: start,
                                                  target: target, writer: writer, showsUsed: true)
        result.sections += barrierSections(
            recorded: answer.recordedBarriers, reverse: answer.reverseBarriers,
            derived: answer.derivedBarriers + answer.derivedReverseBarriers, writer: writer)

        if let fact = answer.withIdealisedModels {
            result.sections.append(withIdealisedSection(
                fact, proof: answer.withIdealisedModelsProof,
                usesStub: answer.withIdealisedModelsUsesStub, writer: writer))
        }

        if !answer.refused.isEmpty {
            // The closure the refusal happened in, for the models a scoped
            // hypothesis holds in.
            let closure = writer.derivation.closure(from: Set(start), options: .all)
            result.sections.append(ExplorerSection(
                id: "refused", title: "Refused steps", help: DerivationWording.refusedHelp,
                rows: answer.refused.enumerated().map { index, refused in
                    writer.refusalRow(refused, closure: closure, id: "refused/\(index)")
                }))
        }

        if !answer.hints.isEmpty {
            result.sections.append(ExplorerSection(
                id: "hints", title: DerivationWording.hintsTitle,
                help: "Hosts and their sections are related by the page's structure, never by "
                    + "an edge, so none of these is a derivation.",
                rows: answer.hints.enumerated().map { index, hint in
                    writer.hintRow(hint, id: "hint/\(index)")
                }))
        }

        if let section = completionsSection(answer, query: query, writer: writer) {
            result.sections.append(section)
        }

        // Last: what CCwiki applies to the starts. A refusal carries its
        // quotes on its own row above.
        let trace = CurationTrace.starts(start, derivation: writer.derivation)
        if let section = adjustmentsSection(trace, idPrefix: adjustmentsID, writer: writer) {
            result.sections.append(section)
        }

        result.footer = DerivationWording.noPathFooter
        result.explainsRules = true
        result.announcement = DerivationWording.noDerivationTitle
        result.initiallyCollapsed = collapsedByDefault(result.sections)
        return result
    }

    /// R10.3: the toggle would find it. One step is the wiki's own claim in
    /// that model, and says so.
    private static func withIdealisedSection(_ fact: Derivation.Fact, proof: Derivation.ProofTree?,
                                             usesStub: Bool, writer: ExplorerWriter) -> ExplorerSection {
        let models = fact.models.sorted(by: Derivation.precedes)
        let names = DerivationWording.list(models.map(DerivationWording.modelName))
        let text: String
        if usesStub {
            text = "Derivable with idealised models included, through a stub reduction, whose "
                + "class and model are not evidence: \(DerivationWording.steps(fact.depth))."
        } else if fact.depth <= 1 {
            let name = proof?.relationIDs.first.map { writer.reductionName($0) } ?? "a reduction"
            text = "Recorded in the wiki in the \(names): \(name). Shown with idealised models included."
        } else {
            text = "Derivable with idealised models included: \(DerivationWording.steps(fact.depth)), "
                + names + "."
        }
        var row = ExplorerRow(id: "idealised/row", title: text, accessibilityLabel: text)
        row.wraps = true
        row.models = models
        row.action = ExplorerRow.Action(title: DerivationWording.includeIdealisedModels,
                                        command: .includeIdealisedModels)
        row.help = DerivationWording.toggleHelp
        return ExplorerSection(id: "idealised", title: "With idealised models included", rows: [row])
    }

    /// R10.6: single objects with which the recorded reductions reach the
    /// target. Never "a missing assumption": one may suffice on its own.
    private static func completionsSection(_ answer: Derivation.NoPathAnswer, query: ExplorerQuery,
                                           writer: ExplorerWriter) -> ExplorerSection? {
        guard !answer.completions.isEmpty || !answer.questionBecomes.isEmpty else { return nil }
        var rows: [ExplorerRow] = []
        for completion in answer.completions {
            let name = writer.label(completion.objectID)
            let fact = completion.fact
            var parts = [DerivationWording.steps(fact.depth)]
            let keys = completion.relationIDs.flatMap { writer.citations(of: $0) }
            var shown: [String] = []
            for key in keys where !shown.contains(key) { shown.append(key) }
            if !shown.isEmpty {
                parts.append(shown.prefix(3).joined(separator: ", ") + (shown.count > 3 ? ", …" : ""))
            }
            parts.append(DerivationWording.chainClassShort(fact.chainClass))
            var row = ExplorerRow(id: "completion/\(completion.objectID)", title: name,
                                  accessibilityLabel: "")
            row.detail = parts.joined(separator: " · ")
            if let assumed = writer.assuming(fact.assumes.map { $0.notion }) { row.notes = [assumed] }
            row.models = fact.models.sorted(by: Derivation.precedes)
            row.help = "With the wiki's recorded reductions, adding \(name) gives a derivation "
                + "(\(DerivationWording.steps(fact.depth))). It may suffice on its own; the record "
                + "is incomplete."
            row.accessibilityLabel = "\(name), \(row.detail ?? "")"
            row.action = ExplorerRow.Action(title: "Add", command: .add(completion.objectID))
            row.primary = .object(completion.objectID)
            row.objectID = completion.objectID
            row.exploreFrom = [completion.objectID]
            row.ask = query.adding(completion.objectID)
            row.statement = name
            rows.append(row)
        }
        for completion in answer.questionBecomes {
            let name = writer.label(completion.objectID)
            let becomes = ExplorerQuery(from: query.from, to: completion.objectID,
                                        includesIdealisedModels: query.includesIdealisedModels)
            let text = "The target gives back \(name), so the question becomes "
                + "\(writer.conjunction(query.from)) \(DerivationWording.derivedArrow) \(name)."
            var row = ExplorerRow(id: "becomes/\(completion.objectID)", title: text,
                                  accessibilityLabel: text)
            row.wraps = true
            row.help = "Adding \(name) would only restate the target, which already gives it back."
            row.action = ExplorerRow.Action(title: "Ask", command: .ask(becomes))
            row.primary = .ask(becomes)
            row.objectID = completion.objectID
            row.exploreFrom = [completion.objectID]
            row.ask = becomes
            row.statement = text
            rows.append(row)
        }
        let more = answer.completionCount - answer.completions.count
        return ExplorerSection(
            id: "completions", title: DerivationWording.completionsTitle,
            help: "With the wiki's recorded reductions, adding one of these gives a derivation. "
                + "It may suffice on its own; the record is incomplete.",
            rows: rows, note: more > 0 ? "and \(more) more" : nil)
    }

    // MARK: Recorded on this pair (R10.0)

    private static func recordedOnPairSections(
        _ entries: [Derivation.RecordedOnPair], start: [String], target: String,
        writer: ExplorerWriter, showsUsed: Bool
    ) -> [ExplorerSection] {
        let shown = showsUsed ? entries : entries.filter { $0.status != .used }
        guard !shown.isEmpty else { return [] }
        let rows = shown.map { recordedOnPairRow($0, writer: writer) }
        return [ExplorerSection(
            id: "onPair", title: "Recorded on this pair",
            help: "Every reduction the wiki records on exactly this question, and what CCwiki did with it.",
            rows: rows)]
    }

    private static func recordedOnPairRow(_ entry: Derivation.RecordedOnPair,
                                          writer: ExplorerWriter) -> ExplorerRow {
        let relation = writer.manifest.reduction(entry.relationID)
        let title = relation.map { writer.labels.statement($0) } ?? entry.relationID
        var status: String
        switch entry.status {
        case .used:
            status = "used"
        case .notOnShownDerivation:
            status = "not on the proof shown"
        case .unused:
            status = "not used"
        case .stub:
            status = "a stub, used only with idealised models included: its class and model are not evidence"
        case .idealisedModel:
            let model = relation.map { DerivationWording.modelName($0.model) } ?? "an idealised model"
            status = "in the \(model), used only with idealised models included"
        case .excluded(let exclusion):
            switch exclusion {
            case .inclusion: status = "an inclusion, never used: containment, not implication"
            case .heuristic: status = "a heuristic candidate, never used: an edge of the graph, not a theorem"
            case .complexityClassEndpoint: status = "touches a complexity class, never used"
            case .unresolvedEndpoint: status = "names an object the wiki does not have, never used"
            case .concludesAModel: status = "concludes a model, never used"
            case .quarantined:
                // A quarantine of one direction of an equivalence: its
                // hypotheses match, but its Statement does not establish
                // this direction (the review's wording, `_description`).
                if writer.derivation.curation.quarantineDirections[entry.relationID] != nil {
                    let way = entry.isReverse ? "right to left" : "left to right"
                    status = "not used \(way): its Statement does not establish that direction; "
                        + "the other direction is still a step"
                } else {
                    status = "not used: its recorded hypotheses do not match its Statement"
                }
            }
        }
        if !entry.needs.isEmpty {
            status += "; it needs " + entry.needs.joined(separator: "; ")
        }
        if entry.isReverse { status += " (⇔, read right to left)" }
        let keys = writer.citations(of: entry.relationID)
        var row = ExplorerRow(id: "onPair/\(entry.relationID)/\(entry.isReverse)", title: title,
                              accessibilityLabel: "\(title), \(status)")
        row.detail = (keys.isEmpty ? "" : keys.joined(separator: ", ") + " · ") + status
        if let detail = entry.detail { row.notes = [detail] }
        if entry.status == .excluded(.quarantined) {
            // The wiki's own text for the quarantine, as on its refused row.
            let evidence = writer.curationEvidence(.quarantine(relationID: entry.relationID),
                                                   rowID: row.id)
            row.notes += evidence.notes
            row.links = evidence.links
        }
        row.isStub = relation?.status == .stub
        if let relation {
            row.primary = .page(relation.path)
            row.page = ExplorerRow.PageLink(kind: "Reduction",
                                            title: writer.reductionName(entry.relationID),
                                            path: relation.path)
            row.exploreFrom = relation.hypotheses
        }
        row.statement = title
        return row
    }

    // MARK: Barriers (R8, R12)

    /// Recorded barriers on the pair, then the other direction, then the
    /// barriers CCwiki derives that no other covers. A redundant derived
    /// barrier is shown only under Show reasoning, on the barrier it repeats.
    private static func barrierSections(recorded: [Barrier], reverse: [Barrier],
                                        derived: [Derivation.DerivedBarrier],
                                        writer: ExplorerWriter) -> [ExplorerSection] {
        var reasoning: [String: [ExplorerRow]] = [:]
        var unattached: [ExplorerRow] = []
        var kept: [ExplorerRow] = []
        let recordedIDs = Set((recorded + reverse).map { $0.id })
        for (index, barrier) in derived.enumerated() {
            let row = writer.derivedBarrierRow(barrier, id: "derived/\(index)")
            guard barrier.isRedundant else {
                kept.append(row)
                continue
            }
            if let owner = barrier.redundantWith.first(where: { recordedIDs.contains($0) }) {
                reasoning[owner, default: []].append(row)
            } else {
                unattached.append(row)
            }
        }

        func withReasoning(_ barrier: Barrier, id: String) -> ExplorerRow {
            var row = writer.barrierRow(barrier, id: id)
            if let rows = reasoning[barrier.id], !rows.isEmpty {
                var disclosure = ExplorerRow(id: id + "/reasoning", title: "Show reasoning",
                                             accessibilityLabel: "Show reasoning")
                disclosure.help = "Barriers CCwiki derives that this recorded barrier already "
                    + "covers. Derived by CCwiki."
                disclosure.isSelectable = false
                disclosure.startsCollapsed = true
                disclosure.children = rows
                row.children = [disclosure]
            }
            return row
        }

        var sections: [ExplorerSection] = []
        if !recorded.isEmpty {
            sections.append(ExplorerSection(
                id: "barriers", title: "Recorded barriers", help: DerivationWording.barrierHelp,
                rows: recorded.map { withReasoning($0, id: "barrier/\($0.id)") }))
        }
        if !reverse.isEmpty {
            sections.append(ExplorerSection(
                id: "reverseBarriers", title: "In the other direction",
                help: DerivationWording.barrierHelp,
                rows: reverse.map { withReasoning($0, id: "reverse/\($0.id)") }))
        }
        if !kept.isEmpty || !unattached.isEmpty {
            var rows = kept
            if !unattached.isEmpty {
                var disclosure = ExplorerRow(id: "derived/reasoning", title: "Show reasoning",
                                             accessibilityLabel: "Show reasoning")
                disclosure.help = "Derived barriers that another barrier here already covers."
                disclosure.isSelectable = false
                disclosure.startsCollapsed = true
                disclosure.children = unattached
                rows.append(disclosure)
            }
            sections.append(ExplorerSection(
                id: "derivedBarriers", title: "Barriers CCwiki derives",
                help: DerivationWording.derivedBarrierHelp, rows: rows))
        }
        return sections
    }

    // MARK: Collapsing

    /// Rows whose disclosure starts closed.
    static func collapsedByDefault(_ sections: [ExplorerSection]) -> Set<String> {
        var collapsed: Set<String> = []
        func walk(_ rows: [ExplorerRow]) {
            for row in rows {
                if row.startsCollapsed { collapsed.insert(row.id) }
                walk(row.children)
            }
        }
        for section in sections { walk(section.rows) }
        return collapsed
    }
}
