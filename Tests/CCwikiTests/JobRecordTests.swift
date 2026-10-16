import Foundation
import Testing
@testable import CCwiki

/// What a job keeps across a relaunch, and what stopping the app does to
/// each kind of work (plans/corrections.md §4.1–§4.3, §12.1).
@MainActor
struct JobRecordTests {

    /// A record exactly as 0.2 wrote it, with synthesized `Codable`: a
    /// `submission` and no `kind`, no `createdAt`, none of the review's
    /// fields. JSONEncoder escapes slashes.
    static let legacyOpened = #"""
        {"id":"20250927-100000-000-eprint-2025-375","submission":{"kind":"url","source":{"eprint":{"year":"2025","number":"375"}},"notes":"Check the LWE page.","submittedAt":780652800},"branch":"ingest\/eprint-2025-375","state":{"opened":{"url":"https:\/\/github.com\/axhoover\/cryptology.city\/pull\/41"}},"startedAt":780652810,"finishedAt":780653900}
        """#

    /// One 0.2 wrote for a job that was running when the app went away.
    static let legacyRunning = #"""
        {"id":"20250927-110000-000-arxiv-2401-12345","submission":{"kind":"url","source":{"arXiv":{"id":"2401.12345"}},"notes":"","submittedAt":780656400},"branch":"ingest\/arxiv-2401-12345","state":{"running":{}},"startedAt":780656410}
        """#

    static let target = CorrectionTarget(
        pagePath: "Primitives/pseudorandom-function.md", pageTitle: "Pseudorandom function",
        baseCommit: "865206d47c53",
        section: CorrectionTarget.Section(id: "security", title: "Security", level: 2),
        lines: LineRange(first: 42, last: 44), region: .body,
        quote: "for every PPT $\\calA$", excerpt: "For every PPT $\\calA$,")

    static let submission = IngestSubmission(
        kind: .url, source: .eprint(year: "2025", number: "375"), localPDF: nil,
        notes: "Check the LWE page.", submittedAt: Date(timeIntervalSinceReferenceDate: 780_652_800))

    static let created = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Records

    @Test("a record 0.2 wrote decodes as an ingestion, created when it was submitted")
    func legacyRecord() throws {
        let record = try JSONDecoder().decode(JobRecord.self, from: Data(Self.legacyOpened.utf8))
        guard case .ingestion(let submission) = record.kind else {
            Issue.record("a 0.2 record is an ingestion")
            return
        }
        #expect(submission.source == .eprint(year: "2025", number: "375"))
        #expect(submission.notes == "Check the LWE page.")
        #expect(record.createdAt == submission.submittedAt)
        #expect(record.branch == "ingest/eprint-2025-375")
        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/41"))
        #expect(record.state == .opened(url: url))
        #expect(record.baseCommit == nil)
        #expect(record.pullRequest == nil)
        #expect(record.pushingCommit == nil && record.pushedCommit == nil && record.notice == nil)
        #expect(record.pushAttempts.isEmpty)

        let running = try JSONDecoder().decode(JobRecord.self, from: Data(Self.legacyRunning.utf8))
        #expect(running.state == .running)
        #expect(running.finishedAt == nil)
    }

    @Test("each kind round-trips, through the memberwise init")
    func kindsRoundTrip() throws {
        let kinds: [JobKind] = [
            .ingestion(Self.submission),
            .correction(CorrectionRequest(
                target: Self.target, description: "It should say PRP.", model: "sonnet")),
            .edit(Self.target),
        ]
        for kind in kinds {
            let record = JobRecord(
                id: "job", kind: kind, branch: "fix/pseudorandom-function",
                state: .awaitingReview, createdAt: Self.created, startedAt: nil, finishedAt: nil,
                baseCommit: "865206d47c53",
                pullRequest: PullRequestDraft(title: "[fix] Pseudorandom function", body: "Why."),
                pushingCommit: "abc", pushedCommit: nil, pushAttempts: Self.attempts,
                notice: JobNotice(tone: .warning, text: "The files changed since you reviewed them."))
            let decoded = try JSONDecoder().decode(
                JobRecord.self, from: JSONEncoder().encode(record))
            #expect(decoded.kind == kind)
            #expect(decoded.state == .awaitingReview)
            #expect(decoded.createdAt == Self.created)
            #expect(decoded.baseCommit == "865206d47c53")
            #expect(decoded.pullRequest == record.pullRequest)
            #expect(decoded.pushingCommit == "abc" && decoded.pushedCommit == nil)
            #expect(decoded.pushAttempts == Self.attempts, "in order, each with where it went")
            #expect(decoded.notice == record.notice)
        }
    }

    /// Two attempts, the second after a rename.
    static let attempts = [
        PushAttempt(repository: "axhoover/cryptology.city", branch: "fix/pseudorandom-function",
                    commit: "abc"),
        PushAttempt(repository: "axhoover/cryptology.city", branch: "fix/pseudorandom-function-2",
                    commit: "abc"),
    ]

    @Test("a record written before push attempts were kept decodes with none, and keeps what it was pushing")
    func recordWithoutAttempts() throws {
        let record = JobRecord(
            id: "job", kind: .edit(Self.target), branch: "fix/pseudorandom-function",
            state: .awaitingReview, createdAt: Self.created, startedAt: nil, finishedAt: nil,
            baseCommit: "865206d47c53", pullRequest: nil, pushingCommit: "abc",
            pushedCommit: "def", pushAttempts: Self.attempts, notice: nil)
        // The record as the last release wrote it: every field but this one.
        let data = try JSONEncoder().encode(record)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let named = object.removeValue(forKey: "pushAttempts") != nil
        #expect(named, "a record names its attempts")
        let old = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(JobRecord.self, from: old)
        #expect(decoded.pushAttempts.isEmpty)
        #expect(decoded.pushingCommit == "abc" && decoded.pushedCommit == "def")
        #expect(decoded.branch == "fix/pseudorandom-function")
        #expect(decoded.kind == .edit(Self.target))

        let paths = try Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.support) }
        let job = Job(restoring: decoded, paths: paths, worktreeExists: true, patchExists: false)
        #expect(job.pushAttempts.isEmpty && job.pushingCommit == "abc")
        #expect(job.hasTriedToPush)
    }

    @Test("every state round-trips, and the old ones keep their labels")
    func statesRoundTrip() throws {
        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/41"))
        let states: [JobState] = [
            .queued, .preparing("Creating worktree…"), .running, .awaitingReview,
            .publishing("Pushing fix/x…"), .opened(url: url), .aborted(reason: "No."),
            .failed("claude exited 1."), .cancelled, .discarded,
        ]
        for state in states {
            let decoded = try JSONDecoder().decode(JobState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state)
        }
        #expect(JobState.opened(url: url).label == "Draft PR opened")
        #expect(JobState.cancelled.label == "Cancelled")
        #expect(JobState.awaitingReview.label == "Awaiting review")
        #expect(!JobState.awaitingReview.isActive && !JobState.awaitingReview.isTerminal)
        #expect(JobState.publishing("x").isActive && !JobState.publishing("x").isCancellable)
        #expect(JobState.discarded.isTerminal)
    }

    @Test("an ingestion keeps its id and branch; a correction's id names its kind")
    func identities() throws {
        let paths = try Self.temporaryPaths()
        let ingestion = Job(kind: .ingestion(Self.submission), paths: paths, createdAt: Self.created)
        #expect(ingestion.id.hasSuffix("-eprint-2025-375"))
        #expect(!ingestion.id.contains("ingestion"))
        #expect(ingestion.branch == "ingest/eprint-2025-375")

        let edit = Job(kind: .edit(Self.target), paths: paths, createdAt: Self.created)
        #expect(edit.id.hasSuffix("-edit-pseudorandom-function"))
        #expect(edit.branch == "fix/pseudorandom-function")
        #expect(edit.patchFile == paths.logs.appending(path: edit.id + ".patch"))
        #expect(edit.scratch == paths.cacheRoot.appending(path: "scratch").appending(path: edit.id))
        #expect(edit.title == "Pseudorandom function")
        #expect(edit.detail == "Lines 42–44, in “Security”")
        #expect(edit.submission == nil && ingestion.submission == Self.submission)
    }

    // MARK: Stopping

    @Test("cancel() leaves a review as it is")
    func cancelSparesReview() throws {
        let paths = try Self.temporaryPaths()
        let job = Job(
            restoring: Self.record("review", kind: .edit(Self.target), state: .awaitingReview),
            paths: paths, worktreeExists: true, patchExists: false)
        job.cancel()
        #expect(job.state == .awaitingReview)
        #expect(!job.log.contains { $0.text == "Cancelled." })
    }

    /// `stopJobs` is `cancelActiveJobs` without `Subprocess.terminateAll()`,
    /// which here would also signal other tests' git.
    @Test("stopping the jobs cancels an agent, spares a review, and returns a publish to review")
    func stoppingJobs() throws {
        let paths = try Self.temporaryPaths()
        for id in ["review", "publish", "agent"] {
            try Self.write(
                Self.record(id, kind: .edit(Self.target), state: .awaitingReview), in: paths)
            try FileManager.default.createDirectory(
                at: paths.worktree(forJob: id), withIntermediateDirectories: true)
        }
        let center = JobCenter(paths: paths) { Self.environment() }
        let publishing = try #require(center.job(id: "publish"))
        publishing.setState(.publishing("Pushing fix/pseudorandom-function…"))
        let agent = try #require(center.job(id: "agent"))
        agent.setState(.running)
        #expect(center.activeJobCount == 2 && center.publishingCount == 1)

        center.stopJobs()

        for id in ["review", "publish"] {
            let job = try #require(center.job(id: id))
            #expect(job.state == .awaitingReview, "\(id) in memory")
            let onDisk = try JSONDecoder().decode(
                JobRecord.self, from: Data(contentsOf: job.recordFile))
            #expect(onDisk.state == .awaitingReview, "\(id) on disk")
        }
        #expect(publishing.log.contains { $0.text == Job.publishingInterrupted })
        #expect(agent.state == .cancelled)
        #expect(center.activeJobCount == 0)
    }

    // MARK: Relaunch

    @Test("a fresh job center has its records as soon as it is made, newest first")
    func historyLoadsInInit() throws {
        let paths = try Self.temporaryPaths()
        try Data(Self.legacyOpened.utf8).write(
            to: paths.record(forJob: "20250927-100000-000-eprint-2025-375"))
        try Self.write(
            Self.record("newer", kind: .edit(Self.target), state: .discarded), in: paths)
        let center = JobCenter(paths: paths) { Self.environment() }
        #expect(center.jobs.map(\.id) == ["newer", "20250927-100000-000-eprint-2025-375"])
        #expect(center.hasFinishedJobs)
    }

    @Test("restoration follows the table in §4.3, row by row")
    func restorationRows() throws {
        let interrupted = Job.restoration(of: .running, worktreeExists: true, patchExists: true)
        #expect(interrupted.state == .failed(Job.interruptedByQuit))
        #expect(Job.restoration(of: .queued, worktreeExists: false, patchExists: false).state
            == .failed(Job.interruptedByQuit))

        let review = Job.restoration(of: .awaitingReview, worktreeExists: true, patchExists: false)
        #expect(review.state == .awaitingReview && !review.needsRestore && review.note == nil)

        let patchOnly = Job.restoration(of: .awaitingReview, worktreeExists: false, patchExists: true)
        #expect(patchOnly.state == .awaitingReview && patchOnly.needsRestore)

        let lost = Job.restoration(of: .awaitingReview, worktreeExists: false, patchExists: false)
        #expect(lost.state == .failed(Job.reviewLost) && !lost.needsRestore)

        let publishing = Job.restoration(
            of: .publishing("Pushing…"), worktreeExists: true, patchExists: true)
        #expect(publishing.state == .awaitingReview)
        #expect(publishing.note == Job.publishingInterrupted)

        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/41"))
        let finished: [JobState] = [
            .opened(url: url), .aborted(reason: "No."), .failed("x"), .cancelled, .discarded,
        ]
        for state in finished {
            #expect(Job.restoration(of: state, worktreeExists: false, patchExists: false).state
                == state)
        }
    }

    @Test("restored from disk: a review with its worktree, one with only its patch, one with neither")
    func restorationFromDisk() throws {
        let paths = try Self.temporaryPaths()
        for id in ["worktree", "patch", "neither"] {
            try Self.write(
                Self.record(id, kind: .edit(Self.target), state: .awaitingReview), in: paths)
        }
        try FileManager.default.createDirectory(
            at: paths.worktree(forJob: "worktree"), withIntermediateDirectories: true)
        try Data("diff --git a/x b/x\n".utf8).write(to: paths.patch(forJob: "patch"))

        let center = JobCenter(paths: paths) { Self.environment() }
        let worktree = try #require(center.job(id: "worktree"))
        #expect(worktree.state == .awaitingReview && !worktree.needsRestore && worktree.canEdit)
        let patch = try #require(center.job(id: "patch"))
        #expect(patch.state == .awaitingReview && patch.needsRestore && !patch.canEdit)
        let neither = try #require(center.job(id: "neither"))
        #expect(neither.state == .failed(Job.reviewLost))
        #expect(center.jobs(touching: Self.target.pagePath).map(\.id).sorted()
            == ["patch", "worktree"])
    }

    @Test("the transcript is appended to after a relaunch, never truncated")
    func transcriptAppends() throws {
        let paths = try Self.temporaryPaths()
        let file = paths.log(forJob: "job")
        try Data("{\"type\":\"system\"}\n".utf8).write(to: file)
        let writer = LogWriter(file: file)
        writer.write("Restored.")
        writer.close()
        writer.waitUntilWritten()
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"type\":\"system\"}\nRestored.\n")
    }

    // MARK: The transcript, replayed

    @Test("CCwiki's own lines keep their role, their time and their line breaks")
    func transcriptLines() throws {
        let at = Date(timeIntervalSince1970: 1_760_263_200.5)
        let entries = [
            JobLogEntry(.system, "git worktree add x -b fix/page abc", at: at),
            JobLogEntry(.error, "Permission denied — Bash: git push", at: at),
            JobLogEntry(.assistant, "READY FOR REVIEW\n\nTwo lines, and a \"quote\".", at: at),
            JobLogEntry(.tool(name: "Edit"), "content/page.md", at: at),
            JobLogEntry(.toolResult(isError: true), "No such file", at: at),
            JobLogEntry(.stderr, "warning", at: at),
        ]
        for entry in entries {
            let line = try #require(TranscriptLine.encode(entry))
            #expect(!line.contains("\n"), "one entry is one line")
            let decoded = try #require(TranscriptLine.decode(Substring(line)))
            #expect(decoded.text == entry.text)
            #expect(decoded.timestamp == at)
            #expect(String(describing: decoded.role) == String(describing: entry.role))
        }
        #expect(TranscriptLine.decode(#"{"type":"assistant","message":{}}"#) == nil)
        #expect(TranscriptLine.decode("plain stderr") == nil)
    }

    @Test("a transcript file comes back as the agent's events, its stderr and CCwiki's lines, in order")
    func transcriptFile() throws {
        let own = try #require(TranscriptLine.encode(JobLogEntry(.system, "Creating worktree…")))
        let text = [
            own,
            #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet","cwd":"/w/job"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the page."},{"type":"tool_use","name":"Read","input":{"file_path":"content/page.md"}}]}}"#,
            "npm warn deprecated",
            #"{"type":"result","subtype":"success","is_error":false,"result":"READY FOR REVIEW","num_turns":4,"total_cost_usd":0.03}"#,
        ].joined(separator: "\n") + "\n"
        let replayed = Job.transcript(from: text)
        #expect(replayed.entries.map(\.text) == [
            "Creating worktree…", "Session started · claude-sonnet · job", "Reading the page.",
            "content/page.md", "npm warn deprecated",
        ])
        #expect(replayed.outcome?.turns == 4)
        #expect(replayed.outcome?.result == "READY FOR REVIEW")
    }

    @Test("a restored job replays what earlier launches wrote, once, before what it logs now")
    func replay() async throws {
        let paths = try Self.temporaryPaths()
        try Self.write(Self.record("review", kind: .edit(Self.target), state: .awaitingReview),
                       in: paths)
        try FileManager.default.createDirectory(
            at: paths.worktree(forJob: "review"), withIntermediateDirectories: true)
        let earlier = try #require(TranscriptLine.encode(JobLogEntry(.system, "Edited by hand.")))
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","num_turns":2}"#
        try Data((earlier + "\n" + result + "\n").utf8).write(to: paths.log(forJob: "review"))

        let center = JobCenter(paths: paths) { Self.environment() }
        let job = try #require(center.job(id: "review"))
        #expect(job.log.count == 1 && job.outcome == nil)
        // Written by this launch, after the restore: already in `log`, never replayed.
        let handle = try FileHandle(forWritingTo: paths.log(forJob: "review"))
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("this launch\n".utf8))
        try handle.close()

        await job.replayTranscript()
        #expect(job.log.map(\.text).first == "Edited by hand.")
        #expect(job.log.last?.text.hasPrefix("Restored from an earlier launch.") == true)
        #expect(!job.log.contains { $0.text == "this launch" })
        #expect(job.outcome?.turns == 2)

        await job.replayTranscript()
        #expect(job.log.count == 2, "a second replay changes nothing")
    }

    @Test("a job from this launch has nothing to replay")
    func noReplay() async throws {
        let paths = try Self.temporaryPaths()
        let job = Job(kind: .edit(Self.target), paths: paths)
        job.append(JobLogEntry(.system, "Live."))
        await job.replayTranscript()
        #expect(job.log.map(\.text) == ["Live."])
    }

    // MARK: The pull request, as edited

    @Test("an edited pull request is written within a second, and at once when the app stops")
    func pullRequestPersists() async throws {
        let paths = try Self.temporaryPaths()
        try Self.write(Self.record("review", kind: .edit(Self.target), state: .awaitingReview),
                       in: paths)
        try FileManager.default.createDirectory(
            at: paths.worktree(forJob: "review"), withIntermediateDirectories: true)
        let center = JobCenter(paths: paths) { Self.environment() }
        let job = try #require(center.job(id: "review"))
        func onDisk() throws -> PullRequestDraft? {
            try JSONDecoder().decode(JobRecord.self, from: Data(contentsOf: job.recordFile)).pullRequest
        }

        job.pullRequest.title = "[fix] Pseudorandom function: Security"
        #expect(try onDisk() == nil, "not at every keystroke")
        try await Task.sleep(for: .milliseconds(2_000))
        #expect(try onDisk()?.title == "[fix] Pseudorandom function: Security")

        job.pullRequest.body = "Why."
        center.stopJobs()
        #expect(try onDisk()?.body == "Why.")
    }

    @Test("a restored edit with a saved, non-empty patch counts as awaiting review")
    func restoredEditWithChanges() throws {
        let paths = try Self.temporaryPaths()
        for id in ["changed", "unchanged"] {
            try Self.write(Self.record(id, kind: .edit(Self.target), state: .awaitingReview),
                           in: paths)
            try FileManager.default.createDirectory(
                at: paths.worktree(forJob: id), withIntermediateDirectories: true)
        }
        try Data("diff --git a/x b/x\n".utf8).write(to: paths.patch(forJob: "changed"))
        try Data().write(to: paths.patch(forJob: "unchanged"))

        let center = JobCenter(paths: paths) { Self.environment() }
        let changed = try #require(center.job(id: "changed"))
        let unchanged = try #require(center.job(id: "unchanged"))
        #expect(changed.statusLabel == "Awaiting review")
        #expect(unchanged.statusLabel == "Editing")
        #expect(center.reviewCount == 1)
    }

    @Test("an edit with no changes yet is Editing, and is not counted as awaiting review")
    func untouchedEdit() throws {
        let paths = try Self.temporaryPaths()
        try Self.write(Self.record("edit", kind: .edit(Self.target), state: .awaitingReview), in: paths)
        try Self.write(
            Self.record("correction", kind: .correction(CorrectionRequest(
                target: Self.target, description: "PRP", model: "sonnet")), state: .awaitingReview),
            in: paths)
        for id in ["edit", "correction"] {
            try FileManager.default.createDirectory(
                at: paths.worktree(forJob: id), withIntermediateDirectories: true)
        }
        let center = JobCenter(paths: paths) { Self.environment() }
        let edit = try #require(center.job(id: "edit"))
        let correction = try #require(center.job(id: "correction"))
        #expect(edit.statusLabel == "Editing")
        #expect(correction.statusLabel == "Awaiting review")
        #expect(center.reviewCount == 1)
    }

    // MARK: Helpers

    static func temporaryPaths() throws -> AppPaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ccwiki-jobs-\(UUID().uuidString)")
        let paths = AppPaths(support: root)
        try paths.createDirectories()
        return paths
    }

    static func record(_ id: String, kind: JobKind, state: JobState) -> JobRecord {
        JobRecord(
            id: id, kind: kind, branch: kind.branchPrefix + kind.slug, state: state,
            createdAt: id == "newer" ? created.addingTimeInterval(60) : created,
            startedAt: nil, finishedAt: nil, baseCommit: "865206d47c53", pullRequest: nil,
            pushingCommit: nil, pushedCommit: nil, pushAttempts: [], notice: nil)
    }

    static func write(_ record: JobRecord, in paths: AppPaths) throws {
        try JSONEncoder().encode(record).write(to: paths.record(forJob: record.id))
    }

    static func environment() -> JobCenter.Environment {
        JobCenter.Environment(
            tools: ToolLocator(), git: nil, index: nil, relations: .empty, labels: .empty,
            appVersion: "0.3.0", correctionModel: "sonnet",
            target: PublishTarget(
                repository: "axhoover/cryptology.city", pushURL: "origin",
                isDevBuild: true, isOverridden: false),
            privatePaths: [])
    }
}

/// What the quit, relaunch and hand-over alerts say about the jobs they
/// would stop (plans/corrections.md §11.1).
struct StopJobsWordingTests {

    @Test("nothing to stop asks nothing")
    func nothing() {
        #expect(StopJobsWording.make(agents: 0, publishing: 0, action: "quit", verb: "Quit") == nil)
    }

    @Test("agents and a publish are counted apart")
    func counted() throws {
        let agents = try #require(StopJobsWording.make(
            agents: 2, publishing: 0, action: "relaunch", verb: "Relaunch"))
        #expect(agents.message == "Stop 2 running jobs and relaunch?")
        #expect(agents.informative == StopJobsWording.agentDetail)
        #expect(agents.confirmTitle == "Stop Jobs and Relaunch")
        #expect(agents.cancelTitle == "Don't Relaunch")

        let publishing = try #require(StopJobsWording.make(
            agents: 0, publishing: 1, action: "quit", verb: "Quit"))
        #expect(publishing.message == "Quit while a pull request is being opened?")
        #expect(publishing.informative == StopJobsWording.publishingDetail)
        #expect(publishing.confirmTitle == "Quit")

        let both = try #require(StopJobsWording.make(
            agents: 1, publishing: 1, action: "quit", verb: "Quit",
            agentsMessage: "Quit and stop the running job?"))
        #expect(both.message == "Quit and stop the running job?")
        #expect(both.informative.hasPrefix(StopJobsWording.agentDetail))
        #expect(both.informative.hasSuffix(StopJobsWording.publishingDetail))
        #expect(both.confirmTitle == "Stop Job and Quit")
    }
}
