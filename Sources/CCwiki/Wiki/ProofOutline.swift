import Foundation

/// Folds the engine's flat proof into the nested rows of an outline.
///
/// `Derivation.ProofTree.rows` are depth-first with a level each, which is
/// what keeps recursion out of a view body; a native outline needs a tree,
/// so this pure step builds one and the view only nests `DisclosureGroup`s.
/// A row's children are its step's hypotheses in the edge's order, and the
/// second and later premises of a conjunctive step carry `∧`: the
/// conjunction is drawn where it lives, never split into separate claims.
enum ProofOutline {

    /// The proof as rows, one root (the target). `idPrefix` makes the ids
    /// unique among every proof in one result.
    static func rows(_ proof: Derivation.ProofTree, idPrefix: String,
                     writer: ExplorerWriter) -> [ExplorerRow] {
        let flat = proof.rows
        guard !flat.isEmpty else { return [] }

        // "Shown above" leads to the fact's first occurrence, the one with
        // its subtree. A weakened fact is a different fact from the full one,
        // and so is the fact a `metBy` producer concluded (R13), so the key
        // keeps them apart, as the engine's own does.
        var first: [String: String] = [:]
        for row in flat where !row.isReference && !row.isGiven {
            let key = occurrenceKey(row)
            if first[key] == nil { first[key] = rowID(idPrefix, row) }
        }

        var position = 0
        func node(parent: Derivation.Step?, index: Int) -> ExplorerRow {
            let row = flat[position]
            position += 1
            var children: [ExplorerRow] = []
            while position < flat.count, flat[position].level == row.level + 1 {
                children.append(node(parent: row.step, index: children.count))
            }
            let isConjunct = (parent?.hypotheses.count ?? 0) > 1 && index > 0
            var made = writer.proofRow(
                row, id: rowID(idPrefix, row), isRoot: row.level == 0, conjunct: isConjunct,
                firstOccurrence: first[occurrenceKey(row)])
            made.children = children
            return made
        }

        var roots: [ExplorerRow] = []
        while position < flat.count {
            roots.append(node(parent: nil, index: roots.count))
        }
        return roots
    }

    /// Copy Proof as Text's lines: the outline, two spaces per level.
    static func copyLines(_ proof: Derivation.ProofTree, writer: ExplorerWriter) -> [String] {
        proof.rows.map { writer.proofCopyLine($0) }
    }

    /// The outline with Copy Proof as Text on every row, so the context menu
    /// of any step offers it, not only the root's (relations-explorer.md
    /// §2.6).
    static func attaching(_ copy: ProofCopy, to rows: [ExplorerRow]) -> [ExplorerRow] {
        rows.map { (row) -> ExplorerRow in
            var row = row
            row.proof = copy
            row.children = attaching(copy, to: row.children)
            return row
        }
    }

    private static func rowID(_ prefix: String, _ row: Derivation.ProofTree.Row) -> String {
        "\(prefix)/\(row.id)"
    }

    private static func occurrenceKey(_ row: Derivation.ProofTree.Row) -> String {
        var key = row.objectID + (row.isWeakened ? "#weak" : "")
        if let producer = row.establishedBy {
            key += "#by:" + producer.relationID + (producer.isReverse ? "~reverse" : "")
        }
        return key
    }
}
