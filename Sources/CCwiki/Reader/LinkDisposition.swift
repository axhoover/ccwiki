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
    /// The page on cryptology.city, in the browser. No click means this:
    /// only the link menu's Open Link on cryptology.city asks for it.
    case onSite

    /// A click in the page, as Safari reads it (§1.4).
    ///
    /// | Gesture | Disposition |
    /// |---|---|
    /// | click; ⇧-click; ⌥-click | `.here` |
    /// | ⌘-click; middle-click | `.newTab(inBackground: true)` |
    /// | ⇧⌘-click; ⇧-middle-click | `.newTab(inBackground: false)` |
    /// | ⌥⌘-click; ⌥⇧⌘-click; ⌥-middle-click | `.newWindow` |
    ///
    /// The middle button is a ⌘-click without the key, so ⇧ and ⌥ change it
    /// as they change a ⌘-click. ⇧ or ⌥ alone never takes a link elsewhere.
    static func forClick(
        command: Bool, shift: Bool, option: Bool, middleButton: Bool
    ) -> LinkDisposition {
        guard command || middleButton else { return .here }
        if option { return .newWindow }
        return .newTab(inBackground: !shift)
    }

    /// The `navigate` message `ccwiki.js` posts for a click on a link, which
    /// carries the keys held and whether it was the middle button. A key that
    /// is missing, `null` or not a Boolean reads as not held.
    static func forClick(message: [String: Any]) -> LinkDisposition {
        func held(_ key: String) -> Bool { message[key] as? Bool ?? false }
        return forClick(
            command: held("command"), shift: held("shift"),
            option: held("option"), middleButton: held("middleButton"))
    }

    /// A link WebKit followed itself, the page's click listener having missed
    /// it: read from `WKNavigationAction`'s `buttonNumber` and
    /// `modifierFlags`. On the Mac WebKit reports the button as a mask, 1
    /// for the primary button, 2 the secondary and 4 the middle; 0 means no
    /// button, as for a navigation a menu item started.
    static func forNavigation(
        buttonNumber: Int, modifierFlags: NSEvent.ModifierFlags
    ) -> LinkDisposition {
        forClick(
            command: modifierFlags.contains(.command), shift: modifierFlags.contains(.shift),
            option: modifierFlags.contains(.option), middleButton: (buttonNumber & 4) != 0)
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
