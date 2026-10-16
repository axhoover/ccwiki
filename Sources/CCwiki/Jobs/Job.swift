import Foundation
import Observation

// MARK: - State

/// Where a job is (plans/corrections.md §4.1).
///
/// ```
///                  ┌──────────── ingestion, correction ─────────────┐
///  queued → preparing(step) → running ──► awaitingReview ◄── edit starts here
///                                              │    ▲  │
///                                              │    │  └──► discarded
///                                              ▼    │
///                                        publishing(step)
///                                              │
///         failed · cancelled · aborted     opened(url)
/// ```
///
/// The case names that existed before 0.3 keep their names and labels:
/// records were written with synthesized `Codable`, which keys on them.
enum JobState: Equatable, Sendable, Codable {
    case queued
    /// Setting up: worktree, submodules.
    case preparing(String)
    /// The agent is working.
    case running
    /// Changes wait for a person: nothing has been pushed or opened.
    case awaitingReview
    /// Approved: committing, pushing, opening the pull request. The step.
    case publishing(String)
    /// Finished, with a draft PR.
    case opened(url: URL)
    /// The agent declined the job on purpose. That is a good outcome.
    case aborted(reason: String)
    case failed(String)
    case cancelled
    /// Thrown away from review. The transcript is kept.
    case discarded

    var isTerminal: Bool {
        switch self {
        case .queued, .preparing, .running, .awaitingReview, .publishing: false
        case .opened, .aborted, .failed, .cancelled, .discarded: true
        }
    }

    /// A process is running for it: an agent, or the publish.
    var isActive: Bool {
        switch self {
        case .preparing, .running, .publishing: true
        default: false
        }
    }

    /// Only work that has not reached review can be cancelled. Discard is
    /// the one way out of review, and a publish is interrupted, never
    /// cancelled (§4.1).
    var isCancellable: Bool {
        switch self {
        case .queued, .preparing, .running: true
        default: false
        }
    }

    var isPublishing: Bool {
        if case .publishing = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .preparing(let step): step
        case .running: "Running"
        case .awaitingReview: "Awaiting review"
        case .publishing(let step): step
        case .opened: "Draft PR opened"
        case .aborted: "Aborted"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .discarded: "Discarded"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .preparing, .running, .publishing: "arrow.triangle.2.circlepath"
        case .awaitingReview: "rectangle.and.text.magnifyingglass"
        case .opened: "checkmark.circle.fill"
        case .aborted: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        case .discarded: "trash"
        }
    }
}

// MARK: - Kind

/// What a job does (§4.1). An issue is not a job: its sheet is its review
/// and its result.
enum JobKind: Codable, Sendable, Equatable {
    case ingestion(IngestSubmission)
    /// Route b: described by a reader, drafted by an agent.
    case correction(CorrectionRequest)
    /// Route a: edited by hand.
    case edit(CorrectionTarget)

    enum Tag: String, Codable, Sendable {
        case ingestion, correction, edit

        /// An edit is checked as a correction is.
        var family: Family {
            self == .ingestion ? .ingestion : .correction
        }
    }

    /// Which of DiffGuard's thresholds apply.
    enum Family: Sendable {
        case ingestion, correction
    }

    var tag: Tag {
        switch self {
        case .ingestion: .ingestion
        case .correction: .correction
        case .edit: .edit
        }
    }

    var family: Family { tag.family }

    /// The page a correction or an edit is about. Nil for ingestion.
    var target: CorrectionTarget? {
        switch self {
        case .ingestion: return nil
        case .correction(let request): return request.target
        case .edit(let target): return target
        }
    }

    /// "eprint-2025-375", "pseudorandom-function": the end of the branch
    /// and of the job's id.
    var slug: String {
        switch self {
        case .ingestion(let submission): submission.slug
        case .correction(let request): BranchName.slug(WikiPage.stem(of: request.target.pagePath))
        case .edit(let target): BranchName.slug(WikiPage.stem(of: target.pagePath))
        }
    }

    var branchPrefix: String {
        switch self {
        case .ingestion: "ingest/"
        case .correction, .edit: "fix/"
        }
    }

    var symbolName: String {
        switch self {
        case .ingestion: "doc.badge.plus"
        case .correction: "text.bubble"
        case .edit: "square.and.pencil"
        }
    }

    /// For dialogs: "Discard this correction?"
    var noun: String {
        switch self {
        case .ingestion: "ingestion"
        case .correction: "correction"
        case .edit: "edit"
        }
    }
}

/// Branch and directory names.
enum BranchName {

    /// A short, filesystem- and branch-safe stem: lowercase letters, digits
    /// and single hyphens, at most 48 characters. Every kind of job names its
    /// branch and worktree with it.
    static func slug(_ base: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let cleaned = base.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { result, character in
                // Collapse runs, so `10.1145/800061.808726` does not become a
                // branch name full of empty segments.
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
        return String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
    }
}

/// What the last publish said, or what the tripwire found (§5.5), shown
/// under the review's banner.
struct JobNotice: Codable, Sendable, Equatable {
    enum Tone: String, Codable, Sendable {
        /// Orange.
        case warning
        /// Red.
        case failure
    }

    let tone: Tone
    let text: String
}

/// One push CCwiki sent, or set out to send, for a job: the commit, and
/// where it went (plans/corrections.md §6.5). Recorded, and the job's
/// record written, before the push is sent, so a push whose reply was lost
/// to a crash or a quit is recognised afterwards. Only an attempt for the
/// same repository and branch makes a tip there CCwiki's own.
struct PushAttempt: Codable, Sendable, Hashable {
    /// `PublishTarget.repository`: "axhoover/cryptology.city".
    let repository: String
    /// "fix/x", not "refs/heads/fix/x".
    let branch: String
    let commit: String
}

// MARK: - Job

/// One job: an ingestion, a correction or an edit. Its state, its
/// transcript, its worktree, and once it awaits review, the reviewed diff
/// and the pull request it would open (plans/corrections.md §4.2).
///
/// A reference type because the runner streams into it from a long-lived task
/// while the UI reads it, and `@MainActor` because the transcript is what the
/// jobs window renders.
@Observable
@MainActor
final class Job: Identifiable {

    /// "<yyyyMMdd-HHmmss-SSS>-<kind>-<slug>"; an ingestion keeps the
    /// "<stamp>-<slug>" it always had.
    let id: String
    let kind: JobKind
    let createdAt: Date
    let worktree: URL
    /// `<caches>/scratch/<id>/`: the agent's `GH_CONFIG_DIR`, outside the
    /// worktree. Removed with the worktree.
    let scratch: URL
    let logFile: URL
    /// Written on every state change, so the job comes back after a relaunch
    /// — with its PR URL, which used to be lost with the window.
    let recordFile: URL
    /// `logs/<id>.patch`: the last reviewed diff, outside Caches (§4.4).
    let patchFile: URL

    /// The branch the job works on. Settled by the runner, which may have to
    /// take the next free name if a previous attempt left one behind.
    private(set) var branch: String
    private(set) var state: JobState = .queued
    private(set) var log: [JobLogEntry] = []
    private(set) var outcome: ClaudeOutcome?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Findings from the pre-flight checks, shown before and after the run.
    private(set) var preflight: [PreflightFinding] = []
    /// The commit the worktree started from: a SHA, never a ref (§5.3).
    private(set) var baseCommit: String?
    /// The diff as last snapshotted, and what DiffGuard said about it.
    private(set) var review: ReviewSnapshot?
    private(set) var findings: [DiffFinding] = []
    /// Persisted before each push is sent, so a crash between the push and
    /// the PR is recoverable (§4.4). The next push overwrites it.
    private(set) var pushingCommit: String?
    /// Persisted once a push is confirmed.
    private(set) var pushedCommit: String?
    /// Every push CCwiki sent, or set out to send, for this job, each with
    /// the repository and the branch it went to: persisted before it is
    /// sent, and never dropped, whatever a later Approve, retry, rename or
    /// relaunch does. With `pushedCommit`, all that makes a tip on GitHub
    /// this job's own (§6.5 step 3).
    private(set) var pushAttempts: [PushAttempt] = []
    /// The last publish result, or the tripwire's finding (§5.5).
    private(set) var notice: JobNotice?
    /// Restored without its worktree: Restore applies `patchFile`.
    private(set) var needsRestore = false
    /// Edited in the review. Persisted at most once a second, and before
    /// Approve (which persists the record as it starts publishing).
    var pullRequest: PullRequestDraft {
        didSet {
            if pullRequest != oldValue { schedulePersist() }
        }
    }

    /// Set by the runner so the panel's Cancel button has something to cancel,
    /// and by Approve so a quit can interrupt the publish.
    @ObservationIgnored var task: Task<Void, Never>?
    /// The branches of every other job the job center knows of, those Clear
    /// Finished has dropped included: asked as the agent exits, for the
    /// tripwire to take for CCwiki's own (§5.5). Set by the job center as it
    /// starts the job.
    @ObservationIgnored var otherJobBranches: (@MainActor () -> Set<String>)?

    /// The raw stream, appended to as it arrives. Kept even after the worktree
    /// is pruned — a transcript you cannot re-read is not a transcript.
    @ObservationIgnored private var logWriter: LogWriter?
    /// A job from an earlier launch, whose transcript is on disk and not yet
    /// in `log`. Cleared by the first `replayTranscript()`.
    @ObservationIgnored private var needsReplay = false
    /// How much of `logFile` earlier launches wrote: what a replay reads.
    /// Anything after it was written by this launch, and is in `log`.
    @ObservationIgnored private var replayLength = 0
    /// Restored with a saved patch that is not empty: the last launch's
    /// snapshot had changes (`isUntouchedEdit`).
    @ObservationIgnored private var restoredWithChanges = false
    /// The pending write of an edited pull request, at most one a second.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    init(kind: JobKind, paths: AppPaths, createdAt: Date = Date()) {
        // A timestamp prefix keeps the jobs directory sorted and readable, and
        // keeps two jobs on the same page or paper from colliding.
        let stamp = Self.stampFormatter.string(from: createdAt)
        let id = kind.tag == .ingestion
            ? "\(stamp)-\(kind.slug)"
            : "\(stamp)-\(kind.tag.rawValue)-\(kind.slug)"
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.worktree = paths.worktree(forJob: id)
        self.scratch = paths.scratch(forJob: id)
        self.logFile = paths.log(forJob: id)
        self.recordFile = paths.record(forJob: id)
        self.patchFile = paths.patch(forJob: id)
        self.branch = kind.branchPrefix + kind.slug
        self.pullRequest = PullRequestDraft(title: "", body: "")
    }

    /// A job from an earlier launch, brought back as §4.3's table says: work
    /// that was running when the app quit is reported as failed and says so;
    /// a review comes back as a review, needing a Restore when only its
    /// saved changes are left.
    init(restoring record: JobRecord, paths: AppPaths, worktreeExists: Bool, patchExists: Bool) {
        self.id = record.id
        self.kind = record.kind
        self.createdAt = record.createdAt
        self.worktree = paths.worktree(forJob: record.id)
        self.scratch = paths.scratch(forJob: record.id)
        self.logFile = paths.log(forJob: record.id)
        self.recordFile = paths.record(forJob: record.id)
        self.patchFile = paths.patch(forJob: record.id)
        self.branch = record.branch
        self.startedAt = record.startedAt
        self.baseCommit = record.baseCommit
        self.pullRequest = record.pullRequest ?? PullRequestDraft(title: "", body: "")
        self.pushingCommit = record.pushingCommit
        self.pushedCommit = record.pushedCommit
        self.pushAttempts = record.pushAttempts
        self.notice = record.notice

        let restored = Self.restoration(
            of: record.state, worktreeExists: worktreeExists, patchExists: patchExists)
        self.state = restored.state
        self.needsRestore = restored.needsRestore
        self.finishedAt = record.finishedAt
            ?? (restored.state.isTerminal && !record.state.isTerminal ? record.startedAt : nil)

        let at = record.startedAt ?? record.createdAt
        var entries = [JobLogEntry(.system,
            "Restored from an earlier launch. The full transcript is in \(logFile.lastPathComponent).",
            at: at)]
        if let note = restored.note { entries.append(JobLogEntry(.system, note, at: at)) }
        self.log = entries
        self.needsReplay = true
        self.replayLength = Self.fileSize(logFile)
        if patchExists { self.restoredWithChanges = Self.fileSize(patchFile) > 0 }
    }

    /// Bytes, or 0 for a file that is not there.
    nonisolated private static func fileSize(_ file: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: file.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// §4.3, row by row: what a recorded state comes back as.
    nonisolated static func restoration(
        of state: JobState, worktreeExists: Bool, patchExists: Bool
    ) -> (state: JobState, needsRestore: Bool, note: String?) {
        switch state {
        case .queued, .preparing, .running:
            // A normal quit has already cancelled these; this is a crash.
            return (.failed(interruptedByQuit), false, nil)
        case .awaitingReview, .publishing:
            // A publish a crash interrupted is a review again, as one a quit
            // interrupted already is.
            let note = state.isPublishing ? publishingInterrupted : nil
            if worktreeExists { return (.awaitingReview, false, note) }
            if patchExists { return (.awaitingReview, true, note) }
            return (.failed(reviewLost), false, note)
        case .opened, .aborted, .failed, .cancelled, .discarded:
            return (state, false, nil)
        }
    }

    nonisolated static let interruptedByQuit =
        "Interrupted — CCwiki quit while this job was running."
    nonisolated static let reviewLost = "The worktree and the saved changes are both gone."
    nonisolated static let publishingInterrupted = "Publishing was interrupted. Opening the pull "
        + "request again checks GitHub first, so it cannot be opened twice."

    var record: JobRecord {
        JobRecord(
            id: id, kind: kind, branch: branch, state: state, createdAt: createdAt,
            startedAt: startedAt, finishedAt: finishedAt, baseCommit: baseCommit,
            pullRequest: pullRequest, pushingCommit: pushingCommit,
            pushedCommit: pushedCommit, pushAttempts: pushAttempts, notice: notice)
    }

    private func persist() {
        persistTask?.cancel()
        persistTask = nil
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: recordFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: recordFile, options: .atomic)
    }

    /// The record again in a second, for the pull request's title and body,
    /// which change at every keystroke. Any other persist meanwhile writes
    /// them too, and cancels this one.
    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            self.persist()
        }
    }

    /// Writes the record now, with the pull request as edited: before
    /// Approve, and when the app quits.
    func saveRecord() {
        persist()
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Milliseconds, because two submissions of the same paper within a
        // second would share a worktree path and the second would fail.
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    // MARK: What the views read

    /// The paper, or the page.
    var title: String {
        switch kind {
        case .ingestion(let submission): submission.displayName
        case .correction(let request): request.target.pageTitle
        case .edit(let target): target.pageTitle
        }
    }

    /// "Lines 42–44, in “Security”", or the paper's source.
    var detail: String {
        switch kind {
        case .ingestion(let submission):
            submission.source?.canonicalURL ?? submission.localPDF?.lastPathComponent ?? ""
        case .correction(let request): request.target.summary
        case .edit(let target): target.summary
        }
    }

    /// An edit whose worktree holds no change yet: "Editing", not counted
    /// as awaiting review, and discarded when its last editor closes.
    /// Judged by the last snapshot; before the first one, an edit restored
    /// from an earlier launch is judged by the patch that launch saved, so
    /// the Dock badge counts it before its review is shown.
    var isUntouchedEdit: Bool {
        guard kind.tag == .edit else { return false }
        if let review { return review.isEmpty }
        return !restoredWithChanges
    }

    /// The state's label, as the kind adjusts it (§4.1).
    var statusLabel: String {
        if state == .awaitingReview, isUntouchedEdit { return "Editing" }
        return state.label
    }

    /// Whether an editor may write into the worktree.
    var canEdit: Bool { state == .awaitingReview && !needsRestore }

    /// Whether CCwiki has pushed this job's branch, or tried to: a push
    /// confirmed, one sent and never confirmed, or any recorded attempt.
    /// Such a job may have a branch, and a pull request, on GitHub, and
    /// only its record says so.
    var hasTriedToPush: Bool {
        pushedCommit != nil || pushingCommit != nil || !pushAttempts.isEmpty
    }

    /// An agent job that ended without a review can be submitted again.
    var canRunAgain: Bool {
        guard kind.tag != .edit else { return false }
        switch state {
        case .failed, .cancelled, .aborted: return true
        default: return false
        }
    }

    /// The submission, for an ingestion.
    var submission: IngestSubmission? {
        if case .ingestion(let submission) = kind { return submission }
        return nil
    }

    // MARK: Mutation — runners and the job center are the only callers

    func setBranch(_ newBranch: String) {
        branch = newBranch
        persist()
    }

    func setState(_ newState: JobState) {
        // Cancelled stays cancelled, but for Review Anyway. A runner that
        // was awaiting something when Cancel was pressed must not bring
        // the job back as it winds down (§4.1).
        if state == .cancelled, newState != .cancelled, newState != .awaitingReview { return }
        state = newState
        if newState.isActive, startedAt == nil { startedAt = Date() }
        if newState.isTerminal, finishedAt == nil {
            finishedAt = Date()
            closeLogFile()
        }
        persist()
    }

    func setPreflight(_ findings: [PreflightFinding]) {
        preflight = findings
    }

    func setOutcome(_ newOutcome: ClaudeOutcome) {
        outcome = newOutcome
    }

    func setBaseCommit(_ sha: String) {
        baseCommit = sha
        persist()
    }

    func setReview(_ snapshot: ReviewSnapshot, findings newFindings: [DiffFinding]) {
        review = snapshot
        findings = newFindings
    }

    func setPushingCommit(_ sha: String?) {
        pushingCommit = sha
        persist()
    }

    func setPushedCommit(_ sha: String?) {
        pushedCommit = sha
        persist()
    }

    /// Adds `attempt`, once, and writes the record: before the push is sent.
    func recordPushAttempt(_ attempt: PushAttempt) {
        if !pushAttempts.contains(attempt) { pushAttempts.append(attempt) }
        persist()
    }

    func setNotice(_ newNotice: JobNotice?) {
        notice = newNotice
        persist()
    }

    func setNeedsRestore(_ flag: Bool) {
        needsRestore = flag
    }

    /// One of CCwiki's own lines: shown, and written to the transcript file
    /// beside the agent's stream, so a replay after a relaunch has it too
    /// (`TranscriptLine`).
    func append(_ entry: JobLogEntry) {
        log.append(entry)
        // The transcript in memory is bounded; the file on disk is not.
        if log.count > 4_000 { log.removeFirst(1_000) }
        if let line = TranscriptLine.encode(entry) { appendRaw(line) }
    }

    /// Many entries as one change to `log`, so the transcript view updates
    /// once for the batch rather than once per line. The agent's, parsed
    /// from lines `appendRaw` has already written, so nothing is written
    /// again.
    func append(_ entries: [JobLogEntry]) {
        guard !entries.isEmpty else { return }
        log.append(contentsOf: entries)
        if log.count > 4_000 { log.removeFirst(log.count - 3_000) }
    }

    /// Mirror the child's raw output to disk, so a finished job can be
    /// re-read after the worktree is gone. The write happens on the log's own
    /// queue: a synchronous write per line used to run on the main actor.
    func appendRaw(_ line: String) {
        if logWriter == nil { logWriter = LogWriter(file: logFile) }
        logWriter?.write(line)
    }

    private func closeLogFile() {
        logWriter?.close()
        logWriter = nil
    }

    /// A restored job: `logFile` through `ClaudeStreamParser`, off the main
    /// actor, to rebuild `log` and `outcome`. Once, when the job is first
    /// shown; a job from this launch has its transcript already, and a
    /// second call does nothing.
    ///
    /// The replayed lines go before whatever the job has logged since the
    /// relaunch, which starts with the line that says it was restored. Only
    /// what earlier launches wrote is read: the rest is in `log` already.
    func replayTranscript() async {
        guard needsReplay else { return }
        needsReplay = false
        let file = logFile
        let length = replayLength
        let replayed = await Task.detached(priority: .utility) {
            Job.transcript(at: file, length: length)
        }.value
        log = replayed.entries + log
        if outcome == nil, let previous = replayed.outcome { outcome = previous }
    }

    /// The entries and the outcome in the first `length` bytes of a
    /// transcript file: the agent's stream-json, its stderr, and CCwiki's
    /// own lines. At most the last 3,000 entries, as the live transcript
    /// keeps.
    nonisolated static func transcript(at file: URL, length: Int) -> (entries: [JobLogEntry], outcome: ClaudeOutcome?) {
        guard length > 0, let data = try? Data(contentsOf: file) else { return ([], nil) }
        return transcript(from: String(decoding: data.prefix(length), as: UTF8.self))
    }

    nonisolated static func transcript(from text: String) -> (entries: [JobLogEntry], outcome: ClaudeOutcome?) {
        var parser = ClaudeStreamParser()
        var entries: [JobLogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let own = TranscriptLine.decode(line) {
                entries.append(own)
            } else {
                entries.append(contentsOf: parser.consume(String(line)))
            }
        }
        return (Array(entries.suffix(3_000)), parser.outcome)
    }

    /// Stops work that has not reached review. Anything else is left as it
    /// is: a review is discarded, never cancelled, and a publish is
    /// interrupted (§4.1).
    func cancel() {
        guard state.isCancellable else { return }
        task?.cancel()
        append(JobLogEntry(.system, "Cancelled."))
        setState(.cancelled)
    }

    /// A publish stopped by a quit or a relaunch: the push or `gh` call is
    /// cancelled and the job goes back to review, where nothing is lost.
    /// Opening the pull request again asks GitHub first (§4.4).
    func interruptPublishing() {
        guard state.isPublishing else { return }
        task?.cancel()
        append(JobLogEntry(.system, Self.publishingInterrupted))
        setState(.awaitingReview)
    }
}

// MARK: - Record

/// What survives a relaunch. Everything else about a job is either derivable
/// from the id (its paths) or in the transcript file.
struct JobRecord: Codable, Sendable {
    let id: String
    let kind: JobKind
    let branch: String
    let state: JobState
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let baseCommit: String?
    let pullRequest: PullRequestDraft?
    let pushingCommit: String?
    let pushedCommit: String?
    /// Empty in a record written before attempts were kept.
    let pushAttempts: [PushAttempt]
    let notice: JobNotice?

    /// Spelled out, so the decoder below and the synthesized encoder agree.
    enum CodingKeys: String, CodingKey {
        case id, kind, branch, state, createdAt, startedAt, finishedAt, baseCommit
        case pullRequest, pushingCommit, pushedCommit, pushAttempts, notice
    }
}

extension JobRecord {
    /// A record written before 0.3 has `submission` and no `kind`.
    private enum LegacyKeys: String, CodingKey { case submission }

    /// In an extension, so the memberwise init `Job.record` uses survives.
    /// A record from before 0.3 decodes as `.ingestion(submission)`, with
    /// `createdAt` its `submittedAt`; the fields it never had are nil, and
    /// a record from before push attempts were kept has none.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind: JobKind
        let createdAt: Date
        if let decoded = try container.decodeIfPresent(JobKind.self, forKey: .kind) {
            kind = decoded
            createdAt = try container.decode(Date.self, forKey: .createdAt)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let submission = try legacy.decode(IngestSubmission.self, forKey: .submission)
            kind = .ingestion(submission)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
                ?? submission.submittedAt
        }
        let id = try container.decode(String.self, forKey: .id)
        let branch = try container.decode(String.self, forKey: .branch)
        let state = try container.decode(JobState.self, forKey: .state)
        let startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        let finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        let baseCommit = try container.decodeIfPresent(String.self, forKey: .baseCommit)
        let pullRequest = try container.decodeIfPresent(PullRequestDraft.self, forKey: .pullRequest)
        let pushingCommit = try container.decodeIfPresent(String.self, forKey: .pushingCommit)
        let pushedCommit = try container.decodeIfPresent(String.self, forKey: .pushedCommit)
        let pushAttempts = try container.decodeIfPresent(
            [PushAttempt].self, forKey: .pushAttempts) ?? []
        let notice = try container.decodeIfPresent(JobNotice.self, forKey: .notice)
        self.init(
            id: id, kind: kind, branch: branch, state: state, createdAt: createdAt,
            startedAt: startedAt, finishedAt: finishedAt, baseCommit: baseCommit,
            pullRequest: pullRequest, pushingCommit: pushingCommit,
            pushedCommit: pushedCommit, pushAttempts: pushAttempts, notice: notice)
    }
}

// MARK: - Transcript file

/// One of CCwiki's own lines in a job's transcript file, which otherwise
/// holds the agent's stream-json and its stderr, line by line.
///
/// JSON, as the agent's lines are, with a type of its own: `{"type":
/// "ccwiki", "role": "error", "text": "…", "at": 1760263200.5}`.
/// `ClaudeStreamParser` passes over a type it does not know, and a replay
/// gives each line back its role and its time, and a text of several lines
/// back as one entry.
enum TranscriptLine {

    static let typeName = "ccwiki"

    static func encode(_ entry: JobLogEntry) -> String? {
        var object: [String: Any] = [
            "type": typeName,
            "role": role(entry.role),
            "text": entry.text,
            "at": entry.timestamp.timeIntervalSince1970,
        ]
        if case .tool(let name) = entry.role { object["tool"] = name }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The entry `line` holds, or nil for any line that is not CCwiki's.
    static func decode(_ line: Substring) -> JobLogEntry? {
        // Cheap test first: most lines are the agent's.
        guard line.hasPrefix("{"), line.contains("\"type\":\"\(typeName)\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == typeName,
              let text = object["text"] as? String
        else { return nil }
        let at = (object["at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let role: JobLogEntry.Role = switch object["role"] as? String ?? "system" {
        case "assistant": .assistant
        case "tool": .tool(name: object["tool"] as? String ?? "tool")
        case "toolResult": .toolResult(isError: false)
        case "toolError": .toolResult(isError: true)
        case "stderr": .stderr
        case "error": .error
        default: .system
        }
        return JobLogEntry(role, text, at: at)
    }

    private static func role(_ role: JobLogEntry.Role) -> String {
        switch role {
        case .system: "system"
        case .assistant: "assistant"
        case .tool: "tool"
        case .toolResult(let isError): isError ? "toolError" : "toolResult"
        case .stderr: "stderr"
        case .error: "error"
        }
    }
}

/// Appends lines to a file on a private serial queue, in order.
///
/// It appends, and never truncates: a job's transcript is written again
/// after a relaunch, a Review Anyway or a publish, and each of those must
/// add to what the agent wrote, not replace it (plans/corrections.md §4.2).
///
/// `@unchecked Sendable` with one audit: every access to `handle` happens on
/// `queue`.
final class LogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ccwiki.job-log")
    private var handle: FileHandle?

    init(file: URL) {
        queue.async {
            let manager = FileManager.default
            let path = file.path(percentEncoded: false)
            try? manager.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: path) {
                manager.createFile(atPath: path, contents: nil)
            }
            self.handle = try? FileHandle(forWritingTo: file)
            _ = try? self.handle?.seekToEnd()
        }
    }

    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { try? self.handle?.write(contentsOf: data) }
    }

    /// Flushes what is queued, then closes.
    func close() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
        }
    }

    /// Returns once everything queued so far is written. For tests.
    func waitUntilWritten() {
        queue.sync {}
    }
}

/// Collects transcript entries and hands them to the job in batches: at most
/// one update to the transcript view every 100 ms, and never more than
/// 100 ms late, so a line that arrives just before a long silence still
/// shows promptly.
@MainActor
final class TranscriptBuffer {
    private let job: Job
    private var pending: [JobLogEntry] = []
    private var flushTask: Task<Void, Never>?
    static let interval: Duration = .milliseconds(100)

    init(job: Job) { self.job = job }

    func append(_ entries: [JobLogEntry]) {
        guard !entries.isEmpty else { return }
        pending.append(contentsOf: entries)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.interval)
            self?.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        job.append(pending)
        pending.removeAll(keepingCapacity: true)
    }
}
