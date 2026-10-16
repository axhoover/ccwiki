import Foundation
import Testing
@testable import CCwiki

/// Whether a change can become a pull request now, and the banner that says
/// why not (plans/corrections.md §7.1, §12.1).
struct GitHubAccessTests {

    static let repository = "axhoover/cryptology.city"

    static func classify(ghPresent: Bool = true, signedIn: Bool?, canPush: Bool?) -> GitHubAccess {
        GitHubAccess.classify(
            ghPresent: ghPresent, signedIn: signedIn, canPush: canPush, repository: repository)
    }

    @Test("each case, from what gh said")
    func classification() {
        #expect(Self.classify(signedIn: true, canPush: true) == .ready)
        #expect(Self.classify(signedIn: true, canPush: false) == .cannotPush(repository: Self.repository))
        #expect(Self.classify(signedIn: false, canPush: nil) == .notSignedIn)
        #expect(Self.classify(ghPresent: false, signedIn: nil, canPush: nil) == .ghMissing)
        #expect(Self.classify(ghPresent: false, signedIn: true, canPush: true) == .ghMissing,
                "without gh there is nothing to open a pull request with")
    }

    @Test("a question gh could not answer is offline, never signed out")
    func unansweredIsOffline() {
        #expect(Self.classify(signedIn: nil, canPush: nil) == .offline)
        #expect(Self.classify(signedIn: nil, canPush: true) == .offline)
        #expect(Self.classify(signedIn: nil, canPush: false) == .offline)
        #expect(Self.classify(signedIn: true, canPush: nil) == .offline)
        for canPush in [true, false, nil] as [Bool?] {
            #expect(Self.classify(signedIn: nil, canPush: canPush) != .notSignedIn)
        }
    }

    @Test("every case but ready has a banner, and the push banner names the repository")
    func banners() {
        #expect(GitHubAccess.ready.banner == nil)
        for access in [GitHubAccess.offline, .ghMissing, .notSignedIn,
                       .cannotPush(repository: "owner/fork")] {
            #expect(!(access.banner ?? "").isEmpty, "\(access) has no banner")
        }
        #expect(GitHubAccess.cannotPush(repository: "owner/fork").banner?.contains("owner/fork") == true)
        #expect(GitHubAccess.offline.banner?.hasPrefix("Offline.") == true)
        #expect(GitHubAccess.notSignedIn.banner?.contains("gh auth login") == true)
        // Each sits beside Check Again. An issue needs gh too, so the banner
        // for a missing gh does not offer one.
        #expect(GitHubAccess.notSignedIn.banner?.hasSuffix("then check again.") == true)
        #expect(GitHubAccess.ghMissing.banner?.contains("brew install gh") == true)
        #expect(GitHubAccess.ghMissing.banner?.contains("issue") == false)
    }

    @Test("gh's and git's words for an unreachable GitHub read as a network failure")
    func networkFailures() {
        for output in [
            "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com",
            "X Timeout trying to log in to github.com account someone (keyring)",
            "Get \"https://api.github.com/\": dial tcp: lookup api.github.com: no such host",
            "fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com",
            "net/http: TLS handshake timeout",
        ] {
            #expect(GitHubAuth.isNetworkFailure(output), "\(output)")
        }
        for output in [
            "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            "X Failed to log in to github.com account someone (keyring)\n"
                + "- The token in keyring is invalid.",
            "HTTP 401: Bad credentials (https://api.github.com/rate_limit)",
        ] {
            #expect(!GitHubAuth.isNetworkFailure(output), "\(output)")
        }
    }
}
