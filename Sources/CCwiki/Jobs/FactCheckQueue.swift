import Foundation

/// The wiki's `.fact-check/queue.json`, read for the pages a human has
/// verified (plans/corrections.md §6.2, `humanVerified`). Pure.
///
/// Phase 0 declares it; Track A fills it (§11.2).
enum FactCheckQueue {
    /// Empty on any error.
    static func humanVerifiedPaths(json: Data) -> Set<String> {
        []
    }
}
