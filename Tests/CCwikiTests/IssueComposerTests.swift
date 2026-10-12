import Foundation
import Testing
@testable import CCwiki

/// The issue sheet's proposed text (plans/corrections.md §8.2): the page
/// line, a permalink to the lines at the commit the reader showed, the quote
/// in a fence, and an empty paragraph to write in.
struct IssueComposerTests {

    static let repository = "axhoover/cryptology.city"

    static let target = CorrectionTarget(
        pagePath: "Primitives/pseudorandom-function.md", pageTitle: "Pseudorandom function",
        baseCommit: "ab81f02", section: CorrectionTarget.Section(id: "security", title: "Security", level: 2),
        lines: LineRange(first: 42, last: 44), region: .body,
        quote: "every efficient $\\calA$", excerpt: "every efficient $\\calA$")

    @Test("the permalink is at the commit, plain, with a line range")
    func permalink() {
        let url = IssueComposer.permalink(
            repository: Self.repository, commit: "ab81f02",
            path: "content/Primitives/pseudorandom-function.md",
            lines: LineRange(first: 42, last: 44))
        #expect(url.absoluteString == "https://github.com/axhoover/cryptology.city/blob/ab81f02/"
            + "content/Primitives/pseudorandom-function.md?plain=1#L42-L44")
    }

    @Test("one line is #L42; the whole page has no anchor")
    func lineAnchors() {
        let one = IssueComposer.permalink(
            repository: Self.repository, commit: "c0ffee", path: "content/a.md",
            lines: LineRange(first: 42, last: 42))
        #expect(one.absoluteString.hasSuffix("/content/a.md?plain=1#L42"))
        let page = IssueComposer.permalink(
            repository: Self.repository, commit: "c0ffee", path: "content/a.md", lines: nil)
        #expect(page.absoluteString.hasSuffix("/content/a.md?plain=1"))
    }

    @Test("each segment of the path is percent-encoded: spaces, & and non-ASCII")
    func encoding() {
        let url = IssueComposer.permalink(
            repository: Self.repository, commit: "ab81f02",
            path: "content/References/BR93 - Random Oracles & Proofs é.md",
            lines: LineRange(first: 3, last: 4))
        #expect(url.absoluteString == "https://github.com/axhoover/cryptology.city/blob/ab81f02/"
            + "content/References/BR93%20-%20Random%20Oracles%20%26%20Proofs%20%C3%A9.md"
            + "?plain=1#L3-L4")
    }

    @Test("the fence is one backtick longer than any run in the quote, and at least three")
    func fence() {
        #expect(IssueComposer.fence(for: "plain text") == "```")
        #expect(IssueComposer.fence(for: "a `code` span") == "```")
        #expect(IssueComposer.fence(for: "a ``` fence") == "````")
        #expect(IssueComposer.fence(for: "a ````` long run and ``") == "``````")
    }

    @Test("the body: the page line, the permalink alone on its line, the quote in a text fence")
    func body() {
        let site = URL(string: "https://cryptology.city/Primitives/pseudorandom-function")
        let body = IssueComposer.body(for: Self.target, siteURL: site, repository: Self.repository)
        let paragraphs = body.components(separatedBy: "\n\n")
        #expect(paragraphs[0] == "**Page:** [Pseudorandom function]"
            + "(https://cryptology.city/Primitives/pseudorandom-function#security), "
            + "`content/Primitives/pseudorandom-function.md`, lines 42–44 (“Security”)")
        #expect(paragraphs[1] == "https://github.com/axhoover/cryptology.city/blob/ab81f02/"
            + "content/Primitives/pseudorandom-function.md?plain=1#L42-L44")
        #expect(paragraphs[2] == "```text\nevery efficient $\\calA$\n```")
    }

    @Test("a quote with a fence in it gets a longer fence")
    func quoteWithFence() {
        var target = Self.target
        target.quote = "```pseudocode\n\\begin{algorithm}\n```"
        let body = IssueComposer.body(for: target, siteURL: nil, repository: Self.repository)
        #expect(body.contains("````text\n```pseudocode\n\\begin{algorithm}\n```\n````"))
    }

    @Test("the body ends with an empty paragraph, where the reader writes")
    func emptyParagraph() {
        let body = IssueComposer.body(for: Self.target, siteURL: nil, repository: Self.repository)
        #expect(body.hasSuffix("```\n\n"))
        #expect(!body.hasSuffix("\n\n\n"))
    }

    @Test("the whole page: no lines, no quote, and the page line says so")
    func wholePage() {
        var target = Self.target
        target.lines = nil
        target.quote = nil
        target.section = nil
        let body = IssueComposer.body(for: target, siteURL: nil, repository: Self.repository)
        #expect(body == "**Page:** Pseudorandom function, `content/Primitives/pseudorandom-function.md`\n\n"
            + "https://github.com/axhoover/cryptology.city/blob/ab81f02/"
            + "content/Primitives/pseudorandom-function.md?plain=1\n\n")
    }

    @Test("the title is the page and the section, or the page alone")
    func title() {
        #expect(IssueComposer.proposedTitle(for: Self.target) == "Pseudorandom function: Security")
        var whole = Self.target
        whole.section = nil
        #expect(IssueComposer.proposedTitle(for: whole) == "Pseudorandom function")
        whole.section = CorrectionTarget.Section(
            id: "pseudorandom-function", title: "Pseudorandom function", level: 1)
        #expect(IssueComposer.proposedTitle(for: whole) == "Pseudorandom function")
    }

    @Test("the footer shows its visible line, and never the hidden marker")
    func visibleFooter() {
        let footer = "---\nOpened with CCwiki 0.3.0 (CCwiki Dev, a development build) · reported from the reader\n"
            + "<!-- ccwiki-issue: 1234 -->"
        #expect(IssueComposer.visibleFooter(footer)
            == "Opened with CCwiki 0.3.0 (CCwiki Dev, a development build) · reported from the reader")
        #expect(IssueComposer.visibleFooter("").isEmpty)
    }

    @Test("a retry finds the issue whose body carries the sheet's marker, in gh's list")
    func lookup() throws {
        let list = #"""
            [{"url": "https://github.com/axhoover/cryptology.city/issues/9", "body": "Other.\n<!-- ccwiki-issue: B -->"},
             {"url": "https://github.com/axhoover/cryptology.city/issues/8", "body": "Text.\n---\nOpened with CCwiki\n<!-- ccwiki-issue: A -->"}]
            """#
        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/issues/8"))
        #expect(IssueComposer.lookup(marker: "A", inList: list) == .found(url))
        #expect(IssueComposer.lookup(marker: "C", inList: list) == .notFound)
        #expect(IssueComposer.lookup(marker: "A", inList: "[]") == .notFound)
        // What cannot be read is never taken for "not there".
        #expect(IssueComposer.lookup(marker: "A", inList: "") == .unknown)
        #expect(IssueComposer.lookup(marker: "A", inList: "gh: HTTP 502") == .unknown)
    }

    @Test("a generated passage says where its fix belongs; the page's own text says nothing")
    func regionNote() {
        #expect(IssueComposer.regionNote(for: Self.target) == nil)
        var generated = Self.target
        generated.region = .generated
        #expect(IssueComposer.regionNote(for: generated)?.contains("reduction page") == true)
        var meta = Self.target
        meta.region = .frontmatter
        meta.lines = LineRange(first: 2, last: 12)
        #expect(IssueComposer.regionNote(for: meta)?.contains("frontmatter (lines 2–12)") == true)
    }

    @Test("the issue's number comes from its URL")
    func issueNumber() throws {
        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/issues/123"))
        #expect(IssueComposer.issueNumber(in: url) == 123)
        let other = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/7"))
        #expect(IssueComposer.issueNumber(in: other) == nil)
    }
}
