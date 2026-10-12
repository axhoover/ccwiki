import SwiftUI

/// Show Paper on a reference page's bar, after the Source link
/// (plans/reader-comforts.md §2.6): the paper in a window of its own,
/// fetched from the reference's own link the first time.
///
/// Its own view, so a download's progress redraws this button and not the
/// whole bar (SWIFTUI-RULES §6.3). The tooltip says what a click will do.
struct ShowPaperButton: View {
    let page: WikiPage

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            ShowPaperCommand.perform(page, model: model, openWindow: openWindow)
        } label: {
            Label("Show Paper", systemImage: "doc.richtext")
                .font(Theme.Fonts.meta)
        }
        .buttonStyle(.link)
        .help(tooltip)
    }

    private var tooltip: String {
        if case .ready = model.papers.state(for: page.path) {
            return "Open the paper from CCwiki's library (⌥⌘P)"
        }
        guard let first = PaperSource(page: page).candidates.first else {
            return "Add your own copy of this paper's PDF (⌥⌘P)"
        }
        let host = first.url.host() ?? first.url.absoluteString
        if first.kind == .landingPage {
            return "Look for the PDF at \(host) and keep it in CCwiki's library (⌥⌘P)"
        }
        return "Download the PDF from \(host) and keep it in CCwiki's library (⌥⌘P)"
    }
}
