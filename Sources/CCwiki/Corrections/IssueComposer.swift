import Foundation

/// The issue sheet's proposed text (plans/corrections.md §8.2): the page
/// line, a permalink to the lines at the commit the reader showed, and the
/// quote in a `text` fence, then an empty paragraph where the cursor lands.
/// Pure.
///
/// Phase 0 declares it; Track C fills it (§11.4).
enum IssueComposer {

    /// "<page title>: <section title>".
    static func proposedTitle(for target: CorrectionTarget) -> String {
        target.pageTitle
    }

    static func body(for target: CorrectionTarget, siteURL: URL?, repository: String) -> String {
        ""
    }

    /// `https://github.com/<repository>/blob/<commit>/<path>?plain=1#L42-L44`,
    /// the path percent-encoded segment by segment.
    static func permalink(
        repository: String, commit: String, path: String, lines: LineRange?
    ) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/" + repository
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// A run of backticks one longer than the longest in `text`, and never
    /// shorter than three, so nothing in the quote can close the fence.
    static func fence(for text: String) -> String {
        String(repeating: "`", count: 3)
    }
}
