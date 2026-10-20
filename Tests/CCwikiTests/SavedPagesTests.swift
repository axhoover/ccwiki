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

    @Test("Move Up and Move Down take a row one place, and past an end nowhere")
    func moveByStep() {
        func moved(_ name: String, by step: Int) -> [String] {
            var saved = Self.four
            saved.move(SavedPages.Entry.Key(path: "\(name).md", anchor: nil), by: step)
            return Self.paths(saved).map { String($0.prefix(1)) }
        }
        #expect(moved("A", by: 1) == ["B", "A", "C", "D"])
        #expect(moved("C", by: -1) == ["A", "C", "B", "D"])
        #expect(moved("D", by: -2) == ["A", "D", "B", "C"])
        #expect(moved("A", by: -1) == ["A", "B", "C", "D"], "the top row has nowhere up to go")
        #expect(moved("D", by: 1) == ["A", "B", "C", "D"], "the bottom row has nowhere down to go")
        #expect(moved("Z", by: 1) == ["A", "B", "C", "D"], "a row not in the list moves nothing")

        var saved = Self.four
        saved.add(path: "B.md", anchor: "proof", title: "B", at: Self.earlier)
        saved.move(SavedPages.Entry.Key(path: "B.md", anchor: "proof"), by: -3)
        #expect(saved.entries.map(\.anchor) == [nil, "proof", nil, nil, nil], "a section moves, not its page")
        #expect(Self.paths(saved) == ["A.md", "B.md", "B.md", "C.md", "D.md"])
    }

    @Test("a saved section keeps its heading, and the menu names it after its page")
    func sectionTitles() {
        var saved = SavedPages()
        saved.add(path: "A.md", sectionTitle: "Syntax", title: "Alpha", at: Self.earlier)
        saved.add(path: "A.md", anchor: "syntax", sectionTitle: "Syntax", title: "Alpha", at: Self.earlier)
        saved.add(path: "B.md", anchor: "proof", title: "Beta", at: Self.earlier)
        #expect(saved.entries.map(\.sectionTitle) == [nil, "Syntax", nil], "the page keeps no heading")
        #expect(saved.entries.map(\.sectionName) == [nil, "Syntax", "proof"],
                "a section saved without its heading is named by its id")
        #expect(saved.entries.map(\.menuTitle) == ["Alpha", "Alpha § Syntax", "Beta § proof"])
        #expect(saved.entries.map(\.title) == ["Alpha", "Alpha", "Beta"], "the title is the page's")
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

    @Test("a section's heading reads back from its JSON, and an entry written without one reads by its id")
    func jsonSectionTitle() throws {
        var saved = SavedPages()
        saved.add(path: "A.md", anchor: "syntax", sectionTitle: "Syntax", title: "A", at: Self.earlier)
        let json = try #require(saved.json)
        #expect(SavedPages(json: json) == saved)
        #expect(SavedPages(json: json).entries.map(\.sectionTitle) == ["Syntax"])

        let without = Data(#"[{"path": "A.md", "anchor": "syntax", "title": "A", "savedAt": 0}]"#.utf8)
        let read = SavedPages(json: without)
        #expect(read.entries.map(\.sectionTitle) == [nil])
        #expect(read.entries.map(\.menuTitle) == ["A § syntax"])
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
        #expect(after.pages[Self.owf] == nil)
        #expect(after.pages[Self.lwe] == nil)

        let reconciled = saved.reconciled(with: after)
        #expect(Self.paths(reconciled) == [Self.prf, Self.renamedOWF, Self.lwe],
                "the order is kept")
        #expect(reconciled.entries[1].title == "One-way functions", "it takes the title it has now")
        #expect(reconciled.entries[2] == saved.entries[2], "a page found nowhere stays as it was")
        #expect(after.pages[reconciled.entries[2].path] == nil, "the sidebar shows it missing")
        #expect(reconciled.reconciled(with: after) == reconciled, "a second load changes nothing")
    }

    @Test("a page renamed with no alias for its title is found as the one page with that title")
    func reconcilesByExactTitle() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let saved = try Self.savedFixturePages(WikiIndex.build(contentRoot: clone.content))

        // OWF's file is renamed and keeps its title, with no alias for it, as
        // the wiki renamed `Oblivious RAM.md` to `oblivious-ram.md`: no link
        // with the title finds the new file.
        try clone.remove(FixtureClone.owf)
        try clone.write("content/" + Self.renamedOWF, FixtureClone.page(
            type: "primitive", title: "One-way function", body: "# One-way function\n"))
        let renamed = WikiIndex.build(contentRoot: clone.content)
        #expect(!renamed.resolve(Self.link("One-way function"), from: Self.owf).isResolved)
        #expect(Self.paths(saved.reconciled(with: renamed)) == [Self.prf, Self.renamedOWF, Self.lwe])

        // Two pages with that title, and neither is taken for it.
        try clone.write("content/Primitives/one-way-function-copy.md", FixtureClone.page(
            type: "primitive", title: "One-way function", body: "# One-way function\n"))
        let twice = WikiIndex.build(contentRoot: clone.content)
        #expect(saved.reconciled(with: twice) == saved, "an entry no page alone answers to stays missing")
    }

    @Test("a title with a # in it never points an entry at a section of another page")
    func reconcilesNoSection() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let index = WikiIndex.build(contentRoot: clone.content)
        let gone = "Primitives/gone.md"

        // As a link, the text before the # is PRF's alias.
        let title = "PRF#Syntax"
        #expect(index.resolve(Self.link(title), from: gone) == .page(path: Self.prf, anchor: "syntax"))
        let saved = SavedPages([.init(path: gone, anchor: nil, title: title, savedAt: Self.earlier)])
        #expect(saved.reconciled(with: index) == saved)
    }

    /// `[[text]]`, as reconciliation asks the index.
    private static func link(_ text: String) -> Wikilink {
        Wikilink(
            target: text, rawAnchor: nil, alias: nil, isEmbed: false,
            range: text.startIndex..<text.startIndex)
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

    @Test("a saved section follows its renamed page, with its id and heading, apart from the page")
    func reconcilesSection() throws {
        let clone = try FixtureClone()
        defer { clone.delete() }
        let before = WikiIndex.build(contentRoot: clone.content)
        let owf = try #require(before.pages[Self.owf])
        var saved = SavedPages()
        saved.add(path: owf.path, title: owf.title, at: Self.earlier)
        saved.add(
            path: owf.path, anchor: "definition", sectionTitle: "Definition", title: owf.title,
            at: Self.earlier)

        try clone.remove(FixtureClone.owf)
        try clone.write("content/" + Self.renamedOWF, FixtureClone.page(
            type: "primitive", title: "One-way functions", aliases: ["One-way function"],
            body: "# One-way functions\n\n## Definition\n\nEasy to compute and hard to invert.\n"))
        let reconciled = saved.reconciled(with: WikiIndex.build(contentRoot: clone.content))

        #expect(Self.paths(reconciled) == [Self.renamedOWF, Self.renamedOWF])
        #expect(reconciled.entries.map(\.anchor) == [nil, "definition"])
        #expect(reconciled.entries.map(\.menuTitle) == ["One-way functions", "One-way functions § Definition"])
    }
}

/// Saved pages in the app model: what it reads from the user defaults when
/// it is made, and what it writes back. Each test puts back the defaults it
/// changes.
@MainActor
struct SavedPagesModelTests {

    @Test("a load re-points a saved page whose file went, and writes the list back")
    func loadReconciles() async throws {
        let stored = CCwikiSettings.savedPages
        defer { CCwikiSettings.savedPages = stored }
        // Put back as soon as the model has read it. Every model is made on
        // the main actor, so no other test's model reads this list.
        let gone = "Primitives/gone.md"
        CCwikiSettings.savedPages = SavedPages([.init(
            path: gone, anchor: nil, title: "OWF",
            savedAt: Date(timeIntervalSinceReferenceDate: 813_196_800))])
        let fixture = try ModelFixture()
        CCwikiSettings.savedPages = stored
        defer { fixture.delete() }
        let model = fixture.model
        #expect(model.savedPages.entries.map(\.path) == [gone], "the model reads the list when it is made")

        // "OWF" is the alias of the fixture's one-way function page.
        await model.loadLibrary(reason: .pulled)
        let owf = FixtureClone.relative(FixtureClone.owf)
        #expect(model.savedPages.entries.map(\.path) == [owf])
        #expect(model.savedPages.entries.map(\.title) == ["One-way function"])
        #expect(CCwikiSettings.savedPages == model.savedPages, "the reconciled list is in the defaults")
    }

    @Test("the Saved section is open or closed as it was left, at the next launch")
    func sectionStaysAsLeft() throws {
        let stored = CCwikiSettings.showsSavedPages
        defer { CCwikiSettings.showsSavedPages = stored }
        CCwikiSettings.showsSavedPages = true
        let fixture = try ModelFixture()
        defer { fixture.delete() }
        #expect(fixture.model.showsSavedPages)

        fixture.model.showsSavedPages = false
        #expect(!CCwikiSettings.showsSavedPages)
        let next = try ModelFixture()
        defer { next.delete() }
        #expect(!next.model.showsSavedPages, "a new launch finds it as it was left")
    }
}
