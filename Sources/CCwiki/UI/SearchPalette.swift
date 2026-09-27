import SwiftUI

/// The frame ⌘S and ⇧⌘R share: a field, a list you move through with the
/// arrow keys and open with Return, and a footer. Each search supplies only
/// its rows and what opening one does.
struct SearchPalette<Item: Identifiable, Row: View>: View where Item.ID == String {
    @Binding var query: String
    let placeholder: String
    let systemImage: String
    let items: [Item]
    let error: String?
    /// Shown before anything is typed.
    let emptyTitle: String
    let emptyDescription: String
    /// "12 pages", "3 papers".
    let countLabel: (Int) -> String
    let open: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    /// By id, not by index — see the note in `QuickSwitcherView`.
    @State private var highlightedID: String?

    /// Falls back to the first row so Return always has a target.
    private var currentHighlight: String? {
        highlightedID.flatMap { id in items.contains { $0.id == id } ? id : nil }
            ?? items.first?.id
    }

    private var isQueryEmpty: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.small) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.paletteTitle)
                    .focused($fieldFocused)
                    .onSubmit(openHighlighted)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.medium)

            Divider()
            content
            Divider()

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                } else if !items.isEmpty {
                    Text(countLabel(items.count))
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
        .onChange(of: query) { _, _ in highlightedID = nil }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
    }

    @ViewBuilder
    private var content: some View {
        if isQueryEmpty {
            ContentUnavailableView(
                emptyTitle, systemImage: systemImage, description: Text(emptyDescription))
        } else if items.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                                .padding(.horizontal, Theme.large)
                                .padding(.vertical, Theme.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    if item.id == currentHighlight {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(.selection)
                                            .padding(.horizontal, Theme.small)
                                    }
                                }
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
                    .padding(.vertical, Theme.tight)
                }
                .onChange(of: currentHighlight) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = currentHighlight.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        highlightedID = items[min(max(0, current + delta), items.count - 1)].id
        return .handled
    }

    private func openHighlighted() {
        guard let id = currentHighlight, let item = items.first(where: { $0.id == id })
        else { return }
        open(item)
        dismiss()
    }
}

/// FTS5's `snippet()` marks matches with `«` … `»` — cheaper and safer than
/// asking it for HTML, since this renders in SwiftUI rather than the web
/// view. The matched words are set in the primary color and semibold.
@MainActor
func markedSnippet(_ text: String) -> Text {
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
