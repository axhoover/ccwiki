import Foundation
import Testing
@testable import CCwiki

/// A window the app opens as a tab waits for its view to see its `NSWindow`,
/// then takes its tabbing, once (plans/reader-comforts.md §1.4).
struct ReaderWindowRequestsTests {

    private static func request(
        tabbingInto window: Int?, inBackground: Bool = true
    ) -> ReaderWindowRequest {
        ReaderWindowRequest(
            window: ReaderWindow(opening: .page(path: "A.md", anchor: nil)),
            tabbingInto: window, inBackground: inBackground)
    }

    @Test("a tabbing request is consumed once, by the window it names")
    func consumedOnce() {
        var requests = ReaderWindowRequests()
        let tab = Self.request(tabbingInto: 42)
        requests.expect(tab)

        let other = requests.takeTabbing(for: UUID())
        #expect(other == nil, "another window takes nothing")
        let first = requests.takeTabbing(for: tab.window.id)
        #expect(first == tab)
        let second = requests.takeTabbing(for: tab.window.id)
        #expect(second == nil, "the second look finds nothing")
        #expect(requests == ReaderWindowRequests())
    }

    @Test("requests for several windows are kept apart")
    func severalWindows() {
        var requests = ReaderWindowRequests()
        let behind = Self.request(tabbingInto: 42)
        let inFront = Self.request(tabbingInto: 42, inBackground: false)
        let window = Self.request(tabbingInto: nil, inBackground: false)
        requests.expect(behind)
        requests.expect(inFront)
        requests.expect(window)

        let step1 = requests.takeTabbing(for: inFront.window.id)
        #expect(step1 == inFront)
        let step2 = requests.takeTabbing(for: window.window.id)
        #expect(step2 == window)
        #expect(step2?.tabbingInto == nil, "a window of its own")
        let step3 = requests.takeTabbing(for: behind.window.id)
        #expect(step3 == behind)
    }

    @Test("a new tab joins the window it was asked from, behind it or in front")
    func tabsJoinTheirSource() {
        let window = ReaderWindow(opening: .page(path: "A.md", anchor: nil), find: ["prf"])

        let behind = ReaderWindowRequest(
            opening: window, as: .newTab(inBackground: true), beside: 42)
        #expect(behind == ReaderWindowRequest(window: window, tabbingInto: 42, inBackground: true))

        let inFront = ReaderWindowRequest(
            opening: window, as: .newTab(inBackground: false), beside: 42)
        #expect(inFront == ReaderWindowRequest(
            window: window, tabbingInto: 42, inBackground: false))
    }

    @Test("a new window, or a tab with no window to join, is a window of its own")
    func windowsJoinNothing() {
        let window = ReaderWindow()

        let newWindow = ReaderWindowRequest(opening: window, as: .newWindow, beside: 42)
        #expect(newWindow == ReaderWindowRequest(
            window: window, tabbingInto: nil, inBackground: false))

        let orphanTab = ReaderWindowRequest(
            opening: window, as: .newTab(inBackground: false), beside: nil)
        #expect(orphanTab?.tabbingInto == nil)
        #expect(orphanTab?.window == window)
    }

    @Test("opening here or on the site opens no window")
    func noWindowForHereOrSite() {
        let window = ReaderWindow()
        #expect(ReaderWindowRequest(opening: window, as: .here, beside: 42) == nil)
        #expect(ReaderWindowRequest(opening: window, as: .onSite, beside: 42) == nil)
    }

    @Test("every window value is new, so opening one never brings another forward")
    func windowValuesAreUnique() {
        let opening = AppModel.Location.page(path: "A.md", anchor: nil)
        #expect(ReaderWindow() != ReaderWindow())
        #expect(ReaderWindow(opening: opening) != ReaderWindow(opening: opening))
        #expect(ReaderWindow().opening == nil)
        #expect(ReaderWindow().find == nil)
    }

    @Test("a window value survives macOS's restoration of it")
    func windowValueRoundTrip() throws {
        let window = ReaderWindow(
            opening: .page(path: "Assumptions/learning-with-errors.md", anchor: "syntax"),
            find: ["LWE", "learning"])
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(ReaderWindow.self, from: data)
        #expect(decoded == window)
    }
}
