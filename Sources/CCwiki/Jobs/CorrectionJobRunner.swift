import Foundation

/// Runs one described correction (route b), up to the review
/// (plans/corrections.md §5.4).
///
/// ```
/// git rev-parse --verify <target.baseCommit>^{commit}   (the commit the reader rendered)
/// git worktree add ../worktrees/<id> -b fix/<slug> <base>
/// claude -p "<prompts/correct.md, composed>" --model sonnet
///   --strict-mcp-config --setting-sources project
///   --allowedTools Read,Edit,Write,Glob,Grep --max-turns 20   (sealed)
/// the tripwire, the hand-over file, the change               → awaiting review
/// ```
///
/// A small, cheap job: no submodules, no `npm ci`, no `Bash`, no web, so the
/// worktree comes up in a second or two and the agent edits one page. The
/// one-page rule is enforced at review, where DiffGuard warns on any other
/// page and blocks anything outside `content/`. Everything from the worktree
/// on is `AgentRun`'s, which an ingestion shares.
@MainActor
struct CorrectionJobRunner {

    let paths: AppPaths
    let tools: ToolLocator
    let git: GitService
    /// The `--model` alias; "" for the claude CLI's default.
    let model: String
    /// Where the pull request would go: the tripwire watches it. The app's
    /// own target unless told otherwise.
    var target = PublishTarget.resolve(
        channel: BuildIdentity.current, environment: ProcessInfo.processInfo.environment)

    /// A correction is a line or two; twenty turns is room to read the
    /// contract, the page and the macros, edit, and write the hand-over.
    static var maxTurns: String {
        ProcessInfo.processInfo.environment["CCWIKI_CORRECTION_MAX_TURNS"] ?? "20"
    }

    func run(_ job: Job) async {
        guard case .correction(let request) = job.kind else {
            job.setState(.failed("This job is not a correction."))
            return
        }
        let page = request.target
        job.setState(.preparing("Checking…"))

        // The sheet refuses all of these first; a job run again later may
        // find the world changed.
        if let refusal = Self.storeRefusal(paths.wikiStore) {
            job.setState(.failed(refusal))
            return
        }
        guard page.region == .body else {
            job.setState(.failed(page.region == .frontmatter
                ? CorrectionBlockers.frontmatterLine : CorrectionBlockers.generated))
            return
        }
        guard let claude = tools.path(for: .claude) else {
            job.setState(.failed("The claude CLI was not found."))
            return
        }

        // MARK: Worktree

        job.setState(.preparing("Creating worktree…"))
        // The commit the reader rendered, not origin/main: the lines were
        // read from that commit's file, so the worktree starts there (§3.5).
        guard let base = await git.resolveCommit(page.baseCommit, in: paths.clone) else {
            if Task.isCancelled { return }
            job.setState(.failed(
                "The commit the page was read at, \(page.baseCommit.prefix(12)), is not in the "
                + "wiki's clone. Sync (⌘R), then describe the correction again."))
            return
        }
        job.setBaseCommit(base)

        let agent = AgentRun(paths: paths, tools: tools, git: git, target: target, job: job)
        guard await agent.addWorktree(base: base, describing: nil) else { return }

        // MARK: Prompt

        let siteURL = Self.siteURL(for: page)
        let prompt: String
        do {
            prompt = try PromptComposer.composeCorrection(request, job: job, siteURL: siteURL)
        } catch {
            job.append(JobLogEntry(.error, error.localizedDescription))
            await agent.cleanUp(keep: true)
            job.setState(.failed(error.localizedDescription))
            return
        }
        job.append(JobLogEntry(.system,
            "Prompt composed from prompts/correct.md for \(page.repositoryPath), "
            + "\(page.lines?.label ?? "the whole page") (\(prompt.count) characters)."))

        // MARK: The agent

        let invocation = AgentInvocation.correction(
            prompt: prompt, model: model, maxTurns: Self.maxTurns,
            base: tools.childEnvironment(), scratch: job.scratch)
        job.append(JobLogEntry(.system, model.isEmpty
            ? "Running claude with the CLI's default model."
            : "Running claude with --model \(model)."))
        await agent.run(invocation, claude: claude, base: base, siteURL: siteURL)
    }

    /// The page on cryptology.city, without an anchor: the prompt and the
    /// proposed pull request add the section.
    nonisolated static func siteURL(for target: CorrectionTarget) -> URL? {
        AppModel.siteURL(slug: QuartzSlug.slugifyFilePath(target.pagePath))
    }

    nonisolated static let snapshotStore = "This copy of the wiki is a snapshot. Sync (⌘R) to "
        + "replace it with a git clone."
    nonisolated static let notCloned = "The wiki has not been cloned yet. Sync first (⌘R)."

    /// Why no job can run on the wiki as it is kept: a job's worktree is
    /// made from the clone's git, which a snapshot has not got, and before
    /// the first sync, or after a reset, nothing is there at all. Nil for a
    /// clone.
    nonisolated static func storeRefusal(_ store: AppPaths.WikiStore) -> String? {
        switch store {
        case .git: return nil
        case .snapshot: return snapshotStore
        case .none: return notCloned
        }
    }
}
