import Foundation

/// The changed words within a changed pair of lines, for the review's
/// Source mode (plans/corrections.md §6.3): emphasised by weight, so a
/// one-letter fix in a long paragraph is findable. Pure.
///
/// A token is a run of non-space, or a run of whitespace, so the segments
/// put back together are the two lines exactly. A formula is one token,
/// spaces and all: `$x + y$` against `$x + z$` is one formula changed, not
/// a stray `y` and `z`, and a word never splits a formula in half.
enum WordDiff {

    struct Segment: Sendable, Equatable {
        enum Kind: Sendable {
            /// In both lines.
            case same
            /// Only in the old line.
            case removed
            /// Only in the new line.
            case added
        }

        let kind: Kind
        let text: String
    }

    /// The two lines as one run of segments, in reading order: at each
    /// change the removed text comes before the added. The old line is the
    /// segments that are not `added`, the new line those not `removed`.
    /// Adjacent segments of one kind are merged.
    static func segments(old: String, new: String) -> [Segment] {
        let a = tokens(old)
        let b = tokens(new)

        var removed = [Bool](repeating: false, count: a.count)
        var inserted = [Bool](repeating: false, count: b.count)
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }

        var segments: [Segment] = []
        func emit(_ kind: Segment.Kind, _ text: String) {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1] = Segment(kind: kind, text: last.text + text)
            } else {
                segments.append(Segment(kind: kind, text: text))
            }
        }

        // Tokens neither removed nor inserted pair up in order; between two
        // such pairs, the old side's tokens go first.
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed[i] {
                emit(.removed, a[i])
                i += 1
            } else if j < b.count, inserted[j] {
                emit(.added, b[j])
                j += 1
            } else if i < a.count, j < b.count {
                emit(.same, b[j])
                i += 1
                j += 1
            } else {
                // Unreachable for a consistent difference; kept total, so
                // nothing is ever dropped.
                if i < a.count { emit(.removed, a[i]); i += 1 }
                if j < b.count { emit(.added, b[j]); j += 1 }
            }
        }
        return segments
    }

    /// `text` as tokens: runs of whitespace, and runs of anything else in
    /// which a formula, `$…$` or `$$…$$` with whatever spaces it holds, is
    /// never broken. A run of n dollars closes at the next run of exactly n,
    /// as the reader pairs them; one that closes nothing is a dollar sign. A
    /// backslash escapes the character after it, so `IND\$-CPA` opens no
    /// formula.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let start = i
            if text[i].isWhitespace {
                while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            } else {
                while i < text.endIndex, !text[i].isWhitespace {
                    if text[i] == "\\" {
                        i = text.index(after: i)
                        if i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
                    } else if text[i] == "$" {
                        let run = dollarRun(in: text, at: i)
                        i = closingRun(in: text, after: run.end, length: run.length) ?? run.end
                    } else {
                        i = text.index(after: i)
                    }
                }
            }
            tokens.append(String(text[start..<i]))
        }
        return tokens
    }

    /// The run of dollars that starts at `index`: where it ends, and how
    /// many it holds.
    private static func dollarRun(
        in text: String, at index: String.Index
    ) -> (end: String.Index, length: Int) {
        var end = index
        var length = 0
        while end < text.endIndex, text[end] == "$" {
            end = text.index(after: end)
            length += 1
        }
        return (end, length)
    }

    /// The end of the first run of exactly `length` dollars from `index`,
    /// skipping escaped characters: the end of the formula. Nil when none
    /// closes it.
    private static func closingRun(
        in text: String, after index: String.Index, length: Int
    ) -> String.Index? {
        var i = index
        while i < text.endIndex {
            if text[i] == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
            } else if text[i] == "$" {
                let run = dollarRun(in: text, at: i)
                if run.length == length { return run.end }
                i = run.end
            } else {
                i = text.index(after: i)
            }
        }
        return nil
    }
}
