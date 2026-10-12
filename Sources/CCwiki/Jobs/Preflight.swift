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
    static func run(
        submission: IngestSubmission,
        index: WikiIndex?,
        paths: AppPaths,
        tools: ToolLocator,
        isGitHubAuthenticated: Bool,
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
        if tools.path(for: .gh) != nil, !isGitHubAuthenticated {
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

/// Is `gh` logged in? Cached, because the answer does not change mid-session.
///
/// `gh auth status` talks to the GitHub API, so it is `async` with a deadline:
/// it used to run synchronously on the main actor at launch, where a captive
/// portal or a slow network held the first window hostage.
enum GitHubAuth {

    nonisolated(unsafe) private static var cached: Bool?
    private static let lock = NSLock()

    /// How long to wait on `gh auth status` before treating it as a "no".
    static let deadline: Duration = .seconds(15)

    static func isAuthenticated(tools: ToolLocator) async -> Bool {
        if let known = lock.withLock({ cached }) { return known }

        // Not cached: `gh` may turn up later in discovery.
        guard let gh = tools.path(for: .gh) else { return false }
        let environment = tools.childEnvironment()

        let answer: Bool? = await Subprocess.withDeadline(deadline) {
            await Subprocess.run(
                executable: gh, arguments: ["auth", "status"], environment: environment
            ).succeeded
        }

        // A timeout is not an answer, so it is not cached either.
        if let answer {
            lock.withLock { cached = answer }
        }
        return answer ?? false
    }

    /// Whether the signed-in account may push to `repository`, asked of
    /// GitHub itself. `nil` when it could not be asked — no `gh`, no network,
    /// or no answer before the deadline.
    static func canPush(tools: ToolLocator, repository: String) async -> Bool? {
        guard let gh = tools.path(for: .gh) else { return nil }
        let environment = tools.childEnvironment()
        let result = await Subprocess.withDeadline(deadline) {
            await Subprocess.run(
                executable: gh,
                arguments: ["api", "repos/\(repository)", "--jq", ".permissions.push"],
                environment: environment)
        }
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Call after the user has been told to run `gh auth login`.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}

extension GitHubAuth {
    /// `gh auth status`: nil on a timeout, unlike `isAuthenticated`'s false,
    /// so an unreachable GitHub reads as offline, not as signed out
    /// (plans/corrections.md §7.1). Nil, too, without `gh`: it could not be
    /// asked, and `GitHubAccess.classify` says gh is missing.
    ///
    /// Not cached, so signing in mid-session is seen at the next ask; a
    /// definite answer refreshes `isAuthenticated`'s cache.
    ///
    /// `gh auth status` reports a timeout as one, but a connection that
    /// fails at once (no network, DNS) as an invalid token. So when it fails
    /// in words that are not a network's, one cheap API call that needs both
    /// the network and a valid token decides between the two.
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
        var answer: Bool?
        if status.succeeded {
            answer = true
        } else if !isNetworkFailure(status.stdout + "\n" + status.stderr),
                  let probe = await ask([
                      "api", "--hostname", "github.com", "rate_limit", "--jq", ".rate.limit",
                  ]) {
            if probe.succeeded {
                answer = true
            } else if !isNetworkFailure(probe.stdout + "\n" + probe.stderr) {
                answer = false
            }
        }

        if let answer {
            lock.withLock { cached = answer }
        }
        return answer
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
    /// A timeout, or a network failure.
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
