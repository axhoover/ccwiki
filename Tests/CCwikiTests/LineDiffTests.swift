import Testing
@testable import CCwiki

/// Line hunks between two texts (plans/corrections.md §6.1, §12.1). Hunks
/// are 0-based and half-open, and a line is what git counts.
struct LineDiffTests {

    /// Ten numbered lines, each ending in a newline.
    static func numbered(_ change: (inout [String]) -> Void = { _ in }) -> String {
        var lines = (1...10).map { "line \($0)" }
        change(&lines)
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("identical texts give no hunks, with and without a final newline")
    func identical() {
        #expect(LineDiff.hunks(old: "", new: "").isEmpty)
        #expect(LineDiff.hunks(old: "a\nb\nc\n", new: "a\nb\nc\n").isEmpty)
        #expect(LineDiff.hunks(old: "a\nb\nc", new: "a\nb\nc").isEmpty)
        #expect(LineDiff.hunks(old: Self.numbered(), new: Self.numbered()).isEmpty)
    }

    @Test("one changed line is one hunk, the same line on both sides")
    func oneChangedLine() {
        let expected = [LineHunk(old: 1..<2, new: 1..<2)]
        #expect(LineDiff.hunks(old: "a\nb\nc\n", new: "a\nB\nc\n") == expected)
        // Without a final newline the last line still counts as a line.
        #expect(LineDiff.hunks(old: "a\nb\nc", new: "a\nB\nc") == expected)
    }

    @Test("an insertion at the end, a deletion, a new file and a deleted one")
    func insertionsAndDeletions() {
        #expect(LineDiff.hunks(old: "a\nb\n", new: "a\nb\nc\n") == [LineHunk(old: 2..<2, new: 2..<3)])
        #expect(LineDiff.hunks(old: "a\nb\nc\n", new: "a\nc\n") == [LineHunk(old: 1..<2, new: 1..<1)])
        #expect(LineDiff.hunks(old: "", new: "a\nb\n") == [LineHunk(old: 0..<0, new: 0..<2)])
        #expect(LineDiff.hunks(old: "a\nb\n", new: "") == [LineHunk(old: 0..<2, new: 0..<0)])
    }

    @Test("a final newline gained or lost changes the last line, as git shows it")
    func finalNewline() {
        #expect(LineDiff.hunks(old: "a\nb", new: "a\nb\n") == [LineHunk(old: 1..<2, new: 1..<2)])
        #expect(LineDiff.hunks(old: "no newline", new: "no newline\n") == [LineHunk(old: 0..<1, new: 0..<1)])
    }

    @Test("two distant changes give two hunks")
    func distantChanges() {
        let new = Self.numbered {
            $0[1] = "changed 2"
            $0[8] = "changed 9"
        }
        #expect(LineDiff.hunks(old: Self.numbered(), new: new) == [
            LineHunk(old: 1..<2, new: 1..<2),
            LineHunk(old: 8..<9, new: 8..<9),
        ])
    }

    @Test("adjacent changes merge into one hunk")
    func adjacentChanges() {
        let new = Self.numbered {
            $0[3] = "changed 4"
            $0[4] = "changed 5"
            $0.insert("inserted after 5", at: 5)
        }
        #expect(LineDiff.hunks(old: Self.numbered(), new: new) == [LineHunk(old: 3..<5, new: 3..<6)])
    }

    @Test("lines compare byte for byte: a change of normal form is a change")
    func byteExact() {
        #expect(LineDiff.hunks(old: "caf\u{E9}\n", new: "cafe\u{301}\n") == [LineHunk(old: 0..<1, new: 0..<1)])
    }

    @Test("a line is split at each line feed, which it keeps; a CRLF line is one line")
    func lines() {
        #expect(LineDiff.lines(of: "").isEmpty)
        #expect(LineDiff.lines(of: "\n").map(String.init) == ["\n"])
        #expect(LineDiff.lines(of: "a\nb").map(String.init) == ["a\n", "b"])
        #expect(LineDiff.lines(of: "a\r\nb\r\n").count == 2)
        #expect(LineDiff.hunks(old: "a\r\nb\r\n", new: "a\r\nB\r\n") == [LineHunk(old: 1..<2, new: 1..<2)])
    }
}
