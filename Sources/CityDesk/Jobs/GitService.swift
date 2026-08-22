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
        case failed(String)

        var isSuccess: Bool {
            if case .failed = self { return false }
            return true
        }

        var summary: String {
            switch self {
            case .cloned: "Cloned the wiki."
            case .updated(let from, let to): "Updated \(from.prefix(7)) → \(to.prefix(7))."
            case .alreadyCurrent(let at): "Already up to date at \(at.prefix(7))."
            case .failed(let message): message
            }
        }
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
            let status = await stream(
                ["clone", "--progress", remote, clone.path(percentEncoded: false)],
                in: nil, onLine: onLine)
            guard status == 0 else { return .failed("git clone failed (exit \(status)).") }
            return .cloned
        }

        let before = await head(in: clone) ?? ""
        let fetch = await stream(
            ["-C", clone.path(percentEncoded: false), "fetch", "--progress", "--prune", "origin"],
            in: nil, onLine: onLine)
        guard fetch == 0 else {
            return .failed("git fetch failed (exit \(fetch)) — working offline from the last pull.")
        }

        let merge = await stream(
            ["-C", clone.path(percentEncoded: false), "merge", "--ff-only", "@{u}"],
            in: nil, onLine: onLine)
        guard merge == 0 else {
            return .failed(
                "Fast-forward failed. The reader's clone at \(clone.lastPathComponent) has "
                + "diverged from origin — CityDesk never writes there, so something else did. "
                + "Resolve it by hand, or delete the clone and let CityDesk re-clone.")
        }

        let after = await head(in: clone) ?? ""
        return before == after ? .alreadyCurrent(at: after) : .updated(from: before, to: after)
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
        ], in: nil, onLine: onLine)
        return status == 0
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
        ], in: nil, onLine: onLine)
        return status == 0
    }

    // MARK: Plumbing

    private func run(_ arguments: [String]) async -> Subprocess.Result {
        await Subprocess.run(
            executable: executable, arguments: arguments, environment: environment)
    }

    private func stream(
        _ arguments: [String], in directory: URL?, onLine: @Sendable (ProcessLine) -> Void
    ) async -> Int32 {
        var status: Int32 = -1
        for await line in Subprocess.lines(
            executable: executable, arguments: arguments,
            currentDirectory: directory, environment: environment
        ) {
            if let exit = line.exitStatus { status = exit; continue }
            onLine(line)
        }
        return status
    }
}
