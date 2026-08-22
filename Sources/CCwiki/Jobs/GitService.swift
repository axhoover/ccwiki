import Foundation

/// Every `git` invocation the app makes.
///
/// The reader's contract, from the app's design: the clone is **pull-only**.
/// This type will fast-forward it, read from it, and add worktrees to it — it
/// will never commit, never create a branch in it, and never write content
/// into it. Ingestion work happens in a worktree, which has its own working
/// directory and cannot dirty the reader's.
struct GitService: Sendable {

    let executable: String
    let environment: [String: String]

    enum SyncOutcome: Sendable {
        case cloned
        case updated(from: String, to: String)
        case alreadyCurrent(at: String)
        /// The network is unreachable. Distinguished from `failed` because it
        /// is not a problem with anything the user did, and because reading
        /// continues to work perfectly — the right response is a quiet note,
        /// not an alarm.
        case offline
        case failed(String)

        var isSuccess: Bool {
            switch self {
            case .cloned, .updated, .alreadyCurrent: true
            case .offline, .failed: false
            }
        }

        var summary: String {
            switch self {
            case .cloned: "Cloned the wiki."
            case .updated(let from, let to): "Updated \(from.prefix(7)) → \(to.prefix(7))."
            case .alreadyCurrent(let at): "Already up to date at \(at.prefix(7))."
            case .offline: "Offline — reading from the last pull."
            case .failed(let message): message
            }
        }
    }

    /// git's vocabulary for "there is no network". Matched on the message
    /// rather than the exit code because git reports all of these as 128.
    static func isNetworkFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return ["could not resolve host", "could not resolve proxy",
                "failed to connect", "connection refused", "network is unreachable",
                "operation timed out", "temporary failure in name resolution",
                "no route to host", "unable to access"].contains { lowered.contains($0) }
    }

    // MARK: Sync

    /// Clone if the directory is empty, otherwise fast-forward.
    ///
    /// `--ff-only` is the whole point: a non-fast-forward means somebody has
    /// written to the reader's clone, which should never happen, and the right
    /// response is to say so rather than to merge.
    func sync(clone: URL, remote: String, onLine: @Sendable (ProcessLine) -> Void) async
        -> SyncOutcome {
        let exists = FileManager.default.fileExists(
            atPath: clone.appending(path: ".git").path(percentEncoded: false))

        if !exists {
            try? FileManager.default.createDirectory(
                at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
            let clone = await stream(
                ["clone", "--progress", remote, clone.path(percentEncoded: false)],
                in: nil, onLine: onLine)
            let (status, transcript) = (clone.status, clone.transcript)
            guard status == 0 else {
                // With no clone there is nothing to read, so this one *is* an
                // alarm however it failed.
                return .failed(Self.isNetworkFailure(transcript)
                    ? "Could not reach GitHub to clone the wiki. Check your connection "
                        + "and sync again."
                    : "git clone failed (exit \(status)). See the sync log.")
            }
            return .cloned
        }

        let before = await head(in: clone) ?? ""
        let fetch = await stream(
            ["-C", clone.path(percentEncoded: false), "fetch", "--progress", "--prune", "origin"],
            in: nil, onLine: onLine)
        guard fetch.status == 0 else {
            // There is a clone on disk, so reading is unaffected either way.
            return Self.isNetworkFailure(fetch.transcript)
                ? .offline
                : .failed("git fetch failed (exit \(fetch.status)). See the sync log.")
        }

        let merge = await stream(
            ["-C", clone.path(percentEncoded: false), "merge", "--ff-only", "@{u}"],
            in: nil, onLine: onLine).status
        guard merge == 0 else {
            return .failed(
                "Fast-forward failed. The reader's clone at \(clone.lastPathComponent) has "
                + "diverged from origin — CCwiki never writes there, so something else did. "
                + "Resolve it by hand, or delete the clone and let CCwiki re-clone.")
        }

        let after = await head(in: clone) ?? ""
        return before == after ? .alreadyCurrent(at: after) : .updated(from: before, to: after)
    }

    /// Teach *this clone* to authenticate HTTPS pushes through `gh`.
    ///
    /// `gh auth login` does not necessarily configure git: a user whose
    /// preferred protocol is SSH has a working `gh` and no HTTPS credential
    /// helper at all, so `git push` over HTTPS fails with "could not read
    /// Username" — at the very end of a long ingestion job, after the agent has
    /// done all the work.
    ///
    /// Written to the clone's **local** config, never `--global`: this clone is
    /// CCwiki's own artifact, and reaching into the user's global git config
    /// to fix our problem would be rude.
    func configureCredentialHelper(clone: URL, ghPath: String) async {
        let key = "credential.https://github.com.helper"
        let existing = await run([
            "-C", clone.path(percentEncoded: false), "config", "--local", "--get", key,
        ])
        guard !existing.succeeded
            || existing.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        _ = await run([
            "-C", clone.path(percentEncoded: false),
            "config", "--local", key, "!\(ghPath) auth git-credential",
        ])
    }

    /// Is the clone able to push? Cheap proxy: a credential helper is
    /// configured, or the remote is SSH (where the agent's own keys apply).
    func canAuthenticatePush(clone: URL) async -> Bool {
        let remote = await run([
            "-C", clone.path(percentEncoded: false), "remote", "get-url", "origin",
        ])
        if remote.succeeded, remote.stdout.contains("git@") { return true }

        let helper = await run([
            "-C", clone.path(percentEncoded: false),
            "config", "--get-urlmatch", "credential.helper", "https://github.com",
        ])
        return helper.succeeded
            && !helper.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Queries

    func head(in clone: URL) async -> String? {
        let result = await run(["-C", clone.path(percentEncoded: false), "rev-parse", "HEAD"])
        return result.succeeded ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func defaultBranch(in clone: URL) async -> String {
        let result = await run([
            "-C", clone.path(percentEncoded: false),
            "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
        ])
        guard result.succeeded else { return AppPaths.defaultBranch }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.components(separatedBy: "/").last ?? AppPaths.defaultBranch
    }

    /// Last-modified time per content file, from one `git log` sweep rather
    /// than one process per file.
    ///
    /// Quartz's `CreatedModifiedDate` prefers frontmatter, then git, then the
    /// filesystem; almost no page carries a date, so in practice this is the
    /// date the site shows.
    func modifiedDates(in clone: URL) async -> [String: Date] {
        let result = await run([
            "-C", clone.path(percentEncoded: false),
            "log", "--name-only", "--no-merges", "--format=%x00%ct", "--", "content",
        ])
        guard result.succeeded else { return [:] }

        var dates: [String: Date] = [:]
        var current: Date?
        for line in result.stdout.components(separatedBy: "\n") {
            if line.hasPrefix("\u{0}") {
                current = TimeInterval(line.dropFirst()).map(Date.init(timeIntervalSince1970:))
                continue
            }
            guard let current, line.hasPrefix("content/") else { continue }
            let relative = String(line.dropFirst("content/".count))
            // `git log` is newest-first, so the first sighting wins.
            if dates[relative] == nil { dates[relative] = current }
        }
        return dates
    }

    /// `true` when the working tree has uncommitted changes.
    func isDirty(_ directory: URL) async -> Bool {
        let result = await run([
            "-C", directory.path(percentEncoded: false), "status", "--porcelain",
        ])
        return result.succeeded && !result.stdout.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Worktrees

    /// Create a worktree for an ingestion job, on a fresh branch off
    /// `origin/<default>`.
    ///
    /// The worktree lives outside the clone directory, has its own working
    /// copy, and shares only the object database — so a job can check out,
    /// edit, commit and push without the reader's checkout changing under the
    /// user's cursor, and several jobs can run at once.
    func addWorktree(
        clone: URL, at path: URL, branch: String, baseRef: String,
        onLine: @Sendable (ProcessLine) -> Void
    ) async -> Bool {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let status = await stream([
            "-C", clone.path(percentEncoded: false),
            "worktree", "add", path.path(percentEncoded: false), "-b", branch, baseRef,
        ], in: nil, onLine: onLine).status
        return status == 0
    }

    /// `preferred`, or `preferred-2`, `preferred-3`… — the first name no local
    /// or remote branch already claims.
    func availableBranchName(clone: URL, preferred: String) async -> String {
        func exists(_ name: String) async -> Bool {
            let result = await run([
                "-C", clone.path(percentEncoded: false),
                "rev-parse", "--verify", "--quiet", "refs/heads/\(name)",
            ])
            if result.succeeded { return true }
            let remote = await run([
                "-C", clone.path(percentEncoded: false),
                "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(name)",
            ])
            return remote.succeeded
        }

        guard await exists(preferred) else { return preferred }
        for suffix in 2...99 {
            let candidate = "\(preferred)-\(suffix)"
            if await !exists(candidate) { return candidate }
        }
        return "\(preferred)-\(UUID().uuidString.prefix(8))"
    }

    /// Re-register worktrees whose directory has moved.
    ///
    /// A worktree records its own absolute path in two places, so moving one
    /// leaves git unable to find it. `git worktree repair` fixes both sides,
    /// and is a no-op when nothing moved — cheap enough to run on every sync.
    func repairWorktrees(clone: URL, worktreeRoot: URL) async {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: worktreeRoot, includingPropertiesForKeys: nil)) ?? []
        guard !entries.isEmpty else { return }

        _ = await run(["-C", clone.path(percentEncoded: false), "worktree", "repair"]
            + entries.map { $0.path(percentEncoded: false) })
        _ = await run(["-C", clone.path(percentEncoded: false), "worktree", "prune"])
    }

    func removeWorktree(clone: URL, at path: URL, force: Bool) async -> Bool {
        var arguments = [
            "-C", clone.path(percentEncoded: false),
            "worktree", "remove", path.path(percentEncoded: false),
        ]
        if force { arguments.append("--force") }
        let result = await run(arguments)
        if !result.succeeded {
            // A worktree whose directory is already gone needs pruning instead.
            _ = await run(["-C", clone.path(percentEncoded: false), "worktree", "prune"])
        }
        return result.succeeded
    }

    /// Worktrees git still knows about — used on relaunch to recover from a
    /// crash mid-job.
    func listWorktrees(clone: URL) async -> [(path: String, branch: String?)] {
        let result = await run([
            "-C", clone.path(percentEncoded: false), "worktree", "list", "--porcelain",
        ])
        guard result.succeeded else { return [] }

        var worktrees: [(String, String?)] = []
        var path: String?
        var branch: String?
        for line in result.stdout.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let path { worktrees.append((path, branch)) }
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        if let path { worktrees.append((path, branch)) }
        // The first entry is the main clone itself.
        return Array(worktrees.dropFirst())
    }

    /// Init or update the two submodules (`vendor/cryptobib`,
    /// `vendor/microcrypt-zoo`). A fresh worktree has empty submodule
    /// directories, and the wiki's lint greps `vendor/cryptobib/crypto.bib` for
    /// citation keys.
    func updateSubmodules(in directory: URL, onLine: @Sendable (ProcessLine) -> Void) async -> Bool {
        let status = await stream([
            "-C", directory.path(percentEncoded: false),
            "submodule", "update", "--init", "--depth", "1", "--recursive",
        ], in: nil, onLine: onLine).status
        return status == 0
    }

    // MARK: Plumbing

    private func run(_ arguments: [String]) async -> Subprocess.Result {
        await Subprocess.run(
            executable: executable, arguments: arguments, environment: environment)
    }

    /// Run git, forwarding each line to `onLine` and keeping a copy.
    ///
    /// The transcript is accumulated here rather than in the caller's closure
    /// because that closure is `@Sendable` — it runs on the reader's dispatch
    /// queue and cannot capture a mutable local.
    @discardableResult
    private func stream(
        _ arguments: [String], in directory: URL?, onLine: @Sendable (ProcessLine) -> Void
    ) async -> (status: Int32, transcript: String) {
        var status: Int32 = -1
        var transcript: [String] = []
        for await line in Subprocess.lines(
            executable: executable, arguments: arguments,
            currentDirectory: directory, environment: environment
        ) {
            if let exit = line.exitStatus { status = exit; continue }
            transcript.append(line.text)
            onLine(line)
        }
        return (status, transcript.joined(separator: "\n"))
    }
}
