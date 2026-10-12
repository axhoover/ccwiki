import SwiftUI

/// A key and what it does, as a palette's footer shows it: "⌘↩ New Tab".
///
/// The key is a small cap on a quaternary fill and the words are secondary,
/// so a row of hints reads as keys, not as a sentence. Every palette footer
/// draws its keys with this, so a key looks the same in each
/// (`SWIFTUI-RULES.md` §5.4, §8.6).
struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
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
        .accessibilityElement(children: .combine)
    }
}

/// ⌘Return and ⇧⌘Return in a palette: the highlighted row in a new tab,
/// behind the reader's window or in front of it (reader-comforts §1.1).
///
/// Key equivalents on buttons nobody sees, zero-sized and transparent, so
/// they take no room in the footer, whose hint names the key instead. A
/// key equivalent is answered before the field sees the key, as the ingest
/// sheet's ⌘Return is, so the field's `onSubmit` never opens the row here
/// as well.
struct PaletteTabShortcuts: View {
    let open: (LinkDisposition) -> Void

    var body: some View {
        ZStack {
            Button("Open in New Tab") { open(.newTab(inBackground: true)) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Open in New Tab in Front") { open(.newTab(inBackground: false)) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
