import Foundation

/// Where pull requests and issues go (plans/corrections.md §10).
///
/// CCwiki Dev targets the same repository as the release, and says so at
/// every step. `CCWIKI_TARGET_REPO=owner/name` points a Dev build at a fork;
/// the release ignores it, so a stray environment cannot redirect it.
struct PublishTarget: Sendable, Equatable {
    /// "axhoover/cryptology.city".
    let repository: String
    /// "origin" for the clone's own remote, else
    /// "https://github.com/<repository>.git".
    let pushURL: String
    let isDevBuild: Bool
    /// `CCWIKI_TARGET_REPO` took effect.
    let isOverridden: Bool

    /// The variable a Dev build reads.
    static let environmentKey = "CCWIKI_TARGET_REPO"

    /// The wiki, unless a Dev build is pointed at another repository by a
    /// valid `owner/name`. An invalid value is ignored here; `AppModel`
    /// warns about it in the status bar. A value naming the wiki itself
    /// changes nothing, and pushes to the clone's own remote.
    static func resolve(channel: BuildIdentity.Channel, environment: [String: String]) -> PublishTarget {
        let isDevBuild = channel == .dev
        let wiki = PublishTarget(
            repository: AppPaths.repositorySlug, pushURL: "origin",
            isDevBuild: isDevBuild, isOverridden: false)
        guard isDevBuild, let requested = environment[environmentKey],
              isRepositorySlug(requested),
              requested.lowercased() != AppPaths.repositorySlug.lowercased()
        else { return wiki }
        return PublishTarget(
            repository: requested, pushURL: "https://github.com/\(requested).git",
            isDevBuild: true, isOverridden: true)
    }

    /// `owner/name`: two parts, neither empty, and no whitespace. The same
    /// test `AppModel` makes before it warns, so a value is either honoured
    /// or reported, never neither.
    static func isRepositorySlug(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts.contains(where: \.isEmpty)
            && !value.contains(where: \.isWhitespace)
    }
}
