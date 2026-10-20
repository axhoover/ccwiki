import Foundation
import Testing
@testable import CCwiki

/// What a load costs on the real wiki (plans/reader-comforts.md §3.8,
/// plans/efficiency.md §2.3).
///
/// Skipped unless `CCWIKI_WIKI` points at a clone; CI clones the wiki for it.
/// Every run prints three reports, which land in the CI log beside the
/// relevance report:
///
/// - **the load:** the full build, each phase the fastest of five runs; the
///   update after three kinds of edit; and the search index synced in full,
///   as a no-op and after one page changed;
/// - **its parts**, each timed alone on the library already loaded, with the
///   counts that check the ports the efficiency plan was counted with, and
///   one ⌘O keystroke;
/// - **backlinks at 46685be against 21df5d7**, in one process: the phase as
///   D1 timed it, each of 21df5d7's four changes to it alone, and all four.
///
/// Each report heads with the wiki's commit and the Swift that built it, and
/// says whether the suite ran alone (CI's standalone step sets
/// `CCWIKI_TIMINGS_ALONE=1`) or beside the other suites (`make
/// test-corpus`). The parts call only what every efficiency track keeps
/// (efficiency.md §2.1), so the lines keep their meaning as the tracks land.
/// No assertion is about time: shared runners are too noisy for that.
///
/// **Only a release build decides D6.** `make test-corpus` runs a debug
/// build (-Onone) beside every other corpus suite, and the pure Swift a
/// load runs can be several times slower that way than in the app, so the
/// report says which it was and holds only a release build's in-memory
/// total against §3.2's 300 ms. That run is this suite alone:
/// `CCWIKI_WIKI=… CCWIKI_TIMINGS_ALONE=1 swift test -c release
/// -Xswiftc -enable-testing --no-parallel --filter IncrementalCorpusTests`.
///
/// **It never touches the clone it reads.** `make test-corpus` defaults to
/// the release's own clone, and an edit there would make the next pull fail
/// as diverged. So it copies what a load reads to a temporary directory,
/// edits only the copy, and checks afterwards that the clone's fingerprints
/// are what they were.
@Suite(.serialized) struct IncrementalCorpusTests {

    #if DEBUG
    /// What the numbers were measured on, at the head of each report.
    static let configuration = "a debug build (-Onone)"
    /// Beside the in-memory total: the threshold, when it can be held
    /// against it, and otherwise why not.
    static let threshold = "; not comparable with §3.2's 300 ms, which is a release build's"
    #else
    static let configuration = "a release build"
    static let threshold = "; §3.2 builds reuse (D6) only above 300 ms"
    #endif

    /// How many times each timed part runs; a line reports the fastest.
    static let runs = 5

    /// Whether CI's standalone step is running the timing suites by
    /// themselves, rather than `make test-corpus` running every suite at once.
    static let isAlone = ProcessInfo.processInfo.environment["CCWIKI_TIMINGS_ALONE"] == "1"

    /// How a report's numbers were measured, for its head: alone or beside
    /// the other suites, on which build, from which commit of the wiki, so a
    /// change in the corpus is never taken for one in the code
    /// (efficiency.md §1.1), and with which Swift.
    static func measuredOn(_ source: URL) -> String {
        (isAlone ? "measured alone" : "measured beside the other suites")
            + " on \(configuration), wiki \(wikiCommit(source)), \(swiftVersion)"
    }

    /// The clone's head: its short hash and commit date.
    static func wikiCommit(_ clone: URL) -> String {
        output(of: ["git", "-C", clone.path(percentEncoded: false), "log", "-1", "--format=%h %cs"])
            ?? "at an unknown commit"
    }

    /// `swift --version`'s line naming the Swift, or the compiler's version
    /// when the tool cannot be run.
    static var swiftVersion: String {
        output(of: ["swift", "--version"])?
            .components(separatedBy: "\n")
            .first { $0.contains("Swift version") }
            ?? compilerVersion
    }

    static var compilerVersion: String {
        #if compiler(>=6.2)
        return "Swift 6.2 or later"
        #elseif compiler(>=6.1)
        return "Swift 6.1"
        #else
        return "Swift 6.0"
        #endif
    }

    /// What a command prints on its standard output, trimmed; nil when it
    /// cannot run, fails, or prints nothing.
    static func output(of arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

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

    /// `work` run `runs` times: the fastest time, and what the last run
    /// returned.
    static func fastestRun<T>(_ work: () throws -> T) rethrows -> (value: T, duration: Duration) {
        var best = try timed(work)
        for _ in 1..<runs {
            let run = try timed(work)
            best = (run.value, min(best.duration, run.duration))
        }
        return best
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
        // Each phase is its own fastest run: the run with the fastest total
        // can hold a phase another run did quicker (efficiency.md §1.1).
        var warmup = LoadTimings()
        let original = LoadedLibrary.build(cloneRoot: clone, timings: &warmup)
        let runs = (0..<Self.runs).map { _ -> LoadTimings in
            var timings = LoadTimings()
            _ = LoadedLibrary.build(cloneRoot: clone, timings: &timings)
            return timings
        }
        let phases = LoadTimings.Phase.allCases.compactMap { phase -> String? in
            guard let fastest = runs.compactMap({ $0.durations[phase] }).min() else { return nil }
            return "\(phase.rawValue) \(LoadTimings.format(fastest))"
        }
        let totals = runs.map(\.building)
        lines.append("full build of \(original.index.pages.count) pages, each phase the fastest of "
            + "\(runs.count): " + phases.joined(separator: " · "))
        lines.append("  in memory: fastest \(LoadTimings.format(Self.fastest(totals))), median "
            + "\(LoadTimings.format(Self.median(totals)))" + Self.threshold)

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
        lines.append("search sync, one run each: " + searchLines.joined(separator: "; "))
        #expect(reports.map(\.rebuiltFromScratch) == [true, false, false])
        #expect(reports.map(\.writes) == [original.index.pages.count, 0, 1])

        print("Incremental indexing on the real wiki (plans/reader-comforts.md §3.8), "
            + "\(Self.measuredOn(source)):\n"
            + lines.map { "  " + $0 }.joined(separator: "\n"))

        #expect(ContentFingerprints.scan(cloneRoot: source) == untouched,
                "the clone CCWIKI_WIKI names must be read, never written")
    }

    // MARK: The parts of a load

    /// One way to find every line end in every body (efficiency.md §2.3):
    /// (a) is how CodeMask, `headings()` and the backlink context find them
    /// at 21df5d7, (c) how they did before it, and (d) the byte scan L1
    /// proposes. All four are written here, not called, so the line keeps
    /// its meaning whatever the app's code becomes.
    enum LineEndScan: String, CaseIterable {
        case keyPath = "(a) key path"
        case closure = "(b) closure"
        case newline = "(c) \"\\n\" alone"
        case bytes = "(d) UTF-8 bytes"

        /// The lines in `bodies`, counted as CodeMask's loop walks them: a
        /// last line counts without its line end, and CR LF is one end.
        func lines(in bodies: [String]) -> Int {
            var count = 0
            switch self {
            case .keyPath:
                for text in bodies {
                    var lineStart = text.startIndex
                    while lineStart < text.endIndex {
                        let lineEnd = text[lineStart...].firstIndex(where: \.isTimedLineEnding)
                            ?? text.endIndex
                        count += 1
                        lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
                    }
                }
            case .closure:
                for text in bodies {
                    var lineStart = text.startIndex
                    while lineStart < text.endIndex {
                        let lineEnd = text[lineStart...].firstIndex { $0.isTimedLineEnding }
                            ?? text.endIndex
                        count += 1
                        lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
                    }
                }
            case .newline:
                for text in bodies {
                    var lineStart = text.startIndex
                    while lineStart < text.endIndex {
                        let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
                        count += 1
                        lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
                    }
                }
            case .bytes:
                for text in bodies {
                    let utf8 = text.utf8
                    var lineStart = utf8.startIndex
                    while lineStart < utf8.endIndex {
                        count += 1
                        guard let lineEnd = utf8[lineStart...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D })
                        else { break }
                        let next = utf8.index(after: lineEnd)
                        lineStart = utf8[lineEnd] == 0x0D && next < utf8.endIndex && utf8[next] == 0x0A
                            ? utf8.index(after: next) : next
                    }
                }
            }
            return count
        }
    }

    /// What `resolve` reads of a link: links that share it resolve alike.
    private struct ResolveKey: Hashable {
        let target: String
        let rawAnchor: String?
        let isEmbed: Bool
    }

    /// A `[[wikilink]]` or `![[embed]]`, rather than a markdown link.
    static func isWikilink(_ link: Wikilink, in body: String) -> Bool {
        body[link.range].hasPrefix("[[") || body[link.range].hasPrefix("![[")
    }

    /// The line holding `range`, cut as the backlinks pane's context cuts it
    /// at 21df5d7: back to the line end before it, on to the next.
    static func line(around range: Range<String.Index>, in body: String) -> String {
        var start = range.lowerBound
        while start > body.startIndex {
            let previous = body.index(before: start)
            if body[previous].isTimedLineEnding { break }
            start = previous
        }
        let end = body[range.upperBound...].firstIndex(where: \.isTimedLineEnding) ?? body.endIndex
        return String(body[start..<end])
    }

    /// The path a target names, if it is a page.
    static func pagePath(_ target: WikiIndex.Target) -> String? {
        if case .page(let path, _) = target { return path }
        return nil
    }

    /// A word for what the explorer answered.
    static func outcome(of answer: Derivation.Answer) -> String {
        if case .derived = answer { return "derived" }
        if case .notDerived = answer { return "not derived" }
        return "unsupported"
    }

    @Test("each part of a load timed alone, with the counts that check the ports")
    func parts() async throws {
        guard let source = Self.source else { return }
        let untouched = ContentFingerprints.scan(cloneRoot: source)
        let clone = try Self.copy(of: source)
        defer { try? FileManager.default.removeItem(at: clone) }
        func ms(_ duration: Duration) -> String { LoadTimings.format(duration) }

        let library = LoadedLibrary.build(cloneRoot: clone)
        let index = library.index
        let pages = index.pages.values.sorted { $0.path < $1.path }
        let bodies = pages.map(\.body)
        let concepts = pages.filter { $0.kind != .reference }
        var lines: [String] = []

        // The counts efficiency.md §1.2 took from ports of this code, taken
        // from the code: every link, and every backlink as backlinkMap()
        // keeps it, the first link from each page to each other page.
        var links: [(page: WikiPage, link: Wikilink)] = []
        for page in pages {
            for link in WikiIndex.outgoingLinks(in: page.body) {
                links.append((page: page, link: link))
            }
        }
        let wikilinks = links.count(where: { Self.isWikilink($0.link, in: $0.page.body) })
        let keys = Set(links.map {
            ResolveKey(target: $0.link.target, rawAnchor: $0.link.rawAnchor, isEmbed: $0.link.isEmbed)
        })
        let targets = Set(links.map { $0.link.target })
        var contextLines: [String] = []
        var backlinksTo: [String: Int] = [:]
        var linkedFrom: [String: Set<String>] = [:]
        for (page, link) in links {
            guard case .page(let target, _) = index.resolve(link, from: page.path),
                  target != page.path,
                  linkedFrom[page.path, default: []].insert(target).inserted
            else { continue }
            backlinksTo[target, default: 0] += 1
            contextLines.append(Self.line(around: link.range, in: page.body))
        }
        let backlinkCount = library.backlinks.values.reduce(0) { $0 + $1.count }
        #expect(contextLines.count == backlinkCount,
                "the backlinks counted here are the ones backlinkMap() builds")
        #expect(backlinksTo.count == library.backlinks.count)
        let scalars = bodies.reduce(0) { $0 + $1.unicodeScalars.count }
        let withCR = bodies.count(where: { $0.utf8.contains(0x0D) })
        let headings = Self.fastestRun { concepts.reduce(0) { $0 + $1.headings().count } }
        lines.append("counts: \(pages.count) pages, \(scalars) scalars of body, \(withCR) bodies with \\r")
        lines.append("  \(links.count) links (\(wikilinks) wikilinks, \(links.count - wikilinks) markdown "
            + "links), \(keys.count) distinct resolve keys, \(targets.count) distinct targets")
        lines.append("  \(contextLines.count) backlinks to \(backlinksTo.count) pages, at most "
            + "\(backlinksTo.values.max() ?? 0) to one; \(headings.value) headings on "
            + "\(concepts.count) non-reference pages")

        // Line ends, four ways over the same bodies (efficiency.md §1.3).
        var lineCounts: [LineEndScan: Int] = [:]
        var scanTimes: [String] = []
        for scan in LineEndScan.allCases {
            let run = Self.fastestRun { scan.lines(in: bodies) }
            lineCounts[scan] = run.value
            scanTimes.append("\(scan.rawValue) \(ms(run.duration))")
        }
        let lineCount = lineCounts[.keyPath] ?? 0
        #expect(lineCounts[.closure] == lineCount, "(a) and (b) find the same line ends")
        #expect(lineCounts[.bytes] == lineCount, "(a) and (d) find the same line ends")
        if withCR == 0 {
            #expect(lineCounts[.newline] == lineCount, "with no \\r in any body, (c) finds them too")
        }
        lines.append("line ends, A/B over every body, \(lineCount) lines: "
            + scanTimes.joined(separator: " · "))
        if Set(lineCounts.values).count > 1 {
            lines.append("  lines found: " + LineEndScan.allCases.map { scan in
                "\(scan.rawValue) \(lineCounts[scan] ?? 0)"
            }.joined(separator: " · "))
        }

        // The load path, part by part.
        let codeMask = Self.fastestRun { bodies.reduce(0) { $0 + CodeMask.inertRanges(in: $1).count } }
        let outgoing = Self.fastestRun { bodies.reduce(0) { $0 + WikiIndex.outgoingLinks(in: $1).count } }
        let resolved = Self.fastestRun {
            links.count(where: { index.resolve($0.link, from: $0.page.path).isResolved })
        }
        let plain = Self.fastestRun { contextLines.reduce(0) { $0 + WikiIndex.plainText($1).count } }
        let backlinkMap = Self.fastestRun { index.backlinkMap() }
        let plainInput = contextLines.reduce(0) { $0 + $1.unicodeScalars.count }
        lines.append("load path: CodeMask.inertRanges, every body \(ms(codeMask.duration)) · "
            + "outgoingLinks, every body \(ms(outgoing.duration)) · resolve, every link "
            + "\(ms(resolved.duration)) · plainText, every backlink's line (\(plainInput) scalars) "
            + "\(ms(plain.duration)) · backlinkMap() \(ms(backlinkMap.duration))")

        let scopes = Self.fastestRun {
            bodies.count(where: { PreviewExcerpt.scope(of: $0, anchor: nil) != nil })
        }
        let previews = Self.fastestRun {
            LinkPreviews(index: index, manifest: library.manifest, labels: library.labels)
        }
        lines.append("previews: PreviewExcerpt.scope, every body \(ms(scopes.duration)) · "
            + "LinkPreviews \(ms(previews.duration))")

        // The derivation, with the quoted pages read beforehand, so the line
        // is the check and not the disk.
        let derivation = Self.fastestRun { Derivation(manifest: library.manifest) }
        let contentRoot = clone.appending(path: "content")
        var quoted: [String: String] = [:]
        _ = library.derivation.missingQuotes { path in
            let text = try? String(contentsOf: contentRoot.appending(path: path), encoding: .utf8)
            quoted[path] = text
            return text
        }
        let quotes = Self.fastestRun { library.derivation.missingQuotes { quoted[$0] } }
        lines.append("derivation: Derivation(manifest:) \(ms(derivation.duration)) · missingQuotes, "
            + "\(quoted.count) pages read beforehand, \(quotes.value.count) quotes missing "
            + "\(ms(quotes.duration))")

        // The explorer's two questions, in both settings.
        let settings: [Derivation.Options] = [.standard, .all]
        lines.append("explorer, standard / idealised models on:")
        for (start, target) in [("owf", "pke"), ("pke", "ot"), ("ddh", "io")] {
            var cells: [String] = []
            for options in settings {
                let run = Self.fastestRun {
                    library.derivation.answer(from: [start], to: target, options: options)
                }
                cells.append("\(ms(run.duration)) \(Self.outcome(of: run.value))")
            }
            lines.append("  answer \(start) ⇒ \(target): " + cells.joined(separator: " / "))
        }
        for target in ["pke", "ot", "mpc", "nizk"] {
            var cells: [String] = []
            for options in settings {
                let run = Self.fastestRun { library.derivation.implying(target, options: options) }
                cells.append("\(ms(run.duration)) (\(run.value.singleCount) singles, "
                    + "\(run.value.pairCount) pairs)")
            }
            lines.append("  implying \(target): " + cells.joined(separator: " / "))
        }

        // Search: the rankers every sync builds, the headings and bodies a
        // full sync writes, then the syncs themselves.
        let conceptRanker = Self.fastestRun { ConceptRanker(pages: pages) }
        let referenceRanker = Self.fastestRun {
            ReferenceRanker(pages: pages, backlinks: library.backlinks)
        }
        let indexable = Self.fastestRun {
            bodies.reduce(0) { $0 + SearchIndex.indexableBody($1).count }
        }
        let clock = ContinuousClock()
        func timedSync(_ store: SearchIndex) async throws -> (report: SyncReport, duration: Duration) {
            let start = clock.now
            let report = try await store.sync(
                pages: index.allPages, backlinks: library.backlinks,
                fingerprints: library.fingerprints, builder: "IncrementalCorpusTests")
            return (report, start.duration(to: clock.now))
        }
        let store = SearchIndex(path: clone.appending(path: "parts.sqlite3"))
        _ = try await timedSync(store)
        var noOps: [Duration] = []
        for _ in 0..<Self.runs {
            let run = try await timedSync(store)
            #expect(run.report.writes == 0)
            noOps.append(run.duration)
        }
        var fullSyncs: [Duration] = []
        for run in 0..<3 {
            let fresh = try await timedSync(SearchIndex(path: clone.appending(path: "parts-\(run).sqlite3")))
            #expect(fresh.report.rebuiltFromScratch)
            fullSyncs.append(fresh.duration)
        }
        lines.append("search: ConceptRanker \(ms(conceptRanker.duration)) · ReferenceRanker "
            + "\(ms(referenceRanker.duration)) · headings(), \(concepts.count) non-reference pages "
            + "\(ms(headings.duration)) · indexableBody, every body \(ms(indexable.duration))")
        lines.append("  sync as a no-op, the fastest of \(noOps.count) \(ms(Self.fastest(noOps))) · "
            + "sync in full into a fresh file, the fastest of \(fullSyncs.count) "
            + "\(ms(Self.fastest(fullSyncs)))")

        // ⌘O as the quick switcher runs it on each keystroke, on the main
        // actor: every listed page's title, aliases, paper title and slug
        // through FuzzyMatcher (efficiency.md §4.2 defers its arrays).
        let hidden = library.manifest.unlistedPaths
        let listed = pages.filter { !hidden.contains($0.path) }
        var names = 0
        for page in listed {
            names += 2 + page.aliases.count + (page.kind == .reference ? 1 : 0)
        }
        var keystrokes: [String] = []
        for query in ["", "p", "pr", "prf"] {
            let run = Self.fastestRun { index.quickSwitch(query, excluding: hidden, recent: []) }
            let label = query.isEmpty ? "opening, no query" : "“\(query)”"
            keystrokes.append("\(label) \(ms(run.duration))")
        }
        lines.append("⌘O, one keystroke over \(listed.count) pages and \(names) names: "
            + keystrokes.joined(separator: " · "))

        print("The parts of a load on the real wiki (plans/efficiency.md §2.3), each the fastest of "
            + "\(Self.runs) runs on the library already loaded unless it says otherwise, "
            + "\(Self.measuredOn(source)):\n"
            + lines.map { "  " + $0 }.joined(separator: "\n"))

        #expect(ContentFingerprints.scan(cloneRoot: source) == untouched,
                "the clone CCWIKI_WIKI names must be read, never written")
    }

    // MARK: Backlinks, 46685be against 21df5d7

    /// The backlinks phase went from 680 ms at 46685be to 1,605 ms at
    /// 21df5d7 on the same wiki (efficiency.md §1.1). Here both run in one
    /// process on one library, through `LegacyD1.D1Backlinks`: 46685be's path,
    /// with each of 21df5d7's four changes to it alone, and with all four,
    /// interleaved run by run so whatever slows the runner slows them alike.
    /// Old and new must agree wherever no body holds `\r`, which is the
    /// case the old line ends got wrong, and no link resolves to another
    /// page for the old `resolve`.
    @Test("backlinks at 46685be against 21df5d7, each change alone, in one process")
    func backlinksOldAgainstNew() throws {
        guard let source = Self.source else { return }
        typealias D1 = LegacyD1.D1Backlinks
        let index = WikiIndex.build(contentRoot: source.appending(path: "content"))
        let variants: [(name: String, changes: D1.Changes)] = [
            ("46685be, copied", []),
            ("with CodeMask's line ends by key path", .codeMaskLineEnds),
            ("with the context walks' three line endings", .contextLineEnds),
            ("with GithubSlugger's Unicode properties", .sluggerProperties),
            ("with resolve's segments", .resolveSegments),
            ("all four: 21df5d7, copied", .all),
        ]
        let copies = variants.map { D1(index: index, changes: $0.changes) }

        var fastest = [Duration](repeating: .zero, count: copies.count)
        var maps = [[String: [D1.Backlink]]](repeating: [:], count: copies.count)
        var built: [String: [WikiIndex.Backlink]] = [:]
        var builtFastest = Duration.zero
        for run in 0..<Self.runs {
            for (k, copy) in copies.enumerated() {
                let measured = Self.timed { copy.backlinkMap() }
                maps[k] = measured.value
                fastest[k] = run == 0 ? measured.duration : min(fastest[k], measured.duration)
            }
            let measured = Self.timed { index.backlinkMap() }
            built = measured.value
            builtFastest = run == 0 ? measured.duration : min(builtFastest, measured.duration)
        }

        // The copy is 21df5d7's path: it parses, resolves and builds what
        // the app does, on every page.
        let newest = copies[copies.count - 1]
        let oldest = copies[0]
        var unlike: [String] = []
        var moved = 0
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            let links = WikiIndex.outgoingLinks(in: page.body)
            if newest.outgoingLinks(in: page.body) != links { unlike.append(page.path) }
            for link in links {
                let target = index.resolve(link, from: page.path)
                if newest.resolve(link, from: page.path) != target {
                    unlike.append("\(page.path): \(page.body[link.range])")
                }
                if Self.pagePath(oldest.resolve(link, from: page.path)) != Self.pagePath(target) {
                    moved += 1
                }
            }
        }
        let asBuilt = built.mapValues { backlinks in
            backlinks.map { D1.Backlink(sourcePath: $0.sourcePath, context: $0.context) }
        }
        #expect(unlike.isEmpty, "the copy parses and resolves as the app does: \(unlike.prefix(10))")
        #expect(maps[maps.count - 1] == asBuilt, "the copy builds the backlinks backlinkMap() builds")

        let withCR = index.pages.values.count(where: { $0.body.utf8.contains(0x0D) })
        let compared = withCR == 0 && moved == 0
        if compared {
            for (k, map) in maps.enumerated() {
                #expect(map == asBuilt, "\(variants[k].name) gives the backlinks 21df5d7 gives")
            }
        }

        var lines: [String] = []
        for (k, variant) in variants.enumerated() {
            let change = k == 0 ? "" : String(
                format: " (%+.1f ms)", LoadTimings.milliseconds(fastest[k] - fastest[0]))
            lines.append("\(variant.name): \(LoadTimings.format(fastest[k]))" + change)
        }
        lines.append("backlinkMap() as built: \(LoadTimings.format(builtFastest))")
        let count = asBuilt.values.reduce(0) { $0 + $1.count }
        lines.append(compared
            ? "\(count) backlinks to \(asBuilt.count) pages, the same from all six: no body holds \\r, "
                + "and no link resolves to another page at 46685be"
            : "not compared: \(withCR) bodies hold \\r, and \(moved) links resolve to another page "
                + "at 46685be")
        print("Backlinks at 46685be against 21df5d7 (plans/efficiency.md §1.3), in one process, each "
            + "the fastest of \(Self.runs) runs, \(Self.measuredOn(source)):\n"
            + lines.map { "  " + $0 }.joined(separator: "\n"))
    }
}

private extension Character {
    /// 21df5d7's `isMarkdownLineEnding`, for the A/B and the context lines:
    /// `\n`, `\r\n` or a lone `\r`.
    var isTimedLineEnding: Bool { self == "\n" || self == "\r\n" || self == "\r" }
}
