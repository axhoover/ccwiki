import Foundation
import Testing
@testable import CCwiki

/// Markdown links to wiki pages, `[text](slug#anchor)`: parsing where
/// markdown-it would, resolving like wikilinks, and reaching the backlinks and
/// the render request.
///
/// The wiki writes this form wherever a link's text holds math, which a
/// wikilink alias cannot. The expectations below were checked against
/// markdown-it with `ccwiki.js`'s rules loaded, which is what renders them.
struct MarkdownLinkTests {

    private func destinations(_ text: String) -> [String] {
        MarkdownLinkParser.links(in: text).map(\.destination)
    }

    // MARK: Parsing

    @Test("the forms the wiki writes parse, with their math intact")
    func wikiForms() {
        let found = destinations(
            "See [$k$-Linear assumption](bilinear-map-assumptions#k-linear-assumption) and "
                + #"[IND\$-CPA Security](<symmetric-key-encryption#ind-cpa-security>)."#)
        #expect(found == [
            "bilinear-map-assumptions#k-linear-assumption",
            "symmetric-key-encryption#ind-cpa-security",
        ])

        // Brackets, bars and `<` inside math do not end the link text.
        let bounded = destinations(#"[$|x| \le [B]$-bounded](<x#bounded>)"#)
        let majority = destinations("[Honest majority ($t < n/2$)](honest-majority#t-n2)")
        #expect(bounded == ["x#bounded"])
        #expect(majority == ["honest-majority#t-n2"])
    }

    @Test("a link covers its whole source")
    func ranges() throws {
        let text = "Before [a](b) after"
        let links = MarkdownLinkParser.links(in: text)
        let link = try #require(links.first)
        let source = String(text[link.range])
        #expect(source == "[a](b)")
    }

    @Test("what is not a wiki link")
    func notLinks() {
        let texts = [
            "`[a](b)` in code",
            "```\n[a](b)\n```",
            "%%[a](b)%%",
            "$[a](b)$ in math",
            "$$\n[a](b)\n$$",
            "![alt](picture.png)",
            "[see [[wikilink]]](b)",
            "[x](https://example.com)",
            "[x](mailto:someone@example.com)",
            "[x](#same-page)",
            "[x]()",
            "\\[a](b)",
            "[a] (b)",
        ]
        for text in texts {
            let found = destinations(text)
            #expect(found.isEmpty, "\(text) holds no wiki link")
        }
    }

    @Test("nesting, titles, parentheses, escapes and line breaks")
    func destinationGrammar() {
        let cases: [(String, [String])] = [
            ("[a [b] c](dest)", ["dest"]),
            ("[a](dest \"Title\")", ["dest"]),
            ("[a](dest(with)parens)", ["dest(with)parens"]),
            ("[a](\n  dest\n)", ["dest"]),
            // Link text cannot hold a link: the inner one is the link.
            ("[a [b](c) d](e)", ["c"]),
            ("[a](<KEY - Some Title>)", ["KEY - Some Title"]),
            (#"[a](b\_c)"#, ["b_c"]),
            ("[a](b&amp;c)", ["b&c"]),
            ("[[wikilink]] then [a](b)", ["b"]),
            // An image inside link text is fine; the image itself is no link.
            ("[![img](pic.png)](page)", ["page"]),
        ]
        for (text, expected) in cases {
            let found = destinations(text)
            #expect(found == expected, "parsing \(text)")
        }
    }

    @Test("unmatched brackets do not make the scan blow up")
    func unmatchedBrackets() {
        // Each `[` here searches the rest of the paragraph for its `]`. Without
        // the scanner's cache, forty of them take some hundred million label
        // scans, and this test does not finish.
        let unmatched = destinations(String(repeating: "[a ", count: 40) + "[x](y)")
        let intervals = destinations(String(repeating: "[0, 1) ", count: 12) + "[t](d)")
        #expect(unmatched == ["y"])
        #expect(intervals == ["d"])

        // A label holding a link is no link, however many brackets come
        // first: an answer found near the depth limit, where nesting is no
        // longer looked into, is not reused at the top level.
        let nested = destinations(String(repeating: "[a ", count: 9) + "[x [y](z)](w)")
        #expect(nested == ["z"])
    }

    @Test("math stops where its block does")
    func mathStopsAtBlocks() {
        // Two list items are two blocks, so the `$`s cannot pair.
        let listItems = destinations("- $x\n- [a](b)$")
        // One paragraph across a line break is one block, so they do.
        let paragraph = destinations("$x\n[a](b)$")
        #expect(listItems == ["b"])
        #expect(paragraph.isEmpty)
    }

    @Test("a markdown link becomes the wikilink it stands for")
    func asWikilink() throws {
        let text = "[k-Lin](bilinear-map-assumptions#k-linear-assumption) [p](<KEY%20-%20Title>) [e](page#)"
        let links = MarkdownLinkParser.links(in: text).map(\.wikilink)
        try #require(links.count == 3)
        let anchored = links[0]
        #expect(anchored.target == "bilinear-map-assumptions")
        #expect(anchored.rawAnchor == "#k-linear-assumption")
        #expect(anchored.alias == nil)
        #expect(!anchored.isEmbed)

        let encoded = links[1]
        #expect(encoded.target == "KEY - Title")
        #expect(encoded.rawAnchor == nil)
        // An empty fragment is no anchor.
        #expect(links[2].rawAnchor == nil)
    }

    @Test("decodeURI keeps the escapes of reserved characters")
    func decodeURI() {
        let spaces = MarkdownLink.decodeURI("KEY%20-%20Title")
        let hash = MarkdownLink.decodeURI("a%23b")
        let utf8 = MarkdownLink.decodeURI("%CF%86-hiding")
        let malformed = MarkdownLink.decodeURI("100%-secure")
        #expect(spaces == "KEY - Title")
        #expect(hash == "a%23b")
        #expect(utf8 == "φ-hiding")
        #expect(malformed == "100%-secure")
    }

    // MARK: Resolution

    static let fixture: [String: String] = [
        "Primitives/a.md": """
            ---
            type: primitive
            status: draft
            title: A
            aliases: []
            ---

            # A

            Uses [$x$ text](b-page#sec) here.
            And [missing](nowhere), and [[b-page]] too.
            """,
        "Primitives/b-page.md": """
            ---
            type: primitive
            status: draft
            title: B
            aliases: []
            ---

            # B

            ## Sec
            """,
    ]

    static func makeIndex() throws -> (WikiIndex, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-markdown-links-\(UUID().uuidString)")
        for (path, contents) in fixture {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (WikiIndex.build(contentRoot: root), root)
    }

    @Test("markdown links resolve like wikilinks, in source order with them")
    func resolution() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(index.pages["Primitives/a.md"])

        let targets = index.links(on: page).map { $0.target }
        try #require(targets.count == 3)
        let section = WikiIndex.Target.page(path: "Primitives/b-page.md", anchor: "sec")
        let whole = WikiIndex.Target.page(path: "Primitives/b-page.md", anchor: nil)
        #expect(targets[0] == section)
        #expect(!targets[1].isResolved, "[missing](nowhere) has no target")
        #expect(targets[2] == whole)
    }

    @Test("a page reached only by a markdown link has a backlink, with prose context")
    func backlinks() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        let incoming = index.backlinkMap()["Primitives/b-page.md"] ?? []
        // Two links from the page, one backlink.
        #expect(incoming.map(\.sourcePath) == ["Primitives/a.md"])
        #expect(incoming.map(\.context) == ["Uses x text here."])
    }

    @Test("the render request maps a markdown link by its destination")
    func renderRequest() throws {
        let (index, root) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(index.pages["Primitives/a.md"])

        let request = PageRenderer(index: index).request(for: page)
        let resolved = request.links["b-page#sec"]
        #expect(resolved?.href == CCwikiURL.page(path: "Primitives/b-page.md", anchor: "sec"))
        #expect(resolved?.kind == "page")
        #expect(resolved?.external == false)
        #expect(request.links["nowhere"] == nil)
        #expect(request.links["[[b-page]]"] != nil)
        #expect(request.notices.map(\.text) == ["1 link on this page has no target."])
        #expect(request.markdown == page.body, "a primitive page gets no relation-meta line")
    }
}
