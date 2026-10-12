import Foundation

/// Why the library is being loaded. Each answers differently to "what else
/// has to happen after it" (plans/reader-comforts.md §3.2, §3.7).
enum LibraryLoadReason: Equatable, Sendable {
    /// The first load of the process, from what is already on disk.
    case launch
    /// After a sync that fetched, whether or not it brought anything.
    case pulled
    /// After the first clone or snapshot.
    case cloned
    /// After Reset Clone downloaded the wiki again.
    case reset
    /// After a sync that could not reach the network.
    case offline
    /// Settings ▸ Storage ▸ Rebuild.
    case rebuild
}

/// What the clone says about itself: the commit, when it was made, and when
/// each page last changed.
struct RevisionFacts: Equatable, Sendable {
    var head: String?
    var date: Date?
    var modifiedDates: [String: Date]
}

/// The policy around a library load: whether a sync's outcome calls for one,
/// what the status bar says afterwards, and what git is asked. Kept out of
/// `AppModel` so each rule can change, and be tested, without it.
///
/// Every rule here is today's behaviour. Track D (D5) replaces them: no
/// reload when nothing changed, the summary from the fingerprints, the dates
/// from the pulled range only, and the job housekeeping only when it can
/// have found something.
enum LibraryRefresh {

    /// Whether `outcome` calls for a load. Every outcome but a failure does.
    static func needsReload(
        after outcome: GitService.SyncOutcome, loadedRevision: String?, isLoaded: Bool
    ) -> Bool {
        if case .failed = outcome { return false }
        return true
    }

    /// What the status bar says after a sync. A pull says how many pages it
    /// changed, which is what a reader wants to know in place of two hashes;
    /// a snapshot has no history to count them in.
    static func summary(
        after outcome: GitService.SyncOutcome, changes: LibraryChanges?,
        store: AppPaths.WikiStore, git: GitService?, clone: URL
    ) async -> String {
        guard case .updated(let before, let after) = outcome else { return outcome.summary }
        guard let git, store == .git else { return GitService.updateSummary(changedPages: 0) }
        let changed = await git.changedPages(in: clone, from: before, to: after)
        return GitService.updateSummary(changedPages: changed.count)
    }

    /// HEAD, or the snapshot marker's sha; read before and after a load's
    /// scan, so a load that raced a change to the clone does not claim it.
    static func currentRevision(
        store: AppPaths.WikiStore, git: GitService?, clone: URL
    ) async -> String? {
        if let git, store == .git { return await git.head(in: clone) }
        return SnapshotService.marker(in: clone)?.sha
    }

    /// The commit, its date and the pages' dates. From git for a clone, from
    /// the marker for a snapshot, which has no history to date files by;
    /// nothing at all without either.
    static func revisionFacts(
        store: AppPaths.WikiStore, git: GitService?, paths: AppPaths,
        after outcome: GitService.SyncOutcome?
    ) async -> RevisionFacts {
        if let git, store == .git {
            let dates = await git.modifiedDates(in: paths.clone)
            let head = await git.head(in: paths.clone)
            let date = await git.headDate(in: paths.clone)
            return RevisionFacts(head: head, date: date, modifiedDates: dates)
        }
        if let marker = SnapshotService.marker(in: paths.clone) {
            return RevisionFacts(head: marker.sha, date: marker.commitDate, modifiedDates: [:])
        }
        return RevisionFacts(head: nil, date: nil, modifiedDates: [:])
    }

    /// Whether a load repairs the jobs' worktrees and looks for strays. A
    /// crash or force-quit mid-job leaves one behind, and every load looks.
    static func runsJobHousekeeping(_ reason: LibraryLoadReason) -> Bool {
        true
    }
}
