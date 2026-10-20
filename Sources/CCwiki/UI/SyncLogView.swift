import SwiftUI

/// The transcript of the last sync, in git's own words.
///
/// Every sync failure ends "see the sync log", and until this sheet existed
/// there was nowhere to see it. It is a sheet rather than a pane because it
/// matters only when something went wrong.
struct SyncLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.medium) {
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Sync Log")
                    .font(Theme.Fonts.documentTitle)
                Text(Self.subtitle(
                    for: model.syncState, progress: model.syncProgress,
                    hasLog: !model.syncLog.isEmpty))
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            ScrollView {
                Text(text)
                    .font(Theme.Fonts.log)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.small)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(model.syncLog.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.section)
        .frame(width: 640, height: 440)
    }

    private var text: String {
        model.syncLog.isEmpty
            ? "Nothing has been logged yet. The log fills in as a sync runs."
            : model.syncLog.joined(separator: "\n")
    }

    /// The heading under the title. Idle is where a success settles after a
    /// few seconds as well as where a launch starts, and the log keeps the
    /// transcript until the next sync, so an idle state with a log is a sync
    /// that finished, not one that never ran. While a sync runs, it names
    /// the line printed last (`AppModel.syncProgress`), or else the phase.
    static func subtitle(
        for state: AppModel.SyncState, progress: String? = nil, hasLog: Bool
    ) -> String {
        switch state {
        case .idle: hasLog ? "The last sync finished." : "No sync has run since launch."
        case .running(let phase): "Running: \(progress ?? phase)"
        case .succeeded(let message): message
        case .failed(let message): message
        }
    }
}
