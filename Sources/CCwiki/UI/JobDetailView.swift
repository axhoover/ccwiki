import SwiftUI

/// One job: its state and banner, and below them its changes or its live
/// transcript (plans/corrections.md §6.6, design-system §4a).
///
/// A job awaiting review is the review: the toolbar switches between
/// Changes and Transcript, and holds Edit…, Discard… and, last, Open Draft
/// PR. Its metadata moves into the banner's second line and its pre-flight
/// findings to the Transcript. Every other job is its transcript under an
/// outcome banner, as before.
struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let job: Job

    @State private var followsTail = true
    @State private var pane: Pane = .changes
    @State private var discardRequest: DiscardRequest?
    /// What Open Draft PR asks before it runs, while it asks.
    @State private var draftPRQuestion: DraftPRQuestion?
    /// Why Open Draft PR, enabled when drawn, could not run when pressed.
    @State private var draftPRRefusal: String?
    @State private var isApproving = false
    @State private var isRestoring = false
    /// Open an Issue… from the GitHub line: a sheet on this window, not on
    /// a reader behind it (§8).
    @State private var issueRequest: CorrectionSheetRequest?
    /// The local paths that must not be sent, read when the job is shown.
    @State private var privatePaths: [String] = []

    enum Pane: Hashable {
        case changes, transcript
    }

    /// Open Draft PR's question, with the review its click saw: what the
    /// alert's Open Draft PR approves, whatever a refresh has shown since.
    private struct DraftPRQuestion {
        let question: JobReview.Question
        let shown: JobCenter.ShownReview
    }

    /// Waiting for a person, or on its way to GitHub from there.
    private var isUnderReview: Bool {
        job.state == .awaitingReview || job.state.isPublishing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isUnderReview && pane == .changes {
                ReviewView(job: job)
            } else {
                transcriptPane
            }
        }
        .navigationTitle(job.title)
        .navigationSubtitle(job.statusLabel)
        .toolbar { toolbar }
        // Open Draft PR in the Jobs menu, while a review is shown (§9).
        .background {
            if isUnderReview {
                DraftPRCommand(
                    job: job, privatePaths: privatePaths, isApproving: isApproving,
                    open: { openDraftPR() })
            }
        }
        .task(id: job.id) {
            privatePaths = model.jobCenter.environment().privatePaths
            // A restored job's transcript, from its file: once (§4.3).
            await job.replayTranscript()
        }
        // Changes is what a job shows as it enters review (§6.6). Each job
        // has a view of its own (JobsView gives it the job's id), so a pane,
        // a publish under way or a restore never carries over to the next.
        .onChange(of: job.state == .awaitingReview) { _, inReview in
            if inReview { pane = .changes }
        }
        .discardConfirmation($discardRequest)
        .alert(
            draftPRQuestion?.question.title ?? "",
            isPresented: Binding(
                get: { draftPRQuestion != nil }, set: { if !$0 { draftPRQuestion = nil } }),
            presenting: draftPRQuestion
        ) { asked in
            Button("Open Draft PR") { approve(asked.shown) }
            Button("Cancel", role: .cancel) {}
        } message: { asked in
            if let message = asked.question.message { Text(message) }
        }
        .alert("Can't Open the Draft PR Yet", isPresented: Binding(
            get: { draftPRRefusal != nil }, set: { if !$0 { draftPRRefusal = nil } })) {
            Button("OK") {}
        } message: {
            Text(draftPRRefusal ?? "")
        }
        .sheet(item: $issueRequest) { request in
            IssueSheet(request: request)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if isUnderReview {
                Picker("Show", selection: $pane) {
                    Text("Changes").tag(Pane.changes)
                    Text("Transcript").tag(Pane.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("The changes awaiting review, or the agent's transcript")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isUnderReview {
                editControl

                Button(role: .destructive) {
                    requestDiscard()
                } label: {
                    Label("Discard…", systemImage: "trash")
                }
                .disabled(job.state != .awaitingReview)
                .help("Delete this job's changes and its worktree")

                // Last, and the only prominent button. No shortcut: Review
                // Changes brings this window forward on the job, so a key
                // pressed twice from the editor would publish (§9).
                OpenDraftPRButton(
                    job: job, privatePaths: privatePaths, isApproving: isApproving,
                    open: { openDraftPR() })
            } else {
                if case .opened(let url) = job.state {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open PR", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
                // Only work that has not reached review can be cancelled
                // (corrections §4.1).
                if job.state.isCancellable {
                    Button("Cancel", role: .destructive) { job.cancel() }
                }
            }
        }
    }

    /// Edit…: the page, or a pull-down of the files when several changed.
    @ViewBuilder
    private var editControl: some View {
        let files = JobReview.editableFiles(kind: job.kind, review: job.review)
        if files.count > 1 {
            Menu {
                ForEach(files) { file in
                    Button(file.title) { edit(file) }
                }
            } label: {
                Label("Edit…", systemImage: "square.and.pencil")
            }
            .disabled(!job.canEdit)
            .help("Open a changed file in an editor window")
        } else {
            Button {
                if let file = files.first { edit(file) }
            } label: {
                Label("Edit…", systemImage: "square.and.pencil")
            }
            .disabled(!job.canEdit || files.isEmpty)
            .help("Open the page in an editor window")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.small) {
            stateRow
            if isUnderReview {
                reviewBanner
                if let notice = job.notice {
                    JobNoticeLine(notice: notice)
                }
                gitHubLine
            } else {
                outcomeBanner
                outcomeNotice
                metadataRow
                if !job.preflight.isEmpty { preflightList }
            }
        }
        .padding(Theme.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var stateRow: some View {
        HStack(spacing: Theme.small) {
            JobStateIcon(state: job.state)
            Text(job.statusLabel)
                .font(Theme.Fonts.documentTitle)
            Spacer(minLength: Theme.small)
            if let duration = job.duration {
                Text(Duration.seconds(duration).formatted(
                    .units(allowed: [.minutes, .seconds], width: .narrow)))
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let cost = job.outcome?.costUSD {
                Text(cost, format: .currency(code: "USD"))
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help("Model cost for this job")
            }
        }
    }

    /// In the accent colour: what the review waits for, and what is
    /// already on GitHub, or may be (§6.6).
    private var reviewBanner: some View {
        let worktreeIsGone = JobReview.isWorktreeGone(job)
        return banner(.accentColor, reviewSymbol(worktreeIsGone: worktreeIsGone), JobReview.banner(
            state: job.state, needsRestore: worktreeIsGone,
            isUntouchedEdit: job.isUntouchedEdit, pushingCommit: job.pushingCommit,
            pushedCommit: job.pushedCommit, branch: job.branch)
        ) {
            Text(JobReview.metadata(kind: job.kind, branch: job.branch))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if worktreeIsGone {
                Button("Restore") { restore() }
                    .controlSize(.small)
                    .disabled(isRestoring)
                    .help("Make the worktree again and put the saved changes back")
            }
        }
    }

    private func reviewSymbol(worktreeIsGone: Bool) -> String {
        if job.state.isPublishing { return "arrow.up.circle" }
        if worktreeIsGone { return "folder.badge.questionmark" }
        return JobState.awaitingReview.symbolName
    }

    /// Why this cannot become a pull request now, when it cannot (§7.1).
    @ViewBuilder
    private var gitHubLine: some View {
        if let access = model.jobCenter.gitHubAccess, access != .ready {
            GitHubAccessLine(
                access: access, issueTarget: job.kind.target,
                openIssue: { issueRequest = CorrectionSheetRequest(.issue, target: $0) },
                checkAgain: { Task { await model.jobCenter.refreshGitHubAccess() } })
        }
    }

    @ViewBuilder
    private var outcomeBanner: some View {
        switch job.state {
        case .opened(let url):
            // Opened by the agent itself, bypassing review: the tripwire's
            // notice, in orange (§5.5).
            if let notice = job.notice {
                banner(.orange, "exclamationmark.triangle.fill", notice.text) {
                    pullRequestLink(url)
                }
            } else {
                banner(.green, "checkmark.circle.fill",
                       "A draft pull request is open. CCwiki never marks one ready for review.") {
                    pullRequestLink(url)
                }
            }
        case .aborted(let reason):
            banner(.orange, "hand.raised.fill",
                   "The agent declined the job rather than guess. That is a good outcome.") {
                Text(reason)
                    .font(Theme.Fonts.log)
                    .textSelection(.enabled)
                    .lineLimit(8)
                reviewAnywayButton
            }
        case .failed(let message):
            banner(.red, "xmark.octagon.fill", message) {
                HStack(spacing: Theme.medium) {
                    if FileManager.default.fileExists(
                        atPath: job.worktree.path(percentEncoded: false)) {
                        Button("Reveal Worktree in Terminal") {
                            model.openInTerminal(job.worktree)
                        }
                        .buttonStyle(.link)
                        .font(Theme.Fonts.meta)
                    }
                    reviewAnywayButton
                }
            }
        case .cancelled:
            if offersReviewAnyway {
                banner(.secondary, JobState.cancelled.symbolName,
                       "Cancelled. Its worktree and changes are kept.") {
                    reviewAnywayButton
                }
            }
        case .discarded:
            banner(.secondary, JobState.discarded.symbolName,
                   "Discarded. The transcript is kept.") {
                EmptyView()
            }
        case .queued, .preparing, .running, .awaitingReview, .publishing:
            EmptyView()
        }
    }

    /// A finished job's notice, under its banner: why Review Anyway did not
    /// go ahead, or what the tripwire found before the job ended. Drawn
    /// whether or not the banner is: a cancelled job whose worktree has
    /// gone has none. An opened job's banner says its own.
    @ViewBuilder
    private var outcomeNotice: some View {
        switch job.state {
        case .aborted, .failed, .cancelled:
            if let notice = job.notice {
                JobNoticeLine(notice: notice)
            }
        case .queued, .preparing, .running, .awaitingReview, .publishing, .opened, .discarded:
            EmptyView()
        }
    }

    private func pullRequestLink(_ url: URL) -> some View {
        Link(url.absoluteString, destination: url)
            .font(Theme.Fonts.meta)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Review Anyway, on an agent job that ended with changes in its
    /// worktree: a snapshot, then the review (§6.5).
    @ViewBuilder
    private var reviewAnywayButton: some View {
        if offersReviewAnyway {
            Button("Review Anyway") {
                let job = self.job
                Task { await model.jobCenter.reviewAnyway(job) }
            }
            .buttonStyle(.link)
            .font(Theme.Fonts.meta)
            .help("Show what the agent left in its worktree, and review it")
        }
    }

    private var offersReviewAnyway: Bool {
        JobReview.offersReviewAnyway(
            kind: job.kind.tag, state: job.state,
            worktreeExists: FileManager.default.fileExists(
                atPath: job.worktree.path(percentEncoded: false)),
            review: job.review)
    }

    private func banner<Content: View>(
        _ tint: Color, _ symbol: String, _ message: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.small) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text(message)
                    .font(Theme.Fonts.row)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.medium)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    private var metadataRow: some View {
        HStack(spacing: Theme.medium) {
            metadata("Branch", job.branch)
            if let submission = job.submission {
                if let source = submission.source {
                    metadata(source.label, source.canonicalURL)
                }
                if let pdf = submission.localPDF {
                    metadata("PDF", pdf.lastPathComponent)
                }
            } else if let target = job.kind.target {
                metadata("Page", target.repositoryPath)
            }
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.tight) {
            Text(label)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var preflightList: some View {
        VStack(alignment: .leading, spacing: Theme.tight) {
            ForEach(job.preflight) { finding in
                HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                    Image(systemName: finding.symbolName)
                        .font(.caption)
                        .foregroundStyle(finding.level == .info
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    Text(finding.title)
                        .font(Theme.Fonts.meta)
                    Text(finding.detail)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Actions

    private func edit(_ file: JobReview.EditableFile) {
        model.showEditor(
            EditorTarget(jobID: job.id, path: file.path), at: file.lines, using: openWindow)
    }

    private func requestDiscard() {
        let job = self.job
        Task { discardRequest = await DiscardRequest.prepare(for: job, in: model.jobCenter) }
    }

    /// Open Draft PR: asks first with warnings or in a Dev build, then
    /// approves. Read at the click, not when the button was drawn: an
    /// editor opened since may hold text it could not save, which the
    /// button had no way to see. The click then says why, never nothing.
    /// The review is read at the click too, and approved as it was then,
    /// so a refresh while the question is up cannot add a warning it did
    /// not count (§6.5 step 1).
    private func openDraftPR() {
        guard !isApproving else { return }
        let gate = JobReview.draftPR(for: job, privatePaths: privatePaths, model: model)
        guard gate.isEnabled else {
            draftPRRefusal = gate.disabledReason
            return
        }
        let shown = JobCenter.ShownReview(of: job)
        if let question = gate.confirmation {
            draftPRQuestion = DraftPRQuestion(question: question, shown: shown)
        } else {
            approve(shown)
        }
    }

    /// Every outcome but a pull request leaves the job in review, with a
    /// notice saying why (§6.5); the review is what to look at then.
    private func approve(_ shown: JobCenter.ShownReview) {
        guard !isApproving else { return }
        isApproving = true
        let job = self.job
        Task {
            let result = await model.jobCenter.approve(job, shown: shown)
            isApproving = false
            if case .opened = result { return }
            pane = .changes
        }
    }

    private func restore() {
        guard !isRestoring else { return }
        isRestoring = true
        let job = self.job
        Task {
            _ = await model.jobCenter.restoreWorktree(job)
            isRestoring = false
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptPane: some View {
        // Under review, the pre-flight findings are the transcript's.
        if isUnderReview && !job.preflight.isEmpty {
            preflightList
                .padding(.horizontal, Theme.large)
                .padding(.vertical, Theme.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            Divider()
        }
        transcript
    }

    /// The agent's work, one event per row.
    ///
    /// `claude --output-format stream-json` gives structure, so this is a
    /// readable log — "▸ Bash  npm run lint" — rather than a wall of JSON. The
    /// raw stream is on disk regardless.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(job.log) { entry in
                        row(entry).id(entry.id)
                    }
                    // A zero-height anchor is a more reliable scroll target
                    // than the last row, which changes identity as it arrives.
                    Color.clear.frame(height: 1).id(Self.tailAnchor)
                }
                .padding(Theme.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .onChange(of: job.log.count) { _, _ in
                guard followsTail else { return }
                // A hop, so the new row has been laid out before we scroll to
                // the anchor beneath it — otherwise the newest line lands
                // half-clipped behind the tail bar.
                Task { @MainActor in
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { tailBar }
        }
    }

    private static let tailAnchor = "ccwiki.transcript.tail"

    private var tailBar: some View {
        HStack {
            Toggle("Follow", isOn: $followsTail)
                .toggleStyle(.checkbox)
                .font(Theme.Fonts.meta)
            Spacer()
            if let outcome = job.outcome {
                Text("\(outcome.turns) turns")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text("\(job.log.count) events")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.medium)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func row(_ entry: JobLogEntry) -> some View {
        switch entry.role {
        case .system:
            logLine(entry.text, font: Theme.Fonts.log, color: .secondary)
        case .assistant:
            Text(entry.text)
                .font(Theme.Fonts.row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
        case .tool(let name):
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                Text(name)
                    .font(Theme.Fonts.badge)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .rect(cornerRadius: 3))
                Text(entry.text)
                    .font(Theme.Fonts.log)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .toolResult(let isError):
            logLine(entry.text, font: Theme.Fonts.log,
                    color: isError ? .red : .secondary)
                .padding(.leading, Theme.large)
        case .stderr:
            logLine(entry.text, font: Theme.Fonts.log, color: .secondary)
        case .error:
            logLine(entry.text, font: Theme.Fonts.log, color: .red)
        }
    }

    private func logLine(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Open Draft PR

/// Open Draft PR in the toolbar: prominent, disabled with its reason as its
/// help (§6.6). A view of its own, so typing in the pull request redraws
/// this button and not the whole job (SWIFTUI-RULES §6.3).
private struct OpenDraftPRButton: View {
    let job: Job
    let privatePaths: [String]
    let isApproving: Bool
    let open: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let gate = JobReview.draftPR(for: job, privatePaths: privatePaths, model: model)
        Button("Open Draft PR", action: open)
            .buttonStyle(.borderedProminent)
            .disabled(!gate.isEnabled || isApproving)
            .help(gate.disabledReason ?? JobReview.destination(model.publishTarget))
    }
}

/// The Jobs menu's Open Draft PR, published while a review is shown (§9).
private struct DraftPRCommand: View {
    let job: Job
    let privatePaths: [String]
    let isApproving: Bool
    let open: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let gate = JobReview.draftPR(for: job, privatePaths: privatePaths, model: model)
        Color.clear.focusedSceneValue(
            \.openDraftPRAction,
            JobCommandAction(isEnabled: gate.isEnabled && !isApproving) { open() })
    }
}

extension JobReview {
    /// The worktree of a job under review is gone, and Restore can bring
    /// its changes back: restored without it at launch, or deleted since,
    /// as clearing Caches by hand does (§4.3, §4.4). The review then offers
    /// Restore, as the banner's "no worktree" case says (§6.6).
    @MainActor
    static func isWorktreeGone(_ job: Job) -> Bool {
        if job.needsRestore { return true }
        guard job.state == .awaitingReview else { return false }
        return !FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false))
    }

    /// Open Draft PR for `job` as it is now.
    @MainActor
    static func draftPR(for job: Job, privatePaths: [String], model: AppModel) -> DraftPR {
        let request = job.pullRequest
        let gate = draftPR(
            state: job.state, needsRestore: isWorktreeGone(job), review: job.review,
            findings: job.findings, title: request.title,
            privateFindings: privateFindings(
                title: request.title, body: request.body, privatePaths: privatePaths),
            access: model.jobCenter.gitHubAccess, target: model.publishTarget)
        // Publishing would send the file on disk and close an editor whose
        // own version nobody has kept or dropped yet, losing it (§4.4).
        // Approve asks the same again once it has saved the editors.
        guard gate.isEnabled, let path = unsettledEditor(of: job, in: model) else { return gate }
        return DraftPR(disabledReason: unsettledReason(path: path), confirmation: nil)
    }

    /// The file of `job` whose editor holds a version the disk does not: a
    /// conflict nobody has settled, or text a write failed to save. Nil
    /// when there is none.
    @MainActor
    static func unsettledEditor(of job: Job, in model: AppModel) -> String? {
        for (target, session) in model.editorSessions where target.jobID == job.id {
            if case .conflict = session.saveState { return target.path }
            if session.saveError != nil, session.hasUnsavedText { return target.path }
        }
        return nil
    }

    /// Why Open Draft PR waits for the editor of `path` (repository-relative).
    static func unsettledReason(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return "\(name) could not be saved. Settle it in its window first."
    }
}
