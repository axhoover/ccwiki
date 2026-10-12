import SwiftUI

/// What Edit → Copy Proof As acts on: the explorer's proof, published
/// through `focusedSceneValue` as the reader publishes `FindAction`, so the
/// menu bar reaches it without a reference to the view
/// (plans/relations-followups.md §3.1). The explorer publishes nil while its
/// suggestions show, since the answer underneath is not on screen, and
/// whenever it has no answer, which disables the commands.
struct ProofCopyAction: Equatable {
    let id: UUID
    let copy: (ProofFormat) -> Void
    /// Some cited work has an inline BibTeX entry.
    let hasInlineEntries: Bool

    init(id: UUID = UUID(), copy: @escaping (ProofFormat) -> Void, hasInlineEntries: Bool) {
        self.id = id
        self.copy = copy
        self.hasInlineEntries = hasInlineEntries
    }

    static func == (a: ProofCopyAction, b: ProofCopyAction) -> Bool { a.id == b.id }
}

// `@Entry` on a FocusedValues property is macOS 15; this is the macOS 14 form.
private struct ProofCopyActionKey: FocusedValueKey {
    typealias Value = ProofCopyAction
}

extension FocusedValues {
    var proofCopyAction: ProofCopyAction? {
        get { self[ProofCopyActionKey.self] }
        set { self[ProofCopyActionKey.self] = newValue }
    }
}

/// The Edit menu's proof commands, after the pasteboard group: one submenu
/// and one item, the context menu's structure, rather than four new
/// top-level items in every window. ⌥⌘C is Option-Copy, another form of the
/// same thing, as Finder's Copy as Pathname is; ⌥⇧⌘C is the second form.
/// Key equivalents inside a menu-bar submenu still fire and still show.
struct ProofCopyCommandItems: View {
    let action: ProofCopyAction?

    var body: some View {
        Divider()
        Menu("Copy Proof As") {
            Button(ProofFormat.text.title) { action?.copy(.text) }
            Button(ProofFormat.latex.title) { action?.copy(.latex) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button(ProofFormat.wikiMarkdown.title) { action?.copy(.wikiMarkdown) }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
        }
        .disabled(action == nil)
        Button("Copy BibTeX of Cited Works") { action?.copy(.bibtex) }
            .disabled(action?.hasInlineEntries != true)
    }
}

/// "Copy Proof As ▸ Text, LaTeX, Wiki Markdown" in a row's context menu: the
/// explorer's and the inspector's derived rows, so the two read the same
/// (`SWIFTUI-RULES` §5.4). No shortcuts: the inspector has no menu-bar
/// equivalent, and a shortcut shown there would not work.
struct ProofCopyMenu: View {
    let copy: (ProofFormat) -> Void

    var body: some View {
        Menu("Copy Proof As") {
            ForEach(ProofFormat.proofForms, id: \.self) { format in
                Button(format.title) { copy(format) }
            }
        }
    }
}
