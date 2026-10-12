import Foundation

/// The pull request a job would open: its title and body as the review
/// edits them (plans/corrections.md §6.4).
///
/// What CCwiki proposes, per kind:
///
/// - **Edit.** `[fix] <page title>: <section title>`. The body starts with
///   an empty paragraph for the why, then the page line.
/// - **Correction.** The agent's title, or the edit's form. The agent's
///   body, the reader's request as a quote, then the page line.
/// - **Ingestion.** The agent's handover verbatim. Without one, `[paper]`
///   and the source, with its URL and the submitter's notes, and never the
///   dropped PDF's path, which would put a home directory in a public PR.
///
/// The page line:
///
/// ```
/// **Page:** [Pseudorandom function](https://cryptology.city/Primitives/pseudorandom-function#security), `content/Primitives/pseudorandom-function.md`, lines 42–44 (“Security”)
/// ```
struct PullRequestDraft: Codable, Sendable, Equatable {
    var title: String
    var body: String

    /// What the footer says about where the change came from.
    struct Provenance: Sendable, Equatable {
        let appVersion: String
        let isDevBuild: Bool
        /// "edited by hand", "drafted by claude (sonnet)", "ingested by claude".
        let route: String
    }

    /// The prefix of a correction's or an edit's title, as the wiki's own
    /// `[paper]` prefixes an ingestion's.
    static let fixPrefix = "[fix]"

    /// `.ccwiki/pull-request.md`: the first line `# <title>`, the rest the
    /// body. Nil without a title.
    ///
    /// Blank lines before the title are passed over, as is a byte-order
    /// mark; the body loses its blank lines at either end. A first line that
    /// is anything but a level-one ATX heading is no title.
    static func parse(handover: String) -> PullRequestDraft? {
        var text = handover
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
              let heading = WikiPage.atxHeading(lines[first]), heading.level == 1
        else { return nil }
        let title = heading.text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        let body = lines[(first + 1)...].joined(separator: "\n")
        return PullRequestDraft(title: title, body: Self.trimmedBlankLines(body))
    }

    /// What CCwiki proposes, merged with the agent's handover when there is
    /// one. `siteURL` is the page on cryptology.city, without an anchor; the
    /// target's section becomes its fragment. Nil writes the title unlinked.
    static func make(for kind: JobKind, handover: PullRequestDraft?, siteURL: URL?) -> PullRequestDraft {
        switch kind {
        case .edit(let target):
            // No agent writes a handover for an edit.
            return PullRequestDraft(
                title: fixTitle(for: target),
                body: "\n\n" + pageLine(for: target, siteURL: siteURL))

        case .correction(let request):
            let target = request.target
            var title = fixTitle(for: target)
            if let proposed = handover?.title.trimmingCharacters(in: .whitespaces),
               !proposed.isEmpty {
                title = proposed.lowercased().hasPrefix(fixPrefix) ? proposed : "\(fixPrefix) \(proposed)"
            }
            let agentBody = handover.map { trimmedBlankLines($0.body) } ?? ""
            let asked = "**Requested in CCwiki:**\n\n" + quoted(request.description)
            let parts = [agentBody, asked, pageLine(for: target, siteURL: siteURL)]
            // Without the agent's words, the why is the maintainer's to write.
            let body = (agentBody.isEmpty ? "\n\n" : "")
                + parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return PullRequestDraft(title: title, body: body)

        case .ingestion(let submission):
            if let handover { return handover }
            return ingestionFallback(submission)
        }
    }

    /// The line after a rule, then the hidden marker. Shared with issues
    /// (§8.2). `marker` is the comment's whole text: "ccwiki-job: <id>", or
    /// "ccwiki-issue: <uuid>".
    ///
    /// ```
    /// ---
    /// Opened with CCwiki 0.3.0 (CCwiki Dev, a development build) · edited by hand
    /// <!-- ccwiki-job: 20261011-142210-118-edit-pseudorandom-function -->
    /// ```
    static func footer(_ provenance: Provenance, marker: String) -> String {
        var line = "Opened with CCwiki \(provenance.appVersion)"
        if provenance.isDevBuild { line += " (CCwiki Dev, a development build)" }
        let route = provenance.route.trimmingCharacters(in: .whitespacesAndNewlines)
        if !route.isEmpty { line += " · \(route)" }
        return "---\n\(line)\n<!-- \(marker) -->"
    }

    /// The body as sent: the edited body, then the footer with
    /// "ccwiki-job: <id>". A blank line always separates the two, so the
    /// rule can never turn the body's last line into a heading, and a block
    /// the body leaves open is closed first (`closingOpenBlock`), so the
    /// footer is never shown as code, nor hidden.
    func bodyForGitHub(jobID: String, provenance: Provenance) -> String {
        let footer = Self.footer(provenance, marker: "ccwiki-job: \(jobID)")
        let text = Self.closingOpenBlock(Self.trimmedBlankLines(body))
        return text.isEmpty ? footer : text + "\n\n" + footer
    }

    /// `markdown`, with a closing line added when it ends inside a block
    /// that CommonMark runs to the end of the document: a fenced code block,
    /// or an HTML block of the kinds that a blank line does not end
    /// (`<pre>`, `<script>`, `<style>` or `<textarea>`; `<!--`; `<?`;
    /// `<!` and a letter; `<![CDATA[`). Anything appended would otherwise
    /// render inside it, as code or not at all. The body is often an
    /// agent's, and an ingestion's agent reads untrusted papers.
    ///
    /// The closing line takes the opening line's indent, so a block opened
    /// inside a list item closes there.
    static func closingOpenBlock(_ markdown: String) -> String {
        var unclosed: OpenBlock?
        let lines = markdown.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }
        for line in lines {
            if let block = unclosed {
                if block.isEnded(by: line) { unclosed = nil }
            } else {
                unclosed = OpenBlock(opening: line)
            }
        }
        guard let block = unclosed else { return markdown }
        return markdown + "\n" + block.closingLine
    }

    // MARK: The parts

    /// `[fix] <page title>: <section title>`, or `[fix] <page title>` for the
    /// whole page.
    private static func fixTitle(for target: CorrectionTarget) -> String {
        guard let section = target.section, !section.title.isEmpty,
              section.title != target.pageTitle
        else { return "\(fixPrefix) \(target.pageTitle)" }
        return "\(fixPrefix) \(target.pageTitle): \(section.title)"
    }

    /// `**Page:** [title](url#section), `path`, lines 42–44 (“Security”)`.
    private static func pageLine(for target: CorrectionTarget, siteURL: URL?) -> String {
        var line = "**Page:** "
        if let url = pageURL(siteURL, section: target.section) {
            line += "[\(escapedLinkText(target.pageTitle))](\(url.absoluteString))"
        } else {
            line += target.pageTitle
        }
        line += ", `\(target.repositoryPath)`"
        if let lines = target.lines { line += ", \(lines.label)" }
        if let section = target.section, !section.title.isEmpty {
            line += " (“\(section.title)”)"
        }
        return line
    }

    private static func pageURL(_ siteURL: URL?, section: CorrectionTarget.Section?) -> URL? {
        guard let siteURL else { return nil }
        guard let section, !section.id.isEmpty,
              var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)
        else { return siteURL }
        components.fragment = section.id
        return components.url ?? siteURL
    }

    /// Without one, an ingestion proposes the source and the notes. Never
    /// `localPDF`, nor `metadataJSON()`, which carries its absolute path.
    private static func ingestionFallback(_ submission: IngestSubmission) -> PullRequestDraft {
        let title = "[paper] " + (submission.source.map { sourceLabel($0) } ?? "Untitled submission")
        var parts: [String] = []
        if let source = submission.source {
            parts.append("**Source:** \(source.canonicalURL)")
        } else {
            parts.append("**Source:** a PDF submitted in CCwiki, without a URL.")
        }
        let notes = submission.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("**Notes from the submitter:**\n\n" + quoted(notes))
        }
        return PullRequestDraft(title: title, body: parts.joined(separator: "\n\n"))
    }

    /// "ePrint 2025/375", "arXiv:2401.12345": how the wiki's own titles name
    /// a source.
    private static func sourceLabel(_ source: IngestSubmission.Source) -> String {
        switch source {
        case .eprint(let year, let number): "ePrint \(year)/\(number)"
        case .arXiv(let id): "arXiv:\(id)"
        case .doi(let doi): "doi:\(doi)"
        case .eccc(let year, let number): "ECCC \(year)/\(number)"
        case .other(let url): url
        }
    }

    /// `text` as a Markdown quote, line by line; a blank line stays inside.
    private static func quoted(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in line.allSatisfy(\.isWhitespace) ? ">" : "> " + line }
            .joined(separator: "\n")
    }

    /// A title as link text: its brackets escaped, so it cannot close the
    /// link early.
    private static func escapedLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// `text` without whole blank lines at either end. Leading spaces on
    /// the first line that is not blank are kept: they can mean code.
    private static func trimmedBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        lines[lines.count - 1] = Substring(String(lines[lines.count - 1]).trimmedTrailing)
        return lines.joined(separator: "\n")
    }
}

/// A block that runs to the end of a Markdown document unless a line ends
/// it, as CommonMark reads one at the top level: a fence, or an HTML block
/// of kinds 1 to 5. Its opening line has at most three spaces of indent;
/// more makes it indented code.
private enum OpenBlock {
    /// The fence's character, the length of its run, and its indent.
    case fence(marker: Character, length: Int, indent: Int)
    /// A line containing any of `ends` ends it; the first closes it.
    case html(ends: [String], indent: Int)

    /// The tags whose HTML block (kind 1) a blank line does not end. Any of
    /// their closing tags ends any of them.
    private static let rawTags = ["pre", "script", "style", "textarea"]

    /// The block `line` opens and leaves open, if any.
    init?(opening line: Substring) {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)

        if let marker = rest.first, marker == "`" || marker == "~" {
            let length = rest.prefix { $0 == marker }.count
            // A backtick fence's info string holds no backtick: "```a```" is
            // inline code.
            guard length >= 3, marker == "~" || !rest.dropFirst(length).contains("`") else { return nil }
            self = .fence(marker: marker, length: length, indent: indent)
            return
        }

        let ends: [String]
        let lowercased = rest.lowercased()
        if let tag = Self.rawTags.first(where: { Self.opens(lowercased, tag: $0) }) {
            ends = ["</\(tag)>"] + Self.rawTags.filter { $0 != tag }.map { "</\($0)>" }
        } else if rest.hasPrefix("<!--") {
            ends = ["-->"]
        } else if rest.hasPrefix("<?") {
            ends = ["?>"]
        } else if rest.hasPrefix("<![CDATA[") {
            ends = ["]]>"]
        } else if rest.hasPrefix("<!"), let letter = rest.dropFirst(2).first, letter.isASCII, letter.isLetter {
            ends = [">"]
        } else {
            return nil
        }
        // The opening line can end its own block: `<!-- a note -->`.
        guard !ends.contains(where: { lowercased.contains($0) }) else { return nil }
        self = .html(ends: ends, indent: indent)
    }

    /// Whether `line` ends the block: a fence of the same character, at
    /// least as long, with only spaces or tabs after it; or, for HTML, a
    /// line containing an end.
    func isEnded(by line: Substring) -> Bool {
        switch self {
        case .fence(let marker, let length, _):
            let indent = line.prefix { $0 == " " }.count
            let rest = line.dropFirst(indent)
            let run = rest.prefix { $0 == marker }.count
            return indent <= 3 && run >= length && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        case .html(let ends, _):
            let lowercased = line.lowercased()
            return ends.contains { lowercased.contains($0) }
        }
    }

    /// The line that ends the block, at its opening line's indent.
    var closingLine: String {
        switch self {
        case .fence(let marker, let length, let indent):
            String(repeating: " ", count: indent) + String(repeating: marker, count: length)
        case .html(let ends, let indent):
            String(repeating: " ", count: indent) + (ends.first ?? "")
        }
    }

    /// `<tag` at the start of a lowercased line, then a space, a tab, `>`
    /// or the end of the line.
    private static func opens(_ lowercased: String, tag: String) -> Bool {
        guard lowercased.hasPrefix("<" + tag) else { return false }
        let next = lowercased.dropFirst(tag.count + 1).first
        return next == nil || next == " " || next == "\t" || next == ">"
    }
}
