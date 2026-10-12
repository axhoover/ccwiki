import Foundation
import Testing
@testable import CCwiki

/// What `ccwiki.js` reports about a selection (plans/corrections.md §3.3):
/// `CCwiki.selectionSource()`'s JSON, and the `selection` of the
/// `contextTarget` message, which arrives with a JavaScript `null` as
/// `NSNull`.
struct ReaderSelectionTests {

    // Computed: a dictionary of `Any` is not Sendable, so it cannot be a
    // stored static.
    private static var heading: [String: Any] { ["id": "security", "text": "Security", "level": 2] }

    private static var message: [String: Any] { [
        "start": 41,
        "end": 44,
        "text": "every efficient $\\calA$",
        "heading": heading,
        "path": "Primitives/pseudorandom-function.md",
        "revision": "ab81f02",
    ] }

    private static let expected = ReaderSelection(
        renderedLines: 41..<44, text: "every efficient $\\calA$",
        heading: CorrectionTarget.Section(id: "security", title: "Security", level: 2),
        path: "Primitives/pseudorandom-function.md", revision: "ab81f02")

    @Test("a full message decodes, and so does the same as JSON")
    func fullMessage() throws {
        let selection = try #require(ReaderSelection(message: Self.message))
        #expect(selection == Self.expected)
        #expect(selection.isPassage)

        let data = try JSONSerialization.data(withJSONObject: Self.message)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(ReaderSelection(json: json) == Self.expected)
    }

    @Test("a null text is a pointer, not a passage")
    func pointer() throws {
        var message = Self.message
        message["text"] = NSNull()
        let selection = try #require(ReaderSelection(message: message))
        #expect(selection.text == nil)
        #expect(!selection.isPassage)
        #expect(selection.renderedLines == 41..<44)
        #expect(selection.heading?.id == "security")

        let json = #"{"start":3,"end":4,"text":null,"heading":null,"path":"x.md","revision":null}"#
        let fromJSON = try #require(ReaderSelection(json: json))
        #expect(!fromJSON.isPassage)
        #expect(fromJSON.heading == nil)
        #expect(fromJSON.revision == nil)
    }

    @Test("\"null\", malformed JSON and something that is not an object are nil")
    func nothing() {
        #expect(ReaderSelection(json: "null") == nil)
        #expect(ReaderSelection(json: "") == nil)
        #expect(ReaderSelection(json: "{\"start\": 1, ") == nil)
        #expect(ReaderSelection(json: "[1, 2]") == nil)
        #expect(ReaderSelection(json: "\"text\"") == nil)
    }

    @Test("an empty, a negative or a fractional range is nil, as is a missing path")
    func badRanges() {
        func with(_ key: String, _ value: Any) -> [String: Any] {
            var message = Self.message
            message[key] = value
            return message
        }
        #expect(ReaderSelection(message: with("end", 41)) == nil)
        #expect(ReaderSelection(message: with("end", 40)) == nil)
        #expect(ReaderSelection(message: with("start", -1)) == nil)
        #expect(ReaderSelection(message: with("start", 41.5)) == nil)
        #expect(ReaderSelection(message: with("start", NSNull())) == nil)
        #expect(ReaderSelection(message: with("path", "")) == nil)
        var noPath = Self.message
        noPath["path"] = nil
        #expect(ReaderSelection(message: noPath) == nil)
    }

    @Test("an NSNull or malformed heading is absent; the selection stands")
    func headings() throws {
        let headings: [Any] = [
            NSNull(),
            ["id": "", "text": "x", "level": 2] as [String: Any],
            ["id": "x", "text": "X", "level": 9] as [String: Any],
            "security",
        ]
        for heading in headings {
            var message = Self.message
            message["heading"] = heading
            let selection = try #require(ReaderSelection(message: message))
            #expect(selection.heading == nil)
            #expect(selection.renderedLines == 41..<44)
        }
    }

    @Test("numbers come over the bridge as NSNumber")
    func bridgedNumbers() {
        var message = Self.message
        message["start"] = NSNumber(value: 41.0)
        message["end"] = NSNumber(value: 44)
        #expect(ReaderSelection(message: message) == Self.expected)
    }

    @Test("the contextTarget message carries the selection last, and NSNull as none")
    func inContextTarget() {
        let withSelection: [String: Any] = [
            "type": "contextTarget", "tex": NSNull(), "algorithm": NSNull(),
            "algorithmExpanded": NSNull(), "link": NSNull(), "selection": Self.message,
        ]
        #expect(ReaderContextTarget(message: withSelection).selection == Self.expected)

        var without = withSelection
        without["selection"] = NSNull()
        #expect(ReaderContextTarget(message: without).selection == nil)
        without["selection"] = nil
        #expect(ReaderContextTarget(message: without) == ReaderContextTarget())
    }
}
