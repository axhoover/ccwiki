import Foundation
import OSLog

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
/// A sync that changed nothing reloads nothing, the summary counts pages by
/// their fingerprints, the dates come from the pulled range only, and the
/// job housekeeping runs only when it can have found something
/// (plans/reader-comforts.md §3.2, §3.7).
enum LibraryRefresh {

    /// Whether `outcome` calls for a load.
    ///
    /// - Already up to date at the commit the library was read at: no. With
    ///   no such commit (nothing loaded, or a load that raced a change to the
    ///   clone), yes. Every launch used to load twice, the second time for
    ///   this answer.
    /// - Offline: only if nothing is loaded yet. The clone is CCwiki's own,
    ///   and nothing else writes there.
    /// - Updated or cloned: yes. Failed: no, as always.
    static func needsReload(
        after outcome: GitService.SyncOutcome, loadedRevision: String?, isLoaded: Bool
    ) -> Bool {
        switch outcome {
        case .failed:
            return false
        case .offline:
            return !isLoaded
        case .alreadyCurrent(let revision):
            guard isLoaded, let loadedRevision else { return true }
            return loadedRevision != revision
        case .updated, .cloned:
            return true
        }
    }

    /// What the status bar says after a sync. A pull says how many pages it
    /// changed, which is what a reader wants to know in place of two hashes:
    /// counted from the load's fingerprints, for a clone and a snapshot alike.
    /// Only a pull with no earlier load to compare with asks git, which a
    /// snapshot does not have.
    static func summary(
        after outcome: GitService.SyncOutcome, changes: LibraryChanges?,
        store: AppPaths.WikiStore, git: GitService?, clone: URL
    ) async -> String {
        guard case .updated(let before, let after) = outcome else { return outcome.summary }
        if let changes {
            return GitService.updateSummary(changedPages: changes.changedPages.count)
        }
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
    /// nothing at all without either, and then `AppModel` keeps what it has.
    ///
    /// After a sync the commit comes from its outcome, and the dates from
    /// `index/modified-dates.json` brought forward over the commits pulled
    /// since (§3.7), so a pull asks git for one date and one short log.
    static func revisionFacts(
        store: AppPaths.WikiStore, git: GitService?, paths: AppPaths,
        after outcome: GitService.SyncOutcome?
    ) async -> RevisionFacts {
        if let git, store == .git {
            let clock = ContinuousClock()
            let start = clock.now
            var commit = Self.head(after: outcome)
            if commit == nil { commit = await git.head(in: paths.clone) }
            let date = await git.headDate(in: paths.clone)
            let (dates, source) = await Self.modifiedDates(
                git: git, clone: paths.clone, head: commit, pulledFrom: Self.base(of: outcome),
                cache: ModifiedDatesCache.url(in: paths))
            let message = "Revision \(commit.map { String($0.prefix(7)) } ?? "unknown"): "
                + "\(dates.count) dates from \(source.rawValue) in \(start.duration(to: clock.now))"
            Logger.library.notice("\(message, privacy: .public)")
            return RevisionFacts(head: commit, date: date, modifiedDates: dates)
        }
        if let marker = SnapshotService.marker(in: paths.clone) {
            return RevisionFacts(head: marker.sha, date: marker.commitDate, modifiedDates: [:])
        }
        return RevisionFacts(head: nil, date: nil, modifiedDates: [:])
    }

    /// Whether a load repairs the jobs' worktrees and looks for strays: at
    /// launch, and after a clone or a reset, when the worktrees' metadata may
    /// have moved or gone. A pull touches neither, and a finished job looks
    /// for strays itself (audit §3.5).
    static func runsJobHousekeeping(_ reason: LibraryLoadReason) -> Bool {
        switch reason {
        case .launch, .cloned, .reset: true
        case .pulled, .offline, .rebuild: false
        }
    }

    // MARK: Dates

    /// The commit a sync's outcome says the clone is at.
    static func head(after outcome: GitService.SyncOutcome?) -> String? {
        switch outcome {
        case .updated(_, let after)?:
            return after.isEmpty ? nil : after
        case .alreadyCurrent(let revision)?:
            return revision.isEmpty ? nil : revision
        default:
            return nil
        }
    }

    /// The commit a pull started from, which HEAD has in its history by
    /// construction: a fast-forward.
    static func base(of outcome: GitService.SyncOutcome?) -> String? {
        guard case .updated(let before, _)? = outcome, !before.isEmpty else { return nil }
        return before
    }

    /// Where the pages' dates came from, for the log.
    enum DatesSource: String, Sendable {
        case cache = "the cache"
        case range = "the pulled range"
        case history = "the whole history"
    }

    /// The pages' dates at `head`, equal to the whole-history log there, from
    /// the cheapest source that can say: the cache when it is at `head`; the
    /// cache and the commits since, when `head` has the cache's commit in its
    /// history; else the whole history. The answer is cached for next time.
    static func modifiedDates(
        git: GitService, clone: URL, head: String?, pulledFrom base: String?, cache url: URL
    ) async -> (dates: [String: Date], source: DatesSource) {
        guard let head else {
            let dates = await git.modifiedDates(in: clone)
            return (dates, .history)
        }
        let cache = ModifiedDatesCache.read(from: url)
        if let cache, cache.revision == head { return (cache.dates, .cache) }

        var brought: [String: Date]?
        if let cache {
            var isAncestor = cache.revision == base
            if !isAncestor {
                isAncestor = await git.isAncestor(cache.revision, of: head, in: clone)
            }
            if isAncestor, let range = await git.modifiedDates(in: clone, since: cache.revision) {
                brought = merged(cache.dates, range)
            }
        }
        let result: (dates: [String: Date], source: DatesSource)
        if let brought {
            result = (brought, .range)
        } else {
            let history = await git.modifiedDates(in: clone)
            result = (history, .history)
        }
        // An empty answer is git failing, not a wiki with no history: kept,
        // it would stand in for the real dates until the next pull.
        if !result.dates.isEmpty {
            ModifiedDatesCache(revision: head, dates: result.dates).write(to: url)
        }
        return result
    }

    /// Two sets of dates as one, the later date for a file in both: the
    /// whole history's answer, given each half's.
    static func merged(_ earlier: [String: Date], _ later: [String: Date]) -> [String: Date] {
        earlier.merging(later) { max($0, $1) }
    }
}

/// `index/modified-dates.json`: the pages' dates at one commit, so the load
/// after a pull asks git only about the commits it brought (§3.7). Derived
/// and safe to delete, like the search index; a version or file it cannot
/// read is ignored, and the whole history is read again.
struct ModifiedDatesCache: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = ModifiedDatesCache.currentVersion
    var revision: String
    var dates: [String: Date]

    static func url(in paths: AppPaths) -> URL {
        paths.index.appending(path: "modified-dates.json")
    }

    static func read(from url: URL) -> ModifiedDatesCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let cache = try? decoder.decode(ModifiedDatesCache.self, from: data),
              cache.version == currentVersion
        else { return nil }
        return cache
    }

    func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
