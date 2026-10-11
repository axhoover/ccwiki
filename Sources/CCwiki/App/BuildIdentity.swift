import Foundation

/// Which CCwiki this is: the release, or a build from source.
///
/// Every build from source is **CCwiki Dev**. `build.sh` stamps its identity
/// from `CHANNEL`, never from the version string, because a `make` at an
/// exact tag carries a bare `X.Y.Z` and would otherwise look exactly like
/// the release (see `scripts/stamp-info-plist.sh` and
/// plans/update-integrity.md §2.1):
///
/// ```
///                 release                 dev
/// bundle id       com.axhoover.ccwiki     com.axhoover.ccwiki.dev
/// name            CCwiki                  CCwiki Dev
/// URL scheme      ccwiki://               ccwiki-dev://
/// data folders    CCwiki                  CCwiki-Dev
/// updates         checks and installs     never
/// ```
///
/// The bundle id alone keeps the two apart in UserDefaults, saved state,
/// WebKit's data and LaunchServices. The data folders are the app's own
/// business: `AppPaths.standard()` asks `dataFolderName(for:)`.
enum BuildIdentity {

    enum Channel: Equatable, Sendable {
        case release
        case dev
    }

    static let releaseBundleIdentifier = "com.axhoover.ccwiki"
    static let devBundleIdentifier = "com.axhoover.ccwiki.dev"
    static let releaseURLScheme = "ccwiki"
    static let devURLScheme = "ccwiki-dev"

    /// `.release` only for exactly `releaseBundleIdentifier`. Anything else is
    /// `.dev`, including no identifier at all: `swift run` and the test runner
    /// have no bundle of ours around them, and must never act as the release.
    static func channel(forBundleIdentifier identifier: String?) -> Channel {
        identifier == releaseBundleIdentifier ? .release : .dev
    }

    /// The channel of the running bundle.
    static var current: Channel {
        channel(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Only the release looks for updates or replaces itself.
    static var isRelease: Bool { current == .release }

    /// The folder name under Application Support and under Caches. No space
    /// in the dev one: ingestion worktrees live in Caches, and the tooling run
    /// there fails on `%20` (see `AppPaths.worktrees`).
    static func dataFolderName(for channel: Channel) -> String {
        switch channel {
        case .release: "CCwiki"
        case .dev: "CCwiki-Dev"
        }
    }

    /// The scheme this build answers to from outside, as Info.plist declares
    /// it. The reader's own pages are served on `CCwikiURL.scheme` whatever
    /// the channel; only links from other apps differ.
    static func externalURLScheme(for channel: Channel) -> String {
        switch channel {
        case .release: releaseURLScheme
        case .dev: devURLScheme
        }
    }
}
