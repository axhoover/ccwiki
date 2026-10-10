import Foundation

/// The prose on a link preview: a page's first paragraph, reduced to inline
/// markdown the card can render, and cut to a card's length.
///
/// Pure and tested (`LinkPreviewTests`), because every rule here exists to
/// keep something off a card that the reader would take for the page's
/// summary: a heading, an algorithm, the relation-meta line, a reference's
/// byline, a `TODO`. The card renders what this returns with its own small
/// markdown-it (`ccwiki.js`, `previewMarkdown`), so the output keeps `$…$`,
/// emphasis and code, and loses every link: a card is never clicked.
///
/// The block rules follow what the page renderer does with the same text
/// (markdown-it with `ccwiki.js`'s math, fence and HTML rules), closely
/// enough for a summary. Where they cannot match exactly, they err towards
/// skipping a block, never towards showing markup.
enum PreviewExcerpt {

    /// Where a long excerpt is cut: the last sentence end at or before
    /// `soft`, or else the last space before `hard`.
    static let softLimit = 280
    static let hardLimit = 420

    // MARK: Scope

    /// The part of a body a card summarises, as lines.
    struct Scope: Sendable {
        /// The heading the section hangs from, as raw markdown; nil for the
        /// whole page.
        let heading: String?
        /// The anchor named the page's first H1, which is the page itself.
        let isWholePage: Bool
        let lines: [Substring]
    }

    private struct HeadingLine {
        let index: Int
        let level: Int
        let raw: String
        let id: String
    }

    /// The body after the first ATX H1, or the whole body without one. With
    /// an anchor, the section whose heading id matches, up to the next heading
    /// of the same or a higher level; nil when no heading has that id.
    ///
    /// Ids come from the same deduplicating `GithubSlugger` as
    /// `WikiPage.headings()`, over the same headings, so the first heading
    /// with an id wins, as a Quartz anchor lands on the first.
    static func scope(of body: String, anchor: String?) -> Scope? {
        let text = withoutComments(body)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let headings = headingLines(in: text, lines: lines)
        let firstH1 = headings.first { $0.level == 1 }

        guard let anchor, !anchor.isEmpty else {
            let start = firstH1.map { $0.index + 1 } ?? 0
            return Scope(heading: nil, isWholePage: true, lines: Array(lines[start...]))
        }
        guard let target = headings.first(where: { $0.id == anchor }) else { return nil }
        let next = headings.first(where: { $0.index > target.index && $0.level <= target.level })
        let end = next?.index ?? lines.count
        return Scope(
            heading: target.raw,
            isWholePage: target.index == firstH1?.index,
            lines: Array(lines[(target.index + 1)..<end]))
    }

    /// Every ATX heading outside fenced code and comments, with its id, in
    /// the order `WikiPage.headings()` assigns them.
    private static func headingLines(in text: String, lines: [Substring]) -> [HeadingLine] {
        let inert = CodeMask.inertRanges(in: text)
        var slugger = GithubSlugger()
        var result: [HeadingLine] = []
        for (index, line) in lines.enumerated() {
            guard let (level, raw) = WikiPage.atxHeading(line) else { continue }
            guard !inert.contains(where: { $0.contains(line.startIndex) }) else { continue }
            let plain = WikiPage.Heading.plainText(raw)
            guard !plain.isEmpty else { continue }
            result.append(HeadingLine(index: index, level: level, raw: raw, id: slugger.slug(plain)))
        }
        return result
    }

    /// `%%…%%` deleted, as Quartz deletes it before it parses anything, and
    /// CRLF line ends made LF. A comment can span blank lines, so it has to
    /// go before the body is split into blocks.
    private static func withoutComments(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard result.contains("%%") else { return result }
        result = result.replacingOccurrences(
            of: #"%%[\s\S]*?%%"#, with: "", options: .regularExpression)
        return result
    }

    // MARK: The first paragraph

    /// The first paragraph of prose in `body`, its lines joined with single
    /// spaces, links and all; nil when there is none. See `scope(of:anchor:)`
    /// for which part of the body is read.
    static func firstParagraph(in body: String, anchor: String?) -> String? {
        scope(of: body, anchor: anchor).flatMap { firstParagraph(inLines: $0.lines) }
    }

    /// The first paragraph among `lines`, which start outside any block.
    ///
    /// Skipped: headings, fenced code (pseudocode included), `$$` blocks,
    /// HTML blocks and comments, the generated relation lists, blockquotes
    /// and callouts, lists, tables, indented code, thematic breaks; and among
    /// paragraphs the relation-meta line, a reference's byline, a `TODO`
    /// placeholder, an image or embed, a footnote or link definition, a
    /// paragraph that is only a bold label, and one with nothing left once
    /// its links and markup are gone.
    static func firstParagraph(inLines lines: [Substring]) -> String? {
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
            } else if let fence = fenceRun(line) {
                i = endOfFence(lines, from: i, fence: fence)
            } else if let size = displayMathRun(line) {
                i = endOfDisplayMath(lines, from: i, size: size)
            } else if WikiPage.atxHeading(line) != nil || isThematicBreak(line) {
                i += 1
            } else if isGeneratedStart(line) {
                i = endOfGenerated(lines, from: i)
            } else if startsHTMLComment(line) {
                i = endOfHTMLComment(lines, from: i)
            } else if indent(of: line) >= 4 || startsHTMLBlock(line, interrupting: false)
                        || isBlockquote(line) || isTableRow(line) {
                i = nextBlankLine(lines, from: i)
            } else if listMarker(line) != nil {
                i = endOfList(lines, from: i)
            } else {
                var end = i + 1
                while end < lines.count, !isBlank(lines[end]), !interruptsParagraph(lines[end]) {
                    if isSetextUnderline(lines[end]) { break }
                    end += 1
                }
                // A setext underline makes the lines above it a heading, and a
                // delimiter row under the first line makes them a table.
                if end < lines.count, isSetextUnderline(lines[end]) {
                    i = end + 1
                    continue
                }
                if end > i + 1, isTableDelimiterRow(lines[i + 1]) {
                    i = nextBlankLine(lines, from: i)
                    continue
                }
                let paragraph = lines[i..<end].map(joinable).joined(separator: " ")
                i = end
                if isSkippedParagraph(paragraph) { continue }
                let kept = withoutTrailingPlaceholder(paragraph)
                if inlineWithoutLinks(kept).isEmpty { continue }
                return kept
            }
        }
        return nil
    }

    /// A paragraph that is not a summary of anything.
    private static func isSkippedParagraph(_ paragraph: String) -> Bool {
        // The site's line of relation fields, should previews ever read the
        // rendered markdown rather than `page.body`, which does not carry it.
        if paragraph.hasSuffix(RelationMeta.marker) { return true }
        // A reference's byline: metadata, which the card's meta already has.
        if paragraph.hasPrefix("**Authors:**") || paragraph.hasPrefix("Authors:") { return true }
        // "TODO — abstract." on 234 reference pages, "TODO: syntax and
        // security definition." on stubs. Not a preview.
        if paragraph.hasPrefix("TODO") { return true }
        // An image or an embed standing as a paragraph.
        if paragraph.hasPrefix("![") { return true }
        // Footnote and link reference definitions.
        if paragraph.range(of: #"^\[\^?[^\]]+\]:"#, options: .regularExpression) != nil {
            return true
        }
        // A bold label on a line of its own ("**Builds on LWE**") heads what
        // follows; it says nothing by itself.
        if paragraph.range(of: #"^\*\*[^*]+\*\*$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// "Introduced by DGI+19. TODO": a placeholder that ends a paragraph goes,
    /// with whatever follows it.
    private static func withoutTrailingPlaceholder(_ paragraph: String) -> String {
        guard let range = paragraph.range(of: #"(^|\s)TODO\b"#, options: .regularExpression)
        else { return paragraph }
        return paragraph[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    /// One line of a paragraph, ready to be joined to the next with a space:
    /// trimmed, and without the backslash of a hard line break.
    private static func joinable(_ line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("\\"), !text.hasSuffix("\\\\") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Blocks

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// Columns of leading indentation, a tab counting as four.
    private static func indent(of line: Substring) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - columns % 4
            } else {
                break
            }
        }
        return columns
    }

    /// The line without its indentation, when that is three spaces at most.
    private static func content(of line: Substring) -> Substring? {
        guard indent(of: line) <= 3 else { return nil }
        return line.drop { $0 == " " || $0 == "\t" }
    }

    /// `^ {0,3}(`{3,}|~{3,})`, the fence rule `RelationMeta.insertUnderH1`
    /// uses: the marker and the length of its run.
    private static func fenceRun(_ line: Substring) -> (marker: Character, length: Int)? {
        guard let rest = content(of: line), let marker = rest.first,
              marker == "`" || marker == "~"
        else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    /// Past the fence that opens at `start`: a run of the same marker at
    /// least as long closes it, and an unclosed one runs to the end.
    private static func endOfFence(
        _ lines: [Substring], from start: Int, fence: (marker: Character, length: Int)
    ) -> Int {
        var j = start + 1
        while j < lines.count {
            if let run = fenceRun(lines[j]), run.marker == fence.marker, run.length >= fence.length {
                return j + 1
            }
            j += 1
        }
        return lines.count
    }

    /// `ccwiki.js`'s `mathBlock`: a line opening with two or more dollars and
    /// no other dollar on it. The size of its run; a one-line `$$x$$` is
    /// inline math, and so a paragraph.
    private static func displayMathRun(_ line: Substring) -> Int? {
        guard let rest = content(of: line), rest.hasPrefix("$$") else { return nil }
        let size = rest.prefix { $0 == "$" }.count
        return rest.dropFirst(size).contains("$") ? nil : size
    }

    /// Past the display block opening at `start`: the first later line that
    /// is a run of at least `size` dollars and nothing else closes it.
    private static func endOfDisplayMath(_ lines: [Substring], from start: Int, size: Int) -> Int {
        var j = start + 1
        while j < lines.count {
            if let rest = content(of: lines[j]), rest.hasPrefix("$") {
                let run = rest.prefix { $0 == "$" }.count
                if run >= size, isBlank(rest.dropFirst(run)) { return j + 1 }
            }
            j += 1
        }
        return lines.count
    }

    /// `---`, `***` or `___`, three or more, spaces allowed between.
    private static func isThematicBreak(_ line: Substring) -> Bool {
        guard let rest = content(of: line), let mark = rest.first,
              mark == "-" || mark == "*" || mark == "_"
        else { return false }
        return rest.count(where: { $0 == mark }) >= 3
            && rest.allSatisfy { $0 == mark || $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// `===` or `---` under a paragraph line, which makes that line a heading.
    private static func isSetextUnderline(_ line: Substring) -> Bool {
        guard let rest = content(of: line), let mark = rest.first, mark == "=" || mark == "-"
        else { return false }
        let run = rest.prefix { $0 == mark }.count
        return isBlank(rest.dropFirst(run))
    }

    private static func isBlockquote(_ line: Substring) -> Bool {
        content(of: line)?.first == ">"
    }

    private static func isTableRow(_ line: Substring) -> Bool {
        content(of: line)?.first == "|"
    }

    /// `| --- | :-: |`: the row under a table's header.
    private static func isTableDelimiterRow(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return trimmed.range(
            of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil
    }

    /// A bullet (`-`, `*`, `+`) or an ordered item (`1.`, `2)`) and its
    /// number, followed by a space or the end of the line.
    private static func listMarker(_ line: Substring) -> (ordered: Bool, number: Int)? {
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let next = rest.dropFirst().first
            return next == nil || next == " " || next == "\t" ? (false, 0) : nil
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
        let next = after.dropFirst().first
        return next == nil || next == " " || next == "\t" ? (true, number) : nil
    }

    /// Past a list: its items, their indented continuations and the blank
    /// lines between them, up to the first line after a blank that neither
    /// continues an item nor starts one, or an unindented block that ends it.
    private static func endOfList(_ lines: [Substring], from start: Int) -> Int {
        var j = start + 1
        while j < lines.count {
            let line = lines[j]
            if isBlank(line) {
                var k = j + 1
                while k < lines.count, isBlank(lines[k]) { k += 1 }
                guard k < lines.count, indent(of: lines[k]) >= 2 || listMarker(lines[k]) != nil
                else { return k }
                j = k
                continue
            }
            if indent(of: line) < 2, listMarker(line) == nil, interruptsParagraph(line) {
                return j
            }
            j += 1
        }
        return lines.count
    }

    /// The `<!-- BEGIN GENERATED … -->` sections the wiki's tooling writes
    /// onto object pages: lists of relations, which the inspector shows.
    private static func isGeneratedStart(_ line: Substring) -> Bool {
        content(of: line)?.hasPrefix("<!-- BEGIN GENERATED") ?? false
    }

    private static func endOfGenerated(_ lines: [Substring], from start: Int) -> Int {
        var j = start + 1
        while j < lines.count {
            if lines[j].contains("<!-- END GENERATED") { return j + 1 }
            j += 1
        }
        return lines.count
    }

    private static func startsHTMLComment(_ line: Substring) -> Bool {
        content(of: line)?.hasPrefix("<!--") ?? false
    }

    /// Past the comment opening at `start`, which ends on the line that holds
    /// its `-->`.
    private static func endOfHTMLComment(_ lines: [Substring], from start: Int) -> Int {
        if let open = lines[start].range(of: "<!--"),
           lines[start][open.upperBound...].contains("-->") {
            return start + 1
        }
        var j = start + 1
        while j < lines.count {
            if lines[j].contains("-->") { return j + 1 }
            j += 1
        }
        return lines.count
    }

    /// markdown-it's HTML blocks of types 1 and 6 (a block-level tag name) and,
    /// at the start of a block only, type 7 (any whole tag alone on its line).
    /// Type 7 cannot interrupt a paragraph, which is how a stray `</content>`
    /// under one stays part of it, as inline HTML that the excerpt drops.
    private static func startsHTMLBlock(_ line: Substring, interrupting: Bool) -> Bool {
        guard let rest = content(of: line), rest.first == "<" else { return false }
        let afterBracket = rest.dropFirst()
        if afterBracket.first == "?" || afterBracket.first == "!" { return true }
        let name = afterBracket.drop { $0 == "/" }
            .prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            .lowercased()
        if blockTagNames.contains(name) { return true }
        guard !interrupting else { return false }
        return String(rest).range(
            of: #"^</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>\s*$"#, options: .regularExpression) != nil
    }

    private static let blockTagNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2",
        "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param",
        "pre", "script", "section", "source", "style", "summary", "table", "tbody", "td",
        "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    /// Whether `line` ends the paragraph above it without a blank line.
    private static func interruptsParagraph(_ line: Substring) -> Bool {
        if fenceRun(line) != nil || displayMathRun(line) != nil { return true }
        if WikiPage.atxHeading(line) != nil || isBlockquote(line) { return true }
        if isThematicBreak(line), !(content(of: line)?.hasPrefix("-") ?? false) { return true }
        if startsHTMLComment(line) || startsHTMLBlock(line, interrupting: true) { return true }
        // An ordered item interrupts only when it starts at 1.
        if indent(of: line) <= 3, let marker = listMarker(line), !marker.ordered || marker.number == 1 {
            return true
        }
        return false
    }

    private static func nextBlankLine(_ lines: [Substring], from start: Int) -> Int {
        var j = start + 1
        while j < lines.count, !isBlank(lines[j]) { j += 1 }
        return j
    }

    // MARK: Inline markdown without links

    /// `markdown` with every link reduced to what it shows, as inline
    /// markdown on one line:
    ///
    /// - `[[target|alias]]` becomes its display text, by `displayText` in
    ///   `ccwiki.js` (the alias, else the last path segment, plus ` › anchor`),
    ///   escaped, because the page shows that text as written;
    /// - `[text](destination)` becomes its text, which is markdown already;
    /// - images, embeds, footnote markers, inline HTML tags and comments go;
    /// - `$…$`, code spans, emphasis and backslash escapes stay, so the card
    ///   renders math and emphasis as the page does.
    static func inlineWithoutLinks(_ markdown: String) -> String {
        let reduced = reduce(Array(withoutComments(markdown)))
        return reduced.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func reduce(_ chars: [Character]) -> String {
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
            } else if c == "$" || c == "`" {
                let span = codeOrMath(chars, at: i)
                out += String(chars[i..<span])
                i = span
            } else if c == "!" || c == "[", let link = wikilink(chars, at: i) {
                if !link.isEmbed { out += escaped(link.display) }
                i = link.end
            } else if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
                      let image = inlineLink(chars, at: i + 1) {
                i = image.end
            } else if c == "[", i + 1 < chars.count, chars[i + 1] == "^",
                      let close = chars[(i + 2)...].firstIndex(of: "]"),
                      !chars[(i + 2)..<close].contains(where: { $0.isWhitespace }) {
                i = close + 1
            } else if c == "[", let link = inlineLink(chars, at: i) {
                out += reduce(Array(chars[link.text]))
                i = link.end
            } else if c == "<", let tag = htmlTag(chars, at: i) {
                out += tag.text
                i = tag.end
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Past the `$` or backtick run at `start` and the span it opens: a run
    /// closes at the next run of exactly its length, as
    /// `RelationMeta.escapeOutsideMath` reads it. Past the run alone when
    /// nothing closes it.
    private static func codeOrMath(_ chars: [Character], at start: Int) -> Int {
        let marker = chars[start]
        var end = start
        while end < chars.count, chars[end] == marker { end += 1 }
        guard let close = closingRun(chars, from: end, marker: marker, length: end - start)
        else { return end }
        return close + (end - start)
    }

    private static func closingRun(
        _ chars: [Character], from start: Int, marker: Character, length: Int
    ) -> Int? {
        var j = start
        while j < chars.count {
            guard chars[j] == marker else { j += 1; continue }
            var k = j
            while k < chars.count, chars[k] == marker { k += 1 }
            if k - j == length { return j }
            j = k
        }
        return nil
    }

    /// The wikilink starting at `start`, by Quartz's grammar (`ofm.ts:123`,
    /// as `WikilinkParser` and `ccwiki.js` read it), with the text the page
    /// shows for it.
    private static func wikilink(
        _ chars: [Character], at start: Int
    ) -> (end: Int, display: String, isEmbed: Bool)? {
        var p = start
        let isEmbed = chars[p] == "!"
        if isEmbed { p += 1 }
        guard p + 1 < chars.count, chars[p] == "[", chars[p + 1] == "[" else { return nil }
        p += 2
        let stops: Set<Character> = ["[", "]", "|", "#", "\\"]

        let targetStart = p
        while p < chars.count, !stops.contains(chars[p]) { p += 1 }
        let target = String(chars[targetStart..<p]).trimmingCharacters(in: .whitespaces)

        var anchor = ""
        if p < chars.count, chars[p] == "#" {
            while p < chars.count, chars[p] == "#" { p += 1 }
            let anchorStart = p
            while p < chars.count, !stops.contains(chars[p]) { p += 1 }
            guard p > anchorStart else { return nil }
            anchor = String(chars[anchorStart..<p]).trimmingCharacters(in: .whitespaces)
        }

        var alias = ""
        if p < chars.count, chars[p] == "|"
            || (chars[p] == "\\" && p + 1 < chars.count && chars[p + 1] == "|") {
            p += chars[p] == "\\" ? 2 : 1
            let aliasStart = p
            while p < chars.count, chars[p] != "[", chars[p] != "]", chars[p] != "#" { p += 1 }
            alias = String(chars[aliasStart..<p]).trimmingCharacters(in: .whitespaces)
        }
        guard p + 1 < chars.count, chars[p] == "]", chars[p + 1] == "]" else { return nil }

        let display: String
        if !alias.isEmpty {
            display = alias
        } else if target.isEmpty {
            display = anchor
        } else {
            let base = target.components(separatedBy: "/").last ?? target
            display = anchor.isEmpty ? base : base + " › " + anchor
        }
        return (p + 2, display, isEmbed)
    }

    /// The inline link whose text opens at the `[` at `start`: the range of
    /// its text and where it ends. markdown-it's grammar, as far as a summary
    /// needs it: nested brackets, escapes, code and math in the text, a
    /// destination bare or in `<…>`, and an optional title.
    private static func inlineLink(
        _ chars: [Character], at start: Int
    ) -> (text: Range<Int>, end: Int)? {
        guard chars[start] == "[" else { return nil }
        var depth = 1
        var j = start + 1
        while j < chars.count {
            let c = chars[j]
            if c == "\\", j + 1 < chars.count, isASCIIPunctuation(chars[j + 1]) {
                j += 2
                continue
            }
            if c == "$" || c == "`" {
                j = codeOrMath(chars, at: j)
                continue
            }
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        guard j < chars.count, depth == 0 else { return nil }
        let labelEnd = j
        guard labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }

        var p = skipSpaces(chars, from: labelEnd + 2)
        if p < chars.count, chars[p] == "<" {
            var q = p + 1
            while q < chars.count, chars[q] != ">", chars[q] != "<" {
                q += chars[q] == "\\" ? 2 : 1
            }
            guard q < chars.count, chars[q] == ">" else { return nil }
            p = q + 1
        } else {
            var parens = 0
            while p < chars.count {
                let c = chars[p]
                if c.isWhitespace { break }
                if c == "\\" {
                    p += 2
                    continue
                }
                if c == "(" { parens += 1 }
                if c == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                p += 1
            }
        }
        p = skipSpaces(chars, from: p)
        if p < chars.count, chars[p] == "\"" || chars[p] == "'" || chars[p] == "(" {
            let close: Character = chars[p] == "(" ? ")" : chars[p]
            var q = p + 1
            while q < chars.count, chars[q] != close { q += chars[q] == "\\" ? 2 : 1 }
            guard q < chars.count else { return nil }
            p = skipSpaces(chars, from: q + 1)
        }
        guard p < chars.count, chars[p] == ")" else { return nil }
        return ((start + 1)..<labelEnd, p + 1)
    }

    private static func skipSpaces(_ chars: [Character], from start: Int) -> Int {
        var p = start
        while p < chars.count, chars[p].isWhitespace { p += 1 }
        return p
    }

    /// An HTML comment, an inline tag or an autolink at `start`: the text it
    /// leaves behind (nothing for a tag or a comment, the address for an
    /// autolink) and where it ends. Nil when `<` starts none of them, as in
    /// `a < b`.
    private static func htmlTag(_ chars: [Character], at start: Int) -> (text: String, end: Int)? {
        let rest = String(chars[start...])
        if rest.hasPrefix("<!--") {
            guard let close = rest.range(of: "-->") else { return nil }
            return ("", start + rest.distance(from: rest.startIndex, to: close.upperBound))
        }
        let ns = rest as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let match = autolink.firstMatch(in: rest, options: .anchored, range: whole),
           let range = Range(match.range, in: rest) {
            let address = String(rest[range].dropFirst().dropLast())
            return (escaped(address), start + rest.distance(from: rest.startIndex, to: range.upperBound))
        }
        if let match = inlineTag.firstMatch(in: rest, options: .anchored, range: whole),
           let range = Range(match.range, in: rest) {
            return ("", start + rest.distance(from: rest.startIndex, to: range.upperBound))
        }
        return nil
    }

    private static let autolink = try! NSRegularExpression(
        pattern: #"<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*>"#)
    private static let inlineTag = try! NSRegularExpression(
        pattern: #"</?[A-Za-z][A-Za-z0-9\-]*(\s[^<>]*)?/?>"#)

    // MARK: Escaping

    /// Plain text as inline markdown that shows exactly that text: every
    /// character markdown-it could read as markup is backslash-escaped. For
    /// a wikilink's display text, a statement built from labels, a paper's
    /// title, an author list.
    static func escaped(_ plain: String) -> String {
        var out = ""
        for character in plain {
            if markdownSpecials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static let markdownSpecials: Set<Character> = [
        "\\", "`", "*", "_", "$", "[", "]", "<", "&", "~",
    ]

    private static func isASCIIPunctuation(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first
        else { return false }
        return MarkdownLinkParser.isASCIIPunctuation(scalar.value)
    }

    // MARK: Truncation

    /// `inline` cut to a card's length: whole when it is `soft` characters or
    /// fewer; else at the last sentence end at or before `soft`; else at the
    /// last space before `hard`, with an ellipsis.
    ///
    /// Never inside a `$…$` or a code span, by the pairing rule
    /// `RelationMeta.escapeOutsideMath` uses, so no formula is cut in half;
    /// and an emphasis marker the cut leaves unclosed is removed. A sentence
    /// end in the first third of `soft` loses to the space cut, so a short
    /// opening sentence does not leave a card nearly empty.
    static func truncated(
        _ inline: String, soft: Int = PreviewExcerpt.softLimit, hard: Int = PreviewExcerpt.hardLimit
    ) -> String {
        let chars = Array(inline)
        guard chars.count > soft else { return inline }
        let spans = protectedSpans(chars)
        if let cut = lastSentenceEnd(chars, atOrBefore: soft, spans: spans), cut >= soft / 3 {
            return String(withoutUnclosedEmphasis(Array(chars[..<cut])))
        }
        return capped(chars, at: hard, spans: spans)
    }

    /// `inline` cut at the last space before `limit` with an ellipsis, when it
    /// is longer than that: for titles, meta parts and labels, which have no
    /// sentences to end at. Never inside `$…$` or a code span.
    static func capped(_ inline: String, at limit: Int) -> String {
        let chars = Array(inline)
        guard chars.count > limit else { return inline }
        return capped(chars, at: limit, spans: protectedSpans(chars))
    }

    private static func capped(_ chars: [Character], at limit: Int, spans: [Range<Int>]) -> String {
        guard chars.count > limit else { return String(chars) }
        // The ellipsis takes one character of the limit.
        var cut: Int?
        var k = min(limit, chars.count) - 1
        while k > 0, cut == nil {
            if chars[k] == " ", !splits(k, spans) { cut = k }
            k -= 1
        }
        // A formula or a word longer than the limit: past it, rather than
        // through it.
        if cut == nil {
            var forward = limit
            while forward < chars.count, cut == nil {
                if chars[forward] == " ", !splits(forward, spans) { cut = forward }
                forward += 1
            }
        }
        guard let cut else { return String(chars) }

        var kept = withoutUnclosedEmphasis(Array(chars[..<cut]))
        let dangling: Set<Character> = [" ", ",", ";", ":", "—", "–", "-", "(", "/"]
        while let last = kept.last, dangling.contains(last) { kept.removeLast() }
        return String(kept) + "…"
    }

    /// Whether cutting before `index` would split a protected span.
    private static func splits(_ index: Int, _ spans: [Range<Int>]) -> Bool {
        spans.contains { $0.lowerBound < index && index < $0.upperBound }
    }

    /// Every `$…$` and code span, by the pairing rule: a run of n dollars or
    /// backticks closes at the next run of exactly n. A backslash escapes
    /// the character after it outside a span.
    static func protectedSpans(_ chars: [Character]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                i += 2
            } else if c == "$" || c == "`" {
                let end = codeOrMath(chars, at: i)
                var run = i
                while run < chars.count, chars[run] == c { run += 1 }
                if end > run { spans.append(i..<end) }
                i = end
            } else {
                i += 1
            }
        }
        return spans
    }

    /// The end of the last sentence that ends at or before `limit`: a `.`,
    /// `!` or `?` outside math and code, with any closing brackets, quotes or
    /// emphasis after it, followed by a space or the end, where the next word
    /// does not start in lower case and the word before is not an
    /// abbreviation or an initial ("e.g.", "Michael J. Freedman").
    private static func lastSentenceEnd(
        _ chars: [Character], atOrBefore limit: Int, spans: [Range<Int>]
    ) -> Int? {
        let closers: Set<Character> = [")", "]", "\"", "'", "”", "’", "*", "_"]
        var best: Int?
        for p in 0..<min(chars.count, limit) where ".!?".contains(chars[p]) {
            guard !spans.contains(where: { $0.contains(p) }) else { continue }
            var q = p + 1
            while q < chars.count, q - p <= 3, closers.contains(chars[q]) { q += 1 }
            guard q <= limit, q == chars.count || chars[q].isWhitespace, !splits(q, spans)
            else { continue }
            var next = q
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            if next < chars.count, chars[next].isLowercase { continue }
            if chars[p] == ".", isAbbreviation(chars, endingAt: p) { continue }
            best = q
        }
        return best
    }

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "cf", "vs", "resp", "al", "etc", "approx", "fig", "sec", "thm", "def",
        "eq", "prop", "lem", "cor", "no", "vol", "pp", "ch", "ref", "refs", "ex", "viz", "w.r.t",
    ]

    private static func isAbbreviation(_ chars: [Character], endingAt period: Int) -> Bool {
        var start = period
        while start > 0, !chars[start - 1].isWhitespace, chars[start - 1] != "(" { start -= 1 }
        let word = String(chars[start..<period]).lowercased()
        if word.count == 1, word.first?.isLetter == true { return true }
        return abbreviations.contains(word)
    }

    // MARK: Emphasis

    /// The emphasis delimiter runs in `chars` (`*`, `**`, `_`, `__`), outside
    /// math and code, split into the ones that pair and the ones left open.
    /// A simplification of CommonMark's delimiter rules that is enough for
    /// the wiki's `**bold**` and `_italic_`: a run opens when text follows
    /// it and closes the nearest open run of the same marker and length when
    /// text precedes it. An underscore inside a word is not a delimiter.
    private static func emphasisRuns(
        _ chars: [Character]
    ) -> (matched: [Range<Int>], unclosed: [Range<Int>]) {
        var spanEnds: [Int: Int] = [:]
        for span in protectedSpans(chars) { spanEnds[span.lowerBound] = span.upperBound }

        var open: [Range<Int>] = []
        var matched: [Range<Int>] = []
        var unclosed: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                i += 2
                continue
            }
            if let end = spanEnds[i] {
                i = end
                continue
            }
            guard c == "*" || c == "_" else {
                i += 1
                continue
            }
            var end = i
            while end < chars.count, chars[end] == c { end += 1 }
            let before: Character? = i > 0 ? chars[i - 1] : nil
            let after: Character? = end < chars.count ? chars[end] : nil
            defer { i = end }
            if c == "_", let before, let after,
               before.isLetter || before.isNumber, after.isLetter || after.isNumber {
                continue
            }
            let run = i..<end
            let canOpen = after.map { !$0.isWhitespace } ?? false
            let canClose = before.map { !$0.isWhitespace } ?? false
            if canClose, let top = open.lastIndex(where: {
                chars[$0.lowerBound] == c && $0.count == run.count
            }) {
                matched.append(open[top])
                matched.append(run)
                // Anything opened inside the pair and not closed stays open.
                unclosed.append(contentsOf: open[(top + 1)...])
                open.removeSubrange(top...)
            } else if canOpen {
                open.append(run)
            }
        }
        unclosed.append(contentsOf: open)
        return (matched, unclosed)
    }

    /// `chars` without the emphasis markers a cut left open.
    private static func withoutUnclosedEmphasis(_ chars: [Character]) -> [Character] {
        removing(emphasisRuns(chars).unclosed, from: chars)
    }

    private static func removing(_ ranges: [Range<Int>], from chars: [Character]) -> [Character] {
        var result = chars
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            result.removeSubrange(range)
        }
        return result
    }

    // MARK: Plain text

    /// Inline markdown as plain text, for the card's VoiceOver label: math
    /// through `RelationText.plain` (`\bits` reads `{0,1}`), code without its
    /// backticks, escapes resolved, and paired emphasis markers dropped. A
    /// marker that pairs with nothing is a literal, as in MIP*, and stays.
    static func plainText(_ inline: String) -> String {
        let chars = removing(emphasisRuns(Array(inline)).matched, from: Array(inline))
        var spanEnds: [Int: Int] = [:]
        for span in protectedSpans(chars) { spanEnds[span.lowerBound] = span.upperBound }

        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
            } else if let end = spanEnds[i] {
                let span = String(chars[i..<end])
                if c == "$" {
                    out += RelationText.plain(span)
                } else {
                    out += span.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                        .trimmingCharacters(in: .whitespaces)
                }
                i = end
            } else {
                out.append(c)
                i += 1
            }
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
