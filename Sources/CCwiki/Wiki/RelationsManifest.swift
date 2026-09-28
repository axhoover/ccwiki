import Foundation

/// The wiki's relationship manifest — `relations.json`, v1.
///
/// **Where it comes from, and why not over HTTP.** The wiki serves the file at
/// `https://cryptology.city/static/relations.json`, but CCwiki reads the copy
/// committed at `.reductions/relations.json` inside the clone instead. Three
/// reasons, in order of weight:
///
/// 1. **Version skew becomes impossible.** The manifest is a pure function of
///    `content/`, so the clone hands us the manifest and the pages it describes
///    at the same commit. A separate fetch could return a manifest newer than
///    the pages on disk, whose `page` paths point at files we do not have.
/// 2. **Reading stays offline**, which is one of the app's non-negotiables. A
///    network fetch would make relationships the only part of the reader that
///    needs one.
/// 3. **Cache invalidation is already solved.** `GitService.sync` does a full
///    `git clone` — no `--depth`, no `--filter`, no sparse checkout — so the
///    file is already on disk, and `AppModel.loadLibrary()` already runs after
///    every pull. There is no refetch policy to get wrong.
///
/// This is the same contract `MacroTable` has with `macros.ts`: a file at the
/// clone root that the repo's own tooling treats as an interface, read
/// directly, degrading to empty plus a diagnostic rather than throwing.
///
/// **The one structural rule.** A reduction is a *hyperedge*: a set of
/// hypotheses, conjoined, implying one conclusion. 42 of the 343 have more than
/// one hypothesis. Nothing in this type will hand you an object-to-object pair,
/// because a pair cannot represent `{sparse-lpn, ddh} ⇒ she` without asserting
/// two implications the wiki does not claim. Every query returns whole
/// `Relation` values and the UI renders one row per relation.
struct RelationsManifest: Sendable {

    /// The only version whose semantics this code knows. The manifest's own
    /// contract says this is bumped on any breaking change to field names,
    /// types or *semantics*, so a higher number is not something to parse
    /// optimistically — see `Diagnostic.unsupportedVersion`.
    static let supportedVersion = 1

    /// Path of the manifest inside the clone, for messages.
    static let displayPath = ".reductions/relations.json"

    private(set) var objectsByID: [String: RelationObject] = [:]
    private(set) var reductions: [Relation] = []
    private(set) var barriers: [Barrier] = []
    private(set) var classes: [String: ReductionClass] = [:]
    /// Values that are *not* classes and sit outside the partial order —
    /// currently just `unstated`. Read from the file rather than hardcoded.
    private(set) var classSentinels: Set<String> = []
    private(set) var propositions: [String: Proposition] = [:]

    /// Why the manifest is empty, for the warnings menu. `nil` when it loaded.
    private(set) var diagnostic: Diagnostic?
    /// Non-fatal data problems, kept so they can be counted rather than
    /// silently swallowed. One is known upstream today (a barrier consequence
    /// naming a reduction slug where an id belongs).
    private(set) var anomalies: [String] = []

    // Derived indexes, all built once at load.
    private var relationsByHypothesis: [String: [Int]] = [:]
    private var relationsByConclusion: [String: [Int]] = [:]
    private var barriersByEndpoint: [String: [Int]] = [:]
    private var objectIDsByPath: [String: [String]] = [:]
    private var relationIndexByPath: [String: Int] = [:]
    private var barrierIndexByPath: [String: Int] = [:]
    /// class → every class it implies, transitively. Narrower → broader.
    private var classClosure: [String: Set<String>] = [:]

    static let empty = RelationsManifest()

    var isEmpty: Bool { reductions.isEmpty && barriers.isEmpty }

    /// Pages hidden from browse and navigation. `unlisted` nodes are real —
    /// they take part in relations and in the closure — they are only kept out
    /// of the sidebar, the folder listings and the quick switcher.
    var unlistedPaths: Set<String> {
        Set(objectsByID.values.filter { $0.unlisted }.map(\.path))
    }

    enum Diagnostic: Equatable, Sendable {
        case fileMissing(path: String)
        case unreadable(path: String)
        case malformed(path: String, reason: String)
        case unsupportedVersion(found: Int, supported: Int)

        var message: String {
            switch self {
            case .fileMissing(let p):
                "\(p) is not in the clone. Sync to fetch it; relationships are "
                    + "unavailable until then."
            case .unreadable(let p):
                "\(p) could not be read."
            case .malformed(let p, let reason):
                "\(p) could not be parsed — \(reason)"
            case .unsupportedVersion(let found, let supported):
                "\(RelationsManifest.displayPath) is version \(found); CCwiki understands "
                    + "version \(supported). Relationships are hidden rather than guessed — "
                    + "update CCwiki."
            }
        }
    }

    // MARK: - Loading

    /// Reads `.reductions/relations.json` from the root of a wiki clone.
    ///
    /// Never throws. Every failure degrades to an empty manifest plus a
    /// diagnostic, so the reader is unaffected and the relations pane shows a
    /// designed empty state instead of a spinner.
    static func load(cloneRoot: URL) -> RelationsManifest {
        let url = cloneRoot.appending(path: displayPath)

        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return RelationsManifest(diagnostic: .fileMissing(path: displayPath))
        }
        guard let data = try? Data(contentsOf: url) else {
            return RelationsManifest(diagnostic: .unreadable(path: displayPath))
        }
        return decode(data)
    }

    /// Split out so tests can feed bytes without a clone on disk.
    static func decode(_ data: Data) -> RelationsManifest {
        let dto: DTO
        do {
            dto = try JSONDecoder().decode(DTO.self, from: data)
        } catch {
            return RelationsManifest(
                diagnostic: .malformed(path: displayPath, reason: "\(error)"))
        }

        // A version we do not know is not something to parse partially. The
        // contract says the number moves when *semantics* change, and a
        // half-understood manifest renders a false mathematical claim, which is
        // worse than rendering nothing.
        guard dto.version == supportedVersion else {
            return RelationsManifest(
                diagnostic: .unsupportedVersion(found: dto.version, supported: supportedVersion))
        }

        var manifest = RelationsManifest()
        manifest.classSentinels = Set(dto.classSentinels)
        manifest.classes = dto.classes.mapValues {
            ReductionClass(title: $0.title, implies: $0.implies)
        }
        manifest.propositions = dto.propositions.mapValues {
            Proposition(title: $0.title, believed: $0.believed, page: $0.page)
        }

        for raw in dto.objects {
            guard let kind = RelationObject.Kind(rawValue: raw.kind) else {
                manifest.anomalies.append("object \(raw.id): unknown kind “\(raw.kind)”")
                continue
            }
            let object = RelationObject(
                id: raw.id,
                kind: kind,
                type: raw.type,
                path: Self.contentRelative(raw.page),
                slug: raw.slug,
                anchor: raw.anchor.flatMap { $0.isEmpty ? nil : String($0.drop { $0 == "#" }) },
                of: raw.of,
                title: raw.title,
                aliases: raw.aliases,
                unlisted: raw.unlisted)
            manifest.objectsByID[object.id] = object
            // Variants share their host's page, so this is a list.
            manifest.objectIDsByPath[object.path, default: []].append(object.id)
        }

        for raw in dto.reductions {
            // An unknown `kind` is the one field worth dropping a row over:
            // rendering an unrecognised relation as an implication would assert
            // something the wiki did not.
            guard let kind = Relation.Kind(rawValue: raw.kind) else {
                manifest.anomalies.append("reduction \(raw.id): unknown kind “\(raw.kind)”")
                continue
            }
            guard !raw.hypotheses.isEmpty else {
                manifest.anomalies.append("reduction \(raw.id): no hypotheses")
                continue
            }
            // The doc states inclusion and equivalence take exactly one
            // hypothesis. Both are symmetric or containment claims that a
            // conjunction cannot express, so a violation is dropped rather than
            // rendered with the wrong arrow.
            guard kind == .implication || raw.hypotheses.count == 1 else {
                manifest.anomalies.append(
                    "reduction \(raw.id): \(raw.kind) with \(raw.hypotheses.count) hypotheses")
                continue
            }

            let relation = Relation(
                id: raw.id,
                kind: kind,
                hypotheses: raw.hypotheses,
                conclusion: raw.conclusion,
                reductionClass: raw.reductionClass,
                model: raw.model,
                source: raw.source,
                via: raw.via,
                securityLoss: raw.securityLoss,
                status: PageStatus(rawValue: raw.status) ?? .draft,
                path: Self.contentRelative(raw.page),
                slug: raw.slug,
                title: raw.title)

            let index = manifest.reductions.count
            manifest.reductions.append(relation)
            manifest.relationIndexByPath[relation.path] = index
            for hypothesis in relation.hypotheses {
                manifest.relationsByHypothesis[hypothesis, default: []].append(index)
            }
            manifest.relationsByConclusion[relation.conclusion, default: []].append(index)
        }

        let reductionIDs = Set(manifest.reductions.map(\.id))
        for raw in dto.barriers {
            var consequences: [Barrier.Consequence] = []
            for rawConsequence in raw.consequences {
                guard let kind = Barrier.Consequence.Kind(rawValue: rawConsequence.kind) else {
                    manifest.anomalies.append(
                        "barrier \(raw.id): unknown consequence kind “\(rawConsequence.kind)”")
                    continue
                }
                // Drop a consequence whose target does not resolve, keep the
                // barrier. One of these exists upstream today.
                let target = rawConsequence.target
                let resolves: Bool = switch kind {
                case .contradiction: target.isEmpty
                case .object: manifest.objectsByID[target] != nil
                case .complexity: manifest.propositions[target] != nil
                case .reduction: reductionIDs.contains(target)
                }
                guard resolves else {
                    manifest.anomalies.append(
                        "barrier \(raw.id): \(rawConsequence.kind) consequence names "
                            + "“\(target)”, which does not resolve")
                    continue
                }
                consequences.append(Barrier.Consequence(
                    kind: kind, target: target, reductionClass: rawConsequence.reductionClass))
            }

            let barrier = Barrier(
                id: raw.id,
                hypotheses: raw.hypotheses,
                conclusion: raw.conclusion,
                reductionClass: raw.reductionClass,
                consequences: consequences,
                strength: Barrier.Strength(rawValue: raw.strength) ?? .unconditional,
                conditionalOn: raw.conditionalOn,
                source: raw.source,
                status: PageStatus(rawValue: raw.status) ?? .draft,
                path: Self.contentRelative(raw.page),
                slug: raw.slug,
                title: raw.title)

            let index = manifest.barriers.count
            manifest.barriers.append(barrier)
            manifest.barrierIndexByPath[barrier.path] = index
            for endpoint in Set(barrier.hypotheses + [barrier.conclusion]) {
                manifest.barriersByEndpoint[endpoint, default: []].append(index)
            }
        }

        manifest.classClosure = Self.buildClosure(manifest.classes)
        return manifest
    }

    /// The manifest's `page` is repo-relative (`content/Primitives/x.md`);
    /// `WikiPage.path` is content-relative (`Primitives/x.md`) and is the app's
    /// identity for a page. This is the join between the two.
    static func contentRelative(_ page: String) -> String {
        page.hasPrefix("content/") ? String(page.dropFirst("content/".count)) : page
    }

    /// Transitive closure of `implies`, which points from the **narrower**
    /// notion to the **broader** one. Computed from the file, never hardcoded —
    /// the wiki owns this order and can extend it.
    private static func buildClosure(_ classes: [String: ReductionClass]) -> [String: Set<String>] {
        var closure: [String: Set<String>] = [:]

        func reachable(from name: String, visiting: inout Set<String>) -> Set<String> {
            if let cached = closure[name] { return cached }
            // A cycle would mean two classes contain each other; guard anyway so
            // a bad file cannot hang the app.
            guard visiting.insert(name).inserted else { return [] }
            defer { visiting.remove(name) }

            var result: Set<String> = []
            for broader in classes[name]?.implies ?? [] {
                result.insert(broader)
                result.formUnion(reachable(from: broader, visiting: &visiting))
            }
            closure[name] = result
            return result
        }

        for name in classes.keys {
            var visiting: Set<String> = []
            _ = reachable(from: name, visiting: &visiting)
        }
        return closure
    }

    // MARK: - The class order

    /// Does a reduction of class `narrower` also count as one of class
    /// `broader`? `implies` points narrower → broader, so this is the
    /// transitive closure in that direction.
    func reductionClass(_ narrower: String, implies broader: String) -> Bool {
        guard !isSentinel(narrower), !isSentinel(broader) else { return false }
        if narrower == broader { return true }
        return classClosure[narrower]?.contains(broader) ?? false
    }

    /// A sentinel is not a class and is comparable to nothing, so the
    /// contradiction rule never fires on it. 280 of 343 reductions are
    /// `unstated`, which is a deliberate, honest value.
    func isSentinel(_ name: String) -> Bool { classSentinels.contains(name) }

    func classTitle(_ name: String) -> String { classes[name]?.title ?? name }

    // MARK: - Queries
    //
    // Everything here returns whole hyperedges. There is deliberately no API
    // returning `(from, to)` pairs.

    /// Every relation and barrier touching one object, split by the role the
    /// object plays in it.
    func relations(touching objectID: String) -> ObjectRelations {
        ObjectRelations(
            asHypothesis: (relationsByHypothesis[objectID] ?? []).map { reductions[$0] },
            asConclusion: (relationsByConclusion[objectID] ?? []).map { reductions[$0] },
            barriers: (barriersByEndpoint[objectID] ?? []).map { barriers[$0] })
    }

    /// The manifest objects living on one page: the host object, plus any
    /// variants that are sections of it.
    func objectIDs(onPage path: String) -> [String] { objectIDsByPath[path] ?? [] }

    func object(_ id: String) -> RelationObject? { objectsByID[id] }

    /// The reduction a `content/Reductions/…` page *is*, if this is one.
    func relation(onPage path: String) -> Relation? {
        relationIndexByPath[path].map { reductions[$0] }
    }

    /// The barrier a `content/Barriers/…` page *is*, if this is one.
    func barrier(onPage path: String) -> Barrier? {
        barrierIndexByPath[path].map { barriers[$0] }
    }

    /// The barriers that actually rule out a given reduction.
    ///
    /// The rule, and the only one a consumer needs: a barrier against class `B`
    /// bites a reduction of class `C` on the **same hyperedge** iff
    /// `C implies* B`. A barrier against `relativizing` kills a
    /// `fully-black-box` reduction; a barrier against `fully-black-box` does
    /// **not** touch a `free` one. Reversing that inverts every barrier in the
    /// corpus, so `RelationsTests` pins the direction with a live example.
    func barriers(contradicting relation: Relation) -> [Barrier] {
        let edge = Set(relation.hypotheses)
        return barriers.filter { barrier in
            barrier.conclusion == relation.conclusion
                && Set(barrier.hypotheses) == edge
                && reductionClass(relation.reductionClass, implies: barrier.reductionClass)
        }
    }

    /// Does `barrier` rule out `relation`? The same rule as
    /// `barriers(contradicting:)`, for one pair, without sweeping every
    /// barrier in the manifest to answer it.
    func barrier(_ barrier: Barrier, contradicts relation: Relation) -> Bool {
        barrier.conclusion == relation.conclusion
            && Set(barrier.hypotheses) == Set(relation.hypotheses)
            && reductionClass(relation.reductionClass, implies: barrier.reductionClass)
    }

    /// The reductions `barrier` rules out. One pass over the reductions with
    /// the barrier's edge built once; it used to be a sweep of every barrier
    /// for every reduction, rebuilt in a view body.
    func reductions(contradictedBy barrier: Barrier) -> [Relation] {
        let edge = Set(barrier.hypotheses)
        return reductions.filter { relation in
            relation.conclusion == barrier.conclusion
                && relation.hypotheses.count == edge.count
                && Set(relation.hypotheses) == edge
                && reductionClass(relation.reductionClass, implies: barrier.reductionClass)
        }
    }

    /// Every barrier sharing a hyperedge with this reduction, whether or not it
    /// bites. Shown as context on a reduction page — a barrier against a
    /// stricter notion is worth seeing even when it does not apply.
    func barriers(onSameEdgeAs relation: Relation) -> [Barrier] {
        let edge = Set(relation.hypotheses)
        return barriers.filter {
            $0.conclusion == relation.conclusion && Set($0.hypotheses) == edge
        }
    }
}

// MARK: - Nodes and edges

struct RelationObject: Sendable, Identifiable, Hashable {
    /// A `variant` is a named sub-object that lives as a *section* of a page —
    /// `ring-lwe` inside the LWE page — so the graph can name it without the
    /// wiki having to split the page. It is addressed as slug + anchor, never
    /// as a page of its own.
    enum Kind: String, Sendable { case object, variant }

    let id: String
    let kind: Kind
    /// `primitive` | `assumption` | `complexity-class` | `glossary` |
    /// `folklore` | `note`. Kept as a string: it is the wiki's vocabulary, and
    /// an unknown value here should not cost us the node.
    let type: String
    /// Content-relative, matching `WikiPage.path`. Variants share their host's.
    let path: String
    let slug: String
    /// Variants only, with the leading `#` removed so it can go straight into
    /// `AppModel.openPage(_:anchor:)`.
    let anchor: String?
    /// Variants only: the host object's id.
    let of: String?
    let title: String
    let aliases: [String]
    /// A real node, kept out of browse and navigation only.
    let unlisted: Bool

    var isVariant: Bool { kind == .variant }
}

/// One hyperedge: a set of hypotheses, **conjoined**, implying one conclusion.
struct Relation: Sendable, Identifiable, Hashable {
    /// Three different claims, which must never render as one arrow.
    /// `inclusion` is containment (`IP ⊆ PSPACE`, not "IP implies PSPACE") and
    /// `equivalence` holds in both directions.
    enum Kind: String, Sendable {
        case implication, inclusion, equivalence

        var arrow: String {
            switch self {
            case .implication: "⇒"
            case .inclusion: "⊆"
            case .equivalence: "⇔"
            }
        }

        /// Symmetric relations appear once, on both endpoints — never split
        /// across a "builds on" / "produces" pair, which would imply a
        /// direction the claim does not have.
        var isSymmetric: Bool { self == .equivalence }
    }

    let id: String
    let kind: Kind
    /// A **conjunction**, never a disjunction. Assumptions each independently
    /// sufficient are separate entries with one hypothesis each.
    let hypotheses: [String]
    let conclusion: String
    /// A key of `classes`, or a sentinel such as `unstated`.
    let reductionClass: String
    let model: String
    /// Citations in the wiki's own link form, or the single token `folklore`,
    /// which means the wiki has no attribution — never that none exists.
    let source: [String]
    let via: [String]
    let securityLoss: String
    let status: PageStatus
    let path: String
    let slug: String
    let title: String

    var isFolklore: Bool { source == ["folklore"] }
    var hasMultipleHypotheses: Bool { hypotheses.count > 1 }
}

/// A statement that a reduction of some class *cannot* exist — or rather, that
/// its existence would imply something. A classical black-box separation is the
/// case where that something is a contradiction; Impagliazzo–Rudich is the
/// general case, where it is `P ≠ NP`.
struct Barrier: Sendable, Identifiable, Hashable {
    struct Consequence: Sendable, Hashable {
        enum Kind: String, Sendable {
            case contradiction, object, complexity, reduction
        }
        let kind: Kind
        /// Empty for `contradiction`; otherwise an object id, a proposition
        /// key, or a reduction id.
        let target: String
        let reductionClass: String
    }

    enum Strength: String, Sendable { case unconditional, conditional }

    let id: String
    let hypotheses: [String]
    let conclusion: String
    /// The class of reduction the barrier rules out.
    let reductionClass: String
    let consequences: [Consequence]
    let strength: Strength
    let conditionalOn: [String]
    let source: [String]
    let status: PageStatus
    let path: String
    let slug: String
    let title: String

    var isFolklore: Bool { source == ["folklore"] }
}

struct ReductionClass: Sendable, Hashable {
    let title: String
    /// Points from the **narrower** notion to the **broader** one: every
    /// `fully-black-box` reduction is also a `relativizing` one.
    let implies: [String]
}

struct Proposition: Sendable, Hashable {
    let title: String
    /// The community's working belief. Upstream uses it for a soft lint flag,
    /// never as an error; CCwiki does not surface it.
    let believed: Bool
    let page: String?
}

/// Every hyperedge touching one object, by the role the object plays.
struct ObjectRelations: Sendable {
    var asHypothesis: [Relation] = []
    var asConclusion: [Relation] = []
    var barriers: [Barrier] = []

    var isEmpty: Bool { asHypothesis.isEmpty && asConclusion.isEmpty && barriers.isEmpty }
}

// MARK: - Decoding

/// Decode a key, or fall back.
///
/// Swift's *synthesized* `Decodable` ignores a property's default value and
/// throws `keyNotFound` instead, which for this file would mean one missing
/// optional key costs the entire feature. These initializers are written out so
/// the defaults are real. A key of the wrong *type* degrades the same way, for
/// the same reason.
private extension KeyedDecodingContainer {
    /// `try?` flattens the `T??` that `decodeIfPresent` would otherwise
    /// produce, so an absent key and a key of the wrong type both arrive here
    /// as `nil` — which is what we want, since both should cost a default
    /// rather than the file.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key, _ type: T.Type = T.self) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

/// The wire shape, kept separate from the domain types so every field can be
/// optional-with-a-default.
///
/// The manifest's stability contract says additive fields do not bump
/// `version`, so a consumer **must** ignore unknown keys — `Codable` does that
/// by construction. The converse is handled above: a *missing* key costs a
/// default, not the whole file.
private struct DTO: Decodable {
    var version: Int
    var classes: [String: RawClass]
    var classSentinels: [String]
    var propositions: [String: RawProposition]
    var objects: [RawObject]
    var reductions: [RawReduction]
    var barriers: [RawBarrier]

    enum CodingKeys: String, CodingKey {
        case version, classes, classSentinels, propositions, objects, reductions, barriers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, or: 0)
        classes = c.value(.classes, or: [:])
        classSentinels = c.value(.classSentinels, or: [])
        propositions = c.value(.propositions, or: [:])
        objects = c.value(.objects, or: [])
        reductions = c.value(.reductions, or: [])
        barriers = c.value(.barriers, or: [])
    }

    struct RawClass: Decodable {
        var title: String
        var implies: [String]

        enum CodingKeys: String, CodingKey { case title, implies }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.value(.title, or: "")
            implies = c.value(.implies, or: [])
        }
    }

    struct RawProposition: Decodable {
        var title: String
        var believed: Bool
        var page: String?

        enum CodingKeys: String, CodingKey { case title, believed, page }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.value(.title, or: "")
            believed = c.value(.believed, or: false)
            page = c.optional(.page)
        }
    }

    struct RawObject: Decodable {
        var id: String
        var kind: String
        var type: String
        var page: String
        var slug: String
        var anchor: String?
        var of: String?
        var title: String
        var aliases: [String]
        var unlisted: Bool

        enum CodingKeys: String, CodingKey {
            case id, kind, type, page, slug, anchor, of, title, aliases, unlisted
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, or: "")
            kind = c.value(.kind, or: "object")
            type = c.value(.type, or: "")
            page = c.value(.page, or: "")
            slug = c.value(.slug, or: "")
            anchor = c.optional(.anchor)
            of = c.optional(.of)
            title = c.value(.title, or: "")
            aliases = c.value(.aliases, or: [])
            unlisted = c.value(.unlisted, or: false)
        }
    }

    struct RawReduction: Decodable {
        var id: String
        var kind: String
        var hypotheses: [String]
        var conclusion: String
        var reductionClass: String
        var model: String
        var source: [String]
        var via: [String]
        var securityLoss: String
        var status: String
        var page: String
        var slug: String
        var title: String

        // `class` is a Swift keyword.
        enum CodingKeys: String, CodingKey {
            case id, kind, hypotheses, conclusion, model, source, via, securityLoss
            case status, page, slug, title
            case reductionClass = "class"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, or: "")
            kind = c.value(.kind, or: "")
            hypotheses = c.value(.hypotheses, or: [])
            conclusion = c.value(.conclusion, or: "")
            reductionClass = c.value(.reductionClass, or: "")
            model = c.value(.model, or: "")
            source = c.value(.source, or: [])
            via = c.value(.via, or: [])
            securityLoss = c.value(.securityLoss, or: "")
            status = c.value(.status, or: "")
            page = c.value(.page, or: "")
            slug = c.value(.slug, or: "")
            title = c.value(.title, or: "")
        }
    }

    struct RawBarrier: Decodable {
        var id: String
        var hypotheses: [String]
        var conclusion: String
        var reductionClass: String
        var consequences: [RawConsequence]
        var strength: String
        var conditionalOn: [String]
        var source: [String]
        var status: String
        var page: String
        var slug: String
        var title: String

        enum CodingKeys: String, CodingKey {
            case id, hypotheses, conclusion, consequences, strength, conditionalOn
            case source, status, page, slug, title
            case reductionClass = "class"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, or: "")
            hypotheses = c.value(.hypotheses, or: [])
            conclusion = c.value(.conclusion, or: "")
            reductionClass = c.value(.reductionClass, or: "")
            consequences = c.value(.consequences, or: [])
            strength = c.value(.strength, or: "")
            conditionalOn = c.value(.conditionalOn, or: [])
            source = c.value(.source, or: [])
            status = c.value(.status, or: "")
            page = c.value(.page, or: "")
            slug = c.value(.slug, or: "")
            title = c.value(.title, or: "")
        }

        struct RawConsequence: Decodable {
            var kind: String
            var target: String
            var reductionClass: String

            enum CodingKeys: String, CodingKey {
                case kind, target
                case reductionClass = "class"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = c.value(.kind, or: "")
                target = c.value(.target, or: "")
                reductionClass = c.value(.reductionClass, or: "")
            }
        }
    }
}
