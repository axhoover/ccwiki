import Foundation

/// The subset of YAML that cryptology.city's frontmatter actually uses.
///
/// The app takes no SPM dependencies, so this is a hand-written parser. It is
/// not a YAML implementation and does not try to be — it handles exactly the
/// constructs the corpus and the repo's own lint permit:
///
/// - `key: scalar`, splitting on the **first** colon (345 lines carry a colon
///   inside the value — every `source:` URL and every `cryptobib_key`)
/// - block sequences (`aliases:` then `  - item`) and the inline empty `[]`
/// - literal block scalars (`bibtex: |`), preserving interior newlines
/// - double- and single-quoted scalars, unquoted only when both ends match
/// - full-line `#` comments (taught to agents by `Templates/Reference.md`)
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

    func list(_ key: String) -> [String] {
        switch fields[key] {
        case .list(let items): items
        case .string(let s): [s]
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
            let rest = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if ["|", "|-", "|+", ">", ">-", ">+"].contains(rest) {
                let folded = rest.hasPrefix(">")
                let (value, next) = Self.blockScalar(lines, from: i + 1, folded: folded)
                fm.fields[key] = .string(value)
                i = next
                continue
            }

            if rest.isEmpty {
                let (items, next) = Self.blockSequence(lines, from: i + 1)
                fm.fields[key] = items.isEmpty ? .null : .list(items)
                i = next
                continue
            }

            if rest == "[]" {
                fm.fields[key] = .list([])
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                fm.fields[key] = .list(Self.flowSequence(rest))
            } else {
                fm.fields[key] = .string(Self.unquote(rest))
            }
            i += 1
        }

        guard found else { return Frontmatter(bodyStart: text.startIndex) }

        // Map the line index back into the *original* text. Counting from the
        // normalized copy would drift on CRLF input, so walk the original.
        var idx = text.startIndex
        var remaining = i
        while remaining > 0, idx < text.endIndex {
            if let nl = text[idx...].firstIndex(of: "\n") {
                idx = text.index(after: nl)
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

    /// A block sequence: consecutive `  - item` lines.
    private static func blockSequence(_ lines: [String], from start: Int) -> ([String], Int) {
        var items: [String] = []
        var i = start
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t"), trimmed.hasPrefix("-") else {
                break
            }
            let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            items.append(unquote(item))
            i += 1
        }
        return (items, i)
    }

    /// `[a, "b, c"]` — split on commas that are not inside quotes.
    private static func flowSequence(_ s: String) -> [String] {
        let inner = s.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character?

        for c in inner {
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                items.append(unquote(current.trimmingCharacters(in: .whitespaces)))
                current = ""
            } else {
                current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { items.append(unquote(last)) }
        return items
    }

    /// Strips quotes only when the value both starts and ends with the same
    /// quote character. Never strips a trailing `# comment`: doing so would
    /// mangle `title: "#P"` and every `source:` URL with a fragment.
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
