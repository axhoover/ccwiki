import Foundation
import Testing
@testable import CCwiki

/// Opening a pull request: the arguments CCwiki gives git and gh, how a
/// refused lease is recovered, and, against real git with a bare origin for
/// GitHub, the commit and the push (plans/corrections.md §6.5, §12.1, §12.2).
/// `gh` is never run: its argument builders are what is checked.
@MainActor
struct PublisherTests {

    static let target = PublishTarget(
        repository: "axhoover/cryptology.city", pushURL: "origin",
        isDevBuild: false, isOverridden: false)

    // MARK: Arguments

    @Test("the lease is on absence before the first push, and on the last push after")
    func lease() {
        let first = Publisher.pushArguments(
            remote: "origin", branch: "x", commit: "c0ffee", expecting: nil)
        #expect(first.contains("--force-with-lease=refs/heads/x:"))
        #expect(Array(first.suffix(2)) == ["origin", "c0ffee:refs/heads/x"],
                "the commit that was checked, by name")
        let next = Publisher.pushArguments(
            remote: "origin", branch: "x", commit: "c0ffee", expecting: "abc123")
        #expect(next.contains("--force-with-lease=refs/heads/x:abc123"))
        for arguments in [first, next] {
            #expect(!arguments.contains("--force") && !arguments.contains("-f"),
                    "never a push without a lease")
            #expect(!arguments.contains { $0.contains("HEAD") }, "never HEAD, which can move")
            #expect(arguments.contains("--no-verify"))
        }
    }

    @Test("a pull request is always a draft, against the target, and never merged")
    func createArguments() {
        let arguments = Publisher.createArguments(
            target: Self.target, base: "main", branch: "fix/pseudorandom-function",
            title: "[fix] Pseudorandom function: Security", bodyFile: "/tmp/body.md")
        #expect(Array(arguments.prefix(2)) == ["pr", "create"])
        #expect(arguments.contains("--draft"))
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value("--repo") == "axhoover/cryptology.city")
        #expect(value("--head") == "fix/pseudorandom-function")
        #expect(value("--base") == "main")
        #expect(value("--title") == "[fix] Pseudorandom function: Security")
        #expect(value("--body-file") == "/tmp/body.md")
        for forbidden in ["--ready", "merge", "--auto", "--body"] {
            #expect(!arguments.contains(forbidden), "\(forbidden)")
        }

        let fork = PublishTarget(
            repository: "someone/cryptology.city",
            pushURL: "https://github.com/someone/cryptology.city.git",
            isDevBuild: true, isOverridden: true)
        let forked = Publisher.createArguments(
            target: fork, base: "main", branch: "fix/x", title: "t", bodyFile: "b")
        #expect(forked.firstIndex(of: "--repo").map { forked[$0 + 1] } == "someone/cryptology.city")

        let list = Publisher.listArguments(target: Self.target, branch: "fix/x")
        #expect(Array(list.prefix(2)) == ["pr", "list"])
        #expect(list.firstIndex(of: "--repo").map { list[$0 + 1] } == "axhoover/cryptology.city")
        #expect(list.firstIndex(of: "--head").map { list[$0 + 1] } == "fix/x")
        #expect(list.firstIndex(of: "--state").map { list[$0 + 1] } == "open")
        // `--head` matches a name alone: a fork's pull request from its own
        // fix/x is someone else's, never edited and never taken for ours.
        #expect(list.firstIndex(of: "--json").map { list[$0 + 1] }
            == "url,createdAt,isCrossRepository")
        #expect(list.firstIndex(of: "--jq").map { list[$0 + 1] }
            == #".[] | select(.isCrossRepository | not) | "\(.createdAt) \(.url)""#)
    }

    @Test("the commit message is the title, a blank line, and where it came from")
    func commitMessage() {
        #expect(Publisher.commitMessage(
            title: "[fix] Pseudorandom function: Security", version: "0.3.0",
            jobID: "20261011-142210-118-edit-pseudorandom-function")
            == "[fix] Pseudorandom function: Security\n\n"
            + "Opened with CCwiki 0.3.0 (job 20261011-142210-118-edit-pseudorandom-function).")
        #expect(Publisher.commitMessage(title: " [fix] A:\nB ", version: "0.3.0", jobID: "j")
            .hasPrefix("[fix] A: B\n\n"), "a subject is one line")
    }

    @Test("a failure is told by git's own first fatal line, not by its advice")
    func reasons() {
        let output = """
            fatal: '/tmp/nowhere.git' does not appear to be a git repository
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.
            """
        #expect(Publisher.reason(in: output) == "'/tmp/nowhere.git' does not appear to be a git repository")
        #expect(Publisher.reason(in: "GraphQL: Resource not accessible by integration (createPullRequest)\n")
            == "GraphQL: Resource not accessible by integration (createPullRequest)")
        #expect(Publisher.reason(in: "") == "")
        #expect(Publisher.pushFailure("fix/x", output: output).hasPrefix(
            "The push of fix/x failed: '/tmp/nowhere.git' does not appear to be a git repository."))
        // A push stopped at the deadline, or cut off after GitHub moved the
        // branch, may have landed: the message never says nothing was sent.
        #expect(Publisher.pushFailure("fix/x", output: "") == "The push of fix/x failed. "
            + "It may or may not have reached GitHub; opening the pull request again checks "
            + "where the branch is on GitHub before pushing.")
    }

    // MARK: Recovering a refused lease

    @Test("a refused lease: absent retries on absence; ours retries expecting it")
    func recoveryOurs() {
        #expect(Publisher.leaseRecovery(remoteTip: nil, pushing: "c1", pushed: "c0", reflog: [])
            == .retry(expecting: nil))
        #expect(Publisher.leaseRecovery(remoteTip: "c1", pushing: "c1", pushed: nil, reflog: [])
            == .retry(expecting: "c1"))
        #expect(Publisher.leaseRecovery(remoteTip: "c0", pushing: "c1", pushed: "c0", reflog: [])
            == .retry(expecting: "c0"))
        #expect(Publisher.leaseRecovery(
            remoteTip: "c-old", pushing: "c2", pushed: nil, reflog: ["c-old", "c2"])
            == .retry(expecting: "c-old"), "every Approve's commit is in the reflog")
    }

    @Test("a refused lease: someone else's branch is renamed from, or refused after a push")
    func recoveryTheirs() {
        #expect(Publisher.leaseRecovery(
            remoteTip: "theirs", pushing: "c1", pushed: nil, reflog: ["c1"]) == .rename)
        #expect(Publisher.leaseRecovery(
            remoteTip: "theirs", pushing: "c2", pushed: "c1", reflog: ["c1", "c2"]) == .refuse)
    }

    // MARK: Confirming the pull request

    @Test("only an open PR created after the job started counts, and the newest wins")
    func createdAfter() throws {
        let started = try #require(ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z"))
        let listing = """
            2026-09-20T09:00:00Z https://github.com/axhoover/cryptology.city/pull/36
            2026-09-27T10:05:00Z https://github.com/axhoover/cryptology.city/pull/41
            2026-09-27T10:02:00Z https://github.com/axhoover/cryptology.city/pull/40
            garbage line
            """
        let url = Publisher.pullRequest(createdAfter: started, in: listing)
        #expect(url?.absoluteString == "https://github.com/axhoover/cryptology.city/pull/41")
        #expect(Publisher.pullRequest(createdAfter: started, in: "") == nil)
        #expect(Publisher.pullRequest(
            createdAfter: started,
            in: "2026-09-20T09:00:00Z https://github.com/axhoover/cryptology.city/pull/36") == nil,
            "a PR from an earlier job on the same branch name is not this job's")
        #expect(Publisher.pullRequest(createdAfter: .distantPast, in: listing)?.absoluteString
            == "https://github.com/axhoover/cryptology.city/pull/41")
    }

    // MARK: With real git

    /// The scene's publisher, pushing to the bare origin.
    static func publisher(_ scene: JobScene) -> Publisher {
        Publisher(paths: scene.paths, tools: scene.tools, git: scene.git, target: scene.target)
    }

    /// An edit of `content/page.md` to `text`, reviewed, with a title: the
    /// digest of the diff a person would have seen.
    @discardableResult
    static func edit(_ scene: JobScene, _ job: Job, to text: String) async throws -> String {
        try scene.write("content/page.md", text, in: job)
        let snapshot = try #require(await ReviewSnapshotter(git: scene.git).snapshot(
            worktree: job.worktree, base: scene.base, patchFile: job.patchFile))
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        return snapshot.digest
    }

    /// `edit`, then the commit Approve makes of it.
    static func commit(
        _ scene: JobScene, _ publisher: Publisher, _ job: Job, to text: String
    ) async throws -> String {
        let reviewed = try await edit(scene, job, to: text)
        let outcome = await publisher.commit(job, version: "0.3.0", reviewed: reviewed)
        return try #require(outcome.commit, "\(outcome)")
    }

    @Test("the commit collapses whatever the agent committed into one on the base")
    func commit() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        let agent = await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false), "commit", "-q", "-a",
                        "--no-verify", "-m", "the agent's own commit"],
            environment: FixtureRepository.environment(date: 1_780_000_200))
        try #require(agent.succeeded, "\(agent.output)")

        let commit = try await Self.commit(scene, Self.publisher(scene), job, to: "a\nB\nC")
        #expect(await scene.git.resolveCommit("\(commit)^", in: job.worktree) == scene.base)
        let message = await scene.clone.run(["log", "-1", "--format=%B", commit])
        #expect(message.stdout.hasPrefix("[fix] Page: B\n\nOpened with CCwiki 0.3.0 (job \(job.id))."))
        let shown = await scene.git.blob("\(commit):content/page.md", in: job.worktree)
        #expect(shown == Data("a\nB\nC".utf8))
        #expect(await scene.git.resolveCommit("refs/heads/fix/page", in: job.worktree) == commit)
        #expect(job.state == .publishing("Committing…"))
    }

    @Test("a commit whose tree is not the reviewed change is not made, and says why")
    func commitNotReviewed() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        let reviewed = try await Self.edit(scene, job, to: "a\nB\nc")
        try await Self.edit(scene, job, to: "a\nBB\nc")

        let outcome = await Self.publisher(scene).commit(job, version: "0.3.0", reviewed: reviewed)
        guard case .notReviewed = outcome else {
            Issue.record("committed what was not reviewed: \(outcome)")
            return
        }
        #expect(await scene.git.resolveCommit("refs/heads/fix/page", in: job.worktree) == scene.base)
        #expect(job.log.contains { $0.text.contains("is not the reviewed change") })
    }

    @Test("pushes lease on absence first, then on the last push, and record both")
    func push() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()

        let first = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        #expect(await publisher.push(job, commit: first) == .pushed)
        #expect(job.pushedCommit == first && job.pushingCommit == nil)
        #expect(await scene.originTip("fix/page") == .at(first))

        let second = try await Self.commit(scene, publisher, job, to: "a\nBB\nc")
        #expect(await publisher.push(job, commit: second) == .pushed)
        #expect(job.pushedCommit == second)
        #expect(await scene.originTip("fix/page") == .at(second))

        let onDisk = try JSONDecoder().decode(JobRecord.self, from: Data(contentsOf: job.recordFile))
        #expect(onDisk.pushedCommit == second)
    }

    @Test("a push whose reply was lost is recognised as ours, and pushed over")
    func lostReply() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()

        let first = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        #expect(await publisher.push(job, commit: first) == .pushed)
        // The push reached GitHub; the app went away before it heard.
        job.setPushedCommit(nil)
        job.setPushingCommit(first)

        let second = try await Self.commit(scene, publisher, job, to: "a\nBB\nc")
        #expect(await publisher.push(job, commit: second) == .pushed)
        #expect(await scene.originTip("fix/page") == .at(second))
        #expect(job.branch == "fix/page")
        #expect(job.pushedCommit == second)
    }

    @Test("a branch someone else made is left alone: the job takes the next free name")
    func taken() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()
        let theirs = try await scene.foreignCommit(on: scene.base)
        try await scene.pushToOrigin(theirs, as: "fix/page")

        let ours = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        #expect(await publisher.push(job, commit: ours) == .pushed)
        #expect(job.branch == "fix/page-2")
        #expect(await scene.originTip("fix/page-2") == .at(ours))
        #expect(await scene.originTip("fix/page") == .at(theirs), "their branch is untouched")
        #expect(job.log.contains { $0.text == "fix/page was taken on GitHub; using fix/page-2." })
        let head = await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false),
                        "rev-parse", "--abbrev-ref", "HEAD"],
            environment: FixtureRepository.environment())
        #expect(head.stdout == "fix/page-2")
    }

    @Test("commits someone else pushed after ours are never overwritten")
    func refused() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()

        let first = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        #expect(await publisher.push(job, commit: first) == .pushed)
        let theirs = try await scene.foreignCommit(on: first)
        try await scene.pushToOrigin(theirs, as: "fix/page")

        let second = try await Self.commit(scene, publisher, job, to: "a\nBB\nc")
        #expect(await publisher.push(job, commit: second) == .refused(Publisher.notOurs("fix/page")))
        #expect(await scene.originTip("fix/page") == .at(theirs))
        #expect(job.pushedCommit == first)
    }

    @Test("a push to nowhere fails, and remembers what it was pushing")
    func unreachable() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let nowhere = PublishTarget(
            repository: "axhoover/cryptology.city",
            pushURL: scene.root.appending(path: "no-such-origin.git").absoluteString,
            isDevBuild: true, isOverridden: true)
        let publisher = Publisher(
            paths: scene.paths, tools: scene.tools, git: scene.git, target: nowhere)
        let job = try await scene.beginEdit()
        let commit = try await Self.commit(scene, publisher, job, to: "a\nB\nc")

        guard case .failed(let message) = await publisher.push(job, commit: commit) else {
            Issue.record("a push to a repository that is not there did not fail")
            return
        }
        #expect(message.hasPrefix("The push of fix/page failed"))
        #expect(message.contains("It may or may not have reached GitHub"))
        #expect(job.pushingCommit == commit && job.pushedCommit == nil,
                "what was being pushed is remembered for next time")
    }

    // MARK: No hook, and only the commit that was checked

    @Test("the push names the commit that was checked, whatever moves HEAD after")
    func pushNamesTheCheckedCommit() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()
        let checked = try await Self.commit(scene, publisher, job, to: "a\nB\nc")

        // HEAD, and the branch with it, move once the commit was checked.
        try scene.write("content/page.md", "a\nunreviewed\nc", in: job)
        let moved = await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false), "commit", "-q", "-a",
                        "--no-verify", "-m", "moved"],
            environment: FixtureRepository.environment(date: 1_780_000_300))
        try #require(moved.succeeded, "\(moved.output)")
        let head = try #require(await scene.git.resolveCommit("HEAD", in: job.worktree))
        #expect(head != checked)

        #expect(await publisher.push(job, commit: checked) == .pushed)
        #expect(await scene.originTip("fix/page") == .at(checked))
        #expect(job.pushedCommit == checked)
        let command = try #require(job.log.last { $0.text.hasPrefix("git ") })
        #expect(command.text.hasPrefix("git -c core.hooksPath=/dev/null push --no-verify "))
        #expect(command.text.hasSuffix(" \(checked):refs/heads/fix/page"))
        #expect(!command.text.contains("HEAD"))
    }

    /// A `gh` that is signed in, may push, and opens pull request 99.
    static let gitHubThatOpens = #"""
        dir=$(dirname "$0")
        case "$1 $2" in
        "auth status") exit 0 ;;
        "api repos/axhoover/cryptology.city") echo true ;;
        "pr list")
            if [ -f "$dir/opened" ]; then
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) https://github.com/axhoover/cryptology.city/pull/99"
            fi ;;
        "pr create")
            touch "$dir/opened"
            echo https://github.com/axhoover/cryptology.city/pull/99 ;;
        *) echo "unexpected: gh $*" >&2; exit 1 ;;
        esac
        exit 0
        """#

    @Test("Approve runs no hook from staging to the push, and pushes the reviewed tree on the base")
    func approveRunsNoHook() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { GitHubAuth.invalidate() }
        let tools = try JobScene.fakeTools([.gh: Self.gitHubThatOpens], in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        let written = await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false), "write-tree"],
            environment: FixtureRepository.environment())
        let reviewedTree = written.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(written.succeeded && !reviewedTree.isEmpty, "\(written.output)")

        // Hooks everywhere, from now on, in the directory the clone's own
        // configuration names; post-commit amends HEAD with extra.md.
        let trap = try await HookTrap.install(beside: scene.clone)
        let result = await scene.center.approve(job)
        let ran = trap.ran()

        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/99"))
        #expect(result == .opened(url), "\(result); \(job.log.map(\.text))")
        #expect(ran.isEmpty, "hooks ran: \(ran)")
        let commit = try #require(job.pushedCommit)
        #expect(await scene.originTip("fix/page") == .at(commit))
        let tree = await scene.clone.run(["rev-parse", "\(commit)^{tree}"])
        #expect(tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == reviewedTree,
                "the tree that was reviewed")
        let parents = await scene.clone.run(["rev-list", "--parents", "-n", "1", commit])
        #expect(parents.stdout == "\(commit) \(scene.base)", "one commit, on the base")
        #expect(await scene.git.blob("\(commit):extra.md", in: scene.clone.root) == nil)
        let command = try #require(job.log.last { $0.text.hasPrefix("git ") })
        #expect(command.text.hasPrefix("git -c core.hooksPath=/dev/null push --no-verify "))
        #expect(command.text.hasSuffix(" \(commit):refs/heads/fix/page"),
                "the push names the validated commit")

        // The control: the hooks are live for git's own commands.
        #expect(await scene.clone.run(["update-ref", "refs/heads/control", scene.base]).succeeded)
        #expect(trap.ran().contains("reference-transaction"), "\(trap.ran())")
    }

    @Test("a tree staged after the check is never published: the job goes back to review")
    func approveRefusesWhatWasNotReviewed() async throws {
        guard let git = ToolLocator.locate(.git, override: nil) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { GitHubAuth.invalidate() }
        // Asked whether it may push, after the check's snapshot and before
        // the commit, this gh stages a file nobody reviewed.
        let tools = try JobScene.fakeTools([.gh: #"""
            worktree=$(cat "$(dirname "$0")/worktree")
            case "$1 $2" in
            "auth status") exit 0 ;;
            "api repos/axhoover/cryptology.city")
                printf 'unreviewed\n' > "$worktree/extra.md"
                GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
                    '\#(git)' -C "$worktree" -c core.hooksPath=/dev/null add extra.md
                echo true ;;
            *) echo "unexpected: gh $*" >&2; exit 1 ;;
            esac
            exit 0
            """#], in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try Data(job.worktree.path(percentEncoded: false).utf8)
            .write(to: directory.appending(path: "worktree"))
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")

        let result = await scene.center.approve(job)
        #expect(result == .refused(Publisher.notReviewed), "\(result)")
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(tone: .warning, text: Publisher.notReviewed))
        #expect(job.pushingCommit == nil && job.pushedCommit == nil, "no push was even tried")
        #expect(await scene.originTip("fix/page") == .absent)
        #expect(await scene.git.resolveCommit("refs/heads/fix/page", in: scene.clone.root)
            == scene.base, "the branch never moved")
    }

    // MARK: Checking, which needs the review model

    @Test("Approve refuses a diff that changed since it was reviewed")
    func changedSinceReview() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        let reviewed = try #require(job.review?.digest)
        try scene.write("content/page.md", "a\nBB\nc", in: job)

        #expect(await Self.publisher(scene).check(job, reviewed: reviewed) == .changedSinceReview)
        #expect(job.review?.digest != reviewed, "the review now shows the new diff")
    }

    @Test("Approve asks GitHub last, and without gh nothing is sent")
    func withoutGH() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        #expect(job.findings.allSatisfy { $0.severity != .blocking })

        let result = await scene.center.approve(job)
        #expect(result == .refused(GitHubAccess.ghMissing.banner ?? ""))
        #expect(job.state == .awaitingReview)
        #expect(job.notice?.tone == .warning)
        #expect(await scene.originTip("fix/page") == .absent)
    }

    @Test("Approve refuses without a git identity, before GitHub is asked")
    func withoutIdentity() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        let reviewed = try #require(job.review?.digest)

        let anonymous = GitService(
            executable: scene.clone.git,
            environment: FixtureRepository.environment().filter { !$0.key.hasPrefix("GIT_AUTHOR_") })
        let publisher = Publisher(
            paths: scene.paths, tools: scene.tools, git: anonymous, target: scene.target)
        #expect(await publisher.check(job, reviewed: reviewed) == .refused(Publisher.identityMissing))
    }
}
