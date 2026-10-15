import Foundation

/// Whether a quote a curation entry cites is still on its page
/// (plans/relations-followups.md §2.2).
///
/// **One rule, implemented twice.** The reference engine's `locate_quote`
/// (`scripts/derivations_reference.py`) applies it for `--check-quotes` and
/// the review document, and also reports the line; this answers found or not
/// found, for the corpus test and for the app, which marks a quote that has
/// left its page. Both are held to the same cases,
/// `Tests/CCwikiTests/Fixtures/quote-cases.json`.
///
/// **The rule.** CRLF and a lone CR become LF, and page and quote are both
/// normalised to NFC; every run of spaces, tabs and line feeds becomes one
/// space, in both; then the quote must be a case-sensitive substring of the
/// section. A quote that collapses to nothing or to one space is never found.
/// The section is the body under the first ATX heading whose text equals
/// `section`, up to the next heading of the same or a higher level; `nil` is
/// the whole file, frontmatter included. Lines in the frontmatter and in
/// fenced code blocks are not headings.
///
/// **Scalars, never `Character`s.** Everything here compares Unicode scalars,
/// as Python compares code points. `String`'s own `==` and `contains` compare
/// grapheme clusters under canonical equivalence: they would not find "ax" in
/// "ax́b", where the reference does, and the two matchers would part on
/// accented and combining text.
enum CurationQuote {

    static func contains(_ quote: String, section: String?, in page: String) -> Bool {
        let lines = Self.lines(page)
        var body = lines[...]
        if let section {
            let wanted = nfc(Array(section.unicodeScalars))
            let headings = Self.headings(lines)
            guard let found = headings.firstIndex(where: { $0.text == wanted }) else { return false }
            let heading = headings[found]
            let end = headings[(found + 1)...].first { $0.level <= heading.level }?.line ?? lines.count
            body = lines[(heading.line + 1)..<end]
        }
        let needle = collapsed(joined(Self.lines(quote)))
        guard !needle.isEmpty, needle != [" "] else { return false }
        return occurs(needle, in: collapsed(joined(body)))
    }

    // MARK: Lines

    /// The text's lines, a CRLF or a lone CR read as a line break as an LF
    /// is, each in NFC. NFC never composes across a line break, so a line at
    /// a time is the whole text's NFC.
    private static func lines(_ text: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var line: [Unicode.Scalar] = []
        var afterCR = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                lines.append(nfc(line))
                line = []
                afterCR = true
            case "\n":
                // The LF of a CRLF ends nothing: its CR already did.
                if !afterCR {
                    lines.append(nfc(line))
                    line = []
                }
                afterCR = false
            default:
                line.append(scalar)
                afterCR = false
            }
        }
        lines.append(nfc(line))
        return lines
    }

    private static func nfc(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// The lines with an LF between each two, as one run of scalars.
    private static func joined(_ lines: ArraySlice<[Unicode.Scalar]>) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for (position, line) in lines.enumerated() {
            if position > 0 { out.append("\n") }
            out.append(contentsOf: line)
        }
        return out
    }

    private static func joined(_ lines: [[Unicode.Scalar]]) -> [Unicode.Scalar] {
        joined(lines[...])
    }

    /// Every run of space, tab and LF as one space.
    private static func collapsed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var inRun = false
        for scalar in scalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return out
    }

    /// Is `needle` a contiguous run of `haystack`, scalar for scalar?
    private static func occurs(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    // MARK: Headings

    private struct Heading {
        /// Index into the lines.
        let line: Int
        /// How many `#`s.
        let level: Int
        let text: [Unicode.Scalar]
    }

    /// Every ATX heading: `#` to `######` at the start of a line, then a
    /// space. Lines in the frontmatter (a first line `---` up to the next
    /// line `---`, trailing spaces and tabs ignored) and in fenced code
    /// blocks are not headings. A fence opens on at most three spaces and
    /// three or more backticks or tildes, and closes on a line holding only
    /// at least as many of its own character, or at the end of the file.
    private static func headings(_ lines: [[Unicode.Scalar]]) -> [Heading] {
        let rule: [Unicode.Scalar] = ["-", "-", "-"]
        var start = 0
        if let first = lines.first, trimmedTrailing(first) == rule {
            for index in 1..<lines.count where trimmedTrailing(lines[index]) == rule {
                start = index + 1
                break
            }
        }

        var found: [Heading] = []
        var fence: Fence?
        for index in start..<lines.count {
            let line = lines[index]
            if let open = fence {
                if let close = Self.fence(line, closing: true),
                   close.character == open.character, close.count >= open.count {
                    fence = nil
                }
                continue
            }
            if let open = Self.fence(line, closing: false) {
                fence = open
                continue
            }
            if let heading = Self.heading(line, at: index) { found.append(heading) }
        }
        return found
    }

    private struct Fence {
        let character: Unicode.Scalar
        let count: Int
    }

    /// The run of backticks or tildes a fence line starts with, after at
    /// most three spaces, when it is three or more long. A closing fence
    /// must have nothing after it but spaces and tabs.
    private static func fence(_ line: [Unicode.Scalar], closing: Bool) -> Fence? {
        var index = 0
        while index < 3, index < line.count, line[index] == " " { index += 1 }
        guard index < line.count, line[index] == "`" || line[index] == "~" else { return nil }
        let character = line[index]
        var count = 0
        while index < line.count, line[index] == character {
            count += 1
            index += 1
        }
        guard count >= 3 else { return nil }
        if closing, !line[index...].allSatisfy({ $0 == " " || $0 == "\t" }) { return nil }
        return Fence(character: character, count: count)
    }

    /// The heading on this line, if it is one. Its text is trimmed of spaces
    /// and tabs, without a closing run of `#`s that follows a space or a tab
    /// or stands alone.
    private static func heading(_ line: [Unicode.Scalar], at index: Int) -> Heading? {
        var level = 0
        while level < line.count, line[level] == "#" { level += 1 }
        guard (1...6).contains(level), level < line.count, line[level] == " " else { return nil }
        var text = trimmed(Array(line[(level + 1)...]))
        var hashes = text.count
        while hashes > 0, text[hashes - 1] == "#" { hashes -= 1 }
        if hashes < text.count {
            if hashes == 0 {
                text = []
            } else if text[hashes - 1] == " " || text[hashes - 1] == "\t" {
                text = Array(text[..<(hashes - 1)])
            }
        }
        return Heading(line: index, level: level, text: trimmed(text))
    }

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let isBlank: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        guard let first = scalars.firstIndex(where: { !isBlank($0) }),
              let last = scalars.lastIndex(where: { !isBlank($0) })
        else { return [] }
        return Array(scalars[first...last])
    }

    private static func trimmedTrailing(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let last = scalars.lastIndex(where: { $0 != " " && $0 != "\t" }) else { return [] }
        return Array(scalars[...last])
    }
}
