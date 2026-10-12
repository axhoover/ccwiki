import SwiftUI

/// Open an Issue About This Page (route c): the exact text sent to GitHub,
/// with the footer CCwiki adds shown beneath it (plans/corrections.md §8.2).
///
/// Phase 0: a placeholder. Track C builds the sheet (§11.4). `RootView`
/// presents it with `IssueSheet(request:)`; that stays.
struct IssueSheet: View {
    let request: CorrectionSheetRequest

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView {
            Label("Open an Issue About This Page", systemImage: "exclamationmark.bubble")
        } description: {
            Text(request.target.pageTitle)
        } actions: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: Theme.sheetWidth)
        .padding(Theme.section)
    }
}
