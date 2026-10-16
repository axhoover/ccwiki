import Foundation
import Testing
@testable import CCwiki

/// GitHub sign-in and push credentials, from the second audit round: a
/// bare `gh auth status` that failed for another host, a GitHub outage
/// read as signed out, and the clone's credential helper left naming a gh
/// that had moved.
@Suite("Fixes: auth")
struct FixesAuthTests {

    static func result(_ status: Int32, _ stdout: String = "", _ stderr: String = "")
        -> Subprocess.Result {
        Subprocess.Result(status: status, stdout: stdout, stderr: stderr)
    }

    /// What `gh auth status --hostname github.com` prints for a token
    /// GitHub would not check: a refused one, and a 5xx alike.
    static let invalidToken = Self.result(
        1, "", "github.com\n  X Failed to log in to github.com account someone (keyring)\n"
            + "  - The token in keyring is invalid.")

    // MARK: Signed in, signed out, or not known

    @Test("only a refused token is signed out; a GitHub outage is not knowing")
    func verdicts() {
        let ok = Self.result(0, "5000")
        #expect(GitHubAuth.verdict(status: Self.result(0), probe: nil) == true)
        #expect(GitHubAuth.verdict(status: Self.invalidToken, probe: ok) == true,
                "another account's token, and the active one works")

        for outage in [
            Self.result(1, "{\"message\":\"Service Unavailable\"}", "gh: Service Unavailable (HTTP 503)"),
            Self.result(1, "<html>No server is currently available</html>", "gh: HTTP 502"),
            Self.result(1, "", "gh: HTTP 500"),
        ] {
            #expect(!GitHubAuth.isSignedOut(outage), "\(outage.stderr)")
            #expect(GitHubAuth.verdict(status: Self.invalidToken, probe: outage) == nil,
                    "\(outage.stderr)")
        }

        for refused in [
            Self.result(1, "{\"message\":\"Bad credentials\"}", "gh: Bad credentials (HTTP 401)"),
            Self.result(4, "", "To get started with GitHub CLI, please run:  gh auth login"),
            // `gh api user` with no github.com token: signed in elsewhere only.
            Self.result(1, "{\"message\":\"Requires authentication\"}",
                        "gh: Requires authentication (HTTP 401)"),
        ] {
            #expect(GitHubAuth.isSignedOut(refused), "\(refused.stderr)")
            #expect(GitHubAuth.verdict(status: Self.invalidToken, probe: refused) == false,
                    "\(refused.stderr)")
        }

        // No probe: it was not run (a network failure) or had no answer.
        #expect(GitHubAuth.verdict(status: Self.invalidToken, probe: nil) == nil)
        let unreachable = Self.result(1, "", "error connecting to api.github.com")
        #expect(!GitHubAuth.needsProbe(unreachable))
        #expect(GitHubAuth.needsProbe(Self.invalidToken))
        #expect(GitHubAuth.needsProbe(
            Self.result(1, "", "You are not logged into any accounts on github.com")))
        #expect(!GitHubAuth.needsProbe(Self.result(0)))
    }

    /// One test, in order, with a cache of its own: the app's is written
    /// by every test whose gh answers, all running at once.
    @Test("isAuthenticated asks github.com alone, and caches only a definite answer")
    func isAuthenticatedCaches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        /// A gh whose `auth status` for github.com and whose probe say
        /// what they are given. Asked of every host, it fails, as it does
        /// when an Enterprise host's token has expired.
        func gh(_ name: String, status: String, probe: String) throws -> ToolLocator {
            let file = directory.appending(path: name)
            let script = """
                #!/bin/sh
                case "$*" in
                  "auth status --hostname github.com") \(status) ;;
                  "api --hostname github.com user --jq .login") \(probe) ;;
                  "auth status") echo "X Failed to log in to ghe.example.com account me" >&2; exit 1 ;;
                  *) echo "unexpected: $*" >&2; exit 2 ;;
                esac

                """
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
            var tools = ToolLocator(overrides: [.gh: file.path(percentEncoded: false)])
            tools.locate([.gh])
            try #require(tools.path(for: .gh) != nil)
            return tools
        }
        let invalid = "echo '  - The token in keyring is invalid.' >&2; exit 1"

        // Signed in to github.com; another host's trouble is not ours.
        let signedIn = try gh("signed-in", status: "exit 0", probe: "exit 7")
        await GitHubAuth.$cache.withValue(GitHubAuth.Cache()) {
            #expect(await GitHubAuth.isAuthenticated(tools: signedIn) == true)
            #expect(GitHubAuth.cachedAnswer == true)
        }

        try await GitHubAuth.$cache.withValue(GitHubAuth.Cache()) {
            // A GitHub outage: not known, and asked again next time.
            let outage = try gh(
                "outage", status: invalid,
                probe: "echo 'gh: Service Unavailable (HTTP 503)' >&2; exit 1")
            #expect(await GitHubAuth.isAuthenticated(tools: outage) == nil)
            #expect(GitHubAuth.cachedAnswer == nil)
            #expect(await GitHubAuth.signedIn(tools: outage) == nil)

            // Offline: the same.
            let offline = try gh(
                "offline", status: "echo 'error connecting to api.github.com' >&2; exit 1",
                probe: "exit 7")
            #expect(await GitHubAuth.isAuthenticated(tools: offline) == nil)
            #expect(GitHubAuth.cachedAnswer == nil)

            // A refused token is an answer, and is kept.
            let refused = try gh(
                "refused", status: invalid,
                probe: "echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1")
            #expect(await GitHubAuth.isAuthenticated(tools: refused) == false)
            #expect(GitHubAuth.cachedAnswer == false)
            #expect(await GitHubAuth.isAuthenticated(tools: signedIn) == false, "from the cache")
        }

        // Signed in only to an Enterprise host: github.com asked without a
        // token is a 401, not an answer GitHub gives anyone.
        try await GitHubAuth.$cache.withValue(GitHubAuth.Cache()) {
            let elsewhere = try gh(
                "elsewhere",
                status: "echo 'You are not logged into any accounts on github.com' >&2; exit 1",
                probe: "echo 'gh: Requires authentication (HTTP 401)' >&2; exit 1")
            #expect(await GitHubAuth.isAuthenticated(tools: elsewhere) == false)
            #expect(GitHubAuth.cachedAnswer == false)
        }
    }

    @Test("an unreachable GitHub is offline in the sheet and the pre-flight, never signed out")
    func unreachableIsOffline() throws {
        func blockers(authenticated: Bool, unreachable: Bool, gh: Bool = true) -> [String] {
            AppModel.ingestionBlockers(
                store: .git, missing: [], needsDeveloperTools: false, ghPresent: gh,
                isGitHubAuthenticated: authenticated, canPushToRemote: true,
                isGitHubUnreachable: unreachable)
        }
        #expect(blockers(authenticated: false, unreachable: true)
            == [AppModel.gitHubUnreachableBlocker])
        #expect(AppModel.gitHubUnreachableBlocker.hasPrefix("Offline."), "as the editor's banner")
        let signedOut = blockers(authenticated: false, unreachable: false)
        #expect(signedOut.count == 1)
        #expect(signedOut.first?.contains("gh auth login") == true)
        #expect(blockers(authenticated: true, unreachable: false).isEmpty)
        #expect(blockers(authenticated: false, unreachable: true, gh: false).isEmpty,
                "without gh, nothing is said of GitHub")

        // The job's pre-flight says the same.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appending(path: "gh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path(percentEncoded: false))
        var located = ToolLocator(overrides: [.gh: fake.path(percentEncoded: false)])
        located.locate([.gh])
        try #require(located.path(for: .gh) != nil)
        let tools = located
        let submission = IngestSubmission(
            kind: .url, source: .eprint(year: "2025", number: "375"),
            localPDF: nil, notes: "", submittedAt: Date())
        func titles(authenticated: Bool, unreachable: Bool) -> [String] {
            let findings = Preflight.run(
                submission: submission, index: nil, paths: AppPaths(support: directory),
                tools: tools, isGitHubAuthenticated: authenticated,
                isGitHubUnreachable: unreachable)
            return findings.filter { $0.level == .blocking }.map(\.title)
        }
        let offline = titles(authenticated: false, unreachable: true)
        #expect(offline.contains("GitHub could not be reached"), "\(offline)")
        #expect(!offline.contains("GitHub CLI is not authenticated"), "\(offline)")
        let refused = titles(authenticated: false, unreachable: false)
        #expect(refused.contains("GitHub CLI is not authenticated"), "\(refused)")
        #expect(!refused.contains("GitHub could not be reached"), "\(refused)")
    }

    // MARK: The clone's credential helper

    @Test("the helper's gh path is quoted for the shell, as gh auth setup-git quotes it")
    func shellQuoting() {
        #expect(GitService.shellQuoted("/opt/homebrew/bin/gh") == "/opt/homebrew/bin/gh")
        #expect(GitService.shellQuoted("/Users/me/My Tools/gh") == "'/Users/me/My Tools/gh'")
        #expect(GitService.shellQuoted("/Users/me/it's/gh") == "'/Users/me/it'\\''s/gh'")
        #expect(GitService.shellQuoted("/Users/me/$HOME/gh") == "'/Users/me/$HOME/gh'")
        #expect(GitService.shellQuoted("") == "''")
        #expect(GitService.credentialHelper(ghPath: "/usr/local/bin/gh")
            == "!/usr/local/bin/gh auth git-credential")
    }

    @Test("every value is read: gh's helper is written again when it is stale, the user's never")
    func helperRewrites() {
        let helper = GitService.credentialHelper(ghPath: "/opt/homebrew/bin/gh")
        let stale = "!/usr/local/bin/gh auth git-credential"
        func rewrites(_ values: [String]) -> Bool {
            GitService.rewritesCredentialHelper(values, with: helper)
        }

        // No helper at all: none, or only git's empty value.
        #expect(rewrites([]))
        #expect(rewrites([""]))

        // The user's own, alone.
        #expect(!rewrites(["store"]))
        #expect(!rewrites(["osxkeychain"]))
        #expect(!rewrites(["cache --timeout=1"]))
        #expect(!rewrites(["/usr/local/share/gcm-core/git-credential-manager"]))
        #expect(!rewrites(["!/usr/local/bin/my-helper"]))
        #expect(!rewrites(["", "store"]))
        #expect(!rewrites(["store", "osxkeychain"]))

        // This gh's, once, beside the user's or not.
        #expect(!rewrites([helper]))
        #expect(!rewrites(["store", helper]))
        #expect(!rewrites([helper, "osxkeychain"]))
        #expect(!rewrites(["", helper]))

        // A gh that moved, wherever it is among the values.
        #expect(rewrites([stale]))
        #expect(rewrites(["store", stale]))
        #expect(rewrites([stale, "store"]))
        #expect(rewrites([helper, stale]))
        #expect(rewrites(["!/a/gh auth git-credential", "!/b/gh auth git-credential"]))
        #expect(rewrites(["!'/Applications/x y/gh' auth git-credential"]))
        #expect(rewrites(["store", "!'/Applications/x y/gh' auth git-credential"]))

        // This gh's twice.
        #expect(rewrites([helper, helper]))
        #expect(rewrites([helper, "store", helper]))

        // Quoted paths: written unquoted by an earlier CCwiki, and current.
        let spaced = GitService.credentialHelper(ghPath: "/Users/me/My Tools/gh")
        #expect(spaced == "!'/Users/me/My Tools/gh' auth git-credential")
        #expect(GitService.rewritesCredentialHelper(
            ["!/Users/me/My Tools/gh auth git-credential"], with: spaced),
            "written unquoted by an earlier CCwiki")
        #expect(!GitService.rewritesCredentialHelper(["store", spaced], with: spaced))
        let quote = GitService.credentialHelper(ghPath: "/Users/me/it's/gh")
        #expect(quote == "!'/Users/me/it'\\''s/gh' auth git-credential")
        #expect(!GitService.rewritesCredentialHelper([quote], with: quote))
        #expect(GitService.rewritesCredentialHelper(
            ["!/Users/me/it's/gh auth git-credential"], with: quote))
    }

    @Test("a stale gh helper is repaired in place, and the user's beside it stays, in order")
    func helperRepairedBesideTheUsers() async throws {
        guard let clone = await FixtureRepository.make() else { return }
        defer { clone.delete() }
        let key = "credential.https://github.com.helper"
        let stale = "!/nowhere/gh auth git-credential"
        // Never run: what is checked is the config git is left with. The
        // quote and the space go through git's config file and back.
        let ghPath = "/nowhere/it's here/gh"
        let helper = GitService.credentialHelper(ghPath: ghPath)

        func helpers() async -> [String] {
            let result = await clone.run(["config", "--local", "--get-all", key])
            return result.succeeded ? result.stdout.components(separatedBy: "\n") : []
        }
        func setHelpers(_ values: [String]) async throws {
            await clone.run(["config", "--local", "--unset-all", key])
            for value in values {
                try #require(await clone.run(["config", "--local", "--add", key, value]).succeeded)
            }
            try #require(await helpers() == values)
        }

        // git puts the new helper where the last stale one was.
        let cases: [(before: [String], after: [String])] = [
            ([], [helper]),
            ([""], ["", helper]),
            (["store"], ["store"]),
            (["store", stale], ["store", helper]),
            ([stale, "store"], [helper, "store"]),
            ([stale, "store", "!'/nowhere/x y/gh' auth git-credential"], ["store", helper]),
            (["osxkeychain", stale, "cache --timeout=1"],
             ["osxkeychain", helper, "cache --timeout=1"]),
        ]
        for (before, after) in cases {
            try await setHelpers(before)
            await clone.service.configureCredentialHelper(clone: clone.root, ghPath: ghPath)
            #expect(await helpers() == after, "\(before)")

            // Asked again with the same gh, nothing changes.
            await clone.service.configureCredentialHelper(clone: clone.root, ghPath: ghPath)
            #expect(await helpers() == after, "\(before)")
        }
    }

    @Test("a helper naming a gh that moved is repaired, and git can run the new one")
    func helperRepaired() async throws {
        guard let clone = await FixtureRepository.make() else { return }
        let tools = clone.root.deletingLastPathComponent()
            .appending(path: clone.root.lastPathComponent + "-My Tools")
        defer {
            clone.delete()
            try? FileManager.default.removeItem(at: tools)
        }
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let gh = tools.appending(path: "gh")
        try Data("""
            #!/bin/sh
            if [ "$1 $2 $3" = "auth git-credential get" ]; then
              echo username=x-access-token
              echo password=from-the-new-gh
            fi

            """.utf8).write(to: gh)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: gh.path(percentEncoded: false))
        let ghPath = gh.path(percentEncoded: false)
        let key = "credential.https://github.com.helper"

        func helpers() async -> [String] {
            let result = await clone.run(["config", "--local", "--get-all", key])
            return result.succeeded ? result.stdout.components(separatedBy: "\n") : []
        }

        // Written once by an older CCwiki, for a gh that is gone, and a
        // second value beside it, which a plain set would refuse.
        try #require(await clone.run(["config", "--local", key, "!/nowhere/gh auth git-credential"])
            .succeeded)
        try #require(await clone.run(["config", "--local", "--add", key,
                                      "!/nowhere/else/gh auth git-credential"]).succeeded)

        await clone.service.configureCredentialHelper(clone: clone.root, ghPath: ghPath)
        #expect(await helpers() == [GitService.credentialHelper(ghPath: ghPath)])
        #expect(await clone.service.canAuthenticatePush(clone: clone.root))

        // git runs it, through the shell, with the space in its path.
        let fill = "printf 'protocol=https\\nhost=github.com\\n\\n' | "
            + GitService.shellQuoted(clone.git) + " -C "
            + GitService.shellQuoted(clone.root.path(percentEncoded: false)) + " credential fill"
        let filled = await Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", fill],
            environment: FixtureRepository.environment())
        #expect(filled.succeeded, "\(filled.output)")
        #expect(filled.stdout.contains("password=from-the-new-gh"), "\(filled.output)")

        // Asked again with the same gh, nothing changes.
        await clone.service.configureCredentialHelper(clone: clone.root, ghPath: ghPath)
        #expect(await helpers() == [GitService.credentialHelper(ghPath: ghPath)])

        // A helper the user chose stays theirs.
        try #require(await clone.run(["config", "--local", "--replace-all", key, "store"]).succeeded)
        await clone.service.configureCredentialHelper(clone: clone.root, ghPath: ghPath)
        #expect(await helpers() == ["store"])
    }
}
