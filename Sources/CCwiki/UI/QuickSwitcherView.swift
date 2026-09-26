import SwiftUI

/// ⌘O — the quick switcher.
///
/// Fuzzy-matched over titles, frontmatter aliases and (for references) the
/// paper title, so `prf`, `PRF` and `pseudorandom` all land on the same page,
/// and `AGGM06` and `sorting network` both find the same reference.
///
/// Deliberately keyboard-shaped: type, arrow, Return. A palette you have to
/// reach for the mouse in is slower than the sidebar it replaces.
struct QuickSwitcherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Selection is held by *id*, not by index.
    ///
    /// An index into a list that changes on every keystroke is a bug waiting to
    /// happen, and pairing it with `ForEach(Array(results.enumerated()))` was
    /// one: the tuple elements carry no identity of their own, so the rows kept
    /// rendering the previous query's results while the footer count updated.
    @State private var highlightedID: String?
    @FocusState private var fieldFocused: Bool

    private var results: [QuickSwitchItem] { model.quickSwitcherResults }

    private var highlightedIndex: Int {
        guard let highlightedID,
              let index = results.firstIndex(where: { $0.id == highlightedID })
        else { return 0 }
        return index
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: Theme.small) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Jump to a page", text: $model.quickSwitcherQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.paletteTitle)
                    .focused($fieldFocused)
                    .onSubmit(openHighlighted)
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.medium)

            Divider()

            if results.isEmpty {
                VStack(spacing: Theme.tight) {
                    Text("No matches")
                        .font(Theme.Fonts.row)
                        .foregroundStyle(.secondary)
                    Text("Try a citation key, an alias, or part of a title.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.section)
            } else {
                resultList
            }

            Divider()
            footer
        }
        .frame(width: Theme.paletteWidth)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: model.quickSwitcherQuery) { _, _ in
            highlightedID = results.first?.id
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not lazy: the list is capped at 40 rows, and
                // laziness only buys a caching layer to get wrong.
                VStack(spacing: 0) {
                    ForEach(results) { item in
                        row(item, isHighlighted: item.id == currentHighlight)
                            .id(item.id)
                            .contentShape(.rect)
                            .onTapGesture {
                                highlightedID = item.id
                                openHighlighted()
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            .frame(maxHeight: Theme.paletteMaxHeight)
            .onChange(of: currentHighlight) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Falls back to the first row so there is always something Return will open.
    private var currentHighlight: String? {
        highlightedID.flatMap { id in results.contains { $0.id == id } ? id : nil }
            ?? results.first?.id
    }

    private func row(_ item: QuickSwitchItem, isHighlighted: Bool) -> some View {
        HStack(spacing: Theme.small) {
            KindIcon(kind: item.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.Fonts.paletteSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = item.subtitle, subtitle != item.title {
                    Text(subtitle)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Theme.small)
            StatusBadge(status: item.status, compact: true)
        }
        .padding(.horizontal, Theme.large)
        .padding(.vertical, Theme.small)
        .frame(minHeight: Theme.paletteRowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.selection)
                    .padding(.horizontal, Theme.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.medium) {
            hint("↑↓", "Move")
            hint("↩", "Open")
            hint("esc", "Cancel")
            Spacer()
            Text("\(results.count) match\(results.count == 1 ? "" : "es")")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.large)
        .padding(.vertical, Theme.small)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Theme.tight) {
            Text(key)
                .font(Theme.Fonts.badge)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 3))
            Text(label)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let next = min(max(0, highlightedIndex + delta), results.count - 1)
        highlightedID = results[next].id
        return .handled
    }

    private func openHighlighted() {
        guard let id = currentHighlight, let item = results.first(where: { $0.id == id })
        else { return }
        model.openPage(item.path)
        dismiss()
    }
}
