import Foundation

/// ⇧⌘F: every place a string occurs, like grep. Literal, exhaustive and
/// unranked (plans/search-v2.md §6.1): pages in path order, each with the
/// lines the string is on, references included.
///
/// Smart case, as ripgrep's `--smart-case`: case matters only when the query
/// has a capital, so `ot` finds `not` and `OT` finds only `OT`. Searches the
/// markdown as written, TeX included, which is what makes it the way to find
/// every use of a macro such as `\classNP`.
///
/// The pages are split into lines once per library load; a query is then one
/// pass over them, fast enough to run on every keystroke off the main actor.
struct TextGrep: Sendable {

    struct Page: Sendable {
        let path: String
        let title: String
        let kind: PageKind
        let lines: [String]
    }

    struct Hit: Identifiable, Sendable {
        let path: String
        let title: String
        let kind: PageKind
        /// The first few matching lines, trimmed around the match, with `«` …
        /// `»` around each occurrence as `SearchHit.snippet` has.
        let excerpts: [String]
        /// Occurrences on the page, all of them.
        let count: Int
        /// Lines with at least one occurrence.
        let lineCount: Int

        var id: String { path }
    }

    let pages: [Page]

    static let empty = TextGrep(pages: [WikiPage]())
    /// A one-character query matches nearly every line of the wiki.
    static let minimumLength = 2

    init(pages: [WikiPage]) {
        self.pages = pages.sorted { $0.path < $1.path }.map { page in
            Page(
                path: page.path, title: page.displayTitle, kind: page.kind,
                lines: page.body.components(separatedBy: "\n"))
        }
    }

    static func options(for needle: String) -> String.CompareOptions {
        needle.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
    }

    func search(_ needle: String, excerptsPerPage: Int = 3) -> [Hit] {
        guard needle.trimmingCharacters(in: .whitespaces).count >= Self.minimumLength,
              !needle.contains("\n")
        else { return [] }
        let options = Self.options(for: needle)

        var hits: [Hit] = []
        for page in pages {
            var count = 0
            var lineCount = 0
            var excerpts: [String] = []
            for line in page.lines {
                let occurrences = Self.ranges(of: needle, in: line, options: options)
                guard let first = occurrences.first else { continue }
                count += occurrences.count
                lineCount += 1
                if excerpts.count < excerptsPerPage {
                    excerpts.append(Self.excerpt(line, around: first, marking: occurrences))
                }
            }
            if count > 0 {
                hits.append(Hit(
                    path: page.path, title: page.title, kind: page.kind,
                    excerpts: excerpts, count: count, lineCount: lineCount))
            }
        }
        return hits
    }

    /// Every non-overlapping occurrence, in order.
    static func ranges(
        of needle: String, in line: String, options: String.CompareOptions
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = line.startIndex
        while start < line.endIndex,
              let range = line.range(of: needle, options: options, range: start..<line.endIndex) {
            result.append(range)
            start = range.upperBound
        }
        return result
    }

    /// The line cut to a window around its first match, occurrences marked.
    /// Markdown paragraphs are single lines, often a thousand characters, so
    /// the whole line would bury the match.
    static func excerpt(
        _ line: String, around first: Range<String.Index>, marking occurrences: [Range<String.Index>],
        before: Int = 60, after: Int = 160
    ) -> String {
        let start = line.index(first.lowerBound, offsetBy: -before, limitedBy: line.startIndex)
            ?? line.startIndex
        let end = line.index(first.upperBound, offsetBy: after, limitedBy: line.endIndex)
            ?? line.endIndex

        var text = start > line.startIndex ? "…" : ""
        var cursor = start
        for range in occurrences
        where range.lowerBound >= start && range.upperBound <= end {
            text += clean(line[cursor..<range.lowerBound])
            text += "«" + clean(line[range]) + "»"
            cursor = range.upperBound
        }
        text += clean(line[cursor..<end])
        if end < line.endIndex { text += "…" }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The markers are the only markup the row understands, so the text
    /// must not carry its own.
    private static func clean(_ text: Substring) -> String {
        String(text).replacingOccurrences(of: "«", with: "\"")
            .replacingOccurrences(of: "»", with: "\"")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
