import Foundation

/// What the Relations inspector shows for one page.
///
/// Pure and testable: it turns "the page at this path" into an ordered list of
/// groups. The view renders; it decides nothing.
///
/// **The invariant this type exists to hold.** Every row naming a relation is
/// one whole hyperedge. A reduction with three hypotheses produces exactly
/// *one* row in exactly one group per role, never three. `RelationsTests`
/// asserts the row count equals the reduction count rather than the
/// endpoint-pair count, because that is the difference between reporting what
/// the wiki claims and inventing two implications it does not.
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

    /// A reduction page: what the page's own record says, its endpoints, any
    /// barrier on the same hyperedge, and any barrier it gets around.
    private static func groups(
        for relation: Relation, manifest: RelationsManifest
    ) -> [RelationGroup] {
        var result: [RelationGroup] = [RelationGroup(
            id: "\(relation.id)/summary",
            role: .summary,
            objectID: nil,
            rows: facts(for: relation, manifest: manifest).map { .fact($0) })]

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

        // The barriers this reduction gets around. Listed once, under the
        // more specific claim: BH26's OIHF ⇒ OT both shares a hyperedge with
        // the fully-black-box barrier on OIHF ⇒ OT and circumvents it, and
        // "Circumvents" is the sentence a reader needs.
        let circumvented = manifest.barriers(circumventedBy: relation)
        let circumventedIDs = Set(circumvented.map(\.id))

        // Every other barrier on this hyperedge, whether or not it bites. One
        // that rules out a *narrower* notion than this reduction claims is
        // still worth seeing; it just is not a contradiction.
        let sameEdge = manifest.barriers(onSameEdgeAs: relation)
            .filter { !circumventedIDs.contains($0.id) }
        if !sameEdge.isEmpty {
            result.append(RelationGroup(
                id: "\(relation.id)/barriers",
                role: .barriersOnEdge,
                objectID: nil,
                rows: sameEdge.map { .barrier($0) }))
        }
        if !circumvented.isEmpty {
            result.append(RelationGroup(
                id: "\(relation.id)/circumvents",
                role: .circumvents,
                objectID: nil,
                rows: circumvented.map { .barrier($0) }))
        }
        return result
    }

    /// A barrier page: what the page's own record says, the hyperedge it rules
    /// out, and the reductions that get around it.
    private static func groups(
        for barrier: Barrier, manifest: RelationsManifest
    ) -> [RelationGroup] {
        var result: [RelationGroup] = [RelationGroup(
            id: "\(barrier.id)/summary",
            role: .summary,
            objectID: nil,
            rows: facts(for: barrier, manifest: manifest).map { .fact($0) })]

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
        let ruled = manifest.reductions(contradictedBy: barrier)
        if !ruled.isEmpty {
            result.append(RelationGroup(
                id: "\(barrier.id)/contradicts",
                role: .contradicts,
                objectID: nil,
                rows: ruled.map { .relation($0) }))
        }

        // The manifest's contract: a barrier is not the last word on its
        // conclusion until this list has been read. These need not share the
        // barrier's hyperedge.
        let circumventing = manifest.reductions(circumventing: barrier)
        if !circumventing.isEmpty {
            result.append(RelationGroup(
                id: "\(barrier.id)/circumventedBy",
                role: .circumventedBy,
                objectID: nil,
                rows: circumventing.map { .relation($0) }))
        }
        return result
    }

    // MARK: The page's own record

    /// The summary of a reduction page: kind, the heuristic caveat, class,
    /// model, technique, sources and security loss, in the order the site's
    /// line under the heading gives them (`relationMeta.ts`).
    ///
    /// Two of the site's omissions are kept. A stub shows no class and no
    /// model, because the manifest says a stub's typing is not evidence. A
    /// containment between complexity classes shows no class and no standard
    /// model, because neither axis applies to `IP ⊆ PSPACE`. `unstated`, which
    /// the site leaves out, is shown as itself: here it is the honest answer
    /// to a question the summary visibly asks.
    ///
    /// Every field the record can give a reason for carries that reason as
    /// its tooltip, read through `Relation.why(_:)`.
    static func facts(for relation: Relation, manifest: RelationsManifest) -> [RelationFact] {
        var list = FactList()

        let kindHelp: String? = switch relation.kind {
        case .implication where relation.hasMultipleHypotheses:
            "A conjunction: the theorem needs every hypothesis, not any one of them."
        case .implication: nil
        case .inclusion: "Containment, not implication."
        case .equivalence: "Holds in both directions."
        }
        // The relation's own arrow, so a heuristic edge's kind reads `⇢`, as
        // its rows do, rather than a solid `⇒` above "Heuristic candidate".
        list.add(.kind, "Kind", .text(relation.kind.title),
                 symbol: relation.arrow, help: lines(kindHelp, relation.why("kind")))

        if relation.heuristic {
            list.add(.heuristic, "Proof", .text("Heuristic candidate"),
                     help: lines(Relation.heuristicExplanation, relation.why("heuristic")))
        }

        let containment = manifest.isComplexityContainment(relation)
        if relation.status != .stub {
            if !containment {
                list.addClass(.reductionClass, "Class", relation.reductionClass, noun: nil,
                              rationale: relation.why("class"), manifest: manifest)
            }
            if !relation.model.isEmpty, !(containment && relation.model == "standard") {
                list.add(.model, "Model",
                         .text(sentenceCased(RelationVocabulary.modelName(relation.model))),
                         help: relation.why("model"),
                         link: RelationVocabulary.modelPage(relation.model).map { "[[\($0)]]" })
            }
        }

        for entry in relation.via {
            list.add(.via, "Via", .text(RelationText.linkText(entry)),
                     help: relation.why("via"), link: entry)
        }
        list.addSources(relation.source, rationale: relation.why("source"))

        if !relation.securityLoss.isEmpty {
            let loss = RelationText.plain(relation.securityLoss)
            // The loss itself first: a long one is cut short in the grid, and
            // its tooltip is where it can be read in full.
            list.add(.securityLoss, "Security loss", .text(loss),
                     help: lines(loss, relation.why("securityLoss")))
        }
        return list.facts
    }

    /// The summary of a barrier page: strength, the class it rules out, what
    /// it assumes, what the ruled-out reduction would imply, and its sources.
    /// The consequences are shown rather than left to a tooltip, with the
    /// community's belief about each, because they are what the barrier says.
    static func facts(for barrier: Barrier, manifest: RelationsManifest) -> [RelationFact] {
        var list = FactList()

        let conditional: String? = barrier.strength == .conditional
            ? "The barrier rests on an unproven assumption." : nil
        list.add(.strength, "Strength", .text(barrier.strength.title),
                 help: lines(conditional, barrier.why("strength")))

        if barrier.status != .stub {
            // An oracle separation's oracle is carried by its class
            // (`relativizing`) and described in `oracle`, so that reason
            // belongs beside the class.
            list.addClass(.against, "Against", barrier.reductionClass, noun: "reductions",
                          rationale: lines(barrier.why("class"), barrier.why("oracle")),
                          manifest: manifest)
        }

        for entry in barrier.conditionalOn {
            // An object id becomes a row that opens the object; anything else
            // is the wiki's free text, kept as written.
            let value: RelationFact.Value = manifest.object(entry) != nil
                ? .object(entry) : .text(RelationText.plain(entry))
            list.add(.assuming, "Assuming", value, help: barrier.why("conditionalOn"))
        }

        for consequence in barrier.consequences {
            switch consequence.kind {
            case .contradiction:
                list.add(.consequence, "Would imply", .consequence(consequence),
                         help: "So no such reduction can exist.")
            case .object:
                list.add(.consequence, "Would imply", .object(consequence.target))
            case .complexity:
                let proposition = manifest.propositions[consequence.target]
                let page = proposition?.page ?? ""
                let help: String?
                switch proposition?.believed {
                case true?: help = "Believed true, but open: such a reduction would prove it."
                case false?: help = "Believed false: such a reduction would be a major result."
                case nil: help = nil
                }
                list.add(.consequence, "Would imply", .consequence(consequence),
                         help: help,
                         link: page.isEmpty ? nil : "[[\(page)]]",
                         believed: proposition?.believed)
            case .reduction:
                let slug = manifest.reduction(consequence.target)?.slug ?? ""
                list.add(.consequence, "Would imply", .consequence(consequence),
                         link: slug.isEmpty ? nil : "[[\(slug)]]")
            }
        }

        list.addSources(barrier.source, rationale: barrier.why("source"))
        return list.facts
    }

    /// The non-empty lines, one per line; `nil` when there are none.
    private static func lines(_ parts: String?...) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: "\n")
    }

    /// "random oracle model" → "Random oracle model", for a value standing on
    /// its own. An acronym such as "CRS model" is left alone.
    private static func sentenceCased(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Builds the summary rows in order, giving each a stable id.
    private struct FactList {
        private(set) var facts: [RelationFact] = []

        mutating func add(
            _ field: RelationFact.Field, _ label: String, _ value: RelationFact.Value,
            symbol: String? = nil, help: String? = nil, link: String? = nil,
            isTentative: Bool = false, believed: Bool? = nil
        ) {
            facts.append(RelationFact(
                id: "\(field.rawValue)/\(facts.count)", field: field, label: label,
                value: value, symbol: symbol, help: help, link: link,
                isTentative: isTentative, believed: believed))
        }

        /// A class row, linking to that class's section of the glossary page.
        /// `unstated` has a section there too, so it links as well; it is
        /// shown as itself, de-emphasized, and never with a noun that would
        /// make it read like a class.
        mutating func addClass(
            _ field: RelationFact.Field, _ label: String, _ name: String,
            noun: String?, rationale: String?, manifest: RelationsManifest
        ) {
            guard !name.isEmpty else { return }
            let isSentinel = manifest.isSentinel(name)
            let title = manifest.classTitle(name)
            let value: String = if isSentinel {
                name
            } else if let noun {
                "\(title) \(noun)"
            } else {
                title
            }
            let unstated: String? = isSentinel
                ? "The source does not say which notion of reduction is meant." : nil
            add(field, label, .text(value),
                help: PageRelations.lines(unstated, rationale),
                link: "[[\(RelationVocabulary.classPage)#\(name)]]",
                isTentative: isSentinel)
        }

        /// One row per citation, each opening its reference page, with the
        /// paper's title as the tooltip. `folklore` is a provenance label like
        /// any key, never a warning. The record's reason for its sources, if
        /// it gives one, is about the field as a whole, so every row carries
        /// it under the title.
        mutating func addSources(_ source: [String], rationale: String?) {
            let entries = source.compactMap { entry in
                RelationText.citationKey(entry).map { (entry: entry, key: $0) }
            }
            for (entry, key) in entries {
                let isFolklore = entry == "folklore"
                let title: String? = isFolklore
                    ? "Folklore: the wiki has no attribution for this claim."
                    : WikilinkParser.links(in: entry).first?.target
                add(.source, entries.count > 1 ? "Sources" : "Source", .text(key),
                    help: PageRelations.lines(title, rationale),
                    link: isFolklore ? nil : entry)
            }
        }
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
    case summary, hypotheses, hypothesesConjoined, conclusion, barriersOnEdge, circumvents
    case contradicts, circumventedBy

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
        case .summary: "This result"
        case .hypotheses: "Hypothesis"
        case .hypothesesConjoined: "Hypotheses — all of them"
        case .conclusion: "Conclusion"
        case .barriersOnEdge: "Barriers on this hyperedge"
        case .circumvents: "Circumvents"
        case .contradicts: "Rules out"
        case .circumventedBy: "Circumvented by"
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
        case .summary:
            "What the wiki records about this result. Hover over a value for the "
                + "reason behind it."
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
        case .circumvents:
            "Barriers this reduction gets around: it reaches their conclusion "
                + "outside the class or scope they rule out."
        case .contradicts:
            "Reductions this barrier rules out, because their class implies the "
                + "one the barrier forbids."
        case .circumventedBy:
            "Reductions that get around this barrier, by reaching its conclusion "
                + "outside the class or scope it rules out. They need not share "
                + "its hyperedge."
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

    /// The summary's rows, which the view lays out together as one grid.
    var facts: [RelationFact] {
        rows.compactMap { row -> RelationFact? in
            guard case .fact(let fact) = row else { return nil }
            return fact
        }
    }
}

/// One row. Always a whole hyperedge, a single endpoint, or one field of the
/// page's own record — never a pair.
enum RelationRow: Sendable, Identifiable {
    case relation(Relation)
    case barrier(Barrier)
    /// An endpoint, shown on a reduction or barrier page.
    case object(String)
    /// A field of the page's own record, in the summary of a reduction or
    /// barrier page.
    case fact(RelationFact)

    var id: String {
        switch self {
        case .relation(let relation): "r:" + relation.id
        case .barrier(let barrier): "b:" + barrier.id
        case .object(let id): "o:" + id
        case .fact(let fact): "f:" + fact.id
        }
    }
}

/// One line of the summary that leads a reduction or barrier page: a field of
/// the page's own record, as a label and a value.
///
/// The site prints the same record as one line under the page's heading
/// (`relationMeta.ts`), and the page body no longer restates it. The inspector
/// lays it out as label–value rows instead, because it has room for what the
/// site leaves out: the record's `rationale` beside the value it justifies,
/// and a barrier's consequences with how strongly each is believed.
struct RelationFact: Sendable, Identifiable, Hashable {
    enum Field: String, Sendable {
        case kind, heuristic, reductionClass, model, via, source, securityLoss
        case strength, against, assuming, consequence
    }

    /// What the value is. Object names are left to `RelationLabels`, which
    /// needs the parsed wiki and so is not available here.
    enum Value: Sendable, Hashable {
        /// Already plain text for the chrome.
        case text(String)
        /// A manifest object, named by `RelationLabels.label`.
        case object(String)
        /// A barrier consequence, named by `RelationLabels.consequence`.
        case consequence(Barrier.Consequence)
    }

    /// Unique within its summary: the field plus the row's position.
    let id: String
    let field: Field
    let label: String
    let value: Value
    /// A connective shown before the value, de-emphasized: the kind's arrow.
    var symbol: String?
    /// The tooltip. For most fields, the record's own `rationale` for it.
    var help: String?
    /// Where the value leads, as a wikilink in the wiki's own form. The view
    /// resolves it against the index, so a link the clone cannot resolve
    /// stays plain text.
    var link: String?
    /// An honest "we do not know", such as `unstated`, shown de-emphasized.
    var isTentative = false
    /// For a consequence that is a complexity proposition: the community's
    /// working belief about it.
    var believed: Bool?
}
