import Foundation

/// Runs one ingestion job end to end.
///
/// ```
/// git worktree add ../worktrees/<id> -b ingest/<slug> origin/<default>
/// git submodule update --init --recursive          (cryptobib, for citation keys)
/// claude -p "<composed prompt>"                    (streamed into the transcript)
/// git worktree remove ../worktrees/<id>            (only when it worked)
/// ```
///
/// The worktree is the isolation: it has its own working directory and shares
/// only the object database, so a job cannot dirty the reader's checkout and
/// several jobs can run at once. On failure the worktree is **kept** — a job
/// you cannot inspect is a job you cannot debug — and the panel offers to open
/// it in Terminal.
@MainActor
struct IngestJobRunner {

    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    let index: WikiIndex?

    /// Overridable for experiments; see the note at the call site.
    static var maxTurns: String {
        ProcessInfo.processInfo.environment["CCWIKI_MAX_TURNS"] ?? "200"
    }

    func run(_ job: IngestJob) async {
        job.setState(.preparing("Checking…"))

        let canPush = await git.canAuthenticatePush(clone: paths.clone)
        let authenticated = await GitHubAuth.isAuthenticated(tools: tools)
        let pushRights = authenticated
            ? await GitHubAuth.canPush(tools: tools, repository: AppPaths.repositorySlug)
            : nil
        let findings = Preflight.run(
            submission: job.submission, index: index, paths: paths, tools: tools,
            isGitHubAuthenticated: authenticated, canPush: canPush, hasPushRights: pushRights)
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

        // Re-submitting a paper after a failed job is the common case, and the
        // branch from the failed attempt is still there. Take the next free
        // name rather than making the user learn `git branch -D`.
        let branch = await git.availableBranchName(clone: paths.clone, preferred: job.branch)
        job.setBranch(branch)
        job.append(JobLogEntry(.system,
            "git worktree add \(job.worktree.lastPathComponent) "
            + "-b \(branch) origin/\(baseBranch)"))

        let created = await git.addWorktree(
            clone: paths.clone, at: job.worktree,
            branch: branch, baseRef: "origin/\(baseBranch)"
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

        job.setState(.running)
        var parser = ClaudeStreamParser()

        let arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            // Edits inside a throwaway worktree are safe to auto-accept; every
            // shell command still has to match the allow-list below, so a job
            // that wanders off fails loudly instead of doing something unasked.
            "--permission-mode", "acceptEdits",
            "--allowedTools", PromptComposer.allowedTools.joined(separator: ","),
            // The wiki's own GitHub workflow caps this at 40, but that prompt
            // has no local validation step. Ingesting a paper here means
            // reading five contract files, fetching the paper, writing a page,
            // then `npm ci` → lint → `quartz build` → sync-cryptobib with a fix
            // cycle after each. A first run spent 54 turns before writing a
            // single file. The real bound on a runaway job is the user's
            // Cancel button and the cost readout, not an arbitrary count.
            "--max-turns", Self.maxTurns,
        ]

        var exitStatus: Int32 = -1
        for await line in Subprocess.lines(
            executable: claude,
            arguments: arguments,
            currentDirectory: job.worktree,
            environment: tools.childEnvironment()
        ) {
            if let status = line.exitStatus { exitStatus = status; continue }
            job.appendRaw(line.text)

            switch line.stream {
            case .stdout:
                job.append(parser.consume(line.text))
            case .stderr:
                // The CLI logs progress to stderr; only surface the substantive
                // lines, or the transcript fills with noise.
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, !line.isProgress {
                    job.append(JobLogEntry(.stderr, text))
                }
            }
        }

        if Task.isCancelled {
            await cleanUp(job, keep: true)
            job.setState(.cancelled)
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
        job.setOutcome(outcome)

        for denial in outcome.permissionDenials {
            job.append(JobLogEntry(.error, "Permission denied — \(denial)"))
        }
        if !outcome.result.isEmpty {
            job.append(JobLogEntry(.assistant, outcome.result))
        }

        // What the agent says is prose; what GitHub says is fact. A final
        // message that quotes the abort protocol or mentions an older PR
        // used to be misread — this asks `gh` before believing either.
        if let url = await confirmedPullRequest(job) {
            job.append(JobLogEntry(.system,
                "GitHub confirms a pull request for \(job.branch): \(url.absoluteString)"))
            await cleanUp(job, keep: false)
            job.setState(.opened(url: url))
            return
        }

        if let reason = outcome.abortReason {
            // Aborting is a good outcome, and the prompt says so: a wrong page
            // in the wiki costs a maintainer more than a submission that did
            // not land. Keep the worktree so the reasoning can be checked.
            await cleanUp(job, keep: true)
            job.setState(.aborted(reason: reason))
            return
        }

        if let url = outcome.pullRequestURL {
            job.append(JobLogEntry(.system, "Draft pull request: \(url.absoluteString)"))
            await cleanUp(job, keep: false)
            job.setState(.opened(url: url))
            return
        }

        if outcome.isError {
            await cleanUp(job, keep: true)
            job.setState(.failed("The agent reported an error (\(outcome.subtype))."))
            return
        }

        await cleanUp(job, keep: true)
        job.setState(.failed(
            "The agent finished without opening a pull request and without aborting. "
            + "The worktree has been kept so you can see what it did."))
    }

    /// The PR for the job's branch, if GitHub has one.
    private func confirmedPullRequest(_ job: IngestJob) async -> URL? {
        guard let gh = tools.path(for: .gh) else { return nil }
        let result = await Subprocess.run(
            executable: gh,
            arguments: ["pr", "view", job.branch, "--repo", AppPaths.repositorySlug,
                        "--json", "url", "--jq", ".url"],
            currentDirectory: job.worktree,
            environment: tools.childEnvironment())
        guard result.succeeded else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("https://") else { return nil }
        return URL(string: text)
    }

    /// `cleanUp`, from a task that has been cancelled.
    ///
    /// A `git worktree remove` started from a cancelled task is killed the
    /// moment it starts (`Subprocess.lines` honours cancellation). An
    /// unstructured task does not inherit the cancellation, so the removal
    /// actually runs.
    private func cleanUpDespiteCancellation(_ job: IngestJob, keep: Bool) async {
        await Task { @MainActor in await cleanUp(job, keep: keep) }.value
    }

    /// Remove the worktree, unless there is something in it worth looking at.
    private func cleanUp(_ job: IngestJob, keep: Bool) async {
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
