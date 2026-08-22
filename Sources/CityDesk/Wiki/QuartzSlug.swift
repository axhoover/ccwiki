import Foundation

/// A line-by-line port of Quartz's `quartz/util/path.ts`.
///
/// The wiki is published by Quartz, so CityDesk only shows the same links the
/// website shows if it slugifies exactly the way Quartz does. That means
/// porting the real functions rather than approximating them — including the
/// parts that look like bugs (see `splitAnchor`, which silently drops
/// everything after a second `#`).
///
/// There are two *different* slugifiers in play and they must never be mixed:
///
/// - `QuartzSlug.sluggify` handles **file paths**. It is case-preserving and
///   strips almost nothing.
/// - `GithubSlugger` handles **heading anchors**. It lowercases and deletes
///   nearly all punctuation.
///
/// Verified against `quartz/util/path.test.ts`; those assertions are ported
/// wholesale into `QuartzSlugTests`.
enum QuartzSlug {

    // MARK: - sluggify (path.ts:69)

    /// JavaScript's `\s` character class, which is what Quartz's
    /// `.replace(/\s/g, "-")` matches. Deliberately *not* Swift's
    /// `.whitespaces`, which has a different membership.
    private static let jsWhitespace: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
        "\u{00A0}", "\u{1680}",
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
        "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}",
        "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
    ]

    /// Per `/`-separated segment, in this exact order: whitespace → `-`,
    /// `&` → `-and-`, `%` → `-percent`, `?` deleted, `#` deleted. Then rejoin
    /// with `/` and drop **one** trailing slash.
    ///
    /// Everything else survives verbatim — case, parentheses, commas,
    /// apostrophes, `!`, `=`, `+`, `.`, and all non-ASCII.
    static func sluggify(_ s: String) -> String {
        var joined = s
            .components(separatedBy: "/")
            .map(sluggifySegment)
            .joined(separator: "/")
        if joined.hasSuffix("/") { joined.removeLast() }
        return joined
    }

    private static func sluggifySegment(_ segment: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(segment.unicodeScalars.count)
        for scalar in segment.unicodeScalars {
            if jsWhitespace.contains(scalar) {
                out.append("-")
            } else {
                switch scalar {
                case "&": out.append(contentsOf: "-and-".unicodeScalars)
                case "%": out.append(contentsOf: "-percent".unicodeScalars)
                case "?", "#": break  // deleted
                default: out.append(scalar)
                }
            }
        }
        return String(out)
    }

    // MARK: - Small helpers (path.ts:300–360)

    /// `getFileExtension` — matches `/\.[A-Za-z0-9]+$/`, dot included.
    /// `foo.tar.gz` → `.gz`; `foo.` → nil; `P != NP` → nil.
    static func fileExtension(_ s: String) -> String? {
        guard let dot = s.lastIndex(of: ".") else { return nil }
        let tail = s[s.index(after: dot)...]
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return String(s[dot...])
    }

    /// Strips **one** leading `/`, and unless `onlyStripPrefix`, **one**
    /// trailing `/`.
    static func stripSlashes(_ s: String, onlyStripPrefix: Bool = false) -> String {
        var s = s
        if s.hasPrefix("/") { s.removeFirst() }
        if !onlyStripPrefix, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Segment-aware suffix test: `endsWith("notindex", "index")` is `false`.
    static func endsWith(_ s: String, _ suffix: String) -> Bool {
        s == suffix || s.hasSuffix("/" + suffix)
    }

    /// Removes `suffix` only when `endsWith` holds, and does **not** remove the
    /// preceding slash: `trimSuffix("abc/index", "index")` → `"abc/"`.
    static func trimSuffix(_ s: String, _ suffix: String) -> String {
        endsWith(s, suffix) ? String(s.dropLast(suffix.count)) : s
    }

    static func isFolderPath(_ fplike: String) -> Bool {
        fplike.hasSuffix("/")
            || endsWith(fplike, "index")
            || endsWith(fplike, "index.md")
            || endsWith(fplike, "index.html")
    }

    /// `/^\.{0,2}$/` — matches `""`, `"."` and `".."` only.
    static func isRelativeSegment(_ s: String) -> Bool {
        s.isEmpty || s == "." || s == ".."
    }

    // MARK: - slugifyFilePath (path.ts:84)

    /// A content-relative file path → a `FullSlug`.
    ///
    /// `.md` / `.html` / extensionless lose their extension; every other
    /// extension is kept and re-appended *after* slugification, so
    /// `content/cool.png` → `content/cool.png` but `note with spaces.md` →
    /// `note-with-spaces`.
    static func slugifyFilePath(_ fp: String, excludeExt: Bool = false) -> String {
        let stripped = stripSlashes(fp)
        var ext = fileExtension(stripped)
        let withoutFileExt = ext.map { String(stripped.dropLast($0.count)) } ?? stripped
        if excludeExt || ext == ".md" || ext == ".html" || ext == nil { ext = nil }

        var slug = sluggify(withoutFileExt)
        // Obsidian/Hugo style folder notes: `_index` is the folder's index.
        if endsWith(slug, "_index") {
            slug = String(slug.dropLast("_index".count)) + "index"
        }
        return slug + (ext ?? "")
    }

    /// `FullSlug` → `SimpleSlug`: trims a trailing `index` segment, and the
    /// site root becomes `"/"`.
    static func simplifySlug(_ fp: String) -> String {
        let res = stripSlashes(trimSuffix(fp, "index"), onlyStripPrefix: true)
        return res.isEmpty ? "/" : res
    }

    // MARK: - splitAnchor (path.ts:211)

    /// Splits `page#anchor` into its path and its **already-slugified** anchor
    /// (with the leading `#` kept, or `""` when there is none).
    ///
    /// Two deliberate quirks carried over from JS:
    /// - `String.split("#", 2)` in JS splits fully then truncates, so
    ///   `a#x#y` → `("a", "#x")` — `#y` is silently dropped.
    /// - `.pdf` targets keep their anchor verbatim, so `doc.pdf#page=3` works.
    static func splitAnchor(_ link: String) -> (path: String, anchor: String) {
        let parts = link.components(separatedBy: "#")
        let fp = parts[0]
        let rawAnchor: String? = parts.count > 1 ? parts[1] : nil

        if fp.hasSuffix(".pdf") {
            return (fp, rawAnchor.map { "#" + $0 } ?? "")
        }
        return (fp, rawAnchor.map { "#" + GithubSlugger.slug($0) } ?? "")
    }

    // MARK: - joinSegments / pathToRoot / resolveRelative (path.ts:184–248)

    static func joinSegments(_ args: String...) -> String { joinSegments(args) }

    static func joinSegments(_ args: [String]) -> String {
        guard let first = args.first, let last = args.last else { return "" }

        var joined = args
            .filter { $0 != "" && $0 != "/" }
            .map { stripSlashes($0) }
            .joined(separator: "/")

        if first.hasPrefix("/") { joined = "/" + joined }
        if last.hasSuffix("/") { joined += "/" }
        return joined
    }

    /// `a/b/c` → `../..` — how many levels up the site root is from `slug`.
    static func pathToRoot(_ slug: String) -> String {
        let rootPath = slug
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
            .dropLast()
            .map { _ in ".." }
            .joined(separator: "/")
        return rootPath.isEmpty ? "." : rootPath
    }

    static func resolveRelative(_ current: String, _ target: String) -> String {
        joinSegments(pathToRoot(current), simplifySlug(target))
    }

    private static func addRelativeToStart(_ s: String) -> String {
        if s.isEmpty { return "." }
        return s.hasPrefix(".") ? s : joinSegments(".", s)
    }

    // MARK: - transformInternalLink (path.ts:107)

    /// Canonicalizes a raw link target into a `RelativeURL` rooted at `.`.
    ///
    /// Quartz calls `decodeURI` first because by the time `CrawlLinks` runs the
    /// href has been percent-encoded by `mdast-util-to-hast`. CityDesk works
    /// from raw wikilink text, which is not encoded — and `decodeURI` *throws*
    /// on a bare `%`, so skipping it is both correct and safer here.
    static func transformInternalLink(_ link: String) -> String {
        let (fplike, anchor) = splitAnchor(link)
        let folderPath = isFolderPath(fplike)

        let segments = fplike.components(separatedBy: "/").filter { !$0.isEmpty }
        let prefix = segments.filter(isRelativeSegment).joined(separator: "/")
        let fp = segments.filter { !isRelativeSegment($0) }.joined(separator: "/")

        let simpleSlug = simplifySlug(slugifyFilePath(fp))
        let joined = joinSegments(stripSlashes(prefix), stripSlashes(simpleSlug))
        return addRelativeToStart(joined) + (folderPath ? "/" : "") + anchor
    }

    // MARK: - transformLink (path.ts:264)

    enum Strategy: String, Sendable {
        case absolute, relative, shortest
    }

    /// The resolution function. cryptology.city is configured
    /// `markdownLinkResolution: "shortest"` (`quartz.config.ts:72`), which
    /// means: try to read the target as a bare basename and take the unique
    /// match; on zero *or* two-plus matches, silently fall back to
    /// absolute-from-vault-root.
    static func transformLink(
        src: String,
        target: String,
        strategy: Strategy,
        allSlugs: [String]
    ) -> String {
        let targetSlug = transformInternalLink(target)
        if strategy == .relative { return targetSlug }

        let folderTail = isFolderPath(targetSlug) ? "/" : ""
        let canonicalSlug = stripSlashes(String(targetSlug.dropFirst()))
        let (targetCanonical, targetAnchor) = splitAnchor(canonicalSlug)

        if strategy == .shortest {
            let matches = allSlugs.filter { lastSegment($0) == targetCanonical }
            if matches.count == 1 {
                return resolveRelative(src, matches[0]) + targetAnchor
            }
        }
        return joinSegments(pathToRoot(src), canonicalSlug) + folderTail
    }

    /// The final `/`-separated component, which is what the `shortest`
    /// strategy compares against.
    static func lastSegment(_ slug: String) -> String {
        slug.components(separatedBy: "/").last ?? slug
    }
}
