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

    @Test("the current loop decides every closure as the 21df5d7 loop does",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func loops() async throws {
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
                    let legacy = named.engine.closure(from: start, options: options, loop: .legacy)
                    let current = named.engine.closure(from: start, options: options)
                    let shared = options.includesIdealisedModels ? both.all : both.standard
                    if !current.decidesLike(legacy) || !shared.decidesLike(legacy) {
                        found.append("\(named.name) \(start.sorted()) \(options.settingName)")
                    }
                }
            }
            return found
        }.flatMap { $0 }
        let compared = starts.count * 2 * derivation.namedEngines.count
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(compared) closures differ: \(mismatches.prefix(10))")

        // The single-object closures the derivation keeps, read back.
        let ids = derivation.mainEngine.objects.ids
        for id in ids {
            for options in [Derivation.Options.standard, .all] {
                let legacy = derivation.mainEngine.closure(from: [id], options: options, loop: .legacy)
                #expect(derivation.closure(from: [id], options: options).decidesLike(legacy),
                        "the kept closure of \(id), \(options.settingName)")
            }
        }

        // What Derivation.init spends its closures on: every object, both
        // settings, on the main engine.
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
        let shared = Self.fastest {
            for id in ids { _ = derivation.mainEngine.closures(from: [id]) }
        }
        let build = Self.fastest {
            _ = Derivation(manifest: corpus.manifest, curation: corpus.curation)
        }
        print("derivation loops, \(corpus.modeName): \(compared) closures on \(derivation.namedEngines.count) "
            + "engines compared, \(mismatches.count) differ; the \(ids.count * 2) single-object closures "
            + "of a load take \(LoadTimings.format(legacy)) with the 21df5d7 loop, "
            + "\(LoadTimings.format(current)) with the current one and \(LoadTimings.format(shared)) "
            + "sharing a run between settings; Derivation.init \(LoadTimings.format(build)) (min of 3)")
    }

    // MARK: X2: each cited page parsed once

    @Test("missingQuotes, parsing each page once, misses what a parse per citation misses",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func quotesParsedOnce() throws {
        let corpus = try #require(Self.corpus())
        let derivation = corpus.derivation
        let content = corpus.cloneRoot.appending(path: "content")
        var read: [String: String] = [:]
        var cited = 0
        for entry in derivation.curation.entries {
            for citation in entry.cites {
                cited += 1
                let path = citation.contentPath
                if read[path] == nil {
                    read[path] = try? String(contentsOf: content.appending(path: path), encoding: .utf8)
                }
            }
        }
        let texts = read

        // The shape of 21df5d7: the page parsed again for each citation.
        func perCitation() -> [Derivation.MissingQuote] {
            var missing: [Derivation.MissingQuote] = []
            for entry in derivation.curation.entries {
                for citation in entry.cites {
                    let found = texts[citation.contentPath].map {
                        CurationQuote.contains(citation.quote, section: citation.section, in: $0)
                    } ?? false
                    if !found {
                        missing.append(Derivation.MissingQuote(entryID: entry.id, citation: citation))
                    }
                }
            }
            return missing
        }
        let legacyMissing = perCitation()
        let missing = derivation.missingQuotes { texts[$0] }
        #expect(missing == legacyMissing)
        #expect(Set(missing.map(\.citation)) == Set(legacyMissing.map(\.citation)))

        let legacy = Self.fastest { _ = perCitation() }
        let current = Self.fastest { _ = derivation.missingQuotes { texts[$0] } }
        print("derivation quotes, \(corpus.modeName): \(cited) citations on \(texts.count) pages, "
            + "\(missing.count) missing either way; \(LoadTimings.format(legacy)) parsing the page "
            + "for each citation, \(LoadTimings.format(current)) parsing it once (min of 3)")
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

    /// One target's implied-by, with and without the prefilter.
    private struct Backward: Sendable {
        let differs: String?
        let filtered: Duration
        let unfiltered: Duration
    }

    /// One target's implied-by, timed with and without the prefilter.
    private static func backward(_ derivation: Derivation, _ target: String,
                                 _ options: Derivation.Options) -> Backward {
        let clock = ContinuousClock()
        let started = clock.now
        let filtered = derivation.implying(target, options: options)
        let between = clock.now
        let unfiltered = derivation.implying(target, options: options, prefilter: false)
        let ended = clock.now
        return Backward(
            differs: filtered == unfiltered ? nil : "\(target), \(options.settingName)",
            filtered: started.duration(to: between), unfiltered: between.duration(to: ended))
    }

    @Test("the Horn prefilter changes no implied-by list, completion, chain or circumvention",
          .enabled(if: DerivationEquivalenceTests.corpus() != nil, DerivationCorpusTests.state.skipComment))
    func hornPrefilter() async throws {
        let corpus = try #require(Self.corpus())
        let derivation = corpus.derivation
        let manifest = corpus.manifest
        let ids = manifest.objectsByID.keys.sorted(by: Derivation.precedes)

        // What it rests on: every object a closure derives, in full,
        // weakened or as a `metBy` producer's fact, plain Horn closure
        // reaches too. Every engine, every object, both settings.
        // One task per engine, a few at a time.
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

        // Implied-by for every target in both settings: the pair closures the
        // prefilter skips are all run here, once.
        let targets = ids.filter { derivation.nodeType($0) != Derivation.excludedType }
        // A few at a time: all of them (468 on the wiki) queued at once held
        // every cooperative thread for about a minute of debug CPU.
        let jobs: [(target: String, options: Derivation.Options)] = targets.flatMap { target in
            [Derivation.Options.standard, .all].map { (target: target, options: $0) }
        }
        let backward = await Self.fewAtATime(jobs) { job in
            Self.backward(derivation, job.target, job.options)
        }
        let differing = backward.compactMap(\.differs)
        #expect(backward.count == targets.count * 2)
        #expect(differing.isEmpty, "implied-by differs for \(differing.prefix(10))")

        // Completions for every no-path question the golden file asks.
        var noPath = 0
        for record in corpus.golden["queries"]?.array ?? [] {
            let start = record["start"]?.strings ?? []
            let target = record["target"]?.string ?? ""
            guard (start + [target]).allSatisfy({ manifest.object($0) != nil }) else { continue }
            let options = Derivation.Options(includesIdealisedModels: record["includeIdealised"]?.bool ?? false)
            guard case .notDerived(let answer) = derivation.answer(from: Set(start), to: target, options: options)
            else { continue }
            noPath += 1
            let closure = derivation.closure(from: Set(start), options: options)
            let filtered = derivation.completions(start: answer.start, target: target, closure: closure,
                                                  options: options)
            let unfiltered = derivation.completions(start: answer.start, target: target, closure: closure,
                                                    options: options, prefilter: false)
            let id = record["id"]?.string ?? "?"
            #expect(filtered.offered == unfiltered.offered, "\(id): completions")
            #expect(filtered.count == unfiltered.count, "\(id): completion count")
            #expect(filtered.restating == unfiltered.restating, "\(id): the question becomes")
            #expect(answer.completions == unfiltered.offered, "\(id): the answer's completions")
        }
        #expect(noPath > 0)

        // R8's chains, as the invariants and the answers ask them, and R12's
        // circumventions.
        var chains = 0
        func compareChain(_ start: [String], _ target: String, _ reductionClass: String) {
            let filtered = derivation.chainExists(from: start, to: target, against: reductionClass)
            let unfiltered = derivation.chainExists(from: start, to: target, against: reductionClass,
                                                    prefilter: false)
            #expect(filtered == unfiltered, "\(start) ⇒ \(target) against \(reductionClass)")
            chains += 1
        }
        for barrier in manifest.barriers {
            for rule in Derivation.consequenceRules(of: barrier, in: manifest) {
                compareChain(barrier.hypotheses, barrier.conclusion, rule.reductionClass)
            }
        }
        let derivedBarriers = derivation.allDerivedBarriers()
        var circumventions = 0
        for derived in derivedBarriers {
            compareChain(derived.hypotheses, derived.conclusion, derived.reductionClass.rawValue)
            for relationID in derived.barrier.circumventedBy {
                let filtered = derivation.isDerivable(from: derived.hypotheses, to: derived.conclusion,
                                                      through: relationID)
                let unfiltered = derivation.isDerivable(from: derived.hypotheses, to: derived.conclusion,
                                                        through: relationID, prefilter: false)
                #expect(filtered == unfiltered,
                        "\(derived.hypotheses) ⇒ \(derived.conclusion) through \(relationID)")
                circumventions += 1
            }
        }

        let fast = backward.reduce(Duration.zero) { $0 + $1.filtered }
        let slow = backward.reduce(Duration.zero) { $0 + $1.unfiltered }
        print("derivation prefilter, \(corpus.modeName): implied-by for \(targets.count) targets in both "
            + "settings takes \(LoadTimings.format(fast)) with the Horn prefilter and "
            + "\(LoadTimings.format(slow)) without (summed over tasks), \(differing.count) differ; "
            + "\(noPath) no-path completions, \(chains) chains and \(circumventions) circumventions "
            + "compared")
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
