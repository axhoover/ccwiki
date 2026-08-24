import SwiftUI

/// Centralized layout metrics and type scale for the app *chrome*.
///
/// Two type systems live in CCwiki and they are deliberately different:
///
/// - **This one** — the macOS UI. Semantic SwiftUI text styles only, which on
///   macOS land on the 13 pt system font for body and scale correctly with the
///   OS. Never hardcoded point sizes, so Dynamic Type and future metric
///   changes keep working.
/// - **`Resources/web/app.css`** — the document inside the web view, set in a
///   serif at reading size with a capped measure. A page is a document, not
///   chrome, and setting it in 13 pt UI sans would make the wiki look like a
///   settings panel.
///
/// Emphasis is weight; de-emphasis is color (`.secondary` / `.tertiary`),
/// never a lighter font weight.
enum Theme {

    // MARK: Window

    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 560
    static let windowDefaultWidth: CGFloat = 1280
    static let windowDefaultHeight: CGFloat = 860

    // MARK: Sidebar

    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 268
    static let sidebarMaxWidth: CGFloat = 380

    // MARK: Inspector

    /// 240 rather than 220 so the inspector's three-segment switch —
    /// Outline / Backlinks / Relations — fits without truncating at the
    /// narrowest the column can be dragged to.
    static let inspectorMinWidth: CGFloat = 240
    static let inspectorIdealWidth: CGFloat = 280
    static let inspectorMaxWidth: CGFloat = 400

    // MARK: Spacing — an 8 pt grid, as macOS uses

    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let section: CGFloat = 24

    // MARK: Badges

    static let badgeCornerRadius: CGFloat = 4
    static let badgePaddingHorizontal: CGFloat = 6
    static let badgePaddingVertical: CGFloat = 1.5

    // MARK: Quick switcher

    static let paletteWidth: CGFloat = 620
    static let paletteMaxHeight: CGFloat = 420
    static let paletteRowHeight: CGFloat = 38

    // MARK: Find bar

    static let findBarHeight: CGFloat = 36

    // MARK: Type scale

    enum Fonts {
        /// A sidebar row, a list row, an inspector entry — the app's base size.
        static let row = Font.body
        /// The second line of a two-line row.
        static let rowSubtitle = Font.caption
        /// A section header in the sidebar or inspector.
        static let sectionHeader = Font.caption.weight(.semibold)
        /// The reader's title bar — the page you are looking at.
        static let documentTitle = Font.headline
        /// Metadata: counts, timestamps, statuses.
        static let meta = Font.caption
        /// The status badge label.
        static let badge = Font.caption2.weight(.medium)
        /// The quick switcher's primary line.
        static let paletteTitle = Font.title3
        static let paletteSubtitle = Font.callout
        /// A monospaced log line.
        static let log = Font.system(.caption, design: .monospaced)
        /// An empty state's headline.
        static let emptyTitle = Font.title2.weight(.semibold)
    }
}
