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
        links(in: text, inert: CodeMask.inertRanges(in: text))
    }

    /// `links(in:)`, with `CodeMask.inertRanges(in: text)` already found, as
    /// `LinkParse` finds it once for both kinds of link.
    static func links(in text: String, inert skip: [Range<String.Index>]) -> [Wikilink] {
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

    /// `%%[\s\S]*?%%` — Quartz's own pattern (`ofm.ts`), applied to the whole
    /// source before anything else reads it, so a comment can span lines.
    private static let commentRegex = try! NSRegularExpression(pattern: "%%[\\s\\S]*?%%")

    static func inertRanges(in text: String) -> [Range<String.Index>] {
        var ranges = commentRanges(in: text)
        var fences = Fences()

        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let (lineEnd, next) = MarkdownLineEnd.next(in: text, from: lineStart)
            defer { lineStart = next }

            if fences.isCode(text[lineStart..<lineEnd]) {
                ranges.append(lineStart..<lineEnd)
            } else {
                ranges.append(contentsOf: inlineInertRanges(in: text, line: lineStart..<lineEnd))
            }
        }
        return ranges
    }

    /// Which lines of a text are fenced code, read in order: the rule
    /// `inertRanges` masks fences by, in one place, so that a scan which
    /// stops early (`PreviewExcerpt.scope`) reads fences exactly as it does.
    struct Fences {
        private var inFence = false
        private var fenceMarker: Character = "`"
        private var fenceLength = 0

        init() {}

        /// Whether `line`, the text's next line, is code: a fence's opening or
        /// closing line, or a line inside one. An unterminated fence swallows
        /// the rest of the file, which is what a markdown parser does too.
        mutating func isCode(_ line: Substring) -> Bool {
            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }.count
                if run >= 3 {
                    if !inFence {
                        inFence = true
                        fenceMarker = marker
                        fenceLength = run
                        return true
                    }
                    if marker == fenceMarker, run >= fenceLength,
                       trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                        inFence = false
                        return true
                    }
                }
            }
            return inFence
        }
    }

    /// Every `%% … %%` in the text, across lines. Done on the whole text
    /// rather than per line: a comment that opens on one line and closes on
    /// another used to leave its wikilinks live, and the site never shows them.
    private static func commentRanges(in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        return commentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Range($0.range, in: text) }
    }

    /// Inline code spans within one line. (Comments are handled above.)
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

            i = text.index(after: i)
        }
        return ranges
    }
}

extension Character {
    /// A line ending as markdown-it reads one: `\n`, `\r\n` or a lone `\r`.
    /// `"\r\n"` is a single Character, so a search for `"\n"` alone reads a
    /// page saved with CRLF endings as one long line. The load's own walks
    /// find the same ends on bytes, with `MarkdownLineEnd`.
    var isMarkdownLineEnding: Bool { self == "\n" || self == "\r\n" || self == "\r" }
}

/// One inline markdown link to a wiki page: `[text](slug#anchor)`, or
/// `[text](<KEY - Title>)` when the destination holds spaces.
///
/// The wiki writes these on purpose wherever the display text holds math —
/// `[$k$-Linear assumption](bilinear-map-assumptions#k-linear-assumption)` —
/// because remark-math splits a wikilink whose alias has a `$` before the
/// wikilink pass sees it, while a markdown link's text is ordinary inline
/// content. Quartz's `CrawlLinks` resolves both forms with the same
/// `transformLink`, so here a markdown link becomes the `Wikilink` it stands
/// for and goes through `WikiIndex.resolve` like any other.
struct MarkdownLink: Equatable, Sendable {
    /// The destination as markdown-it parses it — the text between `<…>`, or
    /// the bare destination — with backslash escapes and character references
    /// decoded. It keys the render request's link map, because it is the
    /// string `ccwiki.js` recovers for each link it renders.
    let destination: String
    /// The whole `[text](destination)` in the source.
    let range: Range<String.Index>

    /// The link as the wikilink it stands for: the destination's path as the
    /// target and its fragment as the anchor. Quartz runs an href through
    /// `decodeURI` before resolving it, so `KEY%20-%20Title` names the same
    /// page as `<KEY - Title>`.
    var wikilink: Wikilink {
        let pieces = destination.split(
            separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = Self.decodeURI(String(pieces[0]))
        let fragment = pieces.count > 1 ? Self.decodeURI(String(pieces[1])) : ""
        return Wikilink(
            target: path,
            rawAnchor: fragment.isEmpty ? nil : "#" + fragment,
            alias: nil,
            isEmbed: false,
            range: range)
    }

    /// JavaScript's `decodeURI`: percent escapes decoded, except those of the
    /// characters a URI reserves (`;/?:@&=+$,#`), which stay escaped — so an
    /// encoded `#` never becomes an anchor. An escape that is malformed, or
    /// that decodes to bytes that are not UTF-8, leaves the text as written;
    /// `decodeURI` would throw there, and fail the site's build.
    static func decodeURI(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let reserved = Set(";/?:@&=+$,#".utf8)
        let bytes = Array(text.utf8)
        var decoded: [UInt8] = []
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "%") else {
                decoded.append(bytes[i])
                i += 1
                continue
            }
            guard i + 2 < bytes.count,
                  bytes[(i + 1)...(i + 2)].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
                  let value = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16)
            else { return text }
            if reserved.contains(value) {
                decoded.append(contentsOf: bytes[i...(i + 2)])
            } else {
                decoded.append(value)
            }
            i += 3
        }
        return String(bytes: decoded, encoding: .utf8) ?? text
    }
}

enum MarkdownLinkParser {

    /// Every inline markdown link in `text` whose destination is a wiki page,
    /// in source order.
    ///
    /// A link is wherever markdown-it, with `ccwiki.js`'s math and wikilink
    /// rules, parses one — so none inside code, a `%%comment%%` or math, none
    /// whose text holds a `[[wikilink]]` or another link, and an image is not
    /// one. Code and comments are masked exactly as `WikilinkParser` masks
    /// them, so the two parsers agree on what is inert.
    ///
    /// It finds the inert ranges and the wikilinks itself, as it did before
    /// `LinkParse` shared them (plans/efficiency.md, L2): the equivalence
    /// tests read it as the old code, so it must not go through `LinkParse`.
    static func links(in text: String) -> [MarkdownLink] {
        let inert = CodeMask.inertRanges(in: text)
        return LinkScanner(text, inert: inert, wikilinks: WikilinkParser.links(in: text)).links()
    }

    /// `links(in:)`, with `CodeMask.inertRanges(in: text)` and
    /// `WikilinkParser.links(in: text)` already found.
    static func links(
        in text: String, inert: [Range<String.Index>], wikilinks: [Wikilink]
    ) -> [MarkdownLink] {
        LinkScanner(text, inert: inert, wikilinks: wikilinks).links()
    }

    /// A URL (`https:`, `mailto:`) or a same-page `#anchor` is not a wiki link:
    /// Quartz's `CrawlLinks` leaves both alone, and so does the reader.
    static func isWikiDestination(_ destination: String) -> Bool {
        !destination.isEmpty && !destination.hasPrefix("#")
            && destination.range(
                of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil
    }

    /// `[!-/:-@[-`{-~]`: what a CommonMark backslash can escape.
    static func isASCIIPunctuation(_ value: UInt32) -> Bool {
        switch value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: true
        default: false
        }
    }

    /// markdown-it's `unescapeAll`: a destination's backslash escapes and
    /// character references, decoded.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") || text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count, isASCIIPunctuation(scalars[i + 1].value) {
                out.append(scalars[i + 1])
                i += 2
                continue
            }
            if c == "&", let semicolon = scalars[(i + 1)...].prefix(33).firstIndex(of: ";"),
               let decoded = characterReference(
                String(String.UnicodeScalarView(scalars[(i + 1)..<semicolon]))) {
                out.append(decoded)
                i = semicolon + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// The references a link destination plausibly holds: numeric ones, and
    /// the few named ones people write by hand. Any other name is kept as
    /// written, as markdown-it keeps a name it does not know.
    private static func characterReference(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value = digits.hasPrefix("x") || digits.hasPrefix("X")
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        return value.flatMap { Unicode.Scalar($0) }
    }
}

/// Both kinds of link in a text, from one pass over what is inert in it.
///
/// Taken one parser at a time, a text is read three times: each parser
/// finds the inert ranges, and the markdown-link scan finds the wikilinks
/// again, since a link's text cannot hold one. This finds the inert ranges
/// once and the wikilinks once, for what needs both kinds: a page's outgoing
/// links, and a render request's link map (plans/efficiency.md, L2).
enum LinkParse {

    static func links(in text: String) -> (wikilinks: [Wikilink], markdownLinks: [MarkdownLink]) {
        let inert = CodeMask.inertRanges(in: text)
        let wikilinks = WikilinkParser.links(in: text, inert: inert)
        return (wikilinks, MarkdownLinkParser.links(in: text, inert: inert, wikilinks: wikilinks))
    }
}

/// The scan behind `MarkdownLinkParser`: the parts of markdown-it's inline
/// parser that decide where a link starts and ends, run over the whole body.
///
/// It works on UTF-8 bytes because every delimiter involved is ASCII and the
/// offsets have to map back into the string exactly. What it models: code and
/// comments (through `CodeMask`), backslash escapes, `ccwiki.js`'s inline and
/// display math, wikilinks (tried before links, as in `ccwiki.js`), nested
/// brackets, images, and the destination and title grammar. Each block's
/// inline content is parsed alone, so math and links stop where a paragraph,
/// list item, heading or quote does. Not modelled, as `CodeMask` does not
/// model them either: indented code, raw HTML blocks, and code spans that
/// cross a line break.
private struct LinkScanner {

    private let text: String
    private let bytes: [UInt8]
    /// Bytes inside fenced code, a code span or a `%%comment%%`.
    private let inert: [Bool]
    /// Where each `[[wikilink]]` starts → where it ends.
    private let wikilinkEnds: [Int: Int]

    /// How deep link text may nest inside link text before the scan stops
    /// looking; markdown-it's own nesting limit is far above anything real.
    private static let maxDepth = 8

    /// What `parseLink` has found in the current block, by start offset.
    /// Without it every unmatched `[` rescans the brackets after it, nested up
    /// to `maxDepth` deep: twenty in one paragraph cost hundreds of thousands
    /// of label scans and forty some hundred million, which would freeze a
    /// render. markdown-it keeps the same search in bounds with a cache of its
    /// own (`state.cache`). A class, so the scan's methods stay non-mutating.
    private final class Cache {
        /// The `limit` of the block the entries belong to.
        var limit = -1
        /// Start offset → the depth the link was looked for at, and what was
        /// found. A search nearer `maxDepth` looks into fewer levels of
        /// nesting, so its answer is reused only at the same depth or deeper.
        var links: [Int: (depth: Int, link: (end: Int, destination: Range<Int>?)?)] = [:]
    }

    private let cache = Cache()

    /// `inertRanges` are `CodeMask.inertRanges(in: text)`, and `wikilinks`
    /// are `WikilinkParser.links(in: text)`.
    init(_ text: String, inert inertRanges: [Range<String.Index>], wikilinks: [Wikilink]) {
        let bytes = Array(text.utf8)
        let utf8 = text.utf8
        func offset(_ index: String.Index) -> Int {
            utf8.distance(from: utf8.startIndex, to: index)
        }

        var inert = [Bool](repeating: false, count: bytes.count)
        for range in inertRanges {
            for k in offset(range.lowerBound)..<offset(range.upperBound) { inert[k] = true }
        }
        var wikilinkEnds: [Int: Int] = [:]
        for link in wikilinks {
            wikilinkEnds[offset(link.range.lowerBound)] = offset(link.range.upperBound)
        }

        self.text = text
        self.bytes = bytes
        self.inert = inert
        self.wikilinkEnds = wikilinkEnds
    }

    func links() -> [MarkdownLink] {
        var result: [MarkdownLink] = []
        // The end of the inline content the scan is in, worked out once per
        // block rather than once per delimiter.
        var blockEnd = -1
        var i = 0
        while i < bytes.count {
            if inert[i] { i += 1; continue }
            if i > blockEnd { blockEnd = inlineEnd(from: i) }
            let c = bytes[i]

            if c == .backslash, i + 1 < bytes.count,
               MarkdownLinkParser.isASCIIPunctuation(UInt32(bytes[i + 1])) {
                i += 2
            } else if c == .dollar {
                i = skipMath(at: i, limit: blockEnd, allowsBlock: true)
            } else if c == .bang, i + 1 < bytes.count, bytes[i + 1] == .openBracket {
                // An embed or an image: it may sit inside link text, but it is
                // not a link itself.
                if let end = wikilinkEnds[i] {
                    i = end
                } else if let image = parseLink(at: i + 1, limit: blockEnd, depth: 0) {
                    i = image.end
                } else {
                    i += 1
                }
            } else if c == .openBracket {
                if let end = wikilinkEnds[i] {
                    i = end
                } else if let link = parseLink(at: i, limit: blockEnd, depth: 0) {
                    if let destination = link.destination {
                        let decoded = MarkdownLinkParser.unescape(
                            String(decoding: bytes[destination], as: UTF8.self))
                        if MarkdownLinkParser.isWikiDestination(decoded) {
                            result.append(MarkdownLink(
                                destination: decoded, range: index(i)..<index(link.end)))
                        }
                    }
                    i = link.end
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return result
    }

    private func index(_ offset: Int) -> String.Index {
        text.utf8.index(text.utf8.startIndex, offsetBy: offset)
    }

    // MARK: Links

    /// An inline link whose text opens at the `[` at `start`: where it ends,
    /// and the bytes of its destination — nil for an empty or invalid one,
    /// which markdown-it still renders as a link, to nowhere. Nil when
    /// markdown-it would not read a link here at all.
    ///
    /// A start is scanned again only when it is asked about at a shallower
    /// depth than before, so at most `maxDepth + 1` times a block: see `Cache`.
    private func parseLink(
        at start: Int, limit: Int, depth: Int
    ) -> (end: Int, destination: Range<Int>?)? {
        if cache.limit != limit {
            cache.limit = limit
            cache.links.removeAll(keepingCapacity: true)
        }
        if let known = cache.links[start], known.depth <= depth { return known.link }
        let link = scanLink(at: start, limit: limit, depth: depth)
        cache.links[start] = (depth: depth, link: link)
        return link
    }

    /// `parseLink` without the cache.
    private func scanLink(
        at start: Int, limit: Int, depth: Int
    ) -> (end: Int, destination: Range<Int>?)? {
        guard let labelEnd = parseLabel(at: start, limit: limit, depth: depth) else { return nil }
        var p = labelEnd + 1
        guard p < limit, bytes[p] == .openParen else { return nil }
        p = skipWhitespace(from: p + 1, limit: limit)
        guard p < limit else { return nil }

        var destination: Range<Int>?
        if bytes[p] == .lessThan {
            var q = p + 1
            while q < limit {
                let c = bytes[q]
                if c == .newline || c == .lessThan { break }
                if c == .greaterThan {
                    destination = (p + 1)..<q
                    p = q + 1
                    break
                }
                q += c == .backslash && q + 1 < limit ? 2 : 1
            }
        } else {
            var q = p
            var parens = 0
            var valid = true
            while q < limit {
                let c = bytes[q]
                if c == .space || c < 0x20 || c == 0x7F { break }
                if c == .backslash, q + 1 < limit {
                    // markdown-it 15 keeps a backslash before a space, and
                    // stops at the space.
                    q += bytes[q + 1] == .space ? 1 : 2
                    continue
                }
                if c == .openParen {
                    parens += 1
                    if parens > 32 { valid = false; break }
                }
                if c == .closeParen {
                    if parens == 0 { break }
                    parens -= 1
                }
                q += 1
            }
            if valid, q != p, parens == 0 {
                destination = p..<q
                p = q
            }
        }

        if destination != nil {
            // An optional title, which has to be set off by whitespace.
            let afterDestination = p
            p = skipWhitespace(from: p, limit: limit)
            if p < limit, p != afterDestination, let titleEnd = parseTitle(at: p, limit: limit) {
                p = skipWhitespace(from: titleEnd, limit: limit)
            }
        }
        guard p < limit, bytes[p] == .closeParen else { return nil }
        return (p + 1, destination)
    }

    /// The offset of the `]` that closes the link text opening at `start`, as
    /// markdown-it's `parseLinkLabel` finds it: code, math, escapes and images
    /// are stepped over, and a wikilink or a link inside the text means it is
    /// not link text at all.
    private func parseLabel(at start: Int, limit: Int, depth: Int) -> Int? {
        var level = 1
        var j = start + 1
        while j < limit {
            if inert[j] { j += 1; continue }
            let c = bytes[j]
            if c == .closeBracket {
                level -= 1
                if level == 0 { return j }
                j += 1
            } else if c == .backslash, j + 1 < limit,
                      MarkdownLinkParser.isASCIIPunctuation(UInt32(bytes[j + 1])) {
                j += 2
            } else if c == .dollar {
                j = skipMath(at: j, limit: limit, allowsBlock: false)
            } else if c == .bang, j + 1 < limit, bytes[j + 1] == .openBracket {
                if let end = wikilinkEnds[j] {
                    j = end
                } else if depth < Self.maxDepth,
                          let image = parseLink(at: j + 1, limit: limit, depth: depth + 1) {
                    j = image.end
                } else {
                    j += 1
                }
            } else if c == .openBracket {
                if wikilinkEnds[j] != nil { return nil }
                if depth < Self.maxDepth,
                   parseLink(at: j, limit: limit, depth: depth + 1) != nil {
                    return nil
                }
                level += 1
                j += 1
            } else {
                j += 1
            }
        }
        return nil
    }

    /// A link title, `"…"`, `'…'` or `(…)`: the offset just past it, or nil.
    private func parseTitle(at start: Int, limit: Int) -> Int? {
        let open = bytes[start]
        let close: UInt8
        if open == .quote || open == .apostrophe {
            close = open
        } else if open == .openParen {
            close = .closeParen
        } else {
            return nil
        }
        var q = start + 1
        while q < limit {
            let c = bytes[q]
            if c == close { return q + 1 }
            if c == .openParen, open == .openParen { return nil }
            q += c == .backslash ? 2 : 1
        }
        return nil
    }

    /// Spaces, tabs and line breaks, which markdown-it allows around a
    /// destination and a title.
    private func skipWhitespace(from start: Int, limit: Int) -> Int {
        var p = start
        while p < limit, bytes[p] == .space || bytes[p] == .tab || bytes[p] == .newline { p += 1 }
        return p
    }

    // MARK: Math

    /// Steps over the `$` run at `start`: past the math it opens, or past the
    /// run alone when it opens none. `ccwiki.js`'s `mathInline` (a port of
    /// micromark's), and its `mathBlock` for a `$$` that opens a line with no
    /// other `$` on it.
    private func skipMath(at start: Int, limit: Int, allowsBlock: Bool) -> Int {
        var end = start
        while end < bytes.count, bytes[end] == .dollar { end += 1 }
        // micromark's guard: a `$` right after an unescaped `$` opens nothing.
        if start > 0, bytes[start - 1] == .dollar {
            var backslashes = 0
            var k = start - 2
            while k >= 0, bytes[k] == .backslash {
                backslashes += 1
                k -= 1
            }
            if backslashes % 2 == 0 { return end }
        }
        let size = end - start
        if allowsBlock, size >= 2, isAtLineStart(start),
           !bytes[end..<lineEnd(from: end)].contains(UInt8.dollar) {
            return displayMathEnd(after: end, size: size)
        }
        // Inline math closes at the next run of exactly as many dollars.
        var k = end
        while k < limit {
            guard bytes[k] == .dollar else { k += 1; continue }
            let run = k
            while k < limit, bytes[k] == .dollar { k += 1 }
            if k - run == size { return k }
        }
        return end
    }

    /// The end of a display block whose opening run ends at `start`: the end
    /// of the first later line holding a run of at least `size` dollars and
    /// nothing else, or the end of the text when no line closes it.
    private func displayMathEnd(after start: Int, size: Int) -> Int {
        var lineStart = lineEnd(from: start) + 1
        while lineStart < bytes.count {
            let end = lineEnd(from: lineStart)
            var j = lineStart
            while j < end, bytes[j] == .space || bytes[j] == .tab { j += 1 }
            let run = j
            while j < end, bytes[j] == .dollar { j += 1 }
            if j - run >= size,
               bytes[j..<end].allSatisfy({ $0 == .space || $0 == .tab || $0 == .carriageReturn }) {
                return end
            }
            lineStart = end + 1
        }
        return bytes.count
    }

    // MARK: Blocks

    private func lineEnd(from start: Int) -> Int {
        var j = start
        while j < bytes.count, bytes[j] != .newline { j += 1 }
        return j
    }

    private func isAtLineStart(_ offset: Int) -> Bool {
        var j = offset - 1
        while j >= 0, bytes[j] == .space || bytes[j] == .tab { j -= 1 }
        return j < 0 || bytes[j] == .newline
    }

    /// Where the inline content holding `offset` ends: the end of its line,
    /// carried over the lines that continue the paragraph. markdown-it parses
    /// each block's inline content on its own, so neither math nor a link
    /// runs past it.
    private func inlineEnd(from offset: Int) -> Int {
        var end = lineEnd(from: offset)
        while end < bytes.count {
            let next = end + 1
            let nextEnd = lineEnd(from: next)
            if startsBlock(next..<nextEnd) { return end }
            end = nextEnd
        }
        return end
    }

    /// Whether a line ends the paragraph above it: a blank line, or one that
    /// opens a list item, a heading, a quote, a fence, display math, a setext
    /// underline or a thematic break. Indentation is not weighed, so the
    /// blocks of a nested list count too.
    private func startsBlock(_ line: Range<Int>) -> Bool {
        let isFill: (UInt8) -> Bool = { $0 == .space || $0 == .tab || $0 == .carriageReturn }
        if bytes[line].allSatisfy(isFill) { return true }

        var start = line.lowerBound
        while start < line.upperBound, bytes[start] == .space || bytes[start] == .tab { start += 1 }
        let first = bytes[start]

        // A list item: `-`, `*` or `+`, or one to nine digits and `.` or `)`,
        // then a space, a tab or the end of the line.
        var marker = start
        if first == .dash || first == .star || first == .plus {
            marker += 1
        } else {
            while marker < line.upperBound, marker - start < 9, isDigit(bytes[marker]) {
                marker += 1
            }
            if marker > start, marker < line.upperBound,
               bytes[marker] == .period || bytes[marker] == .closeParen {
                marker += 1
            } else {
                marker = start
            }
        }
        if marker > start,
           marker == line.upperBound || bytes[marker] == .space || bytes[marker] == .tab {
            return true
        }

        if first == .hash {
            var k = start
            while k < line.upperBound, bytes[k] == .hash { k += 1 }
            if k - start <= 6,
               k == line.upperBound || bytes[k] == .space || bytes[k] == .tab
                || bytes[k] == .carriageReturn {
                return true
            }
        }
        if first == .greaterThan { return true }
        if hasPrefix("```", at: start, before: line.upperBound)
            || hasPrefix("~~~", at: start, before: line.upperBound)
            || hasPrefix("$$", at: start, before: line.upperBound) {
            return true
        }

        // A setext underline or a thematic break, indented three spaces at most.
        var s = line.lowerBound
        while s < line.upperBound, bytes[s] == .space { s += 1 }
        if s - line.lowerBound <= 3, s < line.upperBound {
            let mark = bytes[s]
            let tail = bytes[s..<line.upperBound]
            if mark == .equals || mark == .dash {
                let run = tail.prefix { $0 == mark }.count
                if tail.dropFirst(run).allSatisfy(isFill) { return true }
            }
            if mark == .star || mark == .dash || mark == .underscore,
               tail.count(where: { $0 == mark }) >= 3,
               tail.allSatisfy({ $0 == mark || isFill($0) }) {
                return true
            }
        }
        return false
    }

    private func hasPrefix(_ prefix: String, at start: Int, before end: Int) -> Bool {
        let expected = Array(prefix.utf8)
        guard end - start >= expected.count else { return false }
        return bytes[start..<(start + expected.count)].elementsEqual(expected)
    }

    private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
}

private extension UInt8 {
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let tab = UInt8(ascii: "\t")
    static let space = UInt8(ascii: " ")
    static let bang = UInt8(ascii: "!")
    static let quote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let dollar = UInt8(ascii: "$")
    static let apostrophe = UInt8(ascii: "'")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let star = UInt8(ascii: "*")
    static let plus = UInt8(ascii: "+")
    static let dash = UInt8(ascii: "-")
    static let period = UInt8(ascii: ".")
    static let lessThan = UInt8(ascii: "<")
    static let equals = UInt8(ascii: "=")
    static let greaterThan = UInt8(ascii: ">")
    static let openBracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let closeBracket = UInt8(ascii: "]")
    static let underscore = UInt8(ascii: "_")
}
