import Foundation
import Testing
@testable import CCwiki

struct SubmissionSourceTests {

    @Test("the URL shapes people actually paste are recognized")
    func parsing() {
        typealias Source = IngestSubmission.Source
        let cases: [(String, Source)] = [
            // ePrint, including the .pdf and short-link forms.
            ("https://eprint.iacr.org/2025/375", .eprint(year: "2025", number: "375")),
            ("https://eprint.iacr.org/2025/375.pdf", .eprint(year: "2025", number: "375")),
            ("eprint.iacr.org/2025/375", .eprint(year: "2025", number: "375")),
            ("https://ia.cr/2025/375", .eprint(year: "2025", number: "375")),
            ("https://eprint.iacr.org/archive/2005/187", .eprint(year: "2005", number: "187")),

            // arXiv, including versioned ids and the old subject-prefixed ones.
            ("https://arxiv.org/abs/2401.12345", .arXiv(id: "2401.12345")),
            ("https://arxiv.org/pdf/2401.12345", .arXiv(id: "2401.12345")),
            ("https://arxiv.org/pdf/2401.12345v2", .arXiv(id: "2401.12345v2")),
            ("https://arxiv.org/abs/math/0309136", .arXiv(id: "math/0309136")),
            ("arXiv:2401.12345", .arXiv(id: "2401.12345")),

            // DOI, in all three spellings.
            ("https://doi.org/10.1145/800061.808726", .doi("10.1145/800061.808726")),
            ("doi:10.1145/800061.808726", .doi("10.1145/800061.808726")),
            ("10.1145/800061.808726", .doi("10.1145/800061.808726")),

            ("https://eccc.weizmann.ac.il/report/2023/001/",
             .eccc(year: "2023", number: "001")),
        ]
        for (input, expected) in cases {
            #expect(Source.parse(input) == expected, "parse(\(input))")
        }
    }

    @Test("an unknown but valid URL is accepted rather than rejected")
    func unknownHosts() {
        // Refusing a valid link because it is not one of four known hosts would
        // be obnoxious; the agent can still fetch it.
        #expect(IngestSubmission.Source.parse("https://example.org/paper.pdf")
            == .other("https://example.org/paper.pdf"))
        // …but nonsense is still nonsense.
        #expect(IngestSubmission.Source.parse("") == nil)
        #expect(IngestSubmission.Source.parse("   ") == nil)
    }

    @Test("canonical and full-text URLs differ where the site does")
    func canonicalization() {
        let eprint = IngestSubmission.Source.eprint(year: "2025", number: "375")
        #expect(eprint.canonicalURL == "https://eprint.iacr.org/2025/375")
        #expect(eprint.fullTextURL == "https://eprint.iacr.org/2025/375.pdf")

        let doi = IngestSubmission.Source.doi("10.1145/800061.808726")
        #expect(doi.canonicalURL == "https://doi.org/10.1145/800061.808726")
        #expect(doi.fullTextURL == nil, "a DOI resolves to a landing page, not a PDF")
    }

    @Test("the slug is safe as a branch name and a directory name")
    func slugs() {
        func slug(_ source: IngestSubmission.Source?, pdf: URL? = nil) -> String {
            IngestSubmission(
                kind: pdf != nil ? .pdf : .url, source: source, localPDF: pdf,
                notes: "", submittedAt: Date()).slug
        }
        #expect(slug(.eprint(year: "2025", number: "375")) == "eprint-2025-375")
        #expect(slug(.arXiv(id: "2401.12345v2")) == "arxiv-2401-12345v2")
        #expect(slug(.arXiv(id: "math/0309136")) == "arxiv-math-0309136")
        // A DOI is full of characters git will not accept in a ref.
        #expect(slug(.doi("10.1145/800061.808726")) == "doi-10-1145-800061-808726")
        #expect(slug(nil, pdf: URL(fileURLWithPath: "/tmp/Some Paper (final).pdf"))
            == "some-paper-final")

        for source in [IngestSubmission.Source.doi("10.1145/800061.808726"),
                       .arXiv(id: "math/0309136")] {
            let value = slug(source)
            #expect(!value.contains("/"), "a slash would create a nested branch")
            #expect(!value.hasPrefix("-") && !value.hasSuffix("-"))
            #expect(!value.contains("--"), "runs are collapsed")
        }
    }

    @Test("the metadata block matches the shape the wiki's workflow accepts")
    func metadataJSON() throws {
        let submission = IngestSubmission(
            kind: .url,
            source: .eprint(year: "2025", number: "375"),
            localPDF: nil,
            notes: "Probably belongs on the LWE page.",
            submittedAt: Date(timeIntervalSince1970: 1_780_000_000))

        let data = Data(submission.metadataJSON().utf8)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paper = try #require(object["paper"] as? [String: Any])

        #expect(paper["type"] as? String == "url")
        #expect(paper["url"] as? String == "https://eprint.iacr.org/2025/375.pdf")
        #expect(paper["source_url"] as? String == "https://eprint.iacr.org/2025/375")
        #expect(object["notes"] as? String == "Probably belongs on the LWE page.")
        #expect(object["submitted_at"] as? String != nil)
    }
}

struct ClaudeStreamTests {

    /// Real lines, captured from `claude -p --output-format stream-json`.
    @Test("the stream is turned into a readable transcript")
    func parsing() {
        var parser = ClaudeStreamParser()

        let initEvent = """
        {"type":"system","subtype":"init","cwd":"/tmp/wt","session_id":"abc-123",\
        "model":"claude-opus-4-8[1m]","tools":["Bash"],"permissionMode":"acceptEdits"}
        """
        let entries = parser.consume(initEvent)
        #expect(entries.count == 1)
        #expect(parser.sessionID == "abc-123")
        #expect(parser.model == "claude-opus-4-8[1m]")

        let assistant = """
        {"type":"assistant","message":{"role":"assistant","content":[\
        {"type":"text","text":"Reading the lint rules."},\
        {"type":"tool_use","name":"Bash","input":{"command":"node scripts/lint.mjs"}}]}}
        """
        let turn = parser.consume(assistant)
        #expect(turn.count == 2)
        if case .assistant = turn[0].role {} else { Issue.record("expected prose first") }
        if case .tool(let name) = turn[1].role {
            #expect(name == "Bash")
            #expect(turn[1].text == "node scripts/lint.mjs")
        } else {
            Issue.record("expected a tool call second")
        }

        let toolResult = """
        {"type":"user","message":{"role":"user","content":[\
        {"type":"tool_result","is_error":false,"content":"0 errors"}]}}
        """
        let result = parser.consume(toolResult)
        #expect(result.count == 1 && result[0].text == "0 errors")

        // Bookkeeping events are not transcript lines.
        #expect(parser.consume(
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#).isEmpty)
    }

    @Test("the result event carries the outcome")
    func outcome() throws {
        var parser = ClaudeStreamParser()
        let event = """
        {"type":"result","subtype":"success","is_error":false,"num_turns":37,\
        "total_cost_usd":1.25,"duration_ms":184000,"session_id":"abc-123",\
        "result":"Opened https://github.com/axhoover/cryptology.city/pull/42",\
        "permission_denials":[{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}]}
        """
        _ = parser.consume(event)

        let outcome = try #require(parser.outcome)
        #expect(outcome.turns == 37)
        #expect(outcome.costUSD == 1.25)
        #expect(outcome.isError == false)
        #expect(outcome.permissionDenials == ["Bash: rm -rf /"])
        #expect(outcome.pullRequestURL?.absoluteString
            == "https://github.com/axhoover/cryptology.city/pull/42")
        #expect(outcome.abortReason == nil)
    }

    @Test("a PR URL is found among prose, and the last one wins")
    func pullRequestExtraction() {
        // The agent may quote the template before printing the real thing.
        let text = """
        I followed the template at https://github.com/axhoover/cryptology.city/pull/28
        and opened https://github.com/axhoover/cryptology.city/pull/41 as a draft.
        """
        #expect(ClaudeOutcome.findPullRequestURL(in: text)?.absoluteString
            == "https://github.com/axhoover/cryptology.city/pull/41")

        #expect(ClaudeOutcome.findPullRequestURL(in: "no links here") == nil)
        // An issue URL is not a PR URL.
        #expect(ClaudeOutcome.findPullRequestURL(
            in: "https://github.com/axhoover/cryptology.city/issues/7") == nil)
    }

    @Test("an abort is recognized as a distinct outcome, not a failure")
    func abort() throws {
        var parser = ClaudeStreamParser()
        _ = parser.consume("""
        {"type":"result","subtype":"success","is_error":false,"num_turns":9,\
        "result":"ABORTED: the paper is already in the wiki as AGGM06.",\
        "permission_denials":[]}
        """)
        let outcome = try #require(parser.outcome)
        #expect(outcome.abortReason == "ABORTED: the paper is already in the wiki as AGGM06.")
        #expect(outcome.pullRequestURL == nil)
        #expect(outcome.isError == false, "aborting on purpose is a success, not an error")
    }

    @Test("a non-JSON line is surfaced rather than swallowed")
    func nonJSON() {
        var parser = ClaudeStreamParser()
        let entries = parser.consume("Error: something went wrong")
        #expect(entries.count == 1)
        #expect(entries[0].text == "Error: something went wrong")
    }

    @Test("tool calls are summarized by their most useful field")
    func toolSummaries() {
        #expect(ClaudeStreamParser.summarize(
            tool: "Bash", input: ["command": "git status"]) == "git status")
        #expect(ClaudeStreamParser.summarize(
            tool: "Read", input: ["file_path": "content/index.md"]) == "content/index.md")
        #expect(ClaudeStreamParser.summarize(
            tool: "Grep", input: ["pattern": "Other results", "path": "content"])
            == "Other results  in content")
        #expect(ClaudeStreamParser.summarize(
            tool: "WebFetch", input: ["url": "https://eprint.iacr.org/2025/375"])
            == "https://eprint.iacr.org/2025/375")
        // A multi-line command stays on one row.
        #expect(ClaudeStreamParser.summarize(
            tool: "Bash", input: ["command": "cd x\nnpm ci"]) == "cd x ⏎ npm ci")
    }
}

@MainActor
struct PromptCompositionTests {

    @Test("every placeholder is filled, and no house style is inlined")
    func composition() throws {
        let template = try #require(PromptComposer.template(),
                                    "prompts/ingest.md should be findable from the repo root")

        // The template is an envelope. If it ever grows a paraphrase of the
        // wiki's own rules, this is where we find out.
        #expect(template.contains(".github/prompts/paper-submission.md"),
                "the prompt must defer to the repo's own contract")

        let paths = AppPaths(support: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-prompt-\(UUID().uuidString)"))
        let submission = IngestSubmission(
            kind: .url, source: .eprint(year: "2025", number: "375"),
            localPDF: nil, notes: "Check the LWE page.", submittedAt: Date())
        let job = IngestJob(submission: submission, paths: paths)

        let prompt = try PromptComposer.compose(
            job: job, baseBranch: "main",
            preflight: [PreflightFinding(
                level: .warning, title: "Already in the wiki as AGGM06",
                detail: "content/References/AGGM06 - ….md points at this source.")])

        for placeholder in ["{{WORKTREE}}", "{{BRANCH}}", "{{BASE_BRANCH}}", "{{SUBMISSION}}",
                            "{{PAPER_LOCATION}}", "{{PREFLIGHT}}", "{{SKILL_NOTE}}"] {
            #expect(!prompt.contains(placeholder), "\(placeholder) was not substituted")
        }
        #expect(prompt.contains("ingest/eprint-2025-375"))
        #expect(prompt.contains("https://eprint.iacr.org/2025/375"))
        #expect(prompt.contains("Check the LWE page."))
        #expect(prompt.contains("Already in the wiki as AGGM06"))
        #expect(!prompt.hasPrefix("<!--"), "the template's own explanation is stripped")
    }

    @Test("a PDF with no source URL is called out as unpublishable")
    func pdfWithoutSource() throws {
        let paths = AppPaths(support: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-prompt-\(UUID().uuidString)"))
        let submission = IngestSubmission(
            kind: .pdf, source: nil,
            localPDF: URL(fileURLWithPath: "/tmp/library/paper.pdf"),
            notes: "", submittedAt: Date())
        let job = IngestJob(submission: submission, paths: paths)

        let prompt = try PromptComposer.compose(job: job, baseBranch: "main", preflight: [])
        #expect(prompt.contains("/tmp/library/paper.pdf"))
        #expect(prompt.contains("No source URL was given"))
        #expect(prompt.contains("do not copy it into the repository"))
    }

    @Test("the tool allow-list covers what the job actually needs")
    func allowedTools() {
        let tools = PromptComposer.allowedTools
        // The wiki's own workflow grants these…
        for tool in ["Read", "Write", "Edit", "Glob", "Grep",
                     "Bash(git:*)", "Bash(gh:*)", "WebFetch", "WebSearch"] {
            #expect(tools.contains(tool), "missing \(tool)")
        }
        // …and the local lint additionally needs node.
        for tool in ["Bash(npm:*)", "Bash(npx:*)", "Bash(node:*)"] {
            #expect(tools.contains(tool), "missing \(tool)")
        }
        #expect(!tools.contains("Bash"), "an unscoped Bash grant defeats the point")
    }
}

/// The runner believes GitHub over the agent's prose — but only about a PR
/// this job could have opened.
struct PullRequestConfirmationTests {

    @Test("only an open PR created after the job started counts, and the newest wins")
    func createdAfter() throws {
        let started = ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z")!
        let listing = """
            2026-09-20T09:00:00Z https://github.com/axhoover/cryptology.city/pull/36
            2026-09-27T10:05:00Z https://github.com/axhoover/cryptology.city/pull/41
            2026-09-27T10:02:00Z https://github.com/axhoover/cryptology.city/pull/40
            garbage line
            """
        let url = IngestJobRunner.pullRequest(createdAfter: started, in: listing)
        #expect(url?.absoluteString == "https://github.com/axhoover/cryptology.city/pull/41")
        #expect(IngestJobRunner.pullRequest(createdAfter: started, in: "") == nil)
        #expect(IngestJobRunner.pullRequest(
            createdAfter: started,
            in: "2026-09-20T09:00:00Z https://github.com/axhoover/cryptology.city/pull/36") == nil,
            "a PR from an earlier job on the same branch name is not this job's")
    }
}
