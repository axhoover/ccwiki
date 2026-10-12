import Foundation

// The app-wide half of correcting a page (plans/corrections.md §8, §11.6):
// what blocks a route, and opening an issue. What is about the page being
// read — whether it can be corrected, and starting a route — is the
// window's own, in `ReaderSession+Corrections.swift` (§17).
//
// Phase 0 declares these; Track C fills them (§11.4).
extension AppModel {

    /// Why `route` cannot start here, from local conditions only: the tools
    /// and the kind of wiki copy. GitHub is `jobCenter.gitHubAccess`'s.
    func correctionBlockers(_ route: CorrectionRoute, target: CorrectionTarget) -> [String] {
        CorrectionBlockers.list(
            route: route, region: target.region,
            gitPresent: tools.path(for: .git) != nil,
            claudePresent: tools.path(for: .claude) != nil,
            ghPresent: tools.path(for: .gh) != nil,
            store: paths.wikiStore)
    }

    /// The signed-in account's login, for the issue sheet's footer, cached
    /// for the session. Phase 0: nil.
    func githubLogin() async -> String? {
        nil
    }

    /// `gh issue create` with the sheet's text and CCwiki's footer
    /// (§8.2). Phase 0: refused.
    func openIssue(_ draft: IssueDraft) async -> Result<URL, JobError> {
        .failure(JobError("Not built yet."))
    }
}
