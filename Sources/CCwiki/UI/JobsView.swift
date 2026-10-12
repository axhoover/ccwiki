import SwiftUI

/// The jobs window: the queue on the left, one job's transcript on the right.
///
/// A separate window rather than a fourth pane, because the thing you actually
/// want is to watch a job run *while reading the page it is going to edit* —
/// and because a queue has no natural home in a three-column reader without
/// displacing the page.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    private var selectedJob: Job? {
        guard let selection else { return model.jobs.first }
        return model.jobs.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            queue
        } detail: {
            if let job = selectedJob {
                JobDetailView(job: job)
            } else {
                ContentUnavailableView {
                    Label("No Jobs Yet", systemImage: "tray")
                } description: {
                    Text("Drop a PDF on the reader, or paste an ePrint, arXiv or DOI link.")
                } actions: {
                    Button("Ingest a Paper…") { model.requestIngestSheet(in: nil) }
                }
            }
        }
        .navigationTitle("Jobs")
        .frame(minWidth: Theme.jobsMinWidth, minHeight: Theme.jobsMinHeight)
        // A job just started, or the review a reader's status bar leads to:
        // the window opens on it (corrections §6.6). Taken once, so Show
        // Jobs later opens on the newest job, not on one since cleared.
        .onChange(of: model.jobsWindowRequests, initial: true) { _, _ in
            if let requested = model.takeJobsWindowSelection(),
               model.jobs.contains(where: { $0.id == requested }) {
                selection = requested
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.clearFinishedJobs()
                } label: {
                    Label("Clear Finished", systemImage: "xmark.bin")
                }
                .help("Remove finished jobs from the list. Transcripts are kept.")
                .disabled(!model.hasFinishedJobs)

                Button {
                    model.requestIngestSheet(in: nil)
                } label: {
                    Label("Ingest a Paper", systemImage: "plus")
                }
                .help("Ingest a paper (⇧⌘N)")
            }
        }
    }

    private var queue: some View {
        List(selection: $selection) {
            if !model.orphanedWorktrees.isEmpty {
                Section("Left Behind") {
                    ForEach(model.orphanedWorktrees, id: \.self) { path in
                        HStack(spacing: Theme.small) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                    .font(Theme.Fonts.row)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Worktree from an interrupted job")
                                    .font(Theme.Fonts.rowSubtitle)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Theme.small)
                            Button("Prune") { model.pruneOrphan(path) }
                                .buttonStyle(.borderless)
                                .font(Theme.Fonts.meta)
                        }
                        .selectionDisabled()
                    }
                }
            }

            Section("Jobs") {
                ForEach(model.jobs) { job in
                    row(job).tag(job.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        .overlay {
            if model.jobs.isEmpty, model.orphanedWorktrees.isEmpty {
                ContentUnavailableView(
                    "No Jobs", systemImage: "tray",
                    description: Text("Papers you ingest and corrections you start appear here."))
                .padding(Theme.medium)
            }
        }
    }

    private func row(_ job: Job) -> some View {
        HStack(spacing: Theme.small) {
            JobStateIcon(state: job.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(Theme.Fonts.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.statusLabel)
                    .font(Theme.Fonts.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            // Only work that has not reached review can be cancelled
            // (corrections §4.1).
            if job.state.isCancellable {
                Button("Cancel Job") { job.cancel() }
            }
            if job.canRunAgain {
                Button("Run Again") { model.runAgain(job) }
            }
            Button("Reveal Worktree in Terminal") { model.openInTerminal(job.worktree) }
                .disabled(!FileManager.default.fileExists(
                    atPath: job.worktree.path(percentEncoded: false)))
            Button("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([job.logFile])
            }
            if case .opened(let url) = job.state {
                Divider()
                Button("Open Pull Request") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// The queue's status glyph, spinning while the job is live.
struct JobStateIcon: View {
    let state: JobState

    var body: some View {
        Group {
            if state.isActive {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: state.symbolName)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 16)
    }

    private var tint: Color {
        switch state {
        case .queued: .secondary
        case .preparing, .running, .publishing: .accentColor
        case .awaitingReview: .accentColor
        case .opened: .green
        case .aborted: .orange
        case .failed: .red
        case .cancelled, .discarded: .secondary
        }
    }
}
