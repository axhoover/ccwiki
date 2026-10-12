import Foundation

/// The wiki's `.fact-check/queue.json`, read for the pages a human has
/// verified (plans/corrections.md §6.2, `humanVerified`). Pure.
///
/// The live file, as of the wiki at `ab81f02`:
///
/// ```json
/// { "version": 1, "updated_at": "…", "updated_at_sha": "…",
///   "pages": { "content/Primitives/x.md": { "status": "bot_flagged", … } } }
/// ```
///
/// Statuses are `unreviewed`, `bot_verified`, `human_verified`, `stale` and
/// `bot_flagged` (the wiki's `CLAUDE.md`). Its `CLAUDE.md` asks that a change
/// to a claim on a `human_verified` page also marks the entry `stale`, which
/// CCwiki does not do itself: DiffGuard warns instead.
enum FactCheckQueue {

    static let humanVerified = "human_verified"

    /// Repository-relative paths, as the queue keys them
    /// ("content/Primitives/x.md"). Empty on any error. Entries it cannot
    /// read are skipped, not fatal: one odd entry must not hide the others.
    static func humanVerifiedPaths(json: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return [] }
        var paths: Set<String> = []
        if let pages = root["pages"] as? [String: Any] {
            for (path, entry) in pages {
                if let entry = entry as? [String: Any], isHumanVerified(entry) {
                    paths.insert(normalized(path))
                }
            }
        } else if let pages = root["pages"] as? [Any] {
            // A list of entries that name their own path; not the live
            // format, but cheap to accept.
            for case let entry as [String: Any] in pages where isHumanVerified(entry) {
                if let path = entry["path"] as? String { paths.insert(normalized(path)) }
            }
        }
        return paths
    }

    private static func isHumanVerified(_ entry: [String: Any]) -> Bool {
        (entry["status"] as? String)?.lowercased() == humanVerified
    }

    /// "./content/x.md" and "content/x.md" are the same page.
    private static func normalized(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }
}
