import Foundation
@testable import CCwiki

/// A small relationship graph in the shape of the wiki's, for the explorer's
/// and the inspector's pure parts: a hash function page hosting OWF and CRHF
/// as sections, a chain from OWF to PKE through KEM + SKE, a three-premise
/// edge, a model node, a complexity class, and one barrier.
///
/// ```
/// crhf ⇒ owf ⇒ prg ⇒ prf ⇒ ske;  kem ∧ ske ⇒ pke;  lwe ⇒ pke;  lwe ⇒ ring-lwe
/// hash-function ∧ prf ⇒ mpc;  ot ⇒ mpc;  ot-extension ⇒ ot
/// rom ⇒ oihf (random oracle model);  oihf ⇒ ot (free)
/// a ∧ b ∧ c ⇒ d;  lwe ⊆ bpp (inclusion, never used)
/// barrier: owf ⇏ pke (relativizing)
/// ```
enum ExplorerFixture {

    static func manifest() throws -> RelationsManifest {
        let objects: [[String: Any]] = [
            object("hash-function", title: "Hash function",
                   aliases: ["OWF", "One-way function", "CRH"]),
            object("owf", title: "Preimage resistance (one-wayness)", of: "hash-function",
                   anchor: "preimage-resistance-one-wayness"),
            object("crhf", title: "Collision resistance", of: "hash-function",
                   anchor: "collision-resistance"),
            object("prg", title: "Pseudorandom generator", aliases: ["PRG"]),
            object("prf", title: "Pseudorandom function", aliases: ["PRF"]),
            object("ske", title: "Symmetric key encryption", aliases: ["SKE"]),
            object("kem", title: "Key encapsulation mechanism", aliases: ["KEM"]),
            object("pke", title: "Public key encryption", aliases: ["PKE"]),
            object("mpc", title: "Secure multi-party computation", aliases: ["MPC"]),
            object("ot", title: "Oblivious transfer", aliases: ["OT", "Oblivious Transfer"]),
            object("ot-extension", title: "OT Extension"),
            object("oihf", title: "Oblivious interactive hash function", aliases: ["OIHF"]),
            object("lwe", title: "Learning with errors", type: "assumption", aliases: ["LWE"]),
            object("ring-lwe", title: "Ring LWE", type: "assumption", of: "lwe", anchor: "ring-lwe"),
            object("rom", title: "Random Oracle Model", type: "glossary", aliases: ["ROM"]),
            object("bpp", title: "Bounded-error probabilistic polynomial time",
                   type: "complexity-class", aliases: ["BPP"]),
            object("a", title: "Alpha"),
            object("b", title: "Beta"),
            object("c", title: "Gamma"),
            object("d", title: "Delta"),
        ]
        let reductions: [[String: Any]] = [
            reduction("red-crhf-to-owf", ["crhf"], "owf", title: "CRHF ⇒ OWF", source: "Dam87"),
            reduction("red-owf-to-prg", ["owf"], "prg", title: "OWF ⇒ PRG", source: "HILL99"),
            reduction("red-prg-to-prf", ["prg"], "prf", title: "PRG ⇒ PRF (GGM)", source: "GGM86"),
            reduction("red-prf-to-ske", ["prf"], "ske", title: "PRF ⇒ CPA-secure SKE",
                      source: "folklore"),
            reduction("red-kem-and-ske-to-pke", ["kem", "ske"], "pke", title: "KEM + SKE ⇒ PKE",
                      source: "CS03"),
            reduction("red-lwe-to-pke", ["lwe"], "pke", title: "LWE ⇒ PKE", source: "Reg05"),
            reduction("red-lwe-to-ring-lwe", ["lwe"], "ring-lwe", title: "LWE ⇒ Ring LWE",
                      source: "LPR10"),
            reduction("red-hash-function-and-prf-to-mpc", ["hash-function", "prf"], "mpc",
                      title: "Hash + PRF ⇒ MPC", source: "folklore"),
            reduction("red-ot-to-mpc", ["ot"], "mpc", title: "OT ⇒ MPC", source: "Kil88"),
            reduction("red-ot-extension-to-ot", ["ot-extension"], "ot", title: "OT extension ⇒ OT",
                      source: "IKNP03"),
            reduction("red-rom-to-oihf", ["rom"], "oihf", title: "ROM ⇒ OIHF", source: "BH26",
                      model: "rom"),
            reduction("red-oihf-to-ot", ["oihf"], "ot", title: "OIHF ⇒ OT", source: "BH26",
                      reductionClass: "free"),
            reduction("red-abc-to-d", ["a", "b", "c"], "d", title: "A + B + C ⇒ D", source: "ABC20"),
            reduction("red-lwe-in-bpp", ["lwe"], "bpp", title: "LWE ⊆ BPP", source: "folklore",
                      reductionClass: "free", kind: "inclusion"),
        ]
        let barriers: [[String: Any]] = [
            barrier("bar-owf-to-pke", ["owf"], "pke", title: "No relativizing reduction from OWF to PKE",
                    source: "IR89", reductionClass: "relativizing"),
        ]
        return try manifest(objects: objects, reductions: reductions, barriers: barriers)
    }

    /// A manifest of just these, for a test that needs a shape the shared
    /// graph does not have.
    static func manifest(objects: [[String: Any]], reductions: [[String: Any]],
                         barriers: [[String: Any]] = []) throws -> RelationsManifest {
        let root: [String: Any] = [
            "version": 1,
            "classes": classes,
            "classSentinels": ["unstated"],
            "propositions": [String: Any](),
            "objects": objects,
            "reductions": reductions,
            "barriers": barriers,
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return RelationsManifest.decode(data)
    }

    /// The derivation over the fixture, with no curation: nothing here needs
    /// one, and the engine's own tests cover it.
    static func derivation() throws -> Derivation {
        Derivation(manifest: try manifest(), curation: .empty)
    }

    /// The derivation over a graph of just these, likewise uncurated.
    static func derivation(objects: [[String: Any]], reductions: [[String: Any]],
                           barriers: [[String: Any]] = []) throws -> Derivation {
        let manifest = try manifest(objects: objects, reductions: reductions, barriers: barriers)
        return Derivation(manifest: manifest, curation: .empty)
    }

    static func labels(_ manifest: RelationsManifest) -> RelationLabels {
        RelationLabels(manifest: manifest, index: nil)
    }

    // MARK: Builders

    /// The wiki's class graph: `implies` points narrower → broader.
    static var classes: [String: Any] {
        let implies: [String: [String]] = [
            "fully-black-box": ["semi-black-box", "relativizing"],
            "semi-black-box": ["weakly-black-box", "forall-exists-semi-black-box"],
            "forall-exists-semi-black-box": ["forall-exists-weakly-black-box"],
            "weakly-black-box": ["forall-exists-weakly-black-box", "free"],
            "forall-exists-weakly-black-box": ["free"],
            "relativizing": ["forall-exists-semi-black-box"],
            "free": [],
            "fixed-construction": ["free"],
        ]
        let titles: [String: String] = [
            "fully-black-box": "Fully black-box",
            "semi-black-box": "Semi black-box",
            "forall-exists-semi-black-box": "∀∃ semi black-box",
            "weakly-black-box": "Weakly black-box",
            "forall-exists-weakly-black-box": "∀∃ weakly black-box",
            "relativizing": "Relativizing",
            "free": "Free",
            "fixed-construction": "Fixed construction",
        ]
        var classes: [String: Any] = [:]
        for (name, broader) in implies {
            let entry: [String: Any] = ["title": titles[name] ?? name, "implies": broader]
            classes[name] = entry
        }
        return classes
    }

    static func object(_ id: String, title: String, type: String = "primitive",
                       aliases: [String] = [], of host: String? = nil,
                       anchor: String? = nil) -> [String: Any] {
        let folder = type == "assumption" ? "Assumptions"
            : type == "glossary" ? "Glossary"
            : type == "complexity-class" ? "Complexity" : "Primitives"
        let page = host ?? id
        var object: [String: Any] = [
            "id": id,
            "kind": host == nil ? "object" : "variant",
            "type": type,
            "page": "content/\(folder)/\(page).md",
            "slug": page,
            "title": title,
            "aliases": aliases,
            "unlisted": false,
        ]
        if let host {
            object["of"] = host
            object["anchor"] = "#" + (anchor ?? id)
        }
        return object
    }

    static func reduction(_ id: String, _ hypotheses: [String], _ conclusion: String,
                          title: String, source: String,
                          reductionClass: String = "fully-black-box", model: String = "standard",
                          kind: String = "implication") -> [String: Any] {
        [
            "id": id,
            "kind": kind,
            "hypotheses": hypotheses,
            "conclusion": conclusion,
            "class": reductionClass,
            "model": model,
            "source": [source],
            "via": [String](),
            "heuristic": false,
            "securityLoss": "",
            "status": "draft",
            "page": "content/Reductions/\(id).md",
            "slug": id,
            "title": title,
        ]
    }

    static func barrier(_ id: String, _ hypotheses: [String], _ conclusion: String, title: String,
                        source: String, reductionClass: String) -> [String: Any] {
        let consequences: [[String: Any]] = [
            ["kind": "contradiction", "target": "", "class": reductionClass],
        ]
        return [
            "id": id,
            "hypotheses": hypotheses,
            "conclusion": conclusion,
            "class": reductionClass,
            "consequences": consequences,
            "strength": "unconditional",
            "conditionalOn": [String](),
            "circumventedBy": [String](),
            "source": [source],
            "status": "draft",
            "page": "content/Barriers/\(id).md",
            "slug": id,
            "title": title,
        ]
    }
}
