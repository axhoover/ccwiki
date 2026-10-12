import Foundation

/// Local paths and tokens that must never reach a pull request or an issue
/// (plans/corrections.md §6.4). Pure.
///
/// The agent's prompt contains its worktree's path, so its handover can too,
/// and an ingestion's metadata carries a PDF's absolute path. This runs over
/// the title and body as they are typed, over every added line at Approve
/// (DiffGuard's `privateText`), and over an issue's text.
enum PrivateText {

    /// Each local path or token in `text`, as found, in the order they
    /// appear, each once. Paths: the home directory, and the worktree,
    /// library and Application Support roots, as `privatePaths` names them.
    /// Tokens: `gh[pousr]_[A-Za-z0-9]{36,}` and `github_pat_[A-Za-z0-9_]{22,}`.
    ///
    /// A path is found anywhere, in any case (the Mac's disk ignores case),
    /// and percent-encoded as a `file:` URL would carry it, unless a letter,
    /// a digit, `_` or `-` follows it: `/Users/al` is not in `/Users/alice`.
    /// Where one path holds another, the longer is reported.
    static func findings(in text: String, privatePaths: [String]) -> [String] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var matches: [NSRange] = []

        for needle in needles(privatePaths) {
            var searchRange = NSRange(location: 0, length: ns.length)
            while searchRange.length > 0 {
                let found = ns.range(of: needle, options: [.caseInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                if endsAtBoundary(found, in: ns) { matches.append(found) }
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: ns.length - next)
            }
        }
        for pattern in tokenPatterns {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                matches.append(match.range)
            }
        }

        // Earliest first, and at one place the longest; then drop anything
        // inside a match already kept.
        matches.sort {
            $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length
        }
        var kept: [NSRange] = []
        for match in matches {
            if let last = kept.last, NSMaxRange(match) <= NSMaxRange(last),
               match.location >= last.location {
                continue
            }
            kept.append(match)
        }

        var seen: Set<String> = []
        var result: [String] = []
        for range in kept {
            let found = ns.substring(with: range)
            if seen.insert(found).inserted { result.append(found) }
        }
        return result
    }

    private static let tokenPatterns: [NSRegularExpression] = [
        // gh's OAuth, personal, user-to-server, server-to-server and refresh
        // tokens.
        try! NSRegularExpression(pattern: "gh[pousr]_[A-Za-z0-9]{36,}"),
        // Fine-grained personal access tokens.
        try! NSRegularExpression(pattern: "github_pat_[A-Za-z0-9_]{22,}"),
    ]

    /// Each private path without its trailing slash, and its percent-encoded
    /// form where that differs ("Application%20Support"). A path too short
    /// to mean anything, such as "/", would match every line, and is left
    /// out.
    private static func needles(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in paths {
            var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard trimmed.count > 2 else { continue }
            result.append(trimmed)
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               encoded != trimmed {
                result.append(encoded)
            }
        }
        return result
    }

    /// A path ends where a name could not go on: `/Users/al` followed by
    /// `/`, a space, punctuation or the end, never by `ice`.
    private static func endsAtBoundary(_ range: NSRange, in text: NSString) -> Bool {
        let end = NSMaxRange(range)
        guard end < text.length else { return true }
        let unit = text.character(at: end)
        guard let scalar = Unicode.Scalar(unit) else { return true }
        if scalar == "_" || scalar == "-" { return false }
        return !CharacterSet.alphanumerics.contains(scalar)
    }
}
