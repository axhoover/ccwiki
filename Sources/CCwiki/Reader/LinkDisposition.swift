import AppKit

/// What a click on a link means: where the page it names should open.
///
/// One table for every way in, the page's links in the web view and the
/// rows SwiftUI draws alike, so a ⌘-click means the same thing wherever it
/// lands (plans/reader-comforts.md §1.4).
enum LinkDisposition: Hashable, Sendable {
    /// Where you are.
    case here
    /// A new tab in this window, behind the one you are reading or in front.
    case newTab(inBackground: Bool)
    case newWindow
    /// The page on cryptology.city, in the browser.
    case onSite

    /// A click in the page, as Safari reads it (§1.4).
    ///
    /// Until there are tabs to open, ⌘ or ⇧ means the page on the site, as a
    /// modified click always has, and anything else opens the link where you
    /// are. Track B gives the other gestures their meaning (B1).
    static func forClick(
        command: Bool, shift: Bool, option: Bool, middleButton: Bool
    ) -> LinkDisposition {
        command || shift ? .onSite : .here
    }

    /// The modifiers held now, for a SwiftUI button's action. A SwiftUI
    /// button answers only the primary button, so there is no middle click
    /// to read.
    @MainActor static var current: LinkDisposition {
        let flags = NSEvent.modifierFlags
        return forClick(
            command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), middleButton: false)
    }
}
