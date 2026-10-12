import AppKit
import SwiftUI

/// A job's review: the Changes pane of the Jobs window (plans/corrections.md
/// §6.3, §6.6). What DiffGuard flagged, the diff, rendered as the reader
/// draws a page or as source, and below them the pull request CCwiki would
/// open, which can be edited.
///
/// The pane is a `VSplitView`: the findings and the diff above, the pull
/// request below, never shorter than `Theme.reviewFormMinHeight`, so the
/// form never covers the diff. The toolbar's Edit…, Discard… and Open Draft
/// PR are the job's, in `JobDetailView`.
struct ReviewView: View {
    let job: Job

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// A finding to scroll Source mode to.
    @State private var sourceScroll: SourceDiffScroll?
    @State private var showsAllFindings = false
    @State private var revertRequest: RevertRequest?
    @State private var isRestoring = false
    /// The local paths that must not be sent, read when the job is shown.
    @State private var privatePaths: [String] = []
    /// The job a `rawHTML` finding has already switched to Source, once.
    @State private var sourceChosenFor: String?

    var body: some View {
        content
            .task(id: job.id) { await jobShown() }
            .onChange(of: RawHTMLKey(job: job), initial: true) { _, key in
                // Rendered may hide raw HTML, so such a job opens in Source;
                // once, so Rendered stays one click away.
                guard key.hasRawHTML, sourceChosenFor != key.jobID else { return }
                sourceChosenFor = key.jobID
                model.reviewShowsSource = true
            }
            .alert(
                revertRequest?.question.title ?? "",
                isPresented: Binding(
                    get: { revertRequest != nil }, set: { if !$0 { revertRequest = nil } }),
                presenting: revertRequest
            ) { request in
                Button("Revert File", role: .destructive) { revert(request.path) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.question.message ?? "")
            }
    }

    // MARK: What the pane shows

    @ViewBuilder
    private var content: some View {
        if job.needsRestore {
            ContentUnavailableView {
                Label("The Worktree Is Gone", systemImage: "folder.badge.questionmark")
            } description: {
                Text("CCwiki kept your changes. Restore puts them back in a new worktree, "
                    + "and the review returns.")
            } actions: {
                Button("Restore") { restore() }
                    .disabled(isRestoring)
            }
        } else if let review = job.review, !review.isEmpty {
            changes(review)
        } else if job.kind.tag == .edit {
            ContentUnavailableView {
                Label("No Changes Yet", systemImage: "square.and.pencil")
            } description: {
                Text("Edit the page in its window; changes appear here as you save.")
            } actions: {
                Button("Open Editor") { openEditor() }
                    .disabled(!job.canEdit)
            }
        } else if job.review == nil {
            ContentUnavailableView {
                Label {
                    Text("Reading the Changes")
                } icon: {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            ContentUnavailableView(
                "No Changes", systemImage: "tray",
                description: Text("The worktree holds nothing to review."))
        }
    }

    private func changes(_ review: ReviewSnapshot) -> some View {
        VSplitView {
            VStack(spacing: 0) {
                findingsStrip
                Divider()
                diffBar(review)
                Divider()
                diff(review)
            }
            .frame(minHeight: ReviewMetrics.diffMinHeight)
            .layoutPriority(1)

            PullRequestForm(job: job, privatePaths: privatePaths)
                .frame(minHeight: Theme.reviewFormMinHeight, idealHeight: ReviewMetrics.formIdealHeight)
        }
        // The payload again whenever what it is built from changes: the
        // snapshot, its findings, or the wiki the links resolve against.
        .onChange(of: RenderKey(job: job, generation: model.libraryGeneration), initial: true) {
            renderReview()
        }
        // The readers' text size, which every web view follows (§17).
        .onChange(of: model.pageZoom) { _, zoom in
            model.reviewWeb.setPageZoom(zoom)
        }
    }

    // MARK: Findings

    private var findingsStrip: some View {
        let findings = job.findings
        let shown = showsAllFindings ? findings : Array(findings.prefix(ReviewMetrics.findingsShown))
        return VStack(alignment: .leading, spacing: 0) {
            if findings.isEmpty {
                Label("DiffGuard flagged nothing.", systemImage: "checkmark.shield")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.medium)
                    .padding(.vertical, Theme.small)
            } else {
                ForEach(shown) { finding in
                    FindingRow(
                        finding: finding,
                        canRevert: finding.severity == .blocking && !finding.path.isEmpty
                            && job.canEdit,
                        onShow: { show(finding) },
                        onRevert: { askToRevert(finding.path) },
                        onOpenInTerminal: { model.openInTerminal(job.worktree) })
                }
                if findings.count > ReviewMetrics.findingsShown {
                    let hidden = findings.count - ReviewMetrics.findingsShown
                    let title: String = showsAllFindings ? "Show Fewer" : "Show \(hidden) More"
                    Button(title) {
                        showsAllFindings.toggle()
                    }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
                    .padding(.horizontal, Theme.medium)
                    .padding(.vertical, Theme.tight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Clicking a finding scrolls the diff to it.
    private func show(_ finding: DiffFinding) {
        if model.reviewShowsSource {
            sourceScroll = SourceDiffScroll(path: finding.path, lines: finding.lines)
        } else {
            // `scrollToReviewEntry` takes a finding's id as it is.
            model.reviewWeb.scrollToReviewEntry(finding.id)
        }
    }

    // MARK: The diff

    private func diffBar(_ review: ReviewSnapshot) -> some View {
        HStack(spacing: Theme.small) {
            Text(JobReview.changeSummary(review))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.small)
            Picker("Show the changes", selection: Binding(
                get: { model.reviewShowsSource },
                set: { model.reviewShowsSource = $0 })
            ) {
                Text("Rendered").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Rendered shows the page as the reader draws it; Source shows the lines")
        }
        .padding(.horizontal, Theme.medium)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func diff(_ review: ReviewSnapshot) -> some View {
        if model.reviewShowsSource {
            SourceDiffView(snapshot: review, scrollRequest: sourceScroll)
        } else {
            WebPane(controller: model.reviewWeb)
        }
    }

    /// Sends the payload to the review's web view, and points the view's
    /// callbacks at this job: it re-renders after a WebContent restart, and
    /// its links open in the reader, by the explorer's rule (§6.3).
    private func renderReview() {
        let model = self.model
        let job = self.job
        let openWindow = self.openWindow
        let web = model.reviewWeb
        web.onReady = { [weak model, weak job] in
            guard let model, let job, let json = model.reviewPayload(for: job) else { return }
            model.reviewWeb.renderReview(json: json)
        }
        web.onNavigate = { [weak model] destination, disposition in
            guard let model else { return }
            ReviewLinks.follow(destination, disposition, model: model, openWindow: openWindow)
        }
        web.setPageZoom(model.pageZoom)
        guard let json = model.reviewPayload(for: job) else { return }
        web.renderReview(json: json)
    }

    // MARK: Actions

    /// When the job is first shown: its snapshot if it has none yet, and
    /// whether GitHub can be reached if nobody has asked (§4.3, §7.1).
    private func jobShown() async {
        privatePaths = model.jobCenter.environment().privatePaths
        if job.review == nil, job.canEdit {
            await model.jobCenter.refreshReview(job)
        }
        if model.jobCenter.gitHubAccess == nil {
            await model.jobCenter.refreshGitHubAccess()
        }
    }

    private func askToRevert(_ path: String) {
        let isNew = job.review?.files.first(where: { $0.path == path })?.status == .added
        revertRequest = RevertRequest(
            path: path, question: JobReview.revertQuestion(path: path, isNew: isNew))
    }

    private func revert(_ path: String) {
        let job = self.job
        Task { await model.jobCenter.revert(path, in: job) }
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

    private func openEditor() {
        guard let file = JobReview.editableFiles(kind: job.kind, review: job.review).first else { return }
        model.showEditor(
            EditorTarget(jobID: job.id, path: file.path), at: file.lines, using: openWindow)
    }

    // MARK: Keys

    /// What the rendered review is built from.
    private struct RenderKey: Equatable {
        let jobID: String
        let digest: String?
        let paths: [String]
        let findings: [String]
        let generation: Int

        @MainActor init(job: Job, generation: Int) {
            jobID = job.id
            digest = job.review?.digest
            paths = job.review?.files.map(\.path) ?? []
            findings = job.findings.map(\.id)
            self.generation = generation
        }
    }

    private struct RawHTMLKey: Equatable {
        let jobID: String
        let hasRawHTML: Bool

        @MainActor init(job: Job) {
            jobID = job.id
            hasRawHTML = job.findings.contains { $0.rule == .rawHTML }
        }
    }

    private struct RevertRequest: Identifiable {
        let id = UUID()
        let path: String
        let question: JobReview.Question
    }
}

/// Layout metrics of the review, the editor and the Jobs window's rows.
enum ReviewMetrics {
    /// The findings and the diff, at their shortest.
    static let diffMinHeight: CGFloat = 220
    /// The pull request form as the pane first opens.
    static let formIdealHeight: CGFloat = 230
    /// Findings listed before Show More.
    static let findingsShown = 4
    /// A status line under an editor, as under a reader.
    static let statusBarHeight: CGFloat = 26
}

// MARK: - One finding

/// A row of the findings strip: the severity's glyph, DiffGuard's message,
/// where it is, and what can be done about it (§6.6). A click shows it in
/// the diff.
private struct FindingRow: View {
    let finding: DiffFinding
    let canRevert: Bool
    let onShow: () -> Void
    let onRevert: () -> Void
    let onOpenInTerminal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            FindingGlyph(severity: finding.severity)
            VStack(alignment: .leading, spacing: 1) {
                Text(JobReview.inlineMarkdown(finding.message))
                    .font(Theme.Fonts.row)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(JobReview.location(of: finding))
                    .font(Theme.Fonts.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.small)
            if canRevert {
                Button("Revert File…", action: onRevert)
                    .controlSize(.small)
            }
            if finding.rule == .derivedFilesStale {
                Button("Open in Terminal", action: onOpenInTerminal)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.medium)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(perform: onShow)
        .help("Show in the diff")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show in the Diff", onShow)
    }
}

/// A finding's severity: red for blocking, orange for a warning, secondary
/// for a note, each with a glyph of its own, so they differ by more than
/// colour (§6.6).
struct FindingGlyph: View {
    let severity: DiffFinding.Severity

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(style)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch severity {
        case .blocking: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
    }

    private var style: AnyShapeStyle {
        switch severity {
        case .blocking: AnyShapeStyle(Color.red)
        case .warning: AnyShapeStyle(Color.orange)
        case .note: AnyShapeStyle(.secondary)
        }
    }

    private var label: String {
        switch severity {
        case .blocking: "Blocks the pull request"
        case .warning: "Warning"
        case .note: "Note"
        }
    }
}

// MARK: - The pull request

/// The pull request CCwiki would open: its title, its body as Markdown
/// source, and where it goes (§6.4, §6.6). Edited in place; read-only while
/// the job is being published. A local path or a token in either field
/// underlines the body in red and says what it found.
private struct PullRequestForm: View {
    @Bindable var job: Job
    let privatePaths: [String]

    @Environment(AppModel.self) private var model

    var body: some View {
        let found = JobReview.privateFindings(
            title: job.pullRequest.title, body: job.pullRequest.body, privatePaths: privatePaths)
        VStack(alignment: .leading, spacing: Theme.small) {
            Text("Pull Request")
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(.secondary)

            TextField("Title", text: $job.pullRequest.title)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Fonts.row)

            TextEditor(text: $job.pullRequest.body)
                .font(Theme.Fonts.code)
                .scrollContentBackground(.hidden)
                .padding(Theme.tight)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    // Mounted always and faded, never inserted.
                    Rectangle()
                        .fill(Color.red)
                        .frame(height: 2)
                        .opacity(found.isEmpty ? 0 : 1)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Body")

            if let first = found.first {
                Label {
                    Text("This contains a local path or a token, which must not reach GitHub: \(first)")
                        .lineLimit(2)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(.red)
            }

            Text(JobReview.destination(model.publishTarget))
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Theme.medium)
        .disabled(!job.canEdit)
    }
}

// MARK: - GitHub, and notices

/// The line the editor and the review show while a change cannot become a
/// pull request (§7.1), with what can be done instead: an issue, when gh
/// is missing or cannot push, and asking again.
struct GitHubAccessLine: View {
    let access: GitHubAccess
    /// The page an issue would be about. Nil offers none.
    let issueTarget: CorrectionTarget?
    let openIssue: (CorrectionTarget) -> Void
    let checkAgain: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            // Being offline is not a fault: the reader works without a
            // network, and so does editing (design-system §4b).
            if access == .offline {
                Image(systemName: "wifi.slash").foregroundStyle(.tertiary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(access.banner ?? "")
                .font(Theme.Fonts.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.small)
            if JobReview.offersIssue(for: access), let issueTarget {
                Button("Open an Issue…") { openIssue(issueTarget) }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
                    .fixedSize()
            }
            Button("Check Again", action: checkAgain)
                .buttonStyle(.link)
                .font(Theme.Fonts.meta)
                .fixedSize()
        }
    }
}

/// What the last publish said, or what the tripwire found (§5.5): orange
/// or red, under the review's banner.
struct JobNoticeLine: View {
    let notice: JobNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            switch notice.tone {
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failure:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Text(notice.text)
                .font(Theme.Fonts.meta)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Discard

/// Discard…, asked first (§6.5): what goes, and what CCwiki leaves on
/// GitHub. The question asks GitHub about an open pull request when the job
/// has pushed or tried to.
struct DiscardRequest: Identifiable {
    let id = UUID()
    let jobID: String
    let question: JobReview.Question

    @MainActor
    static func prepare(for job: Job, in center: JobCenter) async -> DiscardRequest {
        var openPullRequest: URL?
        if job.pushingCommit != nil || job.pushedCommit != nil {
            openPullRequest = await center.openPullRequest(for: job)
        }
        return DiscardRequest(
            jobID: job.id,
            question: JobReview.discardQuestion(
                kind: job.kind.tag, branch: job.branch, isPushed: job.pushedCommit != nil,
                openPullRequest: openPullRequest))
    }
}

private struct DiscardConfirmation: ViewModifier {
    @Binding var request: DiscardRequest?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            request?.question.title ?? "",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { request in
            Button("Discard", role: .destructive) { discard(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.question.message ?? "")
        }
    }

    private func discard(_ request: DiscardRequest) {
        guard let job = model.jobCenter.job(id: request.jobID) else { return }
        Task { await model.jobCenter.discard(job) }
    }
}

extension View {
    /// Asks before discarding the job `request` names, and discards it.
    func discardConfirmation(_ request: Binding<DiscardRequest?>) -> some View {
        modifier(DiscardConfirmation(request: request))
    }
}

// MARK: - Links

/// Where a link in the review or an editor's preview goes (§6.3, §17): on
/// cryptology.city when asked, otherwise in the reader, by the explorer's
/// rule. The page renders in the active reader without taking it forward;
/// with no reader open, one opens first.
@MainActor
enum ReviewLinks {
    static func follow(
        _ destination: CCwikiURL.Destination, _ disposition: LinkDisposition,
        model: AppModel, openWindow: OpenWindowAction
    ) {
        if disposition == .onSite {
            if let url = siteURL(of: destination, model: model) { NSWorkspace.shared.open(url) }
            return
        }
        switch destination {
        case .page, .folder:
            if model.mainWindowCount == 0 {
                openWindow(id: CCwikiApp.mainWindowID, value: ReaderWindow())
            }
            model.navigate(to: destination)
        case .asset:
            model.navigate(to: destination)
        case .shell:
            break
        }
    }

    private static func siteURL(of destination: CCwikiURL.Destination, model: AppModel) -> URL? {
        switch destination {
        case .page(let path, let anchor):
            guard let page = model.index?.pages[path] else { return nil }
            return AppModel.siteURL(slug: page.slug, anchor: anchor)
        case .folder(let slug):
            return AppModel.siteURL(slug: slug + "/")
        case .asset, .shell:
            return nil
        }
    }
}

// MARK: - The decisions, pure

/// What the review and the editor say and allow, decided apart from the
/// views (plans/corrections.md §6.5, §6.6, §7). Pure, and tested.
enum JobReview {

    /// A question asked before something that cannot be taken back.
    struct Question: Equatable, Sendable {
        let title: String
        let message: String?
    }

    /// Whether Open Draft PR can run now, and what it asks first.
    struct DraftPR: Equatable, Sendable {
        /// Why it cannot run; its help. Nil when it can.
        let disabledReason: String?
        /// Asked before it runs; nil to run at once.
        let confirmation: Question?

        var isEnabled: Bool { disabledReason == nil }
    }

    /// A file the editor can open from a review: Edit… and Open Editor.
    struct EditableFile: Identifiable, Hashable, Sendable {
        /// Repository-relative.
        let path: String
        let lines: LineRange?

        var id: String { path }
        /// What a menu calls it: the path under `content/`, as unique as
        /// the path and shorter.
        var title: String { ReviewPayload.contentPath(path) ?? path }
    }

    // MARK: The banner

    /// The banner over a job under review (§6.6).
    static func banner(
        state: JobState, needsRestore: Bool, isUntouchedEdit: Bool,
        pushedCommit: String?, branch: String
    ) -> String {
        if case .publishing(let step) = state { return step }
        if needsRestore { return "The worktree is gone. CCwiki kept your changes." }
        if isUntouchedEdit { return "Editing. Nothing has been pushed." }
        if pushedCommit != nil {
            return "Awaiting your review. The branch \(branch) is on GitHub; "
                + "no pull request is open yet."
        }
        return "Awaiting your review. Nothing has been pushed."
    }

    /// The banner's second line: the branch, then the page and the passage,
    /// or the paper's source.
    static func metadata(kind: JobKind, branch: String) -> String {
        var parts = [branch]
        switch kind {
        case .ingestion(let submission):
            if let source = submission.source {
                parts.append(source.canonicalURL)
            } else if let pdf = submission.localPDF {
                parts.append(pdf.lastPathComponent)
            }
        case .correction(let request):
            parts += [request.target.repositoryPath, request.target.summary]
        case .edit(let target):
            parts += [target.repositoryPath, target.summary]
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Open Draft PR

    /// Open Draft PR is disabled by a blocking finding, a local path or
    /// token in the title or body, or GitHub not ready; its help says
    /// which. With warnings, or in a Dev build, it asks first (§6.6).
    static func draftPR(
        state: JobState, needsRestore: Bool, review: ReviewSnapshot?,
        findings: [DiffFinding], title: String, privateFindings: [String],
        access: GitHubAccess?, target: PublishTarget
    ) -> DraftPR {
        func disabled(_ reason: String) -> DraftPR { DraftPR(disabledReason: reason, confirmation: nil) }

        if state.isPublishing { return disabled("CCwiki is opening the pull request.") }
        guard state == .awaitingReview else {
            return disabled("Only a job awaiting review can become a pull request.")
        }
        if needsRestore { return disabled("Restore the worktree first.") }
        guard let review else { return disabled("CCwiki is still reading the changes.") }
        if review.isEmpty { return disabled("There are no changes to open yet.") }
        let blocking = findings.filter { $0.severity == .blocking }.count
        if blocking > 0 {
            return disabled(blocking == 1
                ? "DiffGuard blocks one change. Revert it, or make it outside CCwiki."
                : "DiffGuard blocks \(blocking) changes. Revert them, or make them outside CCwiki.")
        }
        if let first = privateFindings.first {
            return disabled("The title or body contains a local path or a token (\(first)). Remove it first.")
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return disabled("The pull request needs a title.")
        }
        guard let access else { return disabled("CCwiki is checking whether GitHub can be reached.") }
        if let banner = access.banner { return disabled(banner) }

        let warnings = findings.filter { $0.severity == .warning }.count
        let onRepository = "on \(target.repository)"
        let devLine = target.isDevBuild ? "\(onRepository) · from CCwiki Dev" : nil
        if warnings > 0 {
            let changes = warnings == 1 ? "1 flagged change" : "\(warnings) flagged changes"
            return DraftPR(disabledReason: nil, confirmation: Question(
                title: "Open a draft pull request with \(changes)?",
                message: devLine ?? "It opens \(onRepository)."))
        }
        if target.isDevBuild {
            return DraftPR(disabledReason: nil, confirmation: Question(
                title: "Open a draft pull request \(onRepository)?", message: devLine))
        }
        return DraftPR(disabledReason: nil, confirmation: nil)
    }

    /// Where the pull request goes, said before anything is sent (§10).
    static func destination(_ target: PublishTarget) -> String {
        "Opens a draft pull request on \(target.repository)"
            + (target.isDevBuild ? " · from CCwiki Dev" : "")
    }

    /// Each local path or token in the pull request's title and body.
    static func privateFindings(title: String, body: String, privatePaths: [String]) -> [String] {
        PrivateText.findings(in: title + "\n" + body, privatePaths: privatePaths)
    }

    // MARK: Questions

    /// Discard…, per kind, with what CCwiki leaves on GitHub (§6.5).
    static func discardQuestion(
        kind: JobKind.Tag, branch: String, isPushed: Bool, openPullRequest: URL?
    ) -> Question {
        var message: String
        switch kind {
        case .correction:
            message = "Its worktree and changes are deleted. The transcript is kept."
        case .edit:
            message = "Your changes are deleted."
        case .ingestion:
            message = "Its worktree and changes are deleted. The transcript is kept."
        }
        if isPushed {
            message += " The branch \(branch) is already on GitHub; CCwiki leaves it there."
        }
        if let openPullRequest {
            message += " An open pull request exists: \(openPullRequest.absoluteString). "
                + "CCwiki leaves it open."
        }
        let noun = switch kind {
        case .correction: "correction"
        case .edit: "edit"
        case .ingestion: "ingestion"
        }
        return Question(title: "Discard this \(noun)?", message: message)
    }

    /// Revert File…, in the review and the editor (§6.5).
    static func revertQuestion(path: String, isNew: Bool) -> Question {
        let name = (path as NSString).lastPathComponent
        return Question(
            title: "Revert \(name) to the version the job started from?",
            message: isNew
                ? "The job added this file, so reverting deletes it."
                : "The changes this job made to it are deleted.")
    }

    // MARK: What can be done

    /// The files Edit… offers: the page a correction or an edit is about,
    /// at its passage, then every other file the snapshot changes, at its
    /// first change. Never a deleted or binary file.
    static func editableFiles(kind: JobKind, review: ReviewSnapshot?) -> [EditableFile] {
        let changed = review?.files ?? []
        var files: [EditableFile] = []
        if let target = kind.target {
            let deleted = changed.contains { $0.path == target.repositoryPath && $0.status == .deleted }
            if !deleted { files.append(EditableFile(path: target.repositoryPath, lines: target.lines)) }
        }
        for file in changed where file.status != .deleted && !file.isBinary {
            guard !files.contains(where: { $0.path == file.path }) else { continue }
            files.append(EditableFile(path: file.path, lines: firstChange(in: file)))
        }
        return files
    }

    /// The first lines a file's hunks add, 1-based; the line a removal
    /// left when they only remove.
    static func firstChange(in file: ChangedFile) -> LineRange? {
        guard let hunk = file.hunks.first else { return nil }
        let first = hunk.new.lowerBound + 1
        return LineRange(first: max(first, 1), last: max(hunk.new.upperBound, first))
    }

    /// Review Anyway: an agent job that ended without a review, whose
    /// worktree is still there and, as far as anyone knows, holds changes
    /// (§5.5, §6.5).
    static func offersReviewAnyway(
        kind: JobKind.Tag, state: JobState, worktreeExists: Bool, review: ReviewSnapshot?
    ) -> Bool {
        guard kind != .edit, worktreeExists else { return false }
        switch state {
        case .failed, .cancelled, .aborted: return !(review?.isEmpty ?? false)
        default: return false
        }
    }

    /// An issue is the way out when gh is missing or cannot push (§7.1).
    static func offersIssue(for access: GitHubAccess) -> Bool {
        switch access {
        case .ghMissing, .cannotPush: true
        case .ready, .offline, .notSignedIn: false
        }
    }

    // MARK: Words

    /// "2 files changed · +12 −3".
    static func changeSummary(_ review: ReviewSnapshot) -> String {
        let added = review.files.reduce(0) { $0 + $1.addedLines }
        let removed = review.files.reduce(0) { $0 + $1.removedLines }
        let files = review.files.count == 1 ? "1 file changed" : "\(review.files.count) files changed"
        return "\(files) · +\(added) \u{2212}\(removed)"
    }

    /// "content/Primitives/x.md · lines 42–44".
    static func location(of finding: DiffFinding) -> String {
        guard let lines = finding.lines else { return finding.path }
        return "\(finding.path) · \(lines.label)"
    }

    /// DiffGuard's messages carry inline code; shown as is otherwise.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
