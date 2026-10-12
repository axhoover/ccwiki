import Foundation

/// Where a line the reader rendered lives in the file (plans/corrections.md
/// §3.4).
///
/// The rendered Markdown differs from the file in exactly two ways: the
/// frontmatter is missing at the top, and on a reduction or barrier page a
/// run of two or three lines, the relation-meta line, is added after the H1
/// (`RelationMeta.insertUnderH1`, which inserts whole lines and changes no
/// other). So a rendered line maps to the file by an offset, around that run.
///
/// Lines are counted as markdown-it counts them, which is what stamped the
/// rendered ranges: a line break is `\n`, `\r\n` or a lone `\r`.
struct SourceLineMap: Sendable, Equatable {
    /// File lines before the body: the frontmatter and both of its fences.
    let bodyOffset: Int
    /// Rendered lines the renderer added (the relation-meta splice). Empty
    /// when none.
    let inserted: Range<Int>

    /// `bodyOffset` counts the line breaks before
    /// `Frontmatter.parse(fileText).bodyStart`. `inserted` aligns the body's
    /// lines with the rendered ones: it starts at the first line where they
    /// differ, and is as long as the rendered text is longer.
    ///
    /// Beside blank lines the alignment can start a line late (the splice
    /// begins with a blank line, and so may the body there). That moves no
    /// line that is not blank: the only lines that could trade places are
    /// identical.
    init(fileText: String, renderedMarkdown: String) {
        let frontmatter = Frontmatter.parse(fileText)
        let body = Self.lines(of: fileText[frontmatter.bodyStart...])
        let rendered = Self.lines(of: Substring(renderedMarkdown))
        bodyOffset = Self.lines(of: fileText[..<frontmatter.bodyStart]).count - 1

        let added = rendered.count - body.count
        guard added > 0 else {
            inserted = 0..<0
            return
        }
        var first = 0
        while first < body.count, body[first] == rendered[first] { first += 1 }
        inserted = first..<(first + added)
    }

    enum Location: Sendable, Equatable {
        /// 1-based, in the file.
        case body(LineRange)
        /// The selection was the generated relation-meta line, which comes
        /// from these frontmatter lines.
        case frontmatter(LineRange)
    }

    /// A 0-based, half-open rendered range → where it lives in the file.
    ///
    /// A range entirely inside the splice is the relation-meta line, made
    /// from the frontmatter's fields: the frontmatter between its fences. A
    /// range that only partly overlaps the splice keeps the part outside
    /// it. Nil for an empty or negative range, or a splice with no
    /// frontmatter to come from.
    func location(ofRendered range: Range<Int>) -> Location? {
        guard range.lowerBound >= 0, !range.isEmpty else { return nil }
        var first = range.lowerBound
        var last = range.upperBound - 1
        if !inserted.isEmpty {
            if inserted.contains(first), inserted.contains(last) {
                guard bodyOffset >= 3 else { return nil }
                return .frontmatter(LineRange(first: 2, last: bodyOffset - 1))
            }
            if inserted.contains(first) { first = inserted.upperBound }
            if inserted.contains(last) { last = inserted.lowerBound - 1 }
        }
        return .body(LineRange(first: fileLine(forRendered: first), last: fileLine(forRendered: last)))
    }

    /// A 1-based file line → the rendered line, for the preview to follow
    /// the cursor. Nil inside the frontmatter.
    func renderedLine(forFileLine line: Int) -> Int? {
        guard line > bodyOffset else { return nil }
        let bodyLine = line - bodyOffset - 1
        return bodyLine < inserted.lowerBound || inserted.isEmpty ? bodyLine : bodyLine + inserted.count
    }

    /// A rendered line outside the splice → its 1-based file line.
    private func fileLine(forRendered line: Int) -> Int {
        let shift = !inserted.isEmpty && line >= inserted.upperBound ? inserted.count : 0
        return bodyOffset + line - shift + 1
    }

    /// `text` split into lines as markdown-it splits it. A text that ends in
    /// a line break ends with an empty line, as markdown-it's lines do.
    static func lines(of text: Substring) -> [Substring] {
        // By scalar, not by Character: "\r\n" is one Character, and one
        // break. Every index this cuts at is a Character boundary.
        let scalars = text.unicodeScalars
        var lines: [Substring] = []
        var start = scalars.startIndex
        var position = scalars.startIndex
        while position < scalars.endIndex {
            let scalar = scalars[position]
            var next = scalars.index(after: position)
            guard scalar == "\n" || scalar == "\r" else {
                position = next
                continue
            }
            if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                next = scalars.index(after: next)
            }
            lines.append(text[start..<position])
            start = next
            position = next
        }
        lines.append(text[start...])
        return lines
    }
}
