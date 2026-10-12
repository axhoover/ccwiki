import Foundation

/// Runs one ingestion job, up to the review (plans/corrections.md §5.3).
///
/// ```
/// git rev-parse --verify origin/<default>^{commit}  (the base: a commit, recorded)
/// git worktree add ../worktrees/<id> -b ingest/<slug> <base>
/// git submodule update --init --recursive          (cryptobib, for citation keys)
/// git ls-remote --heads                             (the tripwire's "before")
/// claude -p "<composed prompt>"                     (sealed; streamed into the transcript)
/// the tripwire, the hand-over file, the changes     → awaiting review
/// ```
///
/// The agent no longer commits, pushes or opens anything. It leaves its
/// change in the worktree and the pull request's text in
/// `.ccwiki/pull-request.md`, and the job waits for a person in Jobs. Only
/// Approve sends anything to GitHub.
///
/// The worktree is the isolation: it has its own working directory and shares
/// only the object database, so a job cannot dirty the reader's checkout and
/// several jobs can run at once. It is **kept** whenever there is something
/// in it to look at — a review, a failure, an abort — because a job you
/// cannot inspect is a job you cannot debug. Only an agent that changed
/// nothing has its worktree pruned.
@MainActor
struct IngestJobRunner {

    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    let index: WikiIndex?
    /// Where the pull request would go: push rights are asked of it, and
    /// the tripwire watches it.
    let target: PublishTarget

    /// Overridable for experiments; see the note at the call site.
    static var maxTurns: String {
        ProcessInfo.processInfo.environment["CCWIKI_MAX_TURNS"] ?? "200"
    }

    func run(_ job: Job) async {
        guard let submission = job.submission else {
            job.setState(.failed("This job is not an ingestion."))
            return
        }
        job.setState(.preparing("Checking…"))

        // Nothing is pushed until Approve, but a credential needed at the
        // end is checked at the beginning: an ingestion takes twenty
        // minutes, and its review is no use if it can never be published.
        let canPush = await git.canAuthenticatePush(clone: paths.clone)
        let authenticated = await GitHubAuth.isAuthenticated(tools: tools)
        let pushRights = authenticated
            ? await GitHubAuth.canPush(tools: tools, repository: target.repository)
            : nil
        let findings = Preflight.run(
            submission: submission, index: index, paths: paths, tools: tools,
            isGitHubAuthenticated: authenticated, canPush: canPush, hasPushRights: pushRights,
            repository: target.repository)
        job.setPreflight(findings)
        for finding in findings {
            job.append(JobLogEntry(
                finding.level == .info ? .system : .error,
                "\(finding.title) — \(finding.detail)"))
        }
        if findings.contains(where: { $0.level == .blocking }) {
            job.setState(.failed("Pre-flight checks failed. Nothing was created."))
            return
        }

        guard let claude = tools.path(for: .claude) else {
            job.setState(.failed("The claude CLI was not found."))
            return
        }

        // MARK: Worktree

        let baseBranch = await git.defaultBranch(in: paths.clone)
        job.setState(.preparing("Creating worktree…"))

        // The base is a commit, not a ref. Left as `origin/main`, a sync
        // during review would move it: the review would show upstream
        // commits reversed, and Approve would commit their reversal.
        guard let base = await git.resolveCommit("origin/\(baseBranch)", in: paths.clone) else {
            // Cancelled meanwhile: `job.cancel()` has set the state.
            if Task.isCancelled { return }
            job.setState(.failed(
                "Could not find origin/\(baseBranch) in the wiki's clone. "
                + "Sync (⌘R), then run the job again."))
            return
        }
        job.setBaseCommit(base)

        // Re-submitting a paper after a failed job is the common case, and the
        // branch from the failed attempt is still there. Take the next free
        // name rather than making the user learn `git branch -D`.
        let branch = await git.availableBranchName(clone: paths.clone, preferred: job.branch)
        job.setBranch(branch)
        job.append(JobLogEntry(.system,
            "git worktree add \(job.worktree.lastPathComponent) "
            + "-b \(branch) \(base.prefix(12)) (origin/\(baseBranch))"))

        let created = await git.addWorktree(
            clone: paths.clone, at: job.worktree,
            branch: branch, baseRef: base
        ) { line in
            Task { @MainActor in job.append(JobLogEntry(.system, line.text)) }
        }
        // Cancelled during `worktree add`: `job.cancel()` has set the state,
        // and a failed add is not a failure to report over it.
        if Task.isCancelled {
            if created { await cleanUpDespiteCancellation(job, keep: false) }
            return
        }
        guard created else {
            job.setState(.failed(
                "Could not create the worktree at \(job.worktree.lastPathComponent). "
                + "Check the transcript for git's reason."))
            return
        }

        // MARK: Submodules

        job.setState(.preparing("Checking out submodules…"))
        let submodules = await git.updateSubmodules(in: job.worktree) { line in
            Task { @MainActor in job.append(JobLogEntry(.system, line.text)) }
        }
        if Task.isCancelled { await cleanUpDespiteCancellation(job, keep: true); return }
        if !submodules {
            job.append(JobLogEntry(.error,
                "Submodules did not check out. The agent cannot look up a cryptobib_key "
                + "and will have to supply an inline bibtex block instead."))
        }

        // MARK: Prompt

        let prompt: String
        do {
            prompt = try PromptComposer.compose(
                job: job, baseBranch: baseBranch, preflight: findings)
        } catch {
            job.append(JobLogEntry(.error, error.localizedDescription))
            await cleanUp(job, keep: true)
            job.setState(.failed(error.localizedDescription))
            return
        }
        job.append(JobLogEntry(.system,
            "Prompt composed from prompts/ingest.md plus the worktree's own "
            + ".github/prompts/paper-submission.md (\(prompt.count) characters)."))

        // Iterating on a prompt should not cost a full agent run. With
        // CCWIKI_INGEST_DRY_RUN=1 the job stops here, having done every
        // mechanical step — worktree, submodules, pre-flight, composition —
        // and writes the prompt it would have sent into the transcript.
        if ProcessInfo.processInfo.environment["CCWIKI_INGEST_DRY_RUN"] == "1" {
            job.appendRaw(prompt)
            job.append(JobLogEntry(.assistant, prompt))
            job.append(JobLogEntry(.system, "Dry run: the agent was not started."))
            await cleanUp(job, keep: true)
            job.setState(.aborted(reason: "Dry run — prompt composed, agent not started."))
            return
        }

        // MARK: The agent

        // What GitHub looked like before, so the tripwire can tell
        // afterwards what moved while the agent ran (§5.5).
        let tripwire = Tripwire(git: git, tools: tools, target: target)
        let headsBefore = await tripwire.headsBefore()
        if Task.isCancelled { await cleanUpDespiteCancellation(job, keep: true); return }
        if headsBefore == nil {
            job.append(JobLogEntry(.system,
                "Could not list the branches on GitHub, so the tripwire will not be able to "
                + "check for a push."))
        }

        // The agent's own, empty gh configuration: the seal (§5.1).
        try? FileManager.default.createDirectory(
            at: AgentInvocation.ghConfigDirectory(scratch: job.scratch),
            withIntermediateDirectories: true)
        // The wiki's own GitHub workflow caps turns at 40, but that prompt
        // has no local validation step. Ingesting a paper here means reading
        // five contract files, fetching the paper, writing a page, then
        // `npm ci` → lint → `quartz build` → sync-cryptobib with a fix cycle
        // after each. A first run spent 54 turns before writing a single
        // file. The real bound on a runaway job is the user's Cancel button
        // and the cost readout, not an arbitrary count.
        let invocation = AgentInvocation.ingestion(
            prompt: prompt, maxTurns: Self.maxTurns,
            base: tools.childEnvironment(), scratch: job.scratch)

        job.setState(.running)
        var parser = ClaudeStreamParser()

        var exitStatus: Int32 = -1
        let transcript = TranscriptBuffer(job: job)
        for await line in Subprocess.lines(
            executable: claude,
            arguments: invocation.arguments,
            currentDirectory: job.worktree,
            environment: invocation.environment
        ) {
            if let status = line.exitStatus { exitStatus = status; continue }
            job.appendRaw(line.text)

            switch line.stream {
            case .stdout:
                transcript.append(parser.consume(line.text))
            case .stderr:
                // The CLI logs progress to stderr; only surface the substantive
                // lines, or the transcript fills with noise.
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, !line.isProgress {
                    transcript.append([JobLogEntry(.stderr, text)])
                }
            }
        }
        // Everything buffered lands before the outcome is written beneath it.
        transcript.flush()

        if Task.isCancelled {
            await cleanUp(job, keep: true)
            job.setState(.cancelled)
            return
        }

        // MARK: The tripwire

        // What the agent says is prose; what GitHub says is fact. Asked
        // after every exit but a cancel, whatever the agent reports.
        let caught = await tripwire.check(
            job, headsBefore: headsBefore,
            otherBranches: Tripwire.otherJobBranches(logs: paths.logs, excluding: job.id))
        if Task.isCancelled {
            await cleanUpDespiteCancellation(job, keep: true)
            return
        }
        if let notice = caught.notice { job.setNotice(notice) }
        if let outcome = parser.outcome { job.setOutcome(outcome) }
        if let url = caught.pullRequest {
            // Not CCwiki's pull request, and nothing to review: the change
            // is already on GitHub. The worktree stays, for inspection.
            await cleanUp(job, keep: true)
            job.setState(.opened(url: url))
            return
        }

        // MARK: Outcome

        guard let outcome = parser.outcome else {
            job.append(JobLogEntry(.error, "claude exited \(exitStatus) with no result event."))
            await cleanUp(job, keep: true)
            job.setState(.failed(
                exitStatus == 0
                    ? "The agent produced no result. The transcript is in the log file."
                    : "claude exited \(exitStatus)."))
            return
        }

        for denial in outcome.permissionDenials {
            job.append(JobLogEntry(.error, "Permission denied — \(denial)"))
        }
        if !outcome.result.isEmpty {
            job.append(JobLogEntry(.assistant, outcome.result))
        }
        if let claimed = outcome.pullRequestURL {
            job.append(JobLogEntry(.system,
                "The agent's last message names \(claimed.absoluteString). CCwiki takes a "
                + "pull request from GitHub, never from the agent's words."))
        }

        if let reason = outcome.abortReason {
            // Aborting is a good outcome, and the prompt says so: a wrong page
            // in the wiki costs a maintainer more than a submission that did
            // not land. Keep the worktree so the reasoning can be checked.
            await cleanUp(job, keep: true)
            job.setState(.aborted(reason: reason))
            return
        }

        if outcome.isError {
            await cleanUp(job, keep: true)
            job.setState(.failed("The agent reported an error (\(outcome.subtype))."))
            return
        }

        await handOver(job, base: base)
    }

    // MARK: Hand-over

    /// The agent finished. Read the pull request text it left, and either
    /// wait for a person or, when it changed nothing, say so and prune.
    /// The full snapshot, with DiffGuard's findings, is the job center's,
    /// taken as the job enters review (§6.1); this asks git only whether
    /// there is anything to review.
    private func handOver(_ job: Job, base: String) async {
        let handover = Handover.pullRequestText(in: job.worktree)
        if handover == nil {
            job.append(JobLogEntry(.system,
                "The agent left no \(Handover.pullRequestPath); CCwiki proposes a title "
                + "and body of its own."))
        }
        job.pullRequest = PullRequestDraft.make(
            for: job.kind,
            handover: handover.flatMap { PullRequestDraft.parse(handover: $0) },
            siteURL: nil)

        let staged = await git.stageAll(in: job.worktree)
        let diff = staged ? await git.stagedDiff(in: job.worktree, base: base) : nil
        if Task.isCancelled {
            await cleanUpDespiteCancellation(job, keep: true)
            return
        }
        guard let diff else {
            job.append(JobLogEntry(.error,
                "git could not stage or compare the worktree's changes."))
            await cleanUp(job, keep: true)
            job.setState(.failed(
                "CCwiki could not read the agent's changes. The worktree has been kept."))
            return
        }
        guard !diff.nameStatus.isEmpty else {
            job.append(JobLogEntry(.system, Self.nothingChanged))
            await cleanUp(job, keep: false)
            job.setState(.failed(Self.nothingChanged))
            return
        }

        job.append(JobLogEntry(.system,
            "Awaiting review in Jobs. Nothing has been pushed: the draft pull request "
            + "opens only when you approve the changes."))
        job.setState(.awaitingReview)
    }

    nonisolated static let nothingChanged = "The agent finished without changing anything."

    /// `<ISO8601 createdAt> <url>` lines → the newest URL created after `date`.
    /// What `gh pr list --json url,createdAt` prints through `--jq`, for a
    /// pull request opened on the job's branch since it started. Publisher
    /// confirms its own pull request with it (§6.5); `Tripwire` keeps a
    /// variant that reads the head too.
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
            if best == nil || created > best!.0 { best = (created, url) }
        }
        return best?.1
    }

    /// `cleanUp`, from a task that has been cancelled.
    ///
    /// A `git worktree remove` started from a cancelled task is killed the
    /// moment it starts (`Subprocess.lines` honours cancellation). An
    /// unstructured task does not inherit the cancellation, so the removal
    /// actually runs.
    private func cleanUpDespiteCancellation(_ job: Job, keep: Bool) async {
        await Task { @MainActor in await cleanUp(job, keep: keep) }.value
    }

    /// Remove the worktree, its scratch directory and its local branch,
    /// unless there is something in them worth looking at. Nothing was
    /// pushed, so nothing on GitHub is touched.
    private func cleanUp(_ job: Job, keep: Bool) async {
        if keep {
            job.append(JobLogEntry(.system,
                "Worktree kept at \(job.worktree.path(percentEncoded: false))"))
            return
        }
        job.append(JobLogEntry(.system, "Pruning worktree."))
        let removed = await git.removeWorktree(clone: paths.clone, at: job.worktree, force: true)
        if !removed {
            job.append(JobLogEntry(.system,
                "Could not remove the worktree; it is still at "
                + job.worktree.path(percentEncoded: false)))
        }
        try? FileManager.default.removeItem(at: job.scratch)
        if removed { _ = await git.deleteBranch(job.branch, in: paths.clone) }
    }

    // MARK: Recovery

    /// Worktrees git still knows about that no live job owns.
    ///
    /// A crash or a force-quit mid-job leaves one behind, and `git worktree
    /// add` will refuse to reuse the path. Offering to prune them on launch is
    /// cheaper than making the user learn the `git worktree` subcommands.
    func orphanedWorktrees(knownJobIDs: Set<String>) async -> [(path: String, branch: String?)] {
        let prefix = paths.worktrees.path(percentEncoded: false)
        return await git.listWorktrees(clone: paths.clone).filter { entry in
            guard entry.path.hasPrefix(prefix) else { return false }
            let id = (entry.path as NSString).lastPathComponent
            return !knownJobIDs.contains(id)
        }
    }

    func prune(worktreeAt path: String) async {
        _ = await git.removeWorktree(
            clone: paths.clone, at: URL(fileURLWithPath: path), force: true)
    }
}
