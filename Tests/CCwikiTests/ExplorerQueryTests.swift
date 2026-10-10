import Foundation
import Testing
@testable import CCwiki

/// The explorer's question: how it is stored, which mode it asks, and what
/// "Explore From This Page" seeds it with (relations-explorer.md §2.5, §2.11,
/// §2.12).
struct ExplorerQueryTests {

    @Test("a question survives a JSON round trip, toggle and all")
    func codableRoundTrip() throws {
        let query = ExplorerQuery(from: ["owf", "kem"], to: "pke", includesIdealisedModels: true)
        let data = try JSONEncoder().encode(query)
        let decoded = try JSONDecoder().decode(ExplorerQuery.self, from: data)
        #expect(decoded == query)
    }

    @Test("a stored question missing keys still reads")
    func decodesMissingKeys() throws {
        let data = Data(#"{"from":["ddh"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ExplorerQuery.self, from: data)
        #expect(decoded == ExplorerQuery(from: ["ddh"]))
    }

    @Test("a launch turns the toggle off and keeps the question; a Recent entry keeps its toggle")
    func launchingResetsToggle() throws {
        let query = ExplorerQuery(from: ["fac"], to: "pke", includesIdealisedModels: true)
        let launched = query.launching()
        #expect(launched.from == ["fac"])
        #expect(launched.to == "pke")
        #expect(!launched.includesIdealisedModels)

        // Recent entries are stored as asked, so they restore the toggle.
        let data = try JSONEncoder().encode([query])
        let recents = try JSONDecoder().decode([ExplorerQuery].self, from: data)
        let restored = try #require(recents.first)
        #expect(restored.includesIdealisedModels)
    }

    @Test("the four modes")
    func modes() {
        #expect(ExplorerQuery().mode == .empty)
        #expect(ExplorerQuery(from: ["ddh"]).mode == .forward)
        #expect(ExplorerQuery(to: "pke").mode == .backward)
        #expect(ExplorerQuery(from: ["owf", "kem"], to: "pke").mode == .question)
    }

    @Test("the toggle is the options the engine is asked with")
    func options() {
        let on = ExplorerQuery(from: ["rom"], includesIdealisedModels: true).options
        let off = ExplorerQuery(from: ["rom"]).options
        #expect(on == .all)
        #expect(off == .standard)
    }

    @Test("entry order is not part of the question")
    func sameQuestion() {
        let first = ExplorerQuery(from: ["owf", "kem"], to: "pke")
        let second = ExplorerQuery(from: ["kem", "owf"], to: "pke")
        let toggled = ExplorerQuery(from: ["kem", "owf"], to: "pke", includesIdealisedModels: true)
        #expect(first.isSameQuestion(as: second))
        #expect(first.key == second.key)
        #expect(!first.isSameQuestion(as: toggled))
    }

    @Test("only a single object swaps: a conjunction is never a conclusion")
    func swapping() {
        let single = ExplorerQuery(from: ["ddh"], to: "ot")
        let swapped = single.swapped()
        #expect(swapped.from == ["ot"])
        #expect(swapped.to == "ddh")

        let conjunction = ExplorerQuery(from: ["owf", "kem"], to: "pke")
        #expect(!conjunction.canSwap)
        #expect(conjunction.swapped() == conjunction)
    }

    @Test("editing keeps the field's order and never repeats an object")
    func editing() {
        let query = ExplorerQuery(from: ["lpn", "kem"], to: "pke")
        #expect(query.adding("ske").from == ["lpn", "kem", "ske"])
        #expect(query.adding("kem").from == ["lpn", "kem"])
        #expect(query.replacingStart("lpn", with: "low-noise-lpn").from == ["low-noise-lpn", "kem"])
        #expect(query.replacingStart("lpn", with: "kem").from == ["kem"])
    }

    @Test("objects the manifest no longer has are named, and left out")
    func staleObjects() throws {
        let manifest = try ExplorerFixture.manifest()
        let query = ExplorerQuery(from: ["owf", "gone"], to: "vanished")
        #expect(query.unknownIDs(in: manifest) == ["gone", "vanished"])
        let kept = query.removing(query.unknownIDs(in: manifest))
        #expect(kept.from == ["owf"])
        #expect(kept.to == nil)
    }

    @Test("the question as a statement: ⇒* for every mode, … for what is left open")
    func statements() throws {
        let manifest = try ExplorerFixture.manifest()
        let labels = ExplorerFixture.labels(manifest)
        let question = ExplorerQuery(from: ["kem", "ske"], to: "pke").statement(labels: labels)
        let forward = ExplorerQuery(from: ["prg"]).statement(labels: labels)
        let backward = ExplorerQuery(to: "pke").statement(labels: labels)
        let empty = ExplorerQuery().statement(labels: labels)
        #expect(question == "Key encapsulation mechanism ∧ Symmetric key encryption ⇒* Public key encryption")
        #expect(forward == "Pseudorandom generator ⇒* …")
        #expect(backward == "… ⇒* Public key encryption")
        #expect(empty == nil)
    }

    // MARK: Seeding from a page

    private static func seed(_ path: String, anchor: String? = nil) throws -> ExplorerQuery? {
        let derivation = try ExplorerFixture.derivation()
        let manifest = derivation.manifest
        let subject = PageRelations(path: path, manifest: manifest).subject
        return ExplorerQuery.seed(for: subject, activeAnchor: anchor, manifest: manifest,
                                  derivation: derivation)
    }

    @Test("on an object page, the section being read is the question's object")
    func seedsTheActiveVariant() throws {
        let query = try #require(try Self.seed("Primitives/hash-function.md",
                                               anchor: "collision-resistance"))
        #expect(query.from == ["crhf"])
        #expect(query.to == nil)
        #expect(!query.includesIdealisedModels)
    }

    @Test("on an object page with no section being read, the host")
    func seedsTheHost() throws {
        let query = try #require(try Self.seed("Primitives/hash-function.md"))
        #expect(query.from == ["hash-function"])
        let lwe = try #require(try Self.seed("Assumptions/lwe.md", anchor: "no-such-heading"))
        #expect(lwe.from == ["lwe"])
    }

    @Test("on a reduction page, its hypotheses together, with To left open")
    func seedsAReduction() throws {
        let query = try #require(try Self.seed("Reductions/red-kem-and-ske-to-pke.md"))
        #expect(query.from == ["kem", "ske"])
        #expect(query.to == nil)
    }

    @Test("on a barrier page, the edge it rules out")
    func seedsABarrier() throws {
        let query = try #require(try Self.seed("Barriers/bar-owf-to-pke.md"))
        #expect(query.from == ["owf"])
        #expect(query.to == "pke")
    }

    @Test("nothing on a complexity class, an inclusion into one, or a page the manifest does not know")
    func seedsNothingForClasses() throws {
        let complexity = try Self.seed("Complexity/bpp.md")
        let inclusion = try Self.seed("Reductions/red-lwe-in-bpp.md")
        let unknown = try Self.seed("References/nobody.md")
        #expect(complexity == nil)
        #expect(inclusion == nil)
        #expect(unknown == nil)
    }

    @Test("nothing on any page when nothing can be derived, as without the bundled curation")
    func seedsNothingWithoutDerivations() throws {
        let manifest = try ExplorerFixture.manifest()
        // What `Derivation(manifest:)` builds when the curation is missing.
        let derivation = Derivation.empty
        let paths = ["Primitives/hash-function.md", "Reductions/red-kem-and-ske-to-pke.md",
                     "Barriers/bar-owf-to-pke.md"]
        for path in paths {
            let subject = PageRelations(path: path, manifest: manifest).subject
            let query = ExplorerQuery.seed(for: subject, activeAnchor: nil, manifest: manifest,
                                           derivation: derivation)
            #expect(query == nil, "\(path)")
        }
    }
}
