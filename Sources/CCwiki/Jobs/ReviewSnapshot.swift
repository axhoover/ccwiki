import CryptoKit
import Foundation

/// A job's changes as staged in its worktree, against the commit it started
/// from (plans/corrections.md §6.1): what the review shows and Approve
/// commits. Approve commits `tree` or nothing, and checks `digest` too.
struct ReviewSnapshot: Sendable, Equatable {
    let baseCommit: String
    /// The staged tree the snapshot was taken of, by name (`git
    /// write-tree`). The files and the patch are its diff from the base,
    /// and the commit Approve makes has exactly this tree
    /// (`GitService.commitReviewed`).
    let tree: String
    let files: [ChangedFile]
    /// Hex SHA-256 of `git diff <GitService.patchOptions> <base> <tree>`.
    let digest: String

    var isEmpty: Bool { files.isEmpty }

    /// Pure and Sendable, so it runs in `Task.detached`: `relations.json` is
    /// 11,432 lines.
    ///
    /// - `entries` and `binary` are `GitNameStatus`'s reading of the diff
    ///   from `base` to `tree`, in git's order, which the files keep.
    /// - `patch` is that diff with `GitService.patchOptions`, byte for byte.
    /// - `oldTexts` holds `git cat-file blob <base>:<path>` by the path at
    ///   the base (a rename's old path); `newTexts` holds `git cat-file blob
    ///   <tree>:<path>` by the new path. Both decoded only after they were
    ///   read as bytes.
    ///
    /// A binary file carries no text and no hunks. So does a file with a
    /// side that should have text and is missing from its map, because
    /// git could not read it or its bytes are not UTF-8: it fails closed, as a
    /// binary, which DiffGuard blocks. Diffed against nothing, it would show
    /// as emptied, and no rule would read the bytes the patch carries.
    static func assemble(
        base: String, tree: String, entries: [GitNameStatus.Entry], binary: Set<String>,
        patch: Data, oldTexts: [String: String], newTexts: [String: String]
    ) -> ReviewSnapshot {
        let files = entries.map { entry -> ChangedFile in
            let unreadableOld = entry.status != .added && oldTexts[entry.oldPath ?? entry.path] == nil
            let unreadableNew = entry.status != .deleted && newTexts[entry.path] == nil
            let isBinary = binary.contains(entry.path)
                || (entry.oldPath.map { binary.contains($0) } ?? false)
                || unreadableOld || unreadableNew
            let oldText = isBinary || entry.status == .added
                ? nil : oldTexts[entry.oldPath ?? entry.path]
            let newText = isBinary || entry.status == .deleted
                ? nil : newTexts[entry.path]
            let hunks = isBinary
                ? [] : LineDiff.hunks(old: oldText ?? "", new: newText ?? "")
            return ChangedFile(
                path: entry.path, oldPath: entry.oldPath, status: entry.status,
                isBinary: isBinary, oldText: oldText, newText: newText, hunks: hunks)
        }
        return ReviewSnapshot(
            baseCommit: base, tree: tree, files: files, digest: Self.digest(patch))
    }

    /// Hex SHA-256: what the snapshot taken at Approve is compared with, and
    /// what the tree Approve commits must give as well as be the reviewed
    /// one (`GitService.commitReviewed`).
    static func digest(_ patch: Data) -> String {
        SHA256.hash(data: patch).map { String(format: "%02x", $0) }.joined()
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
