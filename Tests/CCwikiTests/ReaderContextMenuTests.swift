import Foundation
import Testing
@testable import CCwiki

/// The copy items at the top of the reader's right-click menu, built from
/// what `ccwiki.js` reports under the pointer. The menu is AppKit; what goes
/// into it, and in which order, is not.
struct ReaderContextMenuTests {

    private static let game = "\\begin{algorithm}\n\\caption{$\\Game(\\secpar)$}\n\\end{algorithm}"
    private static let gameExpanded = "\\begin{algorithm}\n\\caption{$\\mathsf{G}(\\lambda)$}\n\\end{algorithm}"

    @Test("a formula in prose offers its LaTeX and nothing else")
    func formulaOnly() {
        let target = ReaderContextTarget(tex: "\\calA^{F_k(\\cdot)}")
        #expect(target.copyItems.map(\.title) == ["Copy LaTeX"])
        #expect(target.copyItems.map(\.text) == ["\\calA^{F_k(\\cdot)}"])
        #expect(target.copyItems.map(\.isAlternate) == [false])
    }

    @Test("a formula in an algorithm offers the formula, then the algorithm and its Option-key alternate")
    func formulaInAlgorithm() {
        let target = ReaderContextTarget(
            tex: "\\Game(\\secpar)", algorithm: Self.game, algorithmExpanded: Self.gameExpanded)
        #expect(target.copyItems.map(\.title) == [
            "Copy LaTeX",
            "Copy Algorithm as LaTeX",
            "Copy Algorithm as LaTeX (No Macros)",
        ])
        #expect(target.copyItems.map(\.text) == ["\\Game(\\secpar)", Self.game, Self.gameExpanded])
        // The alternate has to come straight after the item it stands in for.
        #expect(target.copyItems.map(\.isAlternate) == [false, false, true])
    }

    @Test("an algorithm with no expanded form has no alternate")
    func algorithmWithoutExpansion() {
        let target = ReaderContextTarget(algorithm: Self.game)
        #expect(target.copyItems.map(\.title) == ["Copy Algorithm as LaTeX"])
        #expect(target.copyItems.map(\.isAlternate) == [false])
    }

    @Test("an expanded form on its own offers nothing: it is only ever an alternate")
    func expansionWithoutAlgorithm() {
        let target = ReaderContextTarget(algorithmExpanded: Self.gameExpanded)
        #expect(target.copyItems.isEmpty)
    }

    @Test("the bridge message is read field by field")
    func readsMessage() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "tex": "\\secpar",
            "algorithm": Self.game,
            "algorithmExpanded": Self.gameExpanded,
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target == ReaderContextTarget(
            tex: "\\secpar", algorithm: Self.game, algorithmExpanded: Self.gameExpanded))
    }

    @Test("null, empty and non-string fields are absent, so a click on prose adds nothing")
    func absentFields() {
        let message: [String: Any] = [
            "type": "contextTarget",
            "tex": NSNull(),
            "algorithm": "",
            "algorithmExpanded": 3,
        ]
        let target = ReaderContextTarget(message: message)
        #expect(target == ReaderContextTarget())
        #expect(target.copyItems.isEmpty)
    }
}
