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
/// several jobs can run at once. Everything from the worktree on is
/// `AgentRun`'s, which a correction shares.
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
        // Cancelled meanwhile: `job.cancel()` has set the state, and the
        // answers above failed because their processes were stopped, not
        // because of anything they asked. They are not findings.
        if Task.isCancelled { return }
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
        if Task.isCancelled { return }
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

        let agent = AgentRun(paths: paths, tools: tools, git: git, target: target, job: job)
        guard await agent.addWorktree(base: base, describing: "origin/\(baseBranch)") else { return }

        // MARK: Submodules

        job.setState(.preparing("Checking out submodules…"))
        let submodules = await git.updateSubmodules(in: job.worktree) { line in
            Task { @MainActor in job.append(JobLogEntry(.system, line.text)) }
        }
        if Task.isCancelled { await agent.cleanUpDespiteCancellation(keep: true); return }
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
            await agent.cleanUp(keep: true)
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
            await agent.cleanUp(keep: true)
            job.setState(.aborted(reason: "Dry run — prompt composed, agent not started."))
            return
        }

        // MARK: The agent

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
        await agent.run(invocation, claude: claude, base: base, siteURL: nil)
    }

    // MARK: Recovery

    /// Worktrees git still knows about that no live job owns.
    ///
    /// A crash or a force-quit mid-job leaves one behind, and `git worktree
    /// add` will refuse to reuse the path. Offering to prune them on launch is
    /// cheaper than making the user learn the `git worktree` subcommands.
    func orphanedWorktrees(knownJobIDs: Set<String>) async -> [(path: String, branch: String?)] {
        // git lists real paths, and the worktrees folder may be reached
        // through a symbolic link (the temporary directory is under /var,
        // which is one), so both sides are compared resolved.
        let prefix = GitService.realPath(paths.worktrees.path(percentEncoded: false))
        return await git.listWorktrees(clone: paths.clone).filter { entry in
            guard GitService.realPath(entry.path).hasPrefix(prefix) else { return false }
            let id = (entry.path as NSString).lastPathComponent
            return !knownJobIDs.contains(id)
        }
    }

    func prune(worktreeAt path: String) async {
        _ = await git.removeWorktree(
            clone: paths.clone, at: URL(fileURLWithPath: path), force: true)
    }
}
