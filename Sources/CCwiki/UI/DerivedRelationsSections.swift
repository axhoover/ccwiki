import SwiftUI

/// "Derived: implies" and "Derived: implied by", below the recorded groups
/// of an object page's Relations tab (relations-explorer.md §3).
///
/// Visibly CCwiki's, not the wiki's: a caption where the eye passes from
/// what the wiki says to what CCwiki computes, `⇒*` rather than `⇒`, the
/// label in secondary where recorded rows are primary (de-emphasis is
/// colour, never weight), and a step badge where a recorded row has a status
/// dot. A row's click shows its proof in the Relations Explorer.
///
/// Collapsed by default, and the open state persists per role, not per page,
/// as an Xcode inspector section does. The header is a button with a turning
/// chevron that flips the state, with no `withAnimation`
/// (`SWIFTUI-RULES.md` §1.2): `Section(isExpanded:)` is not known to draw a
/// disclosure in the inset list style.
struct DerivedRelationsSections: View {
    @Environment(AppModel.self) private var model
    let derivations: PageDerivations

    var body: some View {
        if !derivations.isEmpty {
            Section {
                Text(DerivationWording.inspectorCaption)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
                ForEach(derivations.refutations.keys.sorted(), id: \.self) { id in
                    Label(derivations.refutations[id] ?? "", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(PageDerivations.Role.allCases, id: \.self) { role in
                if derivations.count(role) > 0 {
                    section(role)
                }
            }
        }
    }

    private func section(_ role: PageDerivations.Role) -> some View {
        let isExpanded = model.isDerivedSectionExpanded(role)
        return Section {
            if isExpanded {
                ForEach(derivations.blocks(role)) { block in
                    blockRows(block, namesObject: derivations.needsObjectNames)
                }
            }
        } header: {
            header(role, isExpanded: isExpanded)
        }
    }

    private func header(_ role: PageDerivations.Role, isExpanded: Bool) -> some View {
        let state: String = isExpanded ? "expanded" : "collapsed"
        return Button {
            model.toggleDerivedSection(role)
        } label: {
            HStack(spacing: Theme.tight) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(role.title)
                    .font(Theme.Fonts.sectionHeader)
                    .lineLimit(1)
                Spacer(minLength: Theme.small)
                Text("\(derivations.count(role))")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(role.help)
        .accessibilityLabel("\(role.title), \(derivations.count(role))")
        .accessibilityValue(state)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func blockRows(_ block: PageDerivations.Block, namesObject: Bool) -> some View {
        if namesObject {
            Text(model.relationLabels.label(block.objectID))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .listRowSeparator(.hidden)
        }
        ForEach(block.groups) { group in
            if let heading = group.heading {
                Text(heading)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
            }
            ForEach(group.rows) { row in
                derivedRow(row, role: block.role)
                    .listRowSeparator(.hidden)
            }
        }
        if block.role == .impliedBy {
            // Counting pairs means the backward search, which the inspector
            // must not run at load; the explorer does, on request.
            Button(DerivationWording.combinations) {
                model.explore(from: [], to: block.objectID)
            }
            .buttonStyle(.link)
            .font(Theme.Fonts.meta)
            .help("Pairs of objects the recorded reductions use together, in the Relations Explorer.")
            .listRowSeparator(.hidden)
        }
    }

    private func derivedRow(_ row: PageDerivations.Row, role: PageDerivations.Role) -> some View {
        Button {
            showProof(row)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                Text(verbatim: role.arrow)
                    .font(Theme.Fonts.row)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .font(Theme.Fonts.row)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let modelsLine = row.modelsLine {
                        Text(modelsLine)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let weakening = row.weakening {
                        Text(weakening)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.small)
                StepBadge(text: DerivationWording.steps(row.depth))
                    .help(DerivationWording.derivedBy(row.link.relationCount))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(row.help)
        .contextMenu {
            Button("Show Proof") { showProof(row) }
            if let query = model.explorerQuestion(from: [row.link.objectID]) {
                Button("Explore From Here…") { model.explore(query) }
            }
            Button("Open “\(row.label)”") { model.openRelationObject(row.link.objectID) }
            Divider()
            Button("Copy Statement") { model.copyToPasteboard(row.statement) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Shows the proof in the Relations Explorer.")
        .accessibilityAddTraits(.isButton)
    }

    /// The proof is the answer to the row's own question, with the
    /// explorer's toggle kept as it is.
    private func showProof(_ row: PageDerivations.Row) {
        model.explore(from: row.query.from, to: row.query.to)
    }
}
