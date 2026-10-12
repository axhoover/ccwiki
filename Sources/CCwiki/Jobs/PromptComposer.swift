import Foundation

/// Builds the prompt handed to `claude -p`, from `prompts/ingest.md` for an
/// ingestion and `prompts/correct.md` for a correction.
///
/// The governing rule, and the reason this type is so small: **house style is
/// not composed here.** The wiki carries its own editorial contract in
/// `.github/prompts/paper-submission.md` and `CLAUDE.md`, maintained by the
/// people who maintain the wiki, and the templates point the agent at them
/// *in the worktree* rather than restating them. So this only fills in the
/// placeholders that are specific to one job.
///
/// If the template ever grows a paraphrase of the wiki's style rules, delete it
/// — the app would then be teaching agents a snapshot that goes stale the day
/// the wiki's own prompt changes.
struct PromptComposer: Sendable {

    /// A template from the app bundle's `prompts/`: "ingest" or "correct".
    static func template(named name: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: "md",
                                     subdirectory: "prompts"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // `swift run` and the tests have no .app around them.
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "prompts/\(name).md")
        return try? String(contentsOf: fallback, encoding: .utf8)
    }

    /// The ingestion template.
    static func template() -> String? {
        template(named: "ingest")
    }

    enum ComposeError: LocalizedError {
        /// The template's name: "ingest", "correct".
        case templateMissing(String)
        /// `compose` writes an ingestion's prompt, and this job is not one.
        case notAnIngestion

        var errorDescription: String? {
            switch self {
            case .templateMissing(let name):
                return "prompts/\(name).md is missing from the app bundle. "
                    + "Rebuild with `make` — build.sh copies it in."
            case .notAnIngestion:
                return "Only an ingestion job has an ingestion prompt."
            }
        }
    }

    @MainActor
    static func compose(
        job: Job,
        baseBranch: String,
        preflight: [PreflightFinding]
    ) throws -> String {
        guard let submission = job.submission else { throw ComposeError.notAnIngestion }
        guard let template = template() else { throw ComposeError.templateMissing("ingest") }

        return fill(template, [
            "WORKTREE": job.worktree.path(percentEncoded: false),
            "BRANCH": job.branch,
            "BASE_BRANCH": baseBranch,
            "SUBMISSION": submission.metadataJSON(),
            "PAPER_LOCATION": paperLocation(submission),
            "PREFLIGHT": Preflight.promptSection(preflight),
            "SKILL_NOTE": skillNote(worktree: job.worktree),
        ])
    }

    /// The prompt for a correction's agent (plans/corrections.md §5.4), from
    /// `prompts/correct.md`: the page, the lines, the passage the reader
    /// quoted, the source of those lines, and what the reader says is wrong.
    /// House style is not here either: the template points the agent at the
    /// worktree's own `CLAUDE.md`.
    ///
    /// `siteURL` is the page on the published site (`AppModel.siteURL`),
    /// without an anchor; the target's section is added as one. Nil leaves
    /// the URL out. A whole-page target, with no quote and no excerpt,
    /// leaves out the paragraphs that would show them.
    @MainActor
    static func composeCorrection(
        _ request: CorrectionRequest, job: Job, siteURL: URL?
    ) throws -> String {
        guard let template = template(named: "correct") else {
            throw ComposeError.templateMissing("correct")
        }
        let target = request.target
        let excerpt = target.excerpt.flatMap { $0.isEmpty ? nil : $0 }
        // "lines 42–44, in “Security”"; a whole page is only near one.
        let placement: String
        switch (target.lines, target.section) {
        case (_, .none): placement = ""
        case (.some, .some(let heading)): placement = ", in “\(heading.title)”"
        case (.none, .some(let heading)): placement = ", near “\(heading.title)”"
        }

        return fill(template, [
            "WORKTREE": job.worktree.path(percentEncoded: false),
            "PAGE_PATH": target.repositoryPath,
            "PAGE_TITLE": target.pageTitle,
            "PAGE_URL": pageURL(siteURL, section: target.section)?.absoluteString,
            "LINES": target.lines?.label ?? "the whole page",
            "SECTION": placement,
            "QUOTE": target.quote.flatMap { Self.quoted($0) },
            "EXCERPT": excerpt,
            "FENCE": fence(for: excerpt ?? ""),
            "REQUEST": quoted(request.description) ?? "(no description)",
        ])
    }

    // MARK: Filling a template

    /// The template, without its leading HTML comment, with each
    /// `{{NAME}}` replaced by its value.
    ///
    /// - The comment explains the template to a human editing it; the agent
    ///   does not need it. It is cut before anything is filled in, so a
    ///   value that holds `-->` cannot move the cut.
    /// - `{{#NAME}}…{{/NAME}}` keeps what it wraps only when NAME has a
    ///   non-empty value. A marker alone on its line takes its line with it.
    /// - Filling is one pass over the template. A value is never searched
    ///   for placeholders, so a quote or an excerpt holding `{{` (LaTeX does)
    ///   arrives as it was.
    static func fill(_ template: String, _ values: [String: String?]) -> String {
        var text = template
        if let end = text.range(of: "-->") {
            text = String(text[end.upperBound...])
        }
        for (name, value) in values {
            text = section(named: name, in: text, keep: !(value ?? "").isEmpty)
        }
        return substitute(text, values.compactMapValues { $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every `{{#name}}…{{/name}}` in `text`, kept without its markers or
    /// removed with them.
    private static func section(named name: String, in text: String, keep: Bool) -> String {
        let open = "{{#\(name)}}"
        let close = "{{/\(name)}}"
        var result = ""
        var rest = text[...]
        while let start = rest.range(of: open),
              let end = rest[start.upperBound...].range(of: close) {
            result.append(contentsOf: rest[..<start.lowerBound])
            let inner = rest[markerEnd(start.upperBound, in: rest)..<end.lowerBound]
            if keep { result.append(contentsOf: inner) }
            rest = rest[markerEnd(end.upperBound, in: rest)...]
        }
        result.append(contentsOf: rest)
        return result
    }

    /// Past a marker: and past the newline after it, when there is one.
    private static func markerEnd(_ index: Substring.Index, in text: Substring) -> Substring.Index {
        index < text.endIndex && text[index] == "\n" ? text.index(after: index) : index
    }

    /// Each `{{NAME}}` in `template` that `values` has, replaced, in one pass.
    private static func substitute(_ template: String, _ values: [String: String]) -> String {
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result.append(contentsOf: rest[..<open.lowerBound])
            let after = rest[open.upperBound...]
            if let close = after.range(of: "}}"),
               let value = values[String(after[..<close.lowerBound])] {
                result.append(contentsOf: value)
                rest = after[close.upperBound...]
            } else {
                result.append(contentsOf: "{{")
                rest = after
            }
        }
        result.append(contentsOf: rest)
        return result
    }

    /// Each line after the first prefixed with `> `, to follow the
    /// template's own `> ` as one blockquote. An empty line is a bare `>`.
    /// Nil for text that is only whitespace.
    static func quoted(_ text: String) -> String? {
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: "\n").enumerated().map { index, line in
            index == 0 ? line : (line.isEmpty ? ">" : "> " + line)
        }.joined(separator: "\n")
    }

    /// A run of backticks one longer than the longest in `text`, and never
    /// shorter than three, so a pseudocode fence inside an excerpt cannot
    /// close the excerpt's own (§5.4).
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

    /// The page's URL with its section as the anchor, unless it has one.
    private static func pageURL(_ siteURL: URL?, section: CorrectionTarget.Section?) -> URL? {
        guard let siteURL, let section,
              var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false),
              components.fragment == nil
        else { return siteURL }
        components.fragment = section.id
        return components.url ?? siteURL
    }

    /// Where the paper is, and how to canonicalize the URL — the part the
    /// wiki's own workflow writes into its prompt too.
    private static func paperLocation(_ submission: IngestSubmission) -> String {
        var lines = ["## Paper location", ""]

        if let pdf = submission.localPDF {
            lines.append("A PDF is staged at `\(pdf.path(percentEncoded: false))`. "
                + "Read it directly; do not copy it into the repository.")
            if let source = submission.source {
                lines.append("")
                lines.append("The submitter also gave a canonical source: "
                    + "`\(source.canonicalURL)`. Use that for the `source:` frontmatter key.")
            } else {
                lines.append("")
                lines.append("**No source URL was given.** You must find the paper's canonical "
                    + "landing page — ePrint, then arXiv, then a DOI — and cite that. "
                    + "A reference page whose `source` points at a local file is not "
                    + "publishable; abort rather than inventing one.")
            }
            return lines.joined(separator: "\n")
        }

        guard let source = submission.source else {
            lines.append("**No paper was supplied.** Abort.")
            return lines.joined(separator: "\n")
        }

        lines.append("Fetch the paper from **\(source.label)**.")
        lines.append("")
        lines.append("- Canonical landing page, and the value for `source:` — `\(source.canonicalURL)`")
        if let fullText = source.fullTextURL {
            lines.append("- Full text — `\(fullText)`")
        }
        lines.append("")
        lines.append("Read the landing page for the metadata (authors, venue, date, abstract) "
            + "and the full text for the results. The abstract on the landing page is the "
            + "one to quote verbatim.")
        return lines.joined(separator: "\n")
    }

    /// Whether the repo's own Claude skill is present in the worktree. It is
    /// picked up automatically, but saying so stops the agent hunting for it.
    private static func skillNote(worktree: URL) -> String {
        let skill = worktree.appending(path: ".claude/skills/city-style/SKILL.md")
        if FileManager.default.fileExists(atPath: skill.path(percentEncoded: false)) {
            return "The repo's `city-style` skill is in this worktree at "
                + "`.claude/skills/city-style/` and loads automatically. It is a compressed "
                + "digest of `CLAUDE.md` and `CONTRIBUTING.md`; read the full files anyway "
                + "for anything it summarizes."
        }
        return "The repo's `city-style` skill is not present in this worktree. "
            + "Read `CLAUDE.md` and `CONTRIBUTING.md` in full instead."
    }

    // The tools an agent may use are `AgentInvocation`'s, beside the seal
    // they are part of (plans/corrections.md §5.1).
}
