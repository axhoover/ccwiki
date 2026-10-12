import Foundation

/// Line hunks between two texts, built on `CollectionDifference`, adjacent
/// ones merged (plans/corrections.md §6.1). Pure.
///
/// Phase 0 declares it; Track A fills it (§11.2).
enum LineDiff {
    static func hunks(old: String, new: String) -> [LineHunk] {
        []
    }
}
