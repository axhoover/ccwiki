import Foundation
import Testing
@testable import CCwiki

/// The pull request's title and body: the agent's handover, what CCwiki
/// proposes for each kind, and the footer (plans/corrections.md §6.4,
/// §12.1).
struct PullRequestDraftTests {

    static let siteURL = URL(string: "https://cryptology.city/Primitives/pseudorandom-function")

    static let target = CorrectionTarget(
        pagePath: "Primitives/pseudorandom-function.md", pageTitle: "Pseudorandom function",
        baseCommit: "ab81f02",
        section: CorrectionTarget.Section(id: "security", title: "Security", level: 3),
        lines: LineRange(first: 42, last: 44), region: .body,
        quote: "for all efficient $\\calA$", excerpt: "A PRF $\\PRF$ is **pseudorandom** if for all efficient $\\calA$,")

    static let pageLine = "**Page:** [Pseudorandom function](https://cryptology.city/Primitives/"
        + "pseudorandom-function#security), `content/Primitives/pseudorandom-function.md`, "
        + "lines 42–44 (“Security”)"

    // MARK: The handover

    @Test("the handover: the first line `# <title>`, the rest the body")
    func parseHandover() throws {
        let text = "# [fix] Pseudorandom function: say PRP\n\nThe page said PRF where it meant PRP.\n\n"
        let draft = try #require(PullRequestDraft.parse(handover: text))
        #expect(draft.title == "[fix] Pseudorandom function: say PRP")
        #expect(draft.body == "The page said PRF where it meant PRP.")
    }

    @Test("blank lines before the title, a byte-order mark and CRLF line endings are passed over")
    func parseTolerates() throws {
        let draft = try #require(PullRequestDraft.parse(
            handover: "\u{FEFF}\r\n\r\n# Title here\r\nLine one.\r\nLine two.\r\n"))
        #expect(draft.title == "Title here")
        #expect(draft.body == "Line one.\nLine two.")
        #expect(PullRequestDraft.parse(handover: "# Only a title")?.body == "")
    }

    @Test("without a `#` title the handover is nil")
    func parseWithoutTitle() {
        for text in ["", "\n\n", "[fix] no heading\n\nbody", "## Level two\n\nbody", "#NoSpace\n", "# \nbody", "#\n"] {
            #expect(PullRequestDraft.parse(handover: text) == nil, "\(text)")
        }
    }

    // MARK: What CCwiki proposes

    @Test("an edit: `[fix] <page>: <section>`, an empty paragraph for the why, then the page line")
    func editProposal() {
        let draft = PullRequestDraft.make(for: .edit(Self.target), handover: nil, siteURL: Self.siteURL)
        #expect(draft.title == "[fix] Pseudorandom function: Security")
        #expect(draft.body == "\n\n" + Self.pageLine)
    }

    @Test("an edit of the whole page names no lines and no section")
    func editWholePage() {
        var target = Self.target
        target.section = nil
        target.lines = nil
        let draft = PullRequestDraft.make(for: .edit(target), handover: nil, siteURL: Self.siteURL)
        #expect(draft.title == "[fix] Pseudorandom function")
        #expect(draft.body == "\n\n**Page:** [Pseudorandom function](https://cryptology.city/Primitives/"
            + "pseudorandom-function), `content/Primitives/pseudorandom-function.md`")
    }

    @Test("without the site's URL the title is not a link")
    func editWithoutSiteURL() {
        let draft = PullRequestDraft.make(for: .edit(Self.target), handover: nil, siteURL: nil)
        #expect(draft.body == "\n\n**Page:** Pseudorandom function, "
            + "`content/Primitives/pseudorandom-function.md`, lines 42–44 (“Security”)")
    }

    @Test("a correction: the agent's title and body, the request as a quote, the page line")
    func correctionProposal() {
        let request = CorrectionRequest(
            target: Self.target, description: "It should say PRP.\n\nThe game is a permutation game.",
            model: "sonnet")
        let handover = PullRequestDraft(
            title: "[fix] Pseudorandom function: say PRP", body: "Changed PRF to PRP in the definition.")
        let draft = PullRequestDraft.make(for: .correction(request), handover: handover, siteURL: Self.siteURL)
        #expect(draft.title == "[fix] Pseudorandom function: say PRP")
        #expect(draft.body == """
            Changed PRF to PRP in the definition.

            **Requested in CCwiki:**

            > It should say PRP.
            >
            > The game is a permutation game.

            \(Self.pageLine)
            """)
    }

    @Test("a correction's title gains [fix] if the agent left it out; without a handover it is the edit's")
    func correctionTitles() {
        let request = CorrectionRequest(target: Self.target, description: "Say PRP.", model: "")
        let bare = PullRequestDraft(title: "Pseudorandom function: say PRP", body: "")
        #expect(PullRequestDraft.make(for: .correction(request), handover: bare, siteURL: nil).title
            == "[fix] Pseudorandom function: say PRP")

        let draft = PullRequestDraft.make(for: .correction(request), handover: nil, siteURL: Self.siteURL)
        #expect(draft.title == "[fix] Pseudorandom function: Security")
        #expect(draft.body == "\n\n**Requested in CCwiki:**\n\n> Say PRP.\n\n" + Self.pageLine)
    }

    static let submission = IngestSubmission(
        kind: .url, source: .eprint(year: "2025", number: "375"), localPDF: nil,
        notes: "Check the LWE page.", submittedAt: Date(timeIntervalSinceReferenceDate: 780_652_800))

    @Test("an ingestion: the agent's handover, verbatim")
    func ingestionHandover() {
        let handover = PullRequestDraft(title: "[paper] Some paper (2025/375)", body: "## Summary\n\nAs the template says.")
        #expect(PullRequestDraft.make(for: .ingestion(Self.submission), handover: handover, siteURL: nil)
            == handover)
    }

    @Test("an ingestion without a handover: [paper], the source's URL and the notes")
    func ingestionFallback() {
        let draft = PullRequestDraft.make(for: .ingestion(Self.submission), handover: nil, siteURL: nil)
        #expect(draft.title == "[paper] ePrint 2025/375")
        #expect(draft.body.contains("https://eprint.iacr.org/2025/375"))
        #expect(draft.body.contains("> Check the LWE page."))
    }

    @Test("the ingestion fallback never contains the dropped PDF's path")
    func ingestionFallbackHidesThePDF() {
        let pdf = IngestSubmission(
            kind: .pdf, source: nil,
            localPDF: URL(fileURLWithPath: "/Users/alice/Library/Application Support/CCwiki/library/secret draft.pdf"),
            notes: "", submittedAt: Date(timeIntervalSinceReferenceDate: 780_652_800))
        let draft = PullRequestDraft.make(for: .ingestion(pdf), handover: nil, siteURL: nil)
        let sent = draft.title + "\n" + draft.body
        #expect(draft.title == "[paper] Untitled submission")
        #expect(!sent.contains("/Users"))
        #expect(!sent.contains("secret draft"))
        #expect(PrivateText.findings(in: sent, privatePaths: ["/Users/alice"]).isEmpty)
    }

    // MARK: The footer

    static let release = PullRequestDraft.Provenance(
        appVersion: "0.3.0", isDevBuild: false, route: "edited by hand")
    static let dev = PullRequestDraft.Provenance(
        appVersion: "0.3.0", isDevBuild: true, route: "drafted by claude (sonnet)")

    @Test("the footer: a rule, the version and route, and the hidden marker")
    func footer() {
        #expect(PullRequestDraft.footer(Self.release, marker: "ccwiki-job: 20261011-142210-118-edit-prf") == """
            ---
            Opened with CCwiki 0.3.0 · edited by hand
            <!-- ccwiki-job: 20261011-142210-118-edit-prf -->
            """)
        #expect(PullRequestDraft.footer(Self.dev, marker: "ccwiki-issue: 6F1C") == """
            ---
            Opened with CCwiki 0.3.0 (CCwiki Dev, a development build) · drafted by claude (sonnet)
            <!-- ccwiki-issue: 6F1C -->
            """)
    }

    @Test("CCwiki Dev is named only in a Dev build")
    func devOnlyInDev() {
        #expect(!PullRequestDraft.footer(Self.release, marker: "m").contains("CCwiki Dev"))
        #expect(PullRequestDraft.footer(Self.dev, marker: "m").contains("CCwiki Dev"))
    }

    @Test("the body as sent: the body, a blank line, then the footer with the job's marker")
    func bodyForGitHub() {
        let draft = PullRequestDraft(title: "t", body: "\n\nWhy.\n\n" + Self.pageLine + "\n\n")
        let sent = draft.bodyForGitHub(jobID: "job-1", provenance: Self.release)
        #expect(sent == "Why.\n\n" + Self.pageLine + "\n\n---\nOpened with CCwiki 0.3.0 · edited by hand\n"
            + "<!-- ccwiki-job: job-1 -->")

        let empty = PullRequestDraft(title: "t", body: "  \n")
        #expect(empty.bodyForGitHub(jobID: "job-1", provenance: Self.release)
            == PullRequestDraft.footer(Self.release, marker: "ccwiki-job: job-1"))
    }

    static func sent(_ body: String) -> String {
        PullRequestDraft(title: "t", body: body).bodyForGitHub(jobID: "job-1", provenance: Self.release)
    }

    static var jobFooter: String { PullRequestDraft.footer(Self.release, marker: "ccwiki-job: job-1") }

    @Test("a body that ends inside a comment, a fence or a raw HTML block is closed before the footer")
    func bodyLeftOpen() {
        let footer = Self.jobFooter
        // Hidden: GitHub runs a comment to the end of the document.
        #expect(Self.sent("Why.\n\n<!-- note") == "Why.\n\n<!-- note\n-->\n\n" + footer)
        // Shown as code, the marker included.
        #expect(Self.sent("Why.\n\n```\ncode") == "Why.\n\n```\ncode\n```\n\n" + footer)
        // A shorter run does not close a fence; the closing line matches it.
        #expect(Self.sent("~~~~ swift\nlet x = 1\n~~~") == "~~~~ swift\nlet x = 1\n~~~\n~~~~\n\n" + footer)
        // Inside a list item, at the item's indent.
        #expect(Self.sent("- A list:\n\n  ```\n  code") == "- A list:\n\n  ```\n  code\n  ```\n\n" + footer)
        #expect(Self.sent("<pre>\nkept") == "<pre>\nkept\n</pre>\n\n" + footer)
        #expect(Self.sent("<?php echo 1;") == "<?php echo 1;\n?>\n\n" + footer)
    }

    @Test("a body whose blocks are all closed is sent as it is")
    func bodyClosed() {
        for body in [
            "Why.\n\n<!-- a note -->",
            "A `<!--` in code, and an inline <!-- that a blank line ends",
            "```\ncode\n```",
            "~~~\n```\n~~~",
            "```a``` is inline code",
            "    ```\n    indented code",
            "<pre>x</pre>",
            "<!DOCTYPE html>",
        ] {
            #expect(Self.sent(body) == body + "\n\n" + Self.jobFooter, "\(body)")
        }
    }
}
