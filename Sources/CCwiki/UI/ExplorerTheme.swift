import SwiftUI

// The Relations Explorer's metrics, named as `SWIFTUI-RULES.md` §2.4 asks and
// kept beside the views that use them (relations-explorer.md §5).

extension Theme {

    // MARK: Relations explorer

    static let explorerMinWidth: CGFloat = 620
    static let explorerMinHeight: CGFloat = 460
    static let explorerDefaultWidth: CGFloat = 820
    static let explorerDefaultHeight: CGFloat = 640
    static let explorerSuggestionLimit = 8

    /// The From and To boxes: inner padding and corner, as a text field.
    static let tokenFieldPadding: CGFloat = 5
    static let tokenFieldCornerRadius: CGFloat = 6
    /// The typing area never gets narrower than this; below it, it wraps to
    /// a line of its own.
    static let tokenFieldMinTextWidth: CGFloat = 140
    /// A token: one line, cut in the middle beyond this width, so one long
    /// variant cannot take the field over.
    static let tokenCornerRadius: CGFloat = 5
    static let tokenPaddingHorizontal: CGFloat = 6
    static let tokenPaddingVertical: CGFloat = 2
    static let tokenSpacing: CGFloat = 4
    static let tokenMaxWidth: CGFloat = 280

    /// The proof's gutter for `∧`, so premises line up whether or not they
    /// carry one.
    static let conjunctionGutter: CGFloat = 12
}

extension Theme.Fonts {
    /// The explorer's answer: "Derivable", "No derivation found".
    static let verdict = Font.title3.weight(.semibold)
}
