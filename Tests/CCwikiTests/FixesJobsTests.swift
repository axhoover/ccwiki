import Foundation
import Testing
@testable import CCwiki

/// Regressions in the jobs' pipeline (plans/corrections.md §4.1, §4.4, §5.5,
/// §6.5): Cancel during an ingestion's pre-flight, the tripwire after Clear
/// Finished, what Review Anyway says when it cannot go ahead, and the
/// editors a Restore reloads.
@Suite("Fixes: jobs")
@MainActor
struct FixesJobsTests {

    // MARK: Cancel

    @Test("a cancelled job stays cancelled whatever its runner sets as it winds down")
    func cancelledStaysCancelled() throws {
        let paths = try JobRecordTests.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.support) }
        let job = Job(kind: .ingestion(JobRecordTests.submission), paths: paths)
        job.cancel()
        #expect(job.state == .cancelled)

        job.setState(.preparing("Creating worktree…"))
        #expect(job.state == .cancelled)
        job.setState(.failed("Pre-flight checks failed. Nothing was created."))
        #expect(job.state == .cancelled)
        let onDisk = try JSONDecoder().decode(
            JobRecord.self, from: Data(contentsOf: job.recordFile))
        #expect(onDisk.state == .cancelled)

        // Review Anyway may still take it to review.
        job.setState(.awaitingReview)
        #expect(job.state == .awaitingReview)
    }

    @Test("Cancel while an ingestion's pre-flight asks leaves it cancelled, with no findings")
    func cancelDuringPreflight() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = Job(kind: .ingestion(JobRecordTests.submission), paths: scene.paths)
        let paths = scene.paths
        let tools = scene.tools
        let git = scene.git
        let target = scene.target
        job.task = Task { @MainActor in
            await IngestJobRunner(
                paths: paths, tools: tools, git: git, index: nil, target: target
            ).run(job)
        }

        // The runner says "Checking…" and asks git whether the clone can
        // push; Cancel lands while it waits.
        var turns = 0
        while job.state == .queued, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        try #require(job.state == .preparing("Checking…"), "\(job.state)")
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "\(job.state)")
        // No tool is found here, so a pre-flight that went on would block.
        #expect(job.preflight.isEmpty, "a check that was stopped is not a finding")
        #expect(!job.log.contains { $0.text.hasPrefix("claude not found") })
    }

    @Test("an ingestion on a snapshot, or on no wiki at all, fails at once, with git asked nothing")
    func ingestionOnSnapshot() async throws {
        let paths = try JobRecordTests.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.support) }
        try FileManager.default.createDirectory(at: paths.clone, withIntermediateDirectories: true)
        try SnapshotService.write(
            SnapshotService.Marker(
                sha: "75f254251cd77489c40df4e664b9ccf4521b976a", commitDate: nil, fetchedAt: .now),
            in: paths.clone)
        try #require(paths.wikiStore == .snapshot)

        let job = Job(kind: .ingestion(JobRecordTests.submission), paths: paths)
        // A git that fails every command, so a check that ran would block.
        let git = GitService(executable: "/usr/bin/false", environment: [:])
        await IngestJobRunner(
            paths: paths, tools: ToolLocator(), git: git, index: nil,
            target: JobRecordTests.environment().target
        ).run(job)

        #expect(job.state == .failed(CorrectionJobRunner.snapshotStore), "\(job.state)")
        #expect(job.preflight.isEmpty, "no pre-flight on a folder that is not a clone")

        // Run Again after the clone was reset: nothing is there to sync from.
        try FileManager.default.removeItem(at: paths.clone)
        try #require(paths.wikiStore == AppPaths.WikiStore.none)
        let again = Job(kind: .ingestion(JobRecordTests.submission), paths: paths)
        await IngestJobRunner(
            paths: paths, tools: ToolLocator(), git: git, index: nil,
            target: JobRecordTests.environment().target
        ).run(again)
        #expect(again.state == .failed(CorrectionJobRunner.notCloned), "\(again.state)")
        #expect(again.preflight.isEmpty)
    }

    // MARK: The tripwire

    @Test("a push CCwiki made for a job Clear Finished has dropped is not the agent's")
    func tripwireAfterClearFinished() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let git = ToolLocator.locate(.git, override: nil) else { return }
        let root = JobScene.newRoot()
        let origin = root.appending(path: "origin.git").path(percentEncoded: false)
        // While the agent runs, another job's branch reaches GitHub, as an
        // Approve of that job would push it.
        let tools = try JobScene.fakeClaude("""
            printf 'a\\nB\\nc' > content/page.md
            '\(git)' push -q --no-verify '\(origin)' HEAD:refs/heads/fix/other
            """ + "\n" + JobCenterTests.readyForReview, in: directory)
        guard let scene = try await JobScene.make(root: root, tools: tools) else { return }
        defer { scene.delete() }

        // That job: an edit of another page, its pull request open.
        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/41"))
        let opened = JobRecordTests.record(
            "20261001-090000-000-edit-other", kind: .edit(scene.correctionTarget("other.md")),
            state: .opened(url: url))
        try #require(opened.branch == "fix/other")
        try JobRecordTests.write(opened, in: scene.paths)
        let center = scene.relaunched()
        try #require(center.job(id: opened.id) != nil)

        // Clear Finished drops it, record and all, before the agent exits.
        let job = center.startCorrection(JobCenterTests.request(scene))
        center.clearFinishedJobs()
        #expect(center.job(id: opened.id) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: scene.paths.record(forJob: opened.id).path(percentEncoded: false)))
        #expect(center.otherJobBranches(excluding: job.id) == ["fix/other"])

        await job.task?.value
        guard case .at = await scene.originTip("fix/other") else {
            Issue.record("the stand-in agent could not push; nothing for the tripwire to find")
            return
        }
        #expect(job.state == .awaitingReview, "\(job.state)")
        #expect(job.notice == nil, "\(job.notice?.text ?? "")")
        #expect(!job.log.contains { $0.text.hasPrefix("Tripwire:") })
    }

    // MARK: Review Anyway

    @Test("Review Anyway on a worktree without changes says so in the transcript, and is withdrawn")
    func reviewAnywayWithNothingToReview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ABORTED: the page is right; b is a variable.","num_turns":1}'
            """#, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(JobCenterTests.request(scene))
        await job.task?.value
        let aborted = JobState.aborted(reason: "ABORTED: the page is right; b is a variable.")
        try #require(job.state == aborted, "\(job.state)")
        #expect(Self.offersReviewAnyway(job), "nobody knows yet that the worktree holds nothing")

        await scene.center.reviewAnyway(job)
        let nothing = "The worktree holds no changes to review."
        #expect(job.state == aborted)
        #expect(job.review?.isEmpty == true)
        #expect(!Self.offersReviewAnyway(job), "withdrawn once the worktree is known to hold nothing")
        #expect(job.log.contains { $0.text == nothing })
        #expect(job.notice == JobNotice(tone: .warning, text: nothing))

        // A refusal for a worktree that has gone is in the transcript too.
        try FileManager.default.removeItem(at: job.worktree)
        await scene.center.reviewAnyway(job)
        let gone = "The worktree is gone, so there is nothing to review."
        let errors = job.log.filter { entry in
            if case .error = entry.role { return true }
            return false
        }
        #expect(errors.map(\.text).contains(gone))
        #expect(job.notice == JobNotice(tone: .failure, text: gone))
        #expect(job.state == aborted)
    }

    @Test("a Review Anyway that goes ahead clears its own earlier refusal, never another notice")
    func reviewAnywayClearsItsRefusal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            printf 'a\nB\nc' > content/page.md
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ABORTED: not sure b is wrong.","num_turns":1}'
            """#, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(JobCenterTests.request(scene))
        await job.task?.value
        try #require(job.state == .aborted(reason: "ABORTED: not sure b is wrong."), "\(job.state)")

        // Refused once, while the worktree's .git leads elsewhere.
        let file = job.worktree.appending(path: ".git")
        let link = try Data(contentsOf: file)
        try Data("gitdir: .ccwiki\n".utf8).write(to: file)
        await scene.center.reviewAnyway(job)
        #expect(job.notice == JobNotice(tone: .failure, text: GitService.redirectedWorktree))

        // Put back, it goes ahead, and the refusal goes with it.
        try link.write(to: file)
        await scene.center.reviewAnyway(job)
        #expect(job.state == .awaitingReview, "\(job.state)")
        #expect(job.notice == nil, "\(job.notice?.text ?? "")")

        // A tripwire's notice is not one of them.
        #expect(JobCenter.isReviewRefusal(JobNotice(tone: .warning, text: JobCenter.nothingToReview)))
        #expect(!JobCenter.isReviewRefusal(JobNotice(
            tone: .failure, text: "The agent pushed a branch while it ran: fix/page.")))
    }

    @Test("a refusal leaves the tripwire's notice, and the review that follows keeps it")
    func reviewAnywayKeepsTheTripwire() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let git = ToolLocator.locate(.git, override: nil) else { return }
        let root = JobScene.newRoot()
        let origin = root.appending(path: "origin.git").path(percentEncoded: false)
        // The agent pushes its branch itself, then aborts.
        let tools = try JobScene.fakeClaude("""
            printf 'a\\nB\\nc' > content/page.md
            '\(git)' push -q --no-verify '\(origin)' HEAD:refs/heads/fix/page
            """ + "\n" + #"""
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ABORTED: not sure b is wrong.","num_turns":1}'
            """#, in: directory)
        guard let scene = try await JobScene.make(root: root, tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(JobCenterTests.request(scene))
        await job.task?.value
        guard case .at = await scene.originTip("fix/page") else {
            Issue.record("the stand-in agent could not push; nothing for the tripwire to find")
            return
        }
        try #require(job.state == .aborted(reason: "ABORTED: not sure b is wrong."), "\(job.state)")
        let tripwire = JobNotice(
            tone: .warning, text: "The agent pushed fix/page itself, bypassing review.")
        try #require(job.notice == tripwire, "\(job.notice?.text ?? "")")

        // Refused while the worktree's .git leads elsewhere: the transcript
        // says why, and the notice is still the tripwire's.
        let file = job.worktree.appending(path: ".git")
        let link = try Data(contentsOf: file)
        try Data("gitdir: .ccwiki\n".utf8).write(to: file)
        await scene.center.reviewAnyway(job)
        #expect(job.log.contains { $0.text == GitService.redirectedWorktree })
        #expect(job.notice == tripwire, "\(job.notice?.text ?? "")")

        // Put back, it goes ahead, and the review says the agent pushed.
        try link.write(to: file)
        await scene.center.reviewAnyway(job)
        #expect(job.state == .awaitingReview, "\(job.state)")
        #expect(job.notice == tripwire, "\(job.notice?.text ?? "")")
    }

    @Test("Review Anyway asks git for no base through a .git that leads elsewhere")
    func reviewAnywayWithoutABaseRedirected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            printf 'a\nB\nc' > content/page.md
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ABORTED: not sure b is wrong.","num_turns":1}'
            """#, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let started = scene.center.startCorrection(JobCenterTests.request(scene))
        await started.task?.value
        let aborted = JobState.aborted(reason: "ABORTED: not sure b is wrong.")
        try #require(started.state == aborted, "\(started.state)")

        // Its record as one written before 0.3 has it, with no base.
        let data = try Data(contentsOf: started.recordFile)
        var record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        record["baseCommit"] = nil
        try JSONSerialization.data(withJSONObject: record).write(to: started.recordFile)
        let center = scene.relaunched()
        let job = try #require(center.job(id: started.id))
        try #require(job.baseCommit == nil && job.state == aborted)

        // The agent pointed the worktree's .git at a folder of its own.
        try Data("gitdir: .ccwiki\n".utf8).write(to: job.worktree.appending(path: ".git"))
        await center.reviewAnyway(job)
        #expect(job.notice == JobNotice(tone: .failure, text: GitService.redirectedWorktree),
                "\(job.notice?.text ?? "")")
        #expect(job.baseCommit == nil, "no base is taken from a repository the agent chose")
        #expect(job.state == aborted)
    }

    // MARK: The hand-over

    @Test("an agent that points the worktree's .git elsewhere gets no git add there")
    func handOverRedirected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A folder of its own, read from the worktree as git reads it.
        let tools = try JobScene.fakeClaude(#"""
            printf 'a\nB\nc' > content/page.md
            printf 'gitdir: .ccwiki\n' > .git
            """# + "\n" + JobCenterTests.readyForReview, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(JobCenterTests.request(scene))
        await job.task?.value
        #expect(job.state == .failed(AgentRun.redirectedAtHandOver), "\(job.state)")
        #expect(job.log.contains { $0.text == GitService.redirectedWorktree })
        #expect(FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)),
            "the worktree is kept, for inspection")
    }

    private static func offersReviewAnyway(_ job: Job) -> Bool {
        JobReview.offersReviewAnyway(
            kind: job.kind.tag, state: job.state,
            worktreeExists: FileManager.default.fileExists(
                atPath: job.worktree.path(percentEncoded: false)),
            review: job.review)
    }

    // MARK: Restore and the editors

    @Test("after a Restore, every editor of the job that could not load or save reloads")
    func restoreReloadsWaitingEditors() {
        let page = EditorTarget(jobID: "job", path: "content/page.md")
        // Revert File, or a Restore whose diff holds the file.
        #expect(AppModel.reloadsEditor(
            page, of: "job", changed: ["content/page.md"], isLoaded: true, saveFailed: false))
        // Another file, in an editor that loaded and saved: left as it is.
        #expect(!AppModel.reloadsEditor(
            page, of: "job", changed: ["content/other.md"], isLoaded: true, saveFailed: false))
        // An untouched edit's Restore changes nothing: an editor that never
        // loaded, or whose save was refused, reloads all the same.
        #expect(AppModel.reloadsEditor(
            page, of: "job", changed: [], isLoaded: false, saveFailed: false))
        #expect(AppModel.reloadsEditor(
            page, of: "job", changed: [], isLoaded: true, saveFailed: true))
        // Never another job's editor.
        #expect(!AppModel.reloadsEditor(
            page, of: "other", changed: ["content/page.md"], isLoaded: false, saveFailed: true))
    }
}
