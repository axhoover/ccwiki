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

    /// The library after `previous`, equal to `build`, with what changed
    /// between the two. It is `build` plus the fingerprint difference: every
    /// artifact is built again from the files, and nothing is carried over
    /// from `previous` but what it is compared with. Reusing what a pull
    /// left alone (D6) waits for the corpus suite's numbers (§3.2).
    static func update(_ previous: LoadedLibrary, cloneRoot: URL) -> LibraryUpdate {
        var timings = LoadTimings()
        let library = build(cloneRoot: cloneRoot, timings: &timings)
        var result = timings.measure(.compare) {
            LibraryUpdate(library: library, after: previous)
        }
        result.timings = timings
        let message = "Updated the library: \(result.summary). \(timings)"
        Logger.library.notice("\(message, privacy: .public)")
        return result
    }

    /// Every page and asset a render of `page` links to: the links in its
    /// body and in the relation line spliced under its H1, as `PageRenderer`
    /// collects them. When one changes, so does the hover card or the image
    /// the rendered page carries (§3.6). The line is taken whether or not the
    /// clone is new enough to show it, so this is never fewer than the
    /// renderer's links.
    func linkedPaths(from page: WikiPage) -> Set<String> {
        var markdown = page.body
        if let line = RelationMeta.line(for: page.frontmatter, manifest: manifest, labels: labels) {
            markdown = RelationMeta.insertUnderH1(line, into: markdown)
        }
        var paths: Set<String> = []
        for link in WikiIndex.outgoingLinks(in: markdown) {
            switch index.resolve(link, from: page.path) {
            case .page(let path, _), .asset(let path): paths.insert(path)
            case .folder, .samePage, .external, .unresolved: break
            }
        }
        return paths
    }
}

/// One load's result: the library, and what changed since the one before,
/// which decides what else has to follow it (§3.6).
struct LibraryUpdate: Sendable {
    let library: LoadedLibrary
    /// The fingerprint difference; nil only when there was no previous library.
    let changes: LibraryChanges?
    /// Nothing could be trusted to say what changed: there was no previous
    /// library, it had no fingerprints, or `CCWIKI_FULL_RELOAD=1` is set. Every
    /// reader renders again. `changes` is still the real difference whenever
    /// there was something to compare with, so the sync's summary keeps its
    /// page count (§3.3).
    let isFullBuild: Bool
    /// What was built rather than reused, for the log: every artifact, until
    /// loads reuse any (D6).
    let rebuilt: Set<LibraryArtifact>
    /// A file came or went, or a changed page's aliases differ: every link
    /// may now resolve differently.
    let resolutionChanged: Bool
    /// The plain-text names of relation objects differ from the last load's.
    let labelsChanged: Bool
    /// How long each phase of the load took, when it was measured.
    var timings = LoadTimings()

    /// Whether a reader showing `location` has to render it again (§3.6).
    /// Pure, so each tab decides for itself after a pull, and a pull that
    /// changed one page does not re-render every tab.
    func requiresRerender(of location: AppModel.Location) -> Bool {
        switch location {
        case .empty:
            return false
        case .document:
            // One synthetic page, and its links come alive with the first
            // load, which also drops Welcome's "The wiki is downloading".
            return true
        case .page(let path, _):
            guard let changes, !isFullBuild else { return true }
            // What every page's render reads: how links resolve, the
            // relation line's names and fields, and the macros.
            if resolutionChanged || labelsChanged || changes.manifestChanged
                || changes.macrosChanged {
                return true
            }
            let changed = changes.changedFiles
            if changed.contains(path) { return true }
            guard let page = library.index.page(atPath: path) else { return true }
            // A linked page's hover card is in the payload, and an embedded
            // asset is drawn from the file.
            return !library.linkedPaths(from: page).isDisjoint(with: changed)
        case .folder(let slug):
            guard let changes, !isFullBuild else { return true }
            // The listing leaves out the manifest's unlisted pages, and shows
            // each page's title and status.
            if resolutionChanged || changes.manifestChanged { return true }
            return changes.changedPages.contains {
                QuartzSlug.slugifyFilePath($0).hasPrefix(slug + "/")
            }
        }
    }

    /// One line for the log and the corpus report: what changed, and what
    /// that meant.
    var summary: String {
        guard let changes else { return "built from nothing" }
        var parts = [
            "\(changes.added.count) added, \(changes.modified.count) modified, "
                + "\(changes.deleted.count) deleted",
        ]
        if changes.manifestChanged { parts.append("manifest changed") }
        if changes.macrosChanged { parts.append("macros changed") }
        if resolutionChanged { parts.append("links resolve anew") }
        if labelsChanged { parts.append("labels changed") }
        if isFullBuild { parts.append("full build") }
        parts.append(rebuilt == Set(LibraryArtifact.allCases)
            ? "everything built"
            : "built " + rebuilt.map(\.rawValue).sorted().joined(separator: ", "))
        return parts.joined(separator: "; ")
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

    /// `library`, built in full, compared with `previous`: the fingerprint
    /// difference, and the flags §3.6 decides with. Every flag is set when
    /// the comparison cannot be trusted (`isFullBuild`).
    init(library: LoadedLibrary, after previous: LoadedLibrary) {
        let changes = LibraryChanges.between(previous.fingerprints, library.fingerprints)
        let isFullBuild = previous.fingerprints == .empty || LibraryChanges.areIgnored
        self.init(
            library: library, changes: changes, isFullBuild: isFullBuild,
            rebuilt: Set(LibraryArtifact.allCases),
            resolutionChanged: isFullBuild
                || Self.resolutionDiffers(from: previous.index, to: library.index, by: changes),
            labelsChanged: isFullBuild || previous.labels != library.labels)
    }

    /// Whether `changes` can make a link resolve differently: the slug
    /// tables are built from the file list and every page's aliases, so a
    /// file that came or went, or a changed page whose aliases differ (or
    /// that parses only on one side), can.
    static func resolutionDiffers(
        from old: WikiIndex, to new: WikiIndex, by changes: LibraryChanges
    ) -> Bool {
        if !changes.added.isEmpty || !changes.deleted.isEmpty { return true }
        return changes.modified.contains { path in
            path.hasSuffix(".md") && old.pages[path]?.aliases != new.pages[path]?.aliases
        }
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
