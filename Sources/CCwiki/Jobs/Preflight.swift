import Foundation

/// Something CCwiki noticed before (or after) the agent ran.
struct PreflightFinding: Identifiable, Sendable {

    enum Level: Sendable {
        /// Context the agent should have; not a problem.
        case info
        /// Likely to cause a lint failure or a bad edit.
        case warning
        /// The job should not start.
        case blocking
    }

    let id = UUID()
    let level: Level
    let title: String
    let detail: String

    var symbolName: String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }
}

/// Checks CCwiki runs against the clone before launching a job.
///
/// Two reasons these live in Swift rather than in the prompt: they are cheap
/// and deterministic, and telling the agent what is already true is far more
/// reliable than asking it to go and find out. The findings are shown in the
/// launch sheet *and* pasted into the prompt.
enum Preflight {

    /// `repository` is where the pull request would go
    /// (`PublishTarget.repository`). The agent no longer pushes, but CCwiki
    /// does once the change is approved, and a credential needed at the end
    /// is checked at the beginning (plans/corrections.md §5.3).
    /// `isGitHubUnreachable` is gh's "could not ask", which is offline,
    /// never signed out (§7.1).
    static func run(
        submission: IngestSubmission,
        index: WikiIndex?,
        paths: AppPaths,
        tools: ToolLocator,
        isGitHubAuthenticated: Bool,
        isGitHubUnreachable: Bool = false,
        canPush: Bool = true,
        hasPushRights: Bool? = nil,
        repository: String = AppPaths.repositorySlug
    ) -> [PreflightFinding] {
        var findings: [PreflightFinding] = []

        // 1. Tooling. Reading works without any of this; ingesting does not.
        for tool in tools.missingForIngestion {
            findings.append(PreflightFinding(
                level: .blocking,
                title: "\(tool.rawValue) not found",
                detail: "CCwiki needs it for \(tool.purpose). "
                    + "Install it, or set its path in Settings."))
        }

        // 2. GitHub auth. The pull request opens only after review, and
        //    finding then that it cannot is a miserable way to learn this.
        //    A GitHub that could not be asked is not a "no": `gh auth
        //    login` cannot bring a network back.
        if tools.path(for: .gh) != nil, isGitHubUnreachable {
            findings.append(PreflightFinding(
                level: .blocking,
                title: "GitHub could not be reached",
                detail: "Offline, or GitHub did not answer, so CCwiki could not ask whether gh "
                    + "is signed in. Run the job again once you are connected."))
        } else if tools.path(for: .gh) != nil, !isGitHubAuthenticated {
            findings.append(PreflightFinding(
                level: .blocking,
                title: "GitHub CLI is not authenticated",
                detail: "Run `gh auth login` in a terminal. The account needs push access "
                    + "to open a pull request."))
        }

        // 3. Push credentials. `gh auth login` alone is not enough: a user
        //    whose git protocol is SSH has no HTTPS credential helper, and the
        //    push fails at the very end of a long job.
        if !canPush {
            findings.append(PreflightFinding(
                level: .blocking,
                title: "The clone cannot authenticate a push",
                detail: "Run `gh auth setup-git`, or let CCwiki configure a credential "
                    + "helper on its own clone by syncing again (⌘R)."))
        }

        // 3b. Push *rights*, asked of GitHub. A helper that exists is not a
        //     helper that works, and an account without write access finds
        //     out at the very end of the job otherwise.
        if hasPushRights == false {
            findings.append(PreflightFinding(
                level: .blocking,
                title: "The signed-in account cannot push to \(repository)",
                detail: "Opening the pull request pushes a branch to the wiki itself, so a "
                    + "fork is not enough. Ask for write access, or sign in to gh as an "
                    + "account that has it."))
        }

        // 4. The submodules the wiki's lint reads.
        let cryptobib = paths.clone.appending(path: "vendor/cryptobib/crypto.bib")
        if !FileManager.default.fileExists(atPath: cryptobib.path(percentEncoded: false)) {
            findings.append(PreflightFinding(
                level: .info,
                title: "CryptoBib is not checked out yet",
                detail: "The job will run `git submodule update --init` in its worktree. "
                    + "Without it the agent cannot look up a `cryptobib_key`, and inventing "
                    + "one is a lint failure."))
        }

        // 5. Does this paper already have a page?
        if let index, let source = submission.source {
            findings.append(contentsOf: existingPageFindings(for: source, in: index))
        }

        // 6. Is `npm ci` going to be needed? It is slow and needs network.
        let nodeModules = paths.clone.appending(path: "node_modules")
        if !FileManager.default.fileExists(atPath: nodeModules.path(percentEncoded: false)) {
            findings.append(PreflightFinding(
                level: .info,
                title: "Node dependencies are not installed",
                detail: "The job will run `npm ci` in its worktree before linting. "
                    + "That needs network and takes a minute or two."))
        }

        return findings
    }

    /// Look for a reference page that already cites this URL — the most useful
    /// single check, because a duplicate reference is both a lint error (alias
    /// collision) and wasted work.
    private static func existingPageFindings(
        for source: IngestSubmission.Source, in index: WikiIndex
    ) -> [PreflightFinding] {
        let canonical = source.canonicalURL
        let existing = index.pages.values.filter { page in
            guard page.kind == .reference, let pageSource = page.source else { return false }
            return normalize(pageSource) == normalize(canonical)
        }

        return existing.map { page in
            PreflightFinding(
                level: .warning,
                title: "Already in the wiki as \(page.title)",
                detail: "`\(page.path)` already points at this source. The agent should "
                    + "update that page rather than create a second one — or abort.")
        }
    }

    private static func normalize(_ url: String) -> String {
        var value = url.lowercased()
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// A rendering of the findings for the prompt, so the agent starts with
    /// what CCwiki already knows.
    static func promptSection(_ findings: [PreflightFinding]) -> String {
        guard !findings.isEmpty else {
            return "- Nothing flagged. No existing page cites this source, and the tooling "
                + "is all present."
        }
        return findings.map { finding in
            let marker = switch finding.level {
            case .info: "note"
            case .warning: "WARNING"
            case .blocking: "BLOCKING"
            }
            return "- **\(marker):** \(finding.title). \(finding.detail)"
        }.joined(separator: "\n")
    }
}

/// Is `gh` logged in? A definite answer is cached, because it does not
/// change mid-session; "could not ask" is not, so it is asked again.
///
/// `gh auth status` talks to the GitHub API, so it is `async` with a deadline:
/// it used to run synchronously on the main actor at launch, where a captive
/// portal or a slow network held the first window hostage.
enum GitHubAuth {

    /// The definite answer, behind a lock: gh is asked from any task.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Bool?

        var value: Bool? {
            get { lock.withLock { answer } }
            set { lock.withLock { answer = newValue } }
        }
    }

    /// One for the app, shared by every task. A test scopes its own with
    /// `$cache.withValue`, so tests running in parallel never see each
    /// other's answers. Child tasks and `Task {}` inherit the scope; only
    /// a detached task falls back to the app's.
    @TaskLocal static var cache: Cache = Cache()

    /// How long to wait on each of gh's answers before treating it as none.
    /// Task-local, as `cache` is: a test whose gh answers at once scopes a
    /// long one, so the deadline times gh and not how busy the test run is.
    @TaskLocal static var deadline: Duration = .seconds(15)

    /// The cached answer, or `signedIn`'s, which caches only a definite one.
    /// Nil, and not cached, when gh could not be asked (no gh, no network,
    /// no answer before the deadline), so the next ask tries again, and an
    /// unreachable GitHub reads as offline, not as signed out
    /// (plans/corrections.md §7.1).
    ///
    /// Not a bare `gh auth status`: that asks every host and account gh
    /// knows, and exits 1 when any of them has a problem (an expired
    /// Enterprise token, a host behind a VPN that is off, an inactive
    /// account's revoked token), and it reports a connection that fails at
    /// once as an invalid token. Either way a signed-in user read as signed
    /// out, cached for the session, Re-check included.
    static func isAuthenticated(tools: ToolLocator) async -> Bool? {
        if let known = cachedAnswer { return known }
        return await signedIn(tools: tools)
    }

    /// The definite answer last cached, if any.
    static var cachedAnswer: Bool? { cache.value }

    /// Whether the signed-in account may push to `repository`, asked of
    /// GitHub itself. `nil` when it could not be asked — no `gh`, no network,
    /// or no answer before the deadline. github.com by name: left to gh,
    /// the host is its default, which is an Enterprise host when that is
    /// the only one signed in.
    static func canPush(tools: ToolLocator, repository: String) async -> Bool? {
        guard let gh = tools.path(for: .gh) else { return nil }
        let environment = tools.childEnvironment()
        let result = await Subprocess.withDeadline(deadline) {
            await Subprocess.run(
                executable: gh,
                arguments: ["api", "repos/\(repository)", "--hostname", "github.com",
                            "--jq", ".permissions.push"],
                environment: environment)
        }
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Call after the user has been told to run `gh auth login`.
    static func invalidate() { cache.value = nil }
}

extension GitHubAuth {
    /// `gh auth status`, asked afresh: nil on a timeout, so an unreachable
    /// GitHub reads as offline, not as signed out (plans/corrections.md
    /// §7.1). Nil, too, without `gh`: it could not be asked, and
    /// `GitHubAccess.classify` says gh is missing.
    ///
    /// Not cached, so signing in mid-session is seen at the next ask; a
    /// definite answer refreshes `isAuthenticated`'s cache.
    ///
    /// `gh auth status` reports a timeout as one, but a connection that
    /// fails at once (no network, DNS) as an invalid token, and so is an
    /// error from GitHub's API (a 502 or 503). So when it fails in words
    /// that are not a network's, one cheap API call that needs both the
    /// network and a github.com token decides between them (`verdict`):
    /// `gh api user`. Not `rate_limit`, which GitHub answers without a
    /// token, so an account signed in only to an Enterprise host read as
    /// signed in to github.com.
    static func signedIn(tools: ToolLocator) async -> Bool? {
        guard let gh = tools.path(for: .gh) else { return nil }
        let environment = tools.childEnvironment()

        func ask(_ arguments: [String]) async -> Subprocess.Result? {
            await Subprocess.withDeadline(deadline) {
                await Subprocess.run(executable: gh, arguments: arguments, environment: environment)
            }
        }

        guard let status = await ask(["auth", "status", "--hostname", "github.com"]) else {
            return nil
        }
        var probe: Subprocess.Result?
        if needsProbe(status) {
            probe = await ask(["api", "--hostname", "github.com", "user", "--jq", ".login"])
        }
        let answer = verdict(status: status, probe: probe)

        // A "no" from a cancelled task is not an answer either: its `gh`
        // was stopped, not refused.
        if let answer, !Task.isCancelled { cache.value = answer }
        return answer
    }

    /// Whether `gh auth status` failed in words that are not a network's,
    /// so the API probe must decide.
    static func needsProbe(_ status: Subprocess.Result) -> Bool {
        !status.succeeded && !isNetworkFailure(status.stdout + "\n" + status.stderr)
    }

    /// What `gh auth status` and the probe said, pure: true or false when
    /// gh says so, nil when GitHub could not be asked. `probe` is nil when
    /// it was not run or had no answer before the deadline. Only a refused
    /// token is "signed out": any other failure of the probe, a GitHub
    /// outage's 5xx or a proxy's refusal, is not knowing.
    static func verdict(status: Subprocess.Result, probe: Subprocess.Result?) -> Bool? {
        if status.succeeded { return true }
        guard let probe else { return nil }
        if probe.succeeded { return true }
        return isSignedOut(probe) ? false : nil
    }

    /// gh's refusal of the token: exit 4, which is gh's for "no
    /// credentials" (its message names `gh auth login`), or GitHub's 401,
    /// for a bad token or none at all ("Requires authentication").
    static func isSignedOut(_ result: Subprocess.Result) -> Bool {
        if result.status == 4 { return true }
        let lowered = (result.stdout + "\n" + result.stderr).lowercased()
        return ["http 401", "bad credentials", "gh auth login"].contains { lowered.contains($0) }
    }

    /// `gh`'s words, and git's, for "GitHub could not be reached".
    static func isNetworkFailure(_ output: String) -> Bool {
        if GitService.isNetworkFailure(output) { return true }
        let lowered = output.lowercased()
        return ["error connecting to", "timeout", "timed out", "no such host", "dial tcp",
                "tls handshake", "i/o timeout", "proxyconnect",
        ].contains { lowered.contains($0) }
    }
}

/// Whether a correction can become a pull request now (plans/corrections.md
/// §7.1). Editing needs no network; opening the pull request does, so the
/// editor and the review say which of these is in the way, and Approve asks
/// again.
enum GitHubAccess: Sendable, Equatable {
    case ready
    /// A timeout, a network failure, or an error from GitHub other than a
    /// refused token (a 5xx, a proxy's refusal).
    case offline
    case ghMissing
    case notSignedIn
    case cannotPush(repository: String)

    /// The banner the editor and the review show. Nil when ready.
    var banner: String? {
        switch self {
        case .ready:
            return nil
        case .offline:
            return "Offline. You can edit now; opening the pull request needs a connection."
        case .ghMissing:
            // Not "or open an issue": opening one needs gh too.
            return "gh is not installed, so this cannot become a pull request yet. "
                + "Install it with Homebrew (brew install gh), then check again."
        case .notSignedIn:
            return "gh is not signed in. Run gh auth login in Terminal, then check again."
        case .cannotPush(let repository):
            return "The signed-in account cannot push to \(repository), so this cannot "
                + "become a pull request. Open an issue instead."
        }
    }

    /// Pure. `signedIn` and `canPush` are nil when gh could not be asked,
    /// which is offline, never signed out.
    static func classify(
        ghPresent: Bool, signedIn: Bool?, canPush: Bool?, repository: String
    ) -> GitHubAccess {
        guard ghPresent else { return .ghMissing }
        guard let signedIn else { return .offline }
        guard signedIn else { return .notSignedIn }
        guard let canPush else { return .offline }
        return canPush ? .ready : .cannotPush(repository: repository)
    }
}
