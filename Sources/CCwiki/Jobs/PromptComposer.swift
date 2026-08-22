import Foundation

/// Builds the prompt handed to `claude -p`.
///
/// The governing rule, and the reason this type is so small: **house style is
/// not composed here.** The wiki carries its own editorial contract in
/// `.github/prompts/paper-submission.md`, maintained by the people who maintain
/// the wiki, and `prompts/ingest.md` points the agent at it *in the worktree*
/// rather than restating it. So this only fills in the placeholders that are
/// specific to one job.
///
/// If the template ever grows a paraphrase of the wiki's style rules, delete it
/// — the app would then be teaching agents a snapshot that goes stale the day
/// the wiki's own prompt changes.
struct PromptComposer: Sendable {

    /// The template, from the app bundle.
    static func template() -> String? {
        if let url = Bundle.main.url(forResource: "ingest", withExtension: "md",
                                     subdirectory: "prompts"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // `swift run` and the tests have no .app around them.
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "prompts/ingest.md")
        return try? String(contentsOf: fallback, encoding: .utf8)
    }

    enum ComposeError: LocalizedError {
        case templateMissing

        var errorDescription: String? {
            "prompts/ingest.md is missing from the app bundle. "
                + "Rebuild with `make` — build.sh copies it in."
        }
    }

    @MainActor
    static func compose(
        job: IngestJob,
        baseBranch: String,
        preflight: [PreflightFinding]
    ) throws -> String {
        guard var text = template() else { throw ComposeError.templateMissing }

        let worktreePath = job.worktree.path(percentEncoded: false)
        let substitutions: [String: String] = [
            "{{WORKTREE}}": worktreePath,
            "{{BRANCH}}": job.branch,
            "{{BASE_BRANCH}}": baseBranch,
            "{{SUBMISSION}}": job.submission.metadataJSON(),
            "{{PAPER_LOCATION}}": paperLocation(job.submission),
            "{{PREFLIGHT}}": Preflight.promptSection(preflight),
            "{{SKILL_NOTE}}": skillNote(worktree: job.worktree),
        ]
        for (placeholder, value) in substitutions {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }

        // The HTML comment at the top explains the template to a human editing
        // it; the agent does not need it, and it is a third of the file.
        if let end = text.range(of: "-->") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
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

    /// The tools the agent may use, mirroring the allow-list the wiki's own
    /// GitHub workflow grants (`paper-submission.yml`), plus the node and npm
    /// commands the *local* lint needs — which the server pipeline does not run.
    ///
    /// Scoped rather than `bypassPermissions`: a job that hits a denial fails
    /// visibly, with the denied call recorded in the result event, which is far
    /// better than one that quietly did something nobody asked for.
    /// The allow-list matches on a command's **first word**, so `cd X && git …`
    /// is denied however harmless it looks. The first real job hit seven
    /// denials, every one of them a `cd`-prefixed or `ln` command — which is
    /// why `prompts/ingest.md` now says plainly that the shell already starts
    /// in the worktree and there is nothing to `cd` to.
    ///
    /// The entries below are read-only inspection tools plus the four binaries
    /// the job genuinely drives. Nothing here can write outside a file tool,
    /// which keeps the guarantee worth having: a job that wanders off fails
    /// visibly, with the denied call named in the transcript.
    static let allowedTools = [
        "Read", "Write", "Edit", "Glob", "Grep", "TodoWrite",
        // The four the job actually drives.
        "Bash(git:*)", "Bash(gh:*)", "Bash(npm:*)", "Bash(npx:*)", "Bash(node:*)",
        // Read-only inspection.
        "Bash(find:*)", "Bash(file:*)", "Bash(jq:*)", "Bash(cat:*)", "Bash(ls:*)",
        "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(grep:*)", "Bash(rg:*)",
        "Bash(echo:*)", "Bash(pwd)", "Bash(test:*)", "Bash(diff:*)",
        "Bash(sort:*)", "Bash(uniq:*)", "Bash(cut:*)", "Bash(basename:*)",
        "Bash(dirname:*)", "Bash(hexdump:*)", "Bash(xxd:*)", "Bash(od:*)",
        "Bash(pdftotext:*)", "Bash(mdls:*)",
        "WebFetch", "WebSearch",
    ]
}
