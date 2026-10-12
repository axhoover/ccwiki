import SwiftUI

// How a reader window's session reaches what is outside its view tree
// (plans/reader-comforts.md §1.4, §1.5): the menu bar, which acts on the
// key reader window's own session.

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
