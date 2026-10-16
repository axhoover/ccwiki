import SwiftUI

/// The frame ⌘S, ⇧⌘R and ⇧⌘F share: a field, a list you move through with
/// the arrow keys and open with Return, and a footer. Each search supplies
/// only its rows and what opening one does.
///
/// Return opens the highlighted row where you are and closes the palette.
/// ⌘Return opens it in a tab behind this one and leaves the palette open,
/// with its highlight, so a reader can open hit after hit; ⇧⌘Return opens
/// it in a tab in front and closes the palette (reader-comforts §1.1). A
/// click reads the modifiers held, as a link does. Return, with ⌘ or
/// without, pressed before the rows are the results for the text in the
/// field waits for them (`PaletteReturn`).
struct SearchPalette<Item: Identifiable, Row: View>: View where Item.ID == String {
    @Binding var query: String
    let placeholder: String
    let systemImage: String
    let items: [Item]
    /// The text `items` are the results for. The search runs once typing
    /// pauses, so for a moment after a keystroke it is not `query`.
    let resultsQuery: String
    let error: String?
    /// A line above the results, such as the correction they are for.
    var note: String? = nil
    /// Shown before anything is typed.
    let emptyTitle: String
    let emptyDescription: String
    /// "12 pages", "3 papers".
    let countLabel: (Int) -> String
    /// Opens a row where the disposition says: here, or in a new tab or
    /// window.
    let open: (Item, LinkDisposition) -> Void
    @ViewBuilder let row: (Item) -> Row

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    /// By id, not by index — see the note in `QuickSwitcherView`.
    @State private var highlightedID: String?
    @State private var pendingReturn = PaletteReturn()

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
                    .onSubmit { press(.here) }
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
                KeyHint(key: "⌘↩", label: "New Tab")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.small)
            .background { PaletteTabShortcuts { press($0) } }
        }
        .frame(width: 720, height: 540)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, new in
            highlightedID = nil
            pendingReturn.queryChanged(to: new)
        }
        .onChange(of: resultsQuery) { _, new in
            if let disposition = pendingReturn.resultsChanged(to: new, query: query) {
                openHighlighted(disposition)
            }
        }
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
            if let note {
                Label(note, systemImage: "wand.and.stars")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.large)
                    .padding(.top, Theme.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                                    openItem(item, LinkDisposition.current)
                                }
                                .contextMenu {
                                    OpenElsewhereItems { openItem(item, $0) }
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

    /// Return, ⌘Return or ⇧⌘Return: the highlighted row now, or once the
    /// results for the text in the field are in.
    private func press(_ disposition: LinkDisposition) {
        if let now = pendingReturn.press(disposition, query: query, resultsQuery: resultsQuery) {
            openHighlighted(now)
        }
    }

    private func openHighlighted(_ disposition: LinkDisposition) {
        guard let id = currentHighlight, let item = items.first(where: { $0.id == id })
        else { return }
        openItem(item, disposition)
    }

    /// Opens `item`, then closes the palette, unless it opened in a tab
    /// behind this window: then the palette stays for the next hit.
    private func openItem(_ item: Item, _ disposition: LinkDisposition) {
        open(item, disposition)
        if !disposition.keepsPaletteOpen { dismiss() }
    }
}

/// Return in a palette whose search runs once typing pauses: for a moment
/// after a keystroke the rows are still the last query's, and Return must
/// not open one of those. It waits for the results of the text it was
/// pressed on, and is dropped if the text changes first. Pure, so a test can
/// press Return between keystrokes.
struct PaletteReturn {
    /// The text Return was pressed on, and where it asked to open.
    private(set) var pending: (query: String, disposition: LinkDisposition)?

    /// Return on `query` while the rows are the results for `resultsQuery`:
    /// where to open the highlighted row now, or nil while it waits.
    mutating func press(
        _ disposition: LinkDisposition, query: String, resultsQuery: String
    ) -> LinkDisposition? {
        guard query != resultsQuery else {
            pending = nil
            return disposition
        }
        pending = (query: query, disposition: disposition)
        return nil
    }

    /// The text in the field changed. A Return pressed on other text is
    /// dropped. One pressed on this very text stays: SwiftUI can report the
    /// change after a Return typed right behind the keystroke.
    mutating func queryChanged(to query: String) {
        if pending?.query != query { pending = nil }
    }

    /// The rows are now the results for `resultsQuery`: where a waiting
    /// Return opens the highlighted row, if they are for the text it was
    /// pressed on and that is still the text in the field.
    mutating func resultsChanged(to resultsQuery: String, query: String) -> LinkDisposition? {
        guard let waiting = pending, waiting.query == resultsQuery, resultsQuery == query
        else { return nil }
        pending = nil
        return waiting.disposition
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
