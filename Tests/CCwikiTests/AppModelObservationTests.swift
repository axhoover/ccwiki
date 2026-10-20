import Foundation
import Testing
@testable import CCwiki

/// The app model as the main window reads it (plans/efficiency.md, track U):
/// what a load does for the windows, and when.
///
/// Each test makes its own `AppModel` over an Application Support folder of
/// its own, holding `FixtureClone.standard` and no git, so nothing here
/// reaches the network, a real clone or a web view.
@MainActor
@Suite(.serialized)
struct AppModelObservationTests {

    private static let prf = FixtureClone.relative(FixtureClone.prf)

    // MARK: Loading (U1)

    @Test("a query typed during a load is answered from the index the load wrote")
    func searchRunsAgainOnceTheIndexIsWritten() async throws {
        let fixture = try ModelFixture()
        defer { fixture.delete() }
        let model = fixture.model

        model.searchQuery = "pseudorandom"
        let update = await model.loadLibrary(reason: .pulled)

        #expect(update != nil)
        #expect(model.index?.pages[Self.prf] != nil, "the library is on screen")
        // The page renders before the index is written; the query is asked
        // again once it is, so the answer that lands names the page.
        for _ in 0..<400 where !model.searchResults.contains(where: { $0.path == Self.prf }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.searchResults.contains { $0.path == Self.prf })
        #expect(model.searchResultsQuery == "pseudorandom")
    }

    // MARK: ⌘O (U2)

    @Test("a load with no quick switcher up sorts nothing, and opening one lists every page")
    func quickSwitcherIsWorkedOutWhenOpened() async throws {
        let saved = SavedRecentPages()
        defer { saved.restore() }
        let fixture = try ModelFixture()
        defer { fixture.delete() }
        let model = fixture.model

        await model.loadLibrary(reason: .pulled)
        #expect(model.quickSwitcherResults.isEmpty, "no window has a switcher up")

        model.resetQuickSwitcher(excluding: Self.prf)
        #expect(model.quickSwitcherQuery.isEmpty)
        #expect(!model.quickSwitcherResults.isEmpty)
        #expect(Self.paths(model) == Self.emptyQueryList(in: model, recent: []))
        #expect(model.quickSwitcherRecentCount == 0)
        #expect(Self.isFresh(model))
    }

    @Test("⌘O in another window, with the query still empty, leaves out that window's page")
    func quickSwitcherFollowsTheWindowThatOpensIt() async throws {
        let saved = SavedRecentPages()
        defer { saved.restore() }
        let fixture = try ModelFixture()
        defer { fixture.delete() }
        let model = fixture.model
        await model.loadLibrary(reason: .pulled)
        model.noteVisited(Self.owf)
        model.noteVisited(Self.prf)

        // A window reading PRF: OWF is the one recent page.
        model.resetQuickSwitcher(excluding: Self.prf)
        #expect(Self.paths(model) == Self.emptyQueryList(in: model, recent: [Self.owf]))
        #expect(model.quickSwitcherRecentCount == 1)
        #expect(Self.isFresh(model))

        // Another window, reading OWF. The query is empty already, so
        // clearing it changes nothing, and the list must still follow.
        model.resetQuickSwitcher(excluding: Self.owf)
        #expect(Self.paths(model) == Self.emptyQueryList(in: model, recent: [Self.prf]))
        #expect(model.quickSwitcherRecentCount == 1)
        #expect(Self.isFresh(model))

        // A query typed, then ⌘O again: the query is cleared with it.
        model.quickSwitcherQuery = "learning"
        #expect(Self.paths(model) != Self.emptyQueryList(in: model, recent: [Self.owf]))
        model.resetQuickSwitcher(excluding: Self.prf)
        #expect(model.quickSwitcherQuery.isEmpty)
        #expect(Self.paths(model) == Self.emptyQueryList(in: model, recent: [Self.owf]))
        #expect(model.quickSwitcherRecentCount == 1)
        #expect(Self.isFresh(model))
    }

    // MARK: Helpers

    private static let owf = FixtureClone.relative(FixtureClone.owf)

    /// ⌘O's list as paths.
    private static func paths(_ model: AppModel) -> [String] {
        model.quickSwitcherResults.map(\.path)
    }

    /// ⌘O's list for an empty query, from the index itself: the `recent`
    /// pages first, then every other listed page by title.
    private static func emptyQueryList(in model: AppModel, recent: [String]) -> [String] {
        let items = model.index?.quickSwitch("", excluding: model.unlistedPaths, recent: recent)
        return items?.map(\.path) ?? []
    }

    /// Whether ⌘O's list is the one a refresh would give now. Refreshes.
    private static func isFresh(_ model: AppModel) -> Bool {
        let shown = paths(model)
        let recentCount = model.quickSwitcherRecentCount
        model.refreshQuickSwitcher()
        return paths(model) == shown && model.quickSwitcherRecentCount == recentCount
    }

    /// ⌘O's recent pages are a user default, which a model reads when it is
    /// made and `noteVisited` writes, along with the last page. Cleared until
    /// `restore`, so each test starts from none.
    private struct SavedRecentPages {
        let recent = CCwikiSettings.recentPages
        let last = CCwikiSettings.lastPage

        init() {
            CCwikiSettings.recentPages = []
        }

        func restore() {
            CCwikiSettings.recentPages = recent
            CCwikiSettings.lastPage = last
        }
    }
}

/// An `AppModel` over the fixture clone, in an Application Support folder of
/// its own. Not loaded: a test loads it when it needs the library.
@MainActor
struct ModelFixture {
    let support: URL
    let model: AppModel

    init(_ files: [String: String] = FixtureClone.standard) throws {
        support = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-model-\(UUID().uuidString)")
        let paths = AppPaths(support: support)
        for (path, text) in files {
            let file = paths.clone.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        model = AppModel(paths: paths)
    }

    /// Removes the whole folder: the clone, the search index and the rest.
    func delete() {
        try? FileManager.default.removeItem(at: support)
    }
}
