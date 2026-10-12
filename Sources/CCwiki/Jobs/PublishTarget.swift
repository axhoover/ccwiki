import Foundation

/// Where pull requests and issues go (plans/corrections.md §10).
///
/// CCwiki Dev targets the same repository as the release, and says so at
/// every step. `CCWIKI_TARGET_REPO=owner/name` points a Dev build at a fork;
/// the release ignores it.
///
/// Phase 0 declares it; Track A fills `resolve` (§11.2).
struct PublishTarget: Sendable, Equatable {
    /// "axhoover/cryptology.city".
    let repository: String
    /// "origin" for the clone's own remote, else
    /// "https://github.com/<repository>.git".
    let pushURL: String
    let isDevBuild: Bool
    /// `CCWIKI_TARGET_REPO` took effect.
    let isOverridden: Bool

    static func resolve(channel: BuildIdentity.Channel, environment: [String: String]) -> PublishTarget {
        PublishTarget(
            repository: AppPaths.repositorySlug, pushURL: "origin",
            isDevBuild: channel == .dev, isOverridden: false)
    }
}
