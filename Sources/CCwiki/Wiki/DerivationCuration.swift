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
    /// defines. The step fires only when the hypothesis is given (and the
    /// derivation then carries "assuming `notion`") or was concluded by a
    /// reduction in `metBy`, whose own Statement establishes the notion.
    struct Requirement: Hashable, Sendable {
        let relationID: String
        /// The backward direction of an equivalence.
        let isReverse: Bool
        let hypothesis: String
        let notion: String
        let metBy: Set<String>
    }

    /// R13. A step concludes only a weaker notion than its node defines. Its
    /// fact is kept apart from the node's full one, and only the reductions
    /// in `acceptedBy` may consume it.
    struct Weakening: Hashable, Sendable {
        let relationID: String
        let notion: String
        let acceptedBy: Set<String>
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

    let refuted: [String: Refutation]
    let settings: [String: Setting]
    /// R13: reduction id → why its recorded hypotheses do not match its own
    /// Statement. A quarantined reduction is never used.
    let quarantine: [String: String]
    let equivalences: [String: Directions]
    /// In the file's order.
    let requires: [Requirement]
    let weakens: [String: Weakening]
    /// Reduction id → why a Statement-lint hit on it is not a dropped
    /// conjunct.
    let statementLint: [String: String]

    private let requirementsByStep: [RequirementKey: [Requirement]]

    private struct RequirementKey: Hashable, Sendable {
        let relationID: String
        let isReverse: Bool
    }

    static let empty = DerivationCuration()

    init(
        refuted: [Refutation] = [],
        settings: [Setting] = [],
        quarantine: [String: String] = [:],
        equivalences: [String: Directions] = [:],
        requires: [Requirement] = [],
        weakens: [Weakening] = [],
        statementLint: [String: String] = [:]
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
        self.equivalences = equivalences
        self.requires = requires
        self.weakens = weakensByRelation
        self.statementLint = statementLint
        self.requirementsByStep = byStep
    }

    /// The requirements on one direction of one reduction, in the file's order.
    func requirements(on relationID: String, isReverse: Bool) -> [Requirement] {
        requirementsByStep[RequirementKey(relationID: relationID, isReverse: isReverse)] ?? []
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
        return DerivationCuration(
            refuted: dto.refuted.map {
                Refutation(objectID: $0.object, source: $0.source, text: $0.text, evidence: $0.evidence)
            },
            settings: dto.settings.map {
                Setting(objectID: $0.object, text: $0.text, evidence: $0.evidence)
            },
            quarantine: Dictionary(
                dto.quarantine.map { ($0.edge, $0.reason) }, uniquingKeysWith: { _, last in last }),
            equivalences: dto.equivalences.mapValues {
                Directions(forward: $0.forward, reverse: $0.reverse)
            },
            requires: dto.requires.map {
                Requirement(
                    relationID: $0.edge, isReverse: $0.direction == "reverse",
                    hypothesis: $0.hypothesis, notion: $0.notion, metBy: Set($0.metBy))
            },
            weakens: dto.weakens.map {
                Weakening(relationID: $0.edge, notion: $0.notion, acceptedBy: Set($0.acceptedBy))
            },
            statementLint: dto.statementLint)
    }

    // MARK: Drift

    /// Ids in the file that the manifest no longer resolves: an object or a
    /// reduction that is gone, an equivalence that is no longer one, or a
    /// requirement naming a hypothesis its reduction does not have. Sorted.
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

// MARK: - Decoding

/// The file's wire shape. The arrays are keyed by their `object` or `edge`
/// field once decoded; optional keys (`direction`, `metBy`, `acceptedBy`,
/// `evidence`, the notes) cost a default, and every other key is required.
private struct CurationDTO: Decodable {
    var refuted: [RawRefutation]
    var settings: [RawSetting]
    var quarantine: [RawQuarantine]
    var equivalences: [String: RawDirections]
    var requires: [RawRequirement]
    var weakens: [RawWeakening]
    var statementLint: [String: String]

    enum CodingKeys: String, CodingKey {
        case refuted, settings, quarantine, equivalences, requires, weakens, statementLint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refuted = try c.decodeIfPresent([RawRefutation].self, forKey: .refuted) ?? []
        settings = try c.decodeIfPresent([RawSetting].self, forKey: .settings) ?? []
        quarantine = try c.decodeIfPresent([RawQuarantine].self, forKey: .quarantine) ?? []
        equivalences = try c.decodeIfPresent([String: RawDirections].self, forKey: .equivalences) ?? [:]
        requires = try c.decodeIfPresent([RawRequirement].self, forKey: .requires) ?? []
        weakens = try c.decodeIfPresent([RawWeakening].self, forKey: .weakens) ?? []
        statementLint = try c.decodeIfPresent([String: String].self, forKey: .statementLint) ?? [:]
    }

    struct RawRefutation: Decodable {
        var object: String
        var source: String
        var text: String
        var evidence: String

        enum CodingKeys: String, CodingKey { case object, source, text, evidence }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            object = try c.decode(String.self, forKey: .object)
            source = try c.decode(String.self, forKey: .source)
            text = try c.decode(String.self, forKey: .text)
            evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        }
    }

    struct RawSetting: Decodable {
        var object: String
        var text: String
        var evidence: String

        enum CodingKeys: String, CodingKey { case object, text, evidence }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            object = try c.decode(String.self, forKey: .object)
            text = try c.decode(String.self, forKey: .text)
            evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        }
    }

    struct RawQuarantine: Decodable {
        var edge: String
        var reason: String

        enum CodingKeys: String, CodingKey { case edge, reason }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edge = try c.decode(String.self, forKey: .edge)
            reason = try c.decode(String.self, forKey: .reason)
        }
    }

    struct RawDirections: Decodable {
        var forward: String
        var reverse: String

        enum CodingKeys: String, CodingKey { case forward, reverse }

        /// A direction the file does not name is not `record`, so it reads
        /// as `unstated`, as the reference engine reads it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            forward = try c.decodeIfPresent(String.self, forKey: .forward) ?? ""
            reverse = try c.decodeIfPresent(String.self, forKey: .reverse) ?? ""
        }
    }

    struct RawRequirement: Decodable {
        var edge: String
        var direction: String
        var hypothesis: String
        var notion: String
        var metBy: [String]

        enum CodingKeys: String, CodingKey { case edge, direction, hypothesis, notion, metBy }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edge = try c.decode(String.self, forKey: .edge)
            direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? "forward"
            hypothesis = try c.decode(String.self, forKey: .hypothesis)
            notion = try c.decode(String.self, forKey: .notion)
            metBy = try c.decodeIfPresent([String].self, forKey: .metBy) ?? []
        }
    }

    struct RawWeakening: Decodable {
        var edge: String
        var notion: String
        var acceptedBy: [String]

        enum CodingKeys: String, CodingKey { case edge, notion, acceptedBy }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edge = try c.decode(String.self, forKey: .edge)
            notion = try c.decode(String.self, forKey: .notion)
            acceptedBy = try c.decodeIfPresent([String].self, forKey: .acceptedBy) ?? []
        }
    }
}
