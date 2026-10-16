import Foundation
import Testing
@testable import CCwiki

/// Every block the reader renders says which lines of the Markdown it came
/// from (plans/corrections.md §3.2), and `SourceLineMap` takes those lines
/// back to the file, past the frontmatter and around the relation-meta line.
/// `ccwiki-markdown.js` runs in JavaScriptCore here, as the web view runs it.
struct SourceStampTests {

    /// A reduction page with one of every kind of block a selection can land
    /// in: a list, display math, pseudocode, a table, a callout, and a
    /// generated "Participates in" region.
    static let fileText = #"""
        ---
        type: reduction
        status: draft
        title: PRF from OWF
        from: owf
        to: prf
        ---

        # Pseudorandom functions from one-way functions

        A paragraph with $F_k$ in it.

        - one
        - two
          wrapped

        $$
        \Pr[F_k(x) = y] \le \epsilon
        $$

        ```pseudocode
        \begin{algorithm}
        \caption{Game}
        \end{algorithm}
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        > [!note] Heads up
        >
        > Body of the note.

        <!-- BEGIN GENERATED participates-in checksum=865206d47c53 -->
        ## Participates in

        - [[pseudorandom-function]]
        <!-- END GENERATED participates-in -->

        Last paragraph.
        """#

    static let metaLine = "Reduction · from [[one-way-function]] <!-- relation-meta -->"

    /// What the reader renders: the body, with the relation-meta line
    /// spliced under the H1 by the renderer's own function.
    static var renderedMarkdown: String {
        RelationMeta.insertUnderH1(metaLine, into: WikiPage(path: "Reductions/x.md", text: fileText).body)
    }

    static let fileLines = SourceLineMap.lines(of: Substring(fileText)).map(String.init)

    private let map = SourceLineMap(fileText: Self.fileText, renderedMarkdown: Self.renderedMarkdown)

    private func stampedBlocks() throws -> [StampedBlock] {
        let script = try MarkdownScript.load()
        return StampedBlock.all(in: try script.render(Self.renderedMarkdown))
    }

    /// The file's lines for a block, or nil if it maps outside the body.
    private func bodyLines(_ block: StampedBlock) -> [String]? {
        guard case .body(let lines) = map.location(ofRendered: block.lines) else { return nil }
        return Array(Self.fileLines[(lines.first - 1)...(lines.last - 1)])
    }

    private func first(
        _ blocks: [StampedBlock], tag: String, class name: String = ""
    ) throws -> StampedBlock {
        try #require(blocks.first { $0.tag == tag && (name.isEmpty || $0.className.contains(name)) })
    }

    @Test("JavaScriptCore loads the vendored bundles and ccwiki-markdown.js")
    func loads() throws {
        let script = try MarkdownScript.load()
        let kind = try script.evaluate("typeof CCwikiMarkdown.reviewEntries;")?.toString()
        #expect(kind == "function")
    }

    @Test("every stamped block maps to file lines inside the file")
    func everyBlockMaps() throws {
        let blocks = try stampedBlocks()
        #expect(blocks.count >= 12)
        for block in blocks {
            let location = try #require(map.location(ofRendered: block.lines), "\(block)")
            switch location {
            case .body(let lines), .frontmatter(let lines):
                #expect(lines.first >= 1 && lines.last <= Self.fileLines.count, "\(block)")
                #expect(lines.first <= lines.last, "\(block)")
            }
        }
    }

    @Test("headings, paragraphs and the last line land on their own text")
    func prose() throws {
        let blocks = try stampedBlocks()
        let title = try first(blocks, tag: "h1")
        #expect(bodyLines(title) == ["# Pseudorandom functions from one-way functions"])
        let paragraphs = blocks.filter { $0.tag == "p" }.compactMap(bodyLines)
        #expect(paragraphs.contains(["A paragraph with $F_k$ in it."]))
        #expect(paragraphs.contains(["Last paragraph."]))
    }

    @Test("the relation-meta paragraph is the frontmatter it is made from")
    func relationMeta() throws {
        let blocks = try stampedBlocks()
        let meta = try #require(blocks.first { $0.tag == "p" && map.inserted.contains($0.lines.lowerBound) })
        #expect(map.location(ofRendered: meta.lines) == .frontmatter(LineRange(first: 2, last: 6)))
        #expect(map.inserted.count == 3, "a blank line, the line, a blank line")
    }

    @Test("a list and its wrapped item")
    func list() throws {
        let blocks = try stampedBlocks()
        let firstList = try first(blocks, tag: "ul")
        let list = try #require(bodyLines(firstList))
        #expect(list.first == "- one")
        #expect(list.contains("  wrapped"))
        let items = blocks.filter { $0.tag == "li" }.compactMap(bodyLines)
        #expect(items.first == ["- one"])
        let second = try #require(items.dropFirst().first)
        #expect(Array(second.prefix(2)) == ["- two", "  wrapped"])
    }

    @Test("a passage in a list's last item ends on its text, not on the blank line after it")
    func listEndsOnText() throws {
        let blocks = try stampedBlocks()
        let item = try #require(blocks.filter { $0.tag == "li" }.dropFirst().first)
        #expect(bodyLines(item)?.last == "", "markdown-it counts the blank line into the item")

        let page = WikiPage(path: "Reductions/x.md", text: Self.fileText)
        let selection = ReaderSelection(
            renderedLines: item.lines, text: "two wrapped", heading: nil, path: page.path,
            revision: "abc")
        let target = CorrectionTarget.make(
            page: page, fileText: Self.fileText, renderedMarkdown: Self.renderedMarkdown,
            baseCommit: "abc", selection: selection, readingHeading: nil)
        let lines = try #require(target.lines)
        #expect(Self.fileLines[lines.last - 1] == "  wrapped")
        #expect(target.excerpt == "- two\n  wrapped")
        #expect(CorrectionTarget.editorLines(
            fileText: Self.fileText, renderedMarkdown: Self.renderedMarkdown, selection: selection,
            section: nil) == lines)
    }

    @Test("a display block's lines end on its closing $$")
    func displayMath() throws {
        let block = try first(stampedBlocks(), tag: "div", class: "math-display")
        let lines = try #require(bodyLines(block))
        #expect(lines == ["$$", #"\Pr[F_k(x) = y] \le \epsilon"#, "$$"])
    }

    @Test("pseudocode is stamped apart, as ccwiki-lines, fence to fence")
    func pseudocode() throws {
        let block = try first(stampedBlocks(), tag: "pre", class: "pseudocode")
        #expect(block.isPseudocode)
        let lines = try #require(bodyLines(block))
        #expect(lines.first == "```pseudocode")
        #expect(lines.last == "```")
    }

    @Test("a table is stamped on its scrolling box, and each row on its own")
    func table() throws {
        let blocks = try stampedBlocks()
        let box = try first(blocks, tag: "div", class: "table-scroll")
        let table = try #require(bodyLines(box))
        #expect(table == ["| a | b |", "|---|---|", "| 1 | 2 |"])
        let rows = blocks.filter { $0.tag == "tr" }.compactMap(bodyLines)
        #expect(rows == [["| a | b |"], ["| 1 | 2 |"]])
    }

    @Test("a callout keeps its lines")
    func callout() throws {
        let block = try first(stampedBlocks(), tag: "div", class: "callout")
        let lines = try #require(bodyLines(block))
        #expect(lines.first == "> [!note] Heads up")
        #expect(lines.contains("> Body of the note."))
    }

    @Test("a block in a generated region maps inside it, and a target there is generated")
    func generatedRegion() throws {
        let blocks = try stampedBlocks()
        let regions = CorrectionTarget.GeneratedRegions(Self.fileText)
        let region = try #require(regions.regions.first)
        let lists = blocks.filter { $0.tag == "ul" }
        let generated = try #require(lists.last)
        guard case .body(let lines) = map.location(ofRendered: generated.lines) else {
            Issue.record("the generated list maps to the frontmatter")
            return
        }
        #expect(region.overlaps(lines))
        #expect(Self.fileLines[lines.first - 1] == "- [[pseudorandom-function]]")

        let page = WikiPage(path: "Reductions/x.md", text: Self.fileText)
        let selection = ReaderSelection(
            renderedLines: generated.lines, text: "pseudorandom-function", heading: nil,
            path: page.path, revision: "abc")
        let target = CorrectionTarget.make(
            page: page, fileText: Self.fileText, renderedMarkdown: Self.renderedMarkdown,
            baseCommit: "abc", selection: selection, readingHeading: nil)
        #expect(target.region == .generated)
    }

    @Test("an unclosed $$ at the end of a page renders, and runs to the end")
    func unclosedDisplayMath() throws {
        let script = try MarkdownScript.load()
        let html = try script.render("Text.\n\n$$")
        #expect(html.contains("math-display"))
        let open = StampedBlock.all(in: try script.render("$$\nx\ny"))
        #expect(open.map(\.lines) == [0..<3], "one block, its last line not parsed again")
    }
}
