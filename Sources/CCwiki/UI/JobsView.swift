import SwiftUI

/// The jobs window: the queue on the left, one job on the right.
///
/// A separate window rather than a fourth pane, because the thing you actually
/// want is to watch a job run *while reading the page it is going to edit* —
/// and because a queue has no natural home in a three-column reader without
/// displacing the page.
///
/// Work that waits for a person comes first, under Awaiting Review: every
/// route ends there, ingestion included, and it is the only place a change
/// leaves for GitHub (plans/corrections.md §6.6).
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?
    @State private var discardRequest: DiscardRequest?

    /// Waiting for a person, or on its way to GitHub from there. An edit
    /// nobody has changed yet is still being written, and waits under Jobs
    /// (§4.1).
    private var awaitingReview: [Job] {
        model.jobs.filter { Self.isAwaitingReview($0) }
    }

    private var otherJobs: [Job] {
        model.jobs.filter { !Self.isAwaitingReview($0) }
    }

    private static func isAwaitingReview(_ job: Job) -> Bool {
        (job.state == .awaitingReview && !job.isUntouchedEdit) || job.state.isPublishing
    }

    /// The selected job; with none, or once it has left the list (Clear
    /// Finished, an untouched edit gone with its editor), the first in the
    /// list, as it reads.
    private var selectedJob: Job? {
        if let selection, let job = model.jobs.first(where: { $0.id == selection }) { return job }
        return awaitingReview.first ?? otherJobs.first
    }

    var body: some View {
        NavigationSplitView {
            queue
                // Over the queue, as Mail puts New Message over its list.
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            model.clearFinishedJobs()
                        } label: {
                            Label("Clear Finished", systemImage: "xmark.bin")
                        }
                        .help("Remove finished jobs from the list. Transcripts are kept; "
                            + "a discarded job's saved changes are deleted.")
                        .disabled(!model.hasFinishedJobs)

                        Button {
                            IngestCommand.perform(in: nil, model: model, openWindow: openWindow)
                        } label: {
                            Label("Ingest a Paper", systemImage: "plus")
                        }
                        .help("Ingest a paper (⇧⌘N)")
                    }
                }
        } detail: {
            if let job = selectedJob {
                // A view per job: its pane, its publish under way and its
                // restore are that job's, never the next one's.
                JobDetailView(job: job)
                    .id(job.id)
            } else {
                ContentUnavailableView {
                    Label("No Jobs Yet", systemImage: "tray")
                } description: {
                    Text("Drop a PDF on the reader, or paste an ePrint, arXiv or DOI link.")
                } actions: {
                    Button("Ingest a Paper…") {
                        IngestCommand.perform(in: nil, model: model, openWindow: openWindow)
                    }
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
        .discardConfirmation($discardRequest)
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

            let review = awaitingReview
            if !review.isEmpty {
                Section("Awaiting Review") {
                    ForEach(review) { job in
                        row(job).tag(job.id)
                    }
                }
            }

            let others = otherJobs
            if !others.isEmpty {
                Section("Jobs") {
                    ForEach(others) { job in
                        row(job).tag(job.id)
                    }
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

    // MARK: A row

    /// The kind's glyph, the page or paper, then where the job is.
    private func row(_ job: Job) -> some View {
        HStack(spacing: Theme.small) {
            JobKindIcon(kind: job.kind, state: job.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(Theme.Fonts.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.subtitle(of: job))
                    .font(Theme.Fonts.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .contextMenu { menu(for: job) }
    }

    /// "Lines 42–44, in “Security” · Awaiting review"; the status alone for
    /// a paper, whose title already says which.
    private static func subtitle(of job: Job) -> String {
        switch job.kind {
        case .ingestion: job.statusLabel
        case .correction, .edit: "\(job.detail) · \(job.statusLabel)"
        }
    }

    @ViewBuilder
    private func menu(for job: Job) -> some View {
        if job.canEdit {
            let files = JobReview.editableFiles(kind: job.kind, review: job.review)
            if files.count > 1 {
                Menu("Edit") {
                    ForEach(files) { file in
                        Button(file.title) { edit(file, of: job) }
                    }
                }
            } else if let file = files.first {
                Button("Edit…") { edit(file, of: job) }
            }
        }
        if job.state == .awaitingReview {
            Button("Discard…", role: .destructive) { requestDiscard(job) }
        }
        // Only work that has not reached review can be cancelled
        // (corrections §4.1).
        if job.state.isCancellable {
            Button("Cancel Job") { job.cancel() }
        }
        if job.canRunAgain {
            Button("Run Again") { model.runAgain(job) }
        }
        if JobReview.offersReviewAnyway(
            kind: job.kind.tag, state: job.state,
            worktreeExists: Self.exists(job.worktree), review: job.review) {
            Button("Review Anyway") {
                Task { await model.jobCenter.reviewAnyway(job) }
            }
        }

        Divider()

        Button("Reveal Worktree in Terminal") { model.openInTerminal(job.worktree) }
            .disabled(!Self.exists(job.worktree))
        Button("Reveal Transcript in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([job.logFile])
        }
        // The last reviewed diff, kept outside Caches (§4.4).
        if Self.exists(job.patchFile) {
            Button("Reveal Patch in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([job.patchFile])
            }
        }
        if case .opened(let url) = job.state {
            Divider()
            Button("Open Pull Request") { NSWorkspace.shared.open(url) }
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func edit(_ file: JobReview.EditableFile, of job: Job) {
        model.showEditor(
            EditorTarget(jobID: job.id, path: file.path), at: file.lines, using: openWindow)
    }

    private func requestDiscard(_ job: Job) {
        Task { discardRequest = await DiscardRequest.prepare(for: job, in: model.jobCenter) }
    }
}

/// A queue row's glyph: the job's kind, tinted by where it is, and a
/// spinner while a process runs for it (§6.6).
struct JobKindIcon: View {
    let kind: JobKind
    let state: JobState

    var body: some View {
        Group {
            if state.isActive {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(JobStateIcon.tint(for: state))
            }
        }
        .frame(width: 16)
        .accessibilityLabel(kind.noun.capitalized)
    }
}

/// The job's status glyph, spinning while the job is live.
struct JobStateIcon: View {
    let state: JobState

    var body: some View {
        Group {
            if state.isActive {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: state.symbolName)
                    .foregroundStyle(Self.tint(for: state))
            }
        }
        .frame(width: 16)
    }

    static func tint(for state: JobState) -> Color {
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
