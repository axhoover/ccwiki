import AppKit
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
///
/// **One git queue per job.** Everything that runs git in a job's worktree
/// — a snapshot, Revert File, Restore, Approve, Discard — runs through one
/// serial chain for that job, so two `git add -A` never meet on
/// `index.lock` (§6.1). A refresh asked for while another waits joins it;
/// one asked for while another runs waits for a single follow-up. Approve,
/// Revert File, Restore and Discard wait for whatever is in flight. Before
/// Approve, Revert File, a refresh and Restore, every editor of the job is
/// saved (`flushEdits`), so nothing typed is left out of what git sees.
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

    /// The review as Open Draft PR's click saw it: the digest of the diff
    /// on screen, nil when none was, and its DiffGuard findings, which the
    /// question the click asks counted. Approve publishes only that, so a
    /// refresh that lands while the question is up cannot bring a warning
    /// nobody was asked about (§6.5 step 1).
    struct ShownReview: Sendable {
        let digest: String?
        let findings: [DiffFinding]

        @MainActor init(of job: Job) {
            digest = job.review?.digest
            findings = job.findings
        }
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
    /// Why an editor of the job holds text the disk does not, once saved:
    /// a conflict nobody has settled, or a write that failed. Nil when none
    /// does. Approve asks it after `flushEdits`. Set by `AppModel.init`.
    @ObservationIgnored var unsettledEdits: (@MainActor (Job) -> String?)?
    /// CCwiki changed these repository-relative paths in the job's worktree.
    @ObservationIgnored var onFilesChanged: (@MainActor (Job, [String]) -> Void)?
    /// The leftover worktrees were looked for again, with this result. Set
    /// by `AppModel.init`, which keeps the status bar's warning in step.
    @ObservationIgnored var onOrphanedWorktreesChanged: (@MainActor ([String]) -> Void)?

    /// The last link of each job's git queue, by job id.
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    /// A refresh that is queued and has not started, by job id: a refresh
    /// asked for meanwhile joins it rather than queueing another.
    @ObservationIgnored private var queuedRefreshes: [String: Task<Void, Never>] = [:]
    /// Jobs whose Approve has been pressed and not yet answered, so a second
    /// press while the editors save does nothing.
    @ObservationIgnored private var approving: Set<String> = []
    /// What each publish came to, from its task to `approve`.
    @ObservationIgnored private var publishResults: [String: ApproveResult] = [:]
    /// The question to GitHub in flight, which every caller shares.
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    /// The count the Dock badge shows.
    @ObservationIgnored private var badgeCount = 0
    /// Snapshots taken, by job id. For the tests of the queue.
    @ObservationIgnored private(set) var snapshotCounts: [String: Int] = [:]
    /// The branches of the jobs Clear Finished has dropped this launch.
    /// Their records are gone, and an agent still running must not take a
    /// push or a pull request CCwiki made for one of them for its own
    /// (§5.5). A launch is long enough: no agent outlives one.
    @ObservationIgnored private var clearedBranches: Set<String> = []

    /// Loads the job history synchronously.
    init(paths: AppPaths, environment: @escaping @MainActor () -> Environment) {
        self.paths = paths
        self.environment = environment
        loadJobHistory()
        // From the run loop's first turn, once the application exists, the
        // Dock shows how many jobs await review.
        Task { @MainActor [weak self] in self?.observeReviewCount() }
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

    /// The branch of every job but `jobID` that this launch knows of: those
    /// in Jobs, and those Clear Finished has dropped. With the records on
    /// disk, what the tripwire takes for CCwiki's own (§5.5).
    func otherJobBranches(excluding jobID: String) -> Set<String> {
        Set(jobs.filter { $0.id != jobID }.map(\.branch)).union(clearedBranches)
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
    /// keeps the answer (§7.1). Callers while one ask is in flight share it.
    /// Editing needs none of this; the editor and the review show the
    /// banner the answer gives, and Approve asks again.
    func refreshGitHubAccess() async {
        if let accessTask {
            await accessTask.value
            return
        }
        let environment = self.environment()
        let task = Task { @MainActor in
            self.gitHubAccess = await Publisher.gitHubAccess(
                tools: environment.tools, repository: environment.target.repository)
            // Cleared with the answer, before anyone waiting hears it, so one
            // who then asks again (`toolsDidChange`) is asked afresh.
            self.accessTask = nil
        }
        accessTask = task
        await task.value
    }

    /// Every tool has been looked for again (`AppModel.discoverTools`). A
    /// review shown before git was found has no snapshot, and an answer
    /// asked of GitHub before gh was found says gh is missing: both are
    /// asked again, the answer only if one was kept. Approve asks GitHub
    /// for itself, so this is for the banner and the button's help.
    func toolsDidChange() async {
        await refreshMissingReviews()
        if let accessTask { await accessTask.value }
        if gitHubAccess != nil { await refreshGitHubAccess() }
    }

    /// A snapshot for every review that has none, as showing it would take
    /// one: for reviews shown before git was found (§4.3). Called once git
    /// is found, before gh is, and from `toolsDidChange`.
    func refreshMissingReviews() async {
        for job in jobs where job.review == nil && job.canEdit {
            await refreshReview(job)
        }
    }

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

    /// Route b: an agent drafts the edit, in a worktree at the commit the
    /// reader rendered, and the job waits for review (§5.4).
    @discardableResult
    func startCorrection(_ request: CorrectionRequest) -> Job {
        let job = Job(kind: .correction(request), paths: paths)
        jobs.insert(job, at: 0)
        start(job)
        return job
    }

    /// Route a: a worktree at the target's commit, in review from its first
    /// second, which the editor writes into (§7.1). Local only: editing
    /// needs no network. On failure nothing is left behind, and the error
    /// says why.
    func beginEdit(_ target: CorrectionTarget) async -> Result<Job, JobError> {
        let environment = self.environment()
        guard let git = environment.git else {
            return .failure(JobError(
                "git was not found. Install the Command Line Tools, or set its path in Settings."))
        }
        if let refusal = CorrectionJobRunner.storeRefusal(paths.wikiStore) {
            return .failure(JobError(refusal))
        }

        let job = Job(kind: .edit(target), paths: paths)
        // The commit the reader rendered: the lines were read from it.
        guard let base = await git.resolveCommit(target.baseCommit, in: paths.clone) else {
            return .failure(JobError(
                "The commit the page was read at, \(target.baseCommit.prefix(12)), is not in the "
                + "wiki's clone. Sync (⌘R), then edit the page again."))
        }
        let branch = await git.availableBranchName(clone: paths.clone, preferred: job.branch)
        let created = await git.addWorktree(
            clone: paths.clone, at: job.worktree, branch: branch, baseRef: base) { _ in }
        guard created else {
            forgetFiles(of: job)
            return .failure(JobError(
                "git could not make a worktree for this edit at "
                + "\(job.worktree.path(percentEncoded: false))."))
        }

        job.setBaseCommit(base)
        job.setBranch(branch)
        job.pullRequest = PullRequestDraft.make(
            for: job.kind, handover: nil, siteURL: CorrectionJobRunner.siteURL(for: target))
        job.append(JobLogEntry(.system,
            "Editing \(target.repositoryPath) in a worktree at \(base.prefix(12)), on \(branch). "
            + "Nothing is sent until you open the pull request in Jobs."))
        jobs.insert(job, at: 0)
        job.setState(.awaitingReview)
        return .success(job)
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

    /// The job's review again: its editors saved, then a snapshot through
    /// its queue (§6.1). Only for a job awaiting review with its worktree.
    func refreshReview(_ job: Job) async {
        await flushEdits?(job)
        if let queued = queuedRefreshes[job.id] {
            await queued.value
            return
        }
        let refresh = enqueue(job) { @MainActor in
            // Started: from here on, a refresh asked for needs a run of its own.
            self.queuedRefreshes[job.id] = nil
            await self.takeSnapshot(job)
        }
        queuedRefreshes[job.id] = refresh
        await refresh.value
    }

    /// Revert File…: `path` (repository-relative) back to the job's base,
    /// a rename on both sides; its editors reload; a new snapshot (§6.5).
    func revert(_ path: String, in job: Job) async {
        await flushEdits?(job)
        await serially(job) { @MainActor in
            guard job.state == .awaitingReview, !job.needsRestore,
                  let base = job.baseCommit, let git = self.environment().git
            else { return }
            var reverted = [path]
            if let oldPath = job.review?.files.first(where: { $0.path == path })?.oldPath {
                reverted.append(oldPath)
            }
            var failed: [String] = []
            for each in reverted {
                if await !git.revertPath(each, to: base, in: job.worktree) { failed.append(each) }
            }
            if failed.isEmpty {
                job.append(JobLogEntry(.system,
                    "Reverted \(path) to the version at \(base.prefix(12))."))
            } else {
                let message = "git could not revert \(failed.joined(separator: " and "))."
                job.append(JobLogEntry(.error, message))
                job.setNotice(JobNotice(tone: .failure, text: message))
            }
            self.onFilesChanged?(job, reverted)
            await self.takeSnapshot(job)
        }
    }

    /// Review Anyway: a failed, aborted or cancelled agent job whose
    /// worktree holds changes goes to review (§4.1, §6.5). A quit cancels
    /// an agent that has not finished and keeps its worktree, so its work
    /// can still reach review. A record from before 0.3 has no base; it is
    /// computed once, as where HEAD left the default branch, and recorded.
    func reviewAnyway(_ job: Job) async {
        guard job.kind.tag != .edit, Self.mayReviewAnyway(job.state) else { return }
        // A job cancelled a moment ago may still be winding down, and its
        // runner sets the state last. It finishes first, or it would set
        // `cancelled` again over the review.
        await job.task?.value
        await serially(job) { @MainActor in
            guard Self.mayReviewAnyway(job.state) else { return }
            let environment = self.environment()
            guard let git = environment.git else { return }
            guard FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false))
            else {
                Self.refuseReview(job, .failure, Self.worktreeGone)
                return
            }
            // Before any git there: a record from before 0.3 asks for its
            // base through the worktree's `.git`, which the agent could have
            // pointed at a repository of its choosing (§5.1).
            guard GitService.isWorktree(job.worktree, of: self.paths.clone) else {
                Self.refuseReview(job, .failure, GitService.redirectedWorktree)
                return
            }
            if job.baseCommit == nil {
                let branch = await git.defaultBranch(in: self.paths.clone)
                guard let base = await git.mergeBase("HEAD", "origin/\(branch)", in: job.worktree)
                else {
                    Self.refuseReview(job, .failure, Self.unknownBase)
                    return
                }
                job.setBaseCommit(base)
                job.append(JobLogEntry(.system,
                    "This job started before CCwiki recorded bases; its base is \(base.prefix(12)), "
                    + "where it left origin/\(branch)."))
            }
            guard let review = await ReviewSnapshotter(git: git).review(
                of: job, clone: self.paths.clone, privatePaths: environment.privatePaths)
            else {
                Self.refuseReview(job, .failure, self.snapshotFailure(job))
                return
            }
            self.snapshotCounts[job.id, default: 0] += 1
            guard !review.snapshot.isEmpty else {
                // Kept, empty, so Review Anyway is no longer offered for it.
                job.setReview(review.snapshot, findings: review.findings)
                Self.refuseReview(job, .warning, Self.nothingToReview)
                return
            }
            if job.pullRequest.title.isEmpty {
                let handover = Handover.pullRequestText(in: job.worktree)
                job.pullRequest = PullRequestDraft.make(
                    for: job.kind,
                    handover: handover.flatMap { PullRequestDraft.parse(handover: $0) },
                    siteURL: job.kind.target.flatMap { CorrectionJobRunner.siteURL(for: $0) })
            }
            job.append(JobLogEntry(.system,
                "Review Anyway: the worktree's changes await review. CCwiki has pushed nothing."))
            // An earlier refusal is out of date now; a tripwire's notice
            // belongs in the review, and stays.
            if Self.isReviewRefusal(job.notice) { job.setNotice(nil) }
            job.setReview(review.snapshot, findings: review.findings)
            job.setState(.awaitingReview)
        }
        // Whatever Left Behind showed of this worktree goes with the state.
        await refreshOrphanedWorktrees()
    }

    /// Why Review Anyway did not go ahead: in the transcript, which the
    /// job's pane shows whatever its state, and as its notice, unless the
    /// notice is the tripwire's. That one says the agent pushed or opened
    /// something itself, belongs in the review, and stays.
    private static func refuseReview(_ job: Job, _ tone: JobNotice.Tone, _ message: String) {
        job.append(JobLogEntry(tone == .failure ? .error : .system, message))
        guard job.notice == nil || isReviewRefusal(job.notice) else { return }
        job.setNotice(JobNotice(tone: tone, text: message))
    }

    nonisolated static let worktreeGone = "The worktree is gone, so there is nothing to review."
    nonisolated static let unknownBase = "CCwiki could not tell which commit this job started from."
    nonisolated static let cannotCompare =
        "git could not compare the worktree with the commit it started from."
    nonisolated static let nothingToReview = "The worktree holds no changes to review."

    /// Whether `notice` is one of `refuseReview`'s, which a Review Anyway
    /// that goes ahead clears.
    nonisolated static func isReviewRefusal(_ notice: JobNotice?) -> Bool {
        guard let text = notice?.text else { return false }
        return [worktreeGone, unknownBase, cannotCompare, nothingToReview,
                GitService.redirectedWorktree].contains(text)
    }

    /// The states an agent job can be brought to review from, when its
    /// worktree holds changes: every way it can end without a review but
    /// opened and discarded.
    nonisolated static func mayReviewAnyway(_ state: JobState) -> Bool {
        switch state {
        case .failed, .aborted, .cancelled: true
        default: false
        }
    }

    /// Restore: the worktree made again at the base, on the job's own
    /// branch, and the saved patch applied to it and its index (§4.4).
    ///
    /// It is built aside, in the job's scratch directory, and moved to
    /// where the job keeps its worktree only once the patch has applied. A
    /// Restore cut short by a quit or a crash therefore leaves no worktree
    /// there, and the next launch offers Restore again. A worktree there
    /// without its changes would be taken for the job's own, and its first
    /// snapshot would overwrite the saved patch, the only copy of them. A
    /// patch that does not apply leaves things as they were.
    func restoreWorktree(_ job: Job) async -> Bool {
        await flushEdits?(job)
        return await serially(job) { @MainActor () -> Bool in
            guard job.state == .awaitingReview, let base = job.baseCommit,
                  let git = self.environment().git
            else { return false }
            let destination = job.worktree.path(percentEncoded: false)
            guard !FileManager.default.fileExists(atPath: destination) else {
                if job.needsRestore {
                    job.setNotice(JobNotice(tone: .failure, text:
                        "Something is already at \(destination), so CCwiki did not restore over "
                        + "it. Your changes are still saved in \(job.patchFile.lastPathComponent)."))
                }
                return false
            }
            // Gone since the launch: nothing to apply, so git is not asked.
            // An empty patch is there, and applies as nothing.
            guard FileManager.default.fileExists(atPath: job.patchFile.path(percentEncoded: false))
            else {
                job.setNotice(JobNotice(tone: .failure, text:
                    "The saved changes are missing: \(job.patchFile.lastPathComponent) is not in "
                    + "Application Support."))
                return false
            }

            let staging = Self.restoringWorktree(scratch: job.scratch)
            // Whatever an interrupted Restore left there, branch and all.
            await self.removeRestoring(at: staging, git: git)
            job.append(JobLogEntry(.system,
                "Restoring the worktree from \(job.patchFile.lastPathComponent)."))
            guard await git.addWorktree(
                clone: self.paths.clone, at: staging, resettingBranch: job.branch, to: base)
            else {
                await self.removeRestoring(at: staging, git: git)
                job.setNotice(JobNotice(tone: .failure, text:
                    "git could not make the worktree again. The changes are still saved in "
                    + "\(job.patchFile.lastPathComponent)."))
                return false
            }
            guard await git.applyPatch(job.patchFile, in: staging) else {
                await self.removeRestoring(at: staging, git: git)
                job.setNotice(JobNotice(tone: .failure, text:
                    "The saved changes did not apply to the commit the job started from. They are "
                    + "still in \(job.patchFile.lastPathComponent)."))
                return false
            }
            guard await git.moveWorktree(clone: self.paths.clone, from: staging, to: job.worktree)
            else {
                await self.removeRestoring(at: staging, git: git)
                job.setNotice(JobNotice(tone: .failure, text:
                    "git could not move the restored worktree into place. The changes are still "
                    + "saved in \(job.patchFile.lastPathComponent)."))
                return false
            }
            job.setNeedsRestore(false)
            job.setNotice(nil)
            job.append(JobLogEntry(.system, "Restored. Your changes are back in the worktree."))
            await self.takeSnapshot(job)
            self.onFilesChanged?(job, job.review?.files.map(\.path) ?? [])
            return true
        }
    }

    /// Open Draft PR (§6.5): the editors saved, the queue waited for, then
    /// `Publisher` from "Checking…" to the pull request. Every outcome but
    /// `opened` returns the job to review with a notice; nothing is left
    /// half done. Acts only from review, and a second press while the first
    /// is answered does nothing.
    ///
    /// What is approved is `shown`, the review as the click saw it. A
    /// snapshot that finishes while the question is up, the editors save
    /// or the queue drains (a refresh after a save, a sync's, or the first
    /// one of a job just shown) was never seen, so it is compared with, not
    /// taken as, the reviewed one.
    ///
    /// An editor whose text did not reach the disk, whether the review's
    /// button knew it or the save Approve ran found it, stops it: publishing
    /// would send the file without that text, and close the editor (§4.4).
    func approve(_ job: Job, shown: ShownReview) async -> ApproveResult {
        guard job.state == .awaitingReview, !job.needsRestore, !approving.contains(job.id) else {
            return .refused(job.state.isPublishing || approving.contains(job.id)
                ? "The pull request is already being opened."
                : "Only a job awaiting review can be published.")
        }
        approving.insert(job.id)
        defer { approving.remove(job.id) }

        await flushEdits?(job)
        if job.state == .awaitingReview, let unsettled = unsettledEdits?(job) {
            return settle(job, .refused(unsettled))
        }
        return await serially(job) { @MainActor () -> ApproveResult in
            await self.publish(job, shown: shown.digest, findings: shown.findings)
        }
    }

    /// Approve of the review on screen now, as a click that asks nothing
    /// approves it.
    func approve(_ job: Job) async -> ApproveResult {
        await approve(job, shown: ShownReview(of: job))
    }

    /// `shown` is the digest of the diff on screen when Open Draft PR was
    /// pressed, or nil when none was, and `findings` that review's
    /// DiffGuard findings: a warning they lack refuses (§6.5 step 1).
    private func publish(
        _ job: Job, shown: String?, findings: [DiffFinding]
    ) async -> ApproveResult {
        guard job.state == .awaitingReview else {
            return .refused("Only a job awaiting review can be published.")
        }
        let environment = self.environment()
        guard let git = environment.git else {
            return settle(job, .refused("git was not found. Nothing was sent."))
        }
        guard let digest = shown else {
            // No diff was on screen: show it before anything is sent.
            await takeSnapshot(job)
            return settle(job, .changedSinceReview)
        }

        job.setNotice(nil)
        // Read-only editors from here; the record, with the pull request as
        // edited, is written with the state.
        job.setState(.publishing("Checking…"))
        let publisher = Publisher(
            paths: paths, tools: environment.tools, git: git, target: environment.target,
            privatePaths: environment.privatePaths)
        let provenance = Self.provenance(for: job, environment: environment)
        let id = job.id
        // The job's task, so a quit can interrupt the push or the gh call
        // (`Job.interruptPublishing`).
        let publishing = Task { @MainActor in
            let outcome = await publisher.publish(
                job, reviewed: digest, findings: findings, provenance: provenance)
            self.publishResults[id] = outcome
        }
        job.task = publishing
        await publishing.value
        if job.task == publishing { job.task = nil }
        let result = publishResults.removeValue(forKey: id) ?? .refused(Job.publishingInterrupted)

        if publishing.isCancelled {
            // A quit or a relaunch: `interruptPublishing` has returned the
            // job to review, and said so.
            if job.state.isPublishing { job.setState(.awaitingReview) }
            return .refused(Job.publishingInterrupted)
        }
        return settle(job, result)
    }

    /// The job as an Approve leaves it: opened, or back in review with a
    /// notice, orange for what was refused and red for what failed.
    private func settle(_ job: Job, _ result: ApproveResult) -> ApproveResult {
        switch result {
        case .opened(let url):
            if job.state != .opened(url: url) { job.setState(.opened(url: url)) }
            return result
        case .changedSinceReview:
            job.append(JobLogEntry(.system, Self.changedSinceReview))
            job.setNotice(JobNotice(tone: .warning, text: Self.changedSinceReview))
        case .refused(let message):
            job.append(JobLogEntry(.system, message))
            job.setNotice(JobNotice(tone: .warning, text: message))
        case .failed(let message):
            job.append(JobLogEntry(.error, message))
            job.setNotice(JobNotice(tone: .failure, text: message))
        }
        job.setState(.awaitingReview)
        return result
    }

    nonisolated static let changedSinceReview = "The files changed since you reviewed them. "
        + "Check the new diff, then open the pull request."

    /// A line in the job's transcript from outside the runners and the job
    /// center, which alone change a job (§4.2): an editor saying what became
    /// of text it could not save.
    func log(_ entry: JobLogEntry, in job: Job) {
        job.append(entry)
    }

    /// What the footer of the pull request says about where it came from.
    static func provenance(for job: Job, environment: Environment) -> PullRequestDraft.Provenance {
        let route: String = switch job.kind {
        case .edit:
            "edited by hand"
        case .correction(let request):
            request.model.isEmpty ? "drafted by claude" : "drafted by claude (\(request.model))"
        case .ingestion:
            "ingested by claude"
        }
        return PullRequestDraft.Provenance(
            appVersion: environment.appVersion, isDevBuild: environment.target.isDevBuild,
            route: route)
    }

    /// The open PR on the job's branch, if any: for Discard's dialog. Asked
    /// of GitHub only when the job has pushed, or tried to.
    func openPullRequest(for job: Job) async -> URL? {
        guard job.pushedCommit != nil || job.pushingCommit != nil else { return nil }
        let environment = self.environment()
        guard let gh = environment.tools.path(for: .gh) else { return nil }
        let arguments = Publisher.listArguments(target: environment.target, branch: job.branch)
        let childEnvironment = environment.tools.childEnvironment()
        let result = await Subprocess.withDeadline(GitHubAuth.deadline) {
            await Subprocess.run(executable: gh, arguments: arguments, environment: childEnvironment)
        }
        guard let result, result.succeeded else { return nil }
        return Publisher.pullRequest(createdAfter: .distantPast, in: result.stdout)
    }

    /// Discard…, once confirmed: the worktree, the scratch directory and
    /// the local branch go, through the job's queue, and the job is
    /// discarded. The transcript stays, and the patch until Clear Finished.
    /// Nothing on GitHub is touched: a pushed branch and an open pull
    /// request stay where they are.
    func discard(_ job: Job) async {
        guard job.state == .awaitingReview else { return }
        await serially(job) { @MainActor in
            guard job.state == .awaitingReview else { return }
            await self.removeWorktree(of: job)
            job.append(JobLogEntry(.system, job.pushedCommit == nil
                ? "Discarded. The transcript is kept."
                : "Discarded. \(job.branch) stays on GitHub; CCwiki never deletes anything there."))
            job.setState(.discarded)
        }
    }

    /// Closing an untouched edit's last editor: when git confirms its
    /// worktree holds no change, the job goes and leaves nothing behind,
    /// with no dialog (§7.5). Judged on the worktree now, not on the last
    /// snapshot, so a failed or stale snapshot never discards an edit.
    ///
    /// An edit that has pushed, or tried to, is not untouched whatever its
    /// worktree holds now: its branch may be on GitHub, and only its record
    /// says so. It stays in Jobs, where Discard… names the branch.
    func discardIfUntouched(_ job: Job) async {
        guard job.kind.tag == .edit, job.state == .awaitingReview,
              job.pushedCommit == nil, job.pushingCommit == nil
        else { return }
        await serially(job) { @MainActor in
            guard job.kind.tag == .edit, job.state == .awaitingReview, !job.needsRestore,
                  job.pushedCommit == nil, job.pushingCommit == nil,
                  let base = job.baseCommit, let git = self.environment().git,
                  FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)),
                  await git.stageAll(in: job.worktree),
                  let diff = await git.stagedDiff(in: job.worktree, base: base),
                  diff.nameStatus.isEmpty
            else { return }
            await self.removeWorktree(of: job)
            job.setState(.discarded)
            self.jobs.removeAll { $0 === job }
            self.forgetFiles(of: job)
            self.queuedRefreshes[job.id] = nil
        }
    }

    // MARK: The queue

    /// Runs `work` once everything queued before it for `job` has finished,
    /// and returns its result. The work runs in a task of its own, so a
    /// caller that goes away (a view's task, cancelled) does not stop git
    /// half way.
    @discardableResult
    private func serially<T: Sendable>(
        _ job: Job, _ work: @escaping @MainActor @Sendable () async -> T
    ) async -> T {
        await enqueue(job, work).value
    }

    /// `work`, as the new last link of the job's queue.
    private func enqueue<T: Sendable>(
        _ job: Job, _ work: @escaping @MainActor @Sendable () async -> T
    ) -> Task<T, Never> {
        let previous = queues[job.id]
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        queues[job.id] = Task { @MainActor in _ = await task.value }
        return task
    }

    /// The job's snapshot and DiffGuard's findings, as its review. Taken
    /// only for a job awaiting review that has its worktree and its base;
    /// always from inside the job's queue.
    private func takeSnapshot(_ job: Job) async {
        guard job.state == .awaitingReview, !job.needsRestore, job.baseCommit != nil,
              FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false))
        else { return }
        let environment = self.environment()
        guard let git = environment.git else { return }
        snapshotCounts[job.id, default: 0] += 1
        guard let review = await ReviewSnapshotter(git: git).review(
            of: job, clone: paths.clone, privatePaths: environment.privatePaths)
        else {
            job.append(JobLogEntry(.error, snapshotFailure(job)))
            return
        }
        job.setReview(review.snapshot, findings: review.findings)
    }

    /// Why `ReviewSnapshotter.review` gave nothing for `job`: its worktree's
    /// `.git` leads somewhere other than the clone, so no git ran there, or
    /// git could not answer.
    private func snapshotFailure(_ job: Job) -> String {
        GitService.isWorktree(job.worktree, of: paths.clone)
            ? Self.cannotCompare
            : GitService.redirectedWorktree
    }

    /// Where Restore builds a job's worktree before moving it into place:
    /// in its scratch directory, outside `worktrees/`, so it is never taken
    /// for a stray while it is built.
    nonisolated static func restoringWorktree(scratch: URL) -> URL {
        scratch.appending(path: "restoring")
    }

    /// The worktree Restore was building at `staging`, and its directory,
    /// if they are there. It has the job's branch checked out, which no
    /// other worktree can then take, nor can the branch be deleted.
    private func removeRestoring(at staging: URL, git: GitService) async {
        guard FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) else {
            return
        }
        _ = await git.removeWorktree(clone: paths.clone, at: staging, force: true)
        try? FileManager.default.removeItem(at: staging)
    }

    /// The job's worktree, scratch directory and local branch, and anything
    /// an interrupted Restore left. Never a branch on GitHub.
    private func removeWorktree(of job: Job) async {
        if let git = environment().git {
            await removeRestoring(at: Self.restoringWorktree(scratch: job.scratch), git: git)
            let removed = await git.removeWorktree(
                clone: paths.clone, at: job.worktree, force: true)
            if !removed, FileManager.default.fileExists(
                atPath: job.worktree.path(percentEncoded: false)) {
                job.append(JobLogEntry(.error,
                    "Could not remove the worktree at \(job.worktree.path(percentEncoded: false))."))
            }
            _ = await git.deleteBranch(job.branch, in: paths.clone)
        }
        try? FileManager.default.removeItem(at: job.scratch)
    }

    /// The record, transcript and patch of a job that is to leave nothing
    /// behind.
    private func forgetFiles(of job: Job) {
        for file in [job.recordFile, job.logFile, job.patchFile, job.scratch] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: The Dock

    /// The Dock badge follows `reviewCount`, as Mail's follows unread mail:
    /// observed, and observed again after each change.
    private func observeReviewCount() {
        let count = withObservationTracking {
            reviewCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeReviewCount() }
        }
        guard count != badgeCount else { return }
        badgeCount = count
        NSApp?.dockTile.badgeLabel = Self.badgeLabel(for: count)
    }

    /// "2", or nothing at all at zero.
    nonisolated static func badgeLabel(for count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

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
    /// A worktree one of them kept for Review Anyway is a stray from now on.
    func clearFinishedJobs() {
        for job in jobs where job.state.isTerminal {
            // Its branch may be on GitHub, pushed while an agent runs.
            clearedBranches.insert(job.branch)
            try? FileManager.default.removeItem(at: job.recordFile)
            try? FileManager.default.removeItem(at: job.patchFile)
            queues[job.id] = nil
            queuedRefreshes[job.id] = nil
        }
        jobs.removeAll { $0.state.isTerminal }
        Task { @MainActor in await self.refreshOrphanedWorktrees() }
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
    /// call this, since that signal would reach other tests' git too. A
    /// review's pull request, as edited, is written now rather than in a
    /// second.
    func stopJobs() {
        for job in jobs {
            if job.state.isCancellable {
                job.cancel()
            } else if job.state.isPublishing {
                job.interruptPublishing()
            } else if job.state == .awaitingReview {
                job.saveRecord()
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
        let paths = self.paths
        let id = job.id
        job.otherJobBranches = { [weak self] in self?.otherJobBranches(excluding: id) ?? [] }
        job.task = Task { @MainActor in
            switch job.kind {
            case .ingestion:
                await IngestJobRunner(
                    paths: paths, tools: environment.tools, git: git, index: environment.index,
                    target: environment.target
                ).run(job)
            case .correction(let request):
                await CorrectionJobRunner(
                    paths: paths, tools: environment.tools, git: git, model: request.model,
                    target: environment.target
                ).run(job)
            case .edit:
                return
            }
            // In a fresh task: a cancelled job's task would kill the git
            // these need. The review is taken as the job enters it (§6.1),
            // and the branch and worktree bookkeeping moved, so what is
            // known about strays is refreshed.
            await Task { @MainActor in
                if job.state == .awaitingReview { await self.refreshReview(job) }
                await self.refreshOrphanedWorktrees()
            }.value
        }
    }

    // MARK: Leftover worktrees

    /// Look for strays. Every job that is not finished owns its worktree, a
    /// review included, and so does one Review Anyway can still bring to
    /// review, until Clear Finished drops it: none is ever offered for
    /// pruning (§4.3).
    func refreshOrphanedWorktrees() async {
        let environment = self.environment()
        guard let git = environment.git else { return }
        let runner = IngestJobRunner(
            paths: paths, tools: environment.tools, git: git, index: environment.index,
            target: environment.target)
        let known = Set(jobs.filter { Self.ownsWorktree($0.state) }.map(\.id))
        orphanedWorktrees = await runner.orphanedWorktrees(knownJobIDs: known).map(\.path)
        onOrphanedWorktreesChanged?(orphanedWorktrees)
    }

    /// Whether a job in `state` still owns its worktree: it is not finished,
    /// or Review Anyway may yet take what it holds to review.
    nonisolated static func ownsWorktree(_ state: JobState) -> Bool {
        !state.isTerminal || mayReviewAnyway(state)
    }

    /// Prune…, from Left Behind. Never the worktree of a job that owns it,
    /// whatever a list drawn before the job moved on still shows.
    func pruneOrphan(_ path: String) {
        let id = (path as NSString).lastPathComponent
        guard !jobs.contains(where: { $0.id == id && Self.ownsWorktree($0.state) }) else { return }
        let environment = self.environment()
        guard let git = environment.git else { return }
        let runner = IngestJobRunner(
            paths: paths, tools: environment.tools, git: git, index: environment.index,
            target: environment.target)
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
