import Foundation

/// Where CCwiki keeps everything.
///
/// ```
/// ~/Library/Application Support/CCwiki/
/// ├── repo/          the pull-only clone — the reader's copy, never committed to
/// ├── worktrees/     one git worktree per ingestion job, pruned when the PR opens
/// ├── library/       PDFs dropped on the app; deliberately outside the repo
/// ├── index/         search.sqlite3 — derived, safe to delete at any time
/// └── logs/          per-job transcripts, kept after the worktree is gone
/// ```
///
/// The app is not sandboxed (it has to exec `git`, `gh` and `claude`), so this
/// is the real Application Support directory rather than a container.
struct AppPaths: Sendable {

    static let remoteURL = "https://github.com/axhoover/cryptology.city"
    /// The same repository as `gh` names it.
    static let repositorySlug = "axhoover/cryptology.city"
    static let defaultBranch = "main"
    /// The published site. A page's URL there is its Quartz slug, so the
    /// reader can point at the same page it is showing.
    static let siteURL = "https://cryptology.city"

    let support: URL
    /// Space-free scratch space. See `worktrees`.
    let cacheRoot: URL

    /// The pull-only clone. The app fast-forwards it and reads it; it never
    /// commits, branches or writes content here.
    var clone: URL { support.appending(path: "repo") }
    /// `content/` inside the clone — everything the reader shows.
    var content: URL { clone.appending(path: "content") }
    /// One worktree per ingestion job — **deliberately not under Application
    /// Support**.
    ///
    /// That path contains a space, and a worktree is where third-party
    /// developer tooling runs: `npm`, `npx`, `tsx`, `quartz`. The wiki's own
    /// `scripts/*.mjs` read `import.meta.url.pathname` without percent-decoding
    /// it, so a space becomes `%20` and they fail with `ENOENT`. Two consecutive
    /// ingestion jobs lost turns to this — one worked around it with a symlink
    /// (which then needed `ln`, which is not in the tool allow-list), the other
    /// gave up on `sync-cryptobib` entirely and verified the citation key by
    /// hand.
    ///
    /// `~/Library/Caches` has no space and is exactly the right semantics: a
    /// worktree is disposable by construction — created per job, pruned on
    /// success. If the OS ever purges one mid-job, git fails loudly and the
    /// transcript is still in `logs/`, which stays under Application Support
    /// with everything else durable.
    var worktrees: URL { cacheRoot.appending(path: "worktrees") }
    /// Dropped PDFs. These are inputs to a job and never enter the repo.
    var library: URL { support.appending(path: "library") }
    var index: URL { support.appending(path: "index") }
    var searchDatabase: URL { index.appending(path: "search.sqlite3") }
    var logs: URL { support.appending(path: "logs") }

    /// The vendored offline render pipeline, inside the app bundle.
    var webRoot: URL {
        Bundle.main.resourceURL?.appending(path: "web")
            // `swift run` and the test bundle have no .app around them; fall
            // back to the source tree so the reader is debuggable there too.
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Resources/web")
    }

    init(support: URL, cacheRoot: URL) {
        self.support = support
        self.cacheRoot = cacheRoot
    }

    /// Everything under one root. For tests and scratch trees, where the
    /// space-free split that `standard()` makes has nothing to protect against.
    init(support: URL) {
        self.init(support: support, cacheRoot: support)
    }

    static func standard() -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let support = base.appending(path: "CCwiki")
        migrateFromEarlierName(into: support, base: base)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        let paths = AppPaths(support: support, cacheRoot: caches.appending(path: "CCwiki"))
        paths.migrateWorktreesOutOfSupport()
        return paths
    }

    /// Move worktrees left in the old, space-bearing location.
    ///
    /// They belong to jobs that failed and were kept for inspection, so
    /// stranding them would strand the evidence.
    private func migrateWorktreesOutOfSupport() {
        let manager = FileManager.default
        let old = support.appending(path: "worktrees")
        guard let stale = try? manager.contentsOfDirectory(
            at: old, includingPropertiesForKeys: nil), !stale.isEmpty
        else { return }

        try? manager.createDirectory(at: worktrees, withIntermediateDirectories: true)
        for directory in stale {
            let destination = worktrees.appending(path: directory.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path(percentEncoded: false)) else {
                continue
            }
            try? manager.moveItem(at: directory, to: destination)
        }
        // A git worktree records its own path, so anything moved has to be
        // re-registered. `git worktree repair` does exactly that, and the
        // app runs it on the next sync (see GitService.repairWorktrees).
    }

    /// The app was called CityDesk before it was called CCwiki.
    ///
    /// Everything under the old directory is either expensive to reacquire (a
    /// 35 MB clone) or impossible to (job transcripts from runs that already
    /// happened), so a rename should move it rather than orphan it. One shot:
    /// if the new directory already exists, the old one is left alone.
    private static func migrateFromEarlierName(into support: URL, base: URL) {
        let manager = FileManager.default
        let old = base.appending(path: "CityDesk")
        guard manager.fileExists(atPath: old.path(percentEncoded: false)),
              !manager.fileExists(atPath: support.path(percentEncoded: false))
        else { return }
        try? manager.moveItem(at: old, to: support)
    }

    /// Creates the directory tree. Called once at launch; cheap and idempotent.
    func createDirectories() throws {
        for directory in [support, cacheRoot, worktrees, library, index, logs] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    var cloneExists: Bool {
        FileManager.default.fileExists(
            atPath: clone.appending(path: ".git").path(percentEncoded: false))
    }

    func worktree(forJob id: String) -> URL { worktrees.appending(path: id) }
    func log(forJob id: String) -> URL { logs.appending(path: "\(id).log") }
    /// The small JSON record that brings a job back after a relaunch.
    func record(forJob id: String) -> URL { logs.appending(path: "\(id).json") }
}
