import Foundation
import Observation
import Testing
@testable import CCwiki

/// The app model as the main window reads it (plans/efficiency.md, track U):
/// what a load does for the windows, and when; ⌘O's list; and where the
/// Relations inspector offers Explore From Here.
///
/// A test that needs a model makes its own, over an Application Support
/// folder of its own holding `FixtureClone.standard` and no git, so nothing
/// here reaches the network, a real clone or a web view. Serialized: ⌘O's
/// recent pages are a user default, which each model reads when it is made.
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

    // MARK: Explore From Here (U3)

    @Test("the inspector offers Explore From Here wherever it did, on the fixture graph")
    func canExploreAsTheQuestionDid() throws {
        let manifest = try ExplorerFixture.manifest()
        let derivation = try ExplorerFixture.derivation()
        let checked = Self.expectCanExploreAsTheQuestionDid(
            manifest: manifest, derivation: derivation)
        #expect(checked.offered > 0 && checked.withheld > 0, "\(checked)")

        // A class is never derived, an unknown id is no question, and with
        // nothing derivable there is no question at all.
        func explore(_ from: [String], _ to: String?, _ derivation: Derivation) -> Bool {
            AppModel.canExplore(from: from, to: to, manifest: manifest, derivation: derivation)
        }
        #expect(explore(["owf"], "pke", derivation))
        #expect(!explore(["bpp"], nil, derivation))
        #expect(!explore(["lwe"], "bpp", derivation))
        #expect(!explore(["nobody"], nil, derivation))
        #expect(!explore([], nil, derivation))
        #expect(explore([], "pke", derivation))
        #expect(!explore(["owf"], "pke", .empty))
        let none = Self.expectCanExploreAsTheQuestionDid(manifest: manifest, derivation: .empty)
        #expect(none.offered == 0)
    }

    @Test("the inspector offers Explore From Here wherever it did, on the real wiki")
    func canExploreAsTheQuestionDidOnTheCorpus() {
        guard let cloneRoot = RelationsTests.cloneRoot else { return }
        let manifest = RelationsManifest.load(cloneRoot: cloneRoot)
        let checked = Self.expectCanExploreAsTheQuestionDid(
            manifest: manifest, derivation: Derivation(manifest: manifest))
        print("Explore From Here on the corpus: \(checked.offered) offered, "
            + "\(checked.withheld) withheld")
        // Without the bundled curation nothing is derived, and nothing offered.
        if DerivationCuration.bundled != nil {
            #expect(checked.offered > 0)
        }
    }

    /// Asks `canExplore` every question the Relations inspector asks, and
    /// what the question used to be built from, and expects the same answer:
    /// each object alone; each reduction's hypotheses, its conclusion and,
    /// for an equivalence, its other end; each barrier's edge; and ids the
    /// manifest does not have.
    private static func expectCanExploreAsTheQuestionDid(
        manifest: RelationsManifest, derivation: Derivation
    ) -> (offered: Int, withheld: Int) {
        var questions: [(from: [String], to: String?)] = [([], nil), (["nobody"], nil)]
        for id in manifest.objectsByID.keys.sorted() {
            questions.append(([id], nil))
            questions.append(([], id))
        }
        for relation in manifest.reductions {
            questions.append((relation.hypotheses, nil))
            questions.append(([relation.conclusion], nil))
            if let first = relation.hypotheses.first { questions.append(([first], nil)) }
            questions.append((relation.hypotheses, relation.conclusion))
        }
        for barrier in manifest.barriers {
            questions.append((barrier.hypotheses, barrier.conclusion))
        }

        var offered = 0
        var withheld = 0
        for question in questions {
            let offers = AppModel.canExplore(
                from: question.from, to: question.to, manifest: manifest, derivation: derivation)
            let asked = Legacy.explorerQuestion(
                from: question.from, to: question.to, relations: manifest,
                derivation: derivation, explorerQuery: ExplorerQuery())
            #expect(offers == (asked != nil), "\(question.from) → \(question.to ?? "–")")
            if offers { offered += 1 } else { withheld += 1 }
        }
        return (offered, withheld)
    }

    /// Verbatim copy of AppModel.swift's `explorerQuestion(from:to:)` at
    /// 21df5d7 for equivalence tests, with the model's `relations`,
    /// `derivation` and `explorerQuery` as parameters. Do not edit; delete in
    /// the next batch.
    private enum Legacy {
        static func explorerQuestion(
            from: [String], to: String? = nil, relations: RelationsManifest,
            derivation: Derivation, explorerQuery: ExplorerQuery
        ) -> ExplorerQuery? {
            let named = from + (to.map { [$0] } ?? [])
            guard !named.isEmpty, !derivation.participants(.all).isEmpty, named.allSatisfy({ id in
                relations.object(id).map { $0.type != Derivation.excludedType } ?? false
            }) else { return nil }
            return ExplorerQuery(from: from, to: to,
                                 includesIdealisedModels: explorerQuery.includesIdealisedModels)
        }
    }

    // MARK: A sync's lines (U4)

    @Test("a sync's lines reach the line under the status, never its phase")
    func syncLinesLeaveThePhaseAlone() throws {
        let fixture = try ModelFixture()
        defer { fixture.delete() }
        let model = fixture.model
        let readPhase = { _ = model.syncState }
        let readLine = { _ = model.syncProgress }
        var phasesEntered = 0
        var linesAppended = 0
        var phaseNotifications = 0

        /// A change of phase reaches the phase's readers, and clears the line.
        func enter(_ state: AppModel.SyncState) {
            let hadLine = model.syncProgress != nil
            let seen = Self.notifications(readPhase, readLine) { model.enterSyncPhase(state) }
            phasesEntered += 1
            if seen.first { phaseNotifications += 1 }
            #expect(seen.first, "\(state)")
            #expect(seen.second == hadLine, "\(state)")
            #expect(model.syncState == state)
            #expect(model.syncProgress == nil)
        }

        /// A line reaches the line's readers alone, and only while a phase
        /// runs.
        func append(_ lines: [ProcessLine]) {
            for processLine in lines {
                let state = model.syncState
                let before = model.syncProgress
                let shows = state.isRunning && !processLine.text.isEmpty
                let expected: String? = shows ? processLine.text : before
                let seen = Self.notifications(readPhase, readLine) {
                    model.appendSyncLine(processLine)
                }
                linesAppended += 1
                if seen.first { phaseNotifications += 1 }
                #expect(!seen.first, "\(processLine.text)")
                #expect(seen.second == shows, "\(processLine.text)")
                #expect(model.syncState == state)
                #expect(model.syncProgress == expected)
            }
        }

        enter(.running("Cloning the wiki…"))
        let cloning = SyncLogView.subtitle(
            for: model.syncState, progress: model.syncProgress, hasLog: false)
        #expect(cloning == "Running: Cloning the wiki…")
        let clone = Self.cloneLines()
        append(clone)
        let last = try #require(clone.last(where: { !$0.text.isEmpty }))
        let cloned = SyncLogView.subtitle(
            for: model.syncState, progress: model.syncProgress, hasLog: true)
        #expect(cloned == "Running: \(last.text)")

        enter(.running("Indexing…"))
        let indexing = SyncLogView.subtitle(
            for: model.syncState, progress: model.syncProgress, hasLog: true)
        #expect(indexing == "Running: Indexing…")
        // A line can land after its own phase is over: it shows until the
        // next phase, as it did when it replaced the phase's text.
        append([Self.line("Resolving deltas: 100% (2/2), done.")])
        enter(.succeeded("Wiki updated: 4 pages changed."))
        append([Self.line("a line from a sync that is over")])
        enter(.idle)

        enter(.running("Fetching…"))
        append([Self.line("remote: Counting objects:  50% (1/2)", progress: true)])
        enter(.failed("The fetch failed (exit 128)."))
        enter(.running("Fetching…"))
        enter(.failed("Offline — reading from the last pull."))

        #expect(phasesEntered == 8)
        #expect(linesAppended == clone.count + 3)
        // A comment is one string literal: `Comment` is not a `String`, so
        // two joined with `+` do not convert.
        #expect(phaseNotifications == phasesEntered,
                "the phase's readers heard \(phaseNotifications) changes in \(phasesEntered) phases and \(linesAppended) lines")
    }

    @Test("a page's subject alone is the one its relations find")
    func subjectAloneIsTheRelations() throws {
        Self.expectSubjects(in: try ExplorerFixture.manifest())
    }

    @Test("a page's subject alone is the one its relations find, on the real wiki")
    func subjectAloneIsTheRelationsOnTheCorpus() {
        guard let cloneRoot = RelationsTests.cloneRoot else { return }
        Self.expectSubjects(in: RelationsManifest.load(cloneRoot: cloneRoot))
    }

    /// `PageRelations.subject(path:manifest:)` against the relations' own,
    /// for every page the manifest names and two it does not.
    private static func expectSubjects(in manifest: RelationsManifest) {
        let paths = Set(manifest.objectsByID.values.map(\.path))
            .union(manifest.reductions.map(\.path))
            .union(manifest.barriers.map(\.path))
            .union(["References/nobody.md", "index.md"])
        #expect(paths.count > 3)
        for path in paths.sorted() {
            let alone = PageRelations.subject(path: path, manifest: manifest)
            let found = PageRelations(path: path, manifest: manifest).subject
            #expect(alone == found, "\(path)")
        }
    }

    /// What a clone prints, in kind if not in number: a first line, three
    /// runs of progress updates ending in a percentage, a blank line, and a
    /// last line.
    private static func cloneLines() -> [ProcessLine] {
        var lines = [line("Cloning into 'repo'...")]
        for percent in 1...100 {
            lines.append(line("remote: Counting objects: \(percent)% (\(percent)/100)",
                              progress: percent < 100))
        }
        for percent in 1...100 {
            lines.append(line("Receiving objects: \(percent)% (\(percent * 41)/4100)",
                              progress: percent < 100))
        }
        lines.append(line(""))
        for percent in 1...100 {
            lines.append(line("Resolving deltas: \(percent)% (\(percent * 2)/200)",
                              progress: percent < 100))
        }
        lines.append(line("Updating files: 100% (880/880), done."))
        return lines
    }

    private static func line(_ text: String, progress: Bool = false) -> ProcessLine {
        ProcessLine(stream: .stderr, text: text, isProgress: progress)
    }

    /// Whether a view that ran `first`, and one that ran `second`, would be
    /// told of what `change` does. `withObservationTracking` calls `onChange`
    /// as the change is made, so both are known when `change` returns.
    private static func notifications(
        _ first: () -> Void, _ second: () -> Void, when change: () -> Void
    ) -> (first: Bool, second: Bool) {
        let firstFlag = ChangeFlag()
        let secondFlag = ChangeFlag()
        withObservationTracking {
            first()
        } onChange: {
            firstFlag.raise()
        }
        withObservationTracking {
            second()
        } onChange: {
            secondFlag.raise()
        }
        change()
        return (firstFlag.isRaised, secondFlag.isRaised)
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

/// Raised from `withObservationTracking`'s `onChange`, which is `@Sendable`.
/// `@unchecked Sendable` with a lock, as `ProgressLog` is.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        defer { lock.unlock() }
        raised = true
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
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
