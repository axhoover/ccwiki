import Foundation

/// Where CityDesk keeps everything.
///
/// ```
/// ~/Library/Application Support/CityDesk/
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
    static let defaultBranch = "main"

    let support: URL

    /// The pull-only clone. The app fast-forwards it and reads it; it never
    /// commits, branches or writes content here.
    var clone: URL { support.appending(path: "repo") }
    /// `content/` inside the clone — everything the reader shows.
    var content: URL { clone.appending(path: "content") }
    /// One worktree per ingestion job.
    var worktrees: URL { support.appending(path: "worktrees") }
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

    static func standard() -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return AppPaths(support: base.appending(path: "CityDesk"))
    }

    /// Creates the directory tree. Called once at launch; cheap and idempotent.
    func createDirectories() throws {
        for directory in [support, worktrees, library, index, logs] {
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
}
