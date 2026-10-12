import Foundation
import Observation

/// Every job, and everything that moves one along: ingestion, the
/// corrections a reader starts, their review, and opening the pull request
/// (plans/corrections.md §4, §6, §11.6).
///
/// The job section of `AppModel`, moved so the pipeline, the review and the
/// editor have one owner. It reads what it needs of the app through
/// `environment`, fresh at each call (SWIFTUI-RULES §3.5): the tools, git
/// and the wiki change under it.
///
/// History loads in `init`, synchronously: a few small JSON files, no tools
/// needed. The model is the app's `@State`, made before SwiftUI restores a
/// window, so a restored editor or review finds its job (§4.3).
@MainActor
@Observable
final class JobCenter {

    /// What the job center reads of the app at each call.
    struct Environment: Sendable {
        let tools: ToolLocator
        let git: GitService?
        let index: WikiIndex?
        let relations: RelationsManifest
        let labels: RelationLabels
        let appVersion: String
        let correctionModel: String
        let target: PublishTarget
        let privatePaths: [String]
    }

    let paths: AppPaths

    /// Newest first.
    private(set) var jobs: [Job] = []
    /// Worktrees git still knows about that no live job owns — the residue of
    /// a crash or a force-quit mid-job.
    private(set) var orphanedWorktrees: [String] = []
    /// Whether a correction can become a pull request now. Nil until asked.
    private(set) var gitHubAccess: GitHubAccess?

    /// Read fresh at each call (SWIFTUI-RULES §3.5).
    @ObservationIgnored var environment: @MainActor () -> Environment
    /// Saves every open editor of the job. Set by `AppModel.init`.
    @ObservationIgnored var flushEdits: (@MainActor (Job) async -> Void)?
    /// CCwiki changed these repository-relative paths in the job's worktree.
    @ObservationIgnored var onFilesChanged: (@MainActor (Job, [String]) -> Void)?
    /// The leftover worktrees were looked for again, with this result. Set
    /// by `AppModel.init`, which keeps the status bar's warning in step.
    @ObservationIgnored var onOrphanedWorktreesChanged: (@MainActor ([String]) -> Void)?

    /// Loads the job history synchronously.
    init(paths: AppPaths, environment: @escaping @MainActor () -> Environment) {
        self.paths = paths
        self.environment = environment
        loadJobHistory()
    }

    // MARK: Counts

    /// Preparing, running or publishing: a process is running.
    var activeJobCount: Int { jobs.count { $0.state.isActive } }

    var publishingCount: Int { jobs.count { $0.state.isPublishing } }

    /// Awaiting review, less the edits nobody has touched yet. The Dock
    /// badge, and the reader's "2 awaiting review".
    var reviewCount: Int {
        jobs.count { $0.state == .awaitingReview && !$0.isUntouchedEdit }
    }

    var hasFinishedJobs: Bool { jobs.contains { $0.state.isTerminal } }

    func job(id: String) -> Job? {
        jobs.first { $0.id == id }
    }

    /// Jobs that are not finished whose target is this page, or whose last
    /// snapshot changes it, newest first. `pagePath` is relative to
    /// `content/`.
    func jobs(touching pagePath: String) -> [Job] {
        let repositoryPath = "content/" + pagePath
        return self.jobs
            .filter { job in
                guard !job.state.isTerminal else { return false }
                if job.kind.target?.pagePath == pagePath { return true }
                return job.review?.files.contains {
                    $0.path == repositoryPath || $0.oldPath == repositoryPath
                } ?? false
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Asks `gh` whether it is signed in and may push to the target, and
    /// keeps the answer. Phase 0: not yet.
    func refreshGitHubAccess() async {}

    // MARK: Starting

    @discardableResult
    func submitIngestion(source: IngestSubmission.Source?, pdf: URL?, notes: String) -> Job {
        let submission = IngestSubmission(
            kind: pdf != nil ? .pdf : .url,
            source: source,
            localPDF: pdf,
            notes: notes,
            submittedAt: Date())

        let job = Job(kind: .ingestion(submission), paths: paths, createdAt: submission.submittedAt)
        jobs.insert(job, at: 0)
        start(job)
        return job
    }

    /// Route b: an agent drafts the edit. Phase 0: the job is created and
    /// fails at once, saying so.
    @discardableResult
    func startCorrection(_ request: CorrectionRequest) -> Job {
        let job = Job(kind: .correction(request), paths: paths)
        jobs.insert(job, at: 0)
        job.append(JobLogEntry(.error, Self.notBuilt.message))
        job.setState(.failed(Self.notBuilt.message))
        return job
    }

    /// Route a: a worktree at the target's commit, in review from its first
    /// second, which the editor writes into (§7.1).
    func beginEdit(_ target: CorrectionTarget) async -> Result<Job, JobError> {
        .failure(Self.notBuilt)
    }

    /// The same submission or request again, as a new job.
    func runAgain(_ job: Job) {
        switch job.kind {
        case .ingestion(let submission):
            submitIngestion(
                source: submission.source,
                pdf: submission.localPDF,
                notes: submission.notes)
        case .correction(let request):
            startCorrection(request)
        case .edit:
            break
        }
    }

    // MARK: Review

    func refreshReview(_ job: Job) async {}

    func revert(_ path: String, in job: Job) async {}

    func reviewAnyway(_ job: Job) async {}

    func restoreWorktree(_ job: Job) async -> Bool { false }

    func approve(_ job: Job) async -> ApproveResult {
        .refused(Self.notBuilt.message)
    }

    /// The open PR on the job's branch, if any: for Discard's dialog.
    func openPullRequest(for job: Job) async -> URL? { nil }

    func discard(_ job: Job) async {}

    /// Closing an untouched edit's last editor.
    func discardIfUntouched(_ job: Job) async {}

    /// What every stub of the review says until its track lands.
    private static let notBuilt = JobError("Not built yet.")

    // MARK: History

    /// Jobs from earlier launches, from the records beside their
    /// transcripts, each brought back as §4.3's table says.
    private func loadJobHistory() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: paths.logs, includingPropertiesForKeys: nil)
        else { return }
        let decoder = JSONDecoder()
        let known = Set(jobs.map(\.id))
        var restored: [Job] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(JobRecord.self, from: data),
                  !known.contains(record.id)
            else { continue }
            restored.append(Job(
                restoring: record, paths: paths,
                worktreeExists: manager.fileExists(
                    atPath: paths.worktree(forJob: record.id).path(percentEncoded: false)),
                patchExists: manager.fileExists(
                    atPath: paths.patch(forJob: record.id).path(percentEncoded: false))))
        }
        restored.sort { $0.createdAt > $1.createdAt }
        jobs.append(contentsOf: restored)
    }

    /// Forget the finished jobs. Their transcripts stay on disk; the records
    /// that bring them back at launch go, and so do their saved patches.
    func clearFinishedJobs() {
        for job in jobs where job.state.isTerminal {
            try? FileManager.default.removeItem(at: job.recordFile)
            try? FileManager.default.removeItem(at: job.patchFile)
        }
        jobs.removeAll { $0.state.isTerminal }
    }

    // MARK: Stopping

    /// Stop what is running, at a quit, a relaunch or a hand-over to another
    /// copy, so no agent outlives the window it was reporting to. Work that
    /// has not reached review is cancelled; a publish is interrupted and goes
    /// back to review; a review is left as it is (§4.1). Then every child
    /// process is signalled.
    func cancelActiveJobs() {
        stopJobs()
        Subprocess.terminateAll()
    }

    /// `cancelActiveJobs` without the signal to every child process: tests
    /// call this, since that signal would reach other tests' git too.
    func stopJobs() {
        for job in jobs {
            if job.state.isCancellable {
                job.cancel()
            } else if job.state.isPublishing {
                job.interruptPublishing()
            }
        }
    }

    // MARK: Running

    private func start(_ job: Job) {
        let environment = self.environment()
        guard let git = environment.git else {
            job.setState(.failed("git was not found."))
            return
        }
        let runner = IngestJobRunner(
            paths: paths, tools: environment.tools, git: git, index: environment.index)
        job.task = Task { @MainActor in
            await runner.run(job)
            // A job that changed the wiki has changed nothing locally — the PR
            // lives on GitHub — but the branch and worktree bookkeeping moved,
            // so refresh what we know about strays. In a fresh task: a
            // cancelled job's task would kill the `git worktree list` it
            // needs and report no strays at all.
            await Task { @MainActor in await self.refreshOrphanedWorktrees() }.value
        }
    }

    // MARK: Leftover worktrees

    /// Look for strays. Every job that is not finished owns its worktree, a
    /// review included, so one is never offered for pruning (§4.3).
    func refreshOrphanedWorktrees() async {
        let environment = self.environment()
        guard let git = environment.git else { return }
        let runner = IngestJobRunner(
            paths: paths, tools: environment.tools, git: git, index: environment.index)
        let known = Set(jobs.filter { !$0.state.isTerminal }.map(\.id))
        orphanedWorktrees = await runner.orphanedWorktrees(knownJobIDs: known).map(\.path)
        onOrphanedWorktreesChanged?(orphanedWorktrees)
    }

    func pruneOrphan(_ path: String) {
        let environment = self.environment()
        guard let git = environment.git else { return }
        let runner = IngestJobRunner(
            paths: paths, tools: environment.tools, git: git, index: environment.index)
        Task { @MainActor in
            await runner.prune(worktreeAt: path)
            await refreshOrphanedWorktrees()
        }
    }
}

/// What Approve came to (plans/corrections.md §6.5). Every outcome but
/// `opened` returns the job to review, with a notice.
enum ApproveResult: Sendable, Equatable {
    case opened(URL)
    /// Nothing sent; the review now shows the new diff.
    case changedSinceReview
    /// Nothing sent.
    case refused(String)
    /// A step failed; the message says what was already sent.
    case failed(String)
}

/// Why a job could not do what was asked, in words for the person.
struct JobError: Error, Sendable, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension JobError: LocalizedError {
    var errorDescription: String? { message }
}
