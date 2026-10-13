import Foundation

/// Opens a job's pull request, once a person has approved its changes
/// (plans/corrections.md §6.5). The only code in CCwiki that pushes, and
/// the only code that runs `gh pr create`.
///
/// ```
/// 1. Checking…            snapshot again: the digest must be the reviewed one;
///                         DiffGuard, with no warning the review did not show;
///                         the title and body; git's identity; GitHub
/// 2. Committing…          git reset --soft <base>; git commit --no-verify
/// 3. Pushing <branch>…    pushingCommit persisted, then
///                         git push --force-with-lease=refs/heads/<branch>:<pushedCommit or empty>
///                         a refused lease asks GitHub where the branch is (leaseRecovery)
/// 4. Opening the pull request…
///                         gh pr list --head <branch>: edit an open one, else
///                         gh pr create --draft, then confirm with gh pr list
/// 5. The job is opened(url); its worktree, scratch and local branch go
/// ```
///
/// Each step sets `publishing(step)` and is written to the transcript. A
/// pull request is always a draft: never ready for review, never merged,
/// never set to merge itself. Nothing is ever deleted on GitHub.
///
/// The caller, `JobCenter.approve`, has saved every editor of the job and
/// waited for its git queue. Every outcome but `opened` returns the job to
/// review there, with a notice; this never leaves a job terminal with its
/// work stranded.
@MainActor
struct Publisher {

    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    let target: PublishTarget
    /// The local paths no title, body or added line may contain
    /// (`PrivateText`, §6.4).
    var privatePaths: [String] = []
    /// `CCWIKI_PUBLISH_DRY_RUN=1`: stop after committing, and log the push
    /// and the `gh` commands instead of running them (§6.5).
    var isDryRun = ProcessInfo.processInfo.environment["CCWIKI_PUBLISH_DRY_RUN"] == "1"

    /// How long one `gh` call may take. Generous: a slow network is not a
    /// failure, and the next Approve checks GitHub before doing anything
    /// twice.
    nonisolated static let ghDeadline: Duration = .seconds(90)
    /// And one push, which carries the whole change.
    nonisolated static let pushDeadline: Duration = .seconds(180)

    /// `digest` and `findings` are the review on screen when Open Draft PR
    /// was pressed; nil `findings` takes the job's as this starts.
    func publish(
        _ job: Job, reviewed digest: String, findings: [DiffFinding]? = nil,
        provenance: PullRequestDraft.Provenance
    ) async -> ApproveResult {
        if let stop = await check(job, reviewed: digest, findings: findings) { return stop }

        guard let committed = await self.commit(job, version: provenance.appVersion) else {
            return .failed("git could not commit the changes. Nothing was sent.")
        }
        if Task.isCancelled { return .refused(Job.publishingInterrupted) }

        if isDryRun {
            logDryRun(job, provenance: provenance)
            return .refused("Dry run: committed locally, nothing pushed.")
        }

        switch await push(job, commit: committed) {
        case .pushed:
            break
        case .refused(let message):
            return .refused(message)
        case .failed(let message):
            return .failed(message)
        }
        if Task.isCancelled { return .refused(Job.publishingInterrupted) }

        let body = job.pullRequest.bodyForGitHub(jobID: job.id, provenance: provenance)
        let opened: URL
        switch await openPullRequest(job, body: body) {
        case .success(let url):
            opened = url
        case .failure(let error):
            return .failed(error.message)
        }

        await finish(job, url: opened)
        return .opened(opened)
    }

    // MARK: 1. Checking

    /// Why the job cannot be published as it stands, or nil to go on. The
    /// snapshot taken here becomes the job's review either way, so a
    /// changed diff is the one shown when this returns.
    ///
    /// A warning that `findings` (the review that was on screen; nil for
    /// the job's as this starts) did not have refuses too, though the diff
    /// is the same: `changedUpstream` follows `origin/<default>`, which a
    /// sync moves. Open Draft PR asks first about warnings (§6.6), and
    /// it never asked about this one.
    func check(_ job: Job, reviewed digest: String, findings: [DiffFinding]? = nil) async
        -> ApproveResult? {
        let seen = Set((findings ?? job.findings).filter { $0.severity == .warning }.map(\.id))
        step(job, "Checking…")
        let snapshotter = ReviewSnapshotter(git: git)
        guard let review = await snapshotter.review(
            of: job, clone: paths.clone, privatePaths: privatePaths)
        else {
            return .failed(GitService.isWorktree(job.worktree, of: paths.clone)
                ? "CCwiki could not read the changes in the worktree. Nothing was sent."
                : GitService.redirectedWorktree + " Nothing was sent.")
        }
        job.setReview(review.snapshot, findings: review.findings)

        if review.snapshot.digest != digest { return .changedSinceReview }
        if review.snapshot.isEmpty {
            return .refused("There are no changes to open a pull request with.")
        }
        if let blocking = review.findings.first(where: { $0.severity == .blocking }) {
            return .refused("DiffGuard blocks this change: \(blocking.message)")
        }
        if let warning = review.findings.first(where: {
            $0.severity == .warning && !seen.contains($0.id)
        }) {
            return .refused(Self.newWarning(warning))
        }

        let draft = job.pullRequest
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .refused("The pull request needs a title.")
        }
        let leaks = PrivateText.findings(
            in: draft.title + "\n" + draft.body, privatePaths: privatePaths)
        if let leak = leaks.first {
            return .refused("The title or body contains a local path or a token: \(leak). "
                + "Remove it, then open the pull request.")
        }

        if await git.identity(in: job.worktree) == nil {
            return .refused(Self.identityMissing)
        }

        let access = await Self.gitHubAccess(tools: tools, repository: target.repository)
        switch access {
        case .ready:
            return nil
        case .offline:
            return .refused("Offline. Nothing was sent; open the pull request when you are connected.")
        default:
            return .refused(access.banner ?? "GitHub cannot be reached.")
        }
    }

    /// A warning the review on screen did not have. The review shows it
    /// now, so the next Open Draft PR asks about it.
    nonisolated static func newWarning(_ finding: DiffFinding) -> String {
        let name = (finding.path as NSString).lastPathComponent
        return "DiffGuard has a new warning on \(name): \(finding.message) "
            + "Check it, then open the pull request."
    }

    nonisolated static let identityMissing = "Set your git name and email first: "
        + "git config --global user.name “Your Name”, and "
        + "git config --global user.email you@example.com."

    /// Whether `gh` is there, signed in, and may push to `repository`
    /// (§7.1): asked afresh, never from a cache.
    static func gitHubAccess(tools: ToolLocator, repository: String) async -> GitHubAccess {
        let ghPresent = tools.path(for: .gh) != nil
        let signedIn = ghPresent ? await GitHubAuth.signedIn(tools: tools) : nil
        let canPush = signedIn == true
            ? await GitHubAuth.canPush(tools: tools, repository: repository)
            : nil
        return GitHubAccess.classify(
            ghPresent: ghPresent, signedIn: signedIn, canPush: canPush, repository: repository)
    }

    // MARK: 2. Committing

    /// One commit on the base of exactly what is staged, authored by the
    /// user's own git identity. Whatever the agent committed collapses into
    /// it, and no hook runs to change the files after they were reviewed.
    func commit(_ job: Job, version: String) async -> String? {
        guard let base = job.baseCommit else { return nil }
        step(job, "Committing…")
        let message = Self.commitMessage(
            title: job.pullRequest.title, version: version, jobID: job.id)
        let commit = await git.commitStaged(in: job.worktree, base: base, message: message)
        if let commit {
            job.append(JobLogEntry(.system, "Committed \(commit.prefix(12)) on \(base.prefix(12))."))
        }
        return commit
    }

    // MARK: 3. Pushing

    enum PushOutcome: Sendable, Equatable {
        case pushed
        /// Nothing was sent.
        case refused(String)
        case failed(String)
    }

    /// Pushes `commit` to the job's branch, leasing on the last push it
    /// confirmed, or on absence before the first. The commit is persisted
    /// as `pushingCommit` before anything is sent, so a reply lost to a
    /// crash or a quit is recognised next time; a confirmed push is
    /// persisted as `pushedCommit`.
    ///
    /// A refused lease means the branch on GitHub is not where this job
    /// left it. GitHub is asked where it is, and `leaseRecovery` decides:
    /// adopt it as ours and retry once, take the next free name and retry
    /// once, or refuse to overwrite someone else's commits.
    func push(_ job: Job, commit: String) async -> PushOutcome {
        let remote = target.pushURL
        step(job, "Pushing \(job.branch)…")
        job.setPushingCommit(commit)

        var expecting = job.pushedCommit
        var result = await sendPush(job, remote: remote, expecting: expecting)
        if result.succeeded { return confirmed(job, commit: commit) }
        if Task.isCancelled { return .refused(Job.publishingInterrupted) }
        guard GitService.leaseWasRefused(result.output) else {
            return .failed(Self.pushFailure(job.branch, output: result.output))
        }

        job.append(JobLogEntry(.system,
            "\(job.branch) on GitHub is not where CCwiki left it. Asking GitHub where it is."))
        let tip: String?
        switch await git.remoteTip(of: job.branch, remote: remote, in: job.worktree) {
        case .unknown:
            return .refused("GitHub could not be asked where \(job.branch) is. "
                + "Nothing was sent; open the pull request again when you are connected.")
        case .absent:
            tip = nil
        case .at(let found):
            tip = found
        }
        let reflog = await git.reflog(of: job.branch, in: job.worktree)
        switch Self.leaseRecovery(
            remoteTip: tip, pushing: job.pushingCommit, pushed: job.pushedCommit, reflog: reflog) {
        case .retry(let expected):
            if let expected, expected != job.pushedCommit {
                job.append(JobLogEntry(.system,
                    "\(job.branch) is at \(expected.prefix(12)) on GitHub, which CCwiki pushed."))
            }
            expecting = expected
        case .rename:
            guard let renamed = await nextFreeBranch(job, remote: remote) else {
                return .refused("\(job.branch) was taken on GitHub, and CCwiki could not find "
                    + "another name for this job's branch. Nothing was sent.")
            }
            let taken = job.branch
            guard await git.renameBranch(to: renamed, in: job.worktree) else {
                return .failed("\(taken) was taken on GitHub, and git could not rename this "
                    + "job's branch to \(renamed). Nothing was sent.")
            }
            job.setBranch(renamed)
            job.append(JobLogEntry(.system, "\(taken) was taken on GitHub; using \(renamed)."))
            step(job, "Pushing \(renamed)…")
            expecting = nil
        case .refuse:
            return .refused(Self.notOurs(job.branch))
        }

        result = await sendPush(job, remote: remote, expecting: expecting)
        if result.succeeded { return confirmed(job, commit: commit) }
        if Task.isCancelled { return .refused(Job.publishingInterrupted) }
        if GitService.leaseWasRefused(result.output) {
            return .refused(Self.notOurs(job.branch))
        }
        return .failed(Self.pushFailure(job.branch, output: result.output))
    }

    private func sendPush(_ job: Job, remote: String, expecting: String?) async -> Subprocess.Result {
        let git = self.git
        let worktree = job.worktree
        let branch = job.branch
        job.append(JobLogEntry(.system, "git "
            + Self.pushArguments(remote: remote, branch: branch, expecting: expecting)
                .joined(separator: " ")))
        let result = await Subprocess.withDeadline(Self.pushDeadline) {
            await git.push(in: worktree, to: remote, branch: branch, expecting: expecting)
        }
        return result ?? Subprocess.Result(
            status: -1, stdout: "", stderr: "The push did not finish within three minutes.")
    }

    private func confirmed(_ job: Job, commit: String) -> PushOutcome {
        job.setPushedCommit(commit)
        job.setPushingCommit(nil)
        job.append(JobLogEntry(.system, "Pushed \(commit.prefix(12)) to \(job.branch)."))
        return .pushed
    }

    /// The first of `<stem>`, `<stem>-2`, `<stem>-3`… that is neither a
    /// local branch nor a branch on GitHub, other than the one in use.
    /// `<stem>` is the kind's prefix and slug, so a renamed branch is
    /// `fix/x-3`, never `fix/x-2-2`. Nil when GitHub cannot be asked.
    private func nextFreeBranch(_ job: Job, remote: String) async -> String? {
        guard let remoteBranches = await git.remoteHeads(remote: remote, in: job.worktree) else {
            return nil
        }
        let stem = job.kind.branchPrefix + job.kind.slug
        for candidate in [stem] + (2...99).map({ "\(stem)-\($0)" }) {
            guard candidate != job.branch, remoteBranches[candidate] == nil else { continue }
            if await git.resolveCommit("refs/heads/\(candidate)", in: paths.clone) != nil {
                continue
            }
            return candidate
        }
        return nil
    }

    nonisolated static func notOurs(_ branch: String) -> String {
        "\(branch) on GitHub has commits CCwiki did not push. CCwiki will not overwrite them; "
            + "check the branch on GitHub."
    }

    /// A push that failed may still have landed: one stopped at the
    /// deadline, or one whose connection dropped after GitHub moved the
    /// branch. So the message does not say nothing was sent. The next
    /// Approve is safe either way: its push is leased, and a refused lease
    /// asks GitHub where the branch is and recognises CCwiki's own commit.
    nonisolated static func pushFailure(_ branch: String, output: String) -> String {
        let reason = Self.reason(in: output)
        return "The push of \(branch) failed"
            + (reason.isEmpty ? "." : ": \(reason).")
            + " It may or may not have reached GitHub; opening the pull request again "
            + "checks where the branch is on GitHub before pushing."
    }

    /// The line of a tool's output that says what went wrong: git's and
    /// gh's first `fatal:` or `error:` line, else the last line, without the
    /// prefix and the final full stop.
    nonisolated static func reason(in output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var line = lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
            ?? lines.last ?? ""
        for prefix in ["fatal:", "error:"] where line.hasPrefix(prefix) {
            line = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        while line.hasSuffix(".") { line.removeLast() }
        return line
    }

    // MARK: 4. Opening the pull request

    /// The draft pull request for the job's branch: an open one is edited
    /// to the reviewed title and body, rather than a second one opened.
    /// Confirmed by asking GitHub again; `gh`'s own reply is believed only
    /// when GitHub cannot be asked.
    func openPullRequest(_ job: Job, body: String) async -> Result<URL, JobError> {
        step(job, "Opening the pull request…")
        guard let gh = tools.path(for: .gh) else {
            return .failure(JobError(
                "\(job.branch) is on GitHub, but gh is not installed, so the pull request "
                + "could not be opened. Install gh, then open the pull request again."))
        }
        let bodyFile = job.scratch.appending(path: "pull-request-body.md")
        do {
            try FileManager.default.createDirectory(
                at: job.scratch, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: bodyFile, options: .atomic)
        } catch {
            return .failure(JobError(
                "\(job.branch) is on GitHub, but the pull request's body could not be written: "
                + error.localizedDescription))
        }
        let title = job.pullRequest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyPath = bodyFile.path(percentEncoded: false)

        let existing = await runGH(gh, Self.listArguments(target: target, branch: job.branch))
        guard let existing, existing.succeeded else {
            return .failure(JobError(Self.ghFailure(
                job.branch, doing: "look for an open pull request", result: existing)))
        }
        if let open = Self.pullRequest(createdAfter: .distantPast, in: existing.stdout) {
            job.append(JobLogEntry(.system,
                "A pull request is already open from \(job.branch): \(open.absoluteString). "
                + "Updating its title and body."))
            let edit = await runGH(gh, [
                "pr", "edit", open.absoluteString, "--title", title, "--body-file", bodyPath,
            ])
            guard let edit, edit.succeeded else {
                return .failure(JobError(Self.ghFailure(
                    job.branch, doing: "update the open pull request", result: edit)))
            }
            return .success(open)
        }

        let defaultBranch = await git.defaultBranch(in: paths.clone)
        let arguments = Self.createArguments(
            target: target, base: defaultBranch, branch: job.branch,
            title: title, bodyFile: bodyPath)
        job.append(JobLogEntry(.system, "gh " + arguments.joined(separator: " ")))
        let created = await runGH(gh, arguments)
        if let created, !created.succeeded {
            job.append(JobLogEntry(.error, created.output))
        }

        // Whatever gh said, GitHub says whether there is a pull request now:
        // a reply lost on the way back is not a failure to open one.
        let confirmation = await runGH(gh, Self.listArguments(target: target, branch: job.branch))
        if let confirmation, confirmation.succeeded,
           let url = Self.pullRequest(
               createdAfter: job.createdAt.addingTimeInterval(-60), in: confirmation.stdout) {
            return .success(url)
        }
        // GitHub could not be asked again, but gh said it opened one.
        if let created, created.succeeded,
           let url = ClaudeOutcome.findPullRequestURL(in: created.stdout) {
            job.append(JobLogEntry(.system,
                "gh opened \(url.absoluteString); GitHub could not be asked to confirm it."))
            return .success(url)
        }
        return .failure(JobError(Self.ghFailure(
            job.branch, doing: "open the pull request", result: created)))
    }

    private func runGH(_ gh: String, _ arguments: [String]) async -> Subprocess.Result? {
        let environment = tools.childEnvironment()
        return await Subprocess.withDeadline(Self.ghDeadline) {
            await Subprocess.run(executable: gh, arguments: arguments, environment: environment)
        }
    }

    /// `gh pr list` for the open pull requests from `branch` in the target
    /// repository itself, one `<createdAt> <url>` line each. `--head`
    /// matches the branch's name alone, so a pull request from someone's
    /// fork, from a branch that happens to share the name, would match too;
    /// those are left out, so CCwiki never edits a stranger's pull request
    /// or takes it for its own.
    nonisolated static func listArguments(target: PublishTarget, branch: String) -> [String] {
        [
            "pr", "list", "--repo", target.repository, "--head", branch, "--state", "open",
            "--json", "url,createdAt,isCrossRepository",
            "--jq", #".[] | select(.isCrossRepository | not) | "\(.createdAt) \(.url)""#,
        ]
    }

    nonisolated static func ghFailure(
        _ branch: String, doing: String, result: Subprocess.Result?
    ) -> String {
        let reason = result.map { Self.reason(in: $0.output) } ?? "gh did not answer in time"
        return "\(branch) is on GitHub, but gh could not \(doing)"
            + (reason.isEmpty ? "." : ": \(reason).")
            + " Open the pull request again to retry; CCwiki looks for an open one first."
    }

    // MARK: 5. Finishing

    /// The job is opened, and its worktree, scratch and local branch go.
    /// The branch on GitHub stays: the pull request is opened from it.
    private func finish(_ job: Job, url: URL) async {
        job.setNotice(nil)
        job.append(JobLogEntry(.system, "Draft pull request open: \(url.absoluteString)"))
        job.setState(.opened(url: url))
        // In a task of its own, so a cancellation of the publish arriving
        // now cannot stop the removal half way.
        let git = self.git
        let clone = paths.clone
        let worktree = job.worktree
        let scratch = job.scratch
        let branch = job.branch
        let removed = await Task {
            let done = await git.removeWorktree(clone: clone, at: worktree, force: true)
            try? FileManager.default.removeItem(at: scratch)
            if done { _ = await git.deleteBranch(branch, in: clone) }
            return done
        }.value
        job.append(JobLogEntry(.system, removed
            ? "Removed the worktree and the local branch \(branch)."
            : "Could not remove the worktree at \(worktree.path(percentEncoded: false))."))
    }

    // MARK: The dry run

    private func logDryRun(_ job: Job, provenance: PullRequestDraft.Provenance) {
        let push = Self.pushArguments(
            remote: target.pushURL, branch: job.branch, expecting: job.pushedCommit)
        let create = Self.createArguments(
            target: target, base: AppPaths.defaultBranch, branch: job.branch,
            title: job.pullRequest.title, bodyFile: "<body>")
        job.append(JobLogEntry(.system, "Dry run. Would run: git " + push.joined(separator: " ")))
        job.append(JobLogEntry(.system, "Dry run. Would run: gh " + create.joined(separator: " ")))
        job.append(JobLogEntry(.system, "Dry run. The body would be:\n"
            + job.pullRequest.bodyForGitHub(jobID: job.id, provenance: provenance)))
    }

    private func step(_ job: Job, _ text: String) {
        job.setState(.publishing(text))
        job.append(JobLogEntry(.system, text))
    }

    // MARK: Pure

    enum LeaseRecovery: Sendable, Equatable {
        /// Push again, leasing on this commit, or on absence when nil.
        case retry(expecting: String?)
        /// Someone else's branch: take the next free name.
        case rename
        /// Commits CCwiki did not push, on a branch this job has pushed to.
        case refuse
    }

    /// What to do when GitHub refused a push's lease (§6.5 step 3), given
    /// where the branch is there:
    ///
    /// - absent: push again, leasing on absence;
    /// - at `pushing`, `pushed`, or any commit in the local branch's reflog
    ///   (every Approve's commit is there): ours, so push again expecting it;
    /// - anywhere else, and this job never confirmed a push: someone else's
    ///   branch, so take another name;
    /// - anywhere else after a confirmed push: refuse.
    nonisolated static func leaseRecovery(
        remoteTip: String?, pushing: String?, pushed: String?, reflog: Set<String>
    ) -> LeaseRecovery {
        guard let tip = remoteTip else { return .retry(expecting: nil) }
        if tip == pushing || tip == pushed || reflog.contains(tip) {
            return .retry(expecting: tip)
        }
        return pushed == nil ? .rename : .refuse
    }

    /// `push --force-with-lease=refs/heads/<branch>:<expecting> <remote>
    /// HEAD:refs/heads/<branch>`: on absence (`…:`) before the first push.
    nonisolated static func pushArguments(remote: String, branch: String, expecting: String?) -> [String] {
        GitService.pushArguments(remote: remote, branch: branch, expecting: expecting)
    }

    /// `gh pr create`, always as a draft, against the target repository.
    /// Never `--ready`, never a merge, never `--auto`.
    nonisolated static func createArguments(
        target: PublishTarget, base: String, branch: String, title: String, bodyFile: String
    ) -> [String] {
        [
            "pr", "create", "--repo", target.repository, "--draft",
            "--base", base, "--head", branch,
            "--title", title, "--body-file", bodyFile,
        ]
    }

    /// The title, a blank line, and `Opened with CCwiki <version> (job <id>).`
    /// The title is one line, as a commit's subject must be.
    nonisolated static func commitMessage(title: String, version: String, jobID: String) -> String {
        let subject = title.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(subject)\n\nOpened with CCwiki \(version) (job \(jobID))."
    }

    /// `<ISO8601 createdAt> <url>` lines → the newest URL created at or
    /// after `date`: a pull request opened on the job's branch since it
    /// started. What `gh pr list --json url,createdAt` prints through
    /// `--jq`. `Tripwire` keeps a variant that reads the head too.
    nonisolated static func pullRequest(createdAfter date: Date, in listing: String) -> URL? {
        let formatter = ISO8601DateFormatter()
        var best: (Date, URL)?
        for line in listing.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let created = formatter.date(from: parts[0]),
                  created >= date,
                  parts[1].hasPrefix("https://"),
                  let url = URL(string: parts[1])
            else { continue }
            if let current = best, current.0 >= created { continue }
            best = (created, url)
        }
        return best?.1
    }
}
