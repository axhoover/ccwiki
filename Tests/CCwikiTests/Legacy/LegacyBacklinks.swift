import Foundation
@testable import CCwiki

// Verbatim copy of the backlinks path at 46685be (the code D1 timed at
// 680 ms) for M0's old-against-new timing, plans/efficiency.md §2.3:
// Wikilink.swift's CodeMask, WikilinkParser, MarkdownLink, MarkdownLinkParser
// and LinkScanner; WikiIndex.swift's backlinkMap, outgoingLinks, resolve and
// context; GithubSlugger.slug; and QuartzSlug's splitAnchor and
// transformInternalLink, which call it. 21df5d7's four changes to the path
// are here too, as 21df5d7 wrote them, each behind a switch. Do not edit;
// delete in the next batch.

/// Code as it stood before a change, kept in the tests only, to run old and
/// new on the same inputs in one process (plans/efficiency.md §2.1).
enum Legacy {}

extension Legacy {

    /// `WikiIndex.backlinkMap()` as 46685be built it, with 21df5d7's four
    /// changes to it each behind a switch: so one run times the old path,
    /// each change alone and all four, over the same library
    /// (plans/efficiency.md §1.3).
    struct D1Backlinks {

        /// What 21df5d7 changed on the path, one switch each.
        struct Changes: OptionSet, Hashable, Sendable {
            let rawValue: Int

            /// `CodeMask.inertRanges` finds each line end with
            /// `firstIndex(where: \.isMarkdownLineEnding)`, not
            /// `firstIndex(of: "\n")`.
            static let codeMaskLineEnds = Changes(rawValue: 1 << 0)
            /// `context` walks back and forward to `\n`, `\r\n` or `\r`, not
            /// `\n` alone.
            static let contextLineEnds = Changes(rawValue: 1 << 1)
            /// `GithubSlugger.slug` lowercases each scalar and keeps it by its
            /// Unicode properties, not by its general category.
            static let sluggerProperties = Changes(rawValue: 1 << 2)
            /// `resolve` splits the target into segments, for a leading `.`
            /// or `..`, and sends the empty slug to the home page.
            static let resolveSegments = Changes(rawValue: 1 << 3)

            /// 21df5d7's path.
            static let all: Changes = [
                .codeMaskLineEnds, .contextLineEnds, .sluggerProperties, .resolveSegments,
            ]
        }

        /// `WikiIndex.Backlink` as both commits store it.
        struct Backlink: Equatable, Sendable {
            let sourcePath: String
            let context: String
        }

        let changes: Changes
        private let pages: [String: WikiPage]
        private let slugToPath: [String: String]
        private let aliasOwners: [String: [String]]
        private let basenameIndex: [String: [String]]
        private let folders: Set<String>

        /// The path over `index`'s pages. `WikiIndex` keeps its tables
        /// private, so they are built again here as 21df5d7's `assemble`
        /// builds them, from the files `overlaying` lists. They are the index
        /// phase's, not the backlinks phase's: 21df5d7 changed them only for
        /// an alias ending in `.md`.
        init(index: WikiIndex, changes: Changes) {
            let files = Set(index.pages.keys).union(index.assets.values).sorted()
            var slugToPath: [String: String] = [:]
            var allSlugs: [String] = []
            var seen: Set<String> = []
            var folders: Set<String> = []

            func appendSlug(_ slug: String) {
                if seen.insert(slug).inserted { allSlugs.append(slug) }
            }

            for path in files {
                let slug = QuartzSlug.slugifyFilePath(path)
                appendSlug(slug)
                if slugToPath[slug] == nil { slugToPath[slug] = path }

                var segments = slug.components(separatedBy: "/")
                segments.removeLast()
                var prefix: [String] = []
                for segment in segments {
                    prefix.append(segment)
                    folders.insert(prefix.joined(separator: "/"))
                }
            }

            var aliasOwners: [String: [String]] = [:]
            for path in files.filter({ $0.hasSuffix(".md") }).sorted() {
                guard let page = index.pages[path] else { continue }
                for alias in page.aliases where !alias.isEmpty {
                    let slug = QuartzSlug.slugifyFilePath(alias + ".md")
                    appendSlug(slug)
                    aliasOwners[slug, default: []].append(path)
                }
            }

            var basenameIndex: [String: [String]] = [:]
            for slug in allSlugs {
                basenameIndex[QuartzSlug.lastSegment(slug), default: []].append(slug)
            }

            self.changes = changes
            self.pages = index.pages
            self.slugToPath = slugToPath
            self.aliasOwners = aliasOwners.mapValues { $0.sorted() }
            self.basenameIndex = basenameIndex
            self.folders = folders
        }

        // MARK: WikiIndex.swift

        /// path → the paths of every page that links to it.
        func backlinkMap() -> [String: [Backlink]] {
            var result: [String: [Backlink]] = [:]
            for page in pages.values.sorted(by: { $0.path < $1.path }) {
                var seen: Set<String> = []
                for link in outgoingLinks(in: page.body) {
                    guard case .page(let targetPath, _) = resolve(link, from: page.path),
                          targetPath != page.path,
                          seen.insert(targetPath).inserted
                    else { continue }
                    result[targetPath, default: []].append(
                        Backlink(sourcePath: page.path, context: context(of: link, in: page.body)))
                }
            }
            return result
        }

        /// The links in a page body that name a wiki target, in source order.
        func outgoingLinks(in body: String) -> [Wikilink] {
            let markdown = markdownLinks(in: body).map(\.wikilink)
            return (wikilinks(in: body) + markdown)
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
        }

        /// Resolve one wikilink appearing on the page at `sourcePath`.
        func resolve(_ link: Wikilink, from sourcePath: String) -> WikiIndex.Target {
            let target = link.target

            if target.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .external(url: target)
            }

            // ofm.ts:213 slugifies the anchor in place, before resolution.
            let (fp, anchor) = splitAnchor(target + (link.rawAnchor ?? ""))
            let displayAnchor: String
            if anchor.isEmpty {
                displayAnchor = ""
            } else {
                let bare = String(anchor.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                displayAnchor = "#" + (link.isBlockRef ? "^" : "") + bare
            }

            if fp.isEmpty {
                guard !displayAnchor.isEmpty else { return .unresolved(reason: "empty link") }
                return .samePage(anchor: String(displayAnchor.dropFirst()))
            }

            // An embed addresses the file itself; the anchor is not part of the URL.
            let linkText = link.isEmbed ? fp : fp + displayAnchor

            let relative = transformInternalLink(linkText)
            let canonical = QuartzSlug.stripSlashes(String(relative.dropFirst()))
            let (targetCanonical, targetAnchor) = splitAnchor(canonical)

            if changes.contains(.resolveSegments) {
                return resolvedBySegments(targetCanonical: targetCanonical, targetAnchor: targetAnchor)
            }

            let matches = basenameIndex[targetCanonical] ?? []
            let slug = matches.count == 1 ? matches[0] : targetCanonical
            let anchorText = targetAnchor.isEmpty ? nil : String(targetAnchor.dropFirst())

            if let path = slugToPath[slug] {
                return path.hasSuffix(".md")
                    ? .page(path: path, anchor: anchorText)
                    : .asset(path: path)
            }
            if let owners = aliasOwners[slug], let owner = owners.first {
                return .page(path: owner, anchor: anchorText)
            }
            if let path = slugToPath[slug + "/index"] {
                return .page(path: path, anchor: anchorText)
            }
            if folders.contains(slug) {
                return .folder(slug: slug)
            }
            return .unresolved(reason: "no page, alias or folder named “\(targetCanonical)”")
        }

        /// The rest of `resolve` as 21df5d7 wrote it.
        private func resolvedBySegments(
            targetCanonical: String, targetAnchor: String
        ) -> WikiIndex.Target {
            // A relative target keeps its `.` and `..` segments at the front
            // (`../Primitives/prf` → `./Primitives/prf`), and no slug starts with
            // one. The site joins it to the path up to the root and lets URL
            // resolution (`CrawlLinks`) drop them, so it names the slug after
            // them. Never by basename: the site matches the target with its dots
            // still on, which no file name equals.
            let segments = targetCanonical.split(separator: "/", omittingEmptySubsequences: false)
            let isRelative = segments.first.map(Self.isDotSegment) ?? false
            let lookup = isRelative
                ? segments.drop(while: Self.isDotSegment).joined(separator: "/")
                : targetCanonical

            let matches = isRelative ? [] : (basenameIndex[lookup] ?? [])
            let slug = matches.count == 1 ? matches[0] : lookup
            let anchorText = targetAnchor.isEmpty ? nil : String(targetAnchor.dropFirst())

            // `[[index]]`, `[[/]]` and `[[./]]` canonicalize to the empty slug,
            // which `transformLink`'s fallback joins to `./`: the home page. So
            // does a relative `..` or `../`, which climbs to the root.
            if slug.isEmpty, let path = slugToPath["index"], path.hasSuffix(".md") {
                return .page(path: path, anchor: anchorText)
            }
            if let path = slugToPath[slug] {
                return path.hasSuffix(".md")
                    ? .page(path: path, anchor: anchorText)
                    : .asset(path: path)
            }
            if let owners = aliasOwners[slug], let owner = owners.first {
                return .page(path: owner, anchor: anchorText)
            }
            if let path = slugToPath[slug + "/index"] {
                return .page(path: path, anchor: anchorText)
            }
            if folders.contains(slug) {
                return .folder(slug: slug)
            }
            return .unresolved(reason: "no page, alias or folder named “\(lookup)”")
        }

        /// `.` or `..`: a segment URL resolution removes.
        private static func isDotSegment(_ segment: Substring) -> Bool {
            segment == "." || segment == ".."
        }

        /// The line a link appeared on, reduced to plain text.
        private func context(of link: Wikilink, in body: String) -> String {
            var start = link.range.lowerBound
            if changes.contains(.contextLineEnds) {
                while start > body.startIndex {
                    let previous = body.index(before: start)
                    if body[previous].isMarkdownLineEndingAt21df5d7 { break }
                    start = previous
                }
                let end = body[link.range.upperBound...]
                    .firstIndex(where: \.isMarkdownLineEndingAt21df5d7) ?? body.endIndex
                return WikiIndex.plainText(String(body[start..<end]))
            }
            while start > body.startIndex {
                let previous = body.index(before: start)
                if body[previous] == "\n" { break }
                start = previous
            }
            let end = body[link.range.upperBound...].firstIndex(of: "\n") ?? body.endIndex
            return WikiIndex.plainText(String(body[start..<end]))
        }

        // MARK: QuartzSlug.swift, the two functions that slug an anchor

        /// Splits `page#anchor` into its path and its already-slugified anchor.
        private func splitAnchor(_ link: String) -> (path: String, anchor: String) {
            let parts = link.components(separatedBy: "#")
            let fp = parts[0]
            let rawAnchor: String? = parts.count > 1 ? parts[1] : nil

            if fp.hasSuffix(".pdf") {
                return (fp, rawAnchor.map { "#" + $0 } ?? "")
            }
            return (fp, rawAnchor.map { "#" + slug($0) } ?? "")
        }

        /// Canonicalizes a raw link target into a `RelativeURL` rooted at `.`.
        private func transformInternalLink(_ link: String) -> String {
            let (fplike, anchor) = splitAnchor(link)
            let folderPath = QuartzSlug.isFolderPath(fplike)

            let segments = fplike.components(separatedBy: "/").filter { !$0.isEmpty }
            let prefix = segments.filter(QuartzSlug.isRelativeSegment).joined(separator: "/")
            let fp = segments.filter { !QuartzSlug.isRelativeSegment($0) }.joined(separator: "/")

            let simpleSlug = QuartzSlug.simplifySlug(QuartzSlug.slugifyFilePath(fp))
            let joined = QuartzSlug.joinSegments(
                QuartzSlug.stripSlashes(prefix), QuartzSlug.stripSlashes(simpleSlug))
            return Self.addRelativeToStart(joined) + (folderPath ? "/" : "") + anchor
        }

        private static func addRelativeToStart(_ s: String) -> String {
            if s.isEmpty { return "." }
            return s.hasPrefix(".") ? s : QuartzSlug.joinSegments(".", s)
        }

        // MARK: GithubSlugger.swift

        /// The non-deduplicating slug, used for link anchors.
        private func slug(_ value: String) -> String {
            changes.contains(.sluggerProperties)
                ? Self.slugByProperties(value) : Self.slugByCategory(value)
        }

        /// 46685be's: the deleted set is generated upstream from Unicode
        /// categories: letters, marks and numbers survive, along with space,
        /// `-` and `_`.
        private static func slugByCategory(_ value: String) -> String {
            var out = String.UnicodeScalarView()
            out.reserveCapacity(value.unicodeScalars.count)

            for scalar in value.lowercased().unicodeScalars {
                if scalar == " " {
                    out.append("-")
                } else if survivesByCategory(scalar) {
                    out.append(scalar)
                }
            }
            return String(out)
        }

        private static func survivesByCategory(_ scalar: Unicode.Scalar) -> Bool {
            if scalar == "-" || scalar == "_" { return true }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }

        /// 21df5d7's: the kept set is generated upstream from Unicode 13.0.
        private static func slugByProperties(_ value: String) -> String {
            let scalars = Array(value.unicodeScalars)
            var out = String.UnicodeScalarView()
            out.reserveCapacity(scalars.count)

            for (index, scalar) in scalars.enumerated() {
                // JavaScript's `toLowerCase`: Swift's `lowercased()` maps each
                // scalar the same way, except a word-final capital sigma.
                let lower = scalar == "\u{03A3}" && isFinalSigma(scalars, at: index)
                    ? "\u{03C2}" : scalar.properties.lowercaseMapping
                for mapped in lower.unicodeScalars {
                    if mapped == " " {
                        out.append("-")
                    } else if survivesByProperties(mapped) {
                        out.append(mapped)
                    }
                }
            }
            return String(out)
        }

        private static func survivesByProperties(_ scalar: Unicode.Scalar) -> Bool {
            if scalar == "-" { return true }
            let properties = scalar.properties
            // Assigned after the regex was generated, so not in its kept set.
            guard let age = properties.age, (age.major, age.minor) <= (13, 0) else { return false }
            if properties.isAlphabetic { return true }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .connectorPunctuation:
                return true
            default:
                return false
            }
        }

        /// Unicode's Final_Sigma condition, as ICU tests it for `toLowerCase`.
        private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
            let before = scalars[..<index].reversed().first { !$0.properties.isCaseIgnorable }
            let after = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }
            return before?.properties.isCased == true && after?.properties.isCased != true
        }

        // MARK: Wikilink.swift: WikilinkParser

        // `##"..."##` rather than `#"..."#`: inside a single-hash raw string `\#`
        // is the escape introducer, and this pattern is full of `\#`.
        private static let wikilinkRegex = try! NSRegularExpression(
            pattern: ##"!?\[\[([^\[\]\|\#\\]+)?(#+[^\[\]\|\#\\]+)?(\\?\|[^\[\]\#]*)?\]\]"##)

        /// Every wikilink in `text`, skipping the regions Quartz skips.
        fileprivate func wikilinks(in text: String) -> [Wikilink] {
            let skip = inertRanges(in: text)
            let ns = text as NSString

            return Self.wikilinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
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

        // MARK: Wikilink.swift: CodeMask

        /// `%%[\s\S]*?%%` — Quartz's own pattern (`ofm.ts`), applied to the whole
        /// source before anything else reads it, so a comment can span lines.
        private static let commentRegex = try! NSRegularExpression(pattern: "%%[\\s\\S]*?%%")

        /// Fenced code, inline code spans and `%%comments%%`.
        fileprivate func inertRanges(in text: String) -> [Range<String.Index>] {
            var ranges = Self.commentRanges(in: text)
            let keyPathLineEnds = changes.contains(.codeMaskLineEnds)

            var inFence = false
            var fenceMarker: Character = "`"
            var fenceLength = 0

            var lineStart = text.startIndex
            while lineStart < text.endIndex {
                let lineEnd: String.Index
                if keyPathLineEnds {
                    lineEnd = text[lineStart...].firstIndex(where: \.isMarkdownLineEndingAt21df5d7)
                        ?? text.endIndex
                } else {
                    lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
                }
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
                    ranges.append(contentsOf: Self.inlineInertRanges(in: text, line: lineStart..<lineEnd))
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

        // MARK: Wikilink.swift: MarkdownLink and MarkdownLinkParser

        /// `MarkdownLinkParser.links(in:)`: every inline markdown link in
        /// `text` whose destination is a wiki page, in source order.
        fileprivate func markdownLinks(in text: String) -> [MarkdownLink] {
            D1LinkScanner(text, parser: self).links()
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
        fileprivate struct MarkdownLink {
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
            fileprivate static func decodeURI(_ text: String) -> String {
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

        /// A URL (`https:`, `mailto:`) or a same-page `#anchor` is not a wiki link:
        /// Quartz's `CrawlLinks` leaves both alone, and so does the reader.
        fileprivate static func isWikiDestination(_ destination: String) -> Bool {
            !destination.isEmpty && !destination.hasPrefix("#")
                && destination.range(
                    of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil
        }

        /// `[!-/:-@[-`{-~]`: what a CommonMark backslash can escape.
        fileprivate static func isASCIIPunctuation(_ value: UInt32) -> Bool {
            switch value {
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: true
            default: false
            }
        }

        /// markdown-it's `unescapeAll`: a destination's backslash escapes and
        /// character references, decoded.
        fileprivate static func unescape(_ text: String) -> String {
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
private struct D1LinkScanner {

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

    init(_ text: String, parser: Legacy.D1Backlinks) {
        let bytes = Array(text.utf8)
        let utf8 = text.utf8
        func offset(_ index: String.Index) -> Int {
            utf8.distance(from: utf8.startIndex, to: index)
        }

        var inert = [Bool](repeating: false, count: bytes.count)
        for range in parser.inertRanges(in: text) {
            for k in offset(range.lowerBound)..<offset(range.upperBound) { inert[k] = true }
        }
        var wikilinkEnds: [Int: Int] = [:]
        for link in parser.wikilinks(in: text) {
            wikilinkEnds[offset(link.range.lowerBound)] = offset(link.range.upperBound)
        }

        self.text = text
        self.bytes = bytes
        self.inert = inert
        self.wikilinkEnds = wikilinkEnds
    }

    func links() -> [Legacy.D1Backlinks.MarkdownLink] {
        var result: [Legacy.D1Backlinks.MarkdownLink] = []
        // The end of the inline content the scan is in, worked out once per
        // block rather than once per delimiter.
        var blockEnd = -1
        var i = 0
        while i < bytes.count {
            if inert[i] { i += 1; continue }
            if i > blockEnd { blockEnd = inlineEnd(from: i) }
            let c = bytes[i]

            if c == .backslash, i + 1 < bytes.count,
               Legacy.D1Backlinks.isASCIIPunctuation(UInt32(bytes[i + 1])) {
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
                        let decoded = Legacy.D1Backlinks.unescape(
                            String(decoding: bytes[destination], as: UTF8.self))
                        if Legacy.D1Backlinks.isWikiDestination(decoded) {
                            result.append(Legacy.D1Backlinks.MarkdownLink(
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
                      Legacy.D1Backlinks.isASCIIPunctuation(UInt32(bytes[j + 1])) {
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

private extension Character {
    /// 21df5d7's `isMarkdownLineEnding`: a line ending as markdown-it reads
    /// one, `\n`, `\r\n` or a lone `\r`.
    var isMarkdownLineEndingAt21df5d7: Bool { self == "\n" || self == "\r\n" || self == "\r" }
}
