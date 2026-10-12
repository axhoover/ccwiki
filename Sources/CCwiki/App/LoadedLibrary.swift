import Foundation

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
    /// definition however loads come to reuse parts of it (§3.5).
    static func build(cloneRoot: URL) -> LoadedLibrary {
        let index = WikiIndex.build(contentRoot: cloneRoot.appending(path: "content"))
        // 343 KB of JSON, and the labels need every hosting page's
        // headings — both cheap, but neither belongs on the main actor.
        let manifest = RelationsManifest.load(cloneRoot: cloneRoot)
        let labels = RelationLabels(manifest: manifest, index: index)
        return LoadedLibrary(
            index: index,
            backlinks: index.backlinkMap(),
            manifest: manifest,
            labels: labels,
            textGrep: TextGrep(pages: index.allPages),
            // Every single-object closure in both model settings, the
            // derived barriers and the inspector's lookups: a few
            // milliseconds, and it must match this manifest exactly.
            derivation: Derivation(manifest: manifest),
            linkPreviews: LinkPreviews(index: index, manifest: manifest, labels: labels),
            fingerprints: ContentFingerprints.scan(cloneRoot: cloneRoot))
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
