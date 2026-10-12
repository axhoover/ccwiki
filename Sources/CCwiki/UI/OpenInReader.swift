import SwiftUI

// How a reader window's session reaches what is outside its view tree
// (plans/reader-comforts.md §1.4, §1.5): the menu bar, which acts on the
// key reader window's own session, and the scene, which opens the new tabs
// and windows the session asks for.

/// Opens a page in a new reader tab or window, for a session that cannot
/// call `openWindow` itself (§1.4).
///
/// `openWindow` is an environment action, so only a view has one. Each
/// reader window's view builds this from its own and hands it to its
/// session, which calls it for an Open in New Tab or New Window, from a
/// SwiftUI row and from a link in the web view alike. Every session has its
/// view, so nothing waits in a queue.
struct OpenInReaderAction: Sendable {
    /// What a session holds until its view hands it the real one: nothing
    /// opens.
    static let none = OpenInReaderAction { _, _, _ in }

    /// Opens the location as the disposition says; the strings are found on
    /// the page once it renders.
    let handler: @MainActor @Sendable (AppModel.Location, LinkDisposition, [String]?) -> Void

    @MainActor func callAsFunction(
        _ location: AppModel.Location, _ disposition: LinkDisposition, find: [String]? = nil
    ) {
        handler(location, disposition, find)
    }
}

/// Open in New Tab and Open in New Window: what a row that opens a page
/// offers in its context menu, first, or after its own Open item
/// (§1.1). `title` names what opens, as a folder label's "Open Folder Page"
/// does.
///
/// The row says what opening means, so a palette can close itself after.
struct OpenElsewhereItems: View {
    var title = "Open"
    let open: (LinkDisposition) -> Void

    var body: some View {
        Button("\(title) in New Tab") { open(.newTab(inBackground: true)) }
        Button("\(title) in New Window") { open(.newWindow) }
    }
}

extension LinkDisposition {
    /// Whether a palette stays open after it opens a row this way: only for
    /// a tab behind its window, so a reader can open hit after hit (§1.1).
    ///
    /// Until the maintainer has checked background tabs on a Mac
    /// (`WindowTabbing.joinsInBackground`), every new tab opens in front of
    /// the palette's window, and a palette left up on a tab nobody is looking
    /// at would only be found later, so it closes as it does for any other
    /// way of opening.
    @MainActor var keepsPaletteOpen: Bool {
        self == .newTab(inBackground: true) && WindowTabbing.joinsInBackground
    }
}

// `@Entry` on a FocusedValues property is macOS 15; this is the macOS 14 form.
private struct ReaderSessionKey: FocusedValueKey {
    typealias Value = ReaderSession
}

extension FocusedValues {
    /// The key reader window's session, for every command about a page:
    /// Back and Forward, the inspector, the palettes, Print, the page's link.
    /// Nil while a window that is not a reader is key, so those commands are
    /// disabled there, as they always have been.
    var readerSession: ReaderSession? {
        get { self[ReaderSessionKey.self] }
        set { self[ReaderSessionKey.self] = newValue }
    }
}
