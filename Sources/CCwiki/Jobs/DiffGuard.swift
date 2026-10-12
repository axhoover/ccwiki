import Foundation

/// One thing DiffGuard noticed in a snapshot (plans/corrections.md §6.2).
struct DiffFinding: Sendable, Equatable, Identifiable {

    enum Severity: Int, Sendable, Comparable {
        /// Informs.
        case note
        /// Needs a confirmation before Open Draft PR.
        case warning
        /// Open Draft PR stays disabled.
        case blocking

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Rule: String, Sendable, CaseIterable {
        case outsideContent, renamedOrDeleted, binaryFile, generatedRegionEdited,
             relationFieldOnObjectPage, wikilinkMath, privateText,
             newObjectPage, otherPages, largeEdit, ingestionScope, proseRelationBullet,
             derivedFilesStale, relationsJSONByHand, humanVerified, statusComplete,
             changedUpstream, rawHTML, regionRegenerated
    }

    let rule: Rule
    let severity: Severity
    let path: String
    /// In the new text; in the old text for a deletion.
    let lines: LineRange?
    /// Shown as is.
    let message: String

    var id: String { "\(rule.rawValue):\(path):\(lines?.first ?? 0)" }
}

/// What may leave the machine, checked against the wiki's own rules
/// (plans/corrections.md §6.2). Pure.
///
/// Phase 0 declares it; Track A fills it (§11.2).
enum DiffGuard {

    struct Context: Sendable {
        var kind: JobKind.Tag
        /// The thresholds that apply: an edit is checked as a correction is.
        var family: JobKind.Family { kind.family }
        /// Pages `human_verified` in `.fact-check/queue.json` at the base.
        var humanVerifiedPaths: Set<String>
        /// Paths changed on `origin/<default>` since the base.
        var changedUpstream: Set<String>
        var target: CorrectionTarget?
        /// Local paths that must never appear in text (`PrivateText`).
        var privatePaths: [String]
    }

    /// The findings, blocking first, then by path and line.
    static func check(_ snapshot: ReviewSnapshot, context: Context) -> [DiffFinding] {
        []
    }

    /// `sha256(trimmed contents)[0..<12]`, as `lint.mjs` computes it.
    static func regionChecksum(_ inner: String) -> String {
        ""
    }

    /// The allow-list: a `.md` file under `content/` but not
    /// `content/Templates/`, and `.reductions/relations.json`.
    static func isPublishable(_ path: String) -> Bool {
        false
    }
}
