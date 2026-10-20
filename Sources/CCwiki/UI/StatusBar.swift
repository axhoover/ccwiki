import SwiftUI

/// The quiet strip macOS apps keep at the bottom of a reader window: what
/// just happened, and anything that needs attention but must not interrupt
/// reading.
///
/// A view of its own rather than part of `RootView`'s body, so what it reads
/// redraws the strip, not the window (SWIFTUI-RULES §6.3). The line a sync
/// prints is read further down still, by `SyncProgressText`: a clone prints
/// hundreds (plans/efficiency.md, U4).
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.small) {
                switch model.syncState {
                case .running(let phase):
                    ProgressView().controlSize(.small)
                    SyncProgressText(phase: phase)
                case .failed(let message):
                    Image(systemName: model.syncState.isOffline
                        ? "wifi.slash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.syncState.isOffline
                            ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !model.syncLog.isEmpty {
                        Button("Details…") { session.syncLogPresented = true }
                            .buttonStyle(.link)
                            .font(Theme.Fonts.meta)
                            .fixedSize()
                    }
                case .succeeded(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .idle:
                    // The resting state says how current the wiki is, which
                    // a reader can act on; the hash is in the tooltip.
                    if let date = model.headDate {
                        Image(systemName: "clock")
                            .foregroundStyle(.tertiary)
                        (Text("Wiki as of ") + Text(date, format: .relative(presentation: .named)))
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help(model.headRevision.map { "Commit \($0.prefix(12))" } ?? "")
                    } else if let revision = model.headRevision {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .foregroundStyle(.tertiary)
                        Text(revision.prefix(7))
                            .font(Theme.Fonts.log)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: Theme.small)

                if let error = session.webController.lastRenderError {
                    Label(error, systemImage: "exclamationmark.bubble")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let progress = model.updateInstallProgress {
                    HStack(spacing: Theme.tight) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text(progress)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if model.activeJobCount > 0 {
                    Button {
                        openWindow(id: CCwikiApp.jobsWindowID)
                    } label: {
                        HStack(spacing: Theme.tight) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("\(model.activeJobCount) job\(model.activeJobCount == 1 ? "" : "s")")
                                .font(Theme.Fonts.meta)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Show the jobs window (⇧⌘J)")
                }
                // The same in every window, like the job count (corrections
                // §6.6, §17): work that waits for a person.
                if model.jobCenter.reviewCount > 0 {
                    Button {
                        model.requestJobsWindow(selecting: firstAwaitingReview)
                    } label: {
                        Text("\(model.jobCenter.reviewCount) awaiting review")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Review the changes in the jobs window")
                }
                if !model.warnings.isEmpty {
                    // Warnings are unique (`AppModel.warn`), so the text is a
                    // stable identity — and a row, once read, can be put away.
                    Menu {
                        ForEach(model.warnings, id: \.self) { warning in
                            Button(warning) { model.dismissWarning(warning) }
                        }
                        Divider()
                        Button("Dismiss All") { model.dismissAllWarnings() }
                    } label: {
                        Label("\(model.warnings.count)", systemImage: "exclamationmark.triangle")
                            .font(Theme.Fonts.meta)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.orange)
                    .help("Choose a warning to dismiss it")
                }
            }
            .padding(.horizontal, Theme.medium)
            .padding(.vertical, 5)
            .frame(height: 26)
            .background(.bar)
        }
    }

    /// The oldest job that waits for review, which the count opens Jobs on.
    private var firstAwaitingReview: String? {
        model.jobs.last { $0.state == .awaitingReview && !$0.isUntouchedEdit }?.id
    }
}

/// A running sync's latest line, or its phase until git prints one. The one
/// view in a reader window that reads `syncProgress`, so each line redraws
/// this `Text` and nothing around it.
private struct SyncProgressText: View {
    @Environment(AppModel.self) private var model
    let phase: String

    var body: some View {
        Text(model.syncProgress ?? phase)
            .font(Theme.Fonts.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
