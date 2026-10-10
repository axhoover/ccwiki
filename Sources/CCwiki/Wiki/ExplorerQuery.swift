import Foundation

/// The question the Relations Explorer asks: does `from` imply `to`?
///
/// `from` is one conjunction, never a list of separate premises: a recorded
/// reduction fires only once all its hypotheses hold, and the question is
/// asked of all of them together (relations.md §1). It keeps the order the
/// objects were entered in, so the field reads back as typed; two questions
/// with the same objects in another order are the same question.
///
/// Ids are stored, never labels, so a title renamed upstream still matches.
/// The models toggle is part of the question, so a Recent entry restores it,
/// but a launch never does (`launching()`): nobody returns days later to
/// idealised results without having asked for them.
struct ExplorerQuery: Codable, Hashable, Sendable {
    var from: [String] = []
    var to: String? = nil
    var includesIdealisedModels = false

    init(from: [String] = [], to: String? = nil, includesIdealisedModels: Bool = false) {
        self.from = from
        self.to = to
        self.includesIdealisedModels = includesIdealisedModels
    }

    var options: Derivation.Options {
        Derivation.Options(includesIdealisedModels: includesIdealisedModels)
    }

    /// Which of the four layouts the explorer shows (relations-explorer.md
    /// §2.5).
    enum Mode: Sendable, Equatable {
        /// Nothing asked.
        case empty
        /// From only: everything the conjunction derives.
        case forward
        /// To only: everything that derives it.
        case backward
        /// Both: does From imply To?
        case question
    }

    var mode: Mode {
        switch (from.isEmpty, to == nil) {
        case (true, true): .empty
        case (false, true): .forward
        case (true, false): .backward
        case (false, false): .question
        }
    }

    /// The same question with the toggle off: what a launch restores.
    func launching() -> ExplorerQuery {
        var query = self
        query.includesIdealisedModels = false
        return query
    }

    /// Two questions are the same when they ask about the same conjunction,
    /// the same target and the same models. Entry order is not part of the
    /// question.
    func isSameQuestion(as other: ExplorerQuery) -> Bool {
        Set(from) == Set(other.from) && to == other.to
            && includesIdealisedModels == other.includesIdealisedModels
    }

    /// A stable key for a list of questions, such as Recent: the conjunction
    /// sorted, then the target and the toggle.
    var key: String {
        from.sorted(by: Derivation.precedes).joined(separator: ",")
            + ">" + (to ?? "") + (includesIdealisedModels ? "+idealised" : "")
    }

    // MARK: Stale objects

    /// Ids the manifest no longer has, in field order. A sync can remove an
    /// object a persisted question names; the explorer shows it struck
    /// through and leaves it out, rather than pruning it silently.
    func unknownIDs(in manifest: RelationsManifest) -> [String] {
        (from + (to.map { [$0] } ?? [])).filter { manifest.object($0) == nil }
    }

    /// The question without `ids`.
    func removing(_ ids: [String]) -> ExplorerQuery {
        guard !ids.isEmpty else { return self }
        let gone = Set(ids)
        var query = self
        query.from = from.filter { !gone.contains($0) }
        if let to, gone.contains(to) { query.to = nil }
        return query
    }

    // MARK: Editing

    /// From with `id` appended, unless it is already there.
    func adding(_ id: String) -> ExplorerQuery {
        guard !from.contains(id) else { return self }
        var query = self
        query.from.append(id)
        return query
    }

    /// `old` replaced by `new` in From, in place, so the field keeps its
    /// order.
    func replacingStart(_ old: String, with new: String) -> ExplorerQuery {
        var query = self
        if let position = from.firstIndex(of: old) {
            if from.contains(new) {
                query.from.remove(at: position)
            } else {
                query.from[position] = new
            }
        }
        return query
    }

    /// Swap From and To. Only a single object can be a conclusion: a
    /// conjunction is never split to make one.
    var canSwap: Bool { from.count <= 1 }

    func swapped() -> ExplorerQuery {
        guard canSwap else { return self }
        var query = self
        query.from = to.map { [$0] } ?? []
        query.to = from.first
        return query
    }

    // MARK: Wording

    /// The question as a statement: `OWF ∧ KEM ⇒* Public key encryption`,
    /// `DDH ⇒* …`, `… ⇒* PKE`, or `nil` for nothing asked. Always `⇒*`: it
    /// restates a question, and the answer decides whether it is recorded.
    func statement(labels: RelationLabels) -> String? {
        let arrow = DerivationWording.derivedArrow
        let left = from.isEmpty
            ? DerivationWording.anything
            : DerivationWording.conjoined(from.map { labels.label($0) })
        switch mode {
        case .empty:
            return nil
        case .forward:
            return "\(left) \(arrow) \(DerivationWording.anything)"
        case .backward, .question:
            return "\(left) \(arrow) \(labels.label(to ?? ""))"
        }
    }

    // MARK: Seeding from a page (relations-explorer.md §2.11)

    /// What "Explore From This Page" asks on the page whose subject this is:
    ///
    /// - an object page: the variant whose section is being read, else the
    ///   host object, else the page's first object that takes part in a
    ///   derivation; From is that object and To is left open;
    /// - a reduction page: From is its hypotheses, To is open, so you see
    ///   what they give together;
    /// - a barrier page: From is its hypotheses and To its conclusion, which
    ///   opens the answer for the edge it rules out with the barrier in it;
    /// - a complexity class, a page the manifest does not know, or an edge
    ///   with a class endpoint: `nil`, since classes are related by
    ///   containment and never derived (R2).
    ///
    /// The toggle is left off; the caller passes the explorer's own through.
    static func seed(
        for subject: PageRelations.Subject, activeAnchor: String?,
        manifest: RelationsManifest, derivation: Derivation
    ) -> ExplorerQuery? {
        let participants = derivation.participants(.all)
        func takesPart(_ id: String) -> Bool {
            participants.contains(id) && manifest.object(id)?.type != Derivation.excludedType
        }
        func allTakePart(_ ids: [String]) -> Bool {
            !ids.isEmpty && ids.allSatisfy { manifest.object($0) != nil
                && manifest.object($0)?.type != Derivation.excludedType }
        }

        switch subject {
        case .objects(let ids):
            // The host first, then its sections by id, as the inspector
            // orders them.
            let ordered = ids.sorted { left, right in
                let leftVariant = manifest.object(left)?.isVariant ?? false
                let rightVariant = manifest.object(right)?.isVariant ?? false
                if leftVariant != rightVariant { return !leftVariant }
                return Derivation.precedes(left, right)
            }
            if let anchor = activeAnchor,
               let variant = ordered.first(where: {
                   manifest.object($0)?.isVariant == true && manifest.object($0)?.anchor == anchor
               }),
               takesPart(variant) {
                return ExplorerQuery(from: [variant])
            }
            if let host = ordered.first(where: { manifest.object($0)?.isVariant == false }),
               takesPart(host) {
                return ExplorerQuery(from: [host])
            }
            if let first = ordered.first(where: takesPart) {
                return ExplorerQuery(from: [first])
            }
            return nil
        case .reduction(let relation):
            guard allTakePart(relation.hypotheses), allTakePart([relation.conclusion]) else {
                return nil
            }
            return ExplorerQuery(from: relation.hypotheses)
        case .barrier(let barrier):
            guard allTakePart(barrier.hypotheses), allTakePart([barrier.conclusion]) else {
                return nil
            }
            return ExplorerQuery(from: barrier.hypotheses, to: barrier.conclusion)
        case .unknown:
            return nil
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case from, to, includesIdealisedModels
    }

    /// Every key optional, so a question persisted by another version still
    /// reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decodeIfPresent([String].self, forKey: .from) ?? []
        to = try container.decodeIfPresent(String.self, forKey: .to)
        includesIdealisedModels = try container.decodeIfPresent(
            Bool.self, forKey: .includesIdealisedModels) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
        try container.encode(includesIdealisedModels, forKey: .includesIdealisedModels)
    }
}
