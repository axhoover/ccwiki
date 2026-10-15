import Foundation
import Testing
@testable import CCwiki

/// The ingest sheet stays on the window it was asked for in, so its link,
/// notes and dropped PDF survive a click on another window
/// (plans/reader-comforts.md §1.3).
struct IngestSheetTargetTests {

    private let a = UUID()
    private let b = UUID()

    @Test("the sheet goes to the window that asked, else the active reader")
    func pins() {
        var named = IngestSheetTarget()
        named.request(in: a, active: b)
        #expect(named.window == a)
        #expect(!named.isWaiting)

        var active = IngestSheetTarget()
        active.request(in: nil, active: b)
        #expect(active.window == b)
    }

    @Test("the sheet stays on its window when another reader becomes key")
    func staysPut() {
        var target = IngestSheetTarget()
        target.request(in: nil, active: a)
        // B becomes key, and the Jobs window asks again.
        target.request(in: nil, active: b)
        #expect(target.window == a)
    }

    @Test("a request while the sheet is shown changes nothing")
    func requestWhileShown() {
        var target = IngestSheetTarget()
        target.request(in: a, active: a)
        let shown = target
        target.request(in: b, active: b)
        target.request(in: nil, active: nil)
        #expect(target == shown)
    }

    @Test("a request with no reader open waits, and the next session claims it once")
    func waits() {
        var target = IngestSheetTarget()
        target.request(in: nil, active: nil)
        #expect(target.window == nil)
        #expect(target.isWaiting)

        let first = target.claim(by: a)
        #expect(first)
        #expect(target.window == a)
        #expect(!target.isWaiting)
        let second = target.claim(by: b)
        #expect(!second, "claimed once")
        #expect(target.window == a)
    }

    @Test("nothing to claim when nothing is waiting")
    func claimWithoutRequest() {
        var target = IngestSheetTarget()
        let claimed = target.claim(by: a)
        #expect(!claimed)
        #expect(target.window == nil)
    }

    @Test("a waiting request is pinned by the next one that can name a window")
    func waitingThenPinned() {
        var target = IngestSheetTarget()
        target.request(in: nil, active: nil)
        target.request(in: nil, active: b)
        #expect(target.window == b)
        #expect(!target.isWaiting)
    }

    @Test("closing its window clears it; closing another does not")
    func windowClosed() {
        var target = IngestSheetTarget()
        target.request(in: a, active: a)
        target.windowClosed(b)
        #expect(target.window == a)
        target.windowClosed(a)
        #expect(target.window == nil)
        #expect(!target.isWaiting)

        target.request(in: b, active: a)
        #expect(target.window == b, "a new request after the close is pinned afresh")
    }

    @Test("dismissing clears the sheet and any waiting request")
    func dismiss() {
        var shown = IngestSheetTarget()
        shown.request(in: a, active: a)
        shown.dismiss()
        #expect(shown == IngestSheetTarget())

        var waiting = IngestSheetTarget()
        waiting.request(in: nil, active: nil)
        waiting.dismiss()
        #expect(waiting == IngestSheetTarget())
        let claimed = waiting.claim(by: a)
        #expect(!claimed)
    }
}
