import Foundation
import Testing
@testable import CCwiki

/// What a load costs on the real wiki (plans/reader-comforts.md §3.8).
///
/// Skipped unless `CCWIKI_WIKI` points at a clone; CI clones the wiki for it.
/// Every run prints a report, which lands in the CI log beside the relevance
/// report: the full build phase by phase, the update after three kinds of
/// edit, and the search index synced in full, as a no-op and after one page
/// changed. Those numbers replace §3.1's estimates. No assertion is about
/// time: shared runners are too noisy for that.
///
/// **Only a release build decides D6.** `make test-corpus` runs a debug
/// build (-Onone) beside every other corpus suite, and the pure Swift a
/// load runs can be several times slower that way than in the app, so the
/// report says which it was and holds only a release build's in-memory
/// total against §3.2's 300 ms. That run is this suite alone:
/// `CCWIKI_WIKI=… swift test -c release -Xswiftc -enable-testing
/// --no-parallel --filter IncrementalCorpusTests`.
///
/// **It never touches the clone it reads.** `make test-corpus` defaults to
/// the release's own clone, and an edit there would make the next pull fail
/// as diverged. So it copies what a load reads to a temporary directory,
/// edits only the copy, and checks afterwards that the clone's fingerprints
/// are what they were.
struct IncrementalCorpusTests {

    #if DEBUG
    /// What the numbers were measured on, at the head of the report.
    static let configuration = "a debug build (-Onone) run beside the other suites, "
        + "so not comparable with §3.2's 300 ms"
    /// The threshold, beside the in-memory total only when it can be held
    /// against it.
    static let threshold = ""
    #else
    static let configuration = "a release build"
    static let threshold = "; §3.2 builds reuse (D6) only above 300 ms"
    #endif

    /// The clone `CCWIKI_WIKI` names, when it has a `content/`.
    static var source: URL? {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: path)
        let content = root.appending(path: "content").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: content) ? root : nil
    }

    /// Everything a load reads, copied to a fresh temporary directory.
    static func copy(of source: URL) throws -> URL {
        let manager = FileManager.default
        let copy = manager.temporaryDirectory
            .appending(path: "ccwiki-incremental-\(UUID().uuidString)")
        try manager.createDirectory(at: copy, withIntermediateDirectories: true)
        for item in ["content", ".reductions", "macros.ts"] {
            let from = source.appending(path: item)
            guard manager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try manager.copyItem(at: from, to: copy.appending(path: item))
        }
        return copy
    }

    static func timed<T>(_ work: () throws -> T) rethrows -> (value: T, duration: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try work()
        return (value, start.duration(to: clock.now))
    }

    /// The least disturbed of several runs: the best estimate of what the
    /// work costs on a machine doing nothing else.
    static func fastest(_ durations: [Duration]) -> Duration {
        durations.min() ?? .zero
    }

    static func median(_ durations: [Duration]) -> Duration {
        let sorted = durations.sorted()
        return sorted.isEmpty ? .zero : sorted[sorted.count / 2]
    }

    // MARK: Edits, to the copy only

    /// A body edit to the first primitive page.
    static func editBody(in clone: URL, library: LoadedLibrary) throws -> String {
        let path = try #require(library.index.pages.values
            .filter { $0.kind == .primitive }.map(\.path).sorted().first)
        let file = clone.appending(path: "content").appending(path: path)
        let text = try String(contentsOf: file, encoding: .utf8)
        try (text + "\nEdited by IncrementalCorpusTests.\n").write(to: file, atomically: true, encoding: .utf8)
        return path
    }

    /// One more alias on the first page whose frontmatter lists its aliases
    /// one per line.
    static func addAlias(in clone: URL, library: LoadedLibrary) throws -> String? {
        let content = clone.appending(path: "content")
        for path in library.index.pages.keys.sorted() {
            let file = content.appending(path: path)
            var text = try String(contentsOf: file, encoding: .utf8)
            guard let range = text.range(of: "\naliases:\n"),
                  text[range.upperBound...].hasPrefix("  - ")
            else { continue }
            text.insert(contentsOf: "  - Incremental corpus test alias\n", at: range.upperBound)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return path
        }
        return nil
    }

    /// A new title for the manifest's first object, by id.
    static func editManifest(in clone: URL) throws -> String? {
        let file = clone.appending(path: RelationsManifest.displayPath)
        guard let data = try? Data(contentsOf: file),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var objects = json["objects"] as? [[String: Any]],
              let first = objects.indices.min(by: {
                  (objects[$0]["id"] as? String ?? "") < (objects[$1]["id"] as? String ?? "")
              })
        else { return nil }
        let id = objects[first]["id"] as? String ?? "?"
        objects[first]["title"] = (objects[first]["title"] as? String ?? "") + " (edited)"
        json["objects"] = objects
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        return id
    }

    // MARK: The report

    @Test("what a load costs on the real wiki, printed for the integration PR")
    func measure() async throws {
        guard let source = Self.source else { return }
        let untouched = ContentFingerprints.scan(cloneRoot: source)
        let clone = try Self.copy(of: source)
        defer { try? FileManager.default.removeItem(at: clone) }
        var lines: [String] = []

        // The full build. One run warms the page cache; the rest are timed.
        var warmup = LoadTimings()
        let original = LoadedLibrary.build(cloneRoot: clone, timings: &warmup)
        let runs = (0..<5).map { _ -> LoadTimings in
            var timings = LoadTimings()
            _ = LoadedLibrary.build(cloneRoot: clone, timings: &timings)
            return timings
        }
        let best = try #require(runs.min { $0.building < $1.building })
        lines.append("full build of \(original.index.pages.count) pages, the fastest of "
            + "\(runs.count): \(best)")
        lines.append("  in memory: fastest \(LoadTimings.format(best.building)), median "
            + "\(LoadTimings.format(Self.median(runs.map(\.building))))" + Self.threshold)

        let scans = (0..<5).map { _ in
            Self.timed { ContentFingerprints.scan(cloneRoot: clone) }.duration
        }
        lines.append("fingerprint scan alone, every file read and hashed: "
            + LoadTimings.format(Self.fastest(scans)))

        // Each update builds on the library before its edit, three times.
        var current = original
        func measureUpdate(after edit: String) -> LibraryUpdate {
            let previous = current
            var durations: [Duration] = []
            var result = LoadedLibrary.update(previous, cloneRoot: clone)
            for _ in 0..<3 {
                let run = Self.timed { LoadedLibrary.update(previous, cloneRoot: clone) }
                durations.append(run.duration)
                result = run.value
            }
            lines.append("update after \(edit): \(LoadTimings.format(Self.fastest(durations))) "
                + "(\(result.summary))")
            lines.append("  the last run: \(result.timings)")
            current = result.library
            return result
        }

        let edited = try Self.editBody(in: clone, library: current)
        let bodyEdit = measureUpdate(after: "a one-page edit")
        #expect(bodyEdit.changes?.changedFiles == Set([edited]))
        #expect(!bodyEdit.isFullBuild)
        #expect(!bodyEdit.resolutionChanged)
        #expect(!bodyEdit.labelsChanged)
        let afterEdit = current

        if let aliased = try Self.addAlias(in: clone, library: current) {
            let aliasChange = measureUpdate(after: "an alias change")
            #expect(aliasChange.changes?.changedFiles == Set([aliased]))
            #expect(aliasChange.resolutionChanged)
        } else {
            lines.append("update after an alias change: no page lists its aliases one per line")
        }
        if try Self.editManifest(in: clone) != nil {
            let manifestChange = measureUpdate(after: "a manifest change")
            #expect(manifestChange.changes?.manifestChanged == true)
            #expect(manifestChange.changes?.changedFiles.isEmpty == true)
            #expect(manifestChange.labelsChanged)
        } else {
            lines.append("update after a manifest change: the clone has no manifest")
        }

        // The search index, in a file of the test's own: in full, as a no-op,
        // and after the one-page edit.
        let searchIndex = SearchIndex(path: clone.appending(path: "search.sqlite3"))
        let clock = ContinuousClock()
        var searchLines: [String] = []
        var reports: [SyncReport] = []
        for (name, library) in [("in full", original), ("as a no-op", original),
                                ("after \(edited) changed", afterEdit)] {
            let start = clock.now
            let report = try await searchIndex.sync(
                pages: library.index.allPages, backlinks: library.backlinks,
                fingerprints: library.fingerprints, builder: "IncrementalCorpusTests")
            let duration = start.duration(to: clock.now)
            searchLines.append("\(name) \(LoadTimings.format(duration)) (\(report.summary))")
            reports.append(report)
        }
        lines.append("search sync: " + searchLines.joined(separator: "; "))
        #expect(reports.map(\.rebuiltFromScratch) == [true, false, false])
        #expect(reports.map(\.writes) == [original.index.pages.count, 0, 1])

        print("Incremental indexing on the real wiki (plans/reader-comforts.md §3.8), "
            + "measured on \(Self.configuration):\n"
            + lines.map { "  " + $0 }.joined(separator: "\n"))

        #expect(ContentFingerprints.scan(cloneRoot: source) == untouched,
                "the clone CCWIKI_WIKI names must be read, never written")
    }
}
