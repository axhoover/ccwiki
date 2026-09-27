import Foundation
import Observation

/// One ingestion job: its state, its transcript, and where its worktree is.
///
/// A reference type because the runner streams into it from a long-lived task
/// while the UI reads it, and `@MainActor` because the transcript is what the
/// jobs panel renders.
@Observable
@MainActor
final class IngestJob: Identifiable {

    enum State: Equatable, Sendable, Codable {
        case queued
        /// Setting up: worktree, submodules.
        case preparing(String)
        /// The agent is working.
        case running
        /// Finished, with a draft PR.
        case opened(url: URL)
        /// The agent declined the job on purpose. That is a good outcome.
        case aborted(reason: String)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .queued, .preparing, .running: false
            case .opened, .aborted, .failed, .cancelled: true
            }
        }

        var isActive: Bool {
            switch self {
            case .preparing, .running: true
            default: false
            }
        }

        var label: String {
            switch self {
            case .queued: "Queued"
            case .preparing(let step): step
            case .running: "Running"
            case .opened: "Draft PR opened"
            case .aborted: "Aborted"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        var symbolName: String {
            switch self {
            case .queued: "clock"
            case .preparing, .running: "arrow.triangle.2.circlepath"
            case .opened: "checkmark.circle.fill"
            case .aborted: "hand.raised.fill"
            case .failed: "xmark.octagon.fill"
            case .cancelled: "slash.circle"
            }
        }
    }

    let id: String
    let submission: IngestSubmission
    let worktree: URL
    /// The branch the job works on. Settled by the runner, which may have to
    /// take the next free name if a previous attempt left one behind.
    private(set) var branch: String
    let logFile: URL
    /// Written on every state change, so the job comes back after a relaunch
    /// — with its PR URL, which used to be lost with the window.
    let recordFile: URL

    private(set) var state: State = .queued
    private(set) var log: [JobLogEntry] = []
    private(set) var outcome: ClaudeOutcome?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Findings from the pre-flight checks, shown before and after the run.
    private(set) var preflight: [PreflightFinding] = []

    /// Set by the runner so the panel's Cancel button has something to cancel.
    @ObservationIgnored var task: Task<Void, Never>?

    /// The raw stream, appended to as it arrives. Kept even after the worktree
    /// is pruned — a transcript you cannot re-read is not a transcript.
    @ObservationIgnored private var logHandle: FileHandle?

    init(submission: IngestSubmission, paths: AppPaths) {
        // A timestamp prefix keeps the jobs directory sorted and readable, and
        // keeps two jobs on the same paper from colliding.
        let stamp = Self.stampFormatter.string(from: submission.submittedAt)
        self.id = "\(stamp)-\(submission.slug)"
        self.submission = submission
        self.worktree = paths.worktree(forJob: id)
        self.branch = "ingest/\(submission.slug)"
        self.logFile = paths.log(forJob: id)
        self.recordFile = paths.record(forJob: id)
    }

    /// A job from an earlier launch. One that was still running when the app
    /// quit is reported as failed, and says so.
    init(restoring record: JobRecord, paths: AppPaths) {
        self.id = record.id
        self.submission = record.submission
        self.worktree = paths.worktree(forJob: record.id)
        self.branch = record.branch
        self.logFile = paths.log(forJob: record.id)
        self.recordFile = paths.record(forJob: record.id)
        self.startedAt = record.startedAt
        self.finishedAt = record.finishedAt ?? (record.state.isTerminal ? nil : record.startedAt)
        self.state = record.state.isTerminal
            ? record.state
            : .failed("Interrupted — CCwiki quit while this job was running.")
        self.log = [JobLogEntry(.system,
            "Restored from an earlier launch. The full transcript is in \(logFile.lastPathComponent).",
            at: record.startedAt ?? record.submission.submittedAt)]
    }

    var record: JobRecord {
        JobRecord(
            id: id, submission: submission, branch: branch, state: state,
            startedAt: startedAt, finishedAt: finishedAt)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: recordFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: recordFile, options: .atomic)
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

    // MARK: Mutation — the runner is the only caller

    func setBranch(_ newBranch: String) {
        branch = newBranch
        persist()
    }

    func setState(_ newState: State) {
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

    func append(_ entry: JobLogEntry) {
        log.append(entry)
        // The transcript in memory is bounded; the file on disk is not.
        if log.count > 4_000 { log.removeFirst(1_000) }
    }

    func append(_ entries: [JobLogEntry]) {
        for entry in entries { append(entry) }
    }

    /// Mirror the child's raw output to disk, so a finished job can be
    /// re-read after the worktree is gone.
    func appendRaw(_ line: String) {
        if logHandle == nil {
            try? FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logFile.path(percentEncoded: false), contents: nil)
            logHandle = try? FileHandle(forWritingTo: logFile)
        }
        try? logHandle?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func closeLogFile() {
        try? logHandle?.close()
        logHandle = nil
    }

    func cancel() {
        guard !state.isTerminal else { return }
        task?.cancel()
        append(JobLogEntry(.system, "Cancelled."))
        setState(.cancelled)
    }
}

/// What survives a relaunch. Everything else about a job is either derivable
/// from the id (its paths) or in the transcript file.
struct JobRecord: Codable, Sendable {
    let id: String
    let submission: IngestSubmission
    let branch: String
    let state: IngestJob.State
    let startedAt: Date?
    let finishedAt: Date?
}
