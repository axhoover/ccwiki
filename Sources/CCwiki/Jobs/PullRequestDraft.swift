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
    /// rule can never turn the body's last line into a heading.
    func bodyForGitHub(jobID: String, provenance: Provenance) -> String {
        let footer = Self.footer(provenance, marker: "ccwiki-job: \(jobID)")
        let text = Self.trimmedBlankLines(body)
        return text.isEmpty ? footer : text + "\n\n" + footer
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
