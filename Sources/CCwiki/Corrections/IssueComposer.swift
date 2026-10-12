import Foundation

/// The issue sheet's proposed text (plans/corrections.md §8.2): the page
/// line, a permalink to the lines at the commit the reader showed, and the
/// quote in a `text` fence, then an empty paragraph where the cursor lands.
/// Pure.
///
/// ````markdown
/// **Page:** [Pseudorandom function](https://cryptology.city/Primitives/pseudorandom-function#security), `content/Primitives/pseudorandom-function.md`, lines 42–44 (“Security”)
///
/// https://github.com/axhoover/cryptology.city/blob/<commit>/content/Primitives/pseudorandom-function.md?plain=1#L42-L44
///
/// ```text
/// <the quote>
/// ```
///
/// ````
///
/// The body is not rendered in the sheet: GitHub's renderer is not the
/// reader's. It turns the permalink into a code snippet, and renders `$…$`
/// with its own math, which is why the quote is in a fence and not a
/// blockquote: the wiki's macros would show as errors.
enum IssueComposer {

    /// "<page title>: <section title>", or the page title alone when there
    /// is no section, or the section is the page's own title.
    static func proposedTitle(for target: CorrectionTarget) -> String {
        guard let section = target.section?.title.trimmingCharacters(in: .whitespaces),
              !section.isEmpty, section != target.pageTitle
        else { return target.pageTitle }
        return "\(target.pageTitle): \(section)"
    }

    /// The page line; the permalink, on a line of its own, so GitHub embeds
    /// the lines as a snippet; the quote; then an empty paragraph, which is
    /// where the reader starts typing.
    static func body(for target: CorrectionTarget, siteURL: URL?, repository: String) -> String {
        var paragraphs: [String] = [pageLine(for: target, siteURL: siteURL)]
        if !target.baseCommit.isEmpty {
            let link = permalink(
                repository: repository, commit: target.baseCommit,
                path: target.repositoryPath, lines: target.lines)
            paragraphs.append(link.absoluteString)
        }
        if let quote = target.quote, !quote.isEmpty {
            let fence = fence(for: quote)
            paragraphs.append("\(fence)text\n\(quote)\n\(fence)")
        }
        return paragraphs.joined(separator: "\n\n") + "\n\n"
    }

    /// `**Page:** [Title](site#section), `content/…`, lines 42–44 (“Security”)`.
    static func pageLine(for target: CorrectionTarget, siteURL: URL?) -> String {
        let title = escapedLinkText(target.pageTitle)
        var line = "**Page:** "
        if let siteURL {
            var url = siteURL
            if let section = target.section,
               var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) {
                components.fragment = section.id
                url = components.url ?? siteURL
            }
            line += "[\(title)](\(url.absoluteString))"
        } else {
            line += title
        }
        line += ", `\(target.repositoryPath)`"
        if let lines = target.lines { line += ", \(lines.label)" }
        if let section = target.section { line += " (“\(section.title)”)" }
        return line
    }

    /// `https://github.com/<repository>/blob/<commit>/<path>?plain=1#L42-L44`,
    /// the path percent-encoded segment by segment: reference filenames
    /// have spaces, `&` and non-ASCII titles. `#L42` for one line, and no
    /// anchor for the whole page.
    static func permalink(
        repository: String, commit: String, path: String, lines: LineRange?
    ) -> URL {
        let segments: [Substring] = repository.split(separator: "/") + ["blob", Substring(commit)]
            + path.split(separator: "/")
        var string = "https://github.com/"
            + segments.map { percentEncoded(String($0)) }.joined(separator: "/") + "?plain=1"
        if let lines {
            string += lines.first == lines.last
                ? "#L\(lines.first)"
                : "#L\(lines.first)-L\(lines.last)"
        }
        // Every character is ASCII and every segment encoded, so the string
        // is always a URL; github.com itself stands in all the same.
        return URL(string: string) ?? URL(string: "https://github.com")!
    }

    /// A run of backticks one longer than the longest in `text`, and never
    /// shorter than three, so nothing in the quote can close the fence.
    static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// What CCwiki adds under the body, as the sheet names it: the footer's
    /// visible lines, without the rule and the hidden marker.
    static func visibleFooter(_ footer: String) -> String {
        footer.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.allSatisfy { $0 == "-" } && !line.hasPrefix("<!--")
            }
            .joined(separator: " ")
    }

    /// The number GitHub gave an issue, from its URL: ".../issues/123".
    static func issueNumber(in url: URL) -> Int? {
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "issues" else { return nil }
        return Int(parts[parts.count - 1])
    }

    // MARK: Encoding

    /// A path segment as GitHub's own links write it: ASCII letters, digits
    /// and `-._~` stay; everything else, a space and `&` included, is
    /// percent-encoded as UTF-8.
    private static func percentEncoded(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    private static let segmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Link text with the brackets that would end it escaped.
    private static func escapedLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
