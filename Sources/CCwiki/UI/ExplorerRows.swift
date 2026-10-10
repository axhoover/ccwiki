import SwiftUI

/// What a row's controls do, handed down from the explorer.
struct ExplorerRowActions {
    /// A row's button: Add, Use Instead, Include Idealised Models.
    let perform: (ExplorerRow.Command) -> Void
    /// A link on a sentence.
    let follow: (ExplorerRow.Target) -> Void
}

/// A row and, when it has any, its children in a disclosure, recursively:
/// the proof outline (relations-explorer.md §2.6). Expanded unless the
/// explorer's `collapsed` set holds it, so open is the default, and the
/// `List` gives → and ← to open and close and ↑ ↓ to move, natively.
struct ExplorerOutlineRow: View {
    let row: ExplorerRow
    @Binding var collapsed: Set<String>
    let actions: ExplorerRowActions

    var body: some View {
        if row.children.isEmpty {
            ExplorerRowView(row: row, actions: actions)
                .tag(row.id)
                .selectionDisabled(!row.isSelectable)
                .listRowSeparator(.hidden)
        } else {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(row.children) { child in
                    ExplorerOutlineRow(row: child, collapsed: $collapsed, actions: actions)
                }
            } label: {
                ExplorerRowView(row: row, actions: actions)
            }
            .tag(row.id)
            .selectionDisabled(!row.isSelectable)
            .listRowSeparator(.hidden)
        }
    }

    /// Open unless the explorer's set of closed rows holds it. The closures
    /// capture the binding and the id, not the view.
    private var expansion: Binding<Bool> {
        let collapsed = $collapsed
        let id = row.id
        return Binding(
            get: { !collapsed.wrappedValue.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsed.wrappedValue.remove(id)
                } else {
                    collapsed.wrappedValue.insert(id)
                }
            })
    }
}

/// One row of the explorer's list, whatever it shows: a proof step, a
/// barrier, a refusal, a completion. One view for all of them
/// (`SWIFTUI-RULES.md` §4.4); the model decides which fields are filled.
///
/// Emphasis is weight, de-emphasis is colour: the proof's root is semibold,
/// meta lines are secondary, and nothing is lighter than regular.
struct ExplorerRowView: View {
    let row: ExplorerRow
    let actions: ExplorerRowActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            // The conjunction where it lives: the second and later premises
            // of a step that needs several.
            Text(verbatim: row.conjunct ? DerivationWording.conjunction : "")
                .font(Theme.Fonts.row.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.conjunctionGutter, alignment: .trailing)
                .accessibilityHidden(true)

            if row.glyph != .none {
                Image(systemName: "nosign")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if let qualifier = row.qualifier {
                    Text(qualifier)
                        .font(Theme.Fonts.meta)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(row.wraps ? nil : 2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(row.notes, id: \.self) { note in
                    Text(note)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.links.isEmpty {
                    links
                }
            }

            Spacer(minLength: Theme.small)

            ForEach(row.models, id: \.self) { model in
                ModelTag(model: model)
            }
            if let badge = row.badge {
                StepBadge(text: badge)
            }
            if let action = row.action {
                Button(action.title) { actions.perform(action.command) }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .help(row.help ?? row.title)
        .accessibilityElement(children: hasControls ? .contain : .combine)
        .accessibilityLabel(row.accessibilityLabel.isEmpty ? row.title : row.accessibilityLabel)
    }

    private var hasControls: Bool { row.action != nil || !row.links.isEmpty }

    @ViewBuilder
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.tight) {
            Text(row.title)
                .font(Theme.Fonts.row)
                .fontWeight(row.emphasis == .strong ? .semibold : nil)
                .lineLimit(row.wraps ? nil : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if row.isStub {
                StatusBadge(status: .stub, compact: true)
            }
        }
    }

    /// The barrier and side reductions of a derived barrier, the step and
    /// barriers of a refusal: each opens its page.
    private var links: some View {
        HStack(spacing: Theme.small) {
            ForEach(row.links) { link in
                Button(link.title) { actions.follow(link.target) }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// A section's heading: the title, and a second line when it has one.
struct ExplorerSectionHeader: View {
    let section: ExplorerSection

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = section.title {
                Text(title)
                    .font(Theme.Fonts.sectionHeader)
                    .lineLimit(2)
            }
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .help(section.help ?? section.title ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}
