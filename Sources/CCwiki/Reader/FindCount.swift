import Foundation

/// Find on Page's count, from `CCwiki.findCount` in `ccwiki.js`: how many
/// times the needle is on the page, and which of them the last find
/// selected. `WKFindResult` says only whether anything matched.
///
/// The page counts what WebKit's find reads, folded as it folds it. Where
/// it cannot be sure its count agrees with find's, in a formula, it gives
/// the total alone rather than a place that may be wrong.
struct FindCount: Equatable, Sendable, Decodable {
    var total: Int
    /// 1-based; 0 when the page cannot tell which match is selected.
    var current: Int

    /// What the find bar says after a find: "3 of 17" when the page can
    /// tell which match is selected, else "17 matches", and "No matches"
    /// when find found none. Nil when find found a match the page did not
    /// count: the bar then says nothing, rather than something false.
    static func label(found: Bool, count: FindCount?) -> String? {
        guard found else { return "No matches" }
        guard let count, count.total > 0 else { return nil }
        if count.current > 0 { return "\(count.current) of \(count.total)" }
        return count.total == 1 ? "1 match" : "\(count.total) matches"
    }
}

extension FindCount {
    /// The page's `{"total": n, "current": i}`; nil for anything else, its
    /// "null" included.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let count = try? JSONDecoder().decode(FindCount.self, from: data),
              count.total >= 0, (0...count.total).contains(count.current)
        else { return nil }
        self = count
    }
}
