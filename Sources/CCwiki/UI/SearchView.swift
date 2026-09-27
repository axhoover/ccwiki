import SwiftUI

/// ⌘⇧F — full-text search across the wiki, backed by SQLite FTS5.
///
/// Distinct from the quick switcher: that one is "I know the page"; this one
/// is "which pages mention this". Results carry the matching passage, because
/// a list of titles does not tell you which hit you want.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @FocusState private var fieldFocused: Bool
    /// By id, not by index — see the note in `QuickSwitcherView`.
    @State private var highlightedID: String?

    private var results: [SearchHit] { model.searchResults }

    /// Falls back to the first row so Return always has a target.
    private var currentHighlight: String? {
        highlightedID.flatMap { id in results.contains { $0.id == id } ? id : nil }
            ?? results.first?.id
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: Theme.small) {
                Image(systemName: "text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search every page", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.paletteTitle)
                    .focused($fieldFocused)
                    .onSubmit(openHighlighted)
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.medium)

            Divider()
            content
            Divider()

            HStack {
                if let error = model.searchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                } else {
                    Text(results.isEmpty
                        ? "Whole-word and prefix matching; the last word matches as a prefix."
                        : "\(results.count) page\(results.count == 1 ? "" : "s")")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.small)
        }
        .frame(width: 720, height: 540)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: model.searchQuery) { _, _ in highlightedID = nil }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
    }

    @ViewBuilder
    private var content: some View {
        if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Search the Wiki",
                systemImage: "text.magnifyingglass",
                description: Text("Titles, aliases, headings and body text are all indexed."))
        } else if results.isEmpty {
            ContentUnavailableView.search(text: model.searchQuery)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { hit in
                            resultRow(hit, isHighlighted: hit.id == currentHighlight)
                                .id(hit.id)
                                .contentShape(.rect)
                                .onTapGesture {
                                    highlightedID = hit.id
                                    openHighlighted()
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.vertical, Theme.tight)
                }
                .onChange(of: currentHighlight) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func resultRow(_ hit: SearchHit, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.small) {
                KindIcon(kind: hit.kind)
                Text(hit.title)
                    .font(Theme.Fonts.paletteSubtitle.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                StatusBadge(status: hit.status, compact: true)
                Spacer(minLength: Theme.small)
                Text(hit.path)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            snippet(hit.snippet)
                .font(Theme.Fonts.rowSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(.leading, 20)
        }
        .padding(.horizontal, Theme.large)
        .padding(.vertical, Theme.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.selection)
                    .padding(.horizontal, Theme.small)
            }
        }
    }

    /// FTS5's `snippet()` marks matches with `«` … `»` — cheaper and safer than
    /// asking it for HTML, since this renders in SwiftUI rather than the web
    /// view.
    private func snippet(_ text: String) -> Text {
        var result = Text("")
        var isMatch = false
        for part in text.components(separatedBy: CharacterSet(charactersIn: "«»")) {
            guard !part.isEmpty else { isMatch.toggle(); continue }
            result = result + (isMatch
                ? Text(part).foregroundStyle(.primary).fontWeight(.semibold)
                : Text(part))
            isMatch.toggle()
        }
        return result
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let current = currentHighlight.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        highlightedID = results[min(max(0, current + delta), results.count - 1)].id
        return .handled
    }

    private func openHighlighted() {
        guard let id = currentHighlight, let hit = results.first(where: { $0.id == id })
        else { return }
        model.openPage(hit.path)
        dismiss()
    }
}
