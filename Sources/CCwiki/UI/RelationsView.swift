import SwiftUI

/// The inspector's third tab: what this page relates to, from `relations.json`.
///
/// **One row is one hyperedge.** A reduction with three hypotheses renders as a
/// single row reading `A ∧ B ∧ C ⇒ D`, never as three rows — the hypotheses are
/// a conjunction, and splitting them would claim three implications the wiki
/// does not make. The `∧` is deliberately loud enough to read as "and".
///
/// **Three arrows, not one.** `⇒` is implication, `⊆` is containment, `⇔` is
/// equivalence, and the group headings differ to match: an inclusion files
/// under "is contained in", never under "builds on".
///
/// **What the honest-uncertainty fields look like.** `unstated` is 280 of the
/// corpus's 343 reductions and is shown as itself, de-emphasized, with a
/// tooltip saying what it means — never guessed at, never rendered as
/// "black-box". `folklore` is a provenance label in ordinary styling, not a
/// warning. A `stub` gets the same badge it gets everywhere else, and has its
/// class and model *suppressed* rather than shown, because the manifest's own
/// documentation says a stub's typing is not evidence.
struct RelationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let page = model.currentRelations

        Group {
            if let diagnostic = model.relations.diagnostic {
                unavailable(diagnostic)
            } else if page.isEmpty {
                switch page.subject {
                case .unknown:
                    emptyPane(
                        "Not a Relationship Node", systemImage: "circle.dashed",
                        detail: "This page is not one of the objects, reductions or "
                            + "barriers in the wiki's relationship graph.")
                default:
                    emptyPane(
                        "No Relationships", systemImage: "arrow.triangle.branch",
                        detail: "The wiki records nothing that reaches this page yet.")
                }
            } else {
                list(page)
            }
        }
    }

    // MARK: The list

    private func list(_ page: PageRelations) -> some View {
        // A page that hosts variants as well as its own object gets several
        // blocks with the same role, so those need the object's name to tell
        // them apart. A page with one object does not — the title bar already
        // says which object you are reading about.
        let needsObjectNames = Set(page.groups.compactMap(\.objectID)).count > 1

        return List {
            ForEach(page.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        rowView(row, in: group, of: page)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.role.title)
                            .font(Theme.Fonts.sectionHeader)
                            .lineLimit(1)
                        if needsObjectNames, let objectID = group.objectID {
                            Text(model.relationLabels.label(objectID))
                                .font(Theme.Fonts.meta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .help(group.role.explanation)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rowView(
        _ row: RelationRow, in group: RelationGroup, of page: PageRelations
    ) -> some View {
        switch row {
        case .relation(let relation):
            relationRow(
                relation,
                edge: edge(relation, role: group.role, focus: group.objectID))
        case .barrier(let barrier):
            barrierRow(
                barrier,
                edge: edge(barrier, focus: group.objectID),
                contradictsSubject: contradictsSubject(barrier, of: page))
        case .object(let id):
            objectRow(id)
        }
    }

    // MARK: What a row says, given which end of the edge you are standing on

    /// A row shows the end of the edge you are *not* on.
    ///
    /// The group heading already names your end and the direction — "Builds on
    /// Indistinguishability Obfuscation" — so repeating it in every row costs
    /// two of the three lines a row gets and pushes the part that differs off
    /// the end. Leading with the far end puts the distinguishing half first.
    ///
    /// The conjunction does not get lost doing this: any *other* hypothesis the
    /// theorem needs is named on the second line as "also needs …", which is
    /// conjunction in words. So `{sparse-lpn, ddh} ⇒ she` on the DDH page reads
    /// "SHE / also needs Sparse LPN" — one row, one claim, and visibly not
    /// "DDH ⇒ SHE" on its own. The full statement is in the tooltip, and the
    /// reduction's own page states it in full.
    private struct Edge {
        /// Which way, and which kind — `⇒`, `⇐`, `⊆`, `⊇`, `⇔`. `nil` when the
        /// row already carries the whole statement.
        var arrow: String?
        var primary: String
        /// The hypotheses this theorem needs *besides* the one you are reading
        /// about.
        var alsoNeeds: [String] = []
        /// True when `primary` is itself a conjunction — the "Produces" case,
        /// where the hypotheses are the row's whole content.
        var primaryIsConjunction = false

        /// A conjunction gets the room to be read in full: truncating
        /// `DDH ∧ LPN ∧ LWE ∧ PRG in NC¹` mid-list would leave a claim about
        /// fewer assumptions than the theorem actually needs, which is exactly
        /// the misreading this view exists to prevent. Everything else is a
        /// single name and fits in two.
        var lineLimit: Int { primaryIsConjunction ? 4 : 2 }
    }

    private func edge(_ relation: Relation, role: RelationRole, focus: String?) -> Edge {
        // On a reduction or barrier page there is no "your end", so the row
        // carries the entire statement.
        guard let focus else {
            return Edge(arrow: nil, primary: model.relationLabels.statement(relation))
        }
        let label = { (id: String) in self.model.relationLabels.label(id) }

        switch role {
        case .buildsOn, .containedIn:
            return Edge(
                arrow: relation.kind.arrow,
                primary: label(relation.conclusion),
                alsoNeeds: relation.hypotheses.filter { $0 != focus }.map(label))
        case .produces, .contains:
            return Edge(
                arrow: relation.kind == .inclusion ? "⊇" : "⇐",
                primary: relation.hypotheses.map(label).joined(separator: " ∧ "),
                primaryIsConjunction: relation.hypotheses.count > 1)
        case .equivalentTo:
            let other = relation.conclusion == focus
                ? (relation.hypotheses.first ?? relation.conclusion)
                : relation.conclusion
            return Edge(arrow: "⇔", primary: label(other))
        default:
            return Edge(arrow: nil, primary: model.relationLabels.statement(relation))
        }
    }

    private func edge(_ barrier: Barrier, focus: String?) -> Edge {
        guard let focus, barrier.hypotheses.contains(focus) || barrier.conclusion == focus
        else {
            return Edge(arrow: nil, primary: model.relationLabels.statement(barrier))
        }
        let label = { (id: String) in self.model.relationLabels.label(id) }

        // The `nosign` glyph carries the "ruled out" half, so the arrow only
        // has to carry the direction.
        if barrier.conclusion == focus {
            return Edge(
                arrow: "⇐",
                primary: barrier.hypotheses.map(label).joined(separator: " ∧ "),
                primaryIsConjunction: barrier.hypotheses.count > 1)
        }
        return Edge(
            arrow: "⇒",
            primary: label(barrier.conclusion),
            alsoNeeds: barrier.hypotheses.filter { $0 != focus }.map(label))
    }

    /// `⇒ Deniable encryption`, with the connective de-emphasized so the name
    /// reads first.
    private func edgeText(_ edge: Edge) -> Text {
        guard let arrow = edge.arrow else { return Text(edge.primary) }
        return Text(verbatim: arrow + " ").foregroundStyle(.secondary) + Text(edge.primary)
    }

    /// Does this barrier actually rule out the reduction whose page we are on?
    ///
    /// Almost always no, and that is the point: a barrier bites a reduction
    /// only when the reduction's class implies the one the barrier forbids. A
    /// barrier against `fully-black-box` says nothing about a `free` reduction,
    /// and `unstated` is comparable to nothing at all.
    private func contradictsSubject(_ barrier: Barrier, of page: PageRelations) -> Bool {
        guard case .reduction(let relation) = page.subject else { return false }
        return model.relations.barriers(contradicting: relation).contains { $0.id == barrier.id }
    }

    // MARK: Rows

    private func relationRow(_ relation: Relation, edge: Edge) -> some View {
        Button {
            model.openPage(relation.path)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                StatusBadge(status: relation.status, compact: true)
                VStack(alignment: .leading, spacing: 2) {
                    edgeText(edge)
                        .font(Theme.Fonts.row)
                        // Two lines: enough for a long name or a conjunction of
                        // hypotheses, and short enough that a group of six rows
                        // still fits on screen.
                        .lineLimit(edge.lineLimit)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    alsoNeeds(edge)
                    meta(for: relation)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(helpText(for: relation))
    }

    private func barrierRow(
        _ barrier: Barrier, edge: Edge, contradictsSubject: Bool
    ) -> some View {
        Button {
            model.openPage(barrier.path)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                Image(systemName: "nosign")
                    .font(.caption2)
                    .foregroundStyle(contradictsSubject ? AnyShapeStyle(Color.orange)
                        : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    edgeText(edge)
                        .font(Theme.Fonts.row)
                        .lineLimit(edge.lineLimit)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    alsoNeeds(edge)
                    meta(for: barrier, contradictsSubject: contradictsSubject)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(helpText(for: barrier))
    }

    /// The conjunction, in words. This line is the reason a multi-hypothesis
    /// edge cannot be misread as a claim about one hypothesis alone.
    @ViewBuilder
    private func alsoNeeds(_ edge: Edge) -> some View {
        if !edge.alsoNeeds.isEmpty {
            Text("also needs " + edge.alsoNeeds.joined(separator: " ∧ "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// An endpoint of the reduction or barrier being read. A variant resolves
    /// to its host page plus an anchor, so this can land on a section.
    private func objectRow(_ id: String) -> some View {
        let object = model.relations.object(id)
        return Button {
            model.openRelationObject(id)
        } label: {
            HStack(spacing: Theme.small) {
                Text(model.relationLabels.label(id))
                    .font(Theme.Fonts.row)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if object?.isVariant == true {
                    Image(systemName: "number")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("A section of its page, not a page of its own.")
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Metadata

    /// The second line: what the wiki knows about *how* this relation holds.
    ///
    /// A stub shows no class and no model at all. The manifest's documentation
    /// is explicit that a stub was migrated but could not be typed confidently,
    /// so printing `unstated · standard` under one would dress a default up as
    /// a finding.
    @ViewBuilder
    private func meta(for relation: Relation) -> some View {
        let parts: [String] = if relation.status == .stub {
            citations(relation.source)
        } else {
            [classLabel(relation.reductionClass), modelLabel(relation.model)]
                .compactMap { $0 } + citations(relation.source)
        }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func metaParts(for barrier: Barrier, contradictsSubject: Bool) -> [String] {
        var parts: [String] = []
        if contradictsSubject { parts.append("rules this out") }
        if barrier.status != .stub, let classLabel = classLabel(barrier.reductionClass) {
            parts.append("against " + classLabel.lowercased())
        }
        if barrier.strength == .conditional { parts.append("conditional") }
        parts.append(contentsOf: citations(barrier.source))
        return parts
    }

    @ViewBuilder
    private func meta(for barrier: Barrier, contradictsSubject: Bool) -> some View {
        let parts = metaParts(for: barrier, contradictsSubject: contradictsSubject)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(contradictsSubject
                    ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// `unstated` is shown as itself. It is the honest majority of the corpus —
    /// the source pages rarely say which notion of reduction they mean — and
    /// substituting a guess would fabricate a claim.
    private func classLabel(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return model.relations.isSentinel(name) ? name : model.relations.classTitle(name)
    }

    /// The standard model is the default and says nothing; an idealized one is
    /// the whole caveat, so it is the only case worth a word.
    private func modelLabel(_ model: String) -> String? {
        switch model {
        case "", "standard": nil
        case "rom": "ROM"
        case "crs": "CRS"
        case "generic-group": "generic group"
        case "algebraic-group": "algebraic group"
        default: model
        }
    }

    /// `folklore` means the wiki has no attribution for the claim — never that
    /// none exists, and never an error. It reads as a provenance label like any
    /// citation key.
    private func citations(_ source: [String]) -> [String] {
        source.compactMap { entry in
            guard entry != "folklore" else { return "folklore" }
            // `[[KEY - Full Title|KEY]]` → `KEY`.
            let inner = entry.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let display = inner.split(separator: "|").last.map(String.init) ?? inner
            let trimmed = display.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Tooltips

    private func helpText(for relation: Relation) -> String {
        var lines = [model.relationLabels.statement(relation)]
        switch relation.kind {
        case .implication where relation.hasMultipleHypotheses:
            lines.append("A conjunction: the theorem needs every hypothesis, "
                + "not any one of them.")
        case .inclusion:
            lines.append("Containment, not implication.")
        case .equivalence:
            lines.append("Holds in both directions.")
        default:
            break
        }
        if model.relations.isSentinel(relation.reductionClass) {
            lines.append("Class “\(relation.reductionClass)”: the source does not say "
                + "which notion of reduction is meant.")
        }
        if relation.status == .stub {
            lines.append("A stub — migrated, but not confidently typed. Its class and "
                + "model are not evidence.")
        }
        if relation.isFolklore {
            lines.append("Folklore: the wiki has no attribution for this claim.")
        }
        if !relation.securityLoss.isEmpty {
            lines.append("Security loss: \(relation.securityLoss)")
        }
        return lines.joined(separator: "\n")
    }

    private func helpText(for barrier: Barrier) -> String {
        var lines = [model.relationLabels.statement(barrier)]
        let classPhrase = model.relations.isSentinel(barrier.reductionClass)
            ? "a reduction of unstated class"
            : "a \(model.relations.classTitle(barrier.reductionClass).lowercased()) reduction"
        for consequence in barrier.consequences {
            lines.append("The existence of \(classPhrase) here would imply "
                + model.relationLabels.consequence(consequence, manifest: model.relations)
                + ".")
        }
        if !barrier.conditionalOn.isEmpty {
            lines.append("Conditional on: " + barrier.conditionalOn.joined(separator: ", "))
        }
        if barrier.status == .stub {
            lines.append("A stub — migrated, but not confidently typed.")
        }
        if barrier.isFolklore {
            lines.append("Folklore: the wiki has no attribution for this claim.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Empty states

    /// The manifest could not be read. Most often this is simply a clone that
    /// predates the reductions migration, which a sync fixes — so the pane says
    /// that and offers the button, rather than showing an error.
    private func unavailable(_ diagnostic: RelationsManifest.Diagnostic) -> some View {
        VStack(spacing: Theme.small) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Relationships Unavailable")
                .font(Theme.Fonts.row)
                .foregroundStyle(.secondary)
            Text(diagnostic.message)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if case .fileMissing = diagnostic {
                Button("Sync Now") { model.sync() }
                    .disabled(model.syncState.isRunning)
                    .padding(.top, Theme.tight)
            }
            Spacer()
        }
        .padding(Theme.large)
        .frame(maxWidth: .infinity)
    }

    private func emptyPane(
        _ title: String, systemImage: String, detail: String
    ) -> some View {
        VStack(spacing: Theme.small) {
            Spacer()
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.Fonts.row)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(Theme.large)
        .frame(maxWidth: .infinity)
    }
}
