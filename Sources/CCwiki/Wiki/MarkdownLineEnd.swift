import Foundation

/// Where a markdown line ends, found on the text's UTF-8 bytes.
///
/// markdown-it ends a line at `\n`, `\r\n` or a lone `\r`, which is what
/// `Character.isMarkdownLineEnding` tests. Both bytes are ASCII, so no other
/// character's encoding holds either, and Unicode's grapheme rules (UAX #29,
/// GB3–GB5) break before and after each of them everywhere but inside
/// `\r\n`, which is one line end here too. So every index found here is the
/// Character boundary a walk over Characters finds, for a byte compare
/// instead of a grapheme step. The load walks every page body this way
/// several times (plans/efficiency.md, L1).
enum MarkdownLineEnd {

    /// The end of the line that starts at `start`, and where the next line
    /// starts: past the `\r\n` or the single byte that ends this one. Both
    /// are `endIndex` when no line end follows.
    static func next(
        in text: String, from start: String.Index
    ) -> (end: String.Index, next: String.Index) {
        let utf8 = text.utf8
        // `\n` and `\r`.
        guard let end = utf8[start...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D })
        else { return (text.endIndex, text.endIndex) }
        let after = utf8.index(after: end)
        if utf8[end] == 0x0D, after < utf8.endIndex, utf8[after] == 0x0A {
            return (end, utf8.index(after: after))
        }
        return (end, after)
    }

    /// Where the line holding `index` starts: just past the last line end
    /// before it, or `startIndex` when there is none.
    static func start(in text: String, before index: String.Index) -> String.Index {
        let utf8 = text.utf8
        guard let end = utf8[..<index].lastIndex(where: { $0 == 0x0A || $0 == 0x0D })
        else { return text.startIndex }
        return utf8.index(after: end)
    }
}
