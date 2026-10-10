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
/// **What the honest-uncertainty fields look like.** `unstated` is 76 of the
/// corpus's 283 reductions and is shown as itself, de-emphasized, with a
/// tooltip saying what it means — never guessed at, never rendered as
/// "black-box". `folklore` is a provenance label in ordinary styling, not a
/// warning. A `stub` gets the same badge it gets everywhere else, and has its
/// class and model *suppressed* rather than shown, because the manifest's own
/// documentation says a stub's typing is not evidence.
///
/// **A heuristic edge is never shown as a theorem.** Two reductions in the
/// corpus are candidate constructions with no security reduction behind them.
/// Their rows say "heuristic candidate", draw a dashed arrow, as the site's
/// graph draws such an edge, and lead their tooltip with what that means.
///
/// **A reduction or barrier page leads with its own record**, under "This
/// result": the kind, class, model, sources and loss that the site prints
/// under the page's heading, with the wiki's reason for each value as its
/// tooltip.
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
                    rows(of: group, on: page)
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

    /// A group's rows. The summary is one row holding a grid, so its labels
    /// share a column; every other group is a row per hyperedge or endpoint.
    @ViewBuilder
    private func rows(of group: RelationGroup, on page: PageRelations) -> some View {
        if group.role == .summary {
            factGrid(group.facts)
                .listRowSeparator(.hidden)
        } else {
            ForEach(group.rows) { row in
                rowView(row, in: group, of: page)
                    .listRowSeparator(.hidden)
            }
        }
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
                contradictsSubject: contradictsSubject(barrier, of: page),
                // Under "Circumvents" the heading already says it.
                showsCircumvention: group.role != .circumvents)
        case .object(let id):
            objectRow(id)
        case .fact(let fact):
            factGrid([fact])
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
        /// Which way, and which kind — `⇒`, `⇐`, `⊆`, `⊇`, `⇔`, or a dashed
        /// `⇢`, `⇠` for a heuristic edge. `nil` when the row already carries
        /// the whole statement.
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
                arrow: arrow(relation, awayFromFocus: true),
                primary: label(relation.conclusion),
                alsoNeeds: relation.hypotheses.filter { $0 != focus }.map(label))
        case .produces, .contains:
            return Edge(
                arrow: arrow(relation, awayFromFocus: false),
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

    /// The arrow a row draws, pointing from the page's object to the far end
    /// or back towards it. A heuristic implication is dashed, as the site's
    /// graph draws it: an edge of the graph that no theorem backs.
    private func arrow(_ relation: Relation, awayFromFocus: Bool) -> String {
        switch relation.kind {
        case .inclusion: awayFromFocus ? "⊆" : "⊇"
        case .equivalence: "⇔"
        case .implication where relation.heuristic: awayFromFocus ? "⇢" : "⇠"
        case .implication: awayFromFocus ? "⇒" : "⇐"
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
        return model.relations.barrier(barrier, contradicts: relation)
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
        .contextMenu {
            pageMenu(relation.path,
                     copyTitle: "Copy Statement",
                     copyText: model.relationLabels.statement(relation))
        }
    }

    private func barrierRow(
        _ barrier: Barrier, edge: Edge, contradictsSubject: Bool, showsCircumvention: Bool
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
                    meta(for: barrier, contradictsSubject: contradictsSubject,
                         showsCircumvention: showsCircumvention)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(helpText(for: barrier))
        .contextMenu {
            pageMenu(barrier.path,
                     copyTitle: "Copy Statement",
                     copyText: model.relationLabels.statement(barrier))
        }
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
        let label = model.relationLabels.label(id)
        return Button {
            model.openRelationObject(id)
        } label: {
            HStack(spacing: Theme.small) {
                Text(label)
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
        .contextMenu {
            if let destination = model.relationLabels.destination(id) {
                pageMenu(destination.path, anchor: destination.anchor,
                         copyTitle: "Copy Name", copyText: label)
            }
        }
    }

    // MARK: The page's own record

    /// The summary that leads a reduction or barrier page, as a label–value
    /// grid in the manner of a Get Info panel: labels trailing-aligned in
    /// secondary colour, values beside them at the same size. One list row
    /// holds the whole grid, so the label column is as wide as its longest
    /// label and no wider.
    private func factGrid(_ facts: [RelationFact]) -> some View {
        // A run of one field, such as two sources, names the field once.
        var runs: Set<String> = []
        for (previous, fact) in zip(facts, facts.dropFirst()) where previous.field == fact.field {
            runs.insert(fact.id)
        }
        let continued = runs

        return Grid(alignment: .leading, horizontalSpacing: Theme.small,
                    verticalSpacing: Theme.tight) {
            ForEach(facts) { fact in
                GridRow(alignment: .firstTextBaseline) {
                    // Hidden rather than emptied, so the row keeps the label's
                    // metrics and its baseline lines up like the others.
                    Text(verbatim: fact.label)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .opacity(continued.contains(fact.id) ? 0 : 1)
                        .accessibilityHidden(continued.contains(fact.id))
                        .gridColumnAlignment(.trailing)
                    factValue(fact)
                }
            }
        }
        .padding(.vertical, Theme.tight)
    }

    /// A value, as a link when it leads somewhere this clone has: an object, a
    /// reference page, a glossary section, a model's page. Every value has a
    /// tooltip: the record's reason for it, or else its full text, which a
    /// long security loss needs.
    @ViewBuilder
    private func factValue(_ fact: RelationFact) -> some View {
        let help = fact.help ?? factString(fact)
        if let target = target(of: fact) {
            Button {
                follow(target)
            } label: {
                factText(fact)
                    .font(Theme.Fonts.meta)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .help(help)
        } else {
            factText(fact)
                .font(Theme.Fonts.meta)
                .foregroundStyle(fact.isTentative
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(4)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(help)
        }
    }

    /// The value as text, with the kind's arrow de-emphasized before it and a
    /// proposition's believed status de-emphasized after it.
    private func factText(_ fact: RelationFact) -> Text {
        var text = Text(verbatim: factString(fact))
        if let symbol = fact.symbol {
            text = Text(verbatim: symbol + " ").foregroundStyle(.secondary) + text
        }
        if let believed = fact.believed {
            text = text
                + Text(verbatim: believed ? " · believed true" : " · believed false")
                    .foregroundStyle(.secondary)
        }
        return text
    }

    private func factString(_ fact: RelationFact) -> String {
        switch fact.value {
        case .text(let text):
            text
        case .object(let id):
            model.relationLabels.label(id)
        case .consequence(let consequence):
            model.relationLabels.consequence(consequence, manifest: model.relations)
        }
    }

    /// Where a value leads.
    private enum FactTarget {
        case object(String)
        case page(path: String, anchor: String?)
    }

    /// `nil` when the value leads nowhere, or nowhere this clone has, so a
    /// link that cannot be followed is never drawn as one.
    private func target(of fact: RelationFact) -> FactTarget? {
        if case .object(let id) = fact.value {
            return model.relationLabels.destination(id) == nil ? nil : FactTarget.object(id)
        }
        guard let link = fact.link,
              let wikilink = WikilinkParser.links(in: link).first,
              let index = model.index,
              case .page(let path, let anchor) = index.resolve(
                wikilink, from: model.location.path ?? "")
        else { return nil }
        return .page(path: path, anchor: anchor)
    }

    private func follow(_ target: FactTarget) {
        switch target {
        case .object(let id): model.openRelationObject(id)
        case .page(let path, let anchor): model.openPage(path, anchor: anchor)
        }
    }

    // MARK: Context menus

    /// The actions the sidebar and Backlinks offer for a page, plus the row's
    /// own text, which is what you want when quoting a result.
    @ViewBuilder
    private func pageMenu(
        _ path: String, anchor: String? = nil, copyTitle: String, copyText: String
    ) -> some View {
        Button("Open") { model.openPage(path, anchor: anchor) }
        if let page = model.index?.pages[path] {
            if let url = AppModel.siteURL(slug: page.slug, anchor: anchor) {
                Button("Open on cryptology.city") { NSWorkspace.shared.open(url) }
                Button("Copy Link") { model.copyToPasteboard(url.absoluteString) }
            }
            Button("Copy Wikilink") {
                model.copyToPasteboard(wikilink(to: page, anchor: anchor))
            }
        }
        Divider()
        Button(copyTitle) { model.copyToPasteboard(copyText) }
    }

    /// The page's own wikilink, pointed at a section when the row is one.
    private func wikilink(to page: WikiPage, anchor: String?) -> String {
        guard let anchor, page.kind != .reference, page.wikilink.hasSuffix("]]") else {
            return page.wikilink
        }
        return String(page.wikilink.dropLast(2)) + "#\(anchor)]]"
    }

    // MARK: Metadata

    /// The second line: what the wiki knows about *how* this relation holds.
    ///
    /// A stub shows no class and no model at all. The manifest's documentation
    /// is explicit that a stub was migrated but could not be typed confidently,
    /// so printing `unstated · standard` under one would dress a default up as
    /// a finding. A containment between complexity classes shows no class
    /// either: the class axis does not apply to `IP ⊆ PSPACE`, so "Free" under
    /// it would say nothing, as the site also judges.
    private func metaParts(for relation: Relation) -> [String] {
        var parts: [String] = []
        // First, because it changes what every other part means.
        if relation.heuristic { parts.append("heuristic candidate") }
        if relation.status != .stub {
            if !model.relations.isComplexityContainment(relation),
               let classLabel = classLabel(relation.reductionClass) {
                parts.append(classLabel)
            }
            if let modelLabel = modelLabel(relation.model) { parts.append(modelLabel) }
        }
        if !relation.via.isEmpty {
            parts.append("via " + relation.via.map { RelationText.linkText($0) }
                .joined(separator: ", "))
        }
        parts.append(contentsOf: citations(relation.source))
        return parts
    }

    @ViewBuilder
    private func meta(for relation: Relation) -> some View {
        let parts = metaParts(for: relation)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func metaParts(
        for barrier: Barrier, contradictsSubject: Bool, showsCircumvention: Bool
    ) -> [String] {
        var parts: [String] = []
        if contradictsSubject { parts.append("rules this out") }
        if barrier.status != .stub, let classLabel = classLabel(barrier.reductionClass) {
            parts.append("against " + classLabel.lowercased())
        }
        if barrier.strength == .conditional { parts.append("conditional") }
        // The manifest's contract: a barrier is never to be read as the last
        // word on its conclusion without this.
        if showsCircumvention, !barrier.circumventedBy.isEmpty {
            parts.append(circumvention(of: barrier))
        }
        parts.append(contentsOf: citations(barrier.source))
        return parts
    }

    /// "circumvented by BH26": the citation keys of the reductions that get
    /// around the barrier. Their statements are in the tooltip.
    private func circumvention(of barrier: Barrier) -> String {
        var keys: [String] = []
        for relation in model.relations.reductions(circumventing: barrier) {
            for key in citations(relation.source) where key != "folklore" && !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys.isEmpty ? "circumvented" : "circumvented by " + keys.joined(separator: ", ")
    }

    @ViewBuilder
    private func meta(
        for barrier: Barrier, contradictsSubject: Bool, showsCircumvention: Bool
    ) -> some View {
        let parts = metaParts(
            for: barrier, contradictsSubject: contradictsSubject,
            showsCircumvention: showsCircumvention)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(contradictsSubject
                    ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// `unstated` is shown as itself. It is an honest value — the source pages
    /// often do not say which notion of reduction they mean — and
    /// substituting a guess would fabricate a claim.
    private func classLabel(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return model.relations.isSentinel(name) ? name : model.relations.classTitle(name)
    }

    /// The standard model is the default and says nothing; an idealized one is
    /// the whole caveat, so it is the only case worth a word. Named as the
    /// site names it: "random oracle model", "quantum setting".
    private func modelLabel(_ name: String) -> String? {
        name.isEmpty || name == "standard" ? nil : RelationVocabulary.modelName(name)
    }

    /// `folklore` means the wiki has no attribution for the claim — never that
    /// none exists, and never an error. It reads as a provenance label like any
    /// citation key.
    private func citations(_ source: [String]) -> [String] {
        source.compactMap { RelationText.citationKey($0) }
    }

    // MARK: Tooltips

    private func helpText(for relation: Relation) -> String {
        var lines = [model.relationLabels.statement(relation)]
        if relation.heuristic {
            lines.append(Relation.heuristicExplanation)
            if let why = relation.rationale["heuristic"] { lines.append(why) }
        }
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
        } else {
            // The wiki's reasons, which the page body does not repeat.
            if !model.relations.isComplexityContainment(relation),
               let why = relation.rationale["class"],
               let classLabel = classLabel(relation.reductionClass) {
                lines.append("Why \(classLabel.lowercased()): \(why)")
            }
            if let why = relation.rationale["model"], !relation.model.isEmpty {
                lines.append("Why \(RelationVocabulary.modelName(relation.model)): \(why)")
            }
        }
        if relation.isFolklore {
            lines.append("Folklore: the wiki has no attribution for this claim.")
        }
        if !relation.securityLoss.isEmpty {
            lines.append("Security loss: \(RelationText.plain(relation.securityLoss))")
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
        if let why = barrier.rationale["class"], let classLabel = classLabel(barrier.reductionClass) {
            lines.append("Why \(classLabel.lowercased()): \(why)")
        }
        if !barrier.conditionalOn.isEmpty {
            lines.append("Conditional on: " + barrier.conditionalOn
                .map { model.relationLabels.assumption($0) }
                .joined(separator: ", "))
        }
        if let why = barrier.rationale["strength"] {
            lines.append("Why \(barrier.strength.rawValue): \(why)")
        }
        for relation in model.relations.reductions(circumventing: barrier) {
            let keys = citations(relation.source).joined(separator: ", ")
            lines.append("Circumvented by \(model.relationLabels.statement(relation))"
                + (keys.isEmpty ? "" : " (\(keys))") + ".")
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
