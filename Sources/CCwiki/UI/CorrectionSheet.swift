import SwiftUI

/// Describe a Correction (route b): what is wrong and what it should say,
/// for an agent to draft the smallest edit (plans/corrections.md §8.1).
///
/// Phase 0: a placeholder. Track C builds the sheet (§11.4). `RootView`
/// presents it with `CorrectionSheet(request:)`; that stays.
struct CorrectionSheet: View {
    let request: CorrectionSheetRequest

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView {
            Label("Describe a Correction", systemImage: "text.bubble")
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
