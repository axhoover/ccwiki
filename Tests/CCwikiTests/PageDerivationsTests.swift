import Foundation
import Testing
@testable import CCwiki

/// The inspector's derived sections (relations-explorer.md §3): depth two
/// and up, sorted, one block per object per role, object pages only.
struct PageDerivationsTests {

    private static func derivations(_ path: String) throws -> PageDerivations {
        let derivation = try ExplorerFixture.derivation()
        let manifest = derivation.manifest
        return PageDerivations(path: path, manifest: manifest, derivation: derivation,
                               labels: ExplorerFixture.labels(manifest))
    }

    private static let objectPages = [
        "Primitives/hash-function.md", "Primitives/prg.md", "Primitives/prf.md",
        "Primitives/ske.md", "Primitives/pke.md", "Assumptions/lwe.md",
    ]

    @Test("no derived row is a single recorded step")
    func noRowBelowDepthTwo() throws {
        for path in Self.objectPages {
            let page = try Self.derivations(path)
            for block in page.blocks {
                let depths = block.rows.map { $0.depth }
                let allDerived = depths.allSatisfy { $0 >= 2 }
                #expect(allDerived, "\(path) \(block.id): \(depths)")
            }
        }
    }

    @Test("rows are sorted by depth, then by label")
    func rowsSorted() throws {
        let page = try Self.derivations("Primitives/ske.md")
        let block = try #require(page.blocks(.impliedBy).first)
        let labels = block.rows.map { $0.label }
        let depths = block.rows.map { $0.depth }
        #expect(labels == ["Pseudorandom generator",
                           "Hash function § Preimage resistance (one-wayness)",
                           "Hash function § Collision resistance"])
        #expect(depths == [2, 3, 4])
        #expect(page.count(.impliedBy) == 3)
        #expect(page.count(.implies) == 0)
    }

    @Test("a page hosting several objects gets one block per object per role, host first")
    func multiObjectPage() throws {
        let page = try Self.derivations("Primitives/hash-function.md")
        let ids = page.blocks.map { $0.id }
        #expect(ids == ["crhf/implies", "owf/implies"])
        #expect(page.needsObjectNames(.implies))
        let crhf = try #require(page.blocks.first)
        let targets = crhf.rows.map { $0.link.objectID }
        #expect(targets == ["prg", "prf", "ske"])
    }

    @Test("a reduction page or a barrier page gets none")
    func edgePagesGetNone() throws {
        let reduction = try Self.derivations("Reductions/red-owf-to-prg.md")
        let barrier = try Self.derivations("Barriers/bar-owf-to-pke.md")
        #expect(reduction.isEmpty)
        #expect(barrier.isEmpty)
    }

    @Test("a page whose objects derive nothing in two steps gets none")
    func nothingDerived() throws {
        let page = try Self.derivations("Primitives/pke.md")
        #expect(page.isEmpty)
    }

    @Test("a row says it is derived, how far, and asks the explorer for its proof")
    func rowWording() throws {
        let page = try Self.derivations("Primitives/prg.md")
        let implies = try #require(page.blocks(.implies).first?.rows.first)
        #expect(implies.label == "Symmetric key encryption")
        #expect(implies.statement == "Pseudorandom generator ⇒* Symmetric key encryption "
            + "(derived by CCwiki from 2 recorded reductions)")
        #expect(implies.query == ExplorerQuery(from: ["prg"], to: "ske"))
        #expect(implies.modelsLine == nil)
        #expect(implies.accessibilityLabel == "Symmetric key encryption, derived in 2 steps")
        let help = implies.help.components(separatedBy: "\n")
        #expect(help == [
            "Pseudorandom generator ⇒* Symmetric key encryption",
            "Derived by CCwiki from 2 recorded reductions; 2 steps.",
            "Fully black-box: every step is",
            "Click to see the proof.",
        ])

        let impliedBy = try #require(page.blocks(.impliedBy).first?.rows.first)
        #expect(impliedBy.label == "Hash function § Collision resistance")
        #expect(impliedBy.query == ExplorerQuery(from: ["crhf"], to: "prg"))
    }

    @Test("rows that assume nothing form one group with no heading")
    func groupsWithoutAssumptions() throws {
        let page = try Self.derivations("Primitives/ske.md")
        let block = try #require(page.blocks(.impliedBy).first)
        #expect(block.groups.count == 1)
        let group = try #require(block.groups.first)
        #expect(group.heading == nil)
        #expect(group.rows.count == block.rows.count)
    }
}
