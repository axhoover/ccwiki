import Foundation
import Testing
@testable import CCwiki

/// Each page's "last changed" date, from git: the latest committer date among
/// the non-merge commits that touch it. Kept at one commit and brought
/// forward over what a pull brings, it must equal the whole history read
/// again (plans/reader-comforts.md §3.7).
struct ModifiedDatesTests {

    static func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    @Test("the latest date wins, in whatever order git lists the commits")
    func latestWins() {
        let log = "\u{0}1700002000\n\ncontent/a.md\nREADME.md\n"
            + "\u{0}1700005000\n\ncontent/a.md\ncontent/Files/b.png\n"
            + "\u{0}1700001000\n\ncontent/b.md\n"
        let dates = GitService.modifiedDates(fromLog: log)
        #expect(dates == [
            "a.md": Self.date(1_700_005_000),
            "Files/b.png": Self.date(1_700_005_000),
            "b.md": Self.date(1_700_001_000),
        ])
    }

    @Test("merging two sets of dates keeps the later date for a file in both")
    func merging() {
        let merged = LibraryRefresh.merged(
            ["a.md": Self.date(5), "b.md": Self.date(1)],
            ["a.md": Self.date(2), "c.md": Self.date(3)])
        #expect(merged == ["a.md": Self.date(5), "b.md": Self.date(1), "c.md": Self.date(3)])
    }

    /// main:  c1 (t1: a, b) ── c2 (t5: a) ──────── m (merge, t6)
    ///          └── side: c3 (t2: a, c) ────────────┘
    ///
    /// The side branch's commit is older than main's last, so the range
    /// c2..m brings an older date for `a`; only the latest-date rule keeps
    /// c2's.
    struct MergedBranch {
        let repository: FixtureRepository
        let c1, c2, c3, merge: String

        static func make(at place: URL? = nil) async throws -> MergedBranch? {
            guard let repository = await FixtureRepository.make(at: place) else { return nil }
            // Main edits a's first line and the side branch its last, so the
            // two merge without a conflict.
            try repository.write("content/a.md", "one\ntwo\nthree\nfour\nfive\n")
            try repository.write("content/b.md", "b\n")
            try repository.write("README.md", "not content\n")
            let first = await repository.commit("c1", date: 1_700_001_000)
            try repository.write("content/a.md", "ONE\ntwo\nthree\nfour\nfive\n")
            let second = await repository.commit("c2", date: 1_700_005_000)

            let c1 = try #require(first)
            let branched = await repository.run(["checkout", "-q", "-b", "side", c1])
            #expect(branched.succeeded)
            try repository.write("content/a.md", "one\ntwo\nthree\nfour\nFIVE\n")
            try repository.write("content/c.md", "c\n")
            let third = await repository.commit("c3", date: 1_700_002_000)
            let back = await repository.run(["checkout", "-q", "main"])
            #expect(back.succeeded)
            let merged = await repository.run(
                ["merge", "-q", "--no-ff", "--no-edit", "side"], date: 1_700_006_000)
            #expect(merged.succeeded)
            let merge = await repository.head()

            let c2 = try #require(second)
            let c3 = try #require(third)
            let m = try #require(merge)
            return MergedBranch(repository: repository, c1: c1, c2: c2, c3: c3, merge: m)
        }
    }

    @Test("dates at one commit, brought forward over a merged range, equal the whole history")
    func rangeMergeEqualsHistory() async throws {
        guard let fixture = try await MergedBranch.make() else { return }
        defer { fixture.repository.delete() }
        let git = fixture.repository.service
        let clone = fixture.repository.root

        let whole = await git.modifiedDates(in: clone)
        #expect(whole == [
            "a.md": Self.date(1_700_005_000),
            "b.md": Self.date(1_700_001_000),
            "c.md": Self.date(1_700_002_000),
        ])

        // The dates as they were at c2, from the history c2 had.
        let logAtC2 = try await Self.log(fixture, at: fixture.c2)
        let atC2 = GitService.modifiedDates(fromLog: logAtC2)
        #expect(atC2["a.md"] == Self.date(1_700_005_000))
        let pulled = await git.modifiedDates(in: clone, since: fixture.c2)
        let range = try #require(pulled)
        #expect(range == ["a.md": Self.date(1_700_002_000), "c.md": Self.date(1_700_002_000)],
                "the range holds only the side branch's commit")
        #expect(LibraryRefresh.merged(atC2, range) == whole)

        let mainHasC2 = await git.isAncestor(fixture.c2, of: fixture.merge, in: clone)
        let mergeHasItself = await git.isAncestor(fixture.merge, of: fixture.merge, in: clone)
        let c2HasC3 = await git.isAncestor(fixture.c3, of: fixture.c2, in: clone)
        #expect(mainHasC2)
        #expect(mergeHasItself)
        #expect(!c2HasC3)
        let unknown = await git.modifiedDates(
            in: clone, since: "0000000000000000000000000000000000000000")
        #expect(unknown == nil, "a commit this clone does not have")
    }

    /// The whole-history log at `commit`, as `modifiedDates(in:)` reads it.
    static func log(_ fixture: MergedBranch, at commit: String) async throws -> String {
        let result = await fixture.repository.run([
            "log", "--name-only", "--no-merges", "--format=%x00%ct", commit, "--", "content",
        ])
        #expect(result.succeeded)
        return result.stdout
    }

    @Test("a load's dates come from the cache, the pulled range or the whole history, and always agree")
    func revisionFactsUseTheCache() async throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-dates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(support: support)
        guard let repository = await FixtureRepository.make(at: paths.clone) else { return }
        let git = repository.service
        let cache = ModifiedDatesCache.url(in: paths)

        try repository.write("content/a.md", "a\n")
        let firstCommit = await repository.commit("one", date: 1_700_001_000)
        let first = try #require(firstCommit)

        // The first load reads the whole history and keeps it.
        let launch = await LibraryRefresh.revisionFacts(
            store: .git, git: git, paths: paths, after: nil)
        #expect(launch.head == first)
        #expect(launch.date == Self.date(1_700_001_000))
        #expect(launch.modifiedDates == ["a.md": Self.date(1_700_001_000)])
        #expect(ModifiedDatesCache.read(from: cache)?.revision == first)

        // A pull: the dates come from the commits it brought.
        try repository.write("content/b.md", "b\n")
        let secondCommit = await repository.commit("two", date: 1_700_002_000)
        let second = try #require(secondCommit)
        let pulled = await LibraryRefresh.revisionFacts(
            store: .git, git: git, paths: paths, after: .updated(from: first, to: second))
        #expect(pulled.head == second)
        let history = await git.modifiedDates(in: paths.clone)
        #expect(pulled.modifiedDates == history)
        #expect(history.count == 2)
        #expect(ModifiedDatesCache.read(from: cache)?.revision == second)
        let (_, source) = await LibraryRefresh.modifiedDates(
            git: git, clone: paths.clone, head: second, pulledFrom: nil, cache: cache)
        #expect(source == .cache)

        // The pull again, from a cache at its base: only the commits it
        // brought are read, whether the outcome names the base or git is
        // asked whether HEAD has the cached commit in its history.
        ModifiedDatesCache(revision: first, dates: launch.modifiedDates).write(to: cache)
        let (viaBase, baseSource) = await LibraryRefresh.modifiedDates(
            git: git, clone: paths.clone, head: second, pulledFrom: first, cache: cache)
        #expect(baseSource == .range)
        #expect(viaBase == history)
        #expect(ModifiedDatesCache.read(from: cache)?.revision == second)

        ModifiedDatesCache(revision: first, dates: launch.modifiedDates).write(to: cache)
        let (viaAncestry, ancestrySource) = await LibraryRefresh.modifiedDates(
            git: git, clone: paths.clone, head: second, pulledFrom: nil, cache: cache)
        #expect(ancestrySource == .range)
        #expect(viaAncestry == history)

        // A cache from a commit this clone never had: the whole history.
        ModifiedDatesCache(revision: "not-a-commit", dates: ["a.md": Self.date(1)]).write(to: cache)
        let (dates, fallback) = await LibraryRefresh.modifiedDates(
            git: git, clone: paths.clone, head: second, pulledFrom: nil, cache: cache)
        #expect(fallback == .history)
        #expect(dates == pulled.modifiedDates)

        // A cache it cannot read is no cache.
        try Data("{".utf8).write(to: cache)
        #expect(ModifiedDatesCache.read(from: cache) == nil)
    }

    @Test("the cache round-trips, and another version of it is ignored")
    func cacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-dates-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index/modified-dates.json")
        let cache = ModifiedDatesCache(
            revision: "abc", dates: ["a.md": Self.date(1_700_000_000), "b c.md": Self.date(2)])
        cache.write(to: url)
        #expect(ModifiedDatesCache.read(from: url) == cache)

        var future = cache
        future.version = ModifiedDatesCache.currentVersion + 1
        future.write(to: url)
        #expect(ModifiedDatesCache.read(from: url) == nil)
    }
}
