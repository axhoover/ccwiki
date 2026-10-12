import Foundation

/// A job's changes as staged in its worktree, against the commit it started
/// from (plans/corrections.md §6.1): what the review shows and Approve
/// commits, with a digest that makes Approve send only what was reviewed.
///
/// Phase 0 declares it; Track A fills it (§11.2).
struct ReviewSnapshot: Sendable, Equatable {
    let baseCommit: String
    let files: [ChangedFile]
    /// Hex SHA-256 of `git diff --cached --binary <base>`.
    let digest: String

    var isEmpty: Bool { files.isEmpty }

    /// Pure and Sendable, so it runs in `Task.detached`: `relations.json` is
    /// 11,432 lines.
    static func assemble(
        base: String, entries: [GitNameStatus.Entry], binary: Set<String>,
        patch: Data, oldTexts: [String: String], newTexts: [String: String]
    ) -> ReviewSnapshot {
        ReviewSnapshot(baseCommit: base, files: [], digest: "")
    }
}

/// One file the snapshot changes.
struct ChangedFile: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable {
        case added, modified, deleted, renamed
    }

    /// Repository-relative.
    let path: String
    /// The path before a rename.
    let oldPath: String?
    let status: Status
    let isBinary: Bool
    let oldText: String?
    let newText: String?
    let hunks: [LineHunk]

    var id: String { path }

    var addedLines: Int { hunks.reduce(0) { $0 + $1.new.count } }
    var removedLines: Int { hunks.reduce(0) { $0 + $1.old.count } }
    var isMarkdown: Bool { path.hasSuffix(".md") }
}

/// One changed run of lines: 0-based file lines, half-open, on each side.
struct LineHunk: Sendable, Equatable {
    let old: Range<Int>
    let new: Range<Int>
}
