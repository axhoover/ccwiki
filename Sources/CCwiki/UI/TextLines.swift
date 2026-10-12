import Foundation

/// Lines ↔ UTF-16 offsets in a text, for the editor's `NSTextView`
/// (plans/corrections.md §7.3), which selects and reports positions in
/// UTF-16 code units, while a correction names 1-based lines. Pure.
///
/// A line ends at a `"\n"`, as git and the line numbers in a correction
/// count them; a `"\r"` before it belongs to the line break, not the line.
/// Like any editor, the text after the last `"\n"` is a line too, empty
/// when the text ends with one: that is where the cursor sits at the end.
enum TextLines {

    /// The UTF-16 range of `lines` in `text`: from the start of the first
    /// to the end of the last, its line break left out, so the selection
    /// does not reach into the next line. A range that runs past the end
    /// stops at the last line. Nil when the first line is not in the text.
    static func utf16Range(of lines: LineRange, in text: String) -> NSRange? {
        guard lines.first >= 1, lines.last >= lines.first else { return nil }
        var line = 1
        var offset = 0
        var start: Int? = lines.first == 1 ? 0 : nil
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == newline {
                if line == lines.last, let start {
                    let end = previous == carriageReturn ? offset - 1 : offset
                    return NSRange(location: start, length: max(end - start, 0))
                }
                line += 1
                if line == lines.first { start = offset + 1 }
            }
            previous = unit
            offset += 1
        }
        guard let start else { return nil }
        return NSRange(location: start, length: offset - start)
    }

    /// The 1-based line that UTF-16 `offset` falls on. An offset at a line
    /// break is on the line it ends; one past the end of the text is on the
    /// last line.
    static func line(atUTF16Offset offset: Int, in text: String) -> Int {
        var line = 1
        for unit in text.utf16.prefix(max(offset, 0)) where unit == newline {
            line += 1
        }
        return line
    }

    /// Where UTF-16 `offset` is, as the editor's status line says it: the
    /// 1-based line, as `line(atUTF16Offset:in:)`, and the 1-based column,
    /// counted in characters as a reader sees them, so an emoji or an
    /// accented letter is one column. An offset past the end is at the end.
    static func position(atUTF16Offset offset: Int, in text: String) -> (line: Int, column: Int) {
        let utf16 = text.utf16
        let end = min(max(offset, 0), utf16.count)
        var line = 1
        var lineStart = 0
        var index = 0
        for unit in utf16.prefix(end) {
            index += 1
            if unit == newline {
                line += 1
                lineStart = index
            }
        }
        let start = String.Index(utf16Offset: lineStart, in: text)
        let caret = String.Index(utf16Offset: end, in: text)
        return (line, text[start..<caret].count + 1)
    }

    /// `"\n"` and `"\r"` as UTF-16 code units.
    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D
}
