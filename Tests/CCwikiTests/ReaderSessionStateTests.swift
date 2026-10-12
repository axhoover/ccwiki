import Foundation
import Testing
@testable import CCwiki

/// A reader window's saved state is read back whole or not at all: a window
/// restored from bytes it cannot trust starts as a new one rather than with
/// half a history (plans/reader-comforts.md §1.3).
struct ReaderSessionStateTests {

    private typealias Location = AppModel.Location

    private static func sample() -> ReaderSessionState {
        var history = NavigationHistory()
        history.visit(.page(path: "Primitives/pseudorandom-function.md", anchor: nil))
        history.visit(.page(path: "Assumptions/learning-with-errors.md", anchor: "syntax"))
        history.visit(.folder(slug: "Primitives"))
        _ = history.goBack()
        return ReaderSessionState(
            history: history,
            inspectorTab: AppModel.InspectorTab.relations.rawValue,
            showsInspector: false,
            expandedFolders: ["Assumptions", "Primitives"])
    }

    @Test("a saved state reads back as it was")
    func roundTrip() throws {
        let state = Self.sample()
        #expect(state.version == ReaderSessionState.currentVersion)
        let data = try #require(state.encoded())
        #expect(ReaderSessionState.decoded(from: data) == state)
    }

    @Test("the same state always saves the same bytes")
    func stableEncoding() throws {
        let first = try #require(Self.sample().encoded())
        let second = try #require(Self.sample().encoded())
        #expect(first == second)
    }

    @Test("nothing saved is nothing restored")
    func nilData() {
        #expect(ReaderSessionState.decoded(from: nil) == nil)
        #expect(ReaderSessionState.decoded(from: Data()) == nil)
    }

    @Test("bytes that are not a saved state are ignored")
    func garbage() {
        #expect(ReaderSessionState.decoded(from: Data("not json".utf8)) == nil)
        #expect(ReaderSessionState.decoded(from: Data("[1, 2, 3]".utf8)) == nil)
        #expect(ReaderSessionState.decoded(from: Data(#"{"version": "1"}"#.utf8)) == nil)
    }

    @Test("a state missing a part, or naming a place this build does not know, is ignored")
    func incomplete() throws {
        let data = try #require(Self.sample().encoded())

        var missing = try Self.object(from: data)
        missing.removeValue(forKey: "expandedFolders")
        let missingData = try JSONSerialization.data(withJSONObject: missing)
        #expect(ReaderSessionState.decoded(from: missingData) == nil)

        var unknownPlace = try Self.object(from: data)
        var history = try #require(unknownPlace["history"] as? [String: Any])
        history["current"] = ["somewhereElse": [String: Any]()]
        unknownPlace["history"] = history
        let unknownData = try JSONSerialization.data(withJSONObject: unknownPlace)
        #expect(ReaderSessionState.decoded(from: unknownData) == nil)
    }

    private static func object(from data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [String: Any])
    }

    @Test("a state from another version is ignored, whatever shape it has")
    func otherVersions() {
        var future = Self.sample()
        future.version = ReaderSessionState.currentVersion + 1
        #expect(ReaderSessionState.decoded(from: future.encoded()) == nil,
                "a newer build's state, even one this build could read")

        var past = Self.sample()
        past.version = 0
        #expect(ReaderSessionState.decoded(from: past.encoded()) == nil)

        let reshaped = Data(#"{"version": 2, "tabs": [{"page": "A.md"}]}"#.utf8)
        #expect(ReaderSessionState.decoded(from: reshaped) == nil)
    }
}
