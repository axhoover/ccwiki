import Foundation
import OSLog

/// Everything the app reads from the clone, built off the main actor and
/// handed to `AppModel` in one piece, so no view sees half a library. Named
/// fields rather than a tuple: the manifest, the labels and the derivations
/// built from it must all come from the same load.
struct LoadedLibrary: Sendable {
    let index: WikiIndex
    let backlinks: [String: [WikiIndex.Backlink]]
    let manifest: RelationsManifest
    let labels: RelationLabels
    let textGrep: TextGrep
    let derivation: Derivation
    let linkPreviews: LinkPreviews
    /// What the files held when this was built, for the next load to
    /// compare with (plans/reader-comforts.md §3.3).
    let fingerprints: ContentFingerprints

    /// The definition: everything from the files. The full build stays the
    /// definition however loads come to reuse parts of it (§3.5). Logs how
    /// long each part took, under category `library`.
    static func build(cloneRoot: URL) -> LoadedLibrary {
        var timings = LoadTimings()
        let library = build(cloneRoot: cloneRoot, timings: &timings)
        let message = "Built the library: \(library.index.pages.count) pages. \(timings)"
        Logger.library.notice("\(message, privacy: .public)")
        return library
    }

    /// `build`, adding how long each phase took to `timings` and logging
    /// nothing: for `update`, which logs once for the whole load, and for the
    /// corpus suite's report (§3.8).
    static func build(cloneRoot: URL, timings: inout LoadTimings) -> LoadedLibrary {
        // Each file is read once, for its fingerprint and its page together,
        // so the two always describe the same bytes (§3.5).
        let scan = timings.measure(.read) { ContentScan.read(cloneRoot: cloneRoot) }
        let index = timings.measure(.index) {
            WikiIndex.assemble(
                contentRoot: cloneRoot.appending(path: "content"),
                files: scan.files, pages: scan.pages)
        }
        // 343 KB of JSON, and the labels need every hosting page's
        // headings — both cheap, but neither belongs on the main actor. The
        // manifest is decoded from the bytes its fingerprint was taken of;
        // without them, `load` says why it is missing.
        let manifest = timings.measure(.manifest) {
            scan.manifest.map(RelationsManifest.decode) ?? RelationsManifest.load(cloneRoot: cloneRoot)
        }
        let labels = timings.measure(.labels) { RelationLabels(manifest: manifest, index: index) }
        let backlinks = timings.measure(.backlinks) { index.backlinkMap() }
        let textGrep = timings.measure(.grep) { TextGrep(pages: index.allPages) }
        // Every single-object closure in both model settings, the derived
        // barriers and the inspector's lookups: a few milliseconds, and it
        // must match this manifest exactly.
        let derivation = timings.measure(.derivation) { Derivation(manifest: manifest) }
        let linkPreviews = timings.measure(.previews) {
            LinkPreviews(index: index, manifest: manifest, labels: labels)
        }
        return LoadedLibrary(
            index: index,
            backlinks: backlinks,
            manifest: manifest,
            labels: labels,
            textGrep: textGrep,
            derivation: derivation,
            linkPreviews: linkPreviews,
            fingerprints: scan.fingerprints)
    }

    /// The library after `previous`, equal to `build`. Until there are
    /// fingerprints to compare (D2) it is `build`, and reports what a launch
    /// reports: everything rebuilt, nothing to compare with.
    static func update(_ previous: LoadedLibrary, cloneRoot: URL) -> LibraryUpdate {
        LibraryUpdate(building: build(cloneRoot: cloneRoot))
    }
}

/// One load's result: the library, and what changed since the one before,
/// which decides what else has to follow it (§3.6).
struct LibraryUpdate: Sendable {
    let library: LoadedLibrary
    /// The fingerprint difference; nil only when there was no previous library.
    let changes: LibraryChanges?
    let isFullBuild: Bool
    /// What was built rather than reused, for the log.
    let rebuilt: Set<LibraryArtifact>
    /// A file came or went, or a changed page's aliases differ: every link
    /// may now resolve differently.
    let resolutionChanged: Bool
    let labelsChanged: Bool

    /// Whether a reader showing `location` has to render it again (§3.6).
    /// Every one does until the changes are known (D3).
    func requiresRerender(of location: AppModel.Location) -> Bool {
        true
    }
}

extension LibraryUpdate {
    /// A library built from nothing: every artifact new, and every flag set,
    /// since there is nothing it could be compared with.
    init(building library: LoadedLibrary) {
        self.init(
            library: library, changes: nil, isFullBuild: true,
            rebuilt: Set(LibraryArtifact.allCases),
            resolutionChanged: true, labelsChanged: true)
    }
}

/// The parts of a library a load builds or reuses, as `LibraryUpdate.rebuilt`
/// names them.
enum LibraryArtifact: String, Hashable, Sendable, CaseIterable {
    case pages, resolution, backlinks, grep, manifest, labels, derivation, previews
}

/// How long each part of a load took: for the log, and for the corpus suite's
/// report, whose numbers decide whether loads ever reuse what a pull left
/// alone (plans/reader-comforts.md §3.2, §3.8). Never a test's verdict:
/// shared runners are too noisy for that.
struct LoadTimings: Equatable, Sendable, CustomStringConvertible {

    /// The parts of a load that run in memory, in the order a build runs
    /// them, as §3.1 names them.
    enum Phase: String, CaseIterable, Sendable {
        /// Listing the clone's files, reading each once, hashing it, and
        /// parsing the pages: the first half of what `WikiIndex.build` was.
        case read
        /// `WikiIndex.assemble`: the tables that resolve a link.
        case index
        case manifest, labels, backlinks, grep, derivation, previews
        /// Comparing with the library before: the fingerprint difference and
        /// what it means for links and labels.
        case compare
    }

    private(set) var durations: [Phase: Duration] = [:]

    /// Runs `work`, adding the time it took to `phase`.
    mutating func measure<T>(_ phase: Phase, _ work: () throws -> T) rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        defer { durations[phase, default: .zero] += start.duration(to: clock.now) }
        return try work()
    }

    /// Every phase measured.
    var total: Duration {
        durations.values.reduce(.zero, +)
    }

    /// The phases a build runs, without the comparison: the number §3.2
    /// holds to its threshold.
    var building: Duration {
        durations.filter { $0.key != .compare }.values.reduce(.zero, +)
    }

    /// "read 9.1 ms · index 31.0 ms · … · total 160.2 ms", in phase order.
    var description: String {
        let parts = Phase.allCases.compactMap { phase in
            durations[phase].map { "\(phase.rawValue) \(Self.format($0))" }
        }
        return (parts + ["total \(Self.format(total))"]).joined(separator: " · ")
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    static func format(_ duration: Duration) -> String {
        String(format: "%.1f ms", milliseconds(duration))
    }
}
