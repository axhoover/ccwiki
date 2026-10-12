import SwiftUI

/// A paper's window: the PDF behind a reference page, keyed by the page's
/// path (plans/reader-comforts.md §2.2, §2.6).
///
/// A placeholder until Track C builds it (C6). Nothing opens one yet: Show
/// Paper stays out of the menus until `ShowPaperCommand.isAvailable`.
struct PaperWindowView: View {
    let referencePath: String?

    var body: some View {
        ContentUnavailableView(
            "No Paper", systemImage: "doc.richtext",
            description: Text("CCwiki can't show papers yet."))
    }
}

extension Theme {

    // MARK: Paper window

    /// A US Letter page and its margins (§2.2). The height is clamped to the
    /// screen's visible frame on first show; a 13-inch laptop has about 870 pt.
    static let paperDefaultWidth: CGFloat = 780
    static let paperDefaultHeight: CGFloat = 980
    static let paperMinWidth: CGFloat = 480
    static let paperMinHeight: CGFloat = 560
}

/// Wiki ▸ Show Paper (⌥⌘P), and the reference bar's button: the paper behind
/// the reference page being read, in its own window.
enum ShowPaperCommand {

    /// False until papers can be fetched (C6), so no dead item ships
    /// (SWIFTUI-RULES §7.4).
    static let isAvailable = false

    /// Only a reference page has a paper behind it.
    @MainActor static func isEnabled(for page: WikiPage?) -> Bool {
        page?.kind == .reference
    }

    /// Start the fetch, unless the paper is already kept, and bring its
    /// window forward. One window per paper: `WindowGroup` brings an open
    /// one forward rather than opening it twice.
    @MainActor static func perform(
        _ page: WikiPage, model: AppModel, openWindow: OpenWindowAction
    ) {
        model.papers.show(page)
        openWindow(id: CCwikiApp.paperWindowID, value: page.path)
    }
}

/// View ▸ Zoom In, Zoom Out and Actual Size, while a paper window is key.
/// The paper's `PDFView` hands these up, and the View menu's text-size items
/// act on them in its place, retitled as Preview titles them.
struct PaperZoomAction: Sendable {
    let zoomIn: @MainActor @Sendable () -> Void
    let zoomOut: @MainActor @Sendable () -> Void
    /// Fit to the window again: `autoScales` back on.
    let actualSize: @MainActor @Sendable () -> Void
}

// `@Entry` on a FocusedValues property is macOS 15; this is the macOS 14 form.
private struct PaperZoomKey: FocusedValueKey {
    typealias Value = PaperZoomAction
}

extension FocusedValues {
    var paperZoom: PaperZoomAction? {
        get { self[PaperZoomKey.self] }
        set { self[PaperZoomKey.self] = newValue }
    }
}
