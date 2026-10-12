import Foundation

// What a correction is about: the page, the section, the source lines and
// the passage as the reader showed it (plans/corrections.md §3.5), and the
// small types the three routes share (§11.6).
//
// Phase 0 declares these; Track C fills `make`, `ReaderSelection`'s
// decoding and `CorrectionBlockers` (§11.4).

/// Lines of a file: 1-based, inclusive.
struct LineRange: Codable, Sendable, Hashable {
    let first: Int
    let last: Int

    var count: Int { last - first + 1 }

    /// "line 42", "lines 42–44".
    var label: String {
        first == last ? "line \(first)" : "lines \(first)–\(last)"
    }

    func overlaps(_ other: LineRange) -> Bool {
        first <= other.last && other.first <= last
    }
}

/// The page and passage a correction starts from.
struct CorrectionTarget: Codable, Sendable, Hashable {

    struct Section: Codable, Sendable, Hashable {
        let id: String
        let title: String
        let level: Int
    }

    /// What the lines are: the page's own text, the relation-meta line the
    /// renderer builds from the frontmatter, or a region generated from the
    /// reduction pages (§3.5). Route b refuses the last two (§8.1).
    enum Region: String, Codable, Sendable {
        case body, frontmatter, generated
    }

    /// Relative to `content/`.
    let pagePath: String
    let pageTitle: String
    /// The commit the reader rendered: the selection's revision, else the
    /// web view's `lastRenderedRevision`. Never `origin/main` (§3.5).
    let baseCommit: String
    var section: Section?
    /// Nil: the whole page.
    var lines: LineRange?
    var region: Region
    /// As the reader showed it, formulas as `$…$`, at most `quoteLimit`.
    var quote: String?
    /// The file's `lines`, verbatim.
    var excerpt: String?

    var repositoryPath: String { "content/" + pagePath }

    /// "Lines 42–44, in “Security”", "The whole page".
    var summary: String {
        guard let lines else { return "The whole page" }
        let label = lines.label
        let range: String = label.prefix(1).uppercased() + label.dropFirst()
        guard let section else { return range }
        return "\(range), in “\(section.title)”"
    }

    static let quoteLimit = 2_000

    /// The target for what the reader showed: the selection's lines when
    /// it is a passage, the whole page otherwise. Pure. `readingHeading` is
    /// the heading at the top of the viewport, used when there is no
    /// selection and no pointer.
    ///
    /// Phase 0: always the whole page; Track C maps the selection (§3.4).
    static func make(
        page: WikiPage, fileText: String, renderedMarkdown: String,
        baseCommit: String, selection: ReaderSelection?,
        readingHeading: Section?
    ) -> CorrectionTarget {
        CorrectionTarget(
            pagePath: page.path, pageTitle: page.displayTitle, baseCommit: baseCommit,
            section: selection?.heading ?? readingHeading, lines: nil, region: .body,
            quote: nil, excerpt: nil)
    }
}

/// What `ccwiki.js` reports about the selection, or about the block under
/// the pointer at a right-click (§3.3). Decoding is pure and tested.
struct ReaderSelection: Sendable, Equatable {
    /// 0-based, half-open, in the `RenderRequest`'s markdown.
    let renderedLines: Range<Int>
    /// Nil: a right-click with nothing selected, which names a block, not a
    /// passage.
    let text: String?
    let heading: CorrectionTarget.Section?
    let path: String
    /// The `RenderRequest.revision` the selection was made on.
    let revision: String?

    var isPassage: Bool { text != nil }

    init(
        renderedLines: Range<Int>, text: String?, heading: CorrectionTarget.Section?,
        path: String, revision: String?
    ) {
        self.renderedLines = renderedLines
        self.text = text
        self.heading = heading
        self.path = path
        self.revision = revision
    }

    /// `CCwiki.selectionSource()`: nil for "null" or anything malformed.
    /// Phase 0: always nil.
    init?(json: String) {
        return nil
    }

    /// The `contextTarget` message's `selection`; `NSNull` reads as absent.
    /// Phase 0: always nil.
    init?(message: [String: Any]) {
        return nil
    }
}

/// Route b: what a reader asks the agent to correct (§4.1).
struct CorrectionRequest: Codable, Sendable, Equatable {
    let target: CorrectionTarget
    /// What the reader says is wrong.
    let description: String
    /// The `--model` alias used; "" for the claude CLI's default.
    let model: String
}

/// The three ways to correct a page (§0).
enum CorrectionRoute: String, Sendable, CaseIterable {
    /// a. Edit it yourself.
    case edit
    /// b. Describe it, and an agent edits.
    case describe
    /// c. Open an issue.
    case issue
}

/// An issue as the sheet holds it (§8.2).
struct IssueDraft: Sendable, Equatable {
    let target: CorrectionTarget
    /// A UUID, one per sheet: "ccwiki-issue: <marker>" in the body's
    /// hidden footer, which a retry searches for.
    let marker: String
    var title: String
    /// Exactly as typed; the footer is added when sending.
    var body: String
}

/// A sheet on the reader window: Describe a Correction or Open an Issue
/// (§8). `ReaderSession.correctionSheet` holds it.
struct CorrectionSheetRequest: Identifiable, Sendable {
    enum Kind: Sendable {
        case describe, issue
    }

    let id: UUID
    let kind: Kind
    let target: CorrectionTarget
}

extension CorrectionSheetRequest {
    /// A new request, with an identity of its own.
    init(_ kind: Kind, target: CorrectionTarget) {
        self.init(id: UUID(), kind: kind, target: target)
    }
}

/// An editor window's identity: one file of one job, as a document is
/// (§7.2). Its scene restores it.
struct EditorTarget: Codable, Hashable, Sendable {
    let jobID: String
    /// Repository-relative: "content/Primitives/pseudorandom-function.md".
    let path: String
}

/// Why a route cannot start here, in the order the sheet lists them.
enum CorrectionBlockers {

    /// Pure. Local conditions only; GitHub is `GitHubAccess`'s.
    /// Phase 0: nothing yet.
    static func list(
        route: CorrectionRoute, region: CorrectionTarget.Region,
        gitPresent: Bool, claudePresent: Bool, ghPresent: Bool,
        store: AppPaths.WikiStore
    ) -> [String] {
        []
    }
}
