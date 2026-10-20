// Verbatim copy of Sources/CCwiki/Wiki/{Wikilink,WikiPage,WikiIndex}.swift
// and Sources/CCwiki/Reader/RenderRequest.swift at 21df5d7 for equivalence
// tests. Do not edit; delete in the next batch.
//
// The parts the load path's efficiency work (plans/efficiency.md, track L)
// replaces, as they were, for `LoadEquivalenceCorpusTests` to hold the new
// code equal to. Inside `Legacy`, `CodeMask` and `WikilinkParser` name the
// copies below, so the copied code calls the old code it called. What it
// calls of the app is either unchanged by track L or, as with
// `MarkdownLinkParser.links(in:)`, a wrapper the track keeps. Where a
// method had to become a static function, the comment above it says what
// changed; nothing else did.

import Foundation
@testable import CCwiki

enum Legacy {}

// MARK: - Sources/CCwiki/Wiki/Wikilink.swift: WikilinkParser and CodeMask, whole

extension Legacy {

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

        /// `%%[\s\S]*?%%` — Quartz's own pattern (`ofm.ts`), applied to the whole
        /// source before anything else reads it, so a comment can span lines.
        private static let commentRegex = try! NSRegularExpression(pattern: "%%[\\s\\S]*?%%")

        static func inertRanges(in text: String) -> [Range<String.Index>] {
            var ranges = commentRanges(in: text)

            var inFence = false
            var fenceMarker: Character = "`"
            var fenceLength = 0

            var lineStart = text.startIndex
            while lineStart < text.endIndex {
                let lineEnd = text[lineStart...].firstIndex(where: \.isMarkdownLineEnding) ?? text.endIndex
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
}

// MARK: - Sources/CCwiki/Wiki/WikiPage.swift: headings()

extension Legacy {

    /// `WikiPage.headings()`, as a function of the page: `body` is
    /// `page.body`, and `Self.atxHeading` and `Heading` are `WikiPage`'s.
    static func headings(of page: WikiPage) -> [WikiPage.Heading] {
        let body = page.body
        var slugger = GithubSlugger()
        var result: [WikiPage.Heading] = []
        let inert = CodeMask.inertRanges(in: body)

        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(where: \.isMarkdownLineEnding) ?? body.endIndex
            defer {
                lineStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
            }

            guard let (level, raw) = WikiPage.atxHeading(body[lineStart..<lineEnd]) else { continue }
            // A `#` inside a fenced block is a comment, not a heading.
            guard !inert.contains(where: { $0.contains(lineStart) }) else { continue }

            let text = WikiPage.Heading.plainText(raw)
            guard !text.isEmpty else { continue }
            result.append(WikiPage.Heading(level: level, text: text, id: slugger.slug(text)))
        }
        return result
    }
}

// MARK: - Sources/CCwiki/Wiki/WikiIndex.swift: outgoing links and backlinks

extension Legacy {

    /// The links in a page body that name a wiki target, in source order: its
    /// `[[wikilinks]]`, and its markdown links to wiki pages as the wikilinks
    /// they stand for. The wiki writes the second kind wherever a link's text
    /// holds math, so a page reached only that way is still linked to.
    static func outgoingLinks(in body: String) -> [Wikilink] {
        let markdownLinks = MarkdownLinkParser.links(in: body).map(\.wikilink)
        return (WikilinkParser.links(in: body) + markdownLinks)
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Backlinks

    /// `WikiIndex.backlinkMap()`, as a function of the index: `pages` and
    /// `resolve` are `index`'s.
    static func backlinkMap(of index: WikiIndex) -> [String: [Backlink]] {
        var result: [String: [Backlink]] = [:]
        for page in index.pages.values.sorted(by: { $0.path < $1.path }) {
            var seen: Set<String> = []
            for link in Self.outgoingLinks(in: page.body) {
                guard case .page(let targetPath, _) = index.resolve(link, from: page.path),
                      targetPath != page.path,
                      seen.insert(targetPath).inserted
                else { continue }
                result[targetPath, default: []].append(
                    Backlink(sourcePath: page.path, context: Self.context(of: link, in: page.body)))
            }
        }
        return result
    }

    struct Backlink: Identifiable, Hashable, Sendable {
        let sourcePath: String
        /// The line the link appeared on, so the pane can show *why* the page
        /// links here rather than just that it does.
        let context: String

        var id: String { sourcePath + context }
    }

    /// The line a link appeared on, reduced to plain text. `plainText` is
    /// `WikiIndex`'s.
    ///
    /// The raw line is full of `[[wikilinks]]`, `$math$` and `_emphasis_`, and
    /// a backlinks pane that shows markup instead of prose is unreadable — the
    /// whole point of the pane is to tell you *why* another page links here.
    private static func context(of link: Wikilink, in body: String) -> String {
        var start = link.range.lowerBound
        while start > body.startIndex {
            let previous = body.index(before: start)
            if body[previous].isMarkdownLineEnding { break }
            start = previous
        }
        let end = body[link.range.upperBound...].firstIndex(where: \.isMarkdownLineEnding) ?? body.endIndex
        return WikiIndex.plainText(String(body[start..<end]))
    }
}

// MARK: - Sources/CCwiki/Reader/RenderRequest.swift: the request's link list

extension Legacy {

    /// The links `PageRenderer.request(for:)` collected from `markdown`, its
    /// body with the relation-meta line spliced in, as a function: these
    /// lines are the request's, with `return keyed` added.
    static func keyedLinks(in markdown: String) -> [(raw: String, link: Wikilink)] {
        // A wikilink is keyed by its raw `[[…]]` text, a markdown link by its
        // destination: the strings `ccwiki.js` looks each one up by.
        var keyed: [(raw: String, link: Wikilink)] = WikilinkParser.links(in: markdown).map {
            (raw: String(markdown[$0.range]), link: $0)
        }
        keyed += MarkdownLinkParser.links(in: markdown).map {
            (raw: $0.destination, link: $0.wikilink)
        }
        return keyed
    }
}
