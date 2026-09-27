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
                Text(subtitle)
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

    private var subtitle: String {
        switch model.syncState {
        case .idle: "No sync has run since launch."
        case .running(let message): "Running: \(message)"
        case .succeeded(let message): message
        case .failed(let message): message
        }
    }
}
