import Foundation

/// Line hunks between two texts, built on `CollectionDifference`, adjacent
/// ones merged (plans/corrections.md §6.1). Pure.
///
/// A line is what git counts: the text up to and including a `"\n"`, or a
/// final run without one. So the empty text has no lines, `"a"` and `"a\n"`
/// have one each, and the two differ, as `git diff` says they do ("No
/// newline at end of file"). Lines compare byte for byte, not by Unicode
/// equivalence: a page re-saved in another normal form has changed, and the
/// review must show it.
enum LineDiff {

    /// The most lines, removed and added together, that a difference must
    /// change before it is no longer computed line by line. At this size
    /// the stdlib's rows take about 64 MB. The largest regeneration of
    /// `relations.json` in the wiki's history, at `ab81f02`, must change at
    /// least 4,884 of its lines, and is one hunk.
    static let largestDifference = 4_000

    /// The changed runs of lines, in order: 0-based and half-open on each
    /// side. Identical texts give none. Changes with no unchanged line
    /// between them are one hunk.
    static func hunks(old: String, new: String) -> [LineHunk] {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)

        // Each distinct line becomes a small integer, so the difference
        // compares integers rather than strings: `relations.json` is 11,432
        // lines.
        var ids: [[UInt8]: Int] = [:]
        func id(_ line: Substring) -> Int {
            let bytes = Array(line.utf8)
            if let known = ids[bytes] { return known }
            let next = ids.count
            ids[bytes] = next
            return next
        }
        let a = oldLines.map(id)
        let b = newLines.map(id)

        // Most reviews change a line or two of a long file: leave the common
        // ends out of the difference, which is quadratic in the worst case.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }

        // The whole middle as one hunk. When one side of it is empty, that
        // is exactly the difference: a file added or deleted, or a run of
        // lines inserted or removed.
        let middle = [LineHunk(old: prefix..<(a.count - suffix), new: prefix..<(b.count - suffix))]
        if oldMiddle.isEmpty || newMiddle.isEmpty { return middle }

        // The stdlib's Myers keeps one row per step of the difference, so
        // its memory grows as the square of the lines that change: half a
        // gigabyte for all of `relations.json`. A line one side holds more
        // often than the other must change, however the two align; past
        // `largestDifference` of those, the middle is one hunk. No one reads
        // such a diff line by line, and the review collapses it anyway.
        var unmatched = [Int](repeating: 0, count: ids.count)
        for line in oldMiddle { unmatched[line] += 1 }
        var common = 0
        for line in newMiddle where unmatched[line] > 0 {
            unmatched[line] -= 1
            common += 1
        }
        if oldMiddle.count + newMiddle.count - 2 * common > largestDifference { return middle }

        var removed = [Bool](repeating: false, count: oldMiddle.count)
        var inserted = [Bool](repeating: false, count: newMiddle.count)
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }

        // Walk both sides together. Lines neither removed nor inserted pair
        // up in order; everything between two such pairs is one hunk.
        var hunks: [LineHunk] = []
        var i = 0
        var j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            let oldChanged = i < oldMiddle.count && removed[i]
            let newChanged = j < newMiddle.count && inserted[j]
            if !oldChanged, !newChanged {
                i += 1
                j += 1
                continue
            }
            let start = (old: i, new: j)
            while (i < oldMiddle.count && removed[i]) || (j < newMiddle.count && inserted[j]) {
                if i < oldMiddle.count, removed[i] { i += 1 } else { j += 1 }
            }
            hunks.append(LineHunk(
                old: (prefix + start.old)..<(prefix + i),
                new: (prefix + start.new)..<(prefix + j)))
        }
        return hunks
    }

    /// The lines of `text` as the hunks count them, each with its `"\n"`.
    /// Split on the byte, so a `"\r\n"`, which Swift reads as one character,
    /// still ends a line.
    static func lines(of text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.utf8.startIndex
        while index < text.utf8.endIndex {
            let next = text.utf8.index(after: index)
            if text.utf8[index] == UInt8(ascii: "\n") {
                // The index after a line feed is always a character boundary.
                result.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }
}
