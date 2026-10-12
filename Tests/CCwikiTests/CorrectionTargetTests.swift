import Foundation
import Testing
@testable import CCwiki

/// The page, section, lines and passage a correction starts from
/// (plans/corrections.md §3.5), built from the file and the markdown the
/// reader showed, and what blocks each route (§7.1, §8).
struct CorrectionTargetTests {

    static let path = "Primitives/pseudorandom-function.md"

    /// A page with frontmatter (lines 1–5), a paragraph and a display block
    /// (lines 12–15) and a generated region (lines 18–22).
    static let fileText = #"""
        ---
        type: primitive
        status: draft
        title: Pseudorandom function
        ---
        # Pseudorandom function

        A PRF is a keyed function.

        ## Security

        For every efficient $\calA$,
        $$
        \Adv^{\mathrm{prf}}_{F,\calA}(\secpar) \le \negl
        $$

        Last paragraph.
        <!-- BEGIN GENERATED participates-in checksum=865206d47c53 -->
        ## Participates in

        - [[pseudorandom-generator]]
        <!-- END GENERATED participates-in -->
        """#

    static var page: WikiPage { WikiPage(path: path, text: fileText) }
    static var rendered: String { page.body }

    static let security = CorrectionTarget.Section(id: "security", title: "Security", level: 2)
    static let reading = CorrectionTarget.Section(
        id: "pseudorandom-function", title: "Pseudorandom function", level: 1)

    /// A selection of rendered lines `[start, end)`; a pointer without text.
    private static func selection(
        _ lines: Range<Int>, text: String? = "the passage",
        heading: CorrectionTarget.Section? = CorrectionTargetTests.security, revision: String? = "ab81f02"
    ) -> ReaderSelection {
        ReaderSelection(renderedLines: lines, text: text, heading: heading, path: path, revision: revision)
    }

    private static func make(
        _ selection: ReaderSelection?, fileText: String = CorrectionTargetTests.fileText,
        rendered: String = CorrectionTargetTests.rendered,
        reading: CorrectionTarget.Section? = CorrectionTargetTests.reading
    ) -> CorrectionTarget {
        CorrectionTarget.make(
            page: WikiPage(path: path, text: fileText), fileText: fileText, renderedMarkdown: rendered,
            baseCommit: selection?.revision ?? "head", selection: selection, readingHeading: reading)
    }

    // MARK: Lines and excerpts

    @Test("the excerpt is the file's lines, verbatim")
    func excerpt() {
        // Rendered line 2 is the body's "A PRF is a keyed function.", file line 8.
        let target = Self.make(Self.selection(2..<3))
        #expect(target.lines == LineRange(first: 8, last: 8))
        #expect(target.excerpt == "A PRF is a keyed function.")
        #expect(target.region == .body)
        #expect(target.repositoryPath == "content/" + Self.path)
        #expect(target.summary == "Line 8, in “Security”")
    }

    @Test("a display block's excerpt ends with its closing $$")
    func displayBlock() throws {
        // The paragraph and the block, rendered lines 6 to 9: the block is
        // 7 to 9, its closing `$$` included.
        let target = Self.make(Self.selection(6..<10))
        #expect(target.lines == LineRange(first: 12, last: 15))
        let excerpt = try #require(target.excerpt)
        #expect(excerpt.hasPrefix(#"For every efficient $\calA$,"#))
        #expect(excerpt.hasSuffix("\n$$"))
        #expect(target.summary == "Lines 12–15, in “Security”")
    }

    // MARK: Sections

    @Test("the section comes from the selection's heading")
    func sectionFromSelection() {
        let target = Self.make(Self.selection(2..<3))
        #expect(target.section == Self.security)
    }

    @Test("a pointer is the whole page, in the pointer's section")
    func pointer() {
        let target = Self.make(Self.selection(2..<3, text: nil))
        #expect(target.lines == nil)
        #expect(target.quote == nil)
        #expect(target.excerpt == nil)
        #expect(target.section == Self.security)
        #expect(target.summary == "The whole page")
    }

    @Test("the editor opens at a passage, or at the block a pointer named")
    func editorLines() {
        let pointer = Self.selection(2..<3, text: nil)
        #expect(CorrectionTarget.editorLines(
            fileText: Self.fileText, renderedMarkdown: Self.rendered, selection: pointer)
            == LineRange(first: 8, last: 8))
        let passage = Self.selection(6..<10)
        #expect(CorrectionTarget.editorLines(
            fileText: Self.fileText, renderedMarkdown: Self.rendered, selection: passage)
            == Self.make(passage).lines)
        #expect(CorrectionTarget.editorLines(
            fileText: Self.fileText, renderedMarkdown: Self.rendered, selection: nil) == nil)
    }

    @Test("without a selection or a pointer, the heading the reader is on")
    func readingHeading() {
        let target = Self.make(nil)
        #expect(target.section == Self.reading)
        #expect(target.lines == nil)
        #expect(target.baseCommit == "head")
    }

    // MARK: Quotes

    @Test("the quote is trimmed and capped at 2,000 characters")
    func quoteLimit() throws {
        let long = String(repeating: "abcdefghij", count: 300)
        let target = Self.make(Self.selection(2..<3, text: "  \n" + long + "\n"))
        let quote = try #require(target.quote)
        #expect(quote.count == CorrectionTarget.quoteLimit)
        #expect(quote.hasPrefix("abcdefghij"))
    }

    // MARK: Regions

    @Test("a passage in a generated region is generated")
    func generated() {
        // "- [[pseudorandom-generator]]" is file line 21, rendered line 15.
        let target = Self.make(Self.selection(15..<16))
        #expect(target.lines == LineRange(first: 21, last: 21))
        #expect(target.region == .generated)
        #expect(GeneratedRegions(Self.fileText).regions == [LineRange(first: 18, last: 22)])
    }

    @Test("the relation-meta line is the frontmatter")
    func relationMeta() {
        let meta = "Reduction · from [[one-way-function]] <!-- relation-meta -->"
        let spliced = RelationMeta.insertUnderH1(meta, into: Self.page.body)
        let lines = SourceLineMap.lines(of: Substring(spliced))
        let index = lines.firstIndex { $0 == meta } ?? -1
        let target = Self.make(Self.selection(index..<(index + 1)), rendered: spliced)
        #expect(target.region == .frontmatter)
        #expect(target.lines == LineRange(first: 2, last: 4))
        #expect(target.excerpt == "type: primitive\nstatus: draft\ntitle: Pseudorandom function")
    }

    // MARK: Revisions

    @Test("a selection made at an older revision is built at that revision")
    func olderRevision() {
        // HEAD has gained two lines above the paragraph since the tab
        // rendered the old commit, and a sync left the tab alone.
        let old = Self.fileText
        let head = old.replacingOccurrences(
            of: "# Pseudorandom function\n", with: "# Pseudorandom function\n\nA new first paragraph.\n")
        #expect(SourceLineMap.lines(of: Substring(head))[9] == "A PRF is a keyed function.")

        // The selection, its revision, the old file and the old render.
        let selection = Self.selection(2..<3, revision: "old1234")
        let target = Self.make(selection, fileText: old, rendered: WikiPage(path: Self.path, text: old).body)
        #expect(target.baseCommit == "old1234")
        #expect(target.lines == LineRange(first: 8, last: 8))
        #expect(target.excerpt == "A PRF is a keyed function.")
    }

    @Test("a snapshot whose marker moved since the render falls back to the whole page")
    func movedSnapshot() {
        #expect(!CorrectionTarget.diskShows(revision: "old1234", current: "new5678"))
        #expect(CorrectionTarget.diskShows(revision: "same", current: "same"))
        #expect(CorrectionTarget.diskShows(revision: nil, current: "anything"))

        let selection = Self.selection(2..<3, revision: "old1234")
        let target = CorrectionTarget.fallback(
            page: Self.page, head: "new5678", selection: selection, readingHeading: Self.reading)
        #expect(target.baseCommit == "new5678")
        #expect(target.lines == nil)
        #expect(target.quote == nil)
        #expect(target.section == Self.security, "the section is carried over, the lines are not")
    }

    // MARK: Blockers

    private func blockers(
        _ route: CorrectionRoute, region: CorrectionTarget.Region = .body,
        git: Bool = true, claude: Bool = true, gh: Bool = true,
        store: AppPaths.WikiStore = .git
    ) -> [String] {
        CorrectionBlockers.list(
            route: route, region: region, gitPresent: git, claudePresent: claude, ghPresent: gh,
            store: store)
    }

    @Test("nothing blocks a route with the tools and a clone")
    func clear() {
        for route in CorrectionRoute.allCases {
            #expect(blockers(route).isEmpty, "\(route)")
        }
    }

    @Test("Describe gives the reason for both generated regions; the others do not")
    func describeGenerated() {
        for region in [CorrectionTarget.Region.generated, .frontmatter] {
            #expect(blockers(.describe, region: region) == [CorrectionBlockers.generated])
            #expect(blockers(.edit, region: region).isEmpty)
            #expect(blockers(.issue, region: region).isEmpty)
        }
    }

    @Test("a snapshot blocks editing and describing with the Sync message, and not an issue")
    func snapshot() {
        #expect(blockers(.edit, store: .snapshot) == [CorrectionBlockers.snapshot])
        #expect(blockers(.describe, store: .snapshot) == [CorrectionBlockers.snapshot])
        #expect(blockers(.issue, store: .snapshot).isEmpty)
        #expect(CorrectionBlockers.snapshot.contains("Sync (⌘R)"))
    }

    @Test("each route lists only the tools it needs, and nothing about GitHub")
    func tools() {
        #expect(blockers(.edit, git: false, claude: false, gh: false) == [CorrectionBlockers.gitMissing])
        #expect(blockers(.describe, git: false, claude: false, gh: false)
            == [CorrectionBlockers.gitMissing, CorrectionBlockers.claudeMissing])
        #expect(blockers(.issue, git: false, claude: false, gh: false) == [CorrectionBlockers.ghMissing])

        let every = CorrectionRoute.allCases.flatMap { route in
            blockers(route, region: .generated, git: false, claude: false, gh: false, store: .snapshot)
        }
        for blocker in every {
            for word in ["GitHub", "signed", "sign in", "push", "offline", "Offline"] {
                #expect(!blocker.contains(word), "\(blocker)")
            }
        }
    }
}
