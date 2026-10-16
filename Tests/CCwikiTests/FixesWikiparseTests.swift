import Foundation
import Testing
@testable import CCwiki

/// The wiki model's parsing fixes: CRLF pages, github-slugger's kept set,
/// heading plain text, the site root as a link target, flush-left YAML
/// sequences, and aliases that end in `.md`.
@Suite("Wiki parsing fixes")
struct FixesWikiparseTests {

    /// An index over `pages`, as a library load assembles one.
    private static func index(_ pages: [WikiPage]) -> WikiIndex {
        WikiIndex.assemble(
            contentRoot: URL(fileURLWithPath: "/nonexistent/content"),
            files: pages.map(\.path),
            pages: Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) }))
    }

    /// The first wikilink in `text`, resolved from `source`.
    private static func resolve(
        _ text: String, from source: String, in index: WikiIndex
    ) throws -> WikiIndex.Target {
        let link = try #require(WikilinkParser.links(in: text).first, "no wikilink in \(text)")
        return index.resolve(link, from: source)
    }

    // MARK: CRLF pages

    @Test("a CRLF page's body starts after its frontmatter, not at the end of the file")
    func crlfBody() {
        let text = "---\r\ntitle: X\r\n---\r\n# X\r\n"
        let page = WikiPage(path: "Primitives/x.md", text: text)
        #expect(page.title == "X")
        #expect(page.body == "# X\r\n")
        #expect(ReviewPayload.frontmatterLineCount(text) == 3)

        let bom = WikiPage(path: "Primitives/x.md", text: "\u{FEFF}---\r\ntitle: X\r\n---\r\nBody\r\n")
        #expect(bom.body == "Body\r\n")
    }

    @Test("a CRLF body is read line by line: headings, fences and code spans")
    func crlfLines() {
        let page = WikiPage(path: "Primitives/foo.md", text: [
            "---", "title: Foo", "---", "# Foo", "", "## Syntax", "Text [[bar]] here.", "",
            "```", "## Not a heading [[fenced]]", "```", "`[[spanned]]` and [[baz]]", "",
        ].joined(separator: "\r\n"))
        #expect(page.headings().map(\.id) == ["foo", "syntax"])
        #expect(page.headings().map(\.text) == ["Foo", "Syntax"])
        #expect(WikilinkParser.links(in: page.body).map(\.target) == ["bar", "baz"])
        // A fence on the first line closes; the rest of the page is not code.
        #expect(WikilinkParser.links(in: "```\r\ncode\r\n```\r\n[[outside]]\r\n").map(\.target) == ["outside"])
    }

    @Test("a backlink's context is its own line on a CRLF page")
    func crlfBacklinkContext() {
        let index = Self.index([
            WikiPage(path: "Primitives/foo.md",
                     text: "---\r\ntitle: Foo\r\n---\r\n# Foo\r\nFirst.\r\nText [[bar]] here.\r\nLast.\r\n"),
            WikiPage(path: "Primitives/bar.md", text: "---\r\ntitle: Bar\r\n---\r\n# Bar\r\n"),
        ])
        #expect(index.backlinkMap()["Primitives/bar.md"]?.map(\.context) == ["Text bar here."])
    }

    @Test("DiffGuard reads a CRLF page's headings line by line, for its variants")
    func crlfVariantHeading() throws {
        let page = try DiffGuardTests.fixture("pseudorandom-function.md")
            .replacingOccurrences(of: "\n", with: "\r\n")
        func stale(_ old: String, _ new: String) -> Bool {
            let changed = page.replacingOccurrences(of: old, with: new)
            let findings = DiffGuardTests.check([DiffGuardTests.modified(old: page, new: changed)])
            return DiffGuardTests.finding(.derivedFilesStale, in: findings) != nil
        }
        // `variants` names `#weak-prfs`; its heading reworded under the same
        // anchor changes the variant's title. Another heading does not.
        #expect(stale("## Weak PRFs\r\n", "## Weak prfs\r\n"))
        #expect(!stale("## Puncturable PRFs\r\n", "## Puncturable pseudorandom functions\r\n"))
    }

    // MARK: github-slugger's kept set

    @Test("slug keeps what github-slugger 2.0.0 keeps, and lowercases as JavaScript does")
    func slugMatchesUpstream() {
        // Each expectation is the vendored github-slugger's output in node.
        let cases: [(String, String)] = [
            ("O(n²) attack", "on-attack"),
            ("x₁ and x₂", "x-and-x"),
            ("2³² queries", "2-queries"),
            ("½", ""),
            ("a‿b", "a‿b"),
            ("Ⓐ", "ⓐ"),
            ("Ⅻ", "ⅻ"),
            ("x^2 + y_2", "x2--y_2"),
            // Final_Sigma: a capital sigma that ends a word lowercases to ς.
            ("ΟΔΟΣ", "οδος"),
            ("ΣΣ", "σς"),
            ("Σ-protocols", "σ-protocols"),
            ("ΑΣ'Β", "ασβ"),
            ("ΑΣ'", "ας"),
            // U+0870, an Arabic letter from Unicode 14.0: newer than the
            // regex, which deletes it.
            ("a\u{0870}b", "ab"),
        ]
        for (input, expected) in cases {
            #expect(GithubSlugger.slug(input) == expected, "slug(\(input))")
        }
    }

    @Test("a link to a heading with a superscript lands on the renderer's id")
    func superscriptAnchor() {
        let page = WikiPage(path: "Primitives/x.md", text: "---\ntitle: X\n---\n## An O(n²) attack\n")
        #expect(page.headings().map(\.id) == ["an-on-attack"])
        #expect(QuartzSlug.splitAnchor("x#An O(n²) attack").anchor == "#an-on-attack")
    }

    // MARK: Heading plain text

    @Test("heading plain text keeps the underscores markdown-it keeps")
    func headingPlainText() {
        let cases: [(String, String)] = [
            ("The _k_-Lin assumption", "The k-Lin assumption"),
            (#"Security of $\mathsf{Enc}_k$"#, #"Security of \mathsf{Enc}_k"#),
            (#"$\mathsf{CPA}_{\calA}$ security"#, #"\mathsf{CPA}_{\calA} security"#),
            ("snake_case and __init__", "snake_case and init"),
            ("_private", "_private"),
            ("`code_x_` span", "code_x_ span"),
            (#"\_escaped\_"#, "_escaped_"),
            ("[[page#Section]] notes", "page notes"),
            ("[[page#Section|Alias]] notes", "Alias notes"),
            ("[[a_b_c]] and [text_x_](url)", "a_b_c and text_x_"),
            ("_a $x$ b_", "a x b"),
            ("$ x $ padded", "x padded"),
            ("**Bold** and *it*", "Bold and it"),
        ]
        for (input, expected) in cases {
            #expect(WikiPage.Heading.plainText(input) == expected, "plainText(\(input))")
        }
        #expect(GithubSlugger.slug(WikiPage.Heading.plainText("The _k_-Lin assumption"))
            == "the-k-lin-assumption")
        #expect(GithubSlugger.slug(WikiPage.Heading.plainText(#"Security of $\mathsf{Enc}_k$"#))
            == "security-of-mathsfenc_k")
    }

    @Test("heading ids match the renderer's, underscores, math, code and links included")
    func headingIDsMatchRenderer() throws {
        let headings = [
            "The _k_-Lin assumption", #"Security of $\mathsf{Enc}_k$"#,
            #"$\mathsf{CPA}_{\calA}$ security"#, "Game $G_1$", "snake_case names", "_private",
            "__init__ method", "a__b", "MIP* = RE", "An O(n²)-Query Attack",
            "[[page#Section]] notes", "[[page|]] empty alias", "`code_x_` span", "`` a`b `` double",
            "$ x $ padded", #"\_escaped\_ underscores"#, #"\$5 and \$6"#, "_a $x$ b_", "$a$_b_",
            "_x_y_", "(_x_)", "_ spaced _", "Fiat_Shamir_ transform", "*_mixed_*",
            "Nested _a __b__ c_", "Link [a](b) and [[c]]", "ΑΣ final", #"$\ZZ_p$ and $\FF_2$"#,
            "Bound on $[[a]]$", "The $[[prf]]$ game", "Bound on $[[a|b]]$",
        ]
        let markdown = headings.map { "## " + $0 }.joined(separator: "\n\n") + "\n"
        let script = try MarkdownScript.load()
        let toc = try script.json(
            "(function () { var env = { links: {} }; md.render(" + MarkdownScript.literal(markdown)
                + ", env); return env.toc.map(function (h) { return h.id; }); })()")
        let rendered = try #require(toc as? [String])
        let page = WikiPage(path: "Primitives/x.md", text: markdown)
        #expect(page.headings().map(\.id) == rendered)
        #expect(rendered.count == headings.count)
    }

    @Test("heading ids are made after the page's arrows, dashes and ellipses, as the renderer makes them")
    func headingIDsAfterTypography() throws {
        let headings = [
            "A -> B", "A --> B", "A <- B", "A <-- B", "A => B", "A <= B", "A->B", "A ---> B", "A <--- B",
            "A -- B", "A--B", "A --- B", "Wait...", "OWF -> PRG -> PRF",
            "`a -> b` code", "$x -> y$ math", "x `->` y -> z", "a -$x$-> b",
            #"A \-> B"#, #"A \-\- B"#, "_a -> b_", "a -_-_ b", "[a -> b](url) link",
            "[[x|a -> b]] alias", "[[x]]-->y", #"Pages [[x|IND\$-CPA]]"#, "[[x|AT&amp;T]] notes",
            "a &#45;&#45;> b", "AT&amp;T", "x&#97;_y_",
        ]
        let markdown = headings.map { "## " + $0 }.joined(separator: "\n\n") + "\n"
        let script = try MarkdownScript.load()
        let toc = try script.json(
            "(function () { var env = { links: {} }; md.render(" + MarkdownScript.literal(markdown)
                + ", env); return env.toc.map(function (h) { return h.id; }); })()")
        let rendered = try #require(toc as? [String])
        let page = WikiPage(path: "Primitives/x.md", text: markdown)
        #expect(page.headings().map(\.id) == rendered)
        #expect(rendered.count == headings.count)
        #expect(page.headings().first?.id == "a--b", "the page's id, not a---b")

        #expect(WikiPage.Heading.plainText("A -> B") == "A → B")
        #expect(WikiPage.Heading.plainText("$x -> y$ and `a -- b`") == "x -> y and a -- b",
                "never in math or code")
        #expect(WikiPage.Heading.plainText(#"[[x|IND\$-CPA]] and [[x|a -> b]]"#) == "IND$-CPA and a -> b",
                "an alias decoded, and as written otherwise")
        #expect(WikiPage.Heading.plainText("AT&amp;T -- x&#97;_y_") == "AT&T — xay")
    }

    @Test("a URL's, an autolink's or an address's text keeps its dashes, as the page keeps them")
    func headingIDsLeaveLinksAlone() throws {
        let headings = [
            "See https://example.com/a--b", "See <https://example.com/a--b>", "See https://example.com/a->b",
            "Mail a--b@example.com", "Mail <a--b@x.com>", "mailto:a--b@x.com", "See //example.com/a--b",
            "x--https://a.com/b--c", "https://x.com -> y", "_https://x.com/a--b_", "*https://x.com/a--b*",
            "[https://x.com/a--b](u) link", "a--b.com/x--y", "<1x--y>", "<javascript:a--b>",
            #"\https://a--b@c.org"#, "https://[[a]]--b", "a``Σ quotes",
        ]
        let markdown = headings.map { "## " + $0 }.joined(separator: "\n\n") + "\n"
        let script = try MarkdownScript.load()
        let toc = try script.json(
            "(function () { var env = { links: {} }; md.render(" + MarkdownScript.literal(markdown)
                + ", env); return env.toc.map(function (h) { return h.id; }); })()")
        let rendered = try #require(toc as? [String])
        let page = WikiPage(path: "Primitives/x.md", text: markdown)
        #expect(page.headings().map(\.id) == rendered)
        #expect(rendered.count == headings.count)
        #expect(page.headings().first?.id == "see-httpsexamplecoma--b", "the page's id, not see-httpsexamplecomab")

        #expect(WikiPage.Heading.plainText("See https://example.com/a--b -> c")
                == "See https://example.com/a--b → c")
        #expect(WikiPage.Heading.plainText("See <https://example.com/a--b>") == "See https://example.com/a--b")
        #expect(WikiPage.Heading.plainText("Mail a--b@example.com -- now") == "Mail a--b@example.com — now")
        #expect(WikiPage.Heading.plainText("[https://x.com/a--b](u)") == "https://x.com/a—b",
                "a markdown link's text is educated: markdown-it makes no link inside it")
    }

    @Test("a wikilink inside math is the math's source, never a placeholder")
    func wikilinkInsideMath() {
        #expect(WikiPage.Heading.plainText("Bound on $[[a]]$") == "Bound on [[a]]")
        #expect(WikiPage.Heading.plainText("The $[[prf]]$ game") == "The [[prf]] game")
        #expect(WikiPage.Heading.plainText("[[a]] and $[[b|c]]$") == "a and [[b|c]]")
    }

    // MARK: The site root

    @Test("[[index]], [[/]] and [[./]] link to the home page, as on the site")
    func rootLinks() throws {
        let home = WikiPage(path: "index.md", text: "---\ntitle: Cryptology City\n---\n# Home\n## Browse\n")
        let index = Self.index([
            home,
            WikiPage(path: "Primitives/foo.md", text: "---\ntitle: Foo\n---\n# Foo\n"),
        ])
        #expect(home.wikilink == "[[index]]")
        for link in [home.wikilink, "[[index|home]]", "[[/]]", "[[./]]"] {
            #expect(try Self.resolve(link, from: "Primitives/foo.md", in: index)
                == .page(path: "index.md", anchor: nil), "\(link)")
        }
        #expect(try Self.resolve("[[index#Browse]]", from: "Primitives/foo.md", in: index)
            == .page(path: "index.md", anchor: "browse"))
        #expect(try Self.resolve("[[index]]", from: "index.md", in: index)
            == .page(path: "index.md", anchor: nil))

        let homeless = Self.index([WikiPage(path: "Primitives/foo.md", text: "# Foo\n")])
        #expect(try Self.resolve("[[index]]", from: "Primitives/foo.md", in: homeless).isResolved == false)
    }

    // MARK: Flush-left sequences

    @Test("a sequence flush left under its key is read, and the fence still closes")
    func flushLeftSequence() throws {
        let page = WikiPage(path: "Primitives/prf.md", text: """
            ---
            aliases:
            - PRF
            - "P: Q"
            title: Pseudorandom function
            source:
            - https://example.org/a#b
            ---
            # Pseudorandom function

            """)
        #expect(page.aliases == ["PRF", "P: Q"])
        #expect(page.title == "Pseudorandom function")
        #expect(page.frontmatter.list("source") == ["https://example.org/a#b"])
        #expect(page.body == "# Pseudorandom function\n")

        let last = WikiPage(path: "Primitives/prp.md", text: "---\naliases:\n- PRP\n---\n# PRP\n")
        #expect(last.aliases == ["PRP"])
        #expect(last.body == "# PRP\n")

        let indented = WikiPage(path: "Primitives/owf.md", text: "---\naliases:\n  - OWF\n  - OWFs\n---\n")
        #expect(indented.aliases == ["OWF", "OWFs"])

        let index = Self.index([page, WikiPage(path: "Primitives/foo.md", text: "# Foo\n")])
        #expect(try Self.resolve("[[PRF]]", from: "Primitives/foo.md", in: index)
            == .page(path: "Primitives/prf.md", anchor: nil))
    }

    // MARK: Aliases ending in .md

    @Test("an alias ending in .md is slugged as Quartz slugs it, with .md kept")
    func mdAlias() throws {
        let index = Self.index([
            WikiPage(path: "Primitives/notes-page.md", text: "---\ntitle: Notes\naliases: [Notes.md]\n---\n"),
            WikiPage(path: "Primitives/foo.md", text: "# Foo\n"),
        ])
        #expect(index.allSlugs.contains("Notes.md"))
        #expect(!index.allSlugs.contains("Notes"))
        #expect(try Self.resolve("[[Notes]]", from: "Primitives/foo.md", in: index).isResolved == false)
        #expect(try Self.resolve("[[Notes.md.md]]", from: "Primitives/foo.md", in: index)
            == .page(path: "Primitives/notes-page.md", anchor: nil))
    }
}
