import Foundation

/// What the clone's files held when a load read them: a digest of every file
/// `WikiIndex` lists, plus the manifest and the macro table
/// (plans/reader-comforts.md §3.3). Two of them compared say what a pull
/// changed, for a clone and a snapshot alike, without asking git.
///
/// Until Track D reads the files (D2), a scan reads nothing: every load is
/// a full build, as it has always been.
struct ContentFingerprints: Equatable, Sendable {

    /// Nothing read yet.
    static let empty = ContentFingerprints(pages: [:], manifest: nil, macros: nil)

    /// `content/`-relative path → digest, for every listed file.
    let pages: [String: String]
    /// `.reductions/relations.json`.
    let manifest: String?
    /// `macros.ts`.
    let macros: String?

    /// The fingerprints of the clone at `cloneRoot`. Empty until D2.
    static func scan(cloneRoot: URL) -> ContentFingerprints {
        .empty
    }
}

/// The difference between two scans: which content files came, changed or
/// went, and whether the manifest or the macros changed.
struct LibraryChanges: Equatable, Sendable {

    /// `content/`-relative paths, as `ContentFingerprints.pages` keys them.
    var added: Set<String>
    var modified: Set<String>
    var deleted: Set<String>
    var manifestChanged: Bool
    var macrosChanged: Bool

    static let none = LibraryChanges(
        added: [], modified: [], deleted: [], manifestChanged: false, macrosChanged: false)

    /// What changed from `old` to `new`. Nothing, until there is something
    /// to compare (D2).
    static func between(_ old: ContentFingerprints, _ new: ContentFingerprints) -> LibraryChanges {
        .none
    }

    var isEmpty: Bool {
        added.isEmpty && modified.isEmpty && deleted.isEmpty && !manifestChanged && !macrosChanged
    }

    /// The pages among the three sets: an asset that changed is not a page
    /// that changed, for the sync's summary.
    var changedPages: Set<String> {
        added.union(modified).union(deleted).filter { $0.hasSuffix(".md") }
    }
}
