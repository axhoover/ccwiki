import Foundation

/// The order ⌘S shows pages in: rules applied one after another, each only
/// breaking the ties the one before it left (plans/search-v2.md §6.1).
///
/// BM25 alone cannot be trusted with this wiki. A reduction whose text says
/// "LWE" forty times outscores the LWE page, and on the first measurement a
/// concept page came first for its own name only 54% of the time. The rules,
/// in order:
///
/// 1. **How much of a name matched**: all of it (exactly, or once case,
///    accents and punctuation are set aside), then part of it (a prefix, or
///    every query word somewhere in it), then no name at all, only text.
/// 2. **Whose name**: a concept page's before a reduction's or a barrier's.
///    Those are named after the concepts they connect ("Ring-LWE to NTRU"),
///    so a partial match on one says less than a partial match on the
///    concept itself, or on one of its sections.
/// 3. **The finer match**: exact before folded, prefix before every-word,
///    and a title or alias before a heading.
/// 4. **The section**, the maintainer's priority: primitives and assumptions,
///    then complexity classes, then glossary, barriers, folklore and notes,
///    then reductions.
/// 5. **BM25**, over title, aliases, headings and text, for what is left.
///
/// Pure, so the rules are tested without SQLite. References are never here;
/// they have their own search.
struct ConceptRanker: Sendable {

    /// How well a query matched a name, best first.
    enum Match: Int, Comparable, Sendable {
        /// Equal, ignoring case and runs of whitespace. `#P` is not `P`.
        case exact
        /// Equal once case, accents and punctuation are folded away, or once
        /// the spaces between words are too: `one way function` and
        /// `ArthurMerlin` find "One-way function" and "Arthur-Merlin".
        case folded
        /// The name starts with the query, which is what typing looks like,
        /// with or without the spaces between words.
        case prefix
        /// Every word of the query is a word of the name, the last one as a
        /// prefix, and a plural query word matches its singular. Or the query,
        /// its spaces removed, runs across words of the name from the start of
        /// one: `multiparty computation` finds "Secure multi-party
        /// computation".
        case allWords
        /// No name matched; the page is here for its text.
        case text

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The whole name, part of it, or none of it.
        var band: Int {
            switch self {
            case .exact, .folded: 0
            case .prefix, .allWords: 1
            case .text: 2
            }
        }
    }

    /// Where the best-matching name was, best first.
    enum Field: Int, Comparable, Sendable {
        case name, heading, edgeName, edgeHeading

        static func < (lhs: Field, rhs: Field) -> Bool { lhs.rawValue < rhs.rawValue }

        /// A reduction's or a barrier's.
        var isEdge: Bool { self == .edgeName || self == .edgeHeading }
    }

    /// One page, with its names pre-folded so a keystroke costs comparisons
    /// and nothing else.
    struct Entry: Sendable {
        let path: String
        let slug: String
        let title: String
        let kind: PageKind
        let status: PageStatus
        let names: [Name]
        let headings: [Heading]

        struct Heading: Sendable {
            let name: Name
            /// The anchor Quartz gives it, for opening the page at it.
            let id: String
        }

        init(page: WikiPage, headings: [Heading]) {
            path = page.path
            slug = page.slug
            title = page.title
            kind = page.kind
            status = page.status
            // The filename too: a reduction is titled "LWE ⇒ PKE" but filed
            // as `lwe-to-pke-reg05`, which is what a reader types.
            names = ([page.title] + page.aliases + [page.stem]).map(Name.init)
            self.headings = headings
        }
    }

    /// A name as typed and as folded.
    struct Name: Sendable {
        let text: String
        let exact: String
        let folded: String
        let words: [String]
        /// Folded with the word breaks removed too, so that a word written
        /// joined, split or hyphenated is one spelling: `arthurmerlin`.
        let compact: String
        /// The compact form from the start of each word on: `multi-party
        /// computation` is `multipartycomputation`, `partycomputation`,
        /// `computation`. A joined query may begin at any word, not inside one.
        let compactTails: [String]

        init(_ text: String) {
            self.text = text
            exact = ConceptRanker.collapse(text)
            folded = ConceptRanker.fold(text)
            let words = folded.split(separator: " ").map(String.init)
            self.words = words
            compact = words.joined()
            compactTails = words.indices.map { words[$0...].joined() }
        }
    }

    /// One ranked page. `section` is set when a heading was the best match,
    /// so the reader can open there, as documentation search does.
    struct Ranked: Sendable {
        let entry: Entry
        let match: Match
        let field: Field
        let section: Entry.Heading?
        let score: Double
    }

    let entries: [Entry]
    /// Every word of every name and section name, with the number of times it
    /// occurs: what a misspelled word is corrected to.
    let vocabulary: [String: Int]

    /// A heading on this many pages or more is the page template, not a name:
    /// "Participates in" is on 117 pages, "Statement" on nearly every
    /// reduction. Its words still count as text, through BM25.
    static let structuralHeadingPages = 3

    init(pages: [WikiPage]) {
        let pages = pages.filter { $0.kind != .reference }
        let headings = pages.map { page in
            page.headings().map {
                Entry.Heading(name: Name(RelationText.plain($0.text)), id: $0.id)
            }
        }
        var pageCounts: [String: Int] = [:]
        for list in headings {
            for folded in Set(list.map(\.name.folded)) { pageCounts[folded, default: 0] += 1 }
        }
        let entries = zip(pages, headings).map { page, list in
            Entry(page: page, headings: list.filter {
                !$0.name.folded.isEmpty
                    && pageCounts[$0.name.folded, default: 0] < Self.structuralHeadingPages
            })
        }
        var vocabulary: [String: Int] = [:]
        for entry in entries {
            for name in entry.names + entry.headings.map(\.name) {
                for word in name.words { vocabulary[word, default: 0] += 1 }
            }
        }
        self.entries = entries
        self.vocabulary = vocabulary
    }

    static let empty = ConceptRanker(pages: [])

    /// The maintainer's order of sections. References never reach this.
    static func priority(_ kind: PageKind) -> Int {
        switch kind {
        case .primitive, .assumption: 0
        case .complexityClass: 1
        case .glossary, .barrier, .folklore, .note: 2
        case .reduction: 3
        case .reference: 4
        }
    }

    /// Rank every page whose names match the query, plus every page the full
    /// text found. `textScores` is BM25 by path, lower better, as FTS5 gives
    /// it; a page the text search missed sorts after those it found.
    func rank(_ query: String, textScores: [String: Double], limit: Int = 60) -> [Ranked] {
        let query = Name(query)
        guard !query.folded.isEmpty || !query.exact.isEmpty else { return [] }

        var ranked: [Ranked] = []
        for entry in entries {
            let isEdge = entry.kind == .reduction || entry.kind == .barrier
            var best: (match: Match, field: Field, section: Entry.Heading?)?

            for name in entry.names {
                if let match = Self.match(query, name) {
                    let field: Field = isEdge ? .edgeName : .name
                    if best.map({ (match, field) < ($0.match, $0.field) }) ?? true {
                        best = (match, field, nil)
                    }
                }
            }
            for heading in entry.headings {
                if let match = Self.match(query, heading.name) {
                    let field: Field = isEdge ? .edgeHeading : .heading
                    if best.map({ (match, field) < ($0.match, $0.field) }) ?? true {
                        best = (match, field, heading)
                    }
                }
            }

            let score = textScores[entry.path]
            if let best {
                ranked.append(Ranked(
                    entry: entry, match: best.match, field: best.field,
                    section: best.section, score: score ?? .greatestFiniteMagnitude))
            } else if let score {
                ranked.append(Ranked(
                    entry: entry, match: .text, field: isEdge ? .edgeName : .name,
                    section: nil, score: score))
            }
        }

        ranked.sort { a, b in
            if a.match.band != b.match.band { return a.match.band < b.match.band }
            if a.match != .text {
                if a.field.isEdge != b.field.isEdge { return !a.field.isEdge }
                if a.match != b.match { return a.match < b.match }
                if a.field != b.field { return a.field < b.field }
            }
            let pa = Self.priority(a.entry.kind), pb = Self.priority(b.entry.kind)
            if pa != pb { return pa < pb }
            if a.score != b.score { return a.score < b.score }
            return a.entry.path < b.entry.path
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: Did you mean

    /// How many typos a word may have and still be corrected, as Meilisearch
    /// allows: none below five letters, where one edit makes another real
    /// word (`SIS`, `SIVP`, `LPN`); one up to eight; two from nine.
    static func typoBudget(_ word: String) -> Int {
        word.count < 5 ? 0 : word.count < 9 ? 1 : 2
    }

    /// The query, folded, with each word that no name or section name
    /// contains replaced by the nearest one that does; nil when there is
    /// nothing to correct. The last word is left alone while it is still the
    /// start of a known word, since it is probably being typed.
    func correction(for query: String) -> String? {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        var changed = false
        let corrected = words.enumerated().map { index, word -> String in
            let budget = Self.typoBudget(word)
            guard budget > 0, vocabulary[word] == nil else { return word }
            if index == words.count - 1, vocabulary.keys.contains(where: { $0.hasPrefix(word) }) {
                return word
            }
            // Nearest first, then the more common word, then alphabetical so
            // the answer does not depend on dictionary order.
            var best: (distance: Int, count: Int, word: String)?
            for (candidate, count) in vocabulary
            where abs(candidate.count - word.count) <= budget {
                guard let distance = Self.editDistance(word, candidate, limit: budget),
                      best.map({ (distance, -count, candidate) < ($0.distance, -$0.count, $0.word) })
                        ?? true
                else { continue }
                best = (distance, count, candidate)
            }
            guard let best else { return word }
            changed = true
            return best.word
        }
        return changed ? corrected.joined(separator: " ") : nil
    }

    /// Optimal string alignment distance: insertions, deletions,
    /// substitutions, and swaps of two adjacent letters, each one edit. Nil
    /// when it is more than `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return nil }
        guard !a.isEmpty, !b.isEmpty else {
            let distance = max(a.count, b.count)
            return distance <= limit ? distance : nil
        }
        var twoBack = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, twoBack[j - 2] + 1)
                }
                current[j] = value
            }
            (twoBack, previous, current) = (previous, current, twoBack)
        }
        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }

    /// How well `query` matches `name`, or nil.
    static func match(_ query: Name, _ name: Name) -> Match? {
        if !query.exact.isEmpty, query.exact == name.exact { return .exact }
        guard !query.words.isEmpty else { return nil }
        if query.folded == name.folded || query.compact == name.compact { return .folded }
        if name.folded.hasPrefix(query.folded) || name.compact.hasPrefix(query.compact) {
            return .prefix
        }
        if everyWord(of: query, isIn: name) { return .allWords }
        // Joined or split differently from the name: linear in the name's
        // words, so it needs no limit on the query's length.
        if name.compactTails.contains(where: { $0.hasPrefix(query.compact) }) { return .allWords }
        return nil
    }

    private static func everyWord(of query: Name, isIn name: Name) -> Bool {
        for (i, word) in query.words.enumerated() {
            let isLast = i == query.words.count - 1
            let forms = singulars(of: word)
            guard name.words.contains(where: {
                forms.contains($0) || (isLast && $0.hasPrefix(word))
            }) else { return false }
        }
        return true
    }

    /// A word and the singulars it might be the plural of. Deliberately
    /// crude: a full stemmer reaches words that were never meant (`primes` is
    /// not `prime`s of the same thing), and the names here are nouns.
    static func singulars(of word: String) -> Set<String> {
        var forms: Set<String> = [word]
        if word.count > 3, word.hasSuffix("s") { forms.insert(String(word.dropLast())) }
        if word.count > 4, word.hasSuffix("es") { forms.insert(String(word.dropLast(2))) }
        return forms
    }

    /// Lowercased, whitespace runs collapsed to one space, trimmed.
    static func collapse(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Case, accents and width folded; everything but letters and digits is a
    /// word break. `Vigenère`, `vigenere` and `VIGENERE` are one name, and so
    /// are `one-way function` and `One way function`.
    static func fold(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var pendingBreak = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingBreak, !result.isEmpty { result.append(" ") }
                pendingBreak = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingBreak = true
            }
        }
        return result
    }
}
