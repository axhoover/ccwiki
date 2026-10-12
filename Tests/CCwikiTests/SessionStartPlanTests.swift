import Foundation
import Testing
@testable import CCwiki

/// How a reader window starts (plans/reader-comforts.md §1.7): the one rule
/// of tabs and windows that decides what every window shows first, and the
/// one no test could see if it lived in a view.
struct SessionStartPlanTests {

    private typealias Location = AppModel.Location

    private static let lastPage = "Primitives/pseudorandom-function.md"
    private static let a = Location.page(path: "A.md", anchor: nil)
    private static let b = Location.page(path: "B.md", anchor: "proof")
    private static let opening = Location.page(
        path: "Assumptions/learning-with-errors.md", anchor: nil)

    /// A window that was on B, having come from A.
    private static func restored() -> ReaderSessionState {
        var history = NavigationHistory()
        history.visit(a)
        history.visit(b)
        return ReaderSessionState(
            history: history, inspectorTab: AppModel.InspectorTab.outline.rawValue,
            showsInspector: true, expandedFolders: [])
    }

    private static func plan(
        restored: ReaderSessionState? = nil, window: ReaderWindow = ReaderWindow(),
        pending: Location? = nil, launchDocument: AppModel.Document? = nil,
        isColdStart: Bool = false, lastPage: String? = SessionStartPlanTests.lastPage
    ) -> SessionStartPlan {
        SessionStartPlan.plan(
            restored: restored, window: window, pending: pending,
            launchDocument: launchDocument, isColdStart: isColdStart, lastPage: lastPage)
    }

    @Test("a cold launch opens the page read last, once the wiki is loaded")
    func coldLaunch() {
        let plan = Self.plan(isColdStart: true)
        #expect(plan.history == NavigationHistory())
        #expect(plan.showsAtOnce == nil)
        #expect(plan.opensOnLoad == .page(path: Self.lastPage, anchor: nil))
        #expect(plan.find == nil)
        #expect(!plan.opensHomeOnLoad)
    }

    @Test("a cold launch with no page read last, or under the harness, opens Home")
    func coldLaunchWithoutLastPage() {
        let plan = Self.plan(isColdStart: true, lastPage: nil)
        #expect(plan.opensOnLoad == nil)
        #expect(plan.opensHomeOnLoad)
    }

    @Test("New Window, New Tab and the tab bar's + button open Home")
    func newWindowOpensHome() {
        // All three open the group's default value: a fresh ReaderWindow.
        let plan = Self.plan(window: ReaderWindow())
        #expect(plan.history == NavigationHistory())
        #expect(plan.opensOnLoad == nil)
        #expect(plan.opensHomeOnLoad)
    }

    @Test("the cold start is used once: the next window opens Home")
    func coldStartUsedOnce() {
        let first = Self.plan(isColdStart: true)
        let second = Self.plan(isColdStart: false)
        #expect(first.opensOnLoad == .page(path: Self.lastPage, anchor: nil))
        #expect(second.opensOnLoad == nil)
        #expect(second.opensHomeOnLoad)
    }

    @Test("a window opened on a page opens it, and finds on it")
    func openingOpens() {
        let window = ReaderWindow(opening: Self.opening, find: ["LWE"])
        let plan = Self.plan(window: window, isColdStart: true)
        #expect(plan.opensOnLoad == Self.opening, "the opening wins over the cold start")
        #expect(plan.find == ["LWE"])
        #expect(!plan.opensHomeOnLoad)
    }

    @Test("a restored window keeps its history and ignores its value's opening")
    func restoredKeepsHistory() {
        let state = Self.restored()
        let window = ReaderWindow(opening: Self.opening, find: ["LWE"])
        let plan = Self.plan(restored: state, window: window, isColdStart: true)
        #expect(plan.history == state.history)
        #expect(plan.history.current == Self.b)
        #expect(plan.opensOnLoad == nil, "neither the opening nor the last page")
        #expect(plan.find == nil)
        #expect(!plan.opensHomeOnLoad)
    }

    @Test("a restored window with nothing on screen still ignores its opening")
    func restoredEmptyIgnoresOpening() {
        let state = ReaderSessionState(
            history: NavigationHistory(), inspectorTab: "Outline",
            showsInspector: true, expandedFolders: [])
        let window = ReaderWindow(opening: Self.opening, find: ["LWE"])
        let later = Self.plan(restored: state, window: window)
        #expect(later.opensOnLoad == nil)
        #expect(later.find == nil)
        #expect(later.opensHomeOnLoad)

        let first = Self.plan(restored: state, window: window, isColdStart: true)
        #expect(first.opensOnLoad == .page(path: Self.lastPage, anchor: nil))
    }

    @Test("the launch document shows at once, with the restored page behind it")
    func launchDocumentOverRestored() {
        let state = Self.restored()
        let plan = Self.plan(restored: state, launchDocument: .whatsNew, isColdStart: true)
        #expect(plan.showsAtOnce == .document(.whatsNew))
        #expect(plan.history == state.history)
        #expect(plan.opensOnLoad == nil)
        #expect(!plan.opensHomeOnLoad)

        // What the session does with it: the document is a visit, so the
        // restored page is one Back away.
        var history = plan.history
        let step1 = history.visit(Location.document(.whatsNew))
        #expect(step1)
        #expect(history.back.last == Self.b)
    }

    @Test("the launch document is not opened over once the wiki loads")
    func launchDocumentStays() {
        let plan = Self.plan(launchDocument: .welcome, isColdStart: true)
        #expect(plan.showsAtOnce == .document(.welcome))
        #expect(plan.opensOnLoad == nil, "Welcome stays; the last page waits")
        #expect(!plan.opensHomeOnLoad)
    }

    @Test("a pending location opens in any session")
    func pendingOpens() {
        let pending = Location.page(path: "Primitives/one-way-function.md", anchor: "definition")

        let fresh = Self.plan(pending: pending, isColdStart: true)
        #expect(fresh.opensOnLoad == pending)
        #expect(!fresh.opensHomeOnLoad)

        let restored = Self.plan(restored: Self.restored(), pending: pending)
        #expect(restored.history.current == Self.b)
        #expect(restored.opensOnLoad == pending)

        let welcomed = Self.plan(pending: pending, launchDocument: .welcome)
        #expect(welcomed.showsAtOnce == .document(.welcome))
        #expect(welcomed.opensOnLoad == pending)

        let opened = Self.plan(
            window: ReaderWindow(opening: Self.opening, find: ["LWE"]), pending: pending)
        #expect(opened.opensOnLoad == pending)
        #expect(opened.find == nil, "the find belongs to the opening")
    }
}
