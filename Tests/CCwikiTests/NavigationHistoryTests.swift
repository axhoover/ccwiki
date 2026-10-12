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
        // 111 visits; the first records nothing, so pages 0…109 were pushed
        // and the oldest ten fell off.
        #expect(history.back.count == NavigationHistory.capacity)
        #expect(history.back.first == .page(path: "10.md", anchor: nil))
    }

    // MARK: Saved and restored (reader-comforts §1.7)

    private static let d = Location.page(path: "D.md", anchor: nil)
    private static let welcome = Location.document(.welcome)

    /// A, B#section, the folder, C, then back twice: something on each side.
    private static func travelled() -> NavigationHistory {
        var history = NavigationHistory()
        history.visit(a)
        history.visit(bAnchored)
        history.visit(folder)
        history.visit(c)
        _ = history.goBack()
        _ = history.goBack()
        return history
    }

    /// The shape `NavigationHistory` encodes to, without its bounds, so a
    /// test can write what an older or damaged save might hold.
    private struct Saved: Encodable {
        var current: Location
        var back: [Location]
        var forward: [Location]
    }

    private static func decode(_ saved: Saved) throws -> NavigationHistory {
        try JSONDecoder().decode(NavigationHistory.self, from: JSONEncoder().encode(saved))
    }

    @Test("Back and Forward survive encoding and decoding, anchors and all")
    func codableRoundTrip() throws {
        let history = Self.travelled()
        #expect(history.current == Self.bAnchored)
        #expect(history.back == [Self.a])
        #expect(history.forward == [Self.c, Self.folder])

        let data = try JSONEncoder().encode(history)
        var decoded = try JSONDecoder().decode(NavigationHistory.self, from: data)
        #expect(decoded == history)
        let step22 = decoded.goForward()
        #expect(step22 == Self.folder)
        let step23 = decoded.goBack()
        #expect(step23 == Self.bAnchored)
        let step24 = decoded.goBack()
        #expect(step24 == Self.a)

        let documents = NavigationHistory(current: Self.welcome, back: [Self.a], forward: [])
        let decodedDocuments = try JSONDecoder().decode(
            NavigationHistory.self, from: JSONEncoder().encode(documents))
        #expect(decodedDocuments == documents)
    }

    @Test("a decoded history keeps the nearest entries within capacity, on both sides")
    func decodeAppliesCapacity() throws {
        let pages = (0..<(NavigationHistory.capacity + 50)).map {
            Location.page(path: "\($0).md", anchor: nil)
        }
        let decoded = try Self.decode(Saved(current: Self.c, back: pages, forward: pages))
        #expect(decoded.current == Self.c)
        #expect(decoded.back.count == NavigationHistory.capacity)
        #expect(decoded.forward.count == NavigationHistory.capacity)
        // Both are stacks, nearest last: the far ends are what goes.
        #expect(decoded.back.first == .page(path: "50.md", anchor: nil))
        #expect(decoded.back.last == pages.last)
        #expect(decoded.forward.first == .page(path: "50.md", anchor: nil))

        let built = NavigationHistory(current: Self.c, back: pages, forward: [])
        #expect(built.back == decoded.back, "the initializer applies the same bound")
    }

    @Test("a saved history with nothing on screen has nothing to go back or forward to")
    func decodeNormalisesEmpty() throws {
        let gaps = try Self.decode(Saved(
            current: Self.c, back: [Self.a, .empty, Self.b], forward: [.empty]))
        #expect(gaps.back == [Self.a, Self.b])
        #expect(!gaps.canGoForward)

        let blank = try Self.decode(Saved(current: .empty, back: [Self.a], forward: [Self.c]))
        #expect(blank.current == Self.a, "the nearest Back entry is put on screen")
        #expect(!blank.canGoBack)
        #expect(blank.forward == [Self.c])

        let nothing = try Self.decode(Saved(current: .empty, back: [], forward: [Self.c]))
        #expect(nothing == NavigationHistory())
    }

    @Test("pruning drops the pages the wiki lost from Back and Forward")
    func prunedDropsLostPages() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.b)
        history.visit(Self.c)
        history.visit(Self.d)
        _ = history.goBack()
        // Back A, B; on C; Forward D.
        let pruned = history.pruned { $0 != Self.b && $0 != Self.d }
        #expect(pruned.current == Self.c)
        #expect(pruned.back == [Self.a])
        #expect(!pruned.canGoForward)
    }

    @Test("pruning keeps a history whose pages all survive as it was")
    func prunedKeepsEverything() {
        let history = Self.travelled()
        #expect(history.pruned { _ in true } == history)
    }

    @Test("a lost current page falls back to the nearest kept Back entry, keeping Forward")
    func prunedLostCurrentFallsBack() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.b)
        history.visit(Self.folder)
        history.visit(Self.c)
        history.visit(Self.d)
        _ = history.goBack()
        // Back A, B, folder; on C; Forward D. C and the folder are gone.
        let pruned = history.pruned { $0 != Self.c && $0 != Self.folder }
        #expect(pruned.current == Self.b)
        #expect(pruned.back == [Self.a])
        #expect(pruned.forward == [Self.d])
    }

    @Test("a lost current page with nothing kept behind it leaves an empty history")
    func prunedLostCurrentWithNothingBehind() {
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.c)
        history.visit(Self.d)
        _ = history.goBack()
        // Back A; on C; Forward D. Only D survives.
        let pruned = history.pruned { $0 == Self.d }
        #expect(pruned.current == .empty)
        #expect(!pruned.canGoBack)
        #expect(!pruned.canGoForward, "an empty reader has nowhere to go forward from")
    }

    @Test("pruning collapses the duplicates a removed page leaves side by side")
    func prunedCollapsesAdjacentDuplicates() {
        // A, B, A, C: without B, Back would hold A twice in a row.
        var history = NavigationHistory()
        history.visit(Self.a)
        history.visit(Self.b)
        history.visit(Self.a)
        history.visit(Self.c)
        let withoutB = history.pruned { $0 != Self.b }
        #expect(withoutB.current == Self.c)
        #expect(withoutB.back == [Self.a])

        // A, B, A: without B, Back's A is the page on screen.
        var returned = NavigationHistory()
        returned.visit(Self.a)
        returned.visit(Self.b)
        returned.visit(Self.a)
        let onA = returned.pruned { $0 != Self.b }
        #expect(onA.current == Self.a)
        #expect(!onA.canGoBack)

        // The same on the Forward side, a stack with the nearest entry last:
        // on C, ahead of it D, B, D, C. Without B: D, C.
        let ahead = NavigationHistory(
            current: Self.c, back: [], forward: [Self.c, Self.d, Self.b, Self.d])
        let collapsed = ahead.pruned { $0 != Self.b }
        #expect(collapsed.forward == [Self.c, Self.d])

        // Back repeating itself behind a lost current: one C, on screen.
        let repeated = NavigationHistory(
            current: Self.b, back: [Self.a, Self.c, Self.c], forward: [])
        let fallen = repeated.pruned { $0 != Self.b }
        #expect(fallen.current == Self.c)
        #expect(fallen.back == [Self.a])
    }

    @Test("an anchor is part of the entry: pruning compares whole locations")
    func prunedKeepsAnchoredEntries() {
        var history = NavigationHistory()
        history.visit(Self.b)
        history.visit(Self.bAnchored)
        history.visit(Self.c)
        let pruned = history.pruned { $0 != Self.c }
        #expect(pruned.current == Self.bAnchored)
        #expect(pruned.back == [Self.b])
    }
}
