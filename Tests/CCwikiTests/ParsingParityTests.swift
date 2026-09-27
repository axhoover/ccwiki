import Foundation
import Testing
@testable import CCwiki

/// Places where the app's own parsing used to drift from the site's, each
/// pinned to what markdown-it and Quartz actually do.
struct ParsingParityTests {

    @Test("ATX headings: indent, closing sequences and tabs, as markdown-it reads them")
    func atxHeadings() throws {
        func heading(_ line: String) -> (Int, String)? {
            WikiPage.atxHeading(Substring(line)).map { ($0.level, $0.text) }
        }
        #expect(heading("## Syntax")! == (2, "Syntax"))
        #expect(heading("## Syntax ##")! == (2, "Syntax"), "closing sequence dropped")
        #expect(heading("   ### Indented")! == (3, "Indented"), "up to three spaces")
        #expect(heading("    #### Code") == nil, "four spaces is code")
        #expect(heading("##\tTabbed")! == (2, "Tabbed"))
        #expect(heading("## C#")! == (2, "C#"), "a # not after a space stays")
        #expect(heading("##NoSpace") == nil)
        #expect(heading("####### Seven") == nil)
        #expect(heading("## ##")! == (2, ""), "all hashes is an empty heading")
    }

    @Test("heading ids ignore the closing sequence and the indent")
    func headingIDs() {
        let page = WikiPage(path: "Primitives/x.md", text: """
            ---
            title: X
            ---
            ## Syntax ##
              ## Security
            """)
        #expect(page.headings().map(\.id) == ["syntax", "security"])
    }

    @Test("a plain aliases value splits on commas, as Quartz's coerceToArray does")
    func aliasesSplit() {
        let page = WikiPage(path: "Primitives/prf.md", text: """
            ---
            title: Pseudorandom function
            aliases: PRF, PRFs ,
            ---
            """)
        #expect(page.aliases == ["PRF", "PRFs"])

        let list = WikiPage(path: "Primitives/prp.md", text: """
            ---
            aliases: [PRP, "block cipher, ideal"]
            ---
            """)
        #expect(list.aliases == ["PRP", "block cipher, ideal"], "a real list is left alone")
    }

    @Test("a quoted value followed by a comment loses the comment and its quotes")
    func quotedComment() {
        #expect(Frontmatter.quotedValue(#""Foo" # note"#) == #""Foo""#)
        #expect(Frontmatter.quotedValue("'It''s' # note") == "'It''s'")
        #expect(Frontmatter.quotedValue(#""a \" b" # c"#) == #""a \" b""#)
        #expect(Frontmatter.quotedValue(#""Foo" bar"#) == nil, "not only a comment after it")
        #expect(Frontmatter.quotedValue("#P") == nil, "unquoted values are untouched")

        let page = WikiPage(path: "Complexity/sharp-p.md", text: """
            ---
            title: "#P" # counting
            ---
            """)
        #expect(page.title == "#P")
    }
}
