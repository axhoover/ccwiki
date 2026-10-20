import Foundation

/// The Relations inspector's derived sections for one page: what each of the
/// page's objects implies, and what implies it, through two or more recorded
/// reductions chained together (relations-explorer.md §3).
///
/// Pure and testable, like `PageRelations`, and computed per read for the
/// same reason (`ReaderSession.currentRelations`): every lookup is into the
/// single-object closures `Derivation` precomputed at load, so this only
/// sorts and words at most a few dozen rows.
///
/// **Always the default models.** The inspector is the most-viewed surface,
/// so it is the last place for a chain that holds only in an idealised model;
/// the Relations Explorer can include them.
///
/// **Derived means depth ≥ 2.** A depth-1 fact is a recorded step, which the
/// recorded groups above already show; repeating it here would call the
/// wiki's own claim CCwiki's.
struct PageDerivations: Sendable {

    enum Role: String, Sendable, CaseIterable {
        case implies, impliedBy

        var title: String {
            switch self {
            case .implies: DerivationWording.impliesTitle
            case .impliedBy: DerivationWording.impliedByTitle
            }
        }

        var help: String {
            switch self {
            case .implies: DerivationWording.impliesHelp
            case .impliedBy: DerivationWording.impliedByHelp
            }
        }

        /// `⇒*` before what this implies, `⇐*` before what implies it.
        var arrow: String {
            switch self {
            case .implies: DerivationWording.derivedArrow
            case .impliedBy: DerivationWording.derivedBackArrow
            }
        }
    }

    /// One derived row, with its words.
    struct Row: Sendable, Identifiable, Hashable {
        /// The far end, and the derived end's fact.
        let link: Derivation.Link
        let label: String
        /// The question that shows its proof: from the source, to the
        /// derived end.
        let query: ExplorerQuery
        /// "quantum setting · CRS model": only for models other than
        /// standard, which on the inspector's default models are those two.
        let modelsLine: String?
        /// "only selectively secure key-policy ABE": a weakened fact (R13)
        /// never passes for the full node.
        let weakening: String?
        /// Copy Statement: "DDH ⇒* Oblivious transfer (derived by CCwiki
        /// from 3 recorded reductions)". An assumed precondition and a
        /// weakened conclusion are part of the claim (derivations.md §7), so
        /// they follow in the parentheses: "…, assuming …", "…, only …".
        let statement: String
        let help: String
        let accessibilityLabel: String

        var id: String { link.id }
        var depth: Int { link.fact.depth }
    }

    /// Rows that share their assumptions. A derivation that assumes a
    /// precondition says so, and in a list the rows are grouped under an
    /// "Assuming …" sub-header rather than tagged one by one (§7).
    struct Group: Sendable, Identifiable, Hashable {
        /// The assumed notions, sorted; empty for rows that assume nothing.
        let assumptions: [String]
        let rows: [Row]

        var id: String { assumptions.joined(separator: "|") }
        var heading: String? {
            assumptions.isEmpty ? nil : "Assuming " + assumptions.joined(separator: "; ")
        }
    }

    struct Block: Sendable, Identifiable {
        /// The page's object this block is about.
        let objectID: String
        let role: Role
        /// Depth ≥ 2, by depth then label.
        let rows: [Row]
        /// The same rows: those that assume nothing first, then one group per
        /// set of assumptions.
        let groups: [Group]

        var id: String { "\(objectID)/\(role.rawValue)" }
    }

    /// Object order as `PageRelations`: the host, then its sections. Empty
    /// blocks are left out.
    let blocks: [Block]
    /// Refuted objects on the page (R14), with the wiki's sentence: their
    /// implications are vacuous, and the inspector says so over its groups.
    let refutations: [String: String]
    /// The objects the page hosts, whether or not they derive anything.
    let objectCount: Int

    static let empty = PageDerivations(blocks: [], refutations: [:], objectCount: 0)

    private init(blocks: [Block], refutations: [String: String], objectCount: Int) {
        self.blocks = blocks
        self.refutations = refutations
        self.objectCount = objectCount
    }

    var isEmpty: Bool { blocks.isEmpty }

    func blocks(_ role: Role) -> [Block] {
        blocks.filter { $0.role == role }
    }

    func count(_ role: Role) -> Int {
        blocks(role).reduce(0) { $0 + $1.rows.count }
    }

    /// A page hosting several objects names the object over each block, in
    /// the inspector's secondary name style; a page with one does not need
    /// to, since the title bar already says which object you are reading.
    ///
    /// Counted over the page, not over the blocks of a role: when only one
    /// of the hash function page's objects derives anything, its rows are
    /// still OWF's, and unnamed they would read as the host's.
    var needsObjectNames: Bool { objectCount > 1 }

    // MARK: Building

    /// Object pages only: a reduction or barrier page is one edge, and what
    /// its endpoints derive is on their own pages.
    init(path: String, manifest: RelationsManifest, derivation: Derivation, labels: RelationLabels) {
        guard manifest.relation(onPage: path) == nil, manifest.barrier(onPage: path) == nil else {
            self.init(blocks: [], refutations: [:], objectCount: 0)
            return
        }
        let ids = manifest.objectIDs(onPage: path)
        let ordered = ids.sorted { left, right in
            let leftVariant = manifest.object(left)?.isVariant ?? false
            let rightVariant = manifest.object(right)?.isVariant ?? false
            if leftVariant != rightVariant { return !leftVariant }
            return left < right
        }
        let writer = ExplorerWriter(derivation: derivation, labels: labels)

        var blocks: [Block] = []
        var refutations: [String: String] = [:]
        for id in ordered {
            if let refutation = derivation.curation.refuted[id] {
                refutations[id] = "The hypothesis is known to be false (\(refutation.source)), so "
                    + "what follows from \(labels.label(id)) is vacuous. \(refutation.text)"
            }
            for role in Role.allCases {
                let links = role == .implies
                    ? derivation.derivedImplications(of: id)
                    : derivation.derivedSources(of: id)
                let rows = links
                    .filter { $0.fact.depth >= 2 }
                    .map { Self.row($0, of: id, role: role, writer: writer) }
                    .sorted(by: Self.rowPrecedes)
                guard !rows.isEmpty else { continue }
                blocks.append(Block(objectID: id, role: role, rows: rows,
                                    groups: Self.grouped(rows)))
            }
        }
        self.init(blocks: blocks, refutations: refutations, objectCount: ordered.count)
    }

    /// By depth, then by label as a reader sorts names, then by id.
    private static func rowPrecedes(_ left: Row, _ right: Row) -> Bool {
        if left.depth != right.depth { return left.depth < right.depth }
        let order = left.label.localizedStandardCompare(right.label)
        if order != .orderedSame { return order == .orderedAscending }
        return Derivation.precedes(left.link.objectID, right.link.objectID)
    }

    /// Rows that assume nothing first, then each set of assumptions in turn,
    /// each keeping the rows' order.
    private static func grouped(_ rows: [Row]) -> [Group] {
        var order: [[String]] = []
        var byAssumptions: [[String]: [Row]] = [:]
        for row in rows {
            let assumptions = row.link.fact.assumes.map { $0.notion }.sorted(by: Derivation.precedes)
            if byAssumptions[assumptions] == nil { order.append(assumptions) }
            byAssumptions[assumptions, default: []].append(row)
        }
        order.sort { left, right in
            if left.isEmpty != right.isEmpty { return left.isEmpty }
            return left.joined(separator: "|").localizedStandardCompare(right.joined(separator: "|"))
                == .orderedAscending
        }
        return order.map { Group(assumptions: $0, rows: byAssumptions[$0] ?? []) }
    }

    private static func row(_ link: Derivation.Link, of id: String, role: Role,
                            writer: ExplorerWriter) -> Row {
        let source = role == .implies ? id : link.objectID
        let target = role == .implies ? link.objectID : id
        let label = writer.label(link.objectID)
        let fact = link.fact
        let models = fact.models.sorted(by: Derivation.precedes).map(DerivationWording.modelName)
        let modelsLine = models.isEmpty ? nil : models.joined(separator: " · ")
        let weakening = fact.weakening.map { "only " + $0.notion }
        // The group heading says "Assuming …" on screen; a copied line and a
        // tooltip leave that context, so each carries the condition itself.
        let assumed = writer.assuming(fact.assumes.map { $0.notion })
        let qualifiers = [assumed, weakening].compactMap { $0 }

        let claim = "\(writer.label(source)) \(DerivationWording.derivedArrow) "
            + writer.label(target)
        let provenance = DerivationWording.derivedBy(link.relationCount) + "; "
            + DerivationWording.steps(fact.depth) + "."
        var helpLines = [claim, provenance]
        if !qualifiers.isEmpty {
            let qualified = qualifiers.joined(separator: "; ")
            helpLines.append(qualified.prefix(1).uppercased() + qualified.dropFirst())
        }
        // Counted from the proof the link table built at load: a row builds
        // no proof tree, on the main actor or anywhere.
        helpLines.append(DerivationWording.chainClass(fact.chainClass, unstatedSteps: link.unstatedSteps))
        helpLines.append("Click to see the proof.")
        let help = helpLines.joined(separator: "\n")

        var spoken = "\(label), derived in \(DerivationWording.steps(fact.depth))"
        if !models.isEmpty { spoken += ", " + models.joined(separator: ", ") }
        if let assumed { spoken += ", " + assumed }
        if let weakening { spoken += ", " + weakening }

        let statement = claim + " ("
            + DerivationWording.derivedBy(link.relationCount).lowercasedFirst
            + qualifiers.map { ", " + $0 }.joined() + ")"

        return Row(
            link: link, label: label,
            query: ExplorerQuery(from: [source], to: target),
            modelsLine: modelsLine, weakening: weakening,
            statement: statement, help: help, accessibilityLabel: spoken)
    }
}
