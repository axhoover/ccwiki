import Foundation

/// What CCwiki may conclude by chaining the wiki's recorded reductions.
///
/// The specification is plans/derivations.md; its rules are cited here as
/// R1–R14. Its executable form is `scripts/derivations_reference.py`, and the
/// corpus test holds this port to that script's answers through
/// `Tests/CCwikiTests/Fixtures/derivations-golden.json`. Where the prose and
/// the script disagree, the script is right, so this file follows it function
/// by function, including its tie-breaks.
///
/// **A derived relation is a claim CCwiki makes, not one the wiki makes.** A
/// derivation is a proof tree whose internal nodes are recorded reductions,
/// each firing only once *all* its hypotheses are derived (Horn-clause forward
/// chaining), so a conjunction is never split. Nothing here returns an
/// object-to-object pair, and nothing here concludes that something *cannot*
/// be derived: no derivation is never a separation. The only negative results
/// are recorded barriers and the derived barriers R12 builds from them.
///
/// Pure and `Sendable`, with no UI and no I/O, like `PageRelations`. It is
/// built once per manifest load, off the main actor, and precomputes every
/// single-object closure in both model settings, the derived barriers and the
/// inspector's lookups, so a view only ever does dictionary reads.
struct Derivation: Sendable {

    // MARK: Policy (derivations.md §2)

    /// R4. Models whose edges are eligible by default.
    static let defaultModels: Set<String> = ["standard", "quantum", "crs"]
    /// R4. Off by default. A fact derived through one holds only inside that
    /// model (R5).
    static let idealisedModels: Set<String> = ["rom", "generic-group", "algebraic-group", "other"]
    /// R3. A stub's `model` is not evidence, so a stub step carries this one,
    /// which R5 treats as idealised.
    static let unknownModel = "unknown"
    static let standardModel = "standard"
    /// The class sentinel the engine assigns where no class is evidence (R1,
    /// R3), as the reference engine does.
    static let unstatedClass = "unstated"
    /// R4. The model pages (`MODEL_PAGES` in the wiki's
    /// `scripts/participates-in.mjs`). These nodes and their variants are
    /// models, not assumptions: `{rom} ⇒ X` reads "X holds in the
    /// random-oracle model".
    static let modelNodes: [String: String] = [
        "rom": "rom", "ggm": "generic-group", "agm": "algebraic-group",
    ]
    /// R5. A step applied to a model-scoped fact must imply this class.
    static let relativizing = "relativizing"
    /// R2. Node types that never take part in a derivation.
    static let excludedType = "complexity-class"
    /// R10. Node types offered as one-object completions.
    static let completionTypes: Set<String> = ["primitive", "assumption"]
    /// R10 and R11. Display caps.
    static let completionCap = 8
    static let impliedBySingleCap = 40
    static let impliedByGroupCap = 12
    /// R12. Side edges are standard-model only, and every node on a side
    /// chain is a primitive.
    static let sideEdgeModel = "standard"
    static let primitiveType = "primitive"
    /// R8. The barrier class that refutes one named construction only.
    static let fixedConstruction = "fixed-construction"
    /// §2a's sentinel: a reduction whose `securityLoss` names one of these
    /// needs a `requires` entry in the curation.
    static let regimeWords = ["sub-exponential", "subexponential", "quasi-polynomial", "quasipolynomial"]
    /// R14 from the record itself (relations-followups.md §4.4): the sentence
    /// a refutation the manifest records with `refutedBy` reads. The engine
    /// has the manifest but no labels, so it says where the attack is rather
    /// than naming the object.
    static let recordedRefutationText = "Its page records the attack."

    /// The order every id is sorted in: Python's `sorted` on `str`, which
    /// compares code points, which is UTF-8 byte order. `String`'s own `<`
    /// compares canonically equivalent grapheme clusters, which is not the
    /// same order once an id leaves ASCII, and the tie-breaks of R7 must match
    /// the reference engine's exactly.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    // MARK: - Types

    struct Options: Hashable, Sendable {
        /// R4's toggle: also `rom`, `generic-group`, `algebraic-group`,
        /// `other`, and stub steps. What they add is model-scoped (R5).
        var includesIdealisedModels = false

        static let standard = Options()
        static let all = Options(includesIdealisedModels: true)
    }

    /// One directed use of a reduction (R1); an equivalence yields two.
    /// `hypotheses` is the whole conjunction, in the edge's order, never one
    /// hypothesis of it.
    struct Step: Hashable, Sendable, Identifiable {
        let relationID: String
        let hypotheses: [String]
        let conclusion: String
        /// The backward direction of an equivalence: "⇔, used right to left".
        let isReverse: Bool
        /// Effective (R3, R4): `unknown` for a stub, and the model node's own
        /// model for an edge whose sole hypothesis is one.
        let model: String
        /// Effective, per direction (R1, R3).
        let reductionClass: String
        let isStub: Bool
        /// R13: what this step needs of its hypotheses.
        let requirements: [DerivationCuration.Requirement]
        /// R13: this step concludes only a weaker notion.
        let weakening: DerivationCuration.Weakening?

        var id: String { isReverse ? relationID + "~reverse" : relationID }
        var key: StepKey { StepKey(relationID: relationID, isReverse: isReverse) }
        /// R4: eligible with the toggle off.
        var isDefault: Bool { Derivation.defaultModels.contains(model) }
        /// No precondition, no weakened conclusion, not a stub (R12's side
        /// edges).
        var isClean: Bool { requirements.isEmpty && weakening == nil && !isStub }
    }

    struct StepKey: Hashable, Sendable {
        let relationID: String
        let isReverse: Bool
    }

    /// R6, strongest first. A raw-value enum gets no synthesized
    /// `Comparable`, so `<` is written out, by declaration order.
    enum ChainClass: String, Sendable, Comparable, CaseIterable {
        case fullyBlackBox = "fully-black-box", relativizing, free, unstated

        /// The classes closed under composition, strongest first. A chain's
        /// class is the first of these every step's class implies.
        static let composable: [ChainClass] = [.fullyBlackBox, .relativizing, .free]

        var rank: Int {
            switch self {
            case .fullyBlackBox: 0
            case .relativizing: 1
            case .free: 2
            case .unstated: 3
            }
        }

        static func < (lhs: ChainClass, rhs: ChainClass) -> Bool { lhs.rank < rhs.rank }
    }

    struct Fact: Hashable, Sendable {
        let objectID: String
        /// The height of the proof tree; 0 for a given.
        let depth: Int
        /// The step that concluded it; `nil` for a given.
        let step: Step?
        /// The non-standard models the derivation uses (R4).
        let models: Set<String>
        /// R5: the derivation uses an idealised or stub step, so the fact
        /// holds only inside that model.
        let isModelScoped: Bool
        let chainClass: ChainClass
        /// R13: preconditions discharged by assuming them of a given.
        let assumes: Set<DerivationCuration.Requirement>
        /// R13: only this weaker notion is derived.
        let weakening: DerivationCuration.Weakening?
        /// The hypotheses this fact's step consumed in their weakened notion.
        let weakInputs: Set<String>

        var isGiven: Bool { step == nil }

        static func given(_ objectID: String) -> Fact {
            // A given's chain class is fully black-box, the identity of R6's
            // meet: it never weakens the chain it starts.
            Fact(objectID: objectID, depth: 0, step: nil, models: [], isModelScoped: false,
                 chainClass: .fullyBlackBox, assumes: [], weakening: nil, weakInputs: [])
        }
    }

    /// Why a step did not fire. An explanation, never a fact.
    enum Refusal: Hashable, Sendable {
        /// R13: the reduction's recorded hypotheses do not match its Statement.
        case quarantined(reason: String)
        /// R13: a hypothesis is derived only in a weaker notion, and this step
        /// is not one that accepts it.
        case weakened(hypothesis: String, producedBy: String, notion: String)
        /// R13: a hypothesis must be `notion`, and the step that produced it
        /// does not establish that.
        case requires(hypothesis: String, notion: String, producedBy: String)
        /// R5: a hypothesis holds only inside an idealised model, and this
        /// step's class need not carry over into it.
        case idealisedComposition(reductionClass: String, scopedHypotheses: [String])

        /// The reference engine's name for the kind.
        var kind: String {
            switch self {
            case .quarantined: "quarantined"
            case .weakened: "weakened"
            case .requires: "requires"
            case .idealisedComposition: "idealised-composition"
            }
        }
    }

    /// A step R5 or R13 refused.
    struct RefusedStep: Hashable, Sendable {
        let step: Step
        let reasons: [Refusal]
        /// The hypotheses that hold only inside a model (R5), for the refusal
        /// sentence. Empty unless R5 is among the reasons.
        let scopedHypotheses: [String]
        /// In a no-path answer (R10.4): the recorded barriers on the refused
        /// step's own pair, or on (start, its conclusion), which often say
        /// more than the refusal. Sorted.
        let barrierIDs: [String]

        init(step: Step, reasons: [Refusal], barrierIDs: [String] = []) {
            self.step = step
            self.reasons = reasons
            self.barrierIDs = barrierIDs
            var scoped: [String] = []
            for reason in reasons {
                if case .idealisedComposition(_, let hypotheses) = reason {
                    scoped = hypotheses
                    break
                }
            }
            self.scopedHypotheses = scoped
        }
    }

    struct ProofTree: Hashable, Sendable {
        /// Depth-first, hypotheses in the edge's order (R7). A fact appears
        /// once with its subtree; a later occurrence is a reference.
        struct Row: Hashable, Sendable, Identifiable {
            /// Position in `rows`.
            let id: Int
            let objectID: String
            /// 0 for the target.
            let level: Int
            /// `nil` for a given or a reference.
            let step: Step?
            /// "shown above".
            let isReference: Bool
            let isGiven: Bool
            /// This row is the fact's weakened notion (R13).
            let isWeakened: Bool
            /// This row's own step's preconditions that the derivation assumes
            /// of a given: "assuming …" belongs on this row (R13).
            let assumed: [DerivationCuration.Requirement]
            /// "only …" (R13).
            let weakening: DerivationCuration.Weakening?
        }

        let rows: [Row]
        /// Distinct, sorted: the N of "from N recorded reductions". An
        /// equivalence used both ways counts once.
        let relationIDs: [String]
        /// The reductions used right to left, sorted.
        let reverseRelationIDs: [String]

        init(rows: [Row]) {
            self.rows = rows
            var ids: Set<String> = []
            var reverse: Set<String> = []
            for row in rows {
                guard let step = row.step else { continue }
                ids.insert(step.relationID)
                if step.isReverse { reverse.insert(step.relationID) }
            }
            self.relationIDs = ids.sorted(by: Derivation.precedes)
            self.reverseRelationIDs = reverse.sorted(by: Derivation.precedes)
        }

        /// R3: a stub step is in the tree.
        var usesStub: Bool { rows.contains { $0.step?.isStub ?? false } }
    }

    struct Closure: Sendable {
        let start: Set<String>
        let options: Options
        /// Full notions, the start included at depth 0.
        let facts: [String: Fact]
        /// R13: objects derived only in a weakened notion. Kept apart, so a
        /// weakened fact never blocks a full one.
        let weakFacts: [String: Fact]
        /// Steps R5 or R13 refused on the way, each with its first reason,
        /// sorted by reduction id.
        let refused: [RefusedStep]

        /// The full fact if there is one, else the weakened one.
        func fact(_ id: String) -> Fact? { facts[id] ?? weakFacts[id] }

        /// The proof of `id`: depth-first, hypotheses in the edge's order, a
        /// fact already shown becoming a reference. A row that consumed a
        /// weakened fact walks to that fact, not to a later full one.
        func proof(of id: String) -> ProofTree? {
            guard facts[id] != nil || weakFacts[id] != nil else { return nil }
            var rows: [ProofTree.Row] = []
            var seen: Set<RowKey> = []

            func walk(_ factID: String, weakened: Bool, level: Int) {
                guard let fact = weakened ? weakFacts[factID] : facts[factID] else { return }
                let key = RowKey(objectID: factID, isWeakened: weakened)
                let isReference = seen.contains(key)
                seen.insert(key)
                let rowStep: Step? = isReference ? nil : fact.step
                let assumed = rowStep?.requirements.filter { fact.assumes.contains($0) } ?? []
                rows.append(ProofTree.Row(
                    id: rows.count, objectID: factID, level: level, step: rowStep,
                    isReference: isReference, isGiven: fact.step == nil, isWeakened: weakened,
                    assumed: assumed, weakening: fact.weakening))
                guard let step = rowStep else { return }
                for hypothesis in step.hypotheses {
                    walk(hypothesis, weakened: fact.weakInputs.contains(hypothesis), level: level + 1)
                }
            }

            walk(id, weakened: facts[id] == nil, level: 0)
            return ProofTree(rows: rows)
        }

        private struct RowKey: Hashable {
            let objectID: String
            let isWeakened: Bool
        }
    }

    /// R6: a derivation of the same notion in a stronger class, when the
    /// shortest one is weaker.
    struct StrongerChain: Hashable, Sendable {
        let chainClass: ChainClass
        let depth: Int
        let proof: ProofTree
    }

    /// One derived row for the inspector.
    ///
    /// `fact` may be a weakened one (R13) when the object is derived only in
    /// a weaker notion; its `weakening` names that notion, and a row must say
    /// "only …" rather than show it as the full node.
    struct Link: Hashable, Sendable, Identifiable {
        /// The far end.
        let objectID: String
        /// The derived end's.
        let fact: Fact
        let relationCount: Int
        var id: String { objectID }
    }

    /// Why a reduction is not an eligible step (R1–R4, R13), in the
    /// reference engine's words.
    enum Exclusion: String, Sendable, CaseIterable {
        case inclusion
        case heuristic
        case complexityClassEndpoint = "complexity-class-endpoint"
        case unresolvedEndpoint = "unresolved-endpoint"
        case concludesAModel = "concludes-a-model"
        case quarantined
    }

    // MARK: - Stored

    let manifest: RelationsManifest
    let curation: DerivationCuration
    /// R1–R4 and R13's quarantine: every eligible directed step, sorted by
    /// reduction id, forward before reverse.
    let steps: [Step]
    /// R4: the steps eligible with the toggle off (no stub).
    let defaultSteps: [Step]
    /// R13: steps whose reduction is quarantined. Never used, but named in
    /// answers.
    let quarantinedSteps: [Step]
    let excluded: [Exclusion: [String]]
    /// R1: equivalences the curation has not reviewed, unstated both ways.
    let unreviewedEquivalences: [String]
    let stepsByKey: [StepKey: Step]

    let classOrder: ClassOrder
    /// Every eligible step, under R5 and R13.
    let mainEngine: Engine
    /// R6: only the steps whose class implies each composable class.
    let restrictedEngines: [Engine]
    /// R8: standard-model, non-stub steps of each composable class, assuming
    /// nothing.
    let cleanEngines: [Engine]
    /// R8: the same with unstated steps too, which count against a `free`
    /// barrier.
    let cleanAnyEngine: Engine
    /// Plain Horn closure, quarantined steps included and no rule applied:
    /// what R5 and R13 refused is read off its trees.
    let relaxedEngine: Engine
    /// R12: one rule per propagating (barrier, consequence).
    let barrierRules: [BarrierRule]

    private let singleClosures: [Options: [String: Closure]]
    private let participantSets: [Options: Set<String>]
    /// R12, all of them: every single-object derived barrier, with its
    /// circumventions and redundancy worked out for its pair.
    private(set) var derivedBarriers: [DerivedBarrier] = []
    private var linkTables: [Options: LinkTable] = [:]

    /// The curation's citations whose quote is no longer on its page in this
    /// clone (relations-followups.md §2.5). The bundled curation stays as
    /// reviewed while the wiki syncs daily, so the explorer says so beside
    /// the quote instead of showing it as the page's text.
    ///
    /// Set on every library load from `missingQuotes(pageText:)`: by
    /// `AppModel.loadLibrary` today, and by `LoadedLibrary.build` and
    /// `.update` after reader-comforts, also when `update` reuses the
    /// derivation. It depends on page text, not on the manifest, so nothing
    /// in `init` can know it; empty means every quote was found, or the
    /// check has not run.
    var unverifiedCitations: Set<DerivationCuration.Citation> = []

    private struct LinkTable: Sendable {
        var implications: [String: [Link]] = [:]
        var sources: [String: [Link]] = [:]
    }

    static let empty = Derivation(manifest: .empty, curation: .empty)

    // MARK: - Building

    /// With the curation the app ships. Without one, nothing is derived:
    /// chaining without its corrections proves claims the cited theorems do
    /// not (`DerivationCuration.bundled`).
    init(manifest: RelationsManifest) {
        if let curation = DerivationCuration.bundled {
            self.init(manifest: manifest, curation: curation)
        } else {
            self.init(manifest: .empty, curation: .empty)
        }
    }

    init(manifest: RelationsManifest, curation: DerivationCuration) {
        // R14 from the record: a manifest's `refutedBy` joins the working
        // curation before anything reads it, and wins over the file's entry
        // for the same object, so every rule that reads `refuted` applies it
        // with no edit of its own (relations-followups.md §4.4).
        let working = curation.adding(refutations: Self.recordedRefutations(in: manifest))
        let table = StepTable(manifest: manifest, curation: working)
        let objects = ObjectTable(manifest: manifest)
        let order = ClassOrder(manifest: manifest)

        let compiled = table.steps.compactMap { CompiledStep($0, objects: objects, order: order) }
        let compiledQuarantined = table.quarantined.compactMap {
            CompiledStep($0, objects: objects, order: order)
        }
        let standard = Derivation.standardModel

        let main = Engine(objects: objects, steps: compiled, order: order,
                          allowsAssuming: true, appliesRules: true)
        var restricted: [Engine] = []
        var clean: [Engine] = []
        for chain in ChainClass.composable {
            let ofClass = compiled.filter { order.implies($0.step.reductionClass, chain.rawValue) }
            restricted.append(Engine(objects: objects, steps: ofClass, order: order,
                                     allowsAssuming: true, appliesRules: true))
            let cleanOfClass = ofClass.filter { $0.step.model == standard && !$0.step.isStub }
            clean.append(Engine(objects: objects, steps: cleanOfClass, order: order,
                                allowsAssuming: false, appliesRules: true))
        }
        let cleanAny = Engine(
            objects: objects,
            steps: compiled.filter { $0.step.model == standard && !$0.step.isStub },
            order: order, allowsAssuming: false, appliesRules: true)
        let relaxed = Engine(objects: objects, steps: compiled + compiledQuarantined, order: order,
                             allowsAssuming: true, appliesRules: false)

        var singles: [Options: [String: Closure]] = [:]
        var participants: [Options: Set<String>] = [:]
        for options in [Options.standard, Options.all] {
            var byObject: [String: Closure] = [:]
            for id in objects.ids {
                byObject[id] = main.closure(from: [id], options: options)
            }
            singles[options] = byObject
            var endpoints: Set<String> = []
            for step in options.includesIdealisedModels ? table.steps : table.defaultSteps {
                endpoints.formUnion(step.hypotheses)
                endpoints.insert(step.conclusion)
            }
            participants[options] = endpoints
        }

        var byKey: [StepKey: Step] = [:]
        for step in table.steps + table.quarantined { byKey[step.key] = step }

        self.manifest = manifest
        self.curation = working
        self.steps = table.steps
        self.defaultSteps = table.defaultSteps
        self.quarantinedSteps = table.quarantined
        self.excluded = table.excluded
        self.unreviewedEquivalences = table.unreviewed
        self.stepsByKey = byKey
        self.classOrder = order
        self.mainEngine = main
        self.restrictedEngines = restricted
        self.cleanEngines = clean
        self.cleanAnyEngine = cleanAny
        self.relaxedEngine = relaxed
        self.barrierRules = BarrierRule.rules(manifest: manifest, steps: table.steps, order: order)
        self.singleClosures = singles
        self.participantSets = participants

        // Everything stored is set; what follows reads `self`.
        derivedBarriers = allDerivedBarriers()
        linkTables = [.standard: makeLinkTable(.standard), .all: makeLinkTable(.all)]
    }

    // MARK: - Queries

    /// Everything `start` derives (R7), the start included at depth 0. A
    /// single object's closure is precomputed.
    func closure(from start: Set<String>, options: Options) -> Closure {
        if start.count == 1, let id = start.first, let cached = singleClosures[options]?[id] {
            return cached
        }
        return mainEngine.closure(from: start, options: options)
    }

    /// Endpoints of an eligible step under `options`; never a complexity
    /// class (R2).
    func participants(_ options: Options) -> Set<String> {
        participantSets[options] ?? []
    }

    /// `rom`, `ggm`, `agm` and their variants (R4).
    func isModelNode(_ id: String) -> Bool {
        Self.modelOfNode(id, in: manifest) != nil
    }

    /// What `id` alone derives at depth ≥ 2, sorted by (depth, id). A lookup.
    /// Depth 1 is a recorded step, which the recorded groups already show.
    func derivedImplications(of id: String, options: Options) -> [Link] {
        linkTables[options]?.implications[id] ?? []
    }

    /// What alone derives `id` at depth ≥ 2, sorted by (depth, id). A lookup.
    /// Like R11's single sources, it never lists a complexity class, a model
    /// node, a refuted object or a setting.
    func derivedSources(of id: String, options: Options) -> [Link] {
        linkTables[options]?.sources[id] ?? []
    }

    // MARK: - Helpers

    /// R4: the model a model node stands for, or `nil`.
    static func modelOfNode(_ id: String, in manifest: RelationsManifest) -> String? {
        if let model = modelNodes[id] { return model }
        if let object = manifest.object(id), object.isVariant, let host = object.of {
            return modelNodes[host]
        }
        return nil
    }

    /// R14 from the record (relations-followups.md §4.4, wiki-asks.md ask 2):
    /// each object whose manifest record carries `refutedBy`, as a
    /// refutation. Its source is the entries' citation keys, so the verdict
    /// names the key once; its evidence, the entries as recorded. Sorted by
    /// object id.
    static func recordedRefutations(in manifest: RelationsManifest) -> [DerivationCuration.Refutation] {
        let ids = manifest.objectsByID.keys.sorted(by: Derivation.precedes)
        return ids.compactMap { id -> DerivationCuration.Refutation? in
            guard let object = manifest.object(id), !object.refutedBy.isEmpty else { return nil }
            let keys = object.refutedBy.compactMap { RelationText.citationKey($0) }
            return DerivationCuration.Refutation(
                objectID: id, source: keys.joined(separator: ", "),
                text: Derivation.recordedRefutationText,
                evidence: object.refutedBy.joined(separator: ", "))
        }
    }

    /// The node's `type`, or "" when the manifest does not know it.
    func nodeType(_ id: String) -> String {
        manifest.object(id)?.type ?? ""
    }

    /// `narrower` implies* `broader`, reflexively, by the manifest's own
    /// order; a sentinel or an unknown class implies nothing.
    func implies(_ narrower: String, _ broader: String) -> Bool {
        classOrder.implies(narrower, broader)
    }

    /// R7's tie-break among candidates for one fact at one layer: fewer
    /// non-standard models, then fewer assumed preconditions, then the
    /// stronger chain class, then the reduction id by UTF-8 bytes, then
    /// forward before reverse.
    static func isPreferred(_ a: Fact, over b: Fact) -> Bool {
        if a.models.count != b.models.count { return a.models.count < b.models.count }
        if a.assumes.count != b.assumes.count { return a.assumes.count < b.assumes.count }
        if a.chainClass != b.chainClass { return a.chainClass < b.chainClass }
        let left = a.step?.relationID ?? ""
        let right = b.step?.relationID ?? ""
        if precedes(left, right) { return true }
        if precedes(right, left) { return false }
        return !(a.step?.isReverse ?? false) && (b.step?.isReverse ?? false)
    }

    /// Steps in the reference engine's order: reduction id, then forward
    /// before reverse.
    static func stepPrecedes(_ a: Step, _ b: Step) -> Bool {
        if precedes(a.relationID, b.relationID) { return true }
        if precedes(b.relationID, a.relationID) { return false }
        return !a.isReverse && b.isReverse
    }

    private static func linkPrecedes(_ a: Link, _ b: Link) -> Bool {
        if a.fact.depth != b.fact.depth { return a.fact.depth < b.fact.depth }
        return precedes(a.objectID, b.objectID)
    }

    /// R11's sources: never a class, a model node, a refuted object or a
    /// setting.
    func isSingleSource(_ id: String) -> Bool {
        nodeType(id) != Self.excludedType && !isModelNode(id)
            && curation.refuted[id] == nil && curation.settings[id] == nil
    }

    private func makeLinkTable(_ options: Options) -> LinkTable {
        var table = LinkTable()
        guard let closures = singleClosures[options] else { return table }
        for start in closures.keys.sorted(by: Self.precedes) {
            guard let closure = closures[start] else { continue }
            var links: [Link] = []
            let ids = Set(closure.facts.keys).union(closure.weakFacts.keys)
            for objectID in ids {
                guard let fact = closure.fact(objectID), fact.depth >= 2 else { continue }
                let count = closure.proof(of: objectID)?.relationIDs.count ?? 0
                links.append(Link(objectID: objectID, fact: fact, relationCount: count))
            }
            guard !links.isEmpty else { continue }
            links.sort(by: Self.linkPrecedes)
            table.implications[start] = links
            guard isSingleSource(start) else { continue }
            for link in links {
                table.sources[link.objectID, default: []].append(
                    Link(objectID: start, fact: link.fact, relationCount: link.relationCount))
            }
        }
        table.sources = table.sources.mapValues { $0.sorted(by: Self.linkPrecedes) }
        return table
    }
}

// MARK: - Eligible steps (R1–R4, R13)

extension Derivation {

    /// The reductions as directed Horn clauses: what is eligible, what is
    /// quarantined, and why the rest is not.
    struct StepTable {
        var steps: [Step] = []
        var quarantined: [Step] = []
        var excluded: [Exclusion: [String]] = [:]
        var unreviewed: [String] = []

        var defaultSteps: [Step] { steps.filter { $0.isDefault && !$0.isStub } }

        private struct Direction {
            let isReverse: Bool
            let hypotheses: [String]
            let conclusion: String
            let reductionClass: String
        }

        init(manifest: RelationsManifest, curation: DerivationCuration) {
            // One record per id, as the reference engine's dictionary keeps.
            let ids = Set(manifest.reductions.map { $0.id }).sorted(by: Derivation.precedes)
            for id in ids {
                guard let relation = manifest.reduction(id) else { continue }
                let ends = relation.hypotheses + [relation.conclusion]
                // R1: containment is not implication.
                if relation.kind == .inclusion {
                    excluded[.inclusion, default: []].append(id)
                    continue
                }
                // R1: "an edge of the graph, not a theorem".
                if relation.heuristic {
                    excluded[.heuristic, default: []].append(id)
                    continue
                }
                // R2: classes are related by containment, not derived.
                if ends.contains(where: { manifest.object($0)?.type == Derivation.excludedType }) {
                    excluded[.complexityClassEndpoint, default: []].append(id)
                    continue
                }
                if ends.contains(where: { manifest.object($0) == nil }) {
                    excluded[.unresolvedEndpoint, default: []].append(id)
                    continue
                }
                // R4: a model is never concluded.
                if Derivation.modelOfNode(relation.conclusion, in: manifest) != nil {
                    excluded[.concludesAModel, default: []].append(id)
                    continue
                }

                var model = relation.model
                var reductionClass = relation.reductionClass
                let isStub = relation.status == .stub
                // R4: an edge whose sole hypothesis is a model node is in that
                // model, whatever its record says.
                if relation.hypotheses.count == 1,
                   let nodeModel = Derivation.modelOfNode(relation.hypotheses[0], in: manifest) {
                    model = nodeModel
                }
                // R3: a stub's class and model are not evidence.
                if isStub {
                    model = Derivation.unknownModel
                    reductionClass = Derivation.unstatedClass
                }

                var directions = [Direction(
                    isReverse: false, hypotheses: relation.hypotheses,
                    conclusion: relation.conclusion, reductionClass: reductionClass)]
                // R1: both directions of an equivalence, each with its own
                // class. A record that states its reverse class says which is
                // which itself (wiki-asks.md ask 1), and the curation's table
                // is not read for it; R3 still makes a stub unstated both
                // ways. Otherwise a direction takes the record's class only
                // where the curation says `record`.
                if relation.kind == .equivalence, let first = relation.hypotheses.first {
                    let forwardClass: String
                    let reverseClass: String
                    if let recorded = relation.reverseClass {
                        forwardClass = reductionClass
                        reverseClass = isStub ? Derivation.unstatedClass : recorded
                    } else if let reviewed = curation.equivalences[id] {
                        forwardClass = reviewed.isForwardRecorded ? reductionClass : Derivation.unstatedClass
                        reverseClass = reviewed.isReverseRecorded ? reductionClass : Derivation.unstatedClass
                    } else {
                        unreviewed.append(id)
                        forwardClass = Derivation.unstatedClass
                        reverseClass = Derivation.unstatedClass
                    }
                    directions = [
                        Direction(isReverse: false, hypotheses: relation.hypotheses,
                                  conclusion: relation.conclusion, reductionClass: forwardClass),
                        Direction(isReverse: true, hypotheses: [relation.conclusion],
                                  conclusion: first, reductionClass: reverseClass),
                    ]
                }

                // R13: hypotheses that do not match the Statement.
                let isQuarantined = curation.quarantine[id] != nil
                for direction in directions {
                    let step = Step(
                        relationID: id,
                        hypotheses: direction.hypotheses,
                        conclusion: direction.conclusion,
                        isReverse: direction.isReverse,
                        model: model,
                        reductionClass: direction.reductionClass,
                        isStub: isStub,
                        requirements: curation.requirements(on: id, isReverse: direction.isReverse),
                        weakening: direction.isReverse ? nil : curation.weakens[id])
                    if isQuarantined {
                        quarantined.append(step)
                    } else {
                        steps.append(step)
                    }
                }
                if isQuarantined {
                    excluded[.quarantined, default: []].append(id)
                }
            }
        }
    }

    /// Object ids as dense indexes, so the inner loop of a closure reads
    /// arrays instead of hashing strings.
    struct ObjectTable: Sendable {
        let ids: [String]
        let index: [String: Int]

        init(manifest: RelationsManifest) {
            let ids = manifest.objectsByID.keys.sorted(by: Derivation.precedes)
            var index: [String: Int] = [:]
            for (position, id) in ids.enumerated() { index[id] = position }
            self.ids = ids
            self.index = index
        }
    }

    /// The manifest's class order, with what the inner loop asks of it
    /// precomputed: which composable classes each class implies (R6), as a
    /// bit mask.
    struct ClassOrder: Sendable {
        private let manifest: RelationsManifest
        private let masks: [String: UInt8]

        init(manifest: RelationsManifest) {
            var masks: [String: UInt8] = [:]
            for name in manifest.classes.keys {
                var mask: UInt8 = 0
                for (bit, chain) in ChainClass.composable.enumerated()
                where Self.implies(name, chain.rawValue, in: manifest) {
                    mask |= UInt8(1) << bit
                }
                masks[name] = mask
            }
            self.manifest = manifest
            self.masks = masks
        }

        /// The reference engine's `implies`: reflexive, by the manifest's own
        /// closure, and false for a sentinel or a class the manifest does not
        /// define.
        static func implies(_ narrower: String, _ broader: String,
                            in manifest: RelationsManifest) -> Bool {
            guard manifest.classes[narrower] != nil, manifest.classes[broader] != nil else {
                return false
            }
            return manifest.reductionClass(narrower, implies: broader)
        }

        func implies(_ narrower: String, _ broader: String) -> Bool {
            Self.implies(narrower, broader, in: manifest)
        }

        /// Bit `i` is set when `name` implies `ChainClass.composable[i]`.
        func mask(_ name: String) -> UInt8 { masks[name] ?? 0 }

        /// R6: the first composable class every class in the meet implies.
        static func chainClass(mask: UInt8) -> ChainClass {
            for (bit, chain) in ChainClass.composable.enumerated()
            where mask & (UInt8(1) << bit) != 0 {
                return chain
            }
            return .unstated
        }
    }

    /// A step with its endpoints as object indexes and its class tests done.
    struct CompiledStep: Sendable {
        let step: Step
        let hypotheses: [Int]
        let conclusion: Int
        /// R6: the composable classes this step's class implies.
        let mask: UInt8
        /// R5: this step may fire on a model-scoped fact.
        let relativizes: Bool

        init?(_ step: Step, objects: ObjectTable, order: ClassOrder) {
            var hypotheses: [Int] = []
            for id in step.hypotheses {
                guard let index = objects.index[id] else { return nil }
                hypotheses.append(index)
            }
            guard let conclusion = objects.index[step.conclusion] else { return nil }
            self.step = step
            self.hypotheses = hypotheses
            self.conclusion = conclusion
            self.mask = order.mask(step.reductionClass)
            self.relativizes = order.implies(step.reductionClass, Derivation.relativizing)
        }
    }
}

// MARK: - Forward chaining (R4, R5, R7, R13)

extension Derivation {

    /// Layered forward chaining over one set of steps.
    ///
    /// The derivation keeps several: the main one, and the restricted ones
    /// R6 and R8 rerun the closure over. Each runs up to three phases (R4):
    /// the default steps with nothing assumed, the default steps with a
    /// precondition on a given assumable (R13), and, with the toggle, every
    /// eligible step. A later phase never replaces a fact an earlier one
    /// found, so turning the toggle on only adds facts, and a fact with a
    /// derivation that needs no assumption shows that derivation.
    struct Engine: Sendable {
        let objects: ObjectTable
        let steps: [CompiledStep]
        let defaultSteps: [CompiledStep]
        /// Phase 2 runs. Off for R8's clean closures.
        let allowsAssuming: Bool
        /// R5 and R13 apply. Off for the relaxed closure, which is plain Horn
        /// closure.
        let appliesRules: Bool
        /// Each chain class's mask, by `ChainClass.rank`.
        private let chainMasks: [UInt8]

        init(objects: ObjectTable, steps: [CompiledStep], order: ClassOrder,
             allowsAssuming: Bool, appliesRules: Bool) {
            self.objects = objects
            self.steps = steps
            self.defaultSteps = steps.filter { $0.step.isDefault && !$0.step.isStub }
            self.allowsAssuming = allowsAssuming
            self.appliesRules = appliesRules
            self.chainMasks = ChainClass.allCases.map { order.mask($0.rawValue) }
        }

        func closure(from start: Set<String>, options: Options) -> Closure {
            var state = State(count: objects.ids.count)
            // Every start is a given fact. A model node given as a start (R4)
            // is not itself model-scoped: the steps leaving it are the
            // idealised ones, and what they conclude is.
            var outside: [String: Fact] = [:]
            for id in start {
                if let index = objects.index[id] {
                    state.add(Fact.given(id), at: index)
                } else {
                    outside[id] = Fact.given(id)
                }
            }
            run(&state, defaultSteps, phase: 1)
            if allowsAssuming {
                run(&state, defaultSteps, phase: 2)
            }
            if options.includesIdealisedModels {
                run(&state, steps, phase: 3)
            }

            var facts = outside
            var weakFacts: [String: Fact] = [:]
            for (index, id) in objects.ids.enumerated() {
                if let fact = state.facts[index] { facts[id] = fact }
                if let fact = state.weak[index] { weakFacts[id] = fact }
            }
            let refused = state.blocked.values.sorted { Derivation.stepPrecedes($0.step, $1.step) }
            return Closure(start: start, options: options, facts: facts, weakFacts: weakFacts,
                           refused: refused)
        }

        private struct State {
            var facts: [Fact?]
            var depths: [Int]
            var weak: [Fact?]
            var weakDepths: [Int]
            var deepest = 0
            /// The first refusal of each step.
            var blocked: [StepKey: RefusedStep] = [:]

            init(count: Int) {
                facts = Array(repeating: nil, count: count)
                depths = Array(repeating: -1, count: count)
                weak = Array(repeating: nil, count: count)
                weakDepths = Array(repeating: -1, count: count)
            }

            mutating func add(_ fact: Fact, at index: Int) {
                facts[index] = fact
                depths[index] = fact.depth
                deepest = max(deepest, fact.depth)
            }

            mutating func addWeak(_ fact: Fact, at index: Int) {
                weak[index] = fact
                weakDepths[index] = fact.depth
                deepest = max(deepest, fact.depth)
            }

            mutating func block(_ step: Step, _ refusal: Refusal) {
                if blocked[step.key] == nil {
                    blocked[step.key] = RefusedStep(step: step, reasons: [refusal])
                }
            }
        }

        private enum Check {
            case fires(Set<DerivationCuration.Requirement>)
            /// Not yet: a precondition on a given waits for phase 2.
            case waits
            case refused(Refusal)
        }

        /// A step fires at layer k when every hypothesis is known with depth
        /// < k; each new fact takes the preferred candidate among the steps
        /// firing at its first layer, and never changes after. A weakened
        /// fact (R13) is kept apart and never blocks a full one.
        private func run(_ state: inout State, _ steps: [CompiledStep], phase: Int) {
            var layer = 0
            while true {
                layer += 1
                var candidates: [Int: Fact] = [:]
                var weakCandidates: [Int: Fact] = [:]
                for compiled in steps {
                    let makesWeak = appliesRules && compiled.step.weakening != nil
                    if state.depths[compiled.conclusion] >= 0 { continue }
                    if makesWeak && state.weakDepths[compiled.conclusion] >= 0 { continue }

                    // Every hypothesis known before this layer: in full, or
                    // weakened for a step the weakening accepts.
                    var ready = true
                    for index in compiled.hypotheses {
                        let depth = state.depths[index]
                        if depth >= 0 && depth < layer { continue }
                        let weakDepth = state.weakDepths[index]
                        if weakDepth >= 0 && weakDepth < layer, let weak = state.weak[index] {
                            if weak.weakening?.acceptedBy.contains(compiled.step.relationID) == true {
                                continue
                            }
                            state.block(compiled.step, .weakened(
                                hypothesis: weak.objectID,
                                producedBy: weak.step?.relationID ?? "",
                                notion: weak.weakening?.notion ?? ""))
                        }
                        ready = false
                        break
                    }
                    guard ready else { continue }

                    var inputs: [Fact] = []
                    var weakInputs: Set<String> = []
                    for index in compiled.hypotheses {
                        let depth = state.depths[index]
                        if depth >= 0 && depth < layer, let fact = state.facts[index] {
                            inputs.append(fact)
                        } else if let weak = state.weak[index] {
                            inputs.append(weak)
                            weakInputs.insert(weak.objectID)
                        }
                    }

                    switch check(compiled, inputs, phase: phase) {
                    case .waits:
                        break
                    case .refused(let refusal):
                        state.block(compiled.step, refusal)
                    case .fires(let assumes):
                        let candidate = fact(compiled, inputs: inputs, weakInputs: weakInputs,
                                             depth: layer, assumes: assumes, makesWeak: makesWeak)
                        if makesWeak {
                            Self.keepPreferred(candidate, at: compiled.conclusion, in: &weakCandidates)
                        } else {
                            Self.keepPreferred(candidate, at: compiled.conclusion, in: &candidates)
                        }
                    }
                }
                for (index, fact) in candidates { state.add(fact, at: index) }
                for (index, fact) in weakCandidates { state.addWeak(fact, at: index) }
                if candidates.isEmpty && weakCandidates.isEmpty && layer > state.deepest {
                    return
                }
            }
        }

        private static func keepPreferred(_ candidate: Fact, at index: Int,
                                          in table: inout [Int: Fact]) {
            if let current = table[index], !Derivation.isPreferred(candidate, over: current) {
                return
            }
            table[index] = candidate
        }

        /// R13, then R5: may this step fire on these facts?
        private func check(_ compiled: CompiledStep, _ inputs: [Fact], phase: Int) -> Check {
            guard appliesRules else { return .fires([]) }
            let step = compiled.step
            var assumes: Set<DerivationCuration.Requirement> = []
            for requirement in step.requirements {
                guard let position = step.hypotheses.firstIndex(of: requirement.hypothesis),
                      position < inputs.count
                else { continue }
                let input = inputs[position]
                guard let producer = input.step else {
                    // A given: assumable, but only once a derivation that
                    // needs no assumption has had its chance (phase 2).
                    if phase >= 2 && allowsAssuming {
                        assumes.insert(requirement)
                        continue
                    }
                    return .waits
                }
                if requirement.metBy.contains(producer.relationID) { continue }
                return .refused(.requires(hypothesis: requirement.hypothesis,
                                          notion: requirement.notion,
                                          producedBy: producer.relationID))
            }
            // R5: only a relativizing step carries a fact into an idealised
            // model's world.
            if !compiled.relativizes && inputs.contains(where: { $0.isModelScoped }) {
                let scoped = inputs.filter { $0.isModelScoped }.map { $0.objectID }
                return .refused(.idealisedComposition(reductionClass: step.reductionClass,
                                                      scopedHypotheses: scoped))
            }
            return .fires(assumes)
        }

        private func fact(_ compiled: CompiledStep, inputs: [Fact], weakInputs: Set<String>,
                          depth: Int, assumes: Set<DerivationCuration.Requirement>,
                          makesWeak: Bool) -> Fact {
            let step = compiled.step
            var models: Set<String> = []
            var allAssumes = assumes
            var mask = compiled.mask
            var isScoped = Derivation.idealisedModels.contains(step.model)
                || step.model == Derivation.unknownModel
            for input in inputs {
                models.formUnion(input.models)
                allAssumes.formUnion(input.assumes)
                mask &= chainMasks[input.chainClass.rank]
                if input.isModelScoped { isScoped = true }
            }
            if step.model != Derivation.standardModel {
                models.insert(step.model)
            }
            return Fact(
                objectID: step.conclusion, depth: depth, step: step, models: models,
                isModelScoped: isScoped, chainClass: ClassOrder.chainClass(mask: mask),
                assumes: allAssumes, weakening: makesWeak ? step.weakening : nil,
                weakInputs: weakInputs)
        }
    }
}
