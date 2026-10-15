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
    /// (`root/origin.git`) before it makes it. A real path: `git worktree
    /// list` reports real paths, and macOS's temporary directory is under
    /// `/var`, a symbolic link to `/private/var`, so a path through it would
    /// never be the one git lists, and a test of what git lists could pass
    /// for the wrong reason.
    nonisolated static func newRoot() -> URL {
        let temporary = GitService.realPath(
            FileManager.default.temporaryDirectory.path(percentEncoded: false))
        return URL(fileURLWithPath: temporary, isDirectory: true)
            .appending(path: "ccwiki-review-\(UUID().uuidString)")
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
        try fakeTools([.claude: body], in: directory)
    }

    /// Each tool a `/bin/sh` script in `directory` that runs its body: a
    /// `claude` in the job's worktree, a `gh` wherever CCwiki runs it. None
    /// reaches the network.
    static func fakeTools(_ bodies: [ToolLocator.Tool: String], in directory: URL) throws
        -> ToolLocator {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var overrides: [ToolLocator.Tool: String] = [:]
        for (tool, body) in bodies {
            let file = directory.appending(path: tool.rawValue)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
            overrides[tool] = file.path(percentEncoded: false)
        }
        var tools = ToolLocator(overrides: overrides)
        tools.locate(Array(bodies.keys))
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

    @Test("Approve pressed while a snapshot is under way approves only what was on screen")
    func approveDuringSnapshot() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)

        // The first snapshot of a job just shown, still being taken when
        // Open Draft PR is pressed: no diff is on screen yet.
        let center = scene.center
        let refresh = Task { await center.refreshReview(job) }
        var waited = 0
        while center.snapshotCounts[job.id] == nil, waited < 10_000 {
            await Task.yield()
            waited += 1
        }
        try #require(center.snapshotCounts[job.id] == 1 && job.review == nil,
                     "the snapshot was not under way when Approve was pressed")

        let result = await center.approve(job)
        await refresh.value
        #expect(result == .changedSinceReview, "\(result)")
        #expect(job.review != nil, "the review now shows the diff")
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(tone: .warning, text: JobCenter.changedSinceReview))
        #expect(await scene.originTip(job.branch) == .absent, "nothing was pushed")
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

    @Test("Approve stops for an editor that could not save, asked once the editors have saved")
    func approveWithAnUnsettledEditor() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)

        // The save Approve runs is the one that fails, so no button could
        // have known: only the job center, asking after it.
        let editor = EditorStandIn()
        let reason = JobReview.unsettledReason(path: "content/page.md")
        scene.center.flushEdits = { job in await editor.flush(job) }
        scene.center.unsettledEdits = { _ in editor.flushes > 0 ? reason : nil }

        let result = await scene.center.approve(job)
        #expect(result == .refused(reason), "\(result)")
        #expect(editor.flushes == 1)
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(tone: .warning, text: reason))
        #expect(reason == "page.md could not be saved. Settle it in its window first.")
        #expect(await scene.originTip(job.branch) == .absent, "nothing was pushed")
    }

    // MARK: Tools found late

    @Test("a review shown before the tools were found gets its snapshot, and GitHub is asked again")
    func toolsFoundLate() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)

        // A window restored at launch, before git or gh is found.
        let center = scene.center
        let found = center.environment
        let target = scene.target
        center.environment = {
            JobCenter.Environment(
                tools: ToolLocator(), git: nil, index: nil, relations: .empty, labels: .empty,
                appVersion: "0.3.0", correctionModel: "sonnet", target: target, privatePaths: [])
        }
        await center.toolsDidChange()
        #expect(center.gitHubAccess == nil, "nobody asked, so nothing is asked again")
        await center.refreshReview(job)
        #expect(job.review == nil, "no git, no snapshot")
        await center.refreshGitHubAccess()
        #expect(center.gitHubAccess == .ghMissing)

        // git is found: the review gets its snapshot.
        center.environment = found
        await center.refreshMissingReviews()
        #expect(job.review?.files.map(\.path) == ["content/page.md"])

        // Then gh, here one that cannot reach GitHub: the answer kept from
        // before it was found is replaced.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gh = directory.appending(path: "gh")
        try Data("#!/bin/sh\necho 'error connecting to api.github.com' >&2\nexit 1\n".utf8)
            .write(to: gh)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: gh.path(percentEncoded: false))
        var located = ToolLocator(overrides: [.gh: gh.path(percentEncoded: false)])
        located.locate([.gh])
        let tools = located
        let git = scene.git
        center.environment = {
            JobCenter.Environment(
                tools: tools, git: git, index: nil, relations: .empty, labels: .empty,
                appVersion: "0.3.0", correctionModel: "sonnet", target: target, privatePaths: [])
        }
        await center.toolsDidChange()
        #expect(center.gitHubAccess == .offline, "asked again, of the gh now found")
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

    @Test("an edit that has pushed, or tried to, is never discarded on close")
    func discardIfUntouchedAfterAPush() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        // Approve pushed the branch and gh then failed, or the reply to the
        // push was lost; the maintainer reverted everything and closed the
        // editor. The branch may be on GitHub, and only the record says so.
        let pushed = try await scene.beginEdit()
        pushed.setPushedCommit(scene.base)
        let pushing = try await scene.beginEdit()
        pushing.setPushingCommit(scene.base)

        for job in [pushed, pushing] {
            await scene.center.discardIfUntouched(job)
            #expect(scene.center.job(id: job.id) === job)
            #expect(job.state == .awaitingReview)
            #expect(FileManager.default.fileExists(atPath: job.recordFile.path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)))
        }
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
        #expect(!FileManager.default.fileExists(atPath: JobCenter.restoringWorktree(
            scratch: restored.scratch).path(percentEncoded: false)), "nothing is left aside")

        await center.refreshOrphanedWorktrees()
        #expect(!center.orphanedWorktrees.contains { $0.hasSuffix(restored.id) })

        // And the check can fail: a worktree no job owns is listed.
        let stray = scene.paths.worktree(forJob: "20261012-120000-000-edit-stray")
        let added = await scene.git.addWorktree(
            clone: scene.paths.clone, at: stray, branch: "stray", baseRef: scene.base,
            onLine: { _ in })
        try #require(added)
        await center.refreshOrphanedWorktrees()
        #expect(center.orphanedWorktrees.contains { $0.hasSuffix("/" + stray.lastPathComponent) })
        #expect(!center.orphanedWorktrees.contains { $0.hasSuffix(restored.id) })
    }

    @Test("a Restore cut short leaves no worktree where the job looks, so it runs again")
    func restoreInterrupted() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        let reviewed = try Data(contentsOf: job.patchFile)
        try FileManager.default.removeItem(at: job.worktree)

        // What a quit in the middle of Restore leaves: the worktree made and
        // the patch applied, aside, on the job's branch, not yet moved.
        let staging = JobCenter.restoringWorktree(scratch: job.scratch)
        let base = try #require(job.baseCommit)
        try #require(await scene.git.addWorktree(
            clone: scene.paths.clone, at: staging, resettingBranch: job.branch, to: base))
        try #require(await scene.git.applyPatch(job.patchFile, in: staging))

        let center = scene.relaunched()
        let restored = try #require(center.job(id: job.id))
        #expect(restored.needsRestore, "the next launch offers Restore again")

        #expect(await center.restoreWorktree(restored))
        #expect(!restored.needsRestore && restored.notice == nil)
        #expect(try scene.read("content/page.md", in: restored) == "a\nB\nc")
        #expect(try Data(contentsOf: restored.patchFile) == reviewed, "byte for byte")
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
        let head = await scene.git.resolveCommit("HEAD", in: restored.worktree)
        #expect(head == base)
    }

    @Test("Restore whose saved changes have gone says so, and makes no worktree")
    func restoreWithoutThePatch() async throws {
        guard let scene = try await JobScene.make() else { return }
        defer { scene.delete() }
        let job = try await scene.beginEdit()
        try scene.write("content/page.md", "a\nB\nc", in: job)
        await scene.center.refreshReview(job)
        try FileManager.default.removeItem(at: job.worktree)

        let center = scene.relaunched()
        let restored = try #require(center.job(id: job.id))
        try #require(restored.needsRestore)
        // Deleted by hand since the launch.
        try FileManager.default.removeItem(at: restored.patchFile)

        #expect(!(await center.restoreWorktree(restored)))
        #expect(restored.needsRestore)
        #expect(restored.notice == JobNotice(tone: .failure, text:
            "The saved changes are missing: \(restored.patchFile.lastPathComponent) is not in "
            + "Application Support."))
        #expect(!restored.log.contains { $0.text.hasPrefix("Restoring the worktree") },
                "git was not asked")
        #expect(!FileManager.default.fileExists(atPath: JobCenter.restoringWorktree(
            scratch: restored.scratch).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: restored.worktree.path(percentEncoded: false)))
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
        #expect(value("--setting-sources") == "project")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(value("-p")?.contains("content/page.md") == true)

        let environment = String(decoding: try Data(contentsOf: job.scratch
            .appending(path: "environment")), as: UTF8.self)
        #expect(environment.contains("=ccwiki-review-first://blocked"), "the push URL is sealed")
        #expect(environment.contains(
            "GH_CONFIG_DIR=" + job.scratch.appending(path: "gh").path(percentEncoded: false)))
        #expect(!environment.contains("GH_TOKEN="))

        // .ccwiki/ was there before the agent started: it has no mkdir, and a
        // shell redirect does not make the directory.
        #expect(Handover.pullRequestText(in: job.worktree) != nil)
        #expect(FileManager.default.fileExists(atPath: job.worktree
            .appending(path: ".ccwiki/lint.log").path(percentEncoded: false)))

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

    /// A determined agent: it commits, and pushes `fix/page` to the
    /// scene's origin by URL, which the seal does not stop and the
    /// deny-list would not see in a script.
    static func agentThatPushes(git: String, origin: String) -> String {
        """
        printf 'a\\nB\\nc' > content/page.md
        '\(git)' -c user.name=Agent -c user.email=agent@ccwiki.invalid \\
            -c commit.gpgsign=false commit -q --no-verify -a -m agent
        '\(git)' push -q --no-verify '\(origin)' HEAD:refs/heads/fix/page
        """ + "\n" + readyForReview
    }

    @Test("the tripwire names a push the agent made itself, and the job still waits for review")
    func tripwireCatchesAPush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let git = ToolLocator.locate(.git, override: nil) else { return }
        let root = JobScene.newRoot()
        let origin = root.appending(path: "origin.git").path(percentEncoded: false)
        let tools = try JobScene.fakeClaude(
            Self.agentThatPushes(git: git, origin: origin), in: directory)
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
        // The transcript says what CCwiki did, which the notice does not
        // contradict: the push was the agent's.
        #expect(job.log.contains {
            $0.text.hasPrefix("Awaiting review in Jobs. CCwiki has pushed nothing")
        })
        #expect(!job.log.contains { $0.text.contains("Nothing has been pushed") })
    }

    @Test("the tripwire names the agent's push of a branch name an earlier job left free")
    func tripwireWithAReusedBranch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let git = ToolLocator.locate(.git, override: nil) else { return }
        let root = JobScene.newRoot()
        let origin = root.appending(path: "origin.git").path(percentEncoded: false)
        let tools = try JobScene.fakeClaude(
            Self.agentThatPushes(git: git, origin: origin), in: directory)
        guard let scene = try await JobScene.make(root: root, tools: tools) else { return }
        defer { scene.delete() }

        // An earlier correction of the page that changed nothing: its local
        // branch went with its worktree, and its record, naming fix/page,
        // stays. Run Again takes the same name.
        try JobRecordTests.write(JobRecordTests.record(
            "20261001-090000-000-correction-page", kind: .correction(Self.request(scene)),
            state: .failed(AgentRun.nothingChanged)), in: scene.paths)

        let job = scene.center.startCorrection(Self.request(scene))
        await job.task?.value
        #expect(job.branch == "fix/page")
        guard case .at = await scene.originTip("fix/page") else {
            Issue.record("the stand-in agent could not push; nothing for the tripwire to find")
            return
        }
        #expect(job.state == .awaitingReview)
        #expect(job.notice == JobNotice(
            tone: .warning, text: "The agent pushed fix/page itself, bypassing review."))
    }

    /// A correction whose agent changes b to B, run while GitHub lists one
    /// open pull request by the signed-in account, from `head`, opened
    /// twenty seconds before the job: inside the tripwire's minute of
    /// look-back. The `gh` answers nothing else. Returns when the job has
    /// settled, with when the pull request was opened.
    static func correction(
        whileListing head: String, isCrossRepository: Bool = false, number: Int
    ) async throws -> (JobScene, Job, Date)? {
        let root = JobScene.newRoot()
        let opened = Date().addingTimeInterval(-20)
        let created = ISO8601DateFormatter().string(from: opened)
        let tools = try JobScene.fakeTools([
            .claude: #"printf 'a\nB\nc' > content/page.md"# + "\n" + readyForReview,
            .gh: """
                case "$1 $2" in
                "pr list")
                    echo '\(created) \(isCrossRepository) \(head) \(TripwireTests.url(number).absoluteString)' ;;
                *) echo 'error connecting to api.github.com' >&2; exit 1 ;;
                esac
                """,
        ], in: root.appending(path: "tools"))
        guard let scene = try await JobScene.make(root: root, tools: tools) else {
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        let job = scene.center.startCorrection(request(scene))
        await job.task?.value
        return (scene, job, opened)
    }

    @Test("a pull request from another branch, opened just before the job, leaves it in review with its own diff")
    func tripwireWithAnotherBranchesPullRequest() async throws {
        guard let (scene, job, opened) = try await Self.correction(
            whileListing: "manual/B", number: 53)
        else { return }
        defer { scene.delete() }
        let started = try #require(job.startedAt)
        #expect(opened < started && opened >= started.addingTimeInterval(-60),
                "the premise: opened in the minute before the job started")

        #expect(job.state == .awaitingReview, "\(job.state)")
        #expect(job.notice?.tone == .warning)
        #expect(job.notice?.text.hasPrefix("A pull request from manual/B was opened while the "
            + "agent ran, and CCwiki did not open it: "
            + "https://github.com/axhoover/cryptology.city/pull/53.") == true,
            "\(job.notice?.text ?? "no notice")")
        #expect(job.log.contains { $0.text == "Opened while the agent ran: "
            + "https://github.com/axhoover/cryptology.city/pull/53 (from manual/B)" })
        // The job's own change, from its own worktree, is what waits.
        #expect(job.review?.files.map(\.path) == ["content/page.md"])
        #expect(scene.patch(of: job).contains("+B"))
        #expect(job.log.contains {
            $0.text.hasPrefix("Awaiting review in Jobs. CCwiki has pushed nothing")
        })
    }

    @Test("a pull request from the job's branch name in another repository leaves it in review")
    func tripwireWithAForksPullRequest() async throws {
        guard let (scene, job, _) = try await Self.correction(
            whileListing: "fix/page", isCrossRepository: true, number: 54)
        else { return }
        defer { scene.delete() }
        #expect(job.branch == "fix/page")
        #expect(job.state == .awaitingReview, "\(job.state)")
        #expect(job.notice?.text.hasPrefix(
            "A pull request from fix/page in another repository was opened") == true)
        #expect(job.review?.files.map(\.path) == ["content/page.md"])
    }

    @Test("a pull request from the job's own branch opens the job, and its worktree is kept")
    func tripwireWithTheJobsOwnPullRequest() async throws {
        guard let (scene, job, _) = try await Self.correction(whileListing: "fix/page", number: 52)
        else { return }
        defer { scene.delete() }
        #expect(job.branch == "fix/page")
        #expect(job.state == .opened(url: TripwireTests.url(52)), "\(job.state)")
        #expect(job.notice == JobNotice(
            tone: .warning, text: "The agent opened this pull request itself, bypassing review."))
        #expect(FileManager.default.fileExists(atPath: job.worktree.path(percentEncoded: false)),
                "kept, for inspection")
    }

    @Test("Review Anyway is offered for every way an agent job ends but opened and discarded")
    func reviewAnywayStates() throws {
        let offered: [JobState] = [.failed("claude exited 1."), .aborted(reason: "ABORTED: no."),
                                   .cancelled]
        for state in offered {
            #expect(JobCenter.mayReviewAnyway(state), "\(state)")
        }
        let url = try #require(URL(string: "https://github.com/axhoover/cryptology.city/pull/41"))
        let refused: [JobState] = [.queued, .preparing("Fetching submodules…"), .running,
                                   .awaitingReview, .publishing("Checking…"), .opened(url: url),
                                   .discarded]
        for state in refused {
            #expect(!JobCenter.mayReviewAnyway(state), "\(state)")
        }
    }

    @Test("Review Anyway takes a failed agent's changes to review")
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

    @Test("Review Anyway takes the changes of an agent a quit or Cancel stopped to review")
    func reviewAnywayAfterCancel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ccwiki-fake-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try JobScene.fakeClaude(#"""
            printf 'a\nB\nc' > content/page.md
            sleep 30
            """#, in: directory)
        guard let scene = try await JobScene.make(tools: tools) else { return }
        defer { scene.delete() }

        // Stopped mid-run, once it has changed the page.
        let job = scene.center.startCorrection(Self.request(scene))
        let page = job.worktree.appending(path: "content/page.md")
        var waited = 0
        while (try? String(contentsOf: page, encoding: .utf8)) != "a\nB\nc", waited < 500 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        try #require(job.state == .running, "\(job.state)")
        job.cancel()
        #expect(job.state == .cancelled)

        // At once, while the runner may still be winding down: it finishes
        // first, and does not set `cancelled` again over the review.
        await scene.center.reviewAnyway(job)
        await job.task?.value
        #expect(job.state == .awaitingReview)
        #expect(job.review?.files.map(\.path) == ["content/page.md"])
    }

    @Test("a worktree Review Anyway can still take to review is never a stray, nor pruned")
    func reviewAnywayOwnsItsWorktree() async throws {
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
        try #require(JobCenter.mayReviewAnyway(job.state), "\(job.state)")
        let worktree = job.worktree.path(percentEncoded: false)
        try #require(FileManager.default.fileExists(atPath: worktree))
        #expect(JobCenter.ownsWorktree(job.state))
        #expect(!JobCenter.ownsWorktree(.discarded))

        await scene.center.refreshOrphanedWorktrees()
        #expect(!scene.center.orphanedWorktrees.contains { $0.hasSuffix("/" + job.id) })

        // Prune from a list drawn before the job ended does nothing.
        scene.center.pruneOrphan(worktree)
        try await Task.sleep(for: .milliseconds(300))
        #expect(FileManager.default.fileExists(atPath: worktree))

        // Once Clear Finished drops the job, nothing will take the worktree
        // to review: it is a stray.
        scene.center.clearFinishedJobs()
        await scene.center.refreshOrphanedWorktrees()
        #expect(scene.center.orphanedWorktrees.contains { $0.hasSuffix("/" + job.id) })
    }
}
