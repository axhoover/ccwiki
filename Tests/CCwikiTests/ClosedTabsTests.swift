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

    // MARK: Where it goes back

    /// The tab of window `number`, closed from between `before` and
    /// `after`, nearest first.
    private static func tab(number: Int, before: [Int], after: [Int]) -> ClosedTab {
        var closedTab = Self.tab("Page \(number).md")
        closedTab.windowNumber = number
        closedTab.tabsBefore = before
        closedTab.tabsAfter = after
        return closedTab
    }

    @Test("a closed tab goes back beside the nearest of its old window's tabs still open")
    func placeBesideNeighbours() {
        // B of [A, B, C, D], numbered 1 to 4.
        let tab = Self.tab(number: 2, before: [1], after: [3, 4])
        let bothOpen = tab.place { $0 }
        #expect(bothOpen == ClosedTab.Place(window: 1, after: true), "after the tab to its left")
        let leftClosed = tab.place { $0 == 1 ? nil : $0 }
        #expect(leftClosed == ClosedTab.Place(window: 3, after: false), "before the tab to its right")
        let onlyFar = tab.place { $0 == 4 ? $0 : nil }
        #expect(onlyFar == ClosedTab.Place(window: 4, after: false), "before the nearest one open")
        let reopened = tab.place { $0 == 1 ? 9 : nil }
        #expect(reopened == ClosedTab.Place(window: 9, after: true),
            "after the window that reopened its neighbour")
        let noneOpen = tab.place { _ in nil }
        #expect(noneOpen == nil, "a window of its own, never a tab of another window")
        let alone = Self.tab(number: 5, before: [], after: []).place { $0 }
        #expect(alone == nil, "a window closed alone comes back as a window")
    }

    /// Closes `closing` of a window whose tabs are `tabs`, by number, then
    /// reopens every closed tab as Undo Close Tab does. Gives the windows
    /// that result, each as its tabs in order, a reopened tab named by the
    /// number it had. `listsClosed`: AppKit still lists a closed tab among
    /// the window's tabs when the next one closes.
    private static func closeAndReopen(
        _ tabs: [Int], closing: [Int], listsClosed: Bool
    ) -> [[Int]] {
        var closed = ClosedTabs()
        var stillOpen = tabs
        for number in closing {
            let listed = listsClosed ? tabs : stillOpen
            guard let index = listed.firstIndex(of: number) else { continue }
            closed.remember(Self.tab(
                number: number,
                before: Array(listed[..<index].reversed()),
                after: Array(listed[(index + 1)...])))
            stillOpen.removeAll { $0 == number }
        }

        var windows: [[Int]] = stillOpen.isEmpty ? [] : [stillOpen]
        var reopenedAs: [Int: Int] = [:]
        func isOpen(_ number: Int) -> Bool { windows.contains { $0.contains(number) } }
        while let tab = closed.takeLast() {
            let number = 100 + reopenedAs.count
            let place = tab.place { old in
                if isOpen(old) { return old }
                if let new = reopenedAs[old], isOpen(new) { return new }
                return nil
            }
            if let place, let row = windows.firstIndex(where: { $0.contains(place.window) }),
               let column = windows[row].firstIndex(of: place.window) {
                windows[row].insert(number, at: place.after ? column + 1 : column)
            } else {
                windows.append([number])
            }
            reopenedAs[tab.windowNumber] = number
        }
        let original = Dictionary(uniqueKeysWithValues: reopenedAs.map { ($0.value, $0.key) })
        return windows.map { window in window.map { original[$0] ?? $0 } }
    }

    /// A window's tabs close one by one, in an order AppKit chooses, and
    /// ⌘Z brings them back one at a time.
    @Test("closed tabs come back in their window, in their order, whatever the order they closed in")
    func windowRebuilt() {
        let orders = [[1, 2, 3], [3, 2, 1], [2, 1, 3], [2, 3, 1], [1, 3, 2], [3, 1, 2]]
        for order in orders {
            for listsClosed in [false, true] {
                let rebuilt = Self.closeAndReopen([1, 2, 3], closing: order, listsClosed: listsClosed)
                #expect(rebuilt == [[1, 2, 3]],
                    "the whole window, closed in the order \(order), listed closed: \(listsClosed)")
            }
        }
        for closing in [[2], [3, 2], [2, 3], [4, 1], [2, 4, 3]] {
            let rebuilt = Self.closeAndReopen([1, 2, 3, 4], closing: closing, listsClosed: false)
            #expect(rebuilt == [[1, 2, 3, 4]], "tabs \(closing) of a window that stays open")
        }
    }
}
