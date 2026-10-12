import Foundation
import Testing
@testable import CCwiki

/// The policy around a library load (plans/reader-comforts.md §3.2, §3.7):
/// a sync that changed nothing reloads nothing, a pull's summary counts its
/// pages from the fingerprints, and the job housekeeping runs only when it
/// can find something.
struct LibraryRefreshTests {

    static let head = "75f254251cd77489c40df4e664b9ccf4521b976a"
    static let other = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"

    // MARK: Whether to reload

    @Test("already up to date at the loaded commit reloads nothing; anything less certain reloads")
    func alreadyCurrent() {
        let outcome = GitService.SyncOutcome.alreadyCurrent(at: Self.head)
        #expect(!LibraryRefresh.needsReload(after: outcome, loadedRevision: Self.head, isLoaded: true))
        #expect(LibraryRefresh.needsReload(after: outcome, loadedRevision: Self.other, isLoaded: true))
        #expect(LibraryRefresh.needsReload(after: outcome, loadedRevision: nil, isLoaded: true),
                "a load that raced a change recorded no commit")
        #expect(LibraryRefresh.needsReload(after: outcome, loadedRevision: nil, isLoaded: false))
        #expect(LibraryRefresh.needsReload(after: outcome, loadedRevision: Self.head, isLoaded: false))
    }

    @Test("offline reloads only when nothing is loaded yet")
    func offline() {
        #expect(!LibraryRefresh.needsReload(after: .offline, loadedRevision: Self.head, isLoaded: true))
        #expect(!LibraryRefresh.needsReload(after: .offline, loadedRevision: nil, isLoaded: true))
        #expect(LibraryRefresh.needsReload(after: .offline, loadedRevision: nil, isLoaded: false))
    }

    @Test("an update or a clone always reloads; a failure never does")
    func updatedClonedFailed() {
        for loaded in [Self.head, nil] as [String?] {
            for isLoaded in [true, false] {
                #expect(LibraryRefresh.needsReload(
                    after: .updated(from: Self.other, to: Self.head),
                    loadedRevision: loaded, isLoaded: isLoaded))
                #expect(LibraryRefresh.needsReload(
                    after: .cloned, loadedRevision: loaded, isLoaded: isLoaded))
                #expect(!LibraryRefresh.needsReload(
                    after: .failed("git fetch failed (exit 128)."),
                    loadedRevision: loaded, isLoaded: isLoaded))
            }
        }
    }

    // MARK: What the status bar says

    static func changes(pages: Int, assets: Int = 0) -> LibraryChanges {
        var changes = LibraryChanges.none
        changes.modified = Set((0..<pages).map { "Primitives/page-\($0).md" })
            .union((0..<assets).map { "Files/picture-\($0).png" })
        return changes
    }

    @Test("a pull counts the pages its load found changed, for a clone and a snapshot alike")
    func summaryFromChanges() async {
        let updated = GitService.SyncOutcome.updated(from: Self.other, to: Self.head)
        let clone = URL(fileURLWithPath: "/nonexistent")
        for store in [AppPaths.WikiStore.git, .snapshot] {
            let four = await LibraryRefresh.summary(
                after: updated, changes: Self.changes(pages: 4, assets: 2),
                store: store, git: nil, clone: clone)
            #expect(four == "Wiki updated: 4 pages changed.", "\(store)")
            let one = await LibraryRefresh.summary(
                after: updated, changes: Self.changes(pages: 1), store: store, git: nil, clone: clone)
            #expect(one == "Wiki updated: 1 page changed.")
            let assetsOnly = await LibraryRefresh.summary(
                after: updated, changes: Self.changes(pages: 0, assets: 3),
                store: store, git: nil, clone: clone)
            #expect(assetsOnly == "Wiki updated.", "an asset is not a page")
        }
        let unknown = await LibraryRefresh.summary(
            after: updated, changes: nil, store: .snapshot, git: nil, clone: clone)
        #expect(unknown == "Wiki updated.", "no earlier load to compare with, and no history")
    }

    @Test("every other outcome says what it is")
    func summaryOfOtherOutcomes() async {
        let clone = URL(fileURLWithPath: "/nonexistent")
        let outcomes: [GitService.SyncOutcome] = [
            .alreadyCurrent(at: Self.head), .cloned, .offline, .failed("boom"),
        ]
        for outcome in outcomes {
            let summary = await LibraryRefresh.summary(
                after: outcome, changes: Self.changes(pages: 2), store: .git, git: nil, clone: clone)
            #expect(summary == outcome.summary)
        }
    }

    @Test("a pull with no earlier load to compare with asks git, on a clone")
    func summaryFromGit() async throws {
        guard let repository = await FixtureRepository.make() else { return }
        defer { repository.delete() }
        try repository.write("content/a.md", "a\n")
        let firstCommit = await repository.commit("one", date: 1_700_000_000)
        try repository.write("content/a.md", "a, again\n")
        try repository.write("content/b.md", "b\n")
        try repository.write("content/Files/c.png", "c")
        let secondCommit = await repository.commit("two", date: 1_700_000_100)
        let first = try #require(firstCommit)
        let second = try #require(secondCommit)

        let summary = await LibraryRefresh.summary(
            after: .updated(from: first, to: second), changes: nil, store: .git,
            git: repository.service, clone: repository.root)
        #expect(summary == "Wiki updated: 2 pages changed.")
    }

    // MARK: The commit

    @Test("the commit a sync's outcome names, and the one a pull started from")
    func headAndBase() {
        #expect(LibraryRefresh.head(after: .updated(from: Self.other, to: Self.head)) == Self.head)
        #expect(LibraryRefresh.head(after: .alreadyCurrent(at: Self.head)) == Self.head)
        #expect(LibraryRefresh.head(after: .alreadyCurrent(at: "")) == nil, "git could not say")
        #expect(LibraryRefresh.head(after: .cloned) == nil)
        #expect(LibraryRefresh.head(after: nil) == nil)
        #expect(LibraryRefresh.base(of: .updated(from: Self.other, to: Self.head)) == Self.other)
        #expect(LibraryRefresh.base(of: .updated(from: "", to: Self.head)) == nil)
        #expect(LibraryRefresh.base(of: .alreadyCurrent(at: Self.head)) == nil)
        #expect(LibraryRefresh.base(of: nil) == nil)
    }

    @Test("a snapshot's commit and date come from its marker, and it has no page dates")
    func snapshotFacts() async throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(support: support)
        try FileManager.default.createDirectory(at: paths.clone, withIntermediateDirectories: true)
        let marker = SnapshotService.Marker(
            sha: Self.head, commitDate: Date(timeIntervalSince1970: 1_756_000_000),
            fetchedAt: Date(timeIntervalSince1970: 1_756_100_000))
        try SnapshotService.write(marker, in: paths.clone)

        let revision = await LibraryRefresh.currentRevision(
            store: .snapshot, git: nil, clone: paths.clone)
        #expect(revision == Self.head)
        let facts = await LibraryRefresh.revisionFacts(
            store: .snapshot, git: nil, paths: paths, after: .updated(from: Self.other, to: Self.head))
        #expect(facts == RevisionFacts(
            head: Self.head, date: Date(timeIntervalSince1970: 1_756_000_000), modifiedDates: [:]))
    }

    @Test("a clone's commit comes from git")
    func cloneRevision() async throws {
        guard let repository = await FixtureRepository.make() else { return }
        defer { repository.delete() }
        try repository.write("content/a.md", "a\n")
        let commit = await repository.commit("one", date: 1_700_000_000)
        let revision = await LibraryRefresh.currentRevision(
            store: .git, git: repository.service, clone: repository.root)
        #expect(revision != nil)
        #expect(revision == commit)
    }

    // MARK: Housekeeping

    @Test("the jobs' worktrees are looked after at launch and after a clone or a reset, not after a pull")
    func housekeeping() {
        #expect(LibraryRefresh.runsJobHousekeeping(.launch))
        #expect(LibraryRefresh.runsJobHousekeeping(.cloned))
        #expect(LibraryRefresh.runsJobHousekeeping(.reset))
        #expect(!LibraryRefresh.runsJobHousekeeping(.pulled))
        #expect(!LibraryRefresh.runsJobHousekeeping(.offline))
        #expect(!LibraryRefresh.runsJobHousekeeping(.rebuild))
    }
}
