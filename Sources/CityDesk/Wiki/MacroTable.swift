import Foundation

/// The site's KaTeX macro definitions, parsed out of the clone.
///
/// **Where the macros actually live.** `content/Glossary/latex-macros.md` is a
/// *documentation* page: a set of tables listing macro names and rendering each
/// one, e.g. `` `\classP` | $\classP$ ``. It contains no definitions. The
/// authoritative table is the TypeScript literal at the repo root:
///
/// ```ts
/// export const customMacros: Record<string, string> = {
///   // Caligraphic letters
///   "\\calA": "\\mathcal{A}",
///   ...
/// };
/// ```
///
/// which `quartz.config.ts` feeds to both `Plugin.Latex({renderEngine: "katex",
/// customMacros})` and `Plugin.Pseudocode({macros: customMacros})`. So CityDesk
/// parses `macros.ts` and hands the result straight to KaTeX's `macros` option.
///
/// The repo's own lint reads the same file (`scripts/lint.mjs:405`) and treats
/// it as the only legal place to define a macro, so this is a stable contract
/// rather than an implementation detail we are peeking at.
struct MacroTable: Sendable {

    /// `\calA` → `\mathcal{A}`, already unescaped from JS string literals.
    let macros: [String: String]
    /// Why the table is empty or short, for the "reading without custom macros"
    /// warning banner.
    let diagnostic: Diagnostic?

    enum Diagnostic: Equatable, Sendable {
        case fileMissing(path: String)
        case unreadable(path: String)
        case noObjectLiteral(path: String)
        case empty(path: String)

        var message: String {
            switch self {
            case .fileMissing(let p):
                "\(p) is missing from the clone."
            case .unreadable(let p):
                "\(p) could not be read as UTF-8."
            case .noObjectLiteral(let p):
                "No `customMacros` object literal found in \(p)."
            case .empty(let p):
                "\(p) parsed, but defined no macros."
            }
        }
    }

    static let empty = MacroTable(macros: [:], diagnostic: nil)

    var isEmpty: Bool { macros.isEmpty }

    // MARK: Loading

    /// Reads `macros.ts` from the root of a wiki clone.
    ///
    /// Never throws: every failure degrades to an empty table plus a
    /// diagnostic, so the reader still renders — just with raw `\calA` showing
    /// as an unknown control sequence instead of 𝒜.
    static func load(cloneRoot: URL) -> MacroTable {
        let url = cloneRoot.appending(path: "macros.ts")
        let display = "macros.ts"

        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return MacroTable(macros: [:], diagnostic: .fileMissing(path: display))
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return MacroTable(macros: [:], diagnostic: .unreadable(path: display))
        }
        return parse(source, path: display)
    }

    static func parse(_ source: String, path: String = "macros.ts") -> MacroTable {
        guard let body = objectLiteral(in: source) else {
            return MacroTable(macros: [:], diagnostic: .noObjectLiteral(path: path))
        }
        let macros = entries(in: body)
        return MacroTable(
            macros: macros,
            diagnostic: macros.isEmpty ? .empty(path: path) : nil)
    }

    // MARK: Parsing

    /// The contents of the first `{...}` that follows `customMacros`, with
    /// braces balanced so a `}` inside a string or a nested object does not
    /// terminate it early.
    private static func objectLiteral(in source: String) -> Substring? {
        guard let anchor = source.range(of: "customMacros") else { return nil }

        var i = anchor.upperBound
        while i < source.endIndex, source[i] != "{" { i = source.index(after: i) }
        guard i < source.endIndex else { return nil }

        let start = source.index(after: i)
        var depth = 1
        var j = start
        while j < source.endIndex {
            let c = source[j]
            if c == "\"" || c == "'" || c == "`" {
                j = skipStringLiteral(source, from: j)
                continue
            }
            if c == "/", source.index(after: j) < source.endIndex {
                let next = source[source.index(after: j)]
                if next == "/" || next == "*" {
                    j = skipComment(source, from: j)
                    continue
                }
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { return source[start..<j] }
            }
            j = source.index(after: j)
        }
        return nil
    }

    /// `"key": "value"` pairs, in order, skipping comments and tolerating
    /// trailing commas and any quote style TypeScript allows.
    private static func entries(in body: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var pending: String?
        var i = body.startIndex

        while i < body.endIndex {
            let c = body[i]

            if c == "/", body.index(after: i) < body.endIndex,
               body[body.index(after: i)] == "/" || body[body.index(after: i)] == "*" {
                i = skipComment(body.base, from: i)
                continue
            }

            if c == "\"" || c == "'" || c == "`" {
                let end = skipStringLiteral(body.base, from: i)
                let literal = body.base[i..<end]
                let text = unescape(literal.dropFirst().dropLast())
                if let key = pending {
                    result[key] = text
                    pending = nil
                } else {
                    pending = text
                }
                i = end
                continue
            }

            // A nested object or array would confuse the key/value pairing;
            // the real file has neither, so bail out of the pending key.
            if c == "{" || c == "[" { pending = nil }

            i = body.index(after: i)
        }
        return result
    }

    /// Index just past the closing quote of the string literal starting at `i`.
    private static func skipStringLiteral(_ s: String, from i: String.Index) -> String.Index {
        let quote = s[i]
        var j = s.index(after: i)
        while j < s.endIndex {
            if s[j] == "\\" {
                j = s.index(j, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
                continue
            }
            if s[j] == quote { return s.index(after: j) }
            j = s.index(after: j)
        }
        return s.endIndex
    }

    private static func skipComment(_ s: String, from i: String.Index) -> String.Index {
        let second = s.index(after: i)
        guard second < s.endIndex else { return s.endIndex }

        if s[second] == "/" {
            return s[second...].firstIndex(of: "\n").map { s.index(after: $0) } ?? s.endIndex
        }
        var j = s.index(after: second)
        while j < s.endIndex {
            let next = s.index(after: j)
            if s[j] == "*", next < s.endIndex, s[next] == "/" { return s.index(after: next) }
            j = next
        }
        return s.endIndex
    }

    /// JavaScript string-literal escapes. The important one by far is `\\` →
    /// `\`, which is how every macro in the file is written.
    static func unescape(_ s: Substring) -> String {
        guard s.contains("\\") else { return String(s) }

        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "\\", s.index(after: i) < s.endIndex else {
                out.append(s[i])
                i = s.index(after: i)
                continue
            }
            let next = s[s.index(after: i)]
            var advance = 2
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{C}")
            case "v": out.append("\u{B}")
            case "0": out.append("\0")
            case "u":
                let hexStart = s.index(i, offsetBy: 2)
                if let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex),
                   let code = UInt32(s[hexStart..<hexEnd], radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                    advance = 6
                } else {
                    out.append(next)
                }
            default:
                out.append(next)
            }
            i = s.index(i, offsetBy: advance, limitedBy: s.endIndex) ?? s.endIndex
        }
        return out
    }

    // MARK: Handoff to KaTeX

    /// The table as the JSON object KaTeX's `macros` option expects.
    /// Sorted so the generated page HTML is stable between runs.
    func katexJSON() -> String {
        let pairs = macros.keys.sorted().map { key in
            "\(jsonString(key)):\(jsonString(macros[key]!))"
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
