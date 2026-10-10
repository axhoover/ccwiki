import Foundation

/// Finds the objects a typed name could mean, for the explorer's From and To
/// fields.
///
/// The quick switcher's fuzzy scoring (`FuzzyMatcher`) over each node's
/// label, its aliases and its id, so `owf`, `OWF` and `preimage` all find
/// *Hash function § Preimage resistance (one-wayness)*. Only objects that
/// take part in some eligible step can be picked: the explorer's question is
/// about derivations, and complexity classes never take part in one (R2).
/// Model nodes do, and say so.
///
/// Pure and `Sendable`; the view builds one per library load.
struct RelationObjectMatcher: Sendable {

    struct Item: Identifiable, Sendable, Hashable {
        /// A manifest object or variant id.
        let id: String
        let label: String
        /// The second line: "Assumption", "Section of Hash function",
        /// "Idealised model", or the alias that matched.
        let detail: String?
        let score: Int
    }

    /// One pickable object, with what it can be matched by.
    private struct Candidate: Sendable {
        let id: String
        let label: String
        let aliases: [String]
        let isVariant: Bool
        /// What the second line says when no alias matched.
        let detail: String?
    }

    /// The weights `WikiIndex.quickSwitch` uses for a title and an alias. An
    /// id scores on its letters alone, except that typing one exactly is
    /// unambiguous: it is the graph's own name for the node. Without that
    /// bonus `ot` would rank *OT Extension* above oblivious transfer, and
    /// `owf` would rank the hash function page, whose aliases include
    /// "OWF", above the one-wayness section that is the OWF node.
    private static let labelWeight = 30
    private static let aliasWeight = 24
    private static let idWeight = 0
    private static let exactIDBonus = 48

    private let candidates: [Candidate]
    /// Complexity classes, matched only to explain why none is offered.
    private let classCandidates: [Candidate]

    static let empty = RelationObjectMatcher(candidates: [], classCandidates: [])

    private init(candidates: [Candidate], classCandidates: [Candidate]) {
        self.candidates = candidates
        self.classCandidates = classCandidates
    }

    /// `participants` is `Derivation.participants(.all)`: the endpoints of an
    /// eligible step under either setting, which never includes a class.
    init(manifest: RelationsManifest, labels: RelationLabels, participants: Set<String>) {
        var candidates: [Candidate] = []
        var classCandidates: [Candidate] = []
        for id in manifest.objectsByID.keys.sorted(by: Derivation.precedes) {
            guard let object = manifest.object(id) else { continue }
            let label = labels.label(id)
            if object.type == Derivation.excludedType {
                classCandidates.append(Candidate(
                    id: id, label: label, aliases: object.aliases, isVariant: object.isVariant,
                    detail: nil))
                continue
            }
            guard participants.contains(id) else { continue }
            candidates.append(Candidate(
                id: id, label: label, aliases: object.aliases, isVariant: object.isVariant,
                detail: Self.detail(for: object, manifest: manifest, labels: labels)))
        }
        self.candidates = candidates
        self.classCandidates = classCandidates
    }

    /// The second line when no alias matched.
    private static func detail(
        for object: RelationObject, manifest: RelationsManifest, labels: RelationLabels
    ) -> String? {
        if Derivation.modelOfNode(object.id, in: manifest) != nil {
            return "Idealised model"
        }
        if object.isVariant, let host = object.of {
            return "Section of \(labels.label(host))"
        }
        return typeName(object.type)
    }

    /// The wiki's node types, as a reader names them.
    static func typeName(_ type: String) -> String? {
        switch type {
        case "primitive": return "Primitive"
        case "assumption": return "Assumption"
        case "glossary": return "Glossary"
        case "folklore": return "Folklore"
        case "note": return "Note"
        case "complexity-class": return "Complexity class"
        case "": return nil
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    // MARK: Matching

    /// Best first, at most `limit`, never an id in `excluding`. Empty for an
    /// empty query. Ties go to the shorter label, then to a host over its
    /// sections, then to the id.
    func matches(_ query: String, excluding: Set<String>, limit: Int) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, limit > 0 else { return [] }

        var scored: [(item: Item, isVariant: Bool)] = []
        for candidate in candidates where !excluding.contains(candidate.id) {
            guard let best = Self.score(needle, candidate) else { continue }
            // An alias that only restates the label says nothing new.
            var alias = best.alias
            if let matched = alias, matched.caseInsensitiveCompare(candidate.label) == .orderedSame {
                alias = nil
            }
            let item = Item(id: candidate.id, label: candidate.label,
                            detail: alias ?? candidate.detail, score: best.score)
            scored.append((item: item, isVariant: candidate.isVariant))
        }
        scored.sort { left, right in
            if left.item.score != right.item.score { return left.item.score > right.item.score }
            if left.item.label.count != right.item.label.count {
                return left.item.label.count < right.item.label.count
            }
            if left.isVariant != right.isVariant { return !left.isVariant }
            return Derivation.precedes(left.item.id, right.item.id)
        }
        return scored.prefix(limit).map { $0.item }
    }

    /// True when nothing pickable matches but a complexity class does: the
    /// field then says why classes are not offered, rather than "no
    /// results".
    func matchesOnlyComplexityClasses(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        if candidates.contains(where: { Self.score(needle, $0) != nil }) { return false }
        return classCandidates.contains { Self.score(needle, $0) != nil }
    }

    /// The best of the label, the aliases and the id, with the alias that
    /// won when one did.
    private static func score(_ needle: String, _ candidate: Candidate) -> (score: Int, alias: String?)? {
        var best: (score: Int, alias: String?)?
        func consider(_ text: String, weight: Int, alias: String?) {
            guard let match = FuzzyMatcher.match(needle, in: text) else { return }
            let score = match.score + weight
            if let current = best, current.score >= score { return }
            best = (score: score, alias: alias)
        }
        consider(candidate.label, weight: labelWeight, alias: nil)
        for alias in candidate.aliases {
            consider(alias, weight: aliasWeight, alias: alias)
        }
        let exact = candidate.id.caseInsensitiveCompare(needle) == .orderedSame
        consider(candidate.id, weight: idWeight + (exact ? exactIDBonus : 0), alias: nil)
        return best
    }
}
