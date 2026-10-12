import Foundation
import Testing
@testable import CCwiki

/// What a load after a pull reports, for each kind of change, and which
/// readers that sends back to render (plans/reader-comforts.md §3.4, §3.6).
///
/// Every library here is built in full from the fixture's files, as
/// `update` does until loads reuse anything: the full build stays the
/// definition, and these tests check only what is compared and decided.
struct IncrementalLibraryTests {

    private typealias Location = AppModel.Location

    private static let prf = Location.page(path: "Primitives/pseudorandom-function.md", anchor: nil)
    private static let owf = Location.page(path: "Primitives/one-way-function.md", anchor: nil)
    private static let lwe = Location.page(path: "Assumptions/learning-with-errors.md", anchor: "syntax")
    private static let ggm = Location.page(
        path: "References/GGM86 - How to construct random functions.md", anchor: nil)
    private static let home = Location.page(path: "index.md", anchor: nil)
    private static let primitives = Location.folder(slug: "Primitives")
    private static let assumptions = Location.folder(slug: "Assumptions")

    /// The fixture loaded, then edited by `edit`, then loaded again.
    private static func update(
        _ edit: (FixtureClone) throws -> Void
    ) throws -> (previous: LoadedLibrary, update: LibraryUpdate) {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let previous = LoadedLibrary.build(cloneRoot: clone.root)
        try edit(clone)
        return (previous, LoadedLibrary.update(previous, cloneRoot: clone.root))
    }

    private static func editBody(of path: String, in clone: FixtureClone) throws {
        try clone.write(path, try clone.read(path) + "\nOne more sentence.\n")
    }

    // MARK: What a load reports

    @Test("a launch has nothing to compare with: every flag set, nothing known to have changed")
    func launch() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let update = LibraryUpdate(building: LoadedLibrary.build(cloneRoot: clone.root))
        #expect(update.changes == nil)
        #expect(update.isFullBuild)
        #expect(update.resolutionChanged)
        #expect(update.labelsChanged)
        #expect(update.rebuilt == Set(LibraryArtifact.allCases))
    }

    @Test("a load that finds nothing changed says so, and builds what the full build does")
    func nothingChanged() throws {
        let (previous, update) = try Self.update { _ in }
        #expect(update.changes == LibraryChanges.none)
        #expect(!update.isFullBuild)
        #expect(!update.resolutionChanged)
        #expect(!update.labelsChanged)
        #expect(update.rebuilt == Set(LibraryArtifact.allCases), "nothing is reused yet")
        #expect(update.library.fingerprints == previous.fingerprints)
        #expect(update.library.backlinks == previous.backlinks)
        #expect(update.library.index.allSlugs == previous.index.allSlugs)
        #expect(update.library.labels == previous.labels)
    }

    @Test("a body edit changes one page, and neither how links resolve nor the labels")
    func bodyEdit() throws {
        let (_, update) = try Self.update { try Self.editBody(of: FixtureClone.owf, in: $0) }
        let changes = try #require(update.changes)
        #expect(changes.modified == ["Primitives/one-way-function.md"])
        #expect(changes.added.isEmpty && changes.deleted.isEmpty)
        #expect(!changes.manifestChanged && !changes.macrosChanged)
        #expect(!update.isFullBuild)
        #expect(!update.resolutionChanged)
        #expect(!update.labelsChanged)
    }

    @Test("an alias change makes every link resolve anew")
    func aliasChange() throws {
        let (_, update) = try Self.update { clone in
            try clone.write(FixtureClone.owf, FixtureClone.page(
                type: "primitive", title: "One-way function", aliases: ["OWF", "OWFs"],
                body: "# One-way function\n\nEasy to compute and hard to invert.\n"))
        }
        #expect(update.changes?.modified == ["Primitives/one-way-function.md"])
        #expect(update.resolutionChanged)
        #expect(!update.labelsChanged)
        #expect(!update.isFullBuild)
    }

    @Test("an added page is added, and can be linked to")
    func addedPage() throws {
        let (_, update) = try Self.update { clone in
            try clone.write("content/Primitives/garbled-circuits.md", FixtureClone.page(
                type: "primitive", title: "Garbled circuits", aliases: ["GC"],
                body: "# Garbled circuits\n"))
        }
        #expect(update.changes?.added == ["Primitives/garbled-circuits.md"])
        #expect(update.changes?.modified.isEmpty == true)
        #expect(update.resolutionChanged)
        #expect(update.library.index.page(atPath: "Primitives/garbled-circuits.md") != nil)
    }

    @Test("a deleted page is deleted, and links to it no longer resolve")
    func deletedPage() throws {
        let (_, update) = try Self.update { try $0.remove(FixtureClone.lwe) }
        #expect(update.changes?.deleted == ["Assumptions/learning-with-errors.md"])
        #expect(update.resolutionChanged)
        #expect(update.library.index.page(atPath: "Assumptions/learning-with-errors.md") == nil)
    }

    @Test("an added asset is a file that came, though not a page")
    func addedAsset() throws {
        let (_, update) = try Self.update { try $0.write("content/Files/second.png", "a picture") }
        #expect(update.changes?.added == ["Files/second.png"])
        #expect(update.changes?.changedPages.isEmpty == true)
        #expect(update.resolutionChanged, "an asset has a slug a link can name")
    }

    @Test("a manifest change; the labels change only when a name does")
    func manifestChange() throws {
        let (_, renamed) = try Self.update { clone in
            try clone.write(FixtureClone.manifestPath, FixtureClone.manifest(prfTitle: "PRFs"))
        }
        #expect(renamed.changes?.manifestChanged == true)
        #expect(renamed.changes?.changedFiles.isEmpty == true)
        #expect(renamed.labelsChanged)
        #expect(!renamed.resolutionChanged)

        let (_, unlisted) = try Self.update { clone in
            try clone.write(FixtureClone.manifestPath, FixtureClone.manifest(unlistingOWF: true))
        }
        #expect(unlisted.changes?.manifestChanged == true)
        #expect(!unlisted.labelsChanged)
        #expect(unlisted.library.manifest.unlistedPaths == ["Primitives/one-way-function.md"])
    }

    @Test("a macros change is that and nothing else")
    func macrosChange() throws {
        let (_, update) = try Self.update { clone in
            try clone.write("macros.ts", FixtureClone.macros.replacingOccurrences(
                of: "mathcal", with: "mathscr"))
        }
        let changes = try #require(update.changes)
        #expect(changes.macrosChanged)
        #expect(!changes.manifestChanged)
        #expect(changes.changedFiles.isEmpty)
        #expect(!update.resolutionChanged && !update.labelsChanged)
    }

    @Test("several changes at once are all reported")
    func severalAtOnce() throws {
        let (_, update) = try Self.update { clone in
            try Self.editBody(of: FixtureClone.prf, in: clone)
            try clone.remove(FixtureClone.ggm)
            try clone.write("content/Primitives/garbled-circuits.md", FixtureClone.page(
                type: "primitive", title: "Garbled circuits", body: "# Garbled circuits\n"))
            try clone.write(FixtureClone.manifestPath, FixtureClone.manifest(prfTitle: "PRFs"))
            try clone.write("macros.ts", FixtureClone.macros + "\n")
        }
        let changes = try #require(update.changes)
        #expect(changes.added == ["Primitives/garbled-circuits.md"])
        #expect(changes.modified == ["Primitives/pseudorandom-function.md"])
        #expect(changes.deleted == ["References/GGM86 - How to construct random functions.md"])
        #expect(changes.manifestChanged && changes.macrosChanged)
        #expect(update.resolutionChanged && update.labelsChanged)
        #expect(!update.isFullBuild)
    }

    @Test("a previous library with no fingerprints cannot be compared with: a full build")
    func noFingerprints() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let built = LoadedLibrary.build(cloneRoot: clone.root)
        let previous = LoadedLibrary(
            index: built.index, backlinks: built.backlinks, manifest: built.manifest,
            labels: built.labels, textGrep: built.textGrep, derivation: built.derivation,
            linkPreviews: built.linkPreviews, fingerprints: .empty)
        let update = LoadedLibrary.update(previous, cloneRoot: clone.root)
        #expect(update.isFullBuild)
        #expect(update.resolutionChanged && update.labelsChanged)
        #expect(update.changes?.added.count == built.fingerprints.pages.count,
                "the difference is still reported, for the sync's summary")
        #expect(update.requiresRerender(of: Self.ggm))
    }

    // MARK: Which readers render again

    @Test("a page renders again when it, or a page it links to, changed; no other page does")
    func rerenderPageWhenLinkTargetChanged() throws {
        let (_, update) = try Self.update { try Self.editBody(of: FixtureClone.owf, in: $0) }
        #expect(update.requiresRerender(of: Self.owf), "the page itself")
        #expect(update.requiresRerender(of: Self.prf), "links to it: its hover card changed")
        #expect(!update.requiresRerender(of: Self.lwe))
        #expect(!update.requiresRerender(of: Self.home))
        #expect(!update.requiresRerender(of: Self.ggm))
        #expect(update.requiresRerender(of: Self.primitives), "lists the changed page")
        #expect(!update.requiresRerender(of: Self.assumptions))
    }

    @Test("a page that embeds a changed asset renders again")
    func rerenderPageWhenAssetChanged() throws {
        let (_, update) = try Self.update { try $0.write(FixtureClone.diagram, "a new picture") }
        #expect(update.requiresRerender(of: Self.lwe))
        #expect(!update.requiresRerender(of: Self.prf))
        #expect(!update.requiresRerender(of: Self.primitives), "an asset is not a listed page")
    }

    @Test("a folder renders again after its unlisted pages change")
    func rerenderFolderOnUnlistedChange() throws {
        let (_, update) = try Self.update { clone in
            try clone.write(FixtureClone.manifestPath, FixtureClone.manifest(unlistingOWF: true))
        }
        #expect(update.requiresRerender(of: Self.primitives))
        #expect(update.requiresRerender(of: Self.prf), "every page reads the manifest")
    }

    @Test("Welcome and What's New render again after every load, the first above all")
    func rerenderDocumentAfterFirstLoad() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let first = LibraryUpdate(building: LoadedLibrary.build(cloneRoot: clone.root))
        #expect(first.requiresRerender(of: .document(.welcome)))
        #expect(first.requiresRerender(of: .document(.whatsNew)))
        let unchanged = LoadedLibrary.update(first.library, cloneRoot: clone.root)
        #expect(unchanged.changes?.isEmpty == true)
        #expect(unchanged.requiresRerender(of: .document(.welcome)))
    }

    @Test("nothing on screen never renders; after a launch, everything else does")
    func rerenderFullBuild() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let launch = LibraryUpdate(building: LoadedLibrary.build(cloneRoot: clone.root))
        #expect(!launch.requiresRerender(of: .empty))
        for location in [Self.prf, Self.owf, Self.lwe, Self.ggm, Self.home, Self.primitives] {
            #expect(launch.requiresRerender(of: location))
        }
        let unchanged = LoadedLibrary.update(launch.library, cloneRoot: clone.root)
        #expect(!unchanged.requiresRerender(of: .empty))
        for location in [Self.prf, Self.owf, Self.lwe, Self.ggm, Self.home, Self.primitives] {
            #expect(!unchanged.requiresRerender(of: location), "nothing changed: \(location)")
        }
    }

    @Test("links resolving anew, new labels and new macros render every page again")
    func rerenderEveryPage() throws {
        let edits: [(String, (FixtureClone) throws -> Void)] = [
            ("an alias", { clone in
                try clone.write(FixtureClone.owf, FixtureClone.page(
                    type: "primitive", title: "One-way function", aliases: ["OWF", "OWFs"],
                    body: "# One-way function\n\nEasy to compute and hard to invert.\n"))
            }),
            ("a label", { clone in
                try clone.write(FixtureClone.manifestPath, FixtureClone.manifest(prfTitle: "PRFs"))
            }),
            ("the macros", { clone in
                try clone.write("macros.ts", FixtureClone.macros + "\n")
            }),
        ]
        for (name, edit) in edits {
            let (_, update) = try Self.update(edit)
            #expect(update.requiresRerender(of: Self.ggm), "after a change to \(name)")
            #expect(update.requiresRerender(of: Self.home), "after a change to \(name)")
        }
        let (_, macros) = try Self.update { try $0.write("macros.ts", FixtureClone.macros + "\n") }
        #expect(!macros.requiresRerender(of: Self.primitives), "a listing has no math")
    }
}
