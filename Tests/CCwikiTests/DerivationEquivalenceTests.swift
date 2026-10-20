import Foundation
import Testing
@testable import CCwiki

/// Track X of plans/efficiency.md §2.6, held to the code it replaces on the
/// real manifest. Each change keeps the old path behind a parameter with the
/// new one as its default (`Engine.Loop`), and these suites run both and
/// compare the results exactly, so CI proves the change equal without a
/// reviewer having to.
///
/// Gated on `CCWIKI_WIKI` like DerivationCorpusTests, whose corpus they share,
/// in either of its modes: equality between two paths needs no golden file.
/// Each prints what both paths cost; no assertion is about time.
struct DerivationEquivalenceTests {

    /// The corpus DerivationCorpusTests loaded, exact or drifted.
    static func corpus() -> DerivationGoldenCorpus? {
        if case .ready(let corpus) = DerivationCorpusTests.state { return corpus }
        return nil
    }

    /// Every single object, every start set of the golden file's queries and
    /// mutations, and 300 sets of two or three objects drawn with a fixed
    /// seed, complexity classes left out as R2 leaves them out.
    static func startSets(_ corpus: DerivationGoldenCorpus) -> [Set<String>] {
        let manifest = corpus.manifest
        let ids = manifest.objectsByID.keys.sorted(by: Derivation.precedes)
        var sets: [Set<String>] = ids.map { [$0] }
        var seen = Set(sets)
        let records = (corpus.golden["queries"]?.array ?? []) + (corpus.golden["mutations"]?.array ?? [])
        for record in records {
            let start = Set(record["start"]?.strings ?? [])
            guard !start.isEmpty, start.allSatisfy({ manifest.object($0) != nil }),
                  seen.insert(start).inserted
            else { continue }
            sets.append(start)
        }
        let eligible = ids.filter { manifest.object($0)?.type != Derivation.excludedType }
        var generator = SplitMix64(seed: 20_261_020)
        for _ in 0..<300 {
            let size = Int.random(in: 2...3, using: &generator)
            var start: Set<String> = []
            while start.count < size, let id = eligible.randomElement(using: &generator) {
                start.insert(id)
            }
            sets.append(start)
        }
        return sets
    }

    /// The least disturbed of `runs` runs.
    static func fastest(of runs: Int = 3, _ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var best: Duration?
        for _ in 0..<runs {
            let duration = clock.measure(work)
            best = min(best ?? duration, duration)
        }
        return best ?? .zero
    }

    // MARK: X1, X5: the forward-chaining loop

    @Test("the current loop decides every closure as the 21df5d7 loop does",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func loops() async throws {
        let corpus = try #require(Self.corpus())
        let derivation = corpus.derivation
        let starts = Self.startSets(corpus)
        let mismatches = await withTaskGroup(of: [String].self, returning: [String].self) { group in
            for (name, engine) in derivation.namedEngines {
                group.addTask {
                    var found: [String] = []
                    for start in starts {
                        for options in [Derivation.Options.standard, .all] {
                            let legacy = engine.closure(from: start, options: options, loop: .legacy)
                            let current = engine.closure(from: start, options: options)
                            if !current.decidesLike(legacy) {
                                found.append("\(name) \(start.sorted()) \(options.settingName)")
                            }
                        }
                    }
                    return found
                }
            }
            var all: [String] = []
            for await found in group { all += found }
            return all
        }
        let compared = starts.count * 2 * derivation.namedEngines.count
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) closures differ: \(mismatches.prefix(10))")

        // What Derivation.init spends its closures on: every object, both
        // settings, on the main engine.
        let ids = derivation.mainEngine.objects.ids
        func singles(_ loop: Derivation.Engine.Loop) -> Duration {
            Self.fastest {
                for id in ids {
                    for options in [Derivation.Options.standard, .all] {
                        _ = derivation.mainEngine.closure(from: [id], options: options, loop: loop)
                    }
                }
            }
        }
        let legacy = singles(.legacy)
        let current = singles(.current)
        print("derivation loops, \(corpus.modeName): \(compared) closures on \(derivation.namedEngines.count) "
            + "engines compared, \(mismatches.count) differ; the \(ids.count * 2) single-object closures "
            + "of a load take \(LoadTimings.format(legacy)) with the 21df5d7 loop and "
            + "\(LoadTimings.format(current)) with the current one (min of 3)")
    }
}

// MARK: - Helpers

extension Derivation {
    /// Every engine the derivation runs, named, for the equivalence tests.
    var namedEngines: [(name: String, engine: Engine)] {
        var engines: [(name: String, engine: Engine)] = [("main", mainEngine)]
        for (chain, engine) in zip(ChainClass.composable, restrictedEngines) {
            engines.append(("restricted to \(chain.rawValue)", engine))
        }
        for (chain, engine) in zip(ChainClass.composable, cleanEngines) {
            engines.append(("clean \(chain.rawValue)", engine))
        }
        engines.append(("clean, any class", cleanAnyEngine))
        engines.append(("relaxed", relaxedEngine))
        return engines
    }
}

extension Derivation.Closure {
    /// Everything a loop decides: each fact, weakened fact and `metBy`
    /// producer's fact, and each refusal with its reasons.
    func decidesLike(_ other: Derivation.Closure) -> Bool {
        facts == other.facts && weakFacts == other.weakFacts && established == other.established
            && refused == other.refused
    }
}

extension Derivation.Options {
    var settingName: String { includesIdealisedModels ? "all models" : "default models" }
}

/// A seeded generator, so the sampled start sets are the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
