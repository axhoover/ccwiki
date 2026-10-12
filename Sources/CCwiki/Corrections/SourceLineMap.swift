import Foundation

/// Where a line the reader rendered lives in the file (plans/corrections.md
/// §3.4).
///
/// The rendered Markdown differs from the file in exactly two ways: the
/// frontmatter is missing at the top, and on a reduction or barrier page a
/// run of two or three lines, the relation-meta line, is added after the H1.
/// So a rendered line maps to the file by an offset, around that run.
///
/// Phase 0 declares it; Track C fills it (§11.4).
struct SourceLineMap: Sendable, Equatable {
    /// File lines before the body: the frontmatter and both of its fences.
    let bodyOffset: Int
    /// Rendered lines the renderer added (the relation-meta splice). Empty
    /// when none.
    let inserted: Range<Int>

    init(fileText: String, renderedMarkdown: String) {
        bodyOffset = 0
        inserted = 0..<0
    }

    enum Location: Sendable, Equatable {
        /// 1-based, in the file.
        case body(LineRange)
        /// The selection was the generated relation-meta line, which comes
        /// from these frontmatter lines.
        case frontmatter(LineRange)
    }

    /// A 0-based, half-open rendered range → where it lives in the file.
    func location(ofRendered range: Range<Int>) -> Location? {
        nil
    }

    /// A 1-based file line → the rendered line, for the preview to follow
    /// the cursor. Nil inside the frontmatter.
    func renderedLine(forFileLine line: Int) -> Int? {
        nil
    }
}
