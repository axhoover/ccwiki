import Foundation
import Testing
@testable import CCwiki

/// "The active reader" for the windows that are not readers: the explorer,
/// Jobs and a paper window open pages in the reader used last
/// (plans/reader-comforts.md §1.8).
struct SessionOrderTests {

    @Test("the explorer's pages go to the most recently key reader")
    func mostRecentlyKey() {
        var order = SessionOrder<String>()
        order.opened("A")
        order.becameKey("A")
        order.opened("B")
        order.becameKey("B")
        #expect(order.mostRecent == "B")
        order.becameKey("A")
        #expect(order.mostRecent == "A")
        #expect(order.count == 2)
    }

    @Test("closing it moves them to the next; with none, nil")
    func closing() {
        var order = SessionOrder<String>()
        for id in ["A", "B", "C"] {
            order.opened(id)
            order.becameKey(id)
        }
        order.closed("C")
        #expect(order.mostRecent == "B")
        order.closed("A")
        #expect(order.mostRecent == "B", "closing another changes nothing")
        order.closed("B")
        #expect(order.mostRecent == nil)
        #expect(order.count == 0)
        #expect(order == SessionOrder<String>())
    }

    @Test("a window opened behind the key one is the least recent until it becomes key")
    func openedIsLeastRecent() {
        var order = SessionOrder<String>()
        order.opened("A")
        #expect(order.mostRecent == "A", "the only reader is the active one, key or not")
        order.becameKey("A")
        order.opened("B")
        #expect(order.mostRecent == "A")
        order.closed("A")
        #expect(order.mostRecent == "B")
    }

    @Test("each window counts once, however it is reported")
    func countsOnce() {
        var order = SessionOrder<UUID>()
        let a = UUID()
        let b = UUID()
        order.opened(a)
        order.opened(a)
        order.becameKey(a)
        order.becameKey(a)
        #expect(order.count == 1)
        order.becameKey(b)
        #expect(order.mostRecent == b, "a window that became key before it was counted")
        #expect(order.count == 2)
        order.closed(UUID())
        #expect(order.count == 2)
    }
}
