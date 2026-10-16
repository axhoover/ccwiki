import Foundation

/// The subset of YAML that cryptology.city's frontmatter actually uses.
///
/// The app takes no SPM dependencies, so this is a hand-written parser. It is
/// not a YAML implementation and does not try to be — it handles exactly the
/// constructs the corpus and the repo's own lint permit:
///
/// - `key: scalar`, splitting on the **first** colon (345 lines carry a colon
///   inside the value — every `source:` URL and every `cryptobib_key`)
/// - block sequences (`aliases:` then `  - item`, or `- item` flush left) and
///   flow sequences (`[a, "b, c"]`, the empty `[]`)
/// - literal block scalars (`bibtex: |`), preserving interior newlines
/// - double- and single-quoted scalars, unquoted only when both ends match
/// - comments: full-line `#` comments (taught to agents by
///   `Templates/Reference.md`), and a trailing `# comment` after a value,
///   which the templates write on most keys. As in YAML, a comment starts at
///   a `#` after whitespace, so `C#`, a URL's `#fragment` and a quoted `"#P"`
///   are values.
/// - values that run on over the indented lines below their key: a plain or
///   quoted scalar, folded as YAML folds it, or a flow sequence, as the wiki's
///   formatter wraps a long one (`key:` then an indented `[…]`), whose items
///   fold the same way, and whose closing `]` may sit at the margin, as in a
///   JSON-style list. Blank lines and comments inside a block sequence do
///   not end it.
///
/// Deliberately *not* handled, because misreading them is worse than ignoring
/// them: nested mappings (an indented block under a key is skipped, so a nested
/// `status:` can never overwrite the top-level one), anchors, aliases, and tags.
struct Frontmatter: Equatable, Sendable {

    enum Value: Equatable, Sendable {
        case string(String)
        case list([String])
        case null
    }

    private(set) var fields: [String: Value] = [:]
    /// Offset of the first body character, after the closing `---`.
    private(set) var bodyStart: String.Index

    // MARK: Typed accessors

    func string(_ key: String) -> String? {
        guard case .string(let s)? = fields[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The raw value, whitespace intact — needed for `bibtex`, whose block
    /// scalar is meaningful line-for-line.
    func raw(_ key: String) -> String? {
        guard case .string(let s)? = fields[key] else { return nil }
        return s
    }

    /// A list field. A plain value is split on commas, as Quartz's
    /// `coerceToArray` does for `aliases` and `tags`: `aliases: PRF, PRP` is
    /// two aliases on the site, so it is two here.
    func list(_ key: String) -> [String] {
        switch fields[key] {
        case .list(let items): items
        case .string(let s):
            s.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default: []
        }
    }

    func bool(_ key: String) -> Bool? {
        guard let s = string(key)?.lowercased() else { return nil }
        return ["true", "yes", "on"].contains(s) ? true
            : ["false", "no", "off"].contains(s) ? false : nil
    }

    // MARK: Parsing

    static func parse(_ text: String) -> Frontmatter {
        var fm = Frontmatter(bodyStart: text.startIndex)

        // Normalize the two things that would break line splitting.
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        if source.contains("\r\n") { source = source.replacingOccurrences(of: "\r\n", with: "\n") }

        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmedTrailing == "---" else { return fm }

        var i = 1
        var found = false
        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmedTrailing

            if trimmedLine == "---" || trimmedLine == "..." {
                found = true
                i += 1
                break
            }
            if trimmedLine.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            // A leading space means we are inside a construct we already
            // consumed (or a nested mapping we are choosing to ignore).
            if line.first == " " || line.first == "\t" { i += 1; continue }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { i += 1; continue }

            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var rest = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            // `key: # note` has nothing on its line: a value never starts
            // with `#`, so this one is a comment and the value is below.
            if rest.hasPrefix("#") { rest = "" }

            let header = Self.plainValue(rest)
            if Self.isBlockScalarHeader(header) {
                let folded = header.hasPrefix(">")
                let (value, next) = Self.blockScalar(lines, from: i + 1, folded: folded)
                fm.fields[key] = .string(value)
                i = next
                continue
            }

            if rest.isEmpty {
                let (value, next) = Self.nestedValue(lines, from: i + 1)
                fm.fields[key] = value
                i = next
            } else if rest.hasPrefix("[") {
                if let flow = Self.flowSequence(rest, lines, from: i + 1, indent: 0) {
                    fm.fields[key] = .list(flow.items)
                    i = flow.next
                } else {
                    // Brackets that never close, or text after them: not
                    // YAML, so kept as written.
                    fm.fields[key] = .string(Self.plainValue(rest))
                    i += 1
                }
            } else {
                let (value, next) = Self.scalar(rest, lines, from: i + 1, indent: 0)
                fm.fields[key] = .string(value)
                i = next
            }
        }

        guard found else { return Frontmatter(bodyStart: text.startIndex) }

        // Map the line index back into the *original* text. Counting from the
        // normalized copy would drift on CRLF input, so walk the original —
        // by UTF-8 byte, because "\r\n" is one Character and never equals
        // "\n". The index after a line feed is always a Character boundary.
        let utf8 = text.utf8
        var idx = text.startIndex
        var remaining = i
        while remaining > 0, idx < text.endIndex {
            if let nl = utf8[idx...].firstIndex(of: UInt8(ascii: "\n")) {
                idx = utf8.index(after: nl)
                remaining -= 1
            } else {
                idx = text.endIndex
                break
            }
        }
        fm.bodyStart = idx
        return fm
    }

    /// A literal (`|`) or folded (`>`) block scalar: every following line that
    /// is blank or indented, dedented by the smallest indent present.
    private static func blockScalar(
        _ lines: [String], from start: Int, folded: Bool
    ) -> (String, Int) {
        var collected: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                collected.append("")
                i += 1
                continue
            }
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
            collected.append(line)
            i += 1
        }
        while collected.last?.isEmpty == true { collected.removeLast() }

        let indent = collected
            .filter { !$0.isEmpty }
            .map { $0.prefix { $0 == " " }.count }
            .min() ?? 0
        let dedented = collected.map { $0.isEmpty ? "" : String($0.dropFirst(indent)) }

        return (folded ? dedented.joined(separator: " ") : dedented.joined(separator: "\n"), i)
    }

    /// The value of a `key:` with nothing after it, read from the lines below
    /// it, past any blank lines and comments: a block sequence, a flow
    /// sequence or a scalar on the next line (as the wiki's formatter wraps
    /// a long value), or null. A nested mapping, an anchor, a tag or anything
    /// else this parser does not read is null, and the main loop skips its
    /// indented lines.
    private static func nestedValue(_ lines: [String], from start: Int) -> (Value, Int) {
        var first = start
        while first < lines.count, isBlankOrComment(lines[first]) { first += 1 }
        guard first < lines.count else { return (.null, start) }
        let line = lines[first]
        let text = line.trimmingCharacters(in: .whitespaces)
        if isItem(text) {
            let (items, next) = blockSequence(lines, from: first)
            return (items.isEmpty ? .null : .list(items), next)
        }
        // Flush left, it is the next key (or the closing `---`).
        guard indentation(line) > 0, let lead = text.first else { return (.null, start) }
        if lead == "[" {
            guard let flow = flowSequence(text, lines, from: first + 1, indent: 0)
            else { return (.null, start) }
            return (.list(flow.items), flow.next)
        }
        if "&*!|>%@`{}],".contains(lead) || isMappingEntry(text) { return (.null, start) }
        let (value, next) = scalar(text, lines, from: first + 1, indent: 0)
        return (.string(value), next)
    }

    /// A block sequence: `  - item` lines, or `- item` lines flush left,
    /// which YAML also allows under a key (and js-yaml, so the site, reads).
    /// The first item, at `start`, sets the column of the dashes. Blank lines
    /// and comments between items do not end it. A line indented past the
    /// dashes continues its item's scalar, or belongs to an item that is a
    /// mapping (`- kind: …` in `consequences`), which is kept as written and
    /// its lines skipped. A flush item has to be `- ` or a bare `-`, so the
    /// closing `---` never is one.
    private static func blockSequence(_ lines: [String], from start: Int) -> ([String], Int) {
        var items: [String] = []
        var dashes: Int?
        var i = start
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            let indent = indentation(lines[i])
            if let dashes, indent > dashes { i += 1; continue }
            guard isItem(trimmed), dashes == nil || indent == dashes else { break }
            dashes = indent

            var item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            // `- # note` is an empty item.
            if item.hasPrefix("#") { item = "" }
            if item.isEmpty || isMappingEntry(item) {
                items.append(item)
                i += 1
            } else {
                let (value, next) = scalar(item, lines, from: i + 1, indent: indent)
                items.append(value)
                i = next
            }
        }
        return (items, i)
    }

    /// A flow sequence from the `[` that starts `first`, the rest of its
    /// line, running on over the following lines indented past `indent`
    /// until its brackets close. A line that starts with `]` may sit at the
    /// margin, as a JSON-style list's closing bracket does; an item there
    /// leaves the brackets unclosed. Commas inside quotes or nested
    /// brackets do not split it, a `#` after whitespace comments out the
    /// rest of a line, and a quote opens a quoted item only at the item's
    /// start, so `[it's, b]` is two items, as in YAML. An item over several
    /// lines folds as a scalar does: a line break to a space, each blank
    /// line to a newline, and a double-quoted item's escaped line break (`\`
    /// at the end of the line) to nothing. Nil when the brackets never
    /// close, or more than a comment follows them. Known edge, as in
    /// `quotedScalar`: an escaped space or tab at the end of a double-quoted
    /// line (`\ `) is trimmed with the line, so it reads as an escaped line
    /// break, where YAML keeps the escaped space or tab and folds the break
    /// as usual.
    private static func flowSequence(
        _ first: String, _ lines: [String], from start: Int, indent: Int
    ) -> (items: [String], next: Int)? {
        var items: [String] = []
        var current = ""
        var depth = 1
        var quote: Character?
        var line = Array(first)
        var k = 1  // past the opening `[`
        var next = start

        while true {
            while k < line.count {
                let c = line[k]
                if let open = quote {
                    current.append(c)
                    if open == "\"", c == "\\", k + 1 < line.count {
                        // The escaped character, a quote included.
                        current.append(line[k + 1])
                        k += 2
                        continue
                    }
                    if c == open {
                        // `''` inside single quotes is an escaped quote.
                        if open == "'", k + 1 < line.count, line[k + 1] == "'" {
                            current.append("'")
                            k += 2
                            continue
                        }
                        quote = nil
                    }
                    k += 1
                    continue
                }
                // A comment runs to the end of the line.
                if c == "#", k == 0 || line[k - 1] == " " || line[k - 1] == "\t" { break }

                if c == "[" || c == "{" {
                    depth += 1
                    current.append(c)
                } else if c == "]" || c == "}" {
                    depth -= 1
                    guard depth == 0 else { current.append(c); k += 1; continue }
                    let tail = String(line[(k + 1)...]).trimmingCharacters(in: .whitespaces)
                    guard c == "]", tail.isEmpty || tail.hasPrefix("#") else { return nil }
                    let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !last.isEmpty { items.append(unquote(last)) }
                    return (items, next)
                } else if c == ",", depth == 1 {
                    items.append(unquote(current.trimmingCharacters(in: .whitespacesAndNewlines)))
                    current = ""
                } else if c == "\"" || c == "'",
                          "[{,".contains(current.last(where: { !$0.isWhitespace }) ?? ",") {
                    quote = c
                    current.append(c)
                } else {
                    current.append(c)
                }
                k += 1
            }

            // The line ends inside the brackets: the sequence runs on, and
            // an item folds as a scalar does. A line break is a space, or
            // nothing after an escaping `\` in double quotes; one followed
            // by blank lines is a newline for each instead. Between items
            // the breaks are only whitespace, which the item's trim drops.
            var blankLines = 0
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                blankLines += 1
                next += 1
            }
            // js-yaml reads an open flow collection's lines at any indentation
            // (a short one is only a "deficient indentation" warning), so a
            // JSON-style closing `]` at the margin still closes the list. Any
            // other line there, an item included, leaves it unclosed, so the
            // next key and the closing `---` are never read into it.
            guard next < lines.count,
                  indentation(lines[next]) > indent || lines[next].hasPrefix("]")
            else { return nil }
            line = Array(lines[next].trimmingCharacters(in: .whitespaces))
            k = 0
            next += 1
            if quote == "\"", current.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
                // An escaped line break joins the lines without a space.
                current.removeLast()
            } else {
                current = current.trimmedTrailing
                if blankLines == 0 { current += " " }
            }
            current += String(repeating: "\n", count: blankLines)
        }
    }

    /// A scalar whose text on its own line is `first`, running on over the
    /// following lines indented past `indent`, as YAML lets it. A quoted one
    /// ends at its closing quote; a plain one at a comment, a blank line
    /// before an outdented one, or a `key:` line, which cannot continue it.
    /// Lines fold as YAML folds them: a line break to a space, each blank
    /// line to a newline. Returns the value and the line after it.
    private static func scalar(
        _ first: String, _ lines: [String], from start: Int, indent: Int
    ) -> (String, Int) {
        if let quote = first.first, quote == "\"" || quote == "'" {
            return quotedScalar(first, quote: quote, lines, from: start, indent: indent)
        }
        var value = plainValue(first)
        // A comment ends the scalar.
        guard value == first else { return (value, start) }

        var next = start
        var blankLines = 0
        var i = start
        while i < lines.count {
            let text = lines[i].trimmingCharacters(in: .whitespaces)
            if text.isEmpty { blankLines += 1; i += 1; continue }
            guard indentation(lines[i]) > indent, !text.hasPrefix("#"), !isMappingEntry(text)
            else { break }
            let piece = plainValue(text)
            value += blankLines > 0 ? String(repeating: "\n", count: blankLines) : " "
            value += piece
            blankLines = 0
            i += 1
            next = i
            if piece != text { break }
        }
        return (value, next)
    }

    /// A quoted scalar that starts `first`. One that closes on its own line
    /// loses its quotes and any comment after them. One that does not runs
    /// on, line by line, to the line holding its closing quote. A quoted
    /// scalar that never closes, or closes with more than a comment after
    /// it, is not YAML and is kept as written.
    private static func quotedScalar(
        _ first: String, quote: Character, _ lines: [String], from start: Int, indent: Int
    ) -> (String, Int) {
        if let value = quotedValue(first) { return (unquote(value), start) }
        let asWritten = (unquote(first), start)
        guard closingQuote(quote, in: first, from: first.index(after: first.startIndex)) == nil
        else { return asWritten }

        var text = first.trimmedTrailing
        var blankLines = 0
        var i = start
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { blankLines += 1; i += 1; continue }
            guard indentation(lines[i]) > indent else { break }
            if blankLines > 0 {
                text += String(repeating: "\n", count: blankLines)
            } else if quote == "\"", text.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
                // An escaped line break joins the lines without a space.
                text.removeLast()
            } else {
                text += " "
            }
            blankLines = 0
            i += 1
            // The quote is open at the start of every line: had the line
            // before closed it, the scan would have stopped there.
            guard let close = closingQuote(quote, in: line, from: line.startIndex) else {
                text += line
                continue
            }
            let tail = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { return asWritten }
            return (unquote(text + String(line[...close])), i)
        }
        return asWritten
    }

    /// The quote that closes a `quote`-quoted scalar in `s`, scanning from
    /// `start`, which is inside the quotes: `\"` is an escaped quote in
    /// double quotes and `''` in single quotes. Nil when `s` ends first.
    private static func closingQuote(
        _ quote: Character, in s: String, from start: String.Index
    ) -> String.Index? {
        var index = start
        while index < s.endIndex {
            let c = s[index]
            if quote == "\"", c == "\\" {
                // Skip the escaped character.
                index = s.index(after: index)
                if index < s.endIndex { index = s.index(after: index) }
                continue
            }
            if c == quote {
                let next = s.index(after: index)
                // `''` inside single quotes is an escaped quote.
                if quote == "'", next < s.endIndex, s[next] == "'" {
                    index = s.index(after: next)
                    continue
                }
                return index
            }
            index = s.index(after: index)
        }
        return nil
    }

    /// `"Foo" # note` → `"Foo"`: a quoted scalar followed only by a comment.
    /// Returns nil when `s` is not a quoted scalar with at most a comment
    /// after it, so `"#P"` keeps its `#`.
    static func quotedValue(_ s: String) -> String? {
        guard let quote = s.first, quote == "\"" || quote == "'",
              let close = closingQuote(quote, in: s, from: s.index(after: s.startIndex))
        else { return nil }
        let tail = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        return String(s[...close])
    }

    /// `implication # a note` → `implication`: a plain (unquoted) scalar
    /// without its trailing comment. As in YAML, a comment starts at a `#`
    /// after a space or tab; one anywhere else is text, so `C#` and a URL's
    /// `#fragment` survive. A `'` in a plain scalar is text, so quotes are
    /// not tracked.
    static func plainValue(_ s: String) -> String {
        var previous: Character?
        for index in s.indices {
            let c = s[index]
            if c == "#", previous == " " || previous == "\t" {
                return String(s[..<index]).trimmedTrailing
            }
            previous = c
        }
        return s
    }

    /// `key: value` or `key:`: a mapping entry, which a plain scalar never
    /// is, since YAML ends one at `: `. A quoted key counts too.
    private static func isMappingEntry(_ s: String) -> Bool {
        if let quote = s.first, quote == "\"" || quote == "'" {
            guard let close = closingQuote(quote, in: s, from: s.index(after: s.startIndex))
            else { return false }
            return s[s.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix(":")
        }
        let plain = plainValue(s)
        return plain.hasSuffix(":") || plain.contains(": ") || plain.contains(":\t")
    }

    /// `|` or `>`, with YAML's optional chomping and indentation indicators
    /// (`|-`, `>+`, `|2`): the header of a block scalar, whose lines are
    /// never read as a plain scalar's.
    private static func isBlockScalarHeader(_ s: String) -> Bool {
        guard let first = s.first, first == "|" || first == ">" else { return false }
        let indicators = s.dropFirst()
        return indicators.count <= 2 && indicators.allSatisfy { "+-123456789".contains($0) }
    }

    /// `- item`, or a bare `-`: a block sequence entry, trimmed. `-x` is a
    /// scalar.
    private static func isItem(_ trimmed: String) -> Bool {
        trimmed == "-" || trimmed.hasPrefix("- ") || trimmed.hasPrefix("-\t")
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.hasPrefix("#")
    }

    /// The spaces and tabs a line starts with.
    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// Strips quotes only when the value both starts and ends with the same
    /// quote character, reading the escapes between them.
    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last,
              first == last, first == "\"" || first == "'"
        else { return s }

        let inner = String(s.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }

        var out = ""
        var escaped = false
        var iterator = inner.makeIterator()
        var pendingUnicode: [Character] = []
        var unicodeRemaining = 0

        while let c = iterator.next() {
            if unicodeRemaining > 0 {
                pendingUnicode.append(c)
                unicodeRemaining -= 1
                if unicodeRemaining == 0,
                   let code = UInt32(String(pendingUnicode), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                }
                continue
            }
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "u": pendingUnicode = []; unicodeRemaining = 4
                default: out.append(c)
                }
                escaped = false
                continue
            }
            if c == "\\" { escaped = true; continue }
            out.append(c)
        }
        return out
    }
}

extension String {
    /// Trailing whitespace removed, leading whitespace kept — the frontmatter
    /// delimiters must be flush left, but may carry trailing spaces.
    var trimmedTrailing: String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
