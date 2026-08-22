import Foundation

/// The quick switcher's matcher: fzf-style subsequence scoring, no dependency.
///
/// Full-text search (FTS5) answers "which page talks about this"; the quick
/// switcher answers "I know the page, get me there in four keystrokes". Those
/// want different algorithms — `prf` should rank `pseudorandom-function` first
/// even though the letters are scattered, which no tokenizer will do.
enum FuzzyMatcher {

    struct Match: Comparable {
        let score: Int
        /// Indices into the candidate that were matched, for highlighting.
        let positions: [String.Index]

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.score < rhs.score }
    }

    // Scoring weights, tuned against the wiki's own titles.
    private static let matchBonus = 16
    private static let consecutiveBonus = 12
    private static let wordStartBonus = 14
    private static let camelStartBonus = 10
    private static let exactPrefixBonus = 32
    private static let gapPenalty = 2
    private static let leadingGapPenalty = 1
    private static let maxLeadingGapPenalty = 12

    /// `nil` when `needle` is not a subsequence of `candidate`.
    ///
    /// Greedy forward pass then a backward refinement: the forward pass finds
    /// *a* match, the backward pass slides each matched character as late as
    /// possible so that runs land on word boundaries. That is what makes
    /// `ot` prefer `oblivious-transfer` over `one-time-pad`… and, when it
    /// doesn't, the alias table does.
    static func match(_ needle: String, in candidate: String) -> Match? {
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }

        let lowerNeedle = Array(needle.lowercased())
        let characters = Array(candidate)
        let lowerCandidate = Array(candidate.lowercased())
        guard characters.count >= lowerNeedle.count else { return nil }

        // Forward pass: is it a subsequence at all, and where does it end?
        var positions: [Int] = []
        var candidateIndex = 0
        for character in lowerNeedle {
            while candidateIndex < lowerCandidate.count,
                  lowerCandidate[candidateIndex] != character {
                candidateIndex += 1
            }
            guard candidateIndex < lowerCandidate.count else { return nil }
            positions.append(candidateIndex)
            candidateIndex += 1
        }

        // Backward refinement: pull each match as late as it can go without
        // crossing the next one, which favours word starts.
        var refined = positions
        for i in stride(from: refined.count - 1, through: 0, by: -1) {
            let ceiling = i + 1 < refined.count ? refined[i + 1] - 1 : lowerCandidate.count - 1
            var best = refined[i]
            var probe = refined[i] + 1
            while probe <= ceiling {
                if lowerCandidate[probe] == lowerNeedle[i], isBoundary(characters, probe) {
                    best = probe
                }
                probe += 1
            }
            refined[i] = best
        }

        var score = 0
        var previous = -1
        for (needleIndex, position) in refined.enumerated() {
            score += matchBonus
            if position == previous + 1 {
                score += consecutiveBonus
            } else if previous >= 0 {
                score -= min(gapPenalty * (position - previous - 1), 24)
            }
            if isBoundary(characters, position) {
                score += position > 0 && characters[position].isUppercase
                    ? camelStartBonus : wordStartBonus
            }
            if needleIndex == 0 {
                score -= min(leadingGapPenalty * position, maxLeadingGapPenalty)
            }
            previous = position
        }
        if lowerCandidate.starts(with: lowerNeedle) { score += exactPrefixBonus }
        // Shorter candidates win ties: `PRF` should beat
        // `pseudorandom-function-with-a-long-name`.
        score -= characters.count / 8

        let indices = refined.map { candidate.index(candidate.startIndex, offsetBy: $0) }
        return Match(score: score, positions: indices)
    }

    private static func isBoundary(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == "-" || previous == "_" || previous == " " || previous == "/" { return true }
        return previous.isLowercase && characters[index].isUppercase
    }
}

/// One row of the quick switcher.
struct QuickSwitchItem: Identifiable, Sendable {
    let path: String
    let title: String
    /// The alias or filename fragment that matched, when it was not the title.
    let subtitle: String?
    let kind: PageKind
    let status: PageStatus
    let score: Int

    var id: String { path }
}

extension WikiIndex {
    /// Fuzzy-match a query against titles, aliases and reference paper titles.
    ///
    /// Every page contributes several candidate strings, and the best-scoring
    /// one wins — which is how `AGGM06` and `one-way functions on NP-hardness`
    /// both find the same reference page.
    func quickSwitch(_ query: String, limit: Int = 40) -> [QuickSwitchItem] {
        let pages = pages.values

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return pages
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .prefix(limit)
                .map {
                    QuickSwitchItem(path: $0.path, title: $0.title, subtitle: subtitle(for: $0),
                                    kind: $0.kind, status: $0.status, score: 0)
                }
        }

        var results: [QuickSwitchItem] = []
        for page in pages {
            var best: (score: Int, source: String?)?

            func consider(_ candidate: String, weight: Int, source: String?) {
                guard let match = FuzzyMatcher.match(query, in: candidate) else { return }
                let score = match.score + weight
                if best == nil || score > best!.score { best = (score, source) }
            }

            consider(page.title, weight: 30, source: nil)
            for alias in page.aliases { consider(alias, weight: 24, source: alias) }
            if page.kind == .reference {
                consider(page.displayTitle, weight: 0, source: page.displayTitle)
            }
            consider(page.slug, weight: 0, source: nil)

            guard let best else { continue }
            results.append(QuickSwitchItem(
                path: page.path,
                title: page.title,
                subtitle: best.source ?? subtitle(for: page),
                kind: page.kind,
                status: page.status,
                score: best.score))
        }

        return results
            .sorted { ($0.score, $1.title.count) > ($1.score, $0.title.count) }
            .prefix(limit)
            .map { $0 }
    }

    private func subtitle(for page: WikiPage) -> String? {
        if page.kind == .reference { return page.displayTitle }
        return page.directory.isEmpty ? nil : page.directory
    }
}
