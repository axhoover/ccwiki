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

    static func run(
        submission: IngestSubmission,
        index: WikiIndex?,
        paths: AppPaths,
        tools: ToolLocator,
        canPush: Bool = true
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

        // 2. GitHub auth. `gh pr create` failing at the very end of a long job
        //    is a miserable way to find this out.
        if tools.path(for: .gh) != nil, !GitHubAuth.isAuthenticated(tools: tools) {
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

/// Is `gh` logged in? Cached, because the answer does not change mid-session
/// and `gh auth status` costs about a hundred milliseconds.
enum GitHubAuth {

    nonisolated(unsafe) private static var cached: Bool?
    private static let lock = NSLock()

    static func isAuthenticated(tools: ToolLocator) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let gh = tools.path(for: .gh) else {
            cached = false
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "status"]
        process.environment = tools.childEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            cached = process.terminationStatus == 0
        } catch {
            cached = false
        }
        return cached ?? false
    }

    /// Call after the user has been told to run `gh auth login`.
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
