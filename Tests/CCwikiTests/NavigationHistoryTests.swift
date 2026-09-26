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
        let step1 = history.visit(Self.a)
        #expect(step1)
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

        let step2 = history.goBack()
        #expect(step2 == Self.b)
        let step3 = history.goBack()
        #expect(step3 == Self.a)
        let step4 = history.goBack()
        #expect(step4 == nil)
        let step5 = history.goForward()
        #expect(step5 == Self.b)
        let step6 = history.goForward()
        #expect(step6 == Self.c)
        let step7 = history.goForward()
        #expect(step7 == nil)
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
        let step8 = history.goBack()
        #expect(step8 == Self.a)
    }

    @Test("re-selecting the current page without an anchor is not a visit")
    func reselectingCurrentPage() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.bAnchored)
        // What the sidebar does after `reveal` selects B's row.
        let step9 = history.visit(Self.b)
        #expect(!step9)
        #expect(history.current == Self.bAnchored, "the anchor is kept")
        #expect(history.back == [Self.a], "nothing was pushed")

        let step10 = history.goBack()
        #expect(step10 == Self.a)
        let step11 = history.goForward()
        #expect(step11 == Self.bAnchored)
    }

    @Test("going back onto an anchored entry keeps forward intact")
    func backOntoAnchoredEntry() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.bAnchored)
        history.visit(Self.c)

        let step12 = history.goBack()
        #expect(step12 == Self.bAnchored)
        // The sidebar re-selects B on reveal; that must not disturb anything.
        let step13 = history.visit(Self.b)
        #expect(!step13)
        #expect(history.canGoForward)
        let step14 = history.goForward()
        #expect(step14 == Self.c)
    }

    @Test("the same location twice is not a visit, and an anchor on the current page is")
    func sameLocation() {
        var history = NavigationHistory()
        history.visit(Self.b)
        let step15 = history.visit(Self.b)
        #expect(!step15)
        let step16 = history.visit(Self.bAnchored)
        #expect(step16, "an in-page jump is a history entry, as in a browser")
        let step17 = history.visit(Self.bAnchored)
        #expect(!step17)
        let step18 = history.goBack()
        #expect(step18 == Self.b)
    }

    @Test("a folder listing is a location like any other")
    func folders() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.folder)
        // Leaving a folder for a page is a move even though the folder has no path.
        let step19 = history.visit(Self.a)
        #expect(step19)
        let step20 = history.goBack()
        #expect(step20 == Self.folder)
        let step21 = history.goBack()
        #expect(step21 == Self.a)
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
