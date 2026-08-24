import Foundation

/// What the Relations inspector shows for one page.
///
/// Pure and testable: it turns "the page at this path" into an ordered list of
/// groups. The view renders; it decides nothing.
///
/// **The invariant this type exists to hold.** Every row is one whole
/// hyperedge. A reduction with three hypotheses produces exactly *one* row in
/// exactly one group per role, never three. `RelationsTests` asserts the row
/// count equals the reduction count rather than the endpoint-pair count,
/// because that is the difference between reporting what the wiki claims and
/// inventing two implications it does not.
struct PageRelations: Sendable {

    /// What kind of page we are looking at. The three cases ask genuinely
    /// different questions, so they get different layouts.
    enum Subject: Sendable, Equatable {
        /// An object page — a primitive, an assumption, a complexity class.
        /// Carries the ids living on it: the host object, plus any variants
        /// that are sections of it.
        case objects([String])
        /// A `content/Reductions/…` page: this page *is* one hyperedge.
        case reduction(Relation)
        /// A `content/Barriers/…` page.
        case barrier(Barrier)
        /// A page the manifest does not know: a reference, a note, the index.
        case unknown
    }

    let subject: Subject
    let groups: [RelationGroup]

    var isEmpty: Bool { groups.isEmpty }

    static let empty = PageRelations(subject: .unknown, groups: [])

    // MARK: Building

    init(path: String, manifest: RelationsManifest) {
        if let relation = manifest.relation(onPage: path) {
            subject = .reduction(relation)
            groups = Self.groups(for: relation, manifest: manifest)
        } else if let barrier = manifest.barrier(onPage: path) {
            subject = .barrier(barrier)
            groups = Self.groups(for: barrier, manifest: manifest)
        } else {
            let ids = manifest.objectIDs(onPage: path)
            subject = ids.isEmpty ? .unknown : .objects(ids)
            groups = Self.groups(forObjects: ids, manifest: manifest)
        }
    }

    private init(subject: Subject, groups: [RelationGroup]) {
        self.subject = subject
        self.groups = groups
    }

    /// An object page: one block per object on the page, in the wiki's own
    /// vocabulary. The host object comes first, then its variants.
    private static func groups(
        forObjects ids: [String], manifest: RelationsManifest
    ) -> [RelationGroup] {
        let ordered = ids.sorted { left, right in
            let leftVariant = manifest.object(left)?.isVariant ?? false
            let rightVariant = manifest.object(right)?.isVariant ?? false
            if leftVariant != rightVariant { return !leftVariant }
            return left < right
        }

        var result: [RelationGroup] = []
        for id in ordered {
            let touching = manifest.relations(touching: id)
            guard !touching.isEmpty else { continue }

            // A relation reaches this object as a hypothesis, as the
            // conclusion, or both — and each kind is a different claim, so each
            // gets its own bucket rather than one shared arrow.
            var buckets: [RelationRole: [RelationRow]] = [:]

            for relation in touching.asHypothesis {
                let role: RelationRole = switch relation.kind {
                case .equivalence: .equivalentTo
                case .inclusion: .containedIn
                case .implication: .buildsOn
                }
                buckets[role, default: []].append(.relation(relation))
            }
            for relation in touching.asConclusion {
                let role: RelationRole = switch relation.kind {
                // Symmetric: it belongs in the one group either way, never
                // split across a directional pair.
                case .equivalence: .equivalentTo
                case .inclusion: .contains
                case .implication: .produces
                }
                buckets[role, default: []].append(.relation(relation))
            }
            for barrier in touching.barriers {
                buckets[.barriers, default: []].append(.barrier(barrier))
            }

            for role in RelationRole.allCases {
                guard let rows = buckets[role], !rows.isEmpty else { continue }
                result.append(RelationGroup(
                    id: "\(id)/\(role.rawValue)",
                    role: role,
                    objectID: id,
                    rows: Self.deduplicated(rows)))
            }
        }
        return result
    }

    /// A reduction page: the edge itself, its endpoints, and any barrier on the
    /// same hyperedge.
    private static func groups(
        for relation: Relation, manifest: RelationsManifest
    ) -> [RelationGroup] {
        var result: [RelationGroup] = []

        if !relation.hypotheses.isEmpty {
            result.append(RelationGroup(
                id: "\(relation.id)/hypotheses",
                role: relation.hypotheses.count > 1 ? .hypothesesConjoined : .hypotheses,
                objectID: nil,
                rows: relation.hypotheses.map { .object($0) }))
        }
        result.append(RelationGroup(
            id: "\(relation.id)/conclusion",
            role: .conclusion,
            objectID: nil,
            rows: [.object(relation.conclusion)]))

        // Every barrier on this hyperedge, whether or not it bites. One that
        // rules out a *narrower* notion than this reduction claims is still
        // worth seeing; it just is not a contradiction.
        let sameEdge = manifest.barriers(onSameEdgeAs: relation)
        if !sameEdge.isEmpty {
            result.append(RelationGroup(
                id: "\(relation.id)/barriers",
                role: .barriersOnEdge,
                objectID: nil,
                rows: sameEdge.map { .barrier($0) }))
        }
        return result
    }

    /// A barrier page: the hyperedge it rules out.
    private static func groups(
        for barrier: Barrier, manifest: RelationsManifest
    ) -> [RelationGroup] {
        var result: [RelationGroup] = []

        if !barrier.hypotheses.isEmpty {
            result.append(RelationGroup(
                id: "\(barrier.id)/hypotheses",
                role: barrier.hypotheses.count > 1 ? .hypothesesConjoined : .hypotheses,
                objectID: nil,
                rows: barrier.hypotheses.map { .object($0) }))
        }
        result.append(RelationGroup(
            id: "\(barrier.id)/conclusion",
            role: .conclusion,
            objectID: nil,
            rows: [.object(barrier.conclusion)]))

        // The reductions this barrier actually rules out. Usually none: a
        // barrier and a reduction on the same edge normally differ in class, or
        // one of them is `unstated`, which is comparable to nothing.
        let ruled = manifest.reductions.filter {
            manifest.barriers(contradicting: $0).contains(where: { $0.id == barrier.id })
        }
        if !ruled.isEmpty {
            result.append(RelationGroup(
                id: "\(barrier.id)/contradicts",
                role: .contradicts,
                objectID: nil,
                rows: ruled.map { .relation($0) }))
        }
        return result
    }

    /// A relation can reach one group twice — a page hosting both an object and
    /// a variant that are hypotheses of the same edge. It is still one claim,
    /// so it is one row.
    private static func deduplicated(_ rows: [RelationRow]) -> [RelationRow] {
        var seen: Set<String> = []
        return rows.filter { seen.insert($0.id).inserted }
    }
}

/// The heading a block of rows files under.
enum RelationRole: String, Sendable, CaseIterable {
    // On an object page, in the wiki's own vocabulary.
    case buildsOn, produces, equivalentTo, containedIn, contains, barriers
    // On a reduction or barrier page.
    case hypotheses, hypothesesConjoined, conclusion, barriersOnEdge, contradicts

    /// The role alone, without the object it is about.
    ///
    /// The object's name is *not* folded in here. A complexity class can be
    /// called "Bounded-Error Probabilistic Polynomial-Time", and
    /// "Bounded-Error Probabilistic Polynomial-Time is contained in" truncates
    /// in a 240 pt column to exactly the half that carries no information —
    /// leaving "contained in" and "contains" indistinguishable. The role leads;
    /// the view adds the object's name underneath, and only when a page hosts
    /// more than one object and it is needed to tell two blocks apart.
    var title: String {
        switch self {
        case .buildsOn: "Builds on"
        case .produces: "Produces"
        case .equivalentTo: "Equivalent to"
        case .containedIn: "Contained in"
        case .contains: "Contains"
        case .barriers: "Barriers"
        case .hypotheses: "Hypothesis"
        case .hypothesesConjoined: "Hypotheses — all of them"
        case .conclusion: "Conclusion"
        case .barriersOnEdge: "Barriers on this hyperedge"
        case .contradicts: "Rules out"
        }
    }

    /// Shown as a tooltip. The inclusion and conjunction cases are the two a
    /// reader is most likely to misread, so they say what they mean.
    var explanation: String {
        switch self {
        case .buildsOn:
            "Reductions that use this as a hypothesis."
        case .produces:
            "Reductions that conclude this."
        case .equivalentTo:
            "Holds in both directions."
        case .containedIn:
            "Containment, not implication."
        case .contains:
            "Containment, not implication."
        case .barriers:
            "Statements about which reductions can exist here."
        case .hypotheses:
            "What this reduction assumes."
        case .hypothesesConjoined:
            "A conjunction: the theorem needs every one of these, not any one "
                + "of them."
        case .conclusion:
            "What this reduction gives you."
        case .barriersOnEdge:
            "Barriers stated about this same set of hypotheses and conclusion. "
                + "A barrier only contradicts a reduction whose class is at "
                + "least as strict as the one it rules out."
        case .contradicts:
            "Reductions this barrier rules out, because their class implies the "
                + "one the barrier forbids."
        }
    }
}

struct RelationGroup: Sendable, Identifiable {
    let id: String
    let role: RelationRole
    /// The object this block is about, on an object page. `nil` on a reduction
    /// or barrier page, where the page itself is the subject.
    let objectID: String?
    let rows: [RelationRow]
}

/// One row. Always a whole hyperedge, or a single endpoint — never a pair.
enum RelationRow: Sendable, Identifiable {
    case relation(Relation)
    case barrier(Barrier)
    /// An endpoint, shown on a reduction or barrier page.
    case object(String)

    var id: String {
        switch self {
        case .relation(let relation): "r:" + relation.id
        case .barrier(let barrier): "b:" + barrier.id
        case .object(let id): "o:" + id
        }
    }
}
