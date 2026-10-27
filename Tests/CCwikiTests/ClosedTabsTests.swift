import Foundation
import Testing
@testable import CCwiki

/// Edit ▸ Undo Close Tab (plans/reader-comforts.md §7): which closed tabs
/// are kept, in what order, how many, and how one starts again.
struct ClosedTabsTests {

    private typealias Location = AppModel.Location

    /// A tab that was on `path`, having come from A, with its inspector on
    /// Backlinks and one folder open.
    private static func tab(_ path: String, reading heading: String? = nil) -> ClosedTab {
        var history = NavigationHistory()
        history.visit(.page(path: "A.md", anchor: nil))
        history.visit(.page(path: path, anchor: nil))
        let state = ReaderSessionState(
            history: history, inspectorTab: AppModel.InspectorTab.backlinks.rawValue,
            showsInspector: true, expandedFolders: ["Primitives"])
        return ClosedTab(state: state, readingAnchor: heading)
    }

    @Test("the tab closed last comes back first, then the one before it")
    func mostRecentFirst() {
        var closed = ClosedTabs()
        #expect(closed.isEmpty)
        closed.remember(Self.tab("B.md"))
        closed.remember(Self.tab("C.md", reading: "proof"))
        #expect(!closed.isEmpty)

        let first = closed.takeLast()
        #expect(first == Self.tab("C.md", reading: "proof"))
        #expect(first?.readingAnchor == "proof", "it comes back at the heading being read")
        let second = closed.takeLast()
        #expect(second == Self.tab("B.md"))
        let third = closed.takeLast()
        #expect(third == nil, "nothing is left to reopen")
        #expect(closed.isEmpty)
    }

    @Test("ten are kept, and the oldest goes first")
    func bounded() {
        var closed = ClosedTabs()
        for number in 0..<(ClosedTabs.limit + 3) {
            closed.remember(Self.tab("Page \(number).md"))
        }
        #expect(closed.tabs.count == ClosedTabs.limit)
        #expect(closed.tabs.first == Self.tab("Page \(ClosedTabs.limit + 2).md"))
        #expect(closed.tabs.last == Self.tab("Page 3.md"), "pages 0 to 2 were closed longest ago")
    }

    @Test("a tab that showed nothing is not kept")
    func emptyTabForgotten() {
        var closed = ClosedTabs()
        let empty = ReaderSessionState(
            history: NavigationHistory(), inspectorTab: AppModel.InspectorTab.outline.rawValue,
            showsInspector: true, expandedFolders: [])
        closed.remember(ClosedTab(state: empty, readingAnchor: nil))
        #expect(closed.isEmpty)
    }

    @Test("an app page is kept, as a page is")
    func documentKept() {
        var history = NavigationHistory()
        history.visit(.document(.welcome))
        let state = ReaderSessionState(
            history: history, inspectorTab: AppModel.InspectorTab.outline.rawValue,
            showsInspector: false, expandedFolders: [])
        var closed = ClosedTabs()
        closed.remember(ClosedTab(state: state, readingAnchor: nil))
        let reopened = closed.takeLast()
        #expect(reopened?.state.history.current == Location.document(.welcome))
    }

    /// The reopened window starts from the closed tab's state as a window
    /// macOS restored does: with its history, not Home or the last page,
    /// even as the first reader after every window closed.
    @Test("a reopened tab starts with its own history, even as the cold start")
    func reopenedStart() {
        let tab = Self.tab("B.md", reading: "proof")
        let plan = SessionStartPlan.plan(
            restored: tab.state, window: ReaderWindow(), pending: nil,
            launchDocument: nil, isColdStart: true,
            lastPage: "Primitives/pseudorandom-function.md")
        #expect(plan.history == tab.state.history)
        #expect(plan.history.current == Location.page(path: "B.md", anchor: nil))
        #expect(plan.history.canGoBack, "Back still goes to A")
        #expect(plan.opensOnLoad == nil, "the page read last does not open over it")
        #expect(!plan.opensHomeOnLoad)
    }
}
