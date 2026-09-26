import Foundation
import Testing
@testable import CCwiki

/// Back and Forward, and the one rule that used to be wrong: re-selecting the
/// current page is not a visit. Following `[[Other#section]]` used to leave
/// the anchored entry on the stack twice and empty Forward, because revealing
/// the destination in the sidebar re-opened it without the anchor.
struct NavigationHistoryTests {

    private typealias Location = AppModel.Location

    private static let a = Location.page(path: "A.md", anchor: nil)
    private static let b = Location.page(path: "B.md", anchor: nil)
    private static let bAnchored = Location.page(path: "B.md", anchor: "section")
    private static let c = Location.page(path: "C.md", anchor: nil)
    private static let folder = Location.folder(slug: "Primitives")

    @Test("the first visit records nothing to go back to")
    func firstVisit() {
        var history = NavigationHistory()
        #expect(history.visit(Self.a))
        #expect(history.current == Self.a)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("back and forward are inverses")
    func backAndForward() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.b)
        history.visit(Self.c)

        #expect(history.goBack() == Self.b)
        #expect(history.goBack() == Self.a)
        #expect(history.goBack() == nil)
        #expect(history.goForward() == Self.b)
        #expect(history.goForward() == Self.c)
        #expect(history.goForward() == nil)
        #expect(history.current == Self.c)
    }

    @Test("a new visit clears forward")
    func visitClearsForward() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.b)
        _ = history.goBack()
        #expect(history.canGoForward)

        history.visit(Self.c)
        #expect(!history.canGoForward)
        #expect(history.goBack() == Self.a)
    }

    @Test("re-selecting the current page without an anchor is not a visit")
    func reselectingCurrentPage() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.bAnchored)
        // What the sidebar does after `reveal` selects B's row.
        #expect(!history.visit(Self.b))
        #expect(history.current == Self.bAnchored, "the anchor is kept")
        #expect(history.back == [Self.a], "nothing was pushed")

        #expect(history.goBack() == Self.a)
        #expect(history.goForward() == Self.bAnchored)
    }

    @Test("going back onto an anchored entry keeps forward intact")
    func backOntoAnchoredEntry() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.bAnchored)
        history.visit(Self.c)

        #expect(history.goBack() == Self.bAnchored)
        // The sidebar re-selects B on reveal; that must not disturb anything.
        #expect(!history.visit(Self.b))
        #expect(history.canGoForward)
        #expect(history.goForward() == Self.c)
    }

    @Test("the same location twice is not a visit, and an anchor on the current page is")
    func sameLocation() {
        var history = NavigationHistory()
        history.visit(Self.b)
        #expect(!history.visit(Self.b))
        #expect(history.visit(Self.bAnchored), "an in-page jump is a history entry, as in a browser")
        #expect(!history.visit(Self.bAnchored))
        #expect(history.goBack() == Self.b)
    }

    @Test("a folder listing is a location like any other")
    func folders() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.folder)
        // Leaving a folder for a page is a move even though the folder has no path.
        #expect(history.visit(Self.a))
        #expect(history.goBack() == Self.folder)
        #expect(history.goBack() == Self.a)
    }

    @Test("an unrecorded visit moves without leaving a trail")
    func unrecorded() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.b, recording: false)
        #expect(history.current == Self.b)
        #expect(!history.canGoBack)
    }

    @Test("back is bounded")
    func bounded() {
        var history = NavigationHistory()
        for i in 0...(NavigationHistory.capacity + 10) {
            history.visit(.page(path: "\(i).md", anchor: nil))
        }
        #expect(history.back.count == NavigationHistory.capacity)
        #expect(history.back.first == .page(path: "11.md", anchor: nil))
    }
}
