import Foundation

/// Every `git` invocation the app makes.
///
/// The reader's contract, from the app's design: the clone is **pull-only**.
/// This type will fast-forward it, read from it, and add worktrees to it — it
/// will never commit to its checkout, and never write content into it. A
/// job's work happens in a worktree, which has its own working directory
/// and its own branch, and cannot dirty the reader's. Only CCwiki's own
/// commands commit or push there, and only once a person has approved the
/// change (plans/corrections.md §5).
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
    ///
    /// Deliberately *not* on "unable to access": git prefixes every HTTP
    /// failure with it — a 403, a certificate problem, a proxy refusing —
    /// and those are faults to show, not outages to sit through quietly.
    static func isNetworkFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return ["could not resolve host", "could not resolve proxy",
                "failed to connect", "connection refused", "network is unreachable",
                "operation timed out", "temporary failure in name resolution",
                "no route to host", "connection reset by peer", "network is down",
        ].contains { lowered.contains($0) }
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
            // Clone beside the destination and move it into place. git
            // creates `.git` first, so a clone interrupted midway used to
            // look like a clone, and the next sync tried to fast-forward a
            // repository with no HEAD and blamed the user for it.
            let manager = FileManager.default
            let parent = clone.deletingLastPathComponent()
            let partial = parent.appending(path: clone.lastPathComponent + ".partial")
            try? manager.createDirectory(at: parent, withIntermediateDirectories: true)
            try? manager.removeItem(at: partial)

            let result = await stream(
                ["clone", "--progress", remote, partial.path(percentEncoded: false)],
                in: nil, onLine: onLine)
            let (status, transcript) = (result.status, result.transcript)
            guard status == 0 else {
                try? manager.removeItem(at: partial)
                // With no clone there is nothing to read, so this one *is* an
                // alarm however it failed.
                return .failed(Self.isNetworkFailure(transcript)
                    ? "Could not reach GitHub to clone the wiki. Check your connection "
                        + "and sync again."
                    : "git clone failed (exit \(status)). See the sync log.")
            }
            // Whatever is at the destination has no `.git`, so it is not a clone.
            try? manager.removeItem(at: clone)
            do {
                try manager.moveItem(at: partial, to: clone)
            } catch {
                return .failed("The clone finished but could not be moved into place: "
                    + error.localizedDescription)
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
                + "Resolve it by hand, or use Reset Clone in Settings > Storage.")
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

    /// The wiki pages a pull changed: `content/…/*.md` paths that differ
    /// between two commits, relative to `content/`.
    func changedPages(in clone: URL, from before: String, to after: String) async -> [String] {
        let result = await run([
            "-C", clone.path(percentEncoded: false),
            "diff", "--name-only", before, after, "--", "content",
        ])
        guard result.succeeded else { return [] }
        return Self.pagePaths(fromDiff: result.stdout)
    }

    /// `git diff --name-only` output → the `.md` pages under `content/`.
    static func pagePaths(fromDiff output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("content/") && $0.hasSuffix(".md") }
            .map { String($0.dropFirst("content/".count)) }
    }

    /// "Wiki updated: 4 pages changed." — what a reader wants to know about a
    /// pull, in place of two commit hashes.
    static func updateSummary(changedPages count: Int) -> String {
        switch count {
        case 0: "Wiki updated."
        case 1: "Wiki updated: 1 page changed."
        default: "Wiki updated: \(count) pages changed."
        }
    }

    /// When the checked-out commit was made — "the wiki as of", for the
    /// status bar, which is more use to a reader than a hash.
    func headDate(in clone: URL) async -> Date? {
        let result = await run([
            "-C", clone.path(percentEncoded: false), "log", "-1", "--format=%ct",
        ])
        guard result.succeeded,
              let seconds = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
    /// than one process per file: the latest committer date among the
    /// non-merge commits that touch it under `content/`.
    ///
    /// Quartz's `CreatedModifiedDate` prefers frontmatter, then git, then the
    /// filesystem; almost no page carries a date, so in practice this is the
    /// date the site shows.
    func modifiedDates(in clone: URL) async -> [String: Date] {
        await modifiedDates(in: clone, range: nil) ?? [:]
    }

    /// The same, over only the commits HEAD has and `base` does not: what a
    /// pull brought. Merged with the dates at `base`, the later date winning,
    /// it equals the whole-history sweep at HEAD
    /// (plans/reader-comforts.md §3.7). Nil when git cannot answer, as when
    /// `base` is not in this clone.
    func modifiedDates(in clone: URL, since base: String) async -> [String: Date]? {
        await modifiedDates(in: clone, range: "\(base)..HEAD")
    }

    private func modifiedDates(in clone: URL, range: String?) async -> [String: Date]? {
        // Paths come back as UTF-8 rather than octal-escaped in quotes, so a
        // page named with an accent is dated too.
        var arguments = [
            "-C", clone.path(percentEncoded: false), "-c", "core.quotePath=false",
            "log", "--name-only", "--no-merges", "--format=%x00%ct",
        ]
        if let range { arguments.append(range) }
        arguments += ["--", "content"]
        let result = await run(arguments)
        guard result.succeeded else { return nil }
        return Self.modifiedDates(fromLog: result.stdout)
    }

    /// `git log --name-only --format=%x00%ct` output → each `content/` file,
    /// relative to `content/`, and the latest date among the commits that
    /// list it. The latest, not the first listed: the two agree in a linear
    /// history, but only the latest makes merging a pulled range into
    /// earlier dates exact when a merged branch carries older dates.
    static func modifiedDates(fromLog output: String) -> [String: Date] {
        var dates: [String: Date] = [:]
        var current: Date?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("\u{0}") {
                current = TimeInterval(line.dropFirst()).map(Date.init(timeIntervalSince1970:))
                continue
            }
            guard let current, line.hasPrefix("content/") else { continue }
            let relative = String(line.dropFirst("content/".count))
            if let known = dates[relative], known >= current { continue }
            dates[relative] = current
        }
        return dates
    }

    /// Whether `head` has `base` in its history (or is it): whether dates
    /// kept at `base` can be brought forward to `head` by a range.
    func isAncestor(_ base: String, of head: String, in clone: URL) async -> Bool {
        await run([
            "-C", clone.path(percentEncoded: false), "merge-base", "--is-ancestor", base, head,
        ]).succeeded
    }

    /// `true` when the working tree has uncommitted changes.
    func isDirty(_ directory: URL) async -> Bool {
        let result = await run([
            "-C", directory.path(percentEncoded: false), "status", "--porcelain",
        ])
        return result.succeeded && !result.stdout.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Worktrees

    /// Create a worktree for a job, on a fresh branch at `baseRef`: the
    /// commit `origin/<default>` named when the job started, which the job
    /// records as its base (plans/corrections.md §5.3).
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

    // MARK: Review (plans/corrections.md §6, §11.6)
    //
    // A job's worktree is the only place these write. They never touch the
    // reader's clone except to add, prune and delete a job's own worktree and
    // branch. Every read of file contents, `-z` output or a patch goes through
    // `Subprocess.runData`, so no line splitting touches the bytes (§6.1).

    /// `rev-parse --verify <ref>^{commit}`: the commit `ref` names, in full.
    /// A job's base is recorded as one, never as a ref, so a sync during
    /// review cannot move it (§5.3).
    func resolveCommit(_ ref: String, in directory: URL) async -> String? {
        let result = await run([
            "-C", directory.path(percentEncoded: false),
            "rev-parse", "--verify", "--quiet", "\(ref)^{commit}",
        ])
        return result.succeeded ? Self.nonEmpty(result.stdout) : nil
    }

    func mergeBase(_ a: String, _ b: String, in directory: URL) async -> String? {
        let result = await run([
            "-C", directory.path(percentEncoded: false), "merge-base", a, b,
        ])
        return result.succeeded ? Self.nonEmpty(result.stdout) : nil
    }

    /// Stages everything in the worktree except `.ccwiki/`, where the agent
    /// leaves its pull request text and any scratch output (§5.2). An agent
    /// that staged or committed something there despite the deny-list has it
    /// taken out of the index again (the files stay on disk), so nothing in
    /// it can reach a pull request.
    func stageAll(in worktree: URL) async -> Bool {
        let path = worktree.path(percentEncoded: false)
        guard await run([
            "-C", path, "add", "-A", "--", ".", ":(exclude)\(Handover.directory)",
        ]).succeeded else { return false }
        return await run([
            "-C", path, "rm", "-r", "--cached", "--force", "--quiet", "--ignore-unmatch", "--",
            Handover.directory,
        ]).succeeded
    }

    /// What is staged against `base`, as three byte-exact outputs:
    ///
    /// - `--name-status -z -M`, for `GitNameStatus.parse`;
    /// - `--numstat -z`, for `GitNameStatus.binaryPaths`. With
    ///   `--no-renames`, so each entry is one path: git otherwise detects
    ///   renames here by default and writes those as two;
    /// - the patch, `--binary` with full object names and the standard
    ///   `a/` and `b/` prefixes, whatever the user's configuration says, so
    ///   it applies again (Restore) and its digest is stable.
    ///
    /// All three with `--ignore-submodules=none`: `git add -A` stages a
    /// submodule's new commit whatever `diff.ignoreSubmodules` or a
    /// submodule's `ignore` says, and the commit carries it, so the review
    /// must show it too. The patch writes it `--submodule=short`, as one
    /// that applies again, whatever `diff.submodule` says.
    ///
    /// Nil when git fails. `-z`, because reference filenames carry spaces,
    /// `&` and non-ASCII titles, which git otherwise quotes.
    func stagedDiff(in worktree: URL, base: String) async
        -> (nameStatus: Data, numstat: Data, patch: Data)? {
        let path = worktree.path(percentEncoded: false)
        let nameStatus = await data([
            "-C", path, "diff", "--cached", "--no-color", "--ignore-submodules=none", "-M",
            "--name-status", "-z", base,
        ])
        guard nameStatus.status == 0 else { return nil }
        let numstat = await data([
            "-C", path, "diff", "--cached", "--no-color", "--no-textconv", "--no-renames",
            "--ignore-submodules=none", "--numstat", "-z", base,
        ])
        guard numstat.status == 0 else { return nil }
        let patch = await data([
            "-C", path, "diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv",
            "--ignore-submodules=none", "--submodule=short",
            "-M", "--binary", "--full-index", "--src-prefix=a/", "--dst-prefix=b/", base,
        ])
        guard patch.status == 0 else { return nil }
        return (nameStatus.stdout, numstat.stdout, patch.stdout)
    }

    /// `git diff --cached --raw -z --no-renames <base>`: each staged path
    /// with its old and new modes, for `GitNameStatus.irregularPaths`. A
    /// symbolic link is staged as a blob holding its target, which the
    /// other outputs show as one line of text (§6.1). Nil when git fails.
    func stagedModes(in worktree: URL, base: String) async -> Data? {
        let result = await data([
            "-C", worktree.path(percentEncoded: false),
            "diff", "--cached", "--no-color", "--no-renames", "--ignore-submodules=none",
            "--raw", "-z", base,
        ])
        return result.status == 0 ? result.stdout : nil
    }

    /// The blob `spec` names, bytes exact: "<commit>:<path>", or ":<path>"
    /// for the index. Nil when there is no such file, as for a page the
    /// commit does not have.
    ///
    /// `cat-file blob` prints what `git show` prints for a blob, with no
    /// text conversion, and refuses a tree rather than listing it.
    func blob(_ spec: String, in directory: URL) async -> Data? {
        let result = await data([
            "-C", directory.path(percentEncoded: false), "cat-file", "blob", spec,
        ])
        return result.status == 0 ? result.stdout : nil
    }

    /// Returns one repository-relative path to `base`: `git checkout <base>
    /// -- <path>`, or, for a file `base` does not have, out of the index and
    /// off the disk. True when the path is as it was at `base`.
    ///
    /// A submodule's commit (a gitlink) is in the submodule's own objects,
    /// not here, so it is found with `ls-tree`, which reads only the tree:
    /// `cat-file -e <base>:<path>` would call it new, and its checkout would
    /// be deleted. `checkout` restores only its index entry; the submodule's
    /// checkout goes back to that commit too, from what it already has, or
    /// the next `git add -A` would stage the moved commit again.
    func revertPath(_ path: String, to base: String, in worktree: URL) async -> Bool {
        let directory = worktree.path(percentEncoded: false)
        let entry = await run(["-C", directory, "ls-tree", base, "--", Self.literal(path)])
        guard entry.succeeded else { return false }
        // "<mode> <type> <object>\t<path>", or nothing for a path not in `base`.
        let mode = entry.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0 != " " }
        if !mode.isEmpty {
            guard await run([
                "-C", directory, "checkout", base, "--", Self.literal(path),
            ]).succeeded else { return false }
            guard mode == Self.gitlinkMode else { return true }
            guard await run([
                "-C", directory, "submodule", "update", "--checkout", "--no-fetch", "--",
                Self.literal(path),
            ]).succeeded else { return false }
            // What `git add -A` would stage: the submodule's commit, not
            // whatever else its checkout holds.
            return await run([
                "-C", directory, "diff", "--quiet", "--ignore-submodules=dirty", base, "--",
                Self.literal(path),
            ]).succeeded
        }
        let unstaged = await run([
            "-C", directory, "rm", "--cached", "--quiet", "--ignore-unmatch", "--",
            Self.literal(path),
        ]).succeeded
        let file = worktree.appending(path: path)
        try? FileManager.default.removeItem(at: file)
        return unstaged && !FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    /// `git reset --soft <base>`, then `git commit --no-verify`: whatever the
    /// agent committed collapses into one commit of exactly what is staged,
    /// and no hook can rewrite the files after they were reviewed (§6.5).
    /// The new commit, or nil.
    func commitStaged(in worktree: URL, base: String, message: String) async -> String? {
        let directory = worktree.path(percentEncoded: false)
        guard await run(["-C", directory, "reset", "--quiet", "--soft", base]).succeeded,
              await run([
                  "-C", directory, "commit", "--quiet", "--no-verify", "-m", message,
              ]).succeeded
        else { return nil }
        return await head(in: worktree)
    }

    /// Pushes the worktree's HEAD to `branch` on `remote`, leasing on
    /// `expecting`: the commit the branch must be at, or nil for a branch
    /// that must not exist yet (§4.4).
    func push(in worktree: URL, to remote: String, branch: String, expecting: String?) async
        -> Subprocess.Result {
        await run(["-C", worktree.path(percentEncoded: false)]
            + Self.pushArguments(remote: remote, branch: branch, expecting: expecting))
    }

    /// `push --force-with-lease=refs/heads/<branch>:<expected> <remote>
    /// HEAD:refs/heads/<branch>`. An empty expectation leases on absence, so
    /// the first push cannot overwrite a branch someone else made. One ref,
    /// and never a submodule's, whatever `push.recurseSubmodules` says.
    static func pushArguments(remote: String, branch: String, expecting: String?) -> [String] {
        [
            "push", "--recurse-submodules=no",
            "--force-with-lease=refs/heads/\(branch):\(expecting ?? "")",
            remote, "HEAD:refs/heads/\(branch)",
        ]
    }

    /// Whether a push was refused because the branch was not where the lease
    /// expected it: git's "stale info".
    static func leaseWasRefused(_ output: String) -> Bool {
        output.contains("(stale info)")
    }

    /// Where `branch` is on `remote`, asked of the remote itself.
    func remoteTip(of branch: String, remote: String, in directory: URL) async -> RemoteTip {
        let ref = "refs/heads/\(branch)"
        let result = await run([
            "-C", directory.path(percentEncoded: false), "ls-remote", remote, ref,
        ])
        guard result.succeeded else { return .unknown }
        return Self.refs(fromLsRemote: result.stdout)[ref].map(RemoteTip.at) ?? .absent
    }

    /// Every branch on `remote`, by name ("fix/x", not "refs/heads/fix/x"),
    /// and its commit. Nil when the remote could not be asked.
    ///
    /// A pattern rather than `--heads`, which git 2.46 deprecated in favour
    /// of `--branches`, which Apple's git does not know.
    func remoteHeads(remote: String, in directory: URL) async -> [String: String]? {
        let result = await run([
            "-C", directory.path(percentEncoded: false), "ls-remote", remote, "refs/heads/*",
        ])
        guard result.succeeded else { return nil }
        let prefix = "refs/heads/"
        var heads: [String: String] = [:]
        for (ref, commit) in Self.refs(fromLsRemote: result.stdout) where ref.hasPrefix(prefix) {
            heads[String(ref.dropFirst(prefix.count))] = commit
        }
        return heads
    }

    /// `ls-remote` output, "<commit>\t<ref>" per line, as ref → commit.
    static func refs(fromLsRemote output: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            refs[fields[1].trimmingCharacters(in: .whitespaces)] = String(fields[0])
        }
        return refs
    }

    /// Every commit the local `branch` has pointed at. Each Approve's commit
    /// is among them, which is how a push CCwiki made is recognised after its
    /// reply was lost (§6.5).
    func reflog(of branch: String, in directory: URL) async -> Set<String> {
        let result = await run([
            "-C", directory.path(percentEncoded: false),
            "log", "--walk-reflogs", "--format=%H", "refs/heads/\(branch)", "--",
        ])
        guard result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
    }

    /// Renames the worktree's own branch.
    func renameBranch(to name: String, in worktree: URL) async -> Bool {
        await run(["-C", worktree.path(percentEncoded: false), "branch", "-m", name]).succeeded
    }

    /// The name and email a commit here would carry: `GIT_AUTHOR_NAME` and
    /// `GIT_AUTHOR_EMAIL` when set, as git itself prefers them, else
    /// `user.name` and `user.email`. Nil when either is missing; git would
    /// otherwise make one up from the account and host names, and a pull
    /// request would carry it.
    func identity(in worktree: URL) async -> (name: String, email: String)? {
        let directory = worktree.path(percentEncoded: false)
        func value(_ key: String, variable: String) async -> String? {
            if let set = environment[variable].flatMap(Self.nonEmpty) { return set }
            let result = await run(["-C", directory, "config", "--get", key])
            return result.succeeded ? Self.nonEmpty(result.stdout) : nil
        }
        guard let name = await value("user.name", variable: "GIT_AUTHOR_NAME"),
              let email = await value("user.email", variable: "GIT_AUTHOR_EMAIL")
        else { return nil }
        return (name, email)
    }

    /// Which of `paths` (repository-relative) changed on `ref` since it and
    /// `base` parted: `git diff base...ref`. For DiffGuard's
    /// `changedUpstream` (§6.2). Empty when git cannot say.
    func changedPaths(in clone: URL, from base: String, to ref: String, limitedTo paths: [String])
        async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let result = await data([
            "-C", clone.path(percentEncoded: false),
            "diff", "--no-color", "--no-renames", "--name-only", "-z", "\(base)...\(ref)", "--",
        ] + paths.map(Self.literal))
        guard result.status == 0 else { return [] }
        return Set(Self.fields(nulSeparated: result.stdout))
    }

    /// `git worktree prune`, then `git worktree add -B <branch> <path>
    /// <base>`: a job's worktree made again where it was, on its own branch
    /// reset to its base, for Restore (§4.4).
    func addWorktree(clone: URL, at path: URL, resettingBranch branch: String, to base: String)
        async -> Bool {
        let directory = clone.path(percentEncoded: false)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = await run(["-C", directory, "worktree", "prune"])
        return await run([
            "-C", directory, "worktree", "add", "-B", branch, path.path(percentEncoded: false), base,
        ]).succeeded
    }

    /// `git worktree move`: a worktree, and git's record of it, to
    /// `destination`, which must not exist yet (git would move it inside an
    /// existing directory). Restore builds a job's worktree aside and moves
    /// it into place only once the patch has applied (§4.4).
    func moveWorktree(clone: URL, from source: URL, to destination: URL) async -> Bool {
        let target = destination.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: target) else { return false }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return await run([
            "-C", clone.path(percentEncoded: false),
            "worktree", "move", source.path(percentEncoded: false), target,
        ]).succeeded
    }

    /// `git apply --index`: the saved patch back into the worktree and its
    /// index. An empty patch is nothing to apply, which git calls an error.
    /// Whitespace is applied as it is, whatever `apply.whitespace` says: the
    /// patch is the reviewed diff, byte for byte.
    func applyPatch(_ patch: URL, in worktree: URL) async -> Bool {
        let file = patch.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
              let size = attributes[.size] as? NSNumber
        else { return false }
        if size.intValue == 0 { return true }
        return await run([
            "-C", worktree.path(percentEncoded: false),
            "apply", "--index", "--whitespace=nowarn", file,
        ]).succeeded
    }

    /// Deletes a job's branch from the clone. Never one on a remote.
    func deleteBranch(_ name: String, in clone: URL) async -> Bool {
        await run(["-C", clone.path(percentEncoded: false), "branch", "-D", name]).succeeded
    }

    /// A pathspec that matches `path` and nothing else: reference filenames
    /// may hold `[`, `*` or `?`, which git would otherwise read as a glob.
    static func literal(_ path: String) -> String {
        ":(literal)" + path
    }

    /// The mode git gives a submodule's commit in a tree or the index.
    static let gitlinkMode = "160000"

    /// Whether `worktree` is still one of `clone`'s worktrees as git made
    /// it: its `.git` is a file, not a link or a folder, that names a folder
    /// in `<clone>/.git/worktrees/` (a relative name is read from the
    /// worktree, as git reads it). CCwiki's own git runs in a worktree
    /// unsealed (§5.1) and finds the repository through that file, which an
    /// agent could rewrite: pointed anywhere else, the snapshot, the commit
    /// and the push would run on a repository and a configuration it chose.
    static func isWorktree(_ worktree: URL, of clone: URL) -> Bool {
        let manager = FileManager.default
        let file = worktree.appending(path: ".git").path(percentEncoded: false)
        guard let attributes = try? manager.attributesOfItem(atPath: file),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let data = manager.contents(atPath: file),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        let prefix = "gitdir: "
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(prefix), !line.contains("\n") else { return false }
        let named = String(line.dropFirst(prefix.count))
        let gitdir = named.hasPrefix("/")
            ? named : worktree.appending(path: named).path(percentEncoded: false)
        let admin = realPath(gitdir)
        let worktrees = realPath(clone.appending(path: ".git/worktrees").path(percentEncoded: false))
        return manager.fileExists(atPath: admin)
            && (admin as NSString).deletingLastPathComponent == worktrees
    }

    /// `-z` output split at each NUL, without the empty field after the
    /// last one.
    static func fields(nulSeparated data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `path` with every symbolic link resolved, as `git worktree list`
    /// reports a worktree's; `path` itself when it does not exist.
    /// Foundation's `resolvingSymlinksInPath` will not do: it takes a
    /// leading `/private` back off.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Plumbing

    private func run(_ arguments: [String]) async -> Subprocess.Result {
        await Subprocess.run(
            executable: executable, arguments: arguments, environment: environment)
    }

    /// Run git and keep stdout as bytes (`Subprocess.runData`).
    private func data(_ arguments: [String]) async -> (status: Int32, stdout: Data, stderr: String) {
        await Subprocess.runData(
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

/// Where a branch is on a remote, as `git ls-remote` reports it: absent, at
/// a commit, or unknown because the remote could not be asked.
enum RemoteTip: Sendable, Equatable {
    case absent
    case at(String)
    case unknown
}
