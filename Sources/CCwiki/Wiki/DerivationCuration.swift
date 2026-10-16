import Foundation

/// CCwiki's reviewed corrections for deriving relations:
/// `Resources/derivation-curation.json` (plans/derivations.md §2a).
///
/// **Why a second input exists at all.** A manifest node is a page or a page
/// section, and a theorem often needs more of its hypothesis than the node
/// defines (a hardness regime, a field, a group) or proves less of its
/// conclusion (selective rather than adaptive security). `relations.json`
/// records neither, so chaining across such a gap proves things the cited
/// theorems do not. Each entry here closes one gap the review found, and each
/// cites the wiki's own text; CCwiki never adds a condition the wiki does not
/// state.
///
/// It is read once from the app bundle, where `build.sh` copies it, and from
/// the source tree when there is no bundle (tests, `swift run`). The reference
/// engine, `scripts/derivations_reference.py`, reads the same file, which is
/// why the corpus test can hold the two to the same answers.
struct DerivationCuration: Sendable {

    /// R13. A step's hypothesis must be a stronger notion than its node
    /// defines. The step fires only when a reduction in `metBy`, whose own
    /// Statement establishes the notion, concludes the hypothesis anywhere
    /// in the closure: not necessarily the step that gave it its fact, since
    /// each such producer keeps a fact of its own (`Closure.established`).
    /// Failing that, a given hypothesis is assumed, in phase 2, and the
    /// derivation carries "assuming `notion`". Anything else is refused.
    struct Requirement: Hashable, Sendable {
        let relationID: String
        /// The backward direction of an equivalence.
        let isReverse: Bool
        let hypothesis: String
        let notion: String
        let metBy: Set<String>
        /// `notion` for the proof copies: plain text and `$…$` math in the
        /// wiki's macros, and nothing else, because the LaTeX writer only
        /// escapes text and expands math. The app's chrome keeps `notion`.
        var notionMarkdown: String? = nil
    }

    /// R13. A step concludes only a weaker notion than its node defines. Its
    /// fact is kept apart from the node's full one, and only the reductions
    /// in `acceptedBy` may consume it.
    struct Weakening: Hashable, Sendable {
        let relationID: String
        let notion: String
        let acceptedBy: Set<String>
        /// As `Requirement.notionMarkdown`.
        var notionMarkdown: String? = nil
    }

    /// R14. An object the wiki says is false. A query from it is answered,
    /// and marked vacuous.
    struct Refutation: Hashable, Sendable {
        let objectID: String
        /// The citation key that refutes it, such as `AMYY25`.
        let source: String
        /// The sentence the UI shows, in the wiki's words.
        let text: String
        let evidence: String
    }

    /// R14. A corruption setting in which a primitive exists unconditionally,
    /// such as honest-majority MPC: not an assumption, so never a completion,
    /// and listed apart in the backward closure.
    struct Setting: Hashable, Sendable {
        let objectID: String
        let text: String
        let evidence: String
    }

    /// R1. Which directions of an equivalence take the record's `class`. The
    /// two directions can be different theorems; a direction marked anything
    /// but `record` is `unstated`.
    struct Directions: Hashable, Sendable {
        let forward: String
        let reverse: String

        static let recorded = "record"

        var isForwardRecorded: Bool { forward == Self.recorded }
        var isReverseRecorded: Bool { reverse == Self.recorded }
    }

    /// The file's refutations, and a manifest's own once `adding(refutations:)`
    /// has merged them.
    private(set) var refuted: [String: Refutation]
    let settings: [String: Setting]
    /// R13: reduction id → why its recorded hypotheses do not match its own
    /// Statement. A quarantined reduction is never used. Ask a step with
    /// `quarantineReason(_:isReverse:)`: an entry may hold back one direction
    /// of an equivalence only.
    let quarantine: [String: String]
    /// R13: the quarantine entries scoped to one direction of an equivalence,
    /// reduction id → `true` for the reverse direction, `false` for the
    /// forward one. A reduction absent here is quarantined whole.
    let quarantineDirections: [String: Bool]
    /// R13: the quarantine entries whose `direction` is neither `forward`
    /// nor `reverse`, by reduction id. Each reads as forward, as the
    /// reference engine reads it, and `unresolved(in:)` reports it.
    let misspeltDirections: Set<String>
    let equivalences: [String: Directions]
    /// In the file's order.
    let requires: [Requirement]
    let weakens: [String: Weakening]
    /// Reduction id → why a Statement-lint hit on it is not a dropped
    /// conjunct: the entry's note, whichever form the file gives it in.
    let statementLint: [String: String]

    /// Every entry of the file, each with the wiki text it rests on, in the
    /// order of plans/relations-followups.md §2.2: refuted, settings,
    /// quarantine, equivalences, requires, statementLint, weakens. A manifest
    /// refutation merged by `adding(refutations:)` is not an entry: it is the
    /// wiki's own record, not CCwiki's.
    let entries: [Entry]
    /// `reviewedAgainst.wikiCommit`: the wiki commit the entries were
    /// reviewed, and their quotes copied, against.
    let reviewedCommit: String?

    private let requirementsByStep: [RequirementKey: [Requirement]]
    private let entryIndexByKey: [Entry.Key: Int]

    private struct RequirementKey: Hashable, Sendable {
        let relationID: String
        let isReverse: Bool
    }

    static let empty = DerivationCuration()

    /// `citations` and `evidence` are keyed by entry, so a test can build a
    /// curation with citations without writing JSON. `evidence` is the prose
    /// of the entries whose table does not carry it (an equivalence's note, a
    /// requirement's or a weakening's evidence); the rest default to what
    /// their table holds: a refutation's or a setting's evidence, a
    /// quarantine's reason, a Statement-lint note.
    init(
        refuted: [Refutation] = [],
        settings: [Setting] = [],
        quarantine: [String: String] = [:],
        quarantineDirections: [String: Bool] = [:],
        misspeltDirections: Set<String> = [],
        equivalences: [String: Directions] = [:],
        requires: [Requirement] = [],
        weakens: [Weakening] = [],
        statementLint: [String: String] = [:],
        citations: [Entry.Key: [Citation]] = [:],
        evidence: [Entry.Key: String] = [:],
        reviewedCommit: String? = nil
    ) {
        var refutedByObject: [String: Refutation] = [:]
        for refutation in refuted { refutedByObject[refutation.objectID] = refutation }
        var settingsByObject: [String: Setting] = [:]
        for setting in settings { settingsByObject[setting.objectID] = setting }
        var weakensByRelation: [String: Weakening] = [:]
        for weakening in weakens { weakensByRelation[weakening.relationID] = weakening }
        var byStep: [RequirementKey: [Requirement]] = [:]
        for requirement in requires {
            let key = RequirementKey(relationID: requirement.relationID, isReverse: requirement.isReverse)
            byStep[key, default: []].append(requirement)
        }

        self.refuted = refutedByObject
        self.settings = settingsByObject
        self.quarantine = quarantine
        self.quarantineDirections = quarantineDirections
        self.misspeltDirections = misspeltDirections
        self.equivalences = equivalences
        self.requires = requires
        self.weakens = weakensByRelation
        self.statementLint = statementLint
        self.requirementsByStep = byStep

        let entries = Self.orderedEntries(
            refuted: refuted, settings: settings, quarantine: quarantine,
            equivalences: equivalences, requires: requires, weakens: weakens,
            statementLint: statementLint, citations: citations, evidence: evidence)
        var indexByKey: [Entry.Key: Int] = [:]
        for (index, entry) in entries.enumerated() { indexByKey[entry.key] = index }
        self.entries = entries
        self.entryIndexByKey = indexByKey
        self.reviewedCommit = reviewedCommit
    }

    /// The requirements on one direction of one reduction, in the file's order.
    func requirements(on relationID: String, isReverse: Bool) -> [Requirement] {
        requirementsByStep[RequirementKey(relationID: relationID, isReverse: isReverse)] ?? []
    }

    /// R13: why this direction of the reduction is quarantined, or `nil` when
    /// it is not. An entry without a direction holds back the whole
    /// reduction; one with a direction holds back that direction of an
    /// equivalence alone, and the other stays a step. The reference engine's
    /// `Curation.quarantined`.
    func quarantineReason(_ relationID: String, isReverse: Bool) -> String? {
        guard let reason = quarantine[relationID] else { return nil }
        if let scoped = quarantineDirections[relationID], scoped != isReverse { return nil }
        return reason
    }

    /// The file's entry for `key`, with its prose and citations.
    func entry(_ key: Entry.Key) -> Entry? {
        entryIndexByKey[key].map { entries[$0] }
    }

    /// A copy whose `refuted` also holds `refutations`, each replacing the
    /// file's for the same object: the manifest's record wins over CCwiki's.
    /// Everything else, `entries` included, is unchanged.
    ///
    /// This is how a manifest's `refutedBy` reaches the engine: every rule
    /// that reads `refuted` (R11's sources, completions, the forward list's
    /// banner, the inspector) applies it with no edit of its own.
    func adding(refutations: [Refutation]) -> DerivationCuration {
        var merged = self
        for refutation in refutations { merged.refuted[refutation.objectID] = refutation }
        return merged
    }

    /// The entries, in §2.2's order. `refuted`, `settings`, `requires` and
    /// `weakens` keep the order they are given in, which is the file's. The
    /// three tables are sorted by id in UTF-8 byte order, as the reference
    /// engine's `sorted` sorts them: a dictionary keeps no order to keep. A
    /// key given twice keeps its first place and its last content, as a
    /// Python dict does and as the tables above keep the last.
    private static func orderedEntries(
        refuted: [Refutation], settings: [Setting], quarantine: [String: String],
        equivalences: [String: Directions], requires: [Requirement], weakens: [Weakening],
        statementLint: [String: String],
        citations: [Entry.Key: [Citation]], evidence: [Entry.Key: String]
    ) -> [Entry] {
        var entries: [Entry] = []
        var indexByKey: [Entry.Key: Int] = [:]
        func add(_ key: Entry.Key, prose: String) {
            let entry = Entry(key: key, evidence: evidence[key] ?? prose, cites: citations[key] ?? [])
            if let index = indexByKey[key] {
                entries[index] = entry
            } else {
                indexByKey[key] = entries.count
                entries.append(entry)
            }
        }

        for refutation in refuted {
            add(.refuted(objectID: refutation.objectID), prose: refutation.evidence)
        }
        for setting in settings {
            add(.setting(objectID: setting.objectID), prose: setting.evidence)
        }
        for relationID in quarantine.keys.sorted(by: Derivation.precedes) {
            add(.quarantine(relationID: relationID), prose: quarantine[relationID] ?? "")
        }
        for relationID in equivalences.keys.sorted(by: Derivation.precedes) {
            add(.equivalence(relationID: relationID), prose: "")
        }
        for requirement in requires {
            add(.requirement(relationID: requirement.relationID, isReverse: requirement.isReverse,
                             hypothesis: requirement.hypothesis),
                prose: "")
        }
        for relationID in statementLint.keys.sorted(by: Derivation.precedes) {
            add(.statementLint(relationID: relationID), prose: statementLint[relationID] ?? "")
        }
        for weakening in weakens {
            add(.weakening(relationID: weakening.relationID), prose: "")
        }
        return entries
    }

    // MARK: Loading

    /// The file's name, in the bundle's `Contents/Resources` and in the
    /// source tree's `Resources/`.
    static let resourceName = "derivation-curation.json"

    /// The curation the app ships, read once.
    ///
    /// `nil` when it is missing or does not parse. `Derivation(manifest:)`
    /// then derives nothing at all: without the curation, chaining would
    /// prove the false claims the review found (derivations.md §0), and a
    /// missing feature is better than a wrong one. The lookup mirrors
    /// `AppPaths.bundledDocument`: the bundle first, then the source tree,
    /// which is all `swift run` and the test runner have.
    static let bundled: DerivationCuration? = {
        let name = DerivationCuration.resourceName
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: name))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appending(path: "Resources/\(name)"))
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            // The first file found is the one meant; a malformed one is not a
            // reason to go looking for another.
            return try? DerivationCuration.decode(data)
        }
        return nil
    }()

    /// Throws on a file that does not parse. Unlike the manifest, this is
    /// CCwiki's own file, reviewed with the code, so a malformed one is a bug
    /// to surface rather than something to degrade around.
    static func decode(_ data: Data) throws -> DerivationCuration {
        let dto = try JSONDecoder().decode(CurationDTO.self, from: data)

        // Each entry's citations, and the prose its table does not carry, by
        // entry. A key given twice takes its last, as the tables do.
        var citations: [Entry.Key: [Citation]] = [:]
        var evidence: [Entry.Key: String] = [:]
        for raw in dto.refuted {
            citations[.refuted(objectID: raw.object)] = raw.cites.map { $0.citation }
        }
        for raw in dto.settings {
            citations[.setting(objectID: raw.object)] = raw.cites.map { $0.citation }
        }
        // A quarantine's direction, as the reference engine reads it: absent
        // (or null) holds back the whole reduction, "reverse" the reverse
        // direction, anything else the forward one. Anything but "forward"
        // or "reverse" is misspelt, and `unresolved(in:)` reports it. The
        // last entry for an edge wins, as it does for the reason: assigning
        // nil removes it.
        var quarantineDirections: [String: Bool] = [:]
        var misspeltDirections: Set<String> = []
        for raw in dto.quarantine {
            citations[.quarantine(relationID: raw.edge)] = raw.cites.map { $0.citation }
            quarantineDirections[raw.edge] = raw.direction.map { $0 == "reverse" }
            if let direction = raw.direction, direction != "forward", direction != "reverse" {
                misspeltDirections.insert(raw.edge)
            } else {
                misspeltDirections.remove(raw.edge)
            }
        }
        for (relationID, raw) in dto.equivalences {
            citations[.equivalence(relationID: relationID)] = raw.cites.map { $0.citation }
            evidence[.equivalence(relationID: relationID)] = raw.note
        }
        for raw in dto.requires {
            let key = Entry.Key.requirement(relationID: raw.edge, isReverse: raw.isReverse,
                                            hypothesis: raw.hypothesis)
            citations[key] = raw.cites.map { $0.citation }
            evidence[key] = raw.evidence
        }
        for (relationID, raw) in dto.statementLint {
            citations[.statementLint(relationID: relationID)] = raw.cites.map { $0.citation }
        }
        for raw in dto.weakens {
            citations[.weakening(relationID: raw.edge)] = raw.cites.map { $0.citation }
            evidence[.weakening(relationID: raw.edge)] = raw.evidence
        }

        return DerivationCuration(
            refuted: dto.refuted.map {
                Refutation(objectID: $0.object, source: $0.source, text: $0.text, evidence: $0.evidence)
            },
            settings: dto.settings.map {
                Setting(objectID: $0.object, text: $0.text, evidence: $0.evidence)
            },
            quarantine: Dictionary(
                dto.quarantine.map { ($0.edge, $0.reason) }, uniquingKeysWith: { _, last in last }),
            quarantineDirections: quarantineDirections,
            misspeltDirections: misspeltDirections,
            equivalences: dto.equivalences.mapValues {
                Directions(forward: $0.forward, reverse: $0.reverse)
            },
            requires: dto.requires.map {
                Requirement(
                    relationID: $0.edge, isReverse: $0.isReverse,
                    hypothesis: $0.hypothesis, notion: $0.notion, metBy: Set($0.metBy),
                    notionMarkdown: $0.notionMarkdown)
            },
            weakens: dto.weakens.map {
                Weakening(relationID: $0.edge, notion: $0.notion, acceptedBy: Set($0.acceptedBy),
                          notionMarkdown: $0.notionMarkdown)
            },
            statementLint: dto.statementLint.mapValues { $0.note },
            citations: citations,
            evidence: evidence,
            reviewedCommit: dto.reviewedAgainst?.wikiCommit)
    }

    // MARK: Drift

    /// Ids in the file that the manifest no longer resolves: an object or a
    /// reduction that is gone, an equivalence that is no longer one, a
    /// quarantine whose direction is misspelt or names a direction of an
    /// implication, or a requirement naming a hypothesis its reduction does
    /// not have. Sorted.
    /// The corpus test fails on any, because the wiki moved under a reviewed
    /// correction and the correction has to be reviewed again.
    func unresolved(in manifest: RelationsManifest) -> [String] {
        var bad: Set<String> = []
        for objectID in Array(refuted.keys) + Array(settings.keys)
        where manifest.object(objectID) == nil {
            bad.insert("object \(objectID)")
        }
        let relationIDs = Array(quarantine.keys) + Array(equivalences.keys)
            + Array(weakens.keys) + Array(statementLint.keys)
        for relationID in relationIDs where manifest.reduction(relationID) == nil {
            bad.insert("reduction \(relationID)")
        }
        for relationID in equivalences.keys {
            if let relation = manifest.reduction(relationID), relation.kind != .equivalence {
                bad.insert("not an equivalence \(relationID)")
            }
        }
        // A quarantine scoped to one direction names a direction of an
        // equivalence; an implication has only the one. The direction is
        // "forward" or "reverse": any other value would hold back the
        // forward direction silently. (A requirement meant for the reverse
        // direction but misspelt reads as forward too, and then names a
        // hypothesis its step lacks, which the check below reports.)
        for relationID in quarantineDirections.keys {
            if let relation = manifest.reduction(relationID), relation.kind != .equivalence {
                bad.insert("not an equivalence \(relationID)")
            }
        }
        for relationID in misspeltDirections {
            bad.insert("direction \(relationID)")
        }
        for requirement in requires {
            guard let relation = manifest.reduction(requirement.relationID) else {
                bad.insert("reduction \(requirement.relationID)")
                continue
            }
            let hypotheses = requirement.isReverse ? [relation.conclusion] : relation.hypotheses
            if !hypotheses.contains(requirement.hypothesis) {
                bad.insert("hypothesis \(requirement.relationID):\(requirement.hypothesis)")
            }
            for producer in requirement.metBy where manifest.reduction(producer) == nil {
                bad.insert("reduction \(producer)")
            }
        }
        for weakening in weakens.values {
            for consumer in weakening.acceptedBy where manifest.reduction(consumer) == nil {
                bad.insert("reduction \(consumer)")
            }
        }
        return bad.sorted(by: Derivation.precedes)
    }
}

// MARK: - Evidence

/// What each entry rests on (plans/relations-followups.md §2.2, §6.1). The
/// prose `evidence` is for people; `cites` quotes the page source verbatim,
/// so a script, a test and the app can each check the quote is still there.
extension DerivationCuration {

    /// A passage of the wiki an entry rests on, verbatim.
    struct Citation: Hashable, Sendable {
        /// Repository-relative, as the manifest writes `page`:
        /// `content/Reductions/ot-to-mpc-kil88.md`.
        let page: String
        /// The heading's text without its `#`s; `nil` for anywhere in the
        /// file, frontmatter included.
        let section: String?
        /// The page source, verbatim: wikilinks, `$…$` and `**` as written.
        let quote: String

        /// `Reductions/ot-to-mpc-kil88.md`: what `AppModel.openPage` and
        /// `ExplorerRow.Target.page` take.
        var contentPath: String { RelationsManifest.contentRelative(page) }
    }

    /// One entry of the file.
    struct Entry: Hashable, Sendable, Identifiable {

        /// Which entry, by what the engine keys it on.
        enum Key: Hashable, Sendable {
            case refuted(objectID: String)
            case setting(objectID: String)
            case quarantine(relationID: String)
            case equivalence(relationID: String)
            case requirement(relationID: String, isReverse: Bool, hypothesis: String)
            case statementLint(relationID: String)
            case weakening(relationID: String)

            /// The entry's id, named for the file's key it is under:
            /// `requires:red-dlog-to-prg-bm84:dlog`, with `~reverse` after
            /// the edge for the backward direction of an equivalence. Computed,
            /// never stored; the review document, the app and the asks all use
            /// it.
            var id: String {
                switch self {
                case .refuted(let objectID): "refuted:\(objectID)"
                case .setting(let objectID): "settings:\(objectID)"
                case .quarantine(let relationID): "quarantine:\(relationID)"
                case .equivalence(let relationID): "equivalences:\(relationID)"
                case .requirement(let relationID, let isReverse, let hypothesis):
                    "requires:\(relationID)\(isReverse ? "~reverse" : ""):\(hypothesis)"
                case .statementLint(let relationID): "statementLint:\(relationID)"
                case .weakening(let relationID): "weakens:\(relationID)"
                }
            }
        }

        let key: Key
        /// `key.id`.
        let id: String
        /// The file's prose: a refutation's, setting's, requirement's or
        /// weakening's `evidence`, a quarantine's `reason`, an equivalence's
        /// or a Statement lint's `note`.
        let evidence: String
        /// Empty only for an entry nobody has cited yet.
        let cites: [Citation]

        init(key: Key, evidence: String, cites: [Citation]) {
            self.key = key
            self.id = key.id
            self.evidence = evidence
            self.cites = cites
        }
    }
}

// MARK: - Decoding

/// The file's wire shape. The arrays are keyed by their `object` or `edge`
/// field once decoded; optional keys (`direction`, `metBy`, `acceptedBy`,
/// `evidence`, the notes, `notionMarkdown`, `cites`, a citation's `section`,
/// `reviewedAgainst`) cost a default, and every other key is required. So a
/// file from before citations still decodes, and an entry nobody has cited
/// yet is simply uncited.
private struct CurationDTO: Decodable {
    var reviewedAgainst: RawReview?
    var refuted: [RawRefutation]
    var settings: [RawSetting]
    var quarantine: [RawQuarantine]
    var equivalences: [String: RawDirections]
    var requires: [RawRequirement]
    var weakens: [RawWeakening]
    var statementLint: [String: RawLint]

    enum CodingKeys: String, CodingKey {
        case reviewedAgainst, refuted, settings, quarantine, equivalences, requires, weakens, statementLint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewedAgainst = try c.decodeIfPresent(RawReview.self, forKey: .reviewedAgainst)
        refuted = try c.decodeIfPresent([RawRefutation].self, forKey: .refuted) ?? []
        settings = try c.decodeIfPresent([RawSetting].self, forKey: .settings) ?? []
        quarantine = try c.decodeIfPresent([RawQuarantine].self, forKey: .quarantine) ?? []
        equivalences = try c.decodeIfPresent([String: RawDirections].self, forKey: .equivalences) ?? [:]
        requires = try c.decodeIfPresent([RawRequirement].self, forKey: .requires) ?? []
        weakens = try c.decodeIfPresent([RawWeakening].self, forKey: .weakens) ?? []
        statementLint = try c.decodeIfPresent([String: RawLint].self, forKey: .statementLint) ?? [:]
    }

    /// `reviewedAgainst`. Its other key, the manifest's SHA-256, is the
    /// reference engine's.
    struct RawReview: Decodable {
        var wikiCommit: String?

        enum CodingKeys: String, CodingKey { case wikiCommit }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wikiCommit = try c.decodeIfPresent(String.self, forKey: .wikiCommit)
        }
    }

    /// One element of an entry's `cites`.
    struct RawCitation: Decodable {
        var page: String
        var section: String?
        var quote: String

        enum CodingKeys: String, CodingKey { case page, section, quote }

        /// `section` absent and `section: null` both mean the whole file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            page = try c.decode(String.self, forKey: .page)
            section = try c.decodeIfPresent(String.self, forKey: .section)
            quote = try c.decode(String.self, forKey: .quote)
        }

        var citation: DerivationCuration.Citation {
            DerivationCuration.Citation(page: page, section: section, quote: quote)
        }
    }

    struct RawRefutation: Decodable {
        var object: String
        var source: String
        var text: String
        var evidence: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey { case object, source, text, evidence, cites }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            object = try c.decode(String.self, forKey: .object)
            source = try c.decode(String.self, forKey: .source)
            text = try c.decode(String.self, forKey: .text)
            evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }
    }

    struct RawSetting: Decodable {
        var object: String
        var text: String
        var evidence: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey { case object, text, evidence, cites }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            object = try c.decode(String.self, forKey: .object)
            text = try c.decode(String.self, forKey: .text)
            evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }
    }

    /// `{edge, direction, reason, cites}`: `reason` is the entry's prose, and
    /// `direction`, when present, scopes it to one direction of an
    /// equivalence. The `evidence` key the file had before citations is
    /// ignored.
    struct RawQuarantine: Decodable {
        var edge: String
        var direction: String?
        var reason: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey { case edge, direction, reason, cites }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edge = try c.decode(String.self, forKey: .edge)
            direction = try c.decodeIfPresent(String.self, forKey: .direction)
            reason = try c.decode(String.self, forKey: .reason)
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }
    }

    struct RawDirections: Decodable {
        var forward: String
        var reverse: String
        var note: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey { case forward, reverse, note, cites }

        /// A direction the file does not name is not `record`, so it reads
        /// as `unstated`, as the reference engine reads it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            forward = try c.decodeIfPresent(String.self, forKey: .forward) ?? ""
            reverse = try c.decodeIfPresent(String.self, forKey: .reverse) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }
    }

    struct RawRequirement: Decodable {
        var edge: String
        var direction: String
        var hypothesis: String
        var notion: String
        var notionMarkdown: String?
        var metBy: [String]
        var evidence: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey {
            case edge, direction, hypothesis, notion, notionMarkdown, metBy, evidence, cites
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edge = try c.decode(String.self, forKey: .edge)
            direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? "forward"
            hypothesis = try c.decode(String.self, forKey: .hypothesis)
            notion = try c.decode(String.self, forKey: .notion)
            notionMarkdown = try c.decodeIfPresent(String.self, forKey: .notionMarkdown)
            metBy = try c.decodeIfPresent([String].self, forKey: .metBy) ?? []
            evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }

        var isReverse: Bool { direction == "reverse" }
    }

    struct RawWeakening: Decodable {
        var edge: String
        var notion: String
        var notionMarkdown: String?
        var acceptedBy: [String]
        var evidence: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey { case edge, notion, notionMarkdown, acceptedBy, evidence, cites }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edge = try c.decode(String.self, forKey: .edge)
            notion = try c.decode(String.self, forKey: .notion)
            notionMarkdown = try c.decodeIfPresent(String.self, forKey: .notionMarkdown)
            acceptedBy = try c.decodeIfPresent([String].self, forKey: .acceptedBy) ?? []
            evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }
    }

    /// A `statementLint` value: the bare note the file held before citations,
    /// or `{note, cites}`. Both read, so the file can move to the second form
    /// without an app in between that derives nothing: a throw here would
    /// make `bundled` nil.
    struct RawLint: Decodable {
        var note: String
        var cites: [RawCitation]

        enum CodingKeys: String, CodingKey { case note, cites }

        init(from decoder: Decoder) throws {
            if let note = try? decoder.singleValueContainer().decode(String.self) {
                self.note = note
                cites = []
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            cites = try c.decodeIfPresent([RawCitation].self, forKey: .cites) ?? []
        }
    }
}
