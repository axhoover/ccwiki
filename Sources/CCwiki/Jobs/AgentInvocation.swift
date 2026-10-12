import Foundation

/// How CCwiki starts `claude` for a job: its arguments, and the environment
/// it runs in (plans/corrections.md §5.1, §5.4). Pure, so every layer of the
/// seal is tested.
///
/// An agent job stops before GitHub. The agent leaves its changes in the
/// worktree and its pull request's text in the handover file; CCwiki shows
/// both to a person, and only once they approve does CCwiki commit, push and
/// open the pull request, with its own unsealed environment. A prompt that
/// says "do not push" is not enough, so every agent runs inside three
/// layers:
///
/// 1. **The allow-list** leaves out `gh` and every git command that writes.
///    A correction gets no `Bash` at all.
/// 2. **The deny-list**, which wins over any allow.
/// 3. **The environment** (`sealed`): no GitHub token, no SSH agent, an
///    empty `gh` configuration, no credential helper, and a push URL that
///    goes nowhere.
///
/// The seal stops a confused agent and an accident: a plain `git push` or
/// `gh pr create` fails. It does not stop a determined one. `git -c
/// credential.helper=… push` does not match the deny rule's prefix, and an
/// ingestion keeps `node`, which can run anything. So the tripwire
/// (`Tripwire`) looks afterwards, and the review is the gate: nothing the
/// agent leaves in the worktree reaches GitHub without approval (§13).
struct AgentInvocation: Sendable, Equatable {

    /// For `claude`, after the executable.
    var arguments: [String]
    var environment: [String: String]

    /// A paper ingestion: the CLI's default model, and the tools the wiki's
    /// own workflow grants plus what the local lint needs.
    static func ingestion(
        prompt: String, maxTurns: String, base: [String: String], scratch: URL
    ) -> AgentInvocation {
        AgentInvocation(
            arguments: arguments(
                prompt: prompt, model: "", allowed: ingestionTools, maxTurns: maxTurns),
            environment: sealed(base, scratch: scratch))
    }

    /// A correction: a smaller model where one is chosen (`""` is the CLI's
    /// default), the file tools, and nothing else (§5.4).
    static func correction(
        prompt: String, model: String, maxTurns: String,
        base: [String: String], scratch: URL
    ) -> AgentInvocation {
        AgentInvocation(
            arguments: arguments(
                prompt: prompt, model: model, allowed: correctionTools, maxTurns: maxTurns),
            environment: sealed(base, scratch: scratch))
    }

    /// ```
    /// claude -p "<prompt>" --output-format stream-json --verbose [--model <m>]
    ///   --permission-mode acceptEdits --allowedTools … --disallowedTools …
    ///   --max-turns <n>
    /// ```
    ///
    /// The prompt goes first: `--allowedTools` and `--disallowedTools` take
    /// a list, and would swallow a prompt that followed them. Edits inside a
    /// throwaway worktree are safe to auto-accept; every other tool still
    /// has to match the allow-list, so a job that wanders off fails visibly,
    /// with the denied call named in the transcript, rather than doing
    /// something nobody asked for.
    private static func arguments(
        prompt: String, model: String, allowed: [String], maxTurns: String
    ) -> [String] {
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if !model.isEmpty { arguments += ["--model", model] }
        arguments += [
            "--permission-mode", "acceptEdits",
            "--allowedTools", allowed.joined(separator: ","),
            "--disallowedTools", denied.joined(separator: ","),
            "--max-turns", maxTurns,
        ]
        return arguments
    }

    // MARK: The environment

    /// `environment`, sealed for an agent (§5.1):
    ///
    /// - `GH_CONFIG_DIR` is an empty directory under the job's scratch,
    ///   outside the worktree, so `gh` sees no signed-in host and nothing it
    ///   writes can be staged;
    /// - the GitHub tokens and `SSH_AUTH_SOCK` are removed;
    /// - three git settings, appended after any the environment already
    ///   carries so they are read last: `remote.origin.pushurl` goes
    ///   nowhere, and both `credential.helper` and the clone's own
    ///   `credential.https://github.com.helper` are emptied, which clears
    ///   each list;
    /// - `GIT_SSH_COMMAND` and both askpass programs are `/usr/bin/false`,
    ///   and git never prompts.
    ///
    /// `GIT_CONFIG_COUNT` needs git 2.31; Apple's is 2.39. CCwiki's own
    /// commands use the environment unsealed.
    static func sealed(_ environment: [String: String], scratch: URL) -> [String: String] {
        var sealed = environment
        for name in removedVariables { sealed[name] = nil }
        sealed["GH_CONFIG_DIR"] = ghConfigDirectory(scratch: scratch).path(percentEncoded: false)

        let start = max(environment["GIT_CONFIG_COUNT"].flatMap { Int($0) } ?? 0, 0)
        for (offset, setting) in gitSettings.enumerated() {
            sealed["GIT_CONFIG_KEY_\(start + offset)"] = setting.key
            sealed["GIT_CONFIG_VALUE_\(start + offset)"] = setting.value
        }
        sealed["GIT_CONFIG_COUNT"] = String(start + gitSettings.count)

        for program in ["GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS"] {
            sealed[program] = "/usr/bin/false"
        }
        sealed["GIT_TERMINAL_PROMPT"] = "0"
        return sealed
    }

    /// The agent's `GH_CONFIG_DIR`: `<scratch>/gh`. The runner creates it,
    /// empty, before the agent starts.
    static func ghConfigDirectory(scratch: URL) -> URL {
        scratch.appending(path: "gh")
    }

    /// Credentials an agent must not inherit.
    static let removedVariables = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
        "SSH_AUTH_SOCK",
    ]

    /// The push URL a sealed `git push origin` is sent to: no transport
    /// answers to it, so the push fails before anything leaves.
    static let blockedPushURL = "ccwiki-review-first://blocked"

    /// In order; an empty helper clears the list of helpers before it.
    static let gitSettings: [(key: String, value: String)] = [
        ("remote.origin.pushurl", blockedPushURL),
        ("credential.helper", ""),
        ("credential.https://github.com.helper", ""),
    ]

    // MARK: Tools

    /// What an ingestion agent may use: the allow-list the wiki's own GitHub
    /// workflow grants (`paper-submission.yml`), less everything that
    /// reaches GitHub, plus the node and npm commands the **local** lint
    /// needs, which the server pipeline does not run.
    ///
    /// git only reads. The agent no longer commits (§5.1): it leaves its
    /// change in the worktree, and CCwiki commits it after review. `gh` is
    /// not here at all.
    ///
    /// The allow-list matches on a command's **first words**, so `cd X &&
    /// git …` is denied however harmless it looks. The first real job hit
    /// seven denials, every one a `cd`-prefixed or `ln` command, which is
    /// why `prompts/ingest.md` says plainly that the shell already starts in
    /// the worktree. The rest are read-only inspection tools.
    static let ingestionTools = [
        "Read", "Write", "Edit", "Glob", "Grep", "TodoWrite",
        // git, to read with.
        "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
        "Bash(git ls-files:*)", "Bash(git grep:*)", "Bash(git rev-parse:*)",
        "Bash(git submodule update:*)",
        // The lint and the build.
        "Bash(npm:*)", "Bash(npx:*)", "Bash(node:*)",
        // Read-only inspection.
        "Bash(find:*)", "Bash(file:*)", "Bash(jq:*)", "Bash(cat:*)", "Bash(ls:*)",
        "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(grep:*)", "Bash(rg:*)",
        "Bash(echo:*)", "Bash(pwd)", "Bash(test:*)", "Bash(diff:*)",
        "Bash(sort:*)", "Bash(uniq:*)", "Bash(cut:*)", "Bash(basename:*)",
        "Bash(dirname:*)", "Bash(hexdump:*)", "Bash(xxd:*)", "Bash(od:*)",
        "Bash(pdftotext:*)", "Bash(mdls:*)",
        // Fetching the paper.
        "WebFetch", "WebSearch",
    ]

    /// What a correction agent may use: the file tools. No `Bash` (CCwiki
    /// computes the diff itself, and `git diff --output=<file>` writes
    /// anywhere), and no web: a correction that needs the cited paper read
    /// again is beyond a cheap job, and the prompt says to abort (§5.4).
    static let correctionTools = ["Read", "Edit", "Write", "Glob", "Grep"]

    /// Denied whatever the allow-list says.
    static let denied = [
        "Bash(git push:*)", "Bash(git commit:*)", "Bash(git remote:*)", "Bash(git config:*)",
        "Bash(gh:*)",
    ]
}

/// The agent's side of the hand-over (plans/corrections.md §5.2). It leaves
/// its changes in the worktree, and the pull request's text in
/// `.ccwiki/pull-request.md`: the first line `# <title>`, the rest the body.
///
/// `.ccwiki/` is also where an agent writes any scratch output, such as a
/// lint log. Every `git add` CCwiki runs leaves it out (`GitService.stageAll`),
/// so nothing in it can reach a pull request.
enum Handover {

    /// Repository-relative.
    static let directory = ".ccwiki"
    static let pullRequestPath = ".ccwiki/pull-request.md"

    /// The pull request text the agent left in `worktree`, if any.
    static func pullRequestText(in worktree: URL) -> String? {
        try? String(contentsOf: worktree.appending(path: pullRequestPath), encoding: .utf8)
    }
}

// MARK: - Running an agent job

/// What an ingestion and a correction do alike, once each has resolved its
/// base: the worktree, then, after the runner has composed its prompt, the
/// agent itself and what comes after it (plans/corrections.md §5.3–§5.5).
///
/// ```
/// git worktree add <worktrees>/<id> -b <branch> <base>
/// git ls-remote <target> 'refs/heads/*'     the tripwire's "before"
/// claude -p "<prompt>" …                    sealed; streamed into the transcript
/// the tripwire                              a push or a PR CCwiki did not make
/// the outcome                               aborted, failed, or
/// the hand-over                             .ccwiki/pull-request.md, the change → awaiting review
/// ```
///
/// The worktree is **kept** whenever there is something in it to look at —
/// a review, a failure, an abort — because a job you cannot inspect is a job
/// you cannot debug. Only an agent that changed nothing has its worktree,
/// scratch and local branch removed. Nothing on GitHub is touched: the
/// agent cannot push, and CCwiki pushes only at Approve.
@MainActor
struct AgentRun {

    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    /// Where the pull request would go: the tripwire watches it.
    let target: PublishTarget
    let job: Job

    // MARK: The worktree

    /// The job's branch, at the first name no local or remote branch claims,
    /// and its worktree on `base`. `ref` names what `base` was resolved
    /// from, for the transcript. False when the job has ended: failed, or
    /// cancelled meanwhile.
    func addWorktree(base: String, describing ref: String?) async -> Bool {
        // Running a job again after a failure is the common case, and the
        // branch from the failed attempt is still there. Take the next free
        // name rather than making the user learn `git branch -D`.
        let branch = await git.availableBranchName(clone: paths.clone, preferred: job.branch)
        job.setBranch(branch)
        job.append(JobLogEntry(.system,
            "git worktree add \(job.worktree.lastPathComponent) -b \(branch) \(base.prefix(12))"
            + (ref.map { " (\($0))" } ?? "")))

        let transcript = job
        let created = await git.addWorktree(
            clone: paths.clone, at: job.worktree, branch: branch, baseRef: base
        ) { line in
            Task { @MainActor in transcript.append(JobLogEntry(.system, line.text)) }
        }
        // Cancelled during `worktree add`: `job.cancel()` has set the state,
        // and a failed add is not a failure to report over it.
        if Task.isCancelled {
            if created { await cleanUpDespiteCancellation(keep: false) }
            return false
        }
        guard created else {
            job.setState(.failed(
                "Could not create the worktree at \(job.worktree.lastPathComponent). "
                + "Check the transcript for git's reason."))
            return false
        }
        return true
    }

    // MARK: The agent

    /// Runs `claude` with `invocation` in the job's worktree, and settles
    /// the job: `awaitingReview` when the agent changed something and did
    /// not abort, `opened` when the tripwire found a pull request it opened
    /// itself, and otherwise aborted, failed or cancelled. `base` is the
    /// commit the worktree started from; `siteURL` is the page on the
    /// site, for the pull request CCwiki proposes.
    func run(_ invocation: AgentInvocation, claude: String, base: String, siteURL: URL?) async {
        // What GitHub looked like before, so the tripwire can tell
        // afterwards what moved while the agent ran (§5.5).
        let tripwire = Tripwire(git: git, tools: tools, target: target)
        let headsBefore = await tripwire.headsBefore()
        if Task.isCancelled { await cleanUpDespiteCancellation(keep: true); return }
        if headsBefore == nil {
            job.append(JobLogEntry(.system,
                "Could not list the branches on GitHub, so the tripwire will not be able to "
                + "check for a push."))
        }

        // The agent's own, empty gh configuration: the seal (§5.1).
        try? FileManager.default.createDirectory(
            at: AgentInvocation.ghConfigDirectory(scratch: job.scratch),
            withIntermediateDirectories: true)
        // `.ccwiki/`, where the prompts send the hand-over and any scratch
        // output. A shell redirect does not make the directory, and the
        // agent has no `mkdir`; `stageAll` never stages anything in it.
        try? FileManager.default.createDirectory(
            at: job.worktree.appending(path: Handover.directory),
            withIntermediateDirectories: true)

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
            await cleanUp(keep: true)
            job.setState(.cancelled)
            return
        }

        // What the agent says is prose; what GitHub says is fact. Asked
        // after every exit but a cancel, whatever the agent reports.
        let caught = await tripwire.check(
            job, headsBefore: headsBefore,
            otherBranches: Tripwire.otherJobBranches(logs: paths.logs, excluding: job.id))
        if Task.isCancelled {
            await cleanUpDespiteCancellation(keep: true)
            return
        }
        if let notice = caught.notice { job.setNotice(notice) }
        if let outcome = parser.outcome { job.setOutcome(outcome) }
        if let url = caught.pullRequest {
            // Not CCwiki's pull request, and nothing to review: the change
            // is already on GitHub. The worktree stays, for inspection.
            await cleanUp(keep: true)
            job.setState(.opened(url: url))
            return
        }

        guard let outcome = parser.outcome else {
            job.append(JobLogEntry(.error, "claude exited \(exitStatus) with no result event."))
            await cleanUp(keep: true)
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
            // Aborting is a good outcome, and the prompts say so: a wrong
            // page in the wiki costs a maintainer more than a change that did
            // not land. Keep the worktree so the reasoning can be checked.
            await cleanUp(keep: true)
            job.setState(.aborted(reason: reason))
            return
        }

        if outcome.isError {
            await cleanUp(keep: true)
            job.setState(.failed("The agent reported an error (\(outcome.subtype))."))
            return
        }

        await handOver(base: base, siteURL: siteURL)
    }

    // MARK: The hand-over

    /// The agent finished. Read the pull request text it left, and either
    /// wait for a person or, when it changed nothing, say so and prune.
    /// The full snapshot, with DiffGuard's findings, is the job center's,
    /// taken as the job enters review (§6.1); this asks git only whether
    /// there is anything to review.
    private func handOver(base: String, siteURL: URL?) async {
        let handover = Handover.pullRequestText(in: job.worktree)
        if handover == nil {
            job.append(JobLogEntry(.system,
                "The agent left no \(Handover.pullRequestPath); CCwiki proposes a title "
                + "and body of its own."))
        }
        job.pullRequest = PullRequestDraft.make(
            for: job.kind,
            handover: handover.flatMap { PullRequestDraft.parse(handover: $0) },
            siteURL: siteURL)

        var diff: (nameStatus: Data, numstat: Data, patch: Data)?
        if await git.stageAll(in: job.worktree) {
            diff = await git.stagedDiff(in: job.worktree, base: base)
        }
        if Task.isCancelled {
            await cleanUpDespiteCancellation(keep: true)
            return
        }
        guard let diff else {
            job.append(JobLogEntry(.error,
                "git could not stage or compare the worktree's changes."))
            await cleanUp(keep: true)
            job.setState(.failed(
                "CCwiki could not read the agent's changes. The worktree has been kept."))
            return
        }
        guard !diff.nameStatus.isEmpty else {
            job.append(JobLogEntry(.system, Self.nothingChanged))
            await cleanUp(keep: false)
            job.setState(.failed(Self.nothingChanged))
            return
        }

        // "CCwiki has pushed nothing", not "nothing has been pushed": the
        // tripwire may just have found a push the agent made itself.
        job.append(JobLogEntry(.system,
            "Awaiting review in Jobs. CCwiki has pushed nothing: it opens the draft pull "
            + "request only when you approve the changes."))
        job.setState(.awaitingReview)
    }

    nonisolated static let nothingChanged = "The agent finished without changing anything."

    // MARK: Cleaning up

    /// `cleanUp`, from a task that has been cancelled.
    ///
    /// A `git worktree remove` started from a cancelled task is killed the
    /// moment it starts (`Subprocess.lines` honours cancellation). An
    /// unstructured task does not inherit the cancellation, so the removal
    /// actually runs.
    func cleanUpDespiteCancellation(keep: Bool) async {
        let agent = self
        await Task { @MainActor in await agent.cleanUp(keep: keep) }.value
    }

    /// Remove the worktree, its scratch directory and its local branch,
    /// unless there is something in them worth looking at. Nothing was
    /// pushed, so nothing on GitHub is touched.
    func cleanUp(keep: Bool) async {
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
}
