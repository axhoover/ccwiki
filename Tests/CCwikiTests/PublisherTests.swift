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
        #expect(first.contains("--no-follow-tags"), "one ref, and no tag with it")
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

    /// An attempt to push `commit` to `branch` in the target repository, or
    /// in `repository`.
    static func attempt(
        _ commit: String, to branch: String = "fix/x",
        in repository: String = "axhoover/cryptology.city"
    ) -> PushAttempt {
        PushAttempt(repository: repository, branch: branch, commit: commit)
    }

    /// `leaseRecovery` for fix/x in the target repository.
    static func recovery(tip: String?, pushed: String?, attempts: [PushAttempt])
        -> Publisher.LeaseRecovery {
        Publisher.leaseRecovery(
            remoteTip: tip, pushed: pushed, attempts: attempts,
            repository: "axhoover/cryptology.city", branch: "fix/x")
    }

    @Test("a refused lease: absent retries on absence; ours retries expecting it")
    func recoveryOurs() {
        #expect(Self.recovery(tip: nil, pushed: "c0", attempts: [Self.attempt("c1")])
            == .retry(expecting: nil))
        #expect(Self.recovery(tip: nil, pushed: nil, attempts: [])
            == .retry(expecting: nil), "absent is absent, whoever asks")
        #expect(Self.recovery(tip: "c1", pushed: nil, attempts: [Self.attempt("c1")])
            == .retry(expecting: "c1"), "the push being made")
        #expect(Self.recovery(tip: "c0", pushed: "c0", attempts: [])
            == .retry(expecting: "c0"), "the last confirmed push, in a record without attempts")
        #expect(Self.recovery(
            tip: "c-old", pushed: nil, attempts: [Self.attempt("c-old"), Self.attempt("c2")])
            == .retry(expecting: "c-old"), "an earlier push whose reply was lost")
        #expect(Self.recovery(
            tip: "c-old", pushed: "c1",
            attempts: [Self.attempt("c1"), Self.attempt("c-old"), Self.attempt("c2")])
            == .retry(expecting: "c-old"), "after a confirmed push too")
    }

    @Test("a refused lease: someone else's branch is renamed from, or refused after a push")
    func recoveryTheirs() {
        #expect(Self.recovery(tip: "theirs", pushed: nil, attempts: [Self.attempt("c1")])
            == .rename)
        #expect(Self.recovery(tip: "theirs", pushed: nil, attempts: []) == .rename)
        #expect(Self.recovery(
            tip: "theirs", pushed: "c1", attempts: [Self.attempt("c1"), Self.attempt("c2")])
            == .refuse)
    }

    @Test("a refused lease: only an attempt for this repository and this branch makes a tip ours")
    func recoveryElsewhere() {
        let elsewhere = [
            Self.attempt("c1", to: "fix/x-2"),
            Self.attempt("c1", to: "fix/y"),
            Self.attempt("c1", to: "fix/x", in: "someone/fork"),
            Self.attempt("c1", to: "fix/x", in: "axhoover/ccwiki"),
        ]
        for attempt in elsewhere {
            let before = [Self.attempt("c0"), attempt, Self.attempt("c2")]
            #expect(Self.recovery(tip: "c1", pushed: nil, attempts: Array(before.dropFirst()))
                == .rename, "\(attempt)")
            #expect(Self.recovery(tip: "c1", pushed: "c0", attempts: before)
                == .refuse, "\(attempt)")
        }
        // The branch a rename left: an attempt for fix/x says nothing of
        // fix/x-2, and one for fix/x-2 nothing of fix/x.
        let renamed = [Self.attempt("c1"), Self.attempt("c2", to: "fix/x-2")]
        #expect(Publisher.leaseRecovery(
            remoteTip: "c1", pushed: nil, attempts: renamed,
            repository: "axhoover/cryptology.city", branch: "fix/x-2") == .rename)
        #expect(Publisher.leaseRecovery(
            remoteTip: "c2", pushed: nil, attempts: renamed,
            repository: "axhoover/cryptology.city", branch: "fix/x-2") == .retry(expecting: "c2"))
        #expect(Self.recovery(tip: "c2", pushed: nil, attempts: renamed) == .rename)
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
    /// snapshot a person would have seen.
    @discardableResult
    static func edit(_ scene: JobScene, _ job: Job, to text: String) async throws
        -> ReviewSnapshot {
        try scene.write("content/page.md", text, in: job)
        let snapshot = try #require(await ReviewSnapshotter(git: scene.git).snapshot(
            worktree: job.worktree, base: scene.base, patchFile: job.patchFile))
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        return snapshot
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
        #expect(onDisk.pushAttempts == [
            Self.attempt(first, in: scene), Self.attempt(second, in: scene),
        ], "each push, recorded before it was sent, and kept")
    }

    /// An attempt to push `commit` to `branch` in the scene's target.
    static func attempt(_ commit: String, to branch: String = "fix/page", in scene: JobScene)
        -> PushAttempt {
        PushAttempt(repository: scene.target.repository, branch: branch, commit: commit)
    }

    /// Every commit the job's branch has pointed at, from git's reflog:
    /// what a refused lease's recovery once took for CCwiki's own.
    static func reflog(_ scene: JobScene, _ job: Job) async -> [String] {
        let result = await agent(
            scene, job, ["log", "--walk-reflogs", "--format=%H", "refs/heads/\(job.branch)", "--"])
        return result.stdout.split(separator: "\n").map(String.init)
    }

    /// A publisher whose pushes, to the scene's repository by name, never
    /// arrive: the origin it names is not there.
    static func offline(_ scene: JobScene) -> Publisher {
        let nowhere = PublishTarget(
            repository: scene.target.repository,
            pushURL: scene.root.appending(path: "no-such-origin.git").absoluteString,
            isDevBuild: true, isOverridden: true)
        return Publisher(paths: scene.paths, tools: scene.tools, git: scene.git, target: nowhere)
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
        #expect(job.log.contains {
            $0.text == "fix/page is at \(first.prefix(12)) on GitHub, which CCwiki pushed."
        })
        #expect(job.pushAttempts == [Self.attempt(first, in: scene), Self.attempt(second, in: scene)])
    }

    @Test("a push whose reply was lost is recognised after a relaunch, with a failed push since")
    func lostReplyAcrossARelaunch() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()

        let first = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        #expect(await publisher.push(job, commit: first) == .pushed)
        // The push reached GitHub; the app went away before it heard.
        job.setPushedCommit(nil)
        job.setPushingCommit(first)
        // The next Approve's push never arrived, so pushingCommit now names
        // a commit GitHub does not have: only the attempt remembers first.
        let offline = Self.offline(scene)
        let second = try await Self.commit(scene, offline, job, to: "a\nBB\nc")
        guard case .failed = await offline.push(job, commit: second) else {
            Issue.record("a push to a repository that is not there did not fail")
            return
        }
        #expect(job.pushingCommit == second && job.pushedCommit == nil)
        #expect(await scene.originTip("fix/page") == .at(first))

        // The job comes back from its record alone.
        let center = scene.relaunched()
        let restored = try #require(center.job(id: job.id))
        #expect(restored !== job)
        #expect(restored.pushAttempts == [
            Self.attempt(first, in: scene), Self.attempt(second, in: scene),
        ])
        #expect(restored.pushingCommit == second && restored.pushedCommit == nil)

        let third = try await Self.commit(scene, publisher, restored, to: "a\nBBB\nc")
        #expect(await publisher.push(restored, commit: third) == .pushed)
        #expect(await scene.originTip("fix/page") == .at(third))
        #expect(restored.branch == "fix/page", "recognised as ours, not renamed from")
        #expect(restored.pushedCommit == third)
        #expect(restored.log.contains {
            $0.text == "fix/page is at \(first.prefix(12)) on GitHub, which CCwiki pushed."
        })
    }

    @Test("the push a record from before attempts were kept was making is recognised after a relaunch")
    func lostReplyInAnOldRecord() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()

        // What the last release did: persist pushingCommit, push, and lose
        // the reply. Its record names no attempts.
        let first = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        job.setPushingCommit(first)
        let sent = await scene.git.push(
            first, in: job.worktree, to: scene.target.pushURL, branch: job.branch, expecting: nil)
        try #require(sent.succeeded, "\(sent.output)")
        let data = try Data(contentsOf: job.recordFile)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pushAttempts"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: job.recordFile)

        let center = scene.relaunched()
        let restored = try #require(center.job(id: job.id))
        #expect(restored.pushAttempts.isEmpty && restored.pushingCommit == first)

        let second = try await Self.commit(scene, publisher, restored, to: "a\nBB\nc")
        #expect(await publisher.push(restored, commit: second) == .pushed)
        #expect(await scene.originTip("fix/page") == .at(second))
        #expect(restored.branch == "fix/page")
        #expect(restored.pushAttempts == [
            Self.attempt(first, in: scene), Self.attempt(second, in: scene),
        ], "the old record's push is kept, as an attempt on its branch, before the new one")
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
        #expect(job.pushAttempts == [
            Self.attempt(ours, in: scene), Self.attempt(ours, to: "fix/page-2", in: scene),
        ], "the retry after the rename is recorded with the branch it went to")
    }

    /// A `gh` that is signed in and may push, with someone else's pull
    /// request 7 open from fix/page, and that opens pull request 99 from
    /// any other branch. It notes the branch of each pull request it opens
    /// in `created`, and each pull request it edits in `edited`.
    static let gitHubWithTheirs = #"""
        dir=$(dirname "$0")
        case "$1 $2" in
        "auth status") exit 0 ;;
        "api repos/axhoover/cryptology.city") echo true ;;
        "pr list")
            if [ "$6" = fix/page ]; then
                echo "2026-10-01T09:00:00Z https://github.com/axhoover/cryptology.city/pull/7"
            elif grep -qxF -- "$6" "$dir/created" 2>/dev/null; then
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) https://github.com/axhoover/cryptology.city/pull/99"
            fi ;;
        "pr create")
            echo "$9" >> "$dir/created"
            echo https://github.com/axhoover/cryptology.city/pull/99 ;;
        "pr edit")
            echo "$3" >> "$dir/edited" ;;
        *) echo "unexpected: gh $*" >&2; exit 1 ;;
        esac
        exit 0
        """#

    @Test("a branch made at the job's base after it started is someone else's: renamed from, and their PR untouched")
    func takenAtTheBase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { GitHubAuth.invalidate() }
        let tools = try JobScene.fakeTools([.gh: Self.gitHubWithTheirs], in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        #expect(job.branch == "fix/page")
        // The job's branch was made at the base, so the base is in its reflog.
        #expect(await Self.reflog(scene, job).contains(scene.base))
        // Then someone else makes fix/page on GitHub at that same base, and
        // opens pull request 7 from it.
        try await scene.pushToOrigin(scene.base, as: "fix/page")

        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        job.pullRequest = PullRequestDraft(title: "[fix] Page: B", body: "Capitalised b.")
        let result = await scene.center.approve(job)

        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/99"))
        #expect(result == .opened(url), "\(result); \(job.log.map(\.text))")
        #expect(job.branch == "fix/page-2")
        let commit = try #require(job.pushedCommit)
        #expect(await scene.originTip("fix/page-2") == .at(commit))
        #expect(await scene.originTip("fix/page") == .at(scene.base), "their branch is untouched")
        #expect(job.log.contains { $0.text == "fix/page was taken on GitHub; using fix/page-2." })
        let created = try? String(contentsOf: directory.appending(path: "created"), encoding: .utf8)
        #expect(created == "fix/page-2\n", "the pull request is opened from the job's own branch")
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "edited").path(percentEncoded: false)),
            "their pull request is never edited")
    }

    @Test("a commit the job's branch was moved through, never pushed by CCwiki, does not make a branch ours")
    func takenAtACommitInTheReflog() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let publisher = Self.publisher(scene)
        let job = try await scene.beginEdit()
        // Someone's commit, which the job's branch is moved through (an
        // agent's reset, say), and which they push as fix/page.
        let theirs = try await scene.foreignCommit(on: scene.base)
        #expect(await Self.agent(scene, job, ["update-ref", "refs/heads/fix/page", theirs]).succeeded)
        try await scene.pushToOrigin(theirs, as: "fix/page")

        let ours = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
        #expect(await Self.reflog(scene, job).contains(theirs), "their commit is in the reflog")
        #expect(await publisher.push(job, commit: ours) == .pushed)
        #expect(job.branch == "fix/page-2")
        #expect(await scene.originTip("fix/page-2") == .at(ours))
        #expect(await scene.originTip("fix/page") == .at(theirs), "their branch is untouched")
    }

    @Test("an attempt for another branch, or another repository, does not make a branch ours")
    func attemptedElsewhere() async throws {
        let elsewhere = [
            (repository: "axhoover/cryptology.city", branch: "fix/other"),
            (repository: "someone/fork", branch: "fix/page"),
        ]
        for place in elsewhere {
            guard let scene = try await JobScene.make() else { return }
            defer { scene.delete() }
            let publisher = Self.publisher(scene)
            let job = try await scene.beginEdit()
            // The job's first commit was sent elsewhere, its reply lost, and
            // someone has since pushed that commit as fix/page here.
            let first = try await Self.commit(scene, publisher, job, to: "a\nB\nc")
            job.recordPushAttempt(PushAttempt(
                repository: place.repository, branch: place.branch, commit: first))
            job.setPushingCommit(first)
            try await scene.pushToOrigin(first, as: "fix/page")

            let second = try await Self.commit(scene, publisher, job, to: "a\nBB\nc")
            #expect(await publisher.push(job, commit: second) == .pushed, "\(place)")
            #expect(job.branch == "fix/page-2", "\(place)")
            #expect(await scene.originTip("fix/page-2") == .at(second), "\(place)")
            #expect(await scene.originTip("fix/page") == .at(first),
                    "that branch is untouched: \(place)")
        }
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
        #expect(job.pushAttempts == [Self.attempt(commit, in: scene)],
                "and where it went, recorded before it was sent")
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
        #expect(command.text.hasPrefix(Self.loggedPush), "\(command.text)")
        #expect(command.text.hasSuffix(" \(checked):refs/heads/fix/page"))
        #expect(!command.text.contains("HEAD"))
    }

    /// How the transcript starts the push it ran: the objects themselves,
    /// every hook off, and one ref with no tag.
    static let loggedPush = "git --no-replace-objects -c core.useReplaceRefs=false "
        + "-c core.hooksPath=/dev/null -c core.fsmonitor=false "
        + "push --no-verify --no-follow-tags --recurse-submodules=no "

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
        #expect(job.review?.tree == reviewedTree, "the review is of the staged tree, by name")

        // Hooks everywhere, from now on, in the directory the clone's own
        // configuration names; post-commit amends HEAD with extra.md, and
        // the clone's configuration names a file-system monitor too.
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
        #expect(command.text.hasPrefix(Self.loggedPush), "\(command.text)")
        #expect(command.text.hasSuffix(" \(commit):refs/heads/fix/page"),
                "the push names the validated commit")

        // The control: the hooks and the monitor are live for git's own
        // commands.
        #expect(await scene.clone.run(["update-ref", "refs/heads/control", scene.base]).succeeded)
        #expect(trap.ran().contains("reference-transaction"), "\(trap.ran())")
        #expect(await scene.clone.run(["status", "--porcelain"]).succeeded)
        #expect(trap.ran().contains(HookTrap.fsmonitor), "\(trap.ran())")
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

    // MARK: What git shows is what git sends (the PR #11 review)

    /// git in the job's worktree, as an agent would run it.
    @discardableResult
    static func agent(_ scene: JobScene, _ job: Job, _ arguments: [String]) async
        -> Subprocess.Result {
        await Subprocess.run(
            executable: scene.clone.git,
            arguments: ["-C", job.worktree.path(percentEncoded: false)] + arguments,
            environment: FixtureRepository.environment())
    }

    /// Approve of `job`, whose review must hold `hidden`, a file git's own
    /// diff does not show: DiffGuard blocks it, and nothing is sent.
    static func approveRefuses(_ scene: JobScene, _ job: Job, showing hidden: String) async {
        let porcelain = await agent(scene, job, ["diff", "--cached", "--name-only", scene.base])
        #expect(porcelain.stdout == "content/page.md", "git's own diff hides \(hidden)")

        await scene.center.refreshReview(job)
        #expect(job.review?.files.map(\.path) == ["content/page.md", hidden])
        #expect(job.findings.contains { $0.path == hidden && $0.severity == .blocking },
                "\(job.findings)")

        let result = await scene.center.approve(job)
        guard case .refused(let message) = result else {
            Issue.record("Approve did not refuse what the review must show: \(result)")
            return
        }
        #expect(message.hasPrefix("DiffGuard blocks this change"), "\(message)")
        #expect(job.state == .awaitingReview)
        #expect(await scene.originTip("fix/page") == .absent, "nothing was pushed")
    }

    @Test("a replaced tree hides nothing from the review, and Approve refuses the file it hid")
    func approveSeesPastReplacements() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        // An agent (it keeps node) stages extra.md, writes that tree, and
        // makes it stand in for the base's tree in the clone's shared refs.
        try scene.write("extra.md", "unreviewed\n", in: job)
        #expect(await Self.agent(scene, job, ["add", "extra.md"]).succeeded)
        let planted = await Self.agent(scene, job, ["write-tree"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = await Self.agent(scene, job, ["replace", "\(scene.base)^{tree}", planted])
        try #require(replaced.succeeded, "git replace: \(replaced.output)")
        try scene.write("content/page.md", "a\nB\nc", in: job)
        #expect(await Self.agent(scene, job, ["add", "-A"]).succeeded)

        await Self.approveRefuses(scene, job, showing: "extra.md")
    }

    @Test("a submodule's new commit is in the review whatever diff.ignoreSubmodules says, and Approve refuses it")
    func approveSeesSubmodules() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        #expect(await scene.clone.run(["config", "diff.ignoreSubmodules", "all"]).succeeded)
        // What `git submodule update --remote` and an add leave: a gitlink at
        // a new commit, its directory there and not populated.
        let commit = String(repeating: "1", count: 40)
        let linked = await Self.agent(
            scene, job, ["update-index", "--add", "--cacheinfo", "160000,\(commit),vendor/cryptobib"])
        try #require(linked.succeeded, "git update-index: \(linked.output)")
        try FileManager.default.createDirectory(
            at: job.worktree.appending(path: "vendor/cryptobib"), withIntermediateDirectories: true)
        try scene.write("content/page.md", "a\nB\nc", in: job)
        #expect(await Self.agent(scene, job, ["add", "-A"]).succeeded)

        await Self.approveRefuses(scene, job, showing: "vendor/cryptobib")
    }

    // MARK: Checking, which needs the review model

    @Test("Approve refuses a diff that changed since it was reviewed")
    func changedSinceReview() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        let reviewed = try #require(job.review)
        try scene.write("content/page.md", "a\nBB\nc", in: job)

        #expect(await Self.publisher(scene).check(job, reviewed: reviewed) == .changedSinceReview)
        #expect(job.review?.digest != reviewed.digest, "the review now shows the new diff")
        #expect(job.review?.tree != reviewed.tree)
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
        let reviewed = try #require(job.review)

        let anonymous = GitService(
            executable: scene.clone.git,
            environment: FixtureRepository.environment().filter { !$0.key.hasPrefix("GIT_AUTHOR_") })
        let publisher = Publisher(
            paths: scene.paths, tools: scene.tools, git: anonymous, target: scene.target)
        #expect(await publisher.check(job, reviewed: reviewed) == .refused(Publisher.identityMissing))
    }
}
