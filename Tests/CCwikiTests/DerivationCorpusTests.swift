import CryptoKit
import Foundation
import Testing
@testable import CCwiki

/// The Swift engine against the reference engine's answers on the real
/// manifest: `Fixtures/derivations-golden.json`, written by
/// `scripts/derivations_reference.py --golden` (plans/derivations.md §8).
///
/// Gated on `CCWIKI_WIKI`, like the other corpus suites, with three outcomes:
///
/// 1. **Exact.** The clone's `relations.json` and the repository's curation
///    hash to the golden file's SHA-256s: every query record is compared field
///    by field, every mutation replayed, and the closure sizes, backward
///    summaries and counts compared.
/// 2. **Drifted, within tolerance.** A hash differs, but objects, reductions
///    and barriers are each within the golden file's tolerance of its counts:
///    the invariants and sentinels recomputed on this manifest, each record's
///    `stable` fields, the mutations' invariants and the Statement lint.
/// 3. **Drifted beyond tolerance.** Skipped, with the golden commit and counts
///    beside the clone's printed once.
struct DerivationCorpusTests {

    static let state = DerivationCorpusState.load()

    /// The corpus, or a recorded issue when the golden file or the curation
    /// could not be read.
    private func loadedCorpus() throws -> DerivationGoldenCorpus {
        switch Self.state {
        case .ready(let corpus):
            return corpus
        case .unreadable(let reason):
            Issue.record("\(reason)")
            throw CorpusUnavailable()
        case .noClone, .beyondTolerance:
            throw CorpusUnavailable()
        }
    }

    private struct CorpusUnavailable: Error {}

    @Test("every golden query", .enabled(if: DerivationCorpusTests.state.runs))
    func goldenQueries() throws {
        let corpus = try loadedCorpus()
        let records = corpus.golden["queries"]?.array ?? []
        #expect(!records.isEmpty)

        var checked = 0
        var skipped = 0
        var fields = 0
        for record in records {
            let id = record["id"]?.string ?? "?"
            let start = record["start"]?.strings ?? []
            let target = record["target"]?.string ?? ""
            let toggle = record["includeIdealised"]?.bool ?? false
            guard case .object(let expected)? = record["expect"] else {
                Issue.record("\(id) has no expectation")
                continue
            }
            // A record naming an object this manifest no longer has is
            // about a question that cannot be asked.
            let named = start + [target]
            if named.contains(where: { corpus.manifest.object($0) == nil }) {
                skipped += 1
                continue
            }
            let options = Derivation.Options(includesIdealisedModels: toggle)
            let answer = corpus.derivation.answer(from: Set(start), to: target, options: options)
            let mine = GoldenExpect.encode(answer, manifest: corpus.manifest)
            let keys = corpus.isExact
                ? Set(expected.keys).union(mine.keys).sorted()
                : (record["stable"]?.strings ?? [])
            for key in keys {
                let theirs = expected[key]
                let ours = mine[key]
                #expect(ours == theirs,
                        "\(id).\(key): golden \(theirs?.description ?? "absent"), got \(ours?.description ?? "absent")")
                fields += 1
            }
            checked += 1
        }
        if corpus.isExact {
            #expect(skipped == 0)
        }
        print("derivations corpus, \(corpus.modeName): \(checked) queries checked "
            + "(\(fields) fields), \(skipped) skipped; \(corpus.derivation.derivedBarriers.count) "
            + "derived barriers; \(corpus.derivation.steps.count) eligible steps")
    }

    @Test("the review's counterexamples, replayed as patches", .enabled(if: DerivationCorpusTests.state.runs))
    func goldenMutations() throws {
        let corpus = try loadedCorpus()
        let mutations = corpus.golden["mutations"]?.array ?? []
        #expect(!mutations.isEmpty)

        var replayed = 0
        for mutation in mutations {
            let id = mutation["id"]?.string ?? "?"
            let patch = mutation["patch"] ?? GoldenJSON.null
            let start = mutation["start"]?.strings ?? []
            let target = mutation["target"]?.string ?? ""
            let toggle = mutation["includeIdealised"]?.bool ?? false

            let missingBarriers = GoldenPatch.barrierIDs(in: patch).filter { barrierID in
                !corpus.manifest.barriers.contains { $0.id == barrierID }
            }
            guard missingBarriers.isEmpty else {
                #expect(!corpus.isExact, "\(id) patches \(missingBarriers), which the manifest lacks")
                continue
            }
            let patched = GoldenPatch.apply(patch, to: corpus.rawManifest)
            let encoded = try JSONEncoder().encode(patched)
            let manifest = RelationsManifest.decode(encoded)
            let named = start + [target]
            guard !named.contains(where: { manifest.object($0) == nil }) else {
                #expect(!corpus.isExact, "\(id) names an object the patched manifest lacks")
                continue
            }
            let derivation = Derivation(manifest: manifest, curation: corpus.curation)

            let invariants = derivation.invariants().byName
            let expectedInvariants = mutation["invariants"]?.bools ?? [:]
            #expect(invariants == expectedInvariants, "\(id): invariants")

            if corpus.isExact {
                let options = Derivation.Options(includesIdealisedModels: toggle)
                let answer = derivation.answer(from: Set(start), to: target, options: options)
                let mine = GoldenExpect.encode(answer, manifest: manifest)
                guard case .object(let expected)? = mutation["expect"] else {
                    Issue.record("\(id) has no expectation")
                    continue
                }
                for key in Set(expected.keys).union(mine.keys).sorted() {
                    let theirs = expected[key]
                    let ours = mine[key]
                    #expect(ours == theirs,
                            "\(id).\(key): golden \(theirs?.description ?? "absent"), got \(ours?.description ?? "absent")")
                }
                let expectedCount = mutation["derivedBarrierCount"]?.int
                let count = derivation.derivedBarriers.count
                #expect(count == expectedCount, "\(id): derived barriers")
            }
            replayed += 1
        }
        print("derivations corpus, \(corpus.modeName): \(replayed) of \(mutations.count) mutations replayed")
    }

    @Test("closure sizes, backward summaries, counts and policy", .enabled(if: DerivationCorpusTests.state.isExact))
    func goldenSummaries() throws {
        let corpus = try loadedCorpus()
        let golden = corpus.golden
        let derivation = corpus.derivation

        if case .object(let sizes)? = golden["closureSizes"] {
            for object in sizes.keys.sorted() {
                let standard = derivation.closure(from: [object], options: .standard)
                let all = derivation.closure(from: [object], options: .all)
                var mine: [String: GoldenJSON] = [:]
                mine["default"] = GoldenJSON.int(standard.facts.count - 1)
                mine["defaultWeak"] = GoldenJSON.int(standard.weakFacts.count)
                mine["all"] = GoldenJSON.int(all.facts.count - 1)
                let ours = GoldenJSON.object(mine)
                let theirs = sizes[object]
                #expect(ours == theirs, "closure of \(object): golden \(theirs?.description ?? "absent"), got \(ours)")
            }
        } else {
            Issue.record("the golden file has no closure sizes")
        }

        if case .object(let backward)? = golden["impliedBy"] {
            for target in backward.keys.sorted() {
                let ours = GoldenExpect.backwardSummary(derivation.implying(target, options: .standard))
                let theirs = backward[target]
                #expect(ours == theirs, "implied by \(target): golden \(theirs?.description ?? "absent"), got \(ours)")
            }
        } else {
            Issue.record("the golden file has no backward summaries")
        }

        var steps: [String: GoldenJSON] = [:]
        steps["default"] = GoldenJSON.int(derivation.defaultSteps.count)
        steps["all"] = GoldenJSON.int(derivation.steps.count)
        steps["quarantined"] = GoldenJSON.int(derivation.quarantinedSteps.count)
        let eligible = GoldenJSON.object(steps)
        #expect(eligible == golden["eligibleSteps"])

        var excluded: [String: GoldenJSON] = [:]
        for (exclusion, ids) in derivation.excluded {
            excluded[exclusion.rawValue] = GoldenJSON.int(ids.count)
        }
        let exclusions = GoldenJSON.object(excluded)
        #expect(exclusions == golden["excluded"])

        let derivedCount = derivation.derivedBarriers.count
        #expect(derivedCount == golden["derivedBarrierCount"]?.int)
        var pairs: Set<[String]> = []
        for barrier in derivation.derivedBarriers {
            pairs.insert([barrier.hypothesis, barrier.conclusion])
        }
        #expect(pairs.count == golden["derivedBarrierPairs"]?.int)

        let policy = golden["policy"]
        let defaultModels = Derivation.defaultModels.sorted()
        let idealisedModels = Derivation.idealisedModels.sorted()
        let composable = Derivation.ChainClass.composable.map { $0.rawValue }
        var modelNodes: [String: GoldenJSON] = [:]
        for (node, model) in Derivation.modelNodes { modelNodes[node] = GoldenJSON.string(model) }
        let nodes = GoldenJSON.object(modelNodes)
        #expect(policy?["defaultModels"]?.strings == defaultModels)
        #expect(policy?["idealisedModels"]?.strings == idealisedModels)
        #expect(policy?["composableClasses"]?.strings == composable)
        #expect(policy?["modelNodes"] == nodes)
        #expect(policy?["completionCap"]?.int == Derivation.completionCap)
        #expect(policy?["unstatedAfterIdealised"]?.string == "refuse")
        #expect(policy?["unmetPrecondition"]?.string == "refuse")
    }

    @Test("the invariants and sentinels hold", .enabled(if: DerivationCorpusTests.state.runs))
    func goldenInvariants() throws {
        let corpus = try loadedCorpus()
        let invariants = corpus.derivation.invariants()
        let sentinels = corpus.derivation.sentinels()

        for name in invariants.byName.keys.sorted() {
            let holds = invariants.byName[name] ?? false
            #expect(holds, "\(name) fails: \(invariants.details)")
        }
        #expect(sentinels.curationResolves,
                "the curation names ids the wiki no longer has: \(sentinels.unresolved)")
        #expect(sentinels.regimeLossCurated,
                "reductions whose securityLoss names a regime need a requires entry: \(sentinels.uncuratedRegime)")
        if corpus.isExact {
            let expectedInvariants = corpus.golden["invariants"]?.bools
            let expectedSentinels = corpus.golden["sentinels"]?.bools
            #expect(invariants.byName == expectedInvariants)
            #expect(sentinels.byName == expectedSentinels)
        } else if !sentinels.equivalencesReviewed {
            // A warning only: an unreviewed equivalence is already unstated
            // both ways.
            print("derivations corpus: unreviewed equivalences \(sentinels.unreviewedEquivalences)")
        }
        print("derivations corpus, \(corpus.modeName): invariants "
            + (invariants.byName.values.allSatisfy { $0 } ? "hold" : "FAIL")
            + ", sentinels " + (sentinels.byName.values.allSatisfy { $0 } ? "hold" : "warn"))
    }

    @Test("the Statement lint finds no unreviewed dropped conjunct", .enabled(if: DerivationCorpusTests.state.runs))
    func goldenStatementLint() throws {
        let corpus = try loadedCorpus()
        let content = corpus.cloneRoot.appending(path: "content")
        let hits = corpus.derivation.statementLint { path in
            try? String(contentsOf: content.appending(path: path), encoding: .utf8)
        }
        let described = hits.map { "\($0.relationID) \($0.hypotheses) names \($0.unlisted)" }
        #expect(hits.isEmpty, "possible dropped conjuncts: \(described)")
    }
}

// MARK: - The corpus

/// What the clone and the golden file say about each other, worked out once
/// per test run.
enum DerivationCorpusState: Sendable {
    case noClone
    case beyondTolerance(String)
    case unreadable(String)
    case ready(DerivationGoldenCorpus)

    var runs: Bool {
        switch self {
        case .ready, .unreadable: true
        case .noClone, .beyondTolerance: false
        }
    }

    var isExact: Bool {
        if case .ready(let corpus) = self { return corpus.isExact }
        return false
    }

    static func load() -> DerivationCorpusState {
        guard let path = ProcessInfo.processInfo.environment["CCWIKI_WIKI"], !path.isEmpty else {
            return .noClone
        }
        let cloneRoot = URL(fileURLWithPath: path)
        guard let manifestData = try? Data(contentsOf: cloneRoot.appending(path: RelationsManifest.displayPath))
        else { return .noClone }

        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent()
        let golden: GoldenJSON
        let curationData: Data
        let curation: DerivationCuration
        let rawManifest: GoldenJSON
        do {
            let goldenData = try Data(contentsOf: tests.appending(path: "Fixtures/derivations-golden.json"))
            golden = try JSONDecoder().decode(GoldenJSON.self, from: goldenData)
            curationData = try Data(contentsOf: repository.appending(path: "Resources/\(DerivationCuration.resourceName)"))
            curation = try DerivationCuration.decode(curationData)
            rawManifest = try JSONDecoder().decode(GoldenJSON.self, from: manifestData)
        } catch {
            return .unreadable("The golden file, the curation or the manifest did not parse: \(error)")
        }
        let manifest = RelationsManifest.decode(manifestData)

        let manifestHash = sha256(manifestData)
        let curationHash = sha256(curationData)
        let isExact = manifestHash == golden["manifestSHA256"]?.string
            && curationHash == golden["curationSHA256"]?.string

        if !isExact {
            let tolerance = golden["tolerance"]?.number ?? 0
            let current: [(String, Int)] = [
                ("objects", manifest.objectsByID.count),
                ("reductions", manifest.reductions.count),
                ("barriers", manifest.barriers.count),
            ]
            var outside: [String] = []
            var compared: [String] = []
            for (key, count) in current {
                let expected = golden["counts"]?[key]?.number ?? 0
                compared.append("\(key) \(count) (golden \(Int(expected)))")
                if abs(Double(count) - expected) > tolerance * expected {
                    outside.append(key)
                }
            }
            if !outside.isEmpty {
                let commit = golden["wikiCommit"]?.string ?? "?"
                let message = "derivations corpus skipped: the clone has drifted beyond the golden file's "
                    + "tolerance (\(compared.joined(separator: ", ")); golden wiki commit \(commit)). "
                    + "Regenerate with scripts/derivations_reference.py RELATIONS_JSON --golden "
                    + "Tests/CCwikiTests/Fixtures/derivations-golden.json --wiki-commit SHA."
                print(message)
                return .beyondTolerance(message)
            }
        }

        return .ready(DerivationGoldenCorpus(
            isExact: isExact, golden: golden, rawManifest: rawManifest, manifest: manifest,
            curation: curation, derivation: Derivation(manifest: manifest, curation: curation),
            cloneRoot: cloneRoot))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct DerivationGoldenCorpus: Sendable {
    let isExact: Bool
    let golden: GoldenJSON
    /// The clone's `relations.json` as plain JSON, for the patches.
    let rawManifest: GoldenJSON
    let manifest: RelationsManifest
    let curation: DerivationCuration
    let derivation: Derivation
    let cloneRoot: URL

    var modeName: String { isExact ? "exact" : "drifted within tolerance" }
}

// MARK: - The reference engine's record shape

/// An answer in the shape `golden_expect` writes, so a record compares field
/// by field.
enum GoldenExpect {

    static func encode(_ answer: Derivation.Answer, manifest: RelationsManifest) -> [String: GoldenJSON] {
        switch answer {
        case .unsupported:
            return ["supported": GoldenJSON.bool(false)]
        case .derived(let answer):
            return derived(answer, manifest: manifest)
        case .notDerived(let answer):
            return noPath(answer, manifest: manifest)
        }
    }

    private static func derived(_ answer: Derivation.DerivedAnswer,
                                manifest: RelationsManifest) -> [String: GoldenJSON] {
        var out = common(
            manifest: manifest, derivable: true, refuted: answer.refutedStarts,
            modelStarts: answer.modelStarts, settingStarts: answer.settingStarts,
            recorded: answer.recordedBarriers, reverse: answer.reverseBarriers,
            derived: answer.derivedBarriers, derivedReverse: answer.derivedReverseBarriers,
            onPair: answer.recordedOnPair)
        let fact = answer.fact
        out["depth"] = GoldenJSON.int(fact.depth)
        out["models"] = strings(fact.models.sorted(by: Derivation.precedes))
        out["scoped"] = GoldenJSON.bool(fact.isModelScoped)
        out["chainClass"] = GoldenJSON.string(fact.chainClass.rawValue)
        out["edges"] = strings(answer.proof.relationIDs)
        out["reverseSteps"] = strings(answer.proof.reverseRelationIDs)
        // The reference engine's comparison policies only; always empty here.
        out["caveats"] = GoldenJSON.array([])
        if !answer.isGiven {
            out["conflictingBarriers"] = GoldenJSON.array(answer.conflicts.map(conflict))
            out["majorResultBarriers"] = GoldenJSON.array(answer.majorResults.map(conflict))
        }
        let assumes = fact.assumes.sorted(by: requirementPrecedes)
        out["assumes"] = strings(assumes.map { "\($0.relationID):\($0.hypothesis)" })
        if let weakening = fact.weakening {
            out["weakened"] = GoldenJSON.string(weakening.relationID)
        } else {
            out["weakened"] = GoldenJSON.null
        }
        if let stronger = answer.stronger {
            var strongest: [String: GoldenJSON] = [:]
            strongest["chainClass"] = GoldenJSON.string(stronger.chainClass.rawValue)
            strongest["depth"] = GoldenJSON.int(stronger.depth)
            strongest["edges"] = strings(stronger.proof.relationIDs)
            out["strongest"] = GoldenJSON.object(strongest)
        }
        if let note = answer.scopeNote {
            out["barrierScopeNote"] = strings(note.reasons)
        }
        return out
    }

    private static func noPath(_ answer: Derivation.NoPathAnswer,
                               manifest: RelationsManifest) -> [String: GoldenJSON] {
        var out = common(
            manifest: manifest, derivable: false, refuted: answer.refutedStarts,
            modelStarts: answer.modelStarts, settingStarts: answer.settingStarts,
            recorded: answer.recordedBarriers, reverse: answer.reverseBarriers,
            derived: answer.derivedBarriers, derivedReverse: answer.derivedReverseBarriers,
            onPair: answer.recordedOnPair)
        out["completions"] = strings(answer.completions.prefix(5).map { $0.objectID })
        out["completionCount"] = GoldenJSON.int(answer.completionCount)
        out["questionBecomes"] = strings(answer.questionBecomes.map { $0.objectID })
        var refused: [GoldenJSON] = []
        for step in answer.refused {
            var row: [String: GoldenJSON] = [:]
            row["edge"] = GoldenJSON.string(step.step.relationID)
            row["reverse"] = GoldenJSON.bool(step.step.isReverse)
            row["reasons"] = strings(step.reasons.map { $0.kind }.sorted(by: Derivation.precedes))
            refused.append(GoldenJSON.object(row))
        }
        out["refusedSteps"] = GoldenJSON.array(refused)
        out["nearMisses"] = nearMisses(answer.hints)
        if let fact = answer.withIdealisedModels {
            var row: [String: GoldenJSON] = [:]
            row["depth"] = GoldenJSON.int(fact.depth)
            row["models"] = strings(fact.models.sorted(by: Derivation.precedes))
            row["usesStub"] = GoldenJSON.bool(answer.withIdealisedModelsUsesStub)
            out["withIdealised"] = GoldenJSON.object(row)
        }
        return out
    }

    private static func common(
        manifest: RelationsManifest, derivable: Bool, refuted: [DerivationCuration.Refutation],
        modelStarts: [String], settingStarts: [String], recorded: [Barrier], reverse: [Barrier],
        derived: [Derivation.DerivedBarrier], derivedReverse: [Derivation.DerivedBarrier],
        onPair: [Derivation.RecordedOnPair]
    ) -> [String: GoldenJSON] {
        var out: [String: GoldenJSON] = [:]
        out["supported"] = GoldenJSON.bool(true)
        out["derivable"] = GoldenJSON.bool(derivable)
        if !refuted.isEmpty { out["vacuous"] = strings(refuted.map { $0.objectID }) }
        if !modelStarts.isEmpty { out["modelStart"] = strings(modelStarts) }
        if !settingStarts.isEmpty { out["settingStart"] = strings(settingStarts) }

        var barriers: [GoldenJSON] = []
        for barrier in recorded {
            var row: [String: GoldenJSON] = [:]
            row["id"] = GoldenJSON.string(barrier.id)
            if let qualifier = Derivation.qualifier(of: barrier, in: manifest) {
                row["qualifier"] = GoldenJSON.string(qualifier.rawValue)
            } else {
                row["qualifier"] = GoldenJSON.null
            }
            barriers.append(GoldenJSON.object(row))
        }
        out["recordedBarriers"] = GoldenJSON.array(barriers)
        out["reverseBarriers"] = strings(reverse.map { $0.id })
        out["derivedBarriers"] = GoldenJSON.array(derived.map(derivedView))
        let keptReverse = derivedReverse.filter { !$0.isRedundant }
        out["derivedReverseBarriers"] = strings(keptReverse.map { "\($0.barrier.id):\($0.reductionClass.rawValue)" })

        var rows: [GoldenJSON] = []
        for entry in onPair {
            var row: [String: GoldenJSON] = [:]
            row["edge"] = GoldenJSON.string(entry.relationID)
            row["reverse"] = GoldenJSON.bool(entry.isReverse)
            row["status"] = GoldenJSON.string(entry.status.rawValue)
            rows.append(GoldenJSON.object(row))
        }
        out["recordedOnPair"] = GoldenJSON.array(rows)
        return out
    }

    /// `derived_view`.
    static func derivedView(_ barrier: Derivation.DerivedBarrier) -> GoldenJSON {
        var up: [String: GoldenJSON] = [:]
        for (start, steps) in barrier.upPaths {
            up[start] = strings(steps.map { $0.relationID })
        }
        var consequence: [String: GoldenJSON] = [:]
        consequence["kind"] = GoldenJSON.string(barrier.consequence.kind.rawValue)
        consequence["target"] = GoldenJSON.string(barrier.consequence.target)
        var view: [String: GoldenJSON] = [:]
        view["barrier"] = GoldenJSON.string(barrier.barrier.id)
        view["hypotheses"] = strings(barrier.hypotheses)
        view["class"] = GoldenJSON.string(barrier.reductionClass.rawValue)
        view["consequence"] = GoldenJSON.object(consequence)
        view["strength"] = GoldenJSON.string(barrier.strength.rawValue)
        view["up"] = GoldenJSON.object(up)
        view["down"] = strings(barrier.down.map { $0.relationID })
        view["circumventedBy"] = strings(barrier.circumventedBy)
        view["circumventsOriginalOnly"] = strings(barrier.circumventsOriginalOnly)
        view["redundantWith"] = strings(barrier.redundantWith)
        return GoldenJSON.object(view)
    }

    private static func conflict(_ conflict: Derivation.BarrierConflict) -> GoldenJSON {
        var row: [String: GoldenJSON] = [:]
        row["barrier"] = GoldenJSON.string((conflict.isDerived ? "derived:" : "") + conflict.barrierID)
        row["consequence"] = GoldenJSON.int(conflict.consequenceIndex)
        row["chainClass"] = GoldenJSON.string(conflict.chainClass.rawValue)
        return GoldenJSON.object(row)
    }

    /// The four hint lists `near_misses` returns.
    private static func nearMisses(_ hints: [Derivation.Hint]) -> GoldenJSON {
        func ids(_ kind: Derivation.Hint.Kind) -> [String] {
            hints.filter { $0.kind == kind }.map { $0.objectID }
        }
        var out: [String: GoldenJSON] = [:]
        out["targetVariantsDerived"] = strings(ids(.targetSection))
        if let host = ids(.targetHost).first {
            out["targetHostDerived"] = GoldenJSON.string(host)
        } else {
            out["targetHostDerived"] = GoldenJSON.null
        }
        out["startVariantsDerive"] = strings(ids(.startSection))
        out["startHostsDerive"] = strings(ids(.startHost))
        return GoldenJSON.object(out)
    }

    /// The `impliedBy` summary the golden file keeps for PKE, OT and MPC.
    static func backwardSummary(_ backward: Derivation.BackwardClosure) -> GoldenJSON {
        var out: [String: GoldenJSON] = [:]
        out["singleCount"] = GoldenJSON.int(backward.singleCount)
        out["pairCount"] = GoldenJSON.int(backward.pairCount)
        out["settings"] = strings(backward.settings.map { $0.objectID })
        out["refutedExcluded"] = strings(backward.refutedExcluded)
        let assuming = backward.singles.filter { !$0.fact.assumes.isEmpty }.map { $0.objectID }
        out["singlesWithAssumptions"] = strings(assuming.sorted(by: Derivation.precedes))
        var groups: [String: GoldenJSON] = [:]
        for group in backward.groups {
            var row: [String: GoldenJSON] = [:]
            row["pairCount"] = GoldenJSON.int(group.pairCount)
            row["models"] = strings(group.models)
            row["assumes"] = strings(group.assumes)
            groups[group.relationID] = GoldenJSON.object(row)
        }
        out["groups"] = GoldenJSON.object(groups)
        return GoldenJSON.object(out)
    }

    private static func strings(_ values: [String]) -> GoldenJSON {
        GoldenJSON.array(values.map { GoldenJSON.string($0) })
    }

    /// The reference engine's order for assumed preconditions: reduction,
    /// direction, hypothesis.
    private static func requirementPrecedes(_ a: DerivationCuration.Requirement,
                                            _ b: DerivationCuration.Requirement) -> Bool {
        if a.relationID != b.relationID { return Derivation.precedes(a.relationID, b.relationID) }
        if a.isReverse != b.isReverse { return !a.isReverse }
        return Derivation.precedes(a.hypothesis, b.hypothesis)
    }
}

/// The golden file's patches: add records, then set fields on existing
/// barriers and append consequences to them (`apply_patch`).
enum GoldenPatch {

    static func barrierIDs(in patch: GoldenJSON) -> [String] {
        (patch["barrierPatches"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    static func apply(_ patch: GoldenJSON, to manifest: GoldenJSON) -> GoldenJSON {
        guard case .object(var root) = manifest else { return manifest }
        for key in ["objects", "reductions", "barriers"] {
            let existing = root[key]?.array ?? []
            let added = patch[key]?.array ?? []
            root[key] = GoldenJSON.array(existing + added)
        }
        var barriers = root["barriers"]?.array ?? []
        for barrierPatch in patch["barrierPatches"]?.array ?? [] {
            guard let id = barrierPatch["id"]?.string,
                  let index = barriers.firstIndex(where: { $0["id"]?.string == id }),
                  case .object(var barrier) = barriers[index]
            else { continue }
            if case .object(let fields)? = barrierPatch["set"] {
                for (field, value) in fields { barrier[field] = value }
            }
            let appended = barrierPatch["appendConsequences"]?.array ?? []
            let consequences = barrier["consequences"]?.array ?? []
            barrier["consequences"] = GoldenJSON.array(consequences + appended)
            barriers[index] = GoldenJSON.object(barrier)
        }
        root["barriers"] = GoldenJSON.array(barriers)
        return GoldenJSON.object(root)
    }
}

/// Plain JSON, decoded without a schema, so a golden record compares as a
/// value. Integers stay integers, so a patched manifest encodes back as it
/// was read.
enum GoldenJSON: Equatable, Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([GoldenJSON])
    case object([String: GoldenJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GoldenJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: GoldenJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> GoldenJSON? {
        if case .object(let entries) = self { return entries[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [GoldenJSON]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var strings: [String]? {
        guard let values = array else { return nil }
        var strings: [String] = []
        for value in values {
            guard let string = value.string else { return nil }
            strings.append(string)
        }
        return strings
    }

    var bools: [String: Bool]? {
        guard case .object(let entries) = self else { return nil }
        var bools: [String: Bool] = [:]
        for (key, value) in entries {
            guard let flag = value.bool else { return nil }
            bools[key] = flag
        }
        return bools
    }

    var description: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return "\"\(value)\""
        case .array(let values):
            let items = values.map { $0.description }
            return "[" + items.joined(separator: ", ") + "]"
        case .object(let entries):
            let keys = entries.keys.sorted()
            let items = keys.map { key in "\"\(key)\": \(entries[key]?.description ?? "null")" }
            return "{" + items.joined(separator: ", ") + "}"
        }
    }
}
