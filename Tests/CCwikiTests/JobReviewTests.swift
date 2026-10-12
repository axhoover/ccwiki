import Foundation
import Testing
@testable import CCwiki

/// What the review and the editor say and allow (plans/corrections.md §6.5,
/// §6.6, §7): the banner, Open Draft PR's gate and its question, Discard's
/// question per kind, the files Edit… offers, and when Review Anyway and an
/// issue are offered.
struct JobReviewTests {

    // MARK: Fixtures

    static let target = CorrectionTarget(
        pagePath: "Primitives/pseudorandom-function.md", pageTitle: "Pseudorandom function",
        baseCommit: "865206d47c53",
        section: CorrectionTarget.Section(id: "security", title: "Security", level: 2),
        lines: LineRange(first: 42, last: 44), region: .body,
        quote: "for every PPT $\\calA$", excerpt: "For every PPT $\\calA$,")

    static let pagePath = "content/Primitives/pseudorandom-function.md"

    static let submission = IngestSubmission(
        kind: .url, source: .eprint(year: "2025", number: "375"), localPDF: nil,
        notes: "", submittedAt: Date(timeIntervalSinceReferenceDate: 780_652_800))

    static let release = PublishTarget(
        repository: "axhoover/cryptology.city", pushURL: "origin",
        isDevBuild: false, isOverridden: false)
    static let dev = PublishTarget(
        repository: "axhoover/cryptology.city", pushURL: "origin",
        isDevBuild: true, isOverridden: false)

    static func changed(
        _ path: String, status: ChangedFile.Status = .modified, isBinary: Bool = false,
        hunks: [LineHunk] = [LineHunk(old: 9..<10, new: 9..<11)]
    ) -> ChangedFile {
        ChangedFile(
            path: path, oldPath: nil, status: status, isBinary: isBinary,
            oldText: "", newText: "", hunks: hunks)
    }

    static func snapshot(_ files: ChangedFile...) -> ReviewSnapshot {
        ReviewSnapshot(baseCommit: "865206d47c53", files: files, digest: "0123")
    }

    static func finding(_ severity: DiffFinding.Severity, rule: DiffFinding.Rule = .largeEdit) -> DiffFinding {
        DiffFinding(
            rule: rule, severity: severity, path: pagePath,
            lines: LineRange(first: 42, last: 44), message: "A message.")
    }

    /// The gate for a job awaiting review with one changed page, all else
    /// as given.
    static func gate(
        state: JobState = .awaitingReview, needsRestore: Bool = false,
        review: ReviewSnapshot? = JobReviewTests.snapshot(JobReviewTests.changed(JobReviewTests.pagePath)),
        findings: [DiffFinding] = [],
        title: String = "[fix] Pseudorandom function: Security", privateFindings: [String] = [],
        access: GitHubAccess? = .ready, target: PublishTarget = JobReviewTests.release
    ) -> JobReview.DraftPR {
        JobReview.draftPR(
            state: state, needsRestore: needsRestore, review: review, findings: findings,
            title: title, privateFindings: privateFindings, access: access, target: target)
    }

    // MARK: The banner

    @Test("the banner says what the review waits for, and what is already on GitHub")
    func banner() {
        func banner(
            _ state: JobState = .awaitingReview, restore: Bool = false, untouched: Bool = false,
            pushed: String? = nil
        ) -> String {
            JobReview.banner(
                state: state, needsRestore: restore, isUntouchedEdit: untouched,
                pushedCommit: pushed, branch: "fix/pseudorandom-function")
        }
        #expect(banner() == "Awaiting your review. Nothing has been pushed.")
        #expect(banner(pushed: "abc123") == "Awaiting your review. The branch "
            + "fix/pseudorandom-function is on GitHub; no pull request is open yet.")
        #expect(banner(restore: true) == "The worktree is gone. CCwiki kept your changes.")
        #expect(banner(.publishing("Pushing fix/pseudorandom-function…"))
            == "Pushing fix/pseudorandom-function…")
        #expect(banner(untouched: true) == "Editing. Nothing has been pushed.")
    }

    @Test("the banner's second line is the branch, then the page and passage, or the paper")
    func metadata() {
        #expect(JobReview.metadata(kind: .edit(Self.target), branch: "fix/pseudorandom-function")
            == "fix/pseudorandom-function · content/Primitives/pseudorandom-function.md"
            + " · Lines 42–44, in “Security”")
        #expect(JobReview.metadata(kind: .ingestion(Self.submission), branch: "ingest/eprint-2025-375")
            == "ingest/eprint-2025-375 · https://eprint.iacr.org/2025/375")
    }

    // MARK: Open Draft PR

    @Test("Open Draft PR runs at once for a clean review in the release")
    func cleanRelease() {
        let gate = Self.gate()
        #expect(gate.isEnabled)
        #expect(gate.confirmation == nil)
    }

    @Test("a blocking finding, a local path in the text, or GitHub not ready disables it, saying why")
    func disabled() {
        #expect(Self.gate(findings: [Self.finding(.blocking)]).disabledReason
            == "DiffGuard blocks one change. Revert it, or make it outside CCwiki.")
        #expect(Self.gate(findings: [Self.finding(.blocking), Self.finding(.blocking, rule: .binaryFile)])
            .disabledReason == "DiffGuard blocks 2 changes. Revert them, or make them outside CCwiki.")
        #expect(Self.gate(privateFindings: ["/Users/alice"]).disabledReason?
            .contains("/Users/alice") == true)
        #expect(Self.gate(access: .offline).disabledReason == GitHubAccess.offline.banner)
        #expect(Self.gate(access: .cannotPush(repository: "axhoover/cryptology.city")).disabledReason
            == GitHubAccess.cannotPush(repository: "axhoover/cryptology.city").banner)
        #expect(Self.gate(access: nil).disabledReason
            == "CCwiki is checking whether GitHub can be reached.")
        #expect(Self.gate(title: "  ").disabledReason == "The pull request needs a title.")
    }

    @Test("nothing to open, a restore pending, or a publish under way disables it too")
    func notReady() {
        #expect(Self.gate(review: nil).isEnabled == false)
        #expect(Self.gate(review: Self.snapshot()).disabledReason == "There are no changes to open yet.")
        #expect(Self.gate(needsRestore: true).disabledReason == "Restore the worktree first.")
        #expect(Self.gate(state: .publishing("Checking…")).disabledReason
            == "CCwiki is opening the pull request.")
        #expect(Self.gate(state: .opened(url: URL(string: "https://github.com/x/y/pull/1")!))
            .isEnabled == false)
    }

    @Test("a blocking finding is named before GitHub, which is only asked about last")
    func reasonsInOrder() {
        let gate = Self.gate(findings: [Self.finding(.blocking)], access: .offline)
        #expect(gate.disabledReason?.hasPrefix("DiffGuard blocks") == true)
    }

    @Test("warnings ask first, counting the flagged changes")
    func warnings() {
        let one = Self.gate(findings: [Self.finding(.warning), Self.finding(.note)])
        #expect(one.isEnabled)
        #expect(one.confirmation == JobReview.Question(
            title: "Open a draft pull request with 1 flagged change?",
            message: "It opens on axhoover/cryptology.city."))
        let two = Self.gate(
            findings: [Self.finding(.warning), Self.finding(.warning, rule: .rawHTML)], target: Self.dev)
        #expect(two.confirmation == JobReview.Question(
            title: "Open a draft pull request with 2 flagged changes?",
            message: "on axhoover/cryptology.city · from CCwiki Dev"))
    }

    @Test("a Dev build always asks, naming the repository; a note alone never asks")
    func devBuild() {
        #expect(Self.gate(target: Self.dev).confirmation == JobReview.Question(
            title: "Open a draft pull request on axhoover/cryptology.city?",
            message: "on axhoover/cryptology.city · from CCwiki Dev"))
        #expect(Self.gate(findings: [Self.finding(.note)]).confirmation == nil)
    }

    @Test("the footer line names where the pull request goes, and the Dev build")
    func destination() {
        #expect(JobReview.destination(Self.release)
            == "Opens a draft pull request on axhoover/cryptology.city")
        #expect(JobReview.destination(Self.dev)
            == "Opens a draft pull request on axhoover/cryptology.city · from CCwiki Dev")
        let fork = PublishTarget(
            repository: "someone/cryptology.city", pushURL: "https://github.com/someone/cryptology.city.git",
            isDevBuild: true, isOverridden: true)
        #expect(JobReview.destination(fork).contains("on someone/cryptology.city"))
    }

    // MARK: Questions

    @Test("Discard asks per kind, and says what CCwiki leaves on GitHub")
    func discard() {
        let correction = JobReview.discardQuestion(
            kind: .correction, branch: "fix/x", isPushed: false, openPullRequest: nil)
        #expect(correction == JobReview.Question(
            title: "Discard this correction?",
            message: "Its worktree and changes are deleted. The transcript is kept."))
        let edit = JobReview.discardQuestion(
            kind: .edit, branch: "fix/x", isPushed: false, openPullRequest: nil)
        #expect(edit == JobReview.Question(title: "Discard this edit?", message: "Your changes are deleted."))
        let ingestion = JobReview.discardQuestion(
            kind: .ingestion, branch: "ingest/x", isPushed: false, openPullRequest: nil)
        #expect(ingestion.title == "Discard this ingestion?")

        let url = URL(string: "https://github.com/axhoover/cryptology.city/pull/12")!
        let pushed = JobReview.discardQuestion(
            kind: .edit, branch: "fix/x", isPushed: true, openPullRequest: url)
        #expect(pushed.message == "Your changes are deleted. The branch fix/x is already on "
            + "GitHub; CCwiki leaves it there. An open pull request exists: "
            + "https://github.com/axhoover/cryptology.city/pull/12. CCwiki leaves it open.")
    }

    @Test("Revert File names the file, and says a new file is deleted")
    func revert() {
        #expect(JobReview.revertQuestion(path: Self.pagePath, isNew: false) == JobReview.Question(
            title: "Revert pseudorandom-function.md to the version the job started from?",
            message: "The changes this job made to it are deleted."))
        #expect(JobReview.revertQuestion(path: "content/References/A - B.md", isNew: true).message
            == "The job added this file, so reverting deletes it.")
    }

    // MARK: Edit…

    @Test("Edit… offers the page at its passage first, then the other changed files")
    func editableFiles() {
        let review = Self.snapshot(
            Self.changed("content/References/GGM86.md", status: .added,
                         hunks: [LineHunk(old: 0..<0, new: 0..<12)]),
            Self.changed(Self.pagePath),
            Self.changed("content/Primitives/old.md", status: .deleted),
            Self.changed("content/papers/x.pdf", isBinary: true))
        let files = JobReview.editableFiles(kind: .correction(CorrectionRequest(
            target: Self.target, description: "Fix it.", model: "")), review: review)
        #expect(files.map(\.path) == [Self.pagePath, "content/References/GGM86.md"])
        #expect(files[0].lines == LineRange(first: 42, last: 44))
        #expect(files[1].lines == LineRange(first: 1, last: 12))
        #expect(files[1].title == "References/GGM86.md")
    }

    @Test("an untouched edit offers its page; an ingestion only what it changed")
    func editableWithoutReview() {
        #expect(JobReview.editableFiles(kind: .edit(Self.target), review: nil).map(\.path)
            == [Self.pagePath])
        #expect(JobReview.editableFiles(kind: .ingestion(Self.submission), review: nil).isEmpty)
        // A page the change deletes is not offered.
        let deleted = Self.snapshot(Self.changed(Self.pagePath, status: .deleted))
        #expect(JobReview.editableFiles(kind: .edit(Self.target), review: deleted).isEmpty)
    }

    @Test("a file's first change: the lines a hunk adds, or the line a removal leaves")
    func firstChange() {
        #expect(JobReview.firstChange(in: Self.changed(Self.pagePath))
            == LineRange(first: 10, last: 11))
        #expect(JobReview.firstChange(in: Self.changed(
            Self.pagePath, hunks: [LineHunk(old: 4..<6, new: 4..<4)])) == LineRange(first: 5, last: 5))
        #expect(JobReview.firstChange(in: Self.changed(Self.pagePath, hunks: [])) == nil)
    }

    // MARK: What is offered

    @Test("Review Anyway: an agent job that ended, with its worktree and maybe changes")
    func reviewAnyway() {
        func offers(
            _ kind: JobKind.Tag = .correction, _ state: JobState = .failed("Out of turns."),
            worktree: Bool = true, review: ReviewSnapshot? = nil
        ) -> Bool {
            JobReview.offersReviewAnyway(kind: kind, state: state, worktreeExists: worktree, review: review)
        }
        #expect(offers())
        #expect(offers(.ingestion, .aborted(reason: "No such paper.")))
        #expect(offers(.correction, .cancelled))
        #expect(!offers(.edit))
        #expect(!offers(worktree: false))
        #expect(!offers(.correction, .awaitingReview))
        #expect(!offers(review: Self.snapshot()))
        #expect(offers(review: Self.snapshot(Self.changed(Self.pagePath))))
    }

    @Test("an issue is offered when gh is missing or cannot push, and never otherwise")
    func issue() {
        #expect(JobReview.offersIssue(for: .ghMissing))
        #expect(JobReview.offersIssue(for: .cannotPush(repository: "axhoover/cryptology.city")))
        #expect(!JobReview.offersIssue(for: .offline))
        #expect(!JobReview.offersIssue(for: .notSignedIn))
        #expect(!JobReview.offersIssue(for: .ready))
    }

    // MARK: Words

    @Test("the diff's summary counts files and lines; a finding says where it is")
    func words() {
        let review = Self.snapshot(
            Self.changed(Self.pagePath),
            Self.changed("content/References/GGM86.md", status: .added,
                         hunks: [LineHunk(old: 0..<0, new: 0..<12)]))
        #expect(JobReview.changeSummary(review) == "2 files changed · +14 \u{2212}1")
        #expect(JobReview.changeSummary(Self.snapshot(Self.changed(Self.pagePath)))
            == "1 file changed · +2 \u{2212}1")
        #expect(JobReview.location(of: Self.finding(.warning))
            == "content/Primitives/pseudorandom-function.md · lines 42–44")
    }

    @Test("a finding's inline code is read as Markdown, and plain text stays as it is")
    func inlineMarkdown() {
        let message = "Revert `scripts/lint.mjs`, or make this change outside CCwiki."
        #expect(String(JobReview.inlineMarkdown(message).characters)
            == "Revert scripts/lint.mjs, or make this change outside CCwiki.")
        #expect(String(JobReview.inlineMarkdown("Lines 42–44 [unclosed").characters)
            == "Lines 42–44 [unclosed")
    }
}
