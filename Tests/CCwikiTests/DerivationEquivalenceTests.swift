import Foundation
import Testing
@testable import CCwiki

/// Track X of plans/efficiency.md §2.6 on the real manifest: what its
/// shortcuts rest on, each held to the longer way round. One run for both
/// settings decides as a run for each, plain Horn closure reaches everything
/// a closure derives (the prefilter's premise), an inspector row carries its
/// proof's counts, and a page parsed once answers every quote as a fresh
/// parse does.
///
/// The 21df5d7 loop and the prefilter's off switch, which these suites ran
/// beside the new code, went after 0.1.4 (efficiency.md §2.1).
///
/// Gated on `CCWIKI_WIKI` like DerivationCorpusTests, whose corpus they share,
/// in either of its modes: none of this needs the golden file. Each prints
/// what it compared; no assertion is about time.
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

    /// `work` on each item, a few at a time: as many as leave one
    /// cooperative thread free. A sweep queued whole held every thread for
    /// up to a minute of debug CPU, and a test racing a deadline behind it
    /// lost. The low priority asked for may not hold, since a group's child
    /// can start at its parent's priority; the width is what leaves the
    /// thread. Results come in the order the items finish.
    static func fewAtATime<Item: Sendable, Output: Sendable>(
        _ items: [Item], _ work: @escaping @Sendable (Item) -> Output
    ) async -> [Output] {
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        return await withTaskGroup(of: Output.self, returning: [Output].self) { group in
            var pending = items.makeIterator()
            for _ in 0..<width {
                guard let item = pending.next() else { break }
                group.addTask(priority: .low) { work(item) }
            }
            var all: [Output] = []
            while let one = await group.next() {
                all.append(one)
                if let item = pending.next() {
                    group.addTask(priority: .low) { work(item) }
                }
            }
            return all
        }
    }

    // MARK: X1, X5: the forward-chaining loop

    @Test("one run for both settings decides every closure as a run for each does",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func sharedRuns() async throws {
        let corpus = try #require(Self.corpus())
        let derivation = corpus.derivation
        let starts = Self.startSets(corpus)
        // One task per engine, a few at a time.
        let mismatches = await Self.fewAtATime(derivation.namedEngines) { named -> [String] in
            var found: [String] = []
            for start in starts {
                // Both settings from one run, as Derivation.init builds the
                // single-object closures.
                let both = named.engine.closures(from: start)
                for options in [Derivation.Options.standard, .all] {
                    let closure = named.engine.closure(from: start, options: options)
                    let shared = options.includesIdealisedModels ? both.all : both.standard
                    if !shared.decidesLike(closure) {
                        found.append("\(named.name) \(start.sorted()) \(options.settingName)")
                    }
                }
            }
            return found
        }.flatMap { $0 }
        let compared = starts.count * 2 * derivation.namedEngines.count
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) closures differ: \(mismatches.prefix(10))")

        // The single-object closures the derivation keeps, read back.
        for id in derivation.mainEngine.objects.ids {
            for options in [Derivation.Options.standard, .all] {
                let closure = derivation.mainEngine.closure(from: [id], options: options)
                #expect(derivation.closure(from: [id], options: options).decidesLike(closure),
                        "the kept closure of \(id), \(options.settingName)")
            }
        }
        print("derivation closures, \(corpus.modeName): \(compared) closures on "
            + "\(derivation.namedEngines.count) engines, one run for both settings against a run "
            + "for each, \(mismatches.count) differ")
    }

    // MARK: X3: the inspector's rows build no proof

    @Test("each inspector link counts its proof as the explorer counts the same proof",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func linksCarryTheirProofs() throws {
        let corpus = try #require(Self.corpus())
        let derivation = corpus.derivation
        let writer = ExplorerWriter(derivation: derivation, labels: .empty)
        var checked = 0
        var unstatedRows = 0
        var wrong: [String] = []
        for id in derivation.manifest.objectsByID.keys.sorted(by: Derivation.precedes) {
            var rows: [(source: String, target: String, link: Derivation.Link)] = []
            for link in derivation.derivedImplications(of: id) {
                rows.append((source: id, target: link.objectID, link: link))
            }
            for link in derivation.derivedSources(of: id) {
                rows.append((source: link.objectID, target: id, link: link))
            }
            for row in rows {
                // What PageDerivations.row built for every row before X3.
                let proof = derivation.closure(from: [row.source], options: .standard).proof(of: row.target)
                let unstated = proof.map { writer.unstatedSteps($0) } ?? 0
                if row.link.unstatedSteps != unstated || row.link.relationCount != proof?.relationIDs.count {
                    wrong.append("\(row.source) ⇒ \(row.target)")
                }
                checked += 1
                if unstated > 0 { unstatedRows += 1 }
            }
        }
        #expect(checked > 0)
        #expect(wrong.isEmpty, "\(wrong.count) links differ: \(wrong.prefix(10))")
        print("derivation links, \(corpus.modeName): \(checked) inspector rows carry their proof's "
            + "counts (\(unstatedRows) with unstated steps), \(wrong.count) differ")
    }

    // MARK: X4: the plain Horn prefilter

    @Test("plain Horn closure reaches everything a closure derives, on every engine",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func hornClosureCovers() async throws {
        let corpus = try #require(Self.corpus())
        let derivation = corpus.derivation
        let ids = corpus.manifest.objectsByID.keys.sorted(by: Derivation.precedes)

        // What the prefilter rests on: every object a closure derives, in
        // full, weakened or as a `metBy` producer's fact, plain Horn closure
        // reaches too. Every engine, every object, both settings, one task
        // per engine, a few at a time.
        let escapes = await Self.fewAtATime(derivation.namedEngines) { named -> [String] in
            var found: [String] = []
            for id in ids {
                for options in [Derivation.Options.standard, .all] {
                    let closure = named.engine.closure(from: [id], options: options)
                    let derived = Set(closure.facts.keys).union(closure.weakFacts.keys)
                        .union(closure.established.values.map(\.objectID))
                    for object in derived.sorted()
                    where !named.engine.mayReach(object, from: [id], options: options) {
                        found.append("\(named.name): \(id) ⇒ \(object), \(options.settingName)")
                    }
                }
            }
            return found
        }.flatMap { $0 }
        #expect(escapes.isEmpty, "closures past their Horn closure: \(escapes.prefix(10))")
        print("derivation Horn closure, \(corpus.modeName): \(ids.count) objects on "
            + "\(derivation.namedEngines.count) engines in both settings, \(escapes.count) derived past it")
    }

    // MARK: X2: the shared quote cases

    private struct QuoteCase: Decodable {
        let name: String
        let page: String
        let section: String?
        let quote: String
        let found: Bool
    }

    private struct QuoteCases: Decodable {
        let cases: [QuoteCase]
    }

    /// The shared cases hold the hazards a corpus page may lack: CRLF, a
    /// lone CR, combining marks after a line break, fences, frontmatter,
    /// a heading twice.
    @Test("one parsed page answers every shared case on it, in any order, as the rule says")
    func quotePageReused() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/quote-cases.json")
        let cases = try JSONDecoder().decode(QuoteCases.self, from: Data(contentsOf: url)).cases
        let byPage = Dictionary(grouping: cases, by: \.page)
        for (text, onPage) in byPage {
            let page = CurationQuote.Page(text)
            for testCase in onPage + onPage.reversed() {
                #expect(page.contains(testCase.quote, section: testCase.section) == testCase.found,
                        "\(testCase.name)")
            }
            // Every other case's quote, against this page, as a fresh parse answers it.
            for other in cases {
                #expect(page.contains(other.quote, section: other.section)
                    == CurationQuote.contains(other.quote, section: other.section, in: text),
                        "\(other.name) on the page of \(onPage[0].name)")
            }
        }
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
