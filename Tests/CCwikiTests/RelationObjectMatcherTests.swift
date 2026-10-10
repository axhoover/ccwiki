import Foundation
import Testing
@testable import CCwiki

/// The explorer's object picker: what a typed name finds, in what order, and
/// what it never offers (relations-explorer.md §2.3, §7).
struct RelationObjectMatcherTests {

    private static func matcher() throws -> RelationObjectMatcher {
        let derivation = try ExplorerFixture.derivation()
        let manifest = derivation.manifest
        return RelationObjectMatcher(
            manifest: manifest, labels: ExplorerFixture.labels(manifest),
            participants: derivation.participants(.all))
    }

    private static func firstID(_ query: String) throws -> String? {
        try matcher().matches(query, excluding: [], limit: 8).first?.id
    }

    @Test("owf, OWF and preimage find the one-wayness section first, not the hash function page")
    func owfFindsTheVariant() throws {
        let typed = try Self.firstID("owf")
        let capitals = try Self.firstID("OWF")
        let word = try Self.firstID("preimage")
        #expect(typed == "owf")
        #expect(capitals == "owf")
        #expect(word == "owf")
    }

    @Test("a section is named with its host, and says so on the second line")
    func variantDetail() throws {
        let item = try #require(try Self.matcher().matches("owf", excluding: [], limit: 8).first)
        #expect(item.label == "Hash function § Preimage resistance (one-wayness)")
        #expect(item.detail == "Section of Hash function")
    }

    @Test("ot finds oblivious transfer before OT Extension")
    func otFindsObliviousTransfer() throws {
        let items = try Self.matcher().matches("ot", excluding: [], limit: 8)
        let ids = items.map { $0.id }
        #expect(ids.first == "ot")
        let extensionIndex = ids.firstIndex(of: "ot-extension")
        #expect(extensionIndex != nil)
    }

    @Test("lwe finds LWE before its sections")
    func lweBeforeVariants() throws {
        let items = try Self.matcher().matches("lwe", excluding: [], limit: 8)
        let ids = items.map { $0.id }
        #expect(ids == ["lwe", "ring-lwe"])
    }

    @Test("a complexity class is never offered, and the field can say why")
    func noComplexityClass() throws {
        let matcher = try Self.matcher()
        for query in ["bpp", "BPP", "bounded", "probabilistic"] {
            let ids = matcher.matches(query, excluding: [], limit: 8).map { $0.id }
            #expect(!ids.contains("bpp"))
        }
        let onlyClasses = matcher.matchesOnlyComplexityClasses("bpp")
        #expect(onlyClasses)
        let notOnlyClasses = matcher.matchesOnlyComplexityClasses("prg")
        #expect(!notOnlyClasses)
    }

    @Test("a model node is offered, and named as a model")
    func modelNodeOffered() throws {
        let items = try Self.matcher().matches("rom", excluding: [], limit: 8)
        let first = try #require(items.first)
        #expect(first.id == "rom")
        #expect(first.detail == "Idealised model")
    }

    @Test("objects already chosen are never suggested")
    func excludedNeverReturned() throws {
        let matcher = try Self.matcher()
        let ids = matcher.matches("p", excluding: ["prg", "prf"], limit: 20).map { $0.id }
        #expect(!ids.contains("prg"))
        #expect(!ids.contains("prf"))
        #expect(ids.contains("pke"))
    }

    @Test("an empty query suggests nothing, and the limit holds")
    func emptyAndLimit() throws {
        let matcher = try Self.matcher()
        let empty = matcher.matches("   ", excluding: [], limit: 8)
        #expect(empty.isEmpty)
        let limited = matcher.matches("o", excluding: [], limit: 3)
        #expect(limited.count <= 3)
    }

    @Test("the empty matcher matches nothing")
    func emptyMatcher() {
        let items = RelationObjectMatcher.empty.matches("owf", excluding: [], limit: 8)
        #expect(items.isEmpty)
        let onlyClasses = RelationObjectMatcher.empty.matchesOnlyComplexityClasses("owf")
        #expect(!onlyClasses)
    }
}
