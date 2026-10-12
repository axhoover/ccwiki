import Foundation
import Testing
@testable import CCwiki

/// Lines ↔ UTF-16 offsets for the editor's text view (plans/corrections.md
/// §7.3, §12.1): right with emoji and combining marks, which take more than
/// one UTF-16 unit, and at the edges of the text.
struct TextLinesTests {

    static func lines(_ first: Int, _ last: Int) -> LineRange {
        LineRange(first: first, last: last)
    }

    @Test("a range of lines runs from the start of the first to the end of the last")
    func plain() {
        let text = "a\nbb\nccc"
        #expect(TextLines.utf16Range(of: Self.lines(1, 1), in: text) == NSRange(location: 0, length: 1))
        #expect(TextLines.utf16Range(of: Self.lines(2, 2), in: text) == NSRange(location: 2, length: 2))
        #expect(TextLines.utf16Range(of: Self.lines(2, 3), in: text) == NSRange(location: 2, length: 6))
    }

    @Test("UTF-16 offsets are right with emoji and combining marks")
    func wideCharacters() {
        // "e" + U+0301 is one character in two units; 👍 is two units.
        let text = "e\u{301}👍 caf\u{E9}\nx👍y\n🇫🇷 \u{E9}"
        let ns = text as NSString
        func find(_ needle: String) -> NSRange { ns.range(of: needle, options: .literal) }
        #expect(TextLines.utf16Range(of: Self.lines(1, 1), in: text) == NSRange(location: 0, length: 9))
        #expect(TextLines.utf16Range(of: Self.lines(2, 2), in: text) == find("x👍y"))
        #expect(TextLines.utf16Range(of: Self.lines(3, 3), in: text) == find("🇫🇷 \u{E9}"))

        let second = find("x👍y").location
        #expect(second == 10)
        #expect(TextLines.line(atUTF16Offset: second, in: text) == 2)
        #expect(TextLines.line(atUTF16Offset: second + 2, in: text) == 2)
        // Inside the first line's emoji, and at its line break.
        #expect(TextLines.line(atUTF16Offset: 3, in: text) == 1)
        #expect(TextLines.line(atUTF16Offset: second - 1, in: text) == 1)
        #expect(TextLines.line(atUTF16Offset: ns.length, in: text) == 3)
    }

    @Test("every line's range starts on that line")
    func roundTrip() {
        let text = "---\ntitle: Café\n---\n# 👍 Pseudorandom function\n\nA $\\calA$ wins.\n"
        let count = text.components(separatedBy: "\n").count
        for line in 1...count {
            let range = TextLines.utf16Range(of: Self.lines(line, line), in: text)
            #expect(range.map { TextLines.line(atUTF16Offset: $0.location, in: text) } == line)
        }
    }

    @Test("a range past the end stops at the last line; one that starts past it is nil")
    func edges() {
        let text = "a\nb"
        #expect(TextLines.utf16Range(of: Self.lines(2, 9), in: text) == NSRange(location: 2, length: 1))
        #expect(TextLines.utf16Range(of: Self.lines(3, 3), in: text) == nil)
        #expect(TextLines.utf16Range(of: Self.lines(0, 1), in: text) == nil)
        #expect(TextLines.utf16Range(of: Self.lines(2, 1), in: text) == nil)
        #expect(TextLines.line(atUTF16Offset: -4, in: text) == 1)
        #expect(TextLines.line(atUTF16Offset: 99, in: text) == 2)
    }

    @Test("after a final newline the cursor is on an empty last line")
    func emptyLastLine() {
        let text = "a\n"
        #expect(TextLines.utf16Range(of: Self.lines(2, 2), in: text) == NSRange(location: 2, length: 0))
        #expect(TextLines.line(atUTF16Offset: 2, in: text) == 2)
        #expect(TextLines.utf16Range(of: Self.lines(1, 1), in: "") == NSRange(location: 0, length: 0))
    }

    @Test("the status line's column counts characters, so an emoji or an accent is one")
    func columns() {
        // "e" + U+0301 is one character in two units; 👍 is two units.
        let text = "e\u{301}👍x\nab"
        func position(_ offset: Int) -> [Int] {
            let found = TextLines.position(atUTF16Offset: offset, in: text)
            return [found.line, found.column]
        }
        #expect(position(0) == [1, 1])
        #expect(position(2) == [1, 2])
        #expect(position(4) == [1, 3])
        #expect(position(5) == [1, 4])
        // Past the line break: the start of the next line.
        #expect(position(6) == [2, 1])
        #expect(position(8) == [2, 3])
        // Out of range: the start, or the end.
        #expect(position(-3) == [1, 1])
        #expect(position(99) == [2, 3])
        // The line agrees with `line(atUTF16Offset:in:)` everywhere.
        for offset in 0...(text as NSString).length {
            #expect(TextLines.position(atUTF16Offset: offset, in: text).line
                == TextLines.line(atUTF16Offset: offset, in: text))
        }
    }

    @Test("a carriage return belongs to the line break, not the line")
    func crlf() {
        let text = "a\r\nb\r\n"
        #expect(TextLines.utf16Range(of: Self.lines(1, 1), in: text) == NSRange(location: 0, length: 1))
        #expect(TextLines.utf16Range(of: Self.lines(2, 2), in: text) == NSRange(location: 3, length: 1))
        #expect(TextLines.utf16Range(of: Self.lines(1, 2), in: text) == NSRange(location: 0, length: 4))
        #expect(TextLines.line(atUTF16Offset: 3, in: text) == 2)
    }
}
