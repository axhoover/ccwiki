import Foundation

/// Local paths and tokens that must never reach a pull request or an issue
/// (plans/corrections.md §6.4). Pure.
///
/// Phase 0 declares it; Track A fills it (§11.2).
enum PrivateText {
    /// Each local path or token in `text`, as found. Paths: the home
    /// directory, and the worktree, library and Application Support roots.
    /// Tokens: `gh[pousr]_[A-Za-z0-9]{36,}` and `github_pat_[A-Za-z0-9_]{22,}`.
    static func findings(in text: String, privatePaths: [String]) -> [String] {
        []
    }
}
