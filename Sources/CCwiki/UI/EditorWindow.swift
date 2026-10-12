import SwiftUI

/// An editor window: one file of one job, its source beside a preview
/// rendered by the reader's own pipeline (plans/corrections.md §7.2).
///
/// Phase 0: a placeholder. Track D builds the window (§11.5). The scene in
/// `CCwikiApp` makes it with `EditorWindow(target:)`, runs the launch, and
/// gives the window `tabbingIdentifier`; those stay.
struct EditorWindow: View {
    /// Nil for a window SwiftUI opens without a value, which has no file.
    let target: EditorTarget?

    /// Editors tab with editors, never with readers or papers (§17).
    static let tabbingIdentifier = "ccwiki.editor"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView(
            "Editing Is Not Built Yet", systemImage: "square.and.pencil",
            description: Text("This window will hold the page's Markdown and its preview."))
            .frame(
                minWidth: Theme.editorPaneMinWidth * 2,
                minHeight: Theme.editorPaneMinWidth)
            .navigationTitle(target.map { ($0.path as NSString).lastPathComponent } ?? "Edit Page")
            // A window whose job is gone, restored or opened without one,
            // closes itself (SWIFTUI-RULES §6.5). The history is loaded
            // before any window, so the answer is already there.
            .onChange(of: hasNoJob, initial: true) { _, gone in
                if gone { dismiss() }
            }
    }

    private var hasNoJob: Bool {
        guard let target else { return true }
        return model.jobCenter.job(id: target.jobID) == nil
    }
}
