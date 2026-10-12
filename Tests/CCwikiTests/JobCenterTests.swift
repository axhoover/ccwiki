import Foundation
import Testing
@testable import CCwiki

/// A wiki clone at `paths.clone`, a bare `origin` beside it standing in for
/// GitHub, and a job center over both: where the review's tests run
/// (plans/corrections.md §12.2). Nothing touches the network: the publish
/// target is the bare repository's `file://` URL, and no `gh` is found.
/// Nil when git is not installed.
@MainActor
struct JobScene {
    let paths: AppPaths
    let clone: FixtureRepository
    /// The bare repository the clone's `origin` names.
    let origin: URL
    /// `origin/main` when the scene was made: every job's base.
    let base: String
    let tools: ToolLocator
    let center: JobCenter

    var git: GitService { clone.service }
    var root: URL { paths.support }

    /// Where pull requests would go: the bare repository, as a URL, so the
    /// tripwire and the publisher use it as it is.
    var target: PublishTarget {
        Self.target(origin: origin)
    }

    /// A page without a final newline, a page with a generated region, and
    /// a page nobody changes.
    static let page = "a\nb\nc"
    static let region = """
        ---
        title: Region
        ---
        # Region

        Text.

        ## Participates in

        <!-- BEGIN GENERATED participates-in checksum=000000000000 -->
        - [[page]]
        <!-- END GENERATED participates-in -->

        """

    /// A new root for a scene, so a test can know where its origin will be
    /// (`root/origin.git`) before it makes it.
    nonisolated static func newRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ccwiki-review-\(UUID().uuidString)")
    }

    static func make(root: URL = JobScene.newRoot(), tools: ToolLocator = ToolLocator()) async throws
        -> JobScene? {
        let paths = AppPaths(support: root)
        try paths.createDirectories()
        guard let clone = await FixtureRepository.make(at: paths.clone) else {
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        let origin = root.appending(path: "origin.git")
        let bare = await Subprocess.run(
            executable: clone.git,
            arguments: ["init", "-q", "--bare", "-b", "main", origin.path(percentEncoded: false)],
            environment: FixtureRepository.environment())
        try #require(bare.succeeded, "git init --bare: \(bare.output)")

        try clone.write("content/page.md", page)
        try clone.write("content/region.md", region)
        try clone.write("content/other.md", "other\n")
        try #require(await clone.commit("init", date: 1_780_000_000) != nil)
        for arguments in [["remote", "add", "origin", origin.path(percentEncoded: false)],
                          ["push", "-q", "origin", "main"],
                          ["fetch", "-q", "origin"]] {
            let result = await clone.run(arguments)
            try #require(result.succeeded, "git \(arguments[0]): \(result.output)")
        }
        let base = try #require(await clone.service.resolveCommit("origin/main", in: clone.root))

        let git = clone.service
        let target = Self.target(origin: origin)
        let center = JobCenter(paths: paths) {
            JobCenter.Environment(
                tools: tools, git: git, index: nil, relations: .empty, labels: .empty,
                appVersion: "0.3.0", correctionModel: "sonnet", target: target,
                privatePaths: [])
        }
        return JobScene(
            paths: paths, clone: clone, origin: origin, base: base, tools: tools, center: center)
    }

    static func target(origin: URL) -> PublishTarget {
        PublishTarget(
            repository: "axhoover/cryptology.city", pushURL: origin.absoluteString,
            isDevBuild: true, isOverridden: true)
    }

    func delete() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The same paths and git, after a relaunch: a new job center, which
    /// loads the records.
    func relaunched() -> JobCenter {
        let git = self.git
        let tools = self.tools
        let target = self.target
        return JobCenter(paths: paths) {
            JobCenter.Environment(
                tools: tools, git: git, index: nil, relations: .empty, labels: .empty,
                appVersion: "0.3.0", correctionModel: "sonnet", target: target,
                privatePaths: [])
        }
    }

    /// Line 2 of `content/<path>`, in the section "B".
    func correctionTarget(_ path: String = "page.md") -> CorrectionTarget {
        CorrectionTarget(
            pagePath: path, pageTitle: "Page", baseCommit: base,
            section: CorrectionTarget.Section(id: "b", title: "B", level: 2),
            lines: LineRange(first: 2, last: 2), region: .body, quote: "b", excerpt: "b")
    }

    func beginEdit(_ path: String = "page.md") async throws -> Job {
        try await center.beginEdit(correctionTarget(path)).get()
    }

    /// Writes into the job's worktree, as an editor or an agent would.
    func write(_ path: String, _ text: String, in job: Job) throws {
        let file = job.worktree.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String, in job: Job) throws -> String {
        try String(contentsOf: job.worktree.appending(path: path), encoding: .utf8)
    }

    /// The job's saved patch, as text.
    func patch(of job: Job) -> String {
        String(decoding: (try? Data(contentsOf: job.patchFile)) ?? Data(), as: UTF8.self)
    }

    /// Where `branch` is in the bare origin.
    func originTip(_ branch: String) async -> RemoteTip {
        await git.remoteTip(of: branch, remote: origin.path(percentEncoded: false), in: clone.root)
    }

    /// A commit nobody in CCwiki made, on top of `parent`, in the clone's
    /// object database: what someone else pushes.
    func foreignCommit(on parent: String) async throws -> String {
        let result = await clone.run(
            ["commit-tree", "\(parent)^{tree}", "-p", parent, "-m", "someone else"],
            date: 1_780_000_500)
        try #require(result.succeeded, "git commit-tree: \(result.output)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `commit` pushed to `branch` in the origin, as someone else would.
    func pushToOrigin(_ commit: String, as branch: String) async throws {
        let result = await clone.run(
            ["push", "-q", "-f", origin.path(percentEncoded: false), "\(commit):refs/heads/\(branch)"])
        try #require(result.succeeded, "git push: \(result.output)")
    }

    /// A `claude` that runs `body` with `/bin/sh` in the job's worktree.
    static func fakeClaude(_ body: String, in directory: URL) throws -> ToolLocator {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "claude")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        var tools = ToolLocator(overrides: [.claude: file.path(percentEncoded: false)])
        tools.locate([.claude])
        return tools
    }
}

/// Stands in for the editors: counts each flush, and saves into the
/// worktree whatever was typed since the last one.
@MainActor
final class EditorStandIn {
    private(set) var flushes = 0
    /// Repository-relative path → the text "typed" and not yet saved.
    var typed: [String: String] = [:]

    func flush(_ job: Job) async {
        flushes += 1
        for (path, text) in typed {
            try? Data(text.utf8).write(to: job.worktree.appending(path: path))
        }
        typed = [:]
    }
}

/// The job center: its queue, its counts, and every way a job moves through
/// review (plans/corrections.md §4.4, §6, §12.1).
@MainActor
struct JobCenterTests {

    // MARK: Counts and lookups

    static func snapshot(changing path: String) -> ReviewSnapshot {
        ReviewSnapshot(
            baseCommit: "865206d47c53",
            files: [ChangedFile(
                path: path, oldPath: nil, status: .modified, isBinary: false,
                oldText: "a\n", newText: "b\n", hunks: [LineHunk(old: 0..<1, new: 0..<1)])],
            digest: "d")
    }

    @Test("reviewCount leaves out an untouched edit, and counts it once it changes something")
    func reviewCount() throws {
        let paths = try JobRecordTests.temporaryPaths()
        for id in ["edit", "correction"] {
            let kind: JobKind = id == "edit"
                ? .edit(JobRecordTests.target)
                : .correction(CorrectionRequest(
                    target: JobRecordTests.target, description: "PRP", model: "sonnet"))
            try JobRecordTests.write(
                JobRecordTests.record(id, kind: kind, state: .awaitingReview), in: paths)
            try FileManager.default.createDirectory(
                at: paths.worktree(forJob: id), withIntermediateDirectories: true)
        }
        let center = JobCenter(paths: paths) { JobRecordTests.environment() }
        let edit = try #require(center.job(id: "edit"))
        #expect(center.reviewCount == 1)

        edit.setReview(ReviewSnapshot(baseCommit: "b", files: [], digest: "e"), findings: [])
        #expect(edit.isUntouchedEdit && center.reviewCount == 1)

        edit.setReview(Self.snapshot(changing: "content/Primitives/pseudorandom-function.md"),
                       findings: [])
        #expect(!edit.isUntouchedEdit && edit.statusLabel == "Awaiting review")
        #expect(center.reviewCount == 2)
    }

    @Test("jobs(touching:) finds a job by its target, and by its snapshot")
    func touching() throws {
        let paths = try JobRecordTests.temporaryPaths()
        let ingestion = JobRecordTests.record(
            "ingestion", kind: .ingestion(JobRecordTests.submission), state: .awaitingReview)
        try JobRecordTests.write(ingestion, in: paths)
        try JobRecordTests.write(
            JobRecordTests.record("edit", kind: .edit(JobRecordTests.target), state: .awaitingReview),
            in: paths)
        for id in ["ingestion", "edit"] {
            try FileManager.default.createDirectory(
                at: paths.worktree(forJob: id), withIntermediateDirectories: true)
        }
        let center = JobCenter(paths: paths) { JobRecordTests.environment() }
        #expect(center.jobs(touching: "Primitives/pseudorandom-function.md").map(\.id) == ["edit"])
        #expect(center.jobs(touching: "Primitives/one-way-function.md").isEmpty)

        let job = try #require(center.job(id: "ingestion"))
        job.setReview(Self.snapshot(changing: "content/Primitives/one-way-function.md"), findings: [])
        #expect(center.jobs(touching: "Primitives/one-way-function.md").map(\.id) == ["ingestion"])
    }

    @Test("the Dock badge shows the count, and nothing at zero")
    func badge() {
        #expect(JobCenter.badgeLabel(for: 0) == nil)
        #expect(JobCenter.badgeLabel(for: 2) == "2")
    }

    @Test("the footer names how the change was made")
    func provenance() {
        let environment = JobRecordTests.environment()
        let paths = AppPaths(support: URL(fileURLWithPath: "/tmp/ccwiki-provenance"))
        let edit = Job(kind: .edit(JobRecordTests.target), paths: paths)
        let correction = Job(kind: .correction(CorrectionRequest(
            target: JobRecordTests.target, description: "PRP", model: "sonnet")), paths: paths)
        let cliDefault = Job(kind: .correction(CorrectionRequest(
            target: JobRecordTests.target, description: "PRP", model: "")), paths: paths)
        let ingestion = Job(kind: .ingestion(JobRecordTests.submission), paths: paths)
        #expect(JobCenter.provenance(for: edit, environment: environment).route == "edited by hand")
        #expect(JobCenter.provenance(for: correction, environment: environment).route
            == "drafted by claude (sonnet)")
        #expect(JobCenter.provenance(for: cliDefault, environment: environment).route
            == "drafted by claude")
        #expect(JobCenter.provenance(for: ingestion, environment: environment).route
            == "ingested by claude")
        let footer = JobCenter.provenance(for: edit, environment: environment)
        #expect(footer.appVersion == "0.3.0" && footer.isDevBuild)
    }

    // MARK: Editing

    @Test("an edit starts in review, in a worktree at the commit the reader rendered")
    func beginEdit() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }

        let job = try await scene.beginEdit()
        #expect(job.state == .awaitingReview && job.canEdit)
        #expect(job.baseCommit == scene.base)
        #expect(job.branch == "fix/page")
        #expect(job.isUntouchedEdit && job.statusLabel == "Editing")
        #expect(scene.center.reviewCount == 0)
        #expect(try scene.read("content/page.md", in: job) == JobScene.page)
        let head = await scene.git.resolveCommit("HEAD", in: job.worktree)
        #expect(head == scene.base)
        #expect(scene.center.jobs.first === job)

        // A second edit of the same page takes the next free branch.
        let second = try await scene.beginEdit()
        #expect(second.branch == "fix/page-2")
    }

    @Test("an edit is refused, leaving nothing behind, when the commit is not in the clone")
    func beginEditRefused() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let target = CorrectionTarget(
            pagePath: "page.md", pageTitle: "Page", baseCommit: String(repeating: "0", count: 40),
            section: nil, lines: nil, region: .body, quote: nil, excerpt: nil)
        let result = await scene.center.beginEdit(target)
        guard case .failure(let error) = result else {
            Issue.record("an unknown commit began an edit")
            return
        }
        #expect(error.message.contains("Sync (⌘R)"))
        #expect(scene.center.jobs.isEmpty)
        let records = try FileManager.default.contentsOfDirectory(atPath: scene.paths.logs
            .path(percentEncoded: false))
        #expect(records.isEmpty)
    }

    // MARK: The queue

    @Test("approve, revert and a refresh save the editors before git looks at the worktree")
    func flushFirst() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let editor = EditorStandIn()
        scene.center.flushEdits = { job in await editor.flush(job) }
        let job = try await scene.beginEdit()

        // What was typed reaches the snapshot, and so the saved patch.
        editor.typed["content/page.md"] = "a\nB\nc"
        await scene.center.refreshReview(job)
        #expect(editor.flushes == 1)
        #expect(scene.patch(of: job).contains("+B"))

        editor.typed["content/other.md"] = "changed\n"
        await scene.center.revert("content/page.md", in: job)
        #expect(editor.flushes == 2)
        let reverted = scene.patch(of: job)
        #expect(reverted.contains("+changed"), "the save came before the revert's snapshot")
        #expect(!reverted.contains("+B"), "the reverted file is back at the base")
        #expect(try scene.read("content/page.md", in: job) == JobScene.page)

        editor.typed["content/page.md"] = "a\nBB\nc"
        let result = await scene.center.approve(job)
        #expect(editor.flushes == 3)
        #expect(scene.patch(of: job).contains("+BB"), "Approve snapshots what was just saved")
        if case .opened = result { Issue.record("nothing here can open a pull request") }
        #expect(job.state == .awaitingReview)
        #expect(job.notice != nil)
        #expect(await scene.originTip(job.branch) == .absent, "nothing was pushed")
    }

    @Test("overlapping refreshes take at most one follow-up snapshot, and none fails")
    func coalescedRefreshes() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)

        let center = scene.center
        let refreshes = (0..<3).map { _ in Task { await center.refreshReview(job) } }
        for refresh in refreshes { await refresh.value }

        let taken = center.snapshotCounts[job.id] ?? 0
        #expect((1...2).contains(taken), "\(taken) snapshots for three overlapping refreshes")
        #expect(job.review != nil)
        #expect(job.notice == nil)
        #expect(!job.log.contains { entry in
            if case .error = entry.role { return true }
            return false
        })
        #expect(scene.patch(of: job).contains("+B"))
    }

    @Test("a second Approve while the first is answered does nothing")
    func approveOnce() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)

        // Editors that take a moment to save, as real ones may.
        let center = scene.center
        center.flushEdits = { _ in try? await Task.sleep(for: .milliseconds(200)) }
        let first = Task { await center.approve(job) }
        let second = Task { await center.approve(job) }
        let results = [await first.value, await second.value]
        #expect(results.contains(.refused("The pull request is already being opened.")))
        #expect(job.state == .awaitingReview)
    }

    @Test("a job never reviewed is shown its diff before anything is sent")
    func approveUnreviewed() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        #expect(job.review == nil)

        #expect(await scene.center.approve(job) == .changedSinceReview)
        #expect(job.review != nil)
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(tone: .warning, text: JobCenter.changedSinceReview))
    }

    // MARK: Leaving review

    @Test("Discard removes the worktree and the local branch, and keeps the record and patch")
    func discard() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)

        await scene.center.discard(job)
        #expect(job.state == .discarded)
        #expect(!FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)))
        #expect(await scene.git.resolveCommit("refs/heads/fix/page", in: scene.clone.root) == nil)
        let record = try JSONDecoder().decode(JobRecord.self, from: Data(contentsOf: job.recordFile))
        #expect(record.state == .discarded)
        #expect(scene.patch(of: job).contains("+B"), "the patch stays until Clear Finished")

        // Discard is the way out of review only.
        await scene.center.discard(job)
        #expect(job.state == .discarded)
    }

    @Test("closing an untouched edit leaves nothing behind; a touched one stays")
    func discardIfUntouched() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let untouched = try await scene.beginEdit()
        let touched = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: touched)

        await scene.center.discardIfUntouched(untouched)
        #expect(scene.center.job(id: untouched.id) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: untouched.worktree.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: untouched.recordFile.path(percentEncoded: false)))
        #expect(await scene.git.resolveCommit("refs/heads/\(untouched.branch)", in: scene.clone.root)
            == nil)

        // Judged on the worktree, not on a snapshot it never had.
        #expect(touched.review == nil)
        await scene.center.discardIfUntouched(touched)
        #expect(scene.center.job(id: touched.id) === touched)
        #expect(touched.state == .awaitingReview)
        #expect(try scene.read("content/page.md", in: touched) == "a\nB\nc")
    }

    @Test("Restore makes the worktree again from the saved patch, and it is never a stray")
    func restore() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        try scene.write("content/References/A - B & é.md", "new\n", in: job)
        await scene.center.refreshReview(job)
        let reviewed = try Data(contentsOf: job.patchFile)
        #expect(!reviewed.isEmpty)

        // Caches cleared by hand, then a relaunch.
        try FileManager.default.removeItem(at: job.worktree)
        let center = scene.relaunched()
        let restored = try #require(center.job(id: job.id))
        #expect(restored.state == .awaitingReview && restored.needsRestore && !restored.canEdit)
        #expect(!restored.isUntouchedEdit, "its saved patch has changes")
        #expect(center.reviewCount == 1)

        #expect(await center.restoreWorktree(restored))
        #expect(!restored.needsRestore && restored.canEdit)
        #expect(try scene.read("content/page.md", in: restored) == "a\nB\nc")
        #expect(try scene.read("content/References/A - B & é.md", in: restored) == "new\n")
        #expect(try Data(contentsOf: restored.patchFile) == reviewed, "byte for byte")
        #expect(!(await center.restoreWorktree(restored)), "a worktree that is there is not restored")

        await center.refreshOrphanedWorktrees()
        #expect(!center.orphanedWorktrees.contains { $0.hasSuffix(restored.id) })
    }

    // MARK: Corrections, with a claude that is a shell script

    static let readyForReview = #"""
        echo '{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet","cwd":"worktree"}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"READY FOR REVIEW","num_turns":3,"total_cost_usd":0.02,"session_id":"s1"}'
        """#

    static func request(_ scene: JobScene, model: String = "sonnet") -> CorrectionRequest {
        CorrectionRequest(
            target: scene.correctionTarget(), description: "b should be B.", model: model)
    }

    @Test("a correction runs sealed, with its model and the file tools, and waits for review")
    func correction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            printf '%s\0' "$@" > "$GH_CONFIG_DIR/../arguments"
            env > "$GH_CONFIG_DIR/../environment"
            printf 'a\nB\nc' > content/page.md
            mkdir -p .ccwiki
            printf '# [fix] Page: B\n\nCapitalised b, as the reader asked.\n' > .ccwiki/pull-request.md
            printf 'lint ok\n' > .ccwiki/lint.log
            """# + "\n" + Self.readyForReview, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(Self.request(scene))
        #expect(scene.center.jobs.first === job)
        await job.task?.value

        #expect(job.state == .awaitingReview, "\(job.state)")
        #expect(job.baseCommit == scene.base)
        #expect(job.branch == "fix/page")
        #expect(job.id.contains("-correction-page"))
        #expect(job.outcome?.turns == 3)
        #expect(job.log.contains { $0.text == "READY FOR REVIEW" })
        #expect(job.notice == nil, "the tripwire found nothing: \(job.notice?.text ?? "")")

        let arguments = try Data(contentsOf: job.scratch.appending(path: "arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        #expect(value("--model") == "sonnet")
        #expect(value("--allowedTools") == "Read,Edit,Write,Glob,Grep")
        #expect(value("--max-turns") == "20")
        #expect(value("-p")?.contains("content/page.md") == true)

        let environment = String(decoding: try Data(contentsOf: job.scratch
            .appending(path: "environment")), as: UTF8.self)
        #expect(environment.contains("=ccwiki-review-first://blocked"), "the push URL is sealed")
        #expect(environment.contains(
            "GH_CONFIG_DIR=" + job.scratch.appending(path: "gh").path(percentEncoded: false)))
        #expect(!environment.contains("GH_TOKEN="))

        // The review was taken as the job entered it; .ccwiki/ is never in it.
        let patch = scene.patch(of: job)
        #expect(patch.contains("+B"))
        #expect(!patch.contains(".ccwiki"))
        #expect(scene.center.snapshotCounts[job.id] == 1)
    }

    @Test("an abort is aborted, with its worktree kept")
    func correctionAborts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ABORTED: the page is right; b is a variable.","num_turns":1}'
            """#, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(Self.request(scene, model: ""))
        await job.task?.value
        #expect(job.state == .aborted(reason: "ABORTED: the page is right; b is a variable."))
        #expect(FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)))
        #expect(job.canRunAgain)
    }

    @Test("an agent that changed nothing fails, and its worktree and branch go")
    func correctionChangesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(Self.readyForReview, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(Self.request(scene))
        await job.task?.value
        #expect(job.state == .failed(AgentRun.nothingChanged))
        #expect(!FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)))
        #expect(await scene.git.resolveCommit("refs/heads/fix/page", in: scene.clone.root) == nil)
    }

    @Test("the tripwire names a push the agent made itself, and the job still waits for review")
    func tripwireCatchesAPush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let git = ToolLocator.locate(.git, override: nil) else { return }
        // A determined agent: it commits, and pushes to GitHub by URL, which
        // the seal does not stop and the deny-list would not see in a script.
        let root = JobScene.newRoot()
        let origin = root.appending(path: "origin.git").path(percentEncoded: false)
        let tools = try JobScene.fakeClaude("""
            printf 'a\\nB\\nc' > content/page.md
            '\(git)' -c user.name=Agent -c user.email=agent@ccwiki.invalid \\
                -c commit.gpgsign=false commit -q --no-verify -a -m agent
            '\(git)' push -q --no-verify '\(origin)' HEAD:refs/heads/fix/page
            """ + "\n" + Self.readyForReview, in: directory)
        guard let scene = try await JobScene.make(root: root, tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(Self.request(scene))
        await job.task?.value
        guard case .at = await scene.originTip("fix/page") else {
            Issue.record("the stand-in agent could not push; nothing for the tripwire to find")
            return
        }
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(
            tone: .warning, text: "The agent pushed fix/page itself, bypassing review."))
    }

    @Test("Review Anyway takes a failed agent's changes to review",
          .disabled("needs Track A: an empty snapshot until ReviewSnapshot.assemble lands"))
    func reviewAnyway() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            printf 'a\nB\nc' > content/page.md
            echo '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"","num_turns":20}'
            """#, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        let job = scene.center.startCorrection(Self.request(scene))
        await job.task?.value
        #expect(job.state == .failed("The agent reported an error (error_max_turns)."))

        await scene.center.reviewAnyway(job)
        #expect(job.state == .awaitingReview)
        #expect(job.review?.files.map(\.path) == ["content/page.md"])
        #expect(job.pullRequest.title.hasPrefix("[fix] Page"))
    }
}
