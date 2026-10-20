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
