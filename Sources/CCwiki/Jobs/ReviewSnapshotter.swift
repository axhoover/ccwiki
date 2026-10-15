import Foundation

/// Takes a job's snapshot: what is staged in its worktree against the
/// commit it started from, as the review shows it and Approve commits it
/// (plans/corrections.md §6.1).
///
/// ```
/// git add -A -- . ':(exclude).ccwiki'
/// git write-tree                                 → <tree>, what is staged, by name
/// git diff -M --name-status -z <base> <tree>     → GitNameStatus.parse
/// git diff --numstat -z <base> <tree>            → binary paths
/// git diff <patchOptions> <base> <tree>          → the digest, and logs/<id>.patch
/// git cat-file blob <base>:<old path>            → each changed file's old text
/// git cat-file blob <tree>:<path>                → its new text
/// ```
///
/// Every command reads the objects themselves, never replacements
/// (`GitService.realObjects`), and every diff shows every submodule
/// (`--ignore-submodules=none`).
///
/// - **Bytes, not lines.** Every read goes through `Subprocess.runData`, and
///   texts are decoded only after, strictly: a file whose bytes are not
///   UTF-8 has no text, and `ReviewSnapshot.assemble` treats it as binary,
///   which DiffGuard blocks.
/// - **Everything comes from one tree**, written from the index, so the
///   snapshot is exactly what was staged and digested, not what was on disk
///   or in the index a moment later; and Approve commits that tree or
///   nothing.
/// - **The patch is written every time**, byte for byte, to `logs/<id>.patch`
///   outside Caches, so a review survives its worktree (§4.4).
/// - Assembling the diff and checking it run in `Task.detached`:
///   `relations.json` is 11,432 lines. Only the result comes back to the
///   main actor.
///
/// The caller runs it through the job's own queue (`JobCenter`), so two
/// `git add` never meet on `index.lock`.
@MainActor
struct ReviewSnapshotter {

    let git: GitService

    /// The snapshot of `worktree` against `base`, with the patch written to
    /// `patchFile`. Nil when git could not stage or compare.
    func snapshot(worktree: URL, base: String, patchFile: URL) async -> ReviewSnapshot? {
        guard await git.stageAll(in: worktree),
              let diff = await git.stagedDiff(in: worktree, base: base)
        else { return nil }

        let manager = FileManager.default
        try? manager.createDirectory(
            at: patchFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? diff.patch.write(to: patchFile, options: .atomic)

        let entries = GitNameStatus.parse(nameStatusZ: diff.nameStatus)
        let binary = GitNameStatus.binaryPaths(numstatZ: diff.numstat)

        // Each side that should have text, read from git as bytes. A binary
        // file is not read at all.
        var oldTexts: [String: String] = [:]
        var newTexts: [String: String] = [:]
        for entry in entries {
            let oldPath = entry.oldPath ?? entry.path
            if binary.contains(entry.path) || binary.contains(oldPath) { continue }
            if entry.status != .added,
               let data = await git.blob("\(base):\(oldPath)", in: worktree),
               let text = String(data: data, encoding: .utf8) {
                oldTexts[oldPath] = text
            }
            if entry.status != .deleted,
               let data = await git.blob("\(diff.tree):\(entry.path)", in: worktree),
               let text = String(data: data, encoding: .utf8) {
                newTexts[entry.path] = text
            }
        }

        let (tree, patch) = (diff.tree, diff.patch)
        let (before, after) = (oldTexts, newTexts)
        return await Task.detached(priority: .userInitiated) {
            ReviewSnapshot.assemble(
                base: base, tree: tree, entries: entries, binary: binary,
                patch: patch, oldTexts: before, newTexts: after)
        }.value
    }

    /// The snapshot, and what DiffGuard says about it in this job's
    /// context: its kind and target, the pages a human verified at the
    /// base, the paths that changed on `origin/<default>` since, and the
    /// local paths no text may contain (§6.2). Nil when the job has no base,
    /// or git could not answer.
    func review(of job: Job, clone: URL, privatePaths: [String]) async
        -> (snapshot: ReviewSnapshot, findings: [DiffFinding])? {
        guard let base = job.baseCommit,
              let taken = await self.snapshot(
                  worktree: job.worktree, base: base, patchFile: job.patchFile)
        else { return nil }
        let snapshot = taken

        // `.fact-check/queue.json` as it was at the base: a page a human
        // verified then is one this change must say it touches.
        let queue = await git.blob("\(base):\(Self.factCheckQueue)", in: job.worktree)
        let humanVerified = queue.map { FactCheckQueue.humanVerifiedPaths(json: $0) } ?? []

        // Only the paths this change touches are asked about.
        let touched = snapshot.files.flatMap { file in [file.path] + (file.oldPath.map { [$0] } ?? []) }
        var upstream: Set<String> = []
        if !touched.isEmpty {
            let branch = await git.defaultBranch(in: clone)
            upstream = await git.changedPaths(
                in: clone, from: base, to: "origin/\(branch)", limitedTo: touched)
        }

        let context = DiffGuard.Context(
            kind: job.kind.tag, humanVerifiedPaths: humanVerified, changedUpstream: upstream,
            target: job.kind.target, privatePaths: privatePaths)
        let findings = await Task.detached(priority: .userInitiated) {
            DiffGuard.check(snapshot, context: context)
        }.value
        return (snapshot, findings)
    }

    /// Repository-relative.
    nonisolated static let factCheckQueue = ".fact-check/queue.json"
}
