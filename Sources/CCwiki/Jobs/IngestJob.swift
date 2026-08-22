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

    enum State: Equatable, Sendable {
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
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    // MARK: Mutation — the runner is the only caller

    func setBranch(_ newBranch: String) { branch = newBranch }

    func setState(_ newState: State) {
        state = newState
        if newState.isActive, startedAt == nil { startedAt = Date() }
        if newState.isTerminal, finishedAt == nil {
            finishedAt = Date()
            closeLogFile()
        }
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
