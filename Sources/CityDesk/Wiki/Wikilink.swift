import Foundation

/// One `[[wikilink]]` occurrence, parsed with Quartz's own grammar
/// (`quartz/plugins/transformers/ofm.ts:123`).
///
/// ```
/// !?\[\[([^\[\]\|\#\\]+)?(#+[^\[\]\|\#\\]+)?(\\?\|[^\[\]\#]*)?\]\]
///  │      └ target            └ #anchor / #^blockref   └ |display
///  └ embed marker
/// ```
/// All three groups are optional, so `[[]]` matches with everything nil.
struct Wikilink: Equatable, Sendable {
    /// The raw target, before slugification. Empty for a same-page `[[#anchor]]`.
    var target: String
    /// The raw anchor including its leading `#`s, or `nil`.
    var rawAnchor: String?
    /// Display text, with the leading `|` already removed, or `nil`.
    var alias: String?
    /// `![[...]]` — an embed rather than a link.
    var isEmbed: Bool
    /// The range this link occupied in the source text.
    var range: Range<String.Index>

    /// `#^block-id` rather than `#heading`.
    var isBlockRef: Bool { rawAnchor?.hasPrefix("#^") ?? false }

    /// The anchor with its `#`s stripped and whitespace trimmed.
    var anchorText: String? {
        guard let raw = rawAnchor else { return nil }
        return String(raw.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }
}

enum WikilinkParser {

    // `##"..."##` rather than `#"..."#`: inside a single-hash raw string `\#`
    // is the escape introducer, and this pattern is full of `\#`.
    private static let regex = try! NSRegularExpression(
        pattern: ##"!?\[\[([^\[\]\|\#\\]+)?(#+[^\[\]\|\#\\]+)?(\\?\|[^\[\]\#]*)?\]\]"##)

    /// Every wikilink in `text`, skipping the regions Quartz skips.
    ///
    /// Quartz replaces wikilinks on the mdast, where `findAndReplace` does not
    /// descend into `code` / `inlineCode` nodes — so a `[[...]]` inside a fence
    /// or a backtick span is *not* a link. A naive regex sweep would invent
    /// links the site does not render, which matters here: the wiki is full of
    /// fenced `pseudocode` blocks containing `[` and `]`.
    ///
    /// `%%comments%%` are deleted before wikilinks are parsed (`ofm.ts:145`),
    /// so links inside them never exist either.
    static func links(in text: String) -> [Wikilink] {
        let skip = CodeMask.inertRanges(in: text)
        let ns = text as NSString

        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> Wikilink? in
                guard let range = Range(match.range, in: text) else { return nil }
                guard !skip.contains(where: { $0.overlaps(range) }) else { return nil }

                func group(_ i: Int) -> String? {
                    guard let r = Range(match.range(at: i), in: text) else { return nil }
                    return String(text[r])
                }

                var alias = group(3)
                if let raw = alias {
                    // The capture includes its leading `|` (or `\|`).
                    alias = String(raw.drop { $0 == "\\" }.dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                }

                return Wikilink(
                    target: (group(1) ?? "").trimmingCharacters(in: .whitespaces),
                    rawAnchor: group(2)?.trimmingCharacters(in: .whitespaces),
                    alias: alias,
                    isEmbed: text[range].hasPrefix("!"),
                    range: range)
            }
    }
}

/// Locates the regions of a markdown document that carry no inline markup:
/// fenced code blocks, inline code spans, and `%%obsidian comments%%`.
///
/// Returned as ranges rather than a blanked copy of the string so that
/// character offsets never have to line up between two representations.
enum CodeMask {

    static func inertRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []

        var inFence = false
        var fenceMarker: Character = "`"
        var fenceLength = 0

        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            defer { lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex }

            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }.count
                if run >= 3 {
                    if !inFence {
                        inFence = true
                        fenceMarker = marker
                        fenceLength = run
                        ranges.append(lineStart..<lineEnd)
                        continue
                    }
                    if marker == fenceMarker, run >= fenceLength,
                       trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                        inFence = false
                        ranges.append(lineStart..<lineEnd)
                        continue
                    }
                }
            }

            if inFence {
                ranges.append(lineStart..<lineEnd)
            } else {
                ranges.append(contentsOf: inlineInertRanges(in: text, line: lineStart..<lineEnd))
            }
        }

        // An unterminated fence swallows the rest of the file, which is what a
        // markdown parser does too.
        return ranges
    }

    /// Inline code spans and `%%comments%%` within one line.
    private static func inlineInertRanges(
        in text: String, line: Range<String.Index>
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = line.lowerBound

        while i < line.upperBound {
            let c = text[i]

            if c == "`" {
                let start = i
                var run = 0
                while i < line.upperBound, text[i] == "`" { run += 1; i = text.index(after: i) }

                // Scan for a closing run of exactly the same length.
                var j = i
                var closed = false
                while j < line.upperBound {
                    guard text[j] == "`" else { j = text.index(after: j); continue }
                    var closeRun = 0
                    while j < line.upperBound, text[j] == "`" {
                        closeRun += 1
                        j = text.index(after: j)
                    }
                    if closeRun == run {
                        ranges.append(start..<j)
                        i = j
                        closed = true
                        break
                    }
                }
                if !closed { ranges.append(start..<i) }
                continue
            }

            if c == "%", text.index(after: i) < line.upperBound,
               text[text.index(after: i)] == "%" {
                var j = text.index(i, offsetBy: 2)
                var end: String.Index?
                while j < line.upperBound {
                    let next = text.index(after: j)
                    if text[j] == "%", next < line.upperBound, text[next] == "%" {
                        end = text.index(after: next)
                        break
                    }
                    j = next
                }
                if let end {
                    ranges.append(i..<end)
                    i = end
                    continue
                }
            }

            i = text.index(after: i)
        }
        return ranges
    }
}
