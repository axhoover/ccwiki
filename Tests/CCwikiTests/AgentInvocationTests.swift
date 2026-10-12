import Foundation
import Testing
@testable import CCwiki

/// How CCwiki starts an agent, and the seal around it
/// (plans/corrections.md §5.1, §5.4, §12.1).
struct AgentInvocationTests {

    static let scratch = URL(fileURLWithPath:
        "/Users/someone/Library/Caches/CCwiki/scratch/20261012-101500-000-correction-prf")
    static let worktree = URL(fileURLWithPath:
        "/Users/someone/Library/Caches/CCwiki/worktrees/20261012-101500-000-correction-prf")

    /// An environment with every credential an agent must not inherit.
    static let base: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
        "HOME": "/Users/someone",
        "GH_TOKEN": "ghp_0123456789abcdef0123456789abcdef0123",
        "GITHUB_TOKEN": "ghs_token",
        "GH_ENTERPRISE_TOKEN": "enterprise",
        "GITHUB_ENTERPRISE_TOKEN": "enterprise",
        "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.abc/Listeners",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    /// The argument after `flag`.
    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// A comma-separated list flag's entries. None of them contains a comma.
    static func list(_ flag: String, in arguments: [String]) -> [String] {
        value(of: flag, in: arguments)?.components(separatedBy: ",") ?? []
    }

    static func correction(model: String = "sonnet") -> AgentInvocation {
        AgentInvocation.correction(
            prompt: "Correct the page.", model: model, maxTurns: "20",
            base: base, scratch: scratch)
    }

    // MARK: Arguments

    @Test("a correction: the chosen model, its turns, the file tools, and no Bash or web")
    func correctionArguments() {
        let arguments = Self.correction().arguments
        #expect(Array(arguments.prefix(2)) == ["-p", "Correct the page."],
                "the prompt comes first, before any list flag could swallow it")
        #expect(Self.value(of: "--model", in: arguments) == "sonnet")
        #expect(Self.value(of: "--max-turns", in: arguments) == "20")
        #expect(Self.value(of: "--output-format", in: arguments) == "stream-json")
        #expect(arguments.contains("--verbose"))
        #expect(Self.value(of: "--permission-mode", in: arguments) == "acceptEdits")

        let allowed = Self.list("--allowedTools", in: arguments)
        #expect(Set(allowed) == ["Read", "Edit", "Write", "Glob", "Grep"])
        let bash = allowed.filter { $0 == "Bash" || $0.hasPrefix("Bash(") }
        #expect(bash.isEmpty, "a correction has no Bash entry at all")
        #expect(!allowed.contains("WebFetch") && !allowed.contains("WebSearch"))
        #expect(!arguments.contains("bypassPermissions"))
    }

    @Test("the CLI's default model passes no --model")
    func defaultModel() {
        let arguments = Self.correction(model: "").arguments
        #expect(!arguments.contains("--model"))
        let ingestion = AgentInvocation.ingestion(
            prompt: "Ingest.", maxTurns: "200", base: Self.base, scratch: Self.scratch)
        #expect(!ingestion.arguments.contains("--model"), "ingestion keeps the CLI's default")
        #expect(Self.value(of: "--max-turns", in: ingestion.arguments) == "200")
    }

    @Test("both deny pushing, committing, remotes, git config and gh")
    func deniedTools() {
        let ingestion = AgentInvocation.ingestion(
            prompt: "Ingest.", maxTurns: "200", base: Self.base, scratch: Self.scratch)
        for invocation in [Self.correction(), ingestion] {
            let denied = Self.list("--disallowedTools", in: invocation.arguments)
            for rule in ["Bash(git push:*)", "Bash(git commit:*)", "Bash(git remote:*)",
                         "Bash(git config:*)", "Bash(gh:*)"] {
                #expect(denied.contains(rule), "\(rule) is not denied")
            }
        }
    }

    @Test("an ingestion: no gh, and every git entry is one that only reads")
    func ingestionTools() {
        let ingestion = AgentInvocation.ingestion(
            prompt: "Ingest.", maxTurns: "200", base: Self.base, scratch: Self.scratch)
        let allowed = Self.list("--allowedTools", in: ingestion.arguments)
        #expect(allowed == AgentInvocation.ingestionTools)
        let gh = allowed.filter { $0.hasPrefix("Bash(gh") }
        #expect(gh.isEmpty, "gh reaches GitHub")
        #expect(!allowed.contains("Bash(git:*)"), "no unscoped git")

        let readOnly: Set = [
            "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
            "Bash(git ls-files:*)", "Bash(git grep:*)", "Bash(git rev-parse:*)",
            "Bash(git submodule update:*)",
        ]
        let git = allowed.filter { $0.hasPrefix("Bash(git") }
        #expect(!git.isEmpty)
        for entry in git {
            #expect(readOnly.contains(entry), "\(entry) is not one of §5.1's read-only subcommands")
        }
        // It still fetches the paper and runs the local lint.
        for tool in ["WebFetch", "WebSearch", "Bash(node:*)", "Bash(npm:*)", "Bash(npx:*)"] {
            #expect(allowed.contains(tool), "missing \(tool)")
        }
    }

    // MARK: The environment

    @Test("the sealed environment: no credentials, an empty gh config, and pushes blocked")
    func sealedEnvironment() {
        for environment in [Self.correction().environment,
                            AgentInvocation.sealed(Self.base, scratch: Self.scratch)] {
            let ghConfig = environment["GH_CONFIG_DIR"] ?? ""
            #expect(ghConfig == Self.scratch.appending(path: "gh").path(percentEncoded: false))
            #expect(ghConfig.hasPrefix(Self.scratch.path(percentEncoded: false) + "/"))
            #expect(!ghConfig.hasPrefix(Self.worktree.path(percentEncoded: false)),
                    "nothing gh writes can be staged")

            for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK"] {
                #expect(environment[name] == nil, "\(name) is still set")
            }

            #expect(environment["GIT_CONFIG_COUNT"] == "3")
            #expect(environment["GIT_CONFIG_KEY_0"] == "remote.origin.pushurl")
            #expect(environment["GIT_CONFIG_VALUE_0"] == "ccwiki-review-first://blocked")
            #expect(environment["GIT_CONFIG_KEY_1"] == "credential.helper")
            #expect(environment["GIT_CONFIG_VALUE_1"] == "")
            #expect(environment["GIT_CONFIG_KEY_2"] == "credential.https://github.com.helper")
            #expect(environment["GIT_CONFIG_VALUE_2"] == "")

            for program in ["GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS"] {
                #expect(environment[program] == "/usr/bin/false", "\(program) is not sealed")
            }
            #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
            // Everything else is the caller's.
            #expect(environment["PATH"] == Self.base["PATH"])
            #expect(environment["HOME"] == "/Users/someone")
        }
    }

    @Test("the seal comes after git settings the environment already carries")
    func sealAppends() {
        var base = Self.base
        base["GIT_CONFIG_COUNT"] = "1"
        base["GIT_CONFIG_KEY_0"] = "core.quotePath"
        base["GIT_CONFIG_VALUE_0"] = "false"
        let sealed = AgentInvocation.sealed(base, scratch: Self.scratch)
        #expect(sealed["GIT_CONFIG_COUNT"] == "4")
        #expect(sealed["GIT_CONFIG_KEY_0"] == "core.quotePath")
        #expect(sealed["GIT_CONFIG_KEY_1"] == "remote.origin.pushurl")
        #expect(sealed["GIT_CONFIG_KEY_3"] == "credential.https://github.com.helper")
    }

    @Test("with the seal, a plain git push to origin fails; without it, the same push works")
    func sealBlocksAPush() async throws {
        guard let repository = await FixtureRepository.make() else { return }
        defer { repository.delete() }
        let origin = repository.root.deletingLastPathComponent()
            .appending(path: repository.root.lastPathComponent + "-origin.git")
        defer { try? FileManager.default.removeItem(at: origin) }

        let git = repository.git
        let environment = FixtureRepository.environment()
        let bare = await Subprocess.run(
            executable: git,
            arguments: ["init", "-q", "--bare", "-b", "main", origin.path(percentEncoded: false)],
            environment: environment)
        try #require(bare.succeeded, "git init --bare: \(bare.output)")
        try repository.write("content/page.md", "# Page\n")
        #expect(await repository.commit("init", date: 1_780_000_000) != nil)
        #expect(await repository.run(["remote", "add", "origin", origin.path(percentEncoded: false)])
            .succeeded)

        let sealed = AgentInvocation.sealed(environment, scratch: Self.scratch)
        let push = ["-C", repository.root.path(percentEncoded: false),
                    "push", "origin", "HEAD:refs/heads/agent"]
        let blocked = await Subprocess.run(executable: git, arguments: push, environment: sealed)
        #expect(!blocked.succeeded, "the sealed push went through: \(blocked.output)")

        let unsealed = await Subprocess.run(executable: git, arguments: push, environment: environment)
        #expect(unsealed.succeeded, "CCwiki's own push failed: \(unsealed.output)")
    }
}

/// The tripwire's pure half: what moved, what was opened, and what the
/// notice says (plans/corrections.md §5.5).
struct TripwireTests {

    static let started = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")!

    static func url(_ number: Int) -> URL {
        URL(string: "https://github.com/axhoover/cryptology.city/pull/\(number)")!
    }

    @Test("a new or moved branch counts, unless it is another job's; a deleted one does not")
    func movedBranches() {
        let before = ["main": "a1", "fix/old": "b1", "gone": "c1", "ingest/other": "d1"]
        let after = ["main": "a1", "fix/old": "b2", "fix/new": "e1", "ingest/other": "d2"]
        #expect(Tripwire.movedBranches(before: before, after: after, ignoring: ["ingest/other"])
            == ["fix/new", "fix/old"])
        #expect(Tripwire.movedBranches(before: before, after: before, ignoring: []).isEmpty)
    }

    @Test("only pull requests created since the job started count, newest first")
    func pullRequestListing() {
        let listing = """
            2026-10-12T09:59:30Z fix/prf https://github.com/axhoover/cryptology.city/pull/52
            2026-10-12T10:20:00Z paper-submission/AB12-x https://github.com/axhoover/cryptology.city/pull/53
            2026-09-20T09:00:00Z fix/old https://github.com/axhoover/cryptology.city/pull/36
            garbage line
            """
        let since = Self.started.addingTimeInterval(-60)
        let found = Tripwire.pullRequests(createdAfter: since, in: listing)
        #expect(found.map(\.url) == [Self.url(53), Self.url(52)])
        #expect(found.map(\.head) == ["paper-submission/AB12-x", "fix/prf"])
        #expect(Tripwire.pullRequests(createdAfter: since, in: "").isEmpty)
    }

    @Test("the job's own pull request makes it opened, and says the agent bypassed review")
    func ownPullRequest() {
        let own = OpenedPullRequest(url: Self.url(52), head: "fix/prf", createdAt: Self.started)
        let other = OpenedPullRequest(
            url: Self.url(53), head: "paper-submission/AB12-x",
            createdAt: Self.started.addingTimeInterval(60))
        let finding = Tripwire.finding(
            jobBranch: "fix/prf", moved: ["fix/prf"], opened: [other, own])
        #expect(finding.pullRequest == Self.url(52))
        #expect(finding.notice?.tone == .warning)
        #expect(finding.notice?.text == "The agent opened this pull request itself, bypassing review.")
    }

    @Test("someone else's pull request is named as one CCwiki did not open")
    func otherPullRequest() {
        let other = OpenedPullRequest(
            url: Self.url(53), head: "paper-submission/AB12-x", createdAt: Self.started)
        let finding = Tripwire.finding(
            jobBranch: "ingest/eprint-2025-375", moved: ["paper-submission/AB12-x"], opened: [other])
        #expect(finding.pullRequest == Self.url(53))
        #expect(finding.notice?.text == "A pull request was opened while the agent ran, and CCwiki "
            + "did not open it. paper-submission/AB12-x was pushed to GitHub while the agent ran, "
            + "and CCwiki did not push it.")
    }

    @Test("a push without a pull request leaves the job for review, with a notice")
    func pushes() {
        let own = Tripwire.finding(jobBranch: "fix/prf", moved: ["fix/prf"], opened: [])
        #expect(own.pullRequest == nil)
        #expect(own.notice?.text == "The agent pushed fix/prf itself, bypassing review.")

        let others = Tripwire.finding(jobBranch: "fix/prf", moved: ["a", "b", "c"], opened: [])
        #expect(others.notice?.text
            == "a, b and c were pushed to GitHub while the agent ran, and CCwiki did not push them.")

        let quiet = Tripwire.finding(jobBranch: "fix/prf", moved: [], opened: [])
        #expect(quiet.pullRequest == nil && quiet.notice == nil)
    }

    @Test("other jobs' branches come from their records, never this job's")
    func otherJobBranches() throws {
        let logs = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-tripwire-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logs) }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let target = CorrectionTarget(
            pagePath: "Primitives/pseudorandom-function.md", pageTitle: "Pseudorandom function",
            baseCommit: "865206d47c53", section: nil, lines: nil, region: .body,
            quote: nil, excerpt: nil)
        for (id, branch) in [("this", "fix/prf"), ("other", "fix/prf-2")] {
            let record = JobRecord(
                id: id, kind: .edit(target), branch: branch, state: .awaitingReview,
                createdAt: Self.started, startedAt: nil, finishedAt: nil, baseCommit: nil,
                pullRequest: nil, pushingCommit: nil, pushedCommit: nil, notice: nil)
            try JSONEncoder().encode(record).write(to: logs.appending(path: "\(id).json"))
        }
        try Data("not a record".utf8).write(to: logs.appending(path: "broken.json"))

        #expect(Tripwire.otherJobBranches(logs: logs, excluding: "this") == ["fix/prf-2"])
    }
}
