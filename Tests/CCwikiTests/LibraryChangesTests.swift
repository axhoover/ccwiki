import Foundation
import Testing
@testable import CCwiki

/// What a pull changed, read from the files themselves rather than from git
/// (plans/reader-comforts.md §3.3).
struct LibraryChangesTests {

    @Test("a digest is the first 16 bytes of the SHA-256, in hex")
    func digest() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a3…
        #expect(ContentFingerprints.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223")
        #expect(ContentFingerprints.digest(Data()).count == 32)
    }

    @Test("the difference names added, modified and deleted files, the manifest and the macros")
    func difference() {
        let old = ContentFingerprints(
            pages: ["a.md": "1", "b.md": "2", "c.md": "3", "Files/x.png": "4"],
            manifest: "m1", macros: "t1")
        let new = ContentFingerprints(
            pages: ["a.md": "1", "b.md": "20", "d.md": "5", "Files/x.png": "40"],
            manifest: "m2", macros: "t1")
        let changes = LibraryChanges.between(old, new)
        #expect(changes.added == ["d.md"])
        #expect(changes.modified == ["b.md", "Files/x.png"])
        #expect(changes.deleted == ["c.md"])
        #expect(changes.manifestChanged)
        #expect(!changes.macrosChanged)
        #expect(changes.changedFiles == ["b.md", "c.md", "d.md", "Files/x.png"])
        #expect(changes.changedPages == ["b.md", "c.md", "d.md"], "an asset is not a page")
        #expect(!changes.isEmpty)

        #expect(LibraryChanges.between(new, new) == LibraryChanges.none)
        #expect(LibraryChanges.between(new, new).isEmpty)
        let macros = LibraryChanges.between(
            new, ContentFingerprints(pages: new.pages, manifest: "m2", macros: "t2"))
        #expect(macros.macrosChanged && !macros.manifestChanged)
        let gone = LibraryChanges.between(
            new, ContentFingerprints(pages: new.pages, manifest: nil, macros: "t1"))
        #expect(gone.manifestChanged, "a manifest that went is a change")
    }

    @Test("a scan lists what WikiIndex lists, and ignores templates, hidden files and files without an extension")
    func scanLists() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let fingerprints = ContentFingerprints.scan(cloneRoot: clone.root)

        #expect(Set(fingerprints.pages.keys) == Set(WikiIndex.contentFiles(root: clone.content)))
        #expect(fingerprints.pages[FixtureClone.relative(FixtureClone.diagram)] != nil,
                "an asset is fingerprinted like a page")
        #expect(fingerprints.pages["Templates/primitive.md"] == nil)
        #expect(fingerprints.pages["Primitives/.draft.md"] == nil)
        #expect(fingerprints.pages["Primitives/README"] == nil)
        let page = try Data(contentsOf: clone.url(FixtureClone.prf))
        let manifest = try Data(contentsOf: clone.url(FixtureClone.manifestPath))
        let macros = try Data(contentsOf: clone.url("macros.ts"))
        #expect(fingerprints.pages[FixtureClone.relative(FixtureClone.prf)]
            == ContentFingerprints.digest(page))
        #expect(fingerprints.manifest == ContentFingerprints.digest(manifest))
        #expect(fingerprints.macros == ContentFingerprints.digest(macros))

        try clone.remove(FixtureClone.manifestPath)
        try clone.remove("macros.ts")
        let bare = ContentFingerprints.scan(cloneRoot: clone.root)
        #expect(bare.manifest == nil && bare.macros == nil)
        #expect(ContentFingerprints.scan(cloneRoot: clone.root.appending(path: "nowhere")) == .empty)
    }

    @Test("edits to the files are the difference between two scans; ignored files never are")
    func scanDifference() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let before = ContentFingerprints.scan(cloneRoot: clone.root)

        try clone.write(FixtureClone.owf, try clone.read(FixtureClone.owf) + "\nMore.\n")
        try clone.remove(FixtureClone.lwe)
        try clone.write("content/Primitives/garbled-circuits.md", FixtureClone.page(
            type: "primitive", title: "Garbled circuits", body: "# Garbled circuits\n"))
        try clone.write(FixtureClone.diagram, "a different picture")
        try clone.write("content/Templates/primitive.md", "changed, but not part of the site")
        try clone.write("content/Primitives/.draft.md", "changed, but hidden")
        try clone.write("macros.ts", FixtureClone.macros + "\n")
        let after = ContentFingerprints.scan(cloneRoot: clone.root)

        let changes = LibraryChanges.between(before, after)
        #expect(changes.added == ["Primitives/garbled-circuits.md"])
        #expect(changes.modified == ["Primitives/one-way-function.md", "Files/diagram.png"])
        #expect(changes.deleted == ["Assumptions/learning-with-errors.md"])
        #expect(!changes.manifestChanged)
        #expect(changes.macrosChanged)

        // Touching a file without changing it changes nothing.
        try clone.write(FixtureClone.prf, try clone.read(FixtureClone.prf))
        #expect(LibraryChanges.between(after, ContentFingerprints.scan(cloneRoot: clone.root)).isEmpty)
    }

    @Test("a page parses the same from its bytes as from its file, and not at all from bad UTF-8")
    func pageFromData() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let path = FixtureClone.relative(FixtureClone.prf)
        let data = try Data(contentsOf: clone.url(FixtureClone.prf))
        let fromData = try #require(WikiPage.load(path: path, data: data))
        let fromFile = try #require(WikiPage.load(path: path, in: clone.content))
        #expect(fromData.title == "Pseudorandom function")
        #expect(fromData.aliases == ["PRF"])
        #expect(fromData.body == fromFile.body)
        #expect(fromData.slug == fromFile.slug)
        #expect(WikiPage.load(path: path, data: Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE])) == nil)
    }

    @Test("the library's one read of each file builds the index WikiIndex.build does")
    func buildReadsOnce() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let library = LoadedLibrary.build(cloneRoot: clone.root)
        let reference = WikiIndex.build(contentRoot: clone.content)

        #expect(library.fingerprints == ContentFingerprints.scan(cloneRoot: clone.root))
        #expect(Set(library.index.pages.keys) == Set(reference.pages.keys))
        #expect(library.index.allSlugs == reference.allSlugs)
        #expect(library.index.assets == reference.assets)
        #expect(library.index.folders == reference.folders)
        #expect(library.index.ambiguousAliases == reference.ambiguousAliases)
        for (path, page) in reference.pages {
            let built = try #require(library.index.pages[path])
            #expect(built.title == page.title && built.aliases == page.aliases)
            #expect(built.body == page.body && built.kind == page.kind && built.status == page.status)
            for link in WikiIndex.outgoingLinks(in: page.body) {
                #expect(library.index.resolve(link, from: path) == reference.resolve(link, from: path))
            }
        }
        #expect(library.manifest.objectsByID.count == 3, "decoded from the bytes the scan read")
    }

    @Test("between two commits, the difference names exactly what git diff names")
    func matchesGit() async throws {
        guard let repository = await FixtureRepository.make() else { return }
        defer { repository.delete() }
        for (path, text) in FixtureClone.standard { try repository.write(path, text) }
        let firstCommit = await repository.commit("first", date: 1_700_000_000)
        let first = try #require(firstCommit)
        let before = ContentFingerprints.scan(cloneRoot: repository.root)

        try repository.write(FixtureClone.owf, FixtureClone.page(
            type: "primitive", title: "One-way function", aliases: ["OWF", "One-way functions"],
            body: "# One-way function\n\nRewritten.\n"))
        try repository.remove(FixtureClone.lwe)
        try repository.write("content/Primitives/garbled-circuits.md", FixtureClone.page(
            type: "primitive", title: "Garbled circuits", body: "# Garbled circuits\n"))
        try repository.write("content/Files/second.png", "another picture")
        try repository.write("content/Templates/primitive.md", "a template, not a page")
        try repository.write(FixtureClone.manifestPath, FixtureClone.manifest(prfTitle: "PRF"))
        let secondCommit = await repository.commit("second", date: 1_700_000_100)
        let second = try #require(secondCommit)
        let after = ContentFingerprints.scan(cloneRoot: repository.root)

        let diff = await repository.run([
            "diff", "--name-status", "--no-renames", first, second,
        ])
        #expect(diff.succeeded)
        let listed = Set(WikiIndex.contentFiles(root: repository.root.appending(path: "content")))
            .union(before.pages.keys)
        var expected = LibraryChanges.none
        for line in diff.stdout.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            let (status, path) = (fields[0], fields[1])
            if path == FixtureClone.manifestPath { expected.manifestChanged = true; continue }
            if path == "macros.ts" { expected.macrosChanged = true; continue }
            guard path.hasPrefix("content/") else { continue }
            let relative = FixtureClone.relative(path)
            // The files a load lists; git also names the template.
            guard listed.contains(relative) else { continue }
            switch status {
            case "A": expected.added.insert(relative)
            case "D": expected.deleted.insert(relative)
            default: expected.modified.insert(relative)
            }
        }
        #expect(!expected.isEmpty)
        #expect(LibraryChanges.between(before, after) == expected)
    }
}
