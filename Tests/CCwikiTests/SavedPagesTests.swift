import Foundation
import Testing
@testable import CCwiki

/// Saved pages (plans/efficiency.md §3.3): the list's operations, its JSON
/// in the user defaults, and what a library load makes of a saved page whose
/// file went.
struct SavedPagesTests {

    private static let earlier = Date(timeIntervalSinceReferenceDate: 813_196_800)
    private static let later = Date(timeIntervalSinceReferenceDate: 813_283_200)

    private static let prf = FixtureClone.relative(FixtureClone.prf)
    private static let owf = FixtureClone.relative(FixtureClone.owf)
    private static let lwe = FixtureClone.relative(FixtureClone.lwe)
    private static let renamedOWF = "Primitives/one-way-functions.md"

    /// A, B, C and D, saved in that order.
    private static var four: SavedPages {
        var saved = SavedPages()
        for name in ["A", "B", "C", "D"] {
            saved.add(path: "\(name).md", title: name, at: earlier)
        }
        return saved
    }

    private static func paths(_ saved: SavedPages) -> [String] {
        saved.entries.map(\.path)
    }

    // MARK: The list

    @Test("a page is saved at the end of the list, once")
    func add() {
        var saved = SavedPages()
        #expect(saved.isEmpty)
        saved.add(path: "A.md", title: "A", at: Self.earlier)
        saved.add(path: "B.md", title: "B", at: Self.later)
        saved.add(path: "A.md", title: "A again", at: Self.later)
        #expect(Self.paths(saved) == ["A.md", "B.md"])
        #expect(saved.entries[0].title == "A", "saving a saved page changes nothing")

        saved.add(path: "A.md", anchor: "syntax", title: "A", at: Self.later)
        #expect(Self.paths(saved) == ["A.md", "B.md", "A.md"], "a section is an entry of its own")
        #expect(saved.entries.map(\.anchor) == [nil, nil, "syntax"])

        saved.add(path: "", title: "Nothing", at: Self.earlier)
        #expect(saved.entries.count == 3, "an entry needs a path")
    }

    @Test("contains tells a page from a section of it")
    func contains() {
        var saved = SavedPages()
        saved.add(path: "A.md", title: "A", at: Self.earlier)
        saved.add(path: "B.md", anchor: "proof", title: "B", at: Self.earlier)
        #expect(saved.contains(path: "A.md"))
        #expect(!saved.contains(path: "A.md", anchor: "proof"))
        #expect(saved.contains(path: "B.md", anchor: "proof"))
        #expect(!saved.contains(path: "B.md"), "a saved section does not save its page")
        #expect(!saved.contains(path: "C.md"))
    }

    @Test("removing takes out that page or section and nothing else")
    func remove() {
        var saved = Self.four
        saved.add(path: "B.md", anchor: "proof", title: "B", at: Self.earlier)
        saved.remove(path: "B.md")
        #expect(Self.paths(saved) == ["A.md", "C.md", "D.md", "B.md"])
        #expect(saved.contains(path: "B.md", anchor: "proof"), "its section stays")

        saved.remove(path: "B.md", anchor: "proof")
        saved.remove(path: "Z.md")
        #expect(Self.paths(saved) == ["A.md", "C.md", "D.md"])

        for path in ["A.md", "C.md", "D.md"] { saved.remove(path: path) }
        #expect(saved.isEmpty)
    }

    @Test("a move puts the rows where a drag in the list drops them")
    func move() {
        func moved(_ source: IndexSet, to destination: Int) -> [String] {
            var saved = Self.four
            saved.move(fromOffsets: source, toOffset: destination)
            return Self.paths(saved).map { String($0.prefix(1)) }
        }
        // The destination is an offset in the list before the move, as
        // `ForEach.onMove` gives it.
        #expect(moved([0], to: 3) == ["B", "C", "A", "D"])
        #expect(moved([0], to: 4) == ["B", "C", "D", "A"])
        #expect(moved([3], to: 0) == ["D", "A", "B", "C"])
        #expect(moved([1, 2], to: 4) == ["A", "D", "B", "C"])
        #expect(moved([0, 3], to: 2) == ["B", "A", "D", "C"])
        #expect(moved([1], to: 1) == ["A", "B", "C", "D"], "dropped where it was")
        #expect(moved([1], to: 2) == ["A", "B", "C", "D"], "dropped just below itself")
        #expect(moved([9], to: 0) == ["A", "B", "C", "D"], "an offset outside the list is ignored")
        #expect(moved([0, 9], to: 4) == ["B", "C", "D", "A"])
        #expect(moved([], to: 0) == ["A", "B", "C", "D"])
    }

    // MARK: JSON

    @Test("the list reads back from its JSON as it was written, order, sections and dates")
    func jsonRoundTrip() throws {
        var saved = Self.four
        saved.add(path: "B.md", anchor: "proof", title: "B", at: Self.later)
        saved.move(fromOffsets: [3], toOffset: 0)
        let json = try #require(saved.json)
        #expect(SavedPages(json: json) == saved)
        let empty = try #require(SavedPages().json)
        #expect(SavedPages(json: empty).isEmpty)
    }

    @Test("bad data reads as the entries that can be read, or as nothing saved")
    func badJSON() {
        #expect(SavedPages(json: Data()).isEmpty)
        #expect(SavedPages(json: Data("not JSON".utf8)).isEmpty)
        let one = Data(#"{"path": "A.md", "title": "A", "savedAt": 0}"#.utf8)
        #expect(SavedPages(json: one).isEmpty, "one entry is not a list")

        let mixed = """
            [{"path": "A.md", "title": "A", "savedAt": 0},
             {"path": 3, "title": "B", "savedAt": 0},
             7, "C.md", [],
             {"path": "D.md", "savedAt": 0},
             {"path": "", "title": "Empty", "savedAt": 0},
             {"path": "A.md", "title": "A twice", "savedAt": 1},
             {"path": "A.md", "anchor": "proof", "title": "A", "savedAt": 2, "colour": "red"}]
            """
        let read = SavedPages(json: Data(mixed.utf8))
        #expect(Self.paths(read) == ["A.md", "A.md"])
        #expect(read.entries.map(\.anchor) == [nil, "proof"])
        #expect(read.entries.map(\.title) == ["A", "A"], "the first entry for a page is kept")
    }

    // MARK: After a load

    /// PRF, OWF and LWE, saved from the fixture wiki.
    private static func savedFixturePages(_ index: WikiIndex) throws -> SavedPages {
        var saved = SavedPages()
        for path in [prf, owf, lwe] {
            let page = try #require(index.pages[path])
            saved.add(path: page.path, title: page.title, at: earlier)
        }
        return saved
    }

    @Test("after a pull, a renamed page is found by its title and a deleted one stays, missing")
    func reconcilesRenamedAndDeleted() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let before = WikiIndex.build(contentRoot: clone.content)
        let saved = try Self.savedFixturePages(before)
        #expect(saved.reconciled(with: before) == saved, "nothing moved, so nothing changes")

        // LWE goes. OWF is renamed and retitled, with its old title kept
        // as an alias.
        try clone.remove(FixtureClone.lwe)
        try clone.remove(FixtureClone.owf)
        try clone.write("content/" + Self.renamedOWF, FixtureClone.page(
            type: "primitive", title: "One-way functions", aliases: ["OWF", "One-way function"],
            body: "# One-way functions\n\nEasy to compute and hard to invert.\n"))
        let after = WikiIndex.build(contentRoot: clone.content)
        #expect(after.pages[Self.owf] == nil && after.pages[Self.lwe] == nil)

        let reconciled = saved.reconciled(with: after)
        #expect(Self.paths(reconciled) == [Self.prf, Self.renamedOWF, Self.lwe],
                "the order is kept")
        #expect(reconciled.entries[1].title == "One-way functions", "it takes the title it has now")
        #expect(reconciled.entries[2] == saved.entries[2], "a page found nowhere stays as it was")
        #expect(after.pages[reconciled.entries[2].path] == nil, "the sidebar shows it missing")
        #expect(reconciled.reconciled(with: after) == reconciled, "a second load changes nothing")
    }

    @Test("a page still at its path takes its new title, and is never looked up")
    func reconcilesRetitled() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let saved = try Self.savedFixturePages(WikiIndex.build(contentRoot: clone.content))

        // PRF is retitled in place. LWE's new alias names OWF's title, which
        // must not move OWF's entry: OWF is still where it was.
        try clone.write(FixtureClone.prf, FixtureClone.page(
            type: "primitive", title: "Pseudorandom functions", aliases: ["PRF"],
            body: "# Pseudorandom functions\n"))
        try clone.write(FixtureClone.lwe, FixtureClone.page(
            type: "assumption", title: "Learning with errors", aliases: ["LWE", "One-way function"],
            body: "# Learning with errors\n"))
        let reconciled = saved.reconciled(with: WikiIndex.build(contentRoot: clone.content))

        #expect(Self.paths(reconciled) == [Self.prf, Self.owf, Self.lwe])
        #expect(reconciled.entries.map(\.title)
            == ["Pseudorandom functions", "One-way function", "Learning with errors"])
    }

    @Test("an entry that comes to name a page already saved is dropped, and the first is kept")
    func reconcilesOntoSavedPage() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        var saved = try Self.savedFixturePages(WikiIndex.build(contentRoot: clone.content))

        try clone.remove(FixtureClone.owf)
        try clone.write("content/" + Self.renamedOWF, FixtureClone.page(
            type: "primitive", title: "One-way functions", aliases: ["One-way function"],
            body: "# One-way functions\n"))
        let after = WikiIndex.build(contentRoot: clone.content)
        // Saved again at its new path before the old entry was reconciled.
        saved.add(path: Self.renamedOWF, title: "One-way functions", at: Self.later)

        let reconciled = saved.reconciled(with: after)
        #expect(Self.paths(reconciled) == [Self.prf, Self.renamedOWF, Self.lwe],
                "the first is kept, where it was")
    }
}
