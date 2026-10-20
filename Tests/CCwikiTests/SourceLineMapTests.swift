import Foundation
import Testing
@testable import CCwiki

/// A line the reader rendered, back to the line of the file it came from
/// (plans/corrections.md §3.4): past the frontmatter, and around the
/// relation-meta line the renderer splices under a reduction's H1.
struct SourceLineMapTests {

    /// A frontmatter of `count` lines, fences included.
    private static func frontmatter(lines count: Int) -> String {
        (["---"] + (1...(count - 2)).map { "key\($0): value" } + ["---"]).joined(separator: "\n") + "\n"
    }

    private static let body = """

        # Title

        First paragraph.

        Second paragraph.
        """

    @Test("a 13-line frontmatter: rendered line 0 is file line 14")
    func frontmatterOffset() {
        let file = Self.frontmatter(lines: 13) + Self.body
        let map = SourceLineMap(fileText: file, renderedMarkdown: Self.body)
        #expect(map.bodyOffset == 13)
        #expect(map.inserted.isEmpty)
        #expect(map.location(ofRendered: 0..<1) == .body(LineRange(first: 14, last: 14)))
        // "First paragraph." is body line 3, file line 17.
        #expect(map.location(ofRendered: 3..<4) == .body(LineRange(first: 17, last: 17)))
        let lines = SourceLineMap.lines(of: Substring(file))
        #expect(lines[16] == "First paragraph.")
    }

    /// A reduction page: four frontmatter lines, and the splice under its H1.
    private static let reduction = "---\ntype: reduction\nfrom: owf\n---\n" + body
    private static let meta = "Reduction · from [[owf]] <!-- relation-meta -->"
    private static var spliced: String {
        RelationMeta.insertUnderH1(meta, into: WikiPage(path: "Reductions/r.md", text: reduction).body)
    }

    @Test("after the splice, lines shift by its length; inside it is the frontmatter")
    func splice() throws {
        let map = SourceLineMap(fileText: Self.reduction, renderedMarkdown: Self.spliced)
        #expect(map.bodyOffset == 4)
        #expect(map.inserted.count == 3)
        let rendered = SourceLineMap.lines(of: Substring(Self.spliced))
        let metaLine = try #require(rendered.firstIndex { $0 == Self.meta })
        #expect(map.inserted.contains(metaLine))

        // The relation-meta line is made from the fields between the fences.
        #expect(map.location(ofRendered: metaLine..<(metaLine + 1))
            == .frontmatter(LineRange(first: 2, last: 3)))

        // "First paragraph." keeps its file line, 4 + 3 + 1.
        let first = try #require(rendered.firstIndex { $0 == "First paragraph." })
        #expect(first == 3 + 3)
        #expect(map.location(ofRendered: first..<(first + 1)) == .body(LineRange(first: 8, last: 8)))
        let file = SourceLineMap.lines(of: Substring(Self.reduction))
        #expect(file[7] == "First paragraph.")
    }

    @Test("a range that partly overlaps the splice keeps only its body part")
    func partialOverlap() throws {
        let map = SourceLineMap(fileText: Self.reduction, renderedMarkdown: Self.spliced)
        let rendered = SourceLineMap.lines(of: Substring(Self.spliced))
        let metaLine = try #require(rendered.firstIndex { $0 == Self.meta })
        let first = try #require(rendered.firstIndex { $0 == "First paragraph." })
        // From the meta line to the first paragraph: the paragraph alone.
        #expect(map.location(ofRendered: metaLine..<(first + 1)) == .body(LineRange(first: 8, last: 8)))
        // From the title through the meta line: the title and the blank
        // line under it, which the body has too.
        let title = try #require(rendered.firstIndex { $0 == "# Title" })
        #expect(map.location(ofRendered: title..<(metaLine + 1)) == .body(LineRange(first: 6, last: 7)))
        // Across it: both ends, and nothing of it.
        #expect(map.location(ofRendered: title..<(first + 1)) == .body(LineRange(first: 6, last: 8)))
    }

    @Test("a splice beside blank lines moves no line that is not blank")
    func spliceBesideBlankLines() {
        let map = SourceLineMap(fileText: Self.reduction, renderedMarkdown: Self.spliced)
        let file = SourceLineMap.lines(of: Substring(Self.reduction))
        let rendered = SourceLineMap.lines(of: Substring(Self.spliced))
        for (index, line) in rendered.enumerated() where !line.isEmpty && line != Self.meta {
            guard case .body(let lines) = map.location(ofRendered: index..<(index + 1)) else {
                Issue.record("rendered line \(index) does not map into the body")
                continue
            }
            #expect(file[lines.first - 1] == line, "rendered line \(index)")
        }
    }

    @Test("a page with no frontmatter maps line for line")
    func noFrontmatter() {
        let map = SourceLineMap(fileText: Self.body, renderedMarkdown: Self.body)
        #expect(map.bodyOffset == 0)
        #expect(map.location(ofRendered: 1..<2) == .body(LineRange(first: 2, last: 2)))
        #expect(map.renderedLine(forFileLine: 2) == 1)
    }

    @Test("a byte-order mark is part of line 1, not a line of its own")
    func byteOrderMark() {
        let file = "\u{FEFF}---\ntitle: X\n---\n# X\n\nText."
        let page = WikiPage(path: "Primitives/x.md", text: file)
        let map = SourceLineMap(fileText: file, renderedMarkdown: page.body)
        #expect(map.bodyOffset == 3)
        #expect(map.location(ofRendered: 2..<3) == .body(LineRange(first: 6, last: 6)))
    }

    @Test("Windows line endings count once")
    func crlf() {
        let lines = SourceLineMap.lines(of: "a\r\nb\rc\nd")
        #expect(lines == ["a", "b", "c", "d"])
        #expect(SourceLineMap.lines(of: "a\n") == ["a", ""])
    }

    @Test("renderedLine(forFileLine:) inverts location, and is nil in the frontmatter")
    func inverse() throws {
        let map = SourceLineMap(fileText: Self.reduction, renderedMarkdown: Self.spliced)
        let rendered = SourceLineMap.lines(of: Substring(Self.spliced))
        for index in rendered.indices where !map.inserted.contains(index) {
            guard case .body(let lines) = map.location(ofRendered: index..<(index + 1)) else {
                Issue.record("rendered line \(index) does not map into the body")
                continue
            }
            #expect(map.renderedLine(forFileLine: lines.first) == index)
        }
        for line in 1...4 {
            #expect(map.renderedLine(forFileLine: line) == nil)
        }
    }

    // MARK: From the body alone (plans/efficiency.md §3.1)

    @Test("a map made from the body alone is the file's, past the frontmatter")
    func bodyAlone() {
        let byFile = SourceLineMap(fileText: Self.reduction, renderedMarkdown: Self.spliced)
        let body = WikiPage(path: "Reductions/r.md", text: Self.reduction).body
        let byBody = SourceLineMap(body: body, renderedMarkdown: Self.spliced)
        #expect(byBody.bodyOffset == 0)
        #expect(byBody.inserted == byFile.inserted)
        for line in SourceLineMap.lines(of: Substring(body)).indices {
            #expect(byBody.renderedLine(forBodyLine: line)
                == byFile.renderedLine(forFileLine: byFile.bodyOffset + line + 1), "body line \(line)")
        }
    }

    @Test("a body line lands on itself, or past the splice; a negative one nowhere")
    func renderedBodyLine() throws {
        let body = WikiPage(path: "Reductions/r.md", text: Self.reduction).body
        let map = SourceLineMap(body: body, renderedMarkdown: Self.spliced)
        let bodyLines = SourceLineMap.lines(of: Substring(body))
        let rendered = SourceLineMap.lines(of: Substring(Self.spliced))
        for (line, text) in bodyLines.enumerated() where !text.isEmpty {
            let landing = try #require(map.renderedLine(forBodyLine: line))
            #expect(rendered[landing] == text, "body line \(line)")
        }
        let plain = SourceLineMap(body: Self.body, renderedMarkdown: Self.body)
        #expect(plain.renderedLine(forBodyLine: 3) == 3)
        #expect(plain.renderedLine(forBodyLine: -1) == nil)
    }

    @Test("an empty or negative range maps nowhere")
    func emptyRange() {
        let map = SourceLineMap(fileText: Self.reduction, renderedMarkdown: Self.spliced)
        #expect(map.location(ofRendered: 3..<3) == nil)
        #expect(map.location(ofRendered: -2..<1) == nil)
    }
}
