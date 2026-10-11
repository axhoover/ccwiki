import Foundation

/// What the Relations Explorer shows for one question: the pure step from
/// "query" to "what to lay out", so the view decides nothing.
///
/// Every sentence is written here (with `DerivationWording`), which is what
/// lets `ExplorerResultTests` hold the honesty contract of
/// relations-explorer.md §1 without a view: a chain of two or more steps
/// says "Derived by CCwiki from N recorded reductions" and draws `⇒*`; one
/// step says "Recorded in the wiki" and draws `⇒`; no derivation never
/// reads as a separation and always carries R10's fixed footer.
///
/// It is computed off the main actor, from `Sendable` inputs, by
/// `compute(_:derivation:labels:)`.
struct ExplorerResult: Sendable, Hashable {

    /// Which resting state or layout to show.
    enum State: Sendable, Hashable {
        /// Nothing asked.
        case empty
        /// A complexity class in the question (R2). Carries its label.
        case unsupported(String)
        /// Forward or backward with nothing found, or an object the wiki
        /// does not have: a designed empty state, not an answer.
        case nothing(title: String, description: String)
        /// A verdict, sections and a footer.
        case answer
    }

    /// As asked, stale objects included.
    var query: ExplorerQuery
    /// Objects the question names that the manifest no longer has. Left out
    /// of what was computed, and said so.
    var ignored: [String] = []
    var state: State
    var verdict: Verdict?
    var sections: [ExplorerSection] = []
    /// R6: a derivation in a stronger class than the shortest one.
    var stronger: Stronger?
    /// Fixed text under the answer. `nil` only for a premise given back.
    var footer: String?
    /// The footer's ⓘ, listing the rules of derivations.md §2.
    var explainsRules = false
    /// Posted to VoiceOver when the outcome changes.
    var announcement: String?
    /// An empty state offers Include Idealised Models.
    var offersIdealisedModels = false
    /// Rows whose disclosure starts closed. Everything else starts open, so
    /// the view keeps the set of collapsed rows.
    var initiallyCollapsed: Set<String> = []

    static let empty = ExplorerResult(query: ExplorerQuery(), state: .empty)

    // MARK: The verdict band

    struct Verdict: Sendable, Hashable {
        enum Tone: Sendable, Hashable {
            /// Derivable or recorded: the tint. Never green, never a
            /// checkmark: this says *chained*, not *true*.
            case derived
            /// A premise given back, or a list.
            case neutral
            /// No derivation: tertiary, the offline state's vocabulary. Not
            /// a fault, never red.
            case noDerivation
        }

        struct Line: Sendable, Hashable, Identifiable {
            enum Style: Sendable, Hashable {
                case secondary
                /// `unstated`, muted as it is everywhere.
                case muted
                /// A vacuous implication, an inconsistency in the record.
                case caution
            }

            let id: String
            let text: String
            var style: Style = .secondary
        }

        var symbol: String
        var tone: Tone
        var title: String
        /// The question restated: `⇒*` for a derivation, `⇒` for a recorded
        /// result.
        var statement: String?
        var lines: [Line] = []
        /// Non-standard models used, one tag each.
        var models: [String] = []
        var action: ExplorerRow.Action?
        var help: String?
    }

    /// R6: "A fully black-box derivation exists in 3 steps", with that
    /// proof, which Show It swaps in for the shortest.
    ///
    /// It carries its own verdict chrome, because the two proofs can differ
    /// in kind: beside a one-step recorded result, the stronger proof is
    /// usually a chain, which is CCwiki's composition and must read `⇒*`,
    /// "Derivable" and the derived footer, never as the wiki's own result.
    struct Stronger: Sendable, Hashable {
        let line: String
        /// Replaces the section with the same id.
        let proof: ExplorerSection
        /// Replace the verdict lines that describe the proof shown (see
        /// `proofLineIDs`), in their place at the head of the verdict.
        let lines: [Verdict.Line]
        let copy: ProofCopy
        let title: String
        /// The question restated with this proof's arrow.
        let statement: String
        /// The non-standard models this proof uses: a subset of the
        /// shortest's (R6 looks only among those).
        let models: [String]
        let footer: String
        let explainsRules: Bool
    }

    /// The verdict lines that say what the proof shown is: its model scope,
    /// where it came from and its chain class. Show It replaces them with
    /// the stronger proof's own.
    static let proofLineIDs: Set<String> = ["scope", "provenance", "class"]

    /// The sections, with the stronger proof swapped in when it is shown.
    func sections(showingStronger: Bool) -> [ExplorerSection] {
        guard showingStronger, let stronger else { return sections }
        return sections.map { $0.id == stronger.proof.id ? stronger.proof : $0 }
    }

    /// The verdict's lines, likewise. The shortest proof's own lines come
    /// first, so the stronger proof's take their place there, every one of
    /// them: a recorded result has no chain class line, and the chain shown
    /// in its place must still state its class.
    func verdictLines(showingStronger: Bool) -> [Verdict.Line] {
        let lines = verdict?.lines ?? []
        guard showingStronger, let stronger else { return lines }
        let kept = lines.filter { !Self.proofLineIDs.contains($0.id) }
        return stronger.lines + kept
    }

    /// The verdict's title, for whichever proof is shown.
    func verdictTitle(showingStronger: Bool) -> String? {
        guard showingStronger, let stronger else { return verdict?.title }
        return stronger.title
    }

    /// The question restated with the arrow of whichever proof is shown.
    func verdictStatement(showingStronger: Bool) -> String? {
        guard showingStronger, let stronger else { return verdict?.statement }
        return stronger.statement
    }

    /// The model tags of whichever proof is shown.
    func verdictModels(showingStronger: Bool) -> [String] {
        guard showingStronger, let stronger else { return verdict?.models ?? [] }
        return stronger.models
    }

    /// The footer under whichever proof is shown.
    func footer(showingStronger: Bool) -> String? {
        guard showingStronger, let stronger else { return footer }
        return stronger.footer
    }

    /// Whether the footer offers the rules, for whichever proof is shown.
    func explainsRules(showingStronger: Bool) -> Bool {
        guard showingStronger, let stronger else { return explainsRules }
        return stronger.explainsRules
    }

    // MARK: Finding rows

    /// The row with this id, wherever it is nested.
    func row(withID id: String, showingStronger: Bool = false) -> ExplorerRow? {
        for section in sections(showingStronger: showingStronger) {
            if let found = Self.find(id, in: section.rows) { return found }
        }
        return nil
    }

    /// The ids of the rows enclosing this one, outermost first: what must be
    /// expanded to show it.
    func ancestors(of id: String, showingStronger: Bool = false) -> [String] {
        for section in sections(showingStronger: showingStronger) {
            if let path = Self.path(to: id, in: section.rows) { return Array(path.dropLast()) }
        }
        return []
    }

    private static func find(_ id: String, in rows: [ExplorerRow]) -> ExplorerRow? {
        for row in rows {
            if row.id == id { return row }
            if let found = find(id, in: row.children) { return found }
        }
        return nil
    }

    private static func path(to id: String, in rows: [ExplorerRow]) -> [String]? {
        for row in rows {
            if row.id == id { return [id] }
            if let below = path(to: id, in: row.children) { return [row.id] + below }
        }
        return nil
    }

    /// Every row, depth first, in list order: for the copy of a selection.
    func rows(showingStronger: Bool) -> [ExplorerRow] {
        var rows: [ExplorerRow] = []
        func walk(_ list: [ExplorerRow]) {
            for row in list {
                rows.append(row)
                walk(row.children)
            }
        }
        for section in sections(showingStronger: showingStronger) { walk(section.rows) }
        return rows
    }

    /// Every row of the answer as first shown.
    var allRows: [ExplorerRow] { rows(showingStronger: false) }
}

/// A block of rows under one heading.
struct ExplorerSection: Identifiable, Sendable, Hashable {
    let id: String
    var title: String?
    var subtitle: String?
    var help: String?
    var rows: [ExplorerRow] = []
    /// After the rows, unselectable: "and 12 more".
    var note: String?
}

/// One row of the explorer's list, whatever it shows.
///
/// One model for every row, as `SWIFTUI-RULES.md` §4.4 asks of the view: a
/// proof step, a barrier, a refused step and a completion differ only in
/// which fields they fill, and the view lays out whatever is there.
struct ExplorerRow: Identifiable, Sendable, Hashable {

    enum Glyph: Sendable, Hashable {
        case none
        /// `nosign`: a barrier the wiki records.
        case barrier
        /// A barrier CCwiki derives (R12), labelled as derived.
        case derivedBarrier
    }

    enum Emphasis: Sendable, Hashable {
        case normal
        /// The proof's root: the answer's object.
        case strong
    }

    /// What a row leads to.
    enum Target: Sendable, Hashable {
        /// A reduction's or barrier's page, by content-relative path.
        case page(String)
        /// An object: its page, or its host's page at its section.
        case object(String)
        /// "Shown above": the first occurrence, by row id.
        case reveal(String)
        /// Another question.
        case ask(ExplorerQuery)
    }

    /// What a row's button does to the question.
    enum Command: Sendable, Hashable {
        case includeIdealisedModels
        /// A completion: append to From.
        case add(String)
        /// A hint on a start: Use Instead.
        case replaceStart(String, with: String)
        /// A hint on the target: Use Instead.
        case replaceTarget(with: String)
        case ask(ExplorerQuery)
    }

    struct Action: Sendable, Hashable {
        let title: String
        let command: Command
    }

    /// A link on a sentence: the barrier and each side reduction of a
    /// derived barrier, the step and barriers of a refusal.
    struct Link: Sendable, Hashable, Identifiable {
        let id: String
        let title: String
        let target: Target
    }

    /// A page the context menu can open, with how it names it: "Open
    /// Reduction “CS03: KEM + SKE ⇒ PKE”".
    struct PageLink: Sendable, Hashable {
        /// "Reduction", "Barrier".
        let kind: String
        let title: String
        let path: String
    }

    let id: String
    var glyph: Glyph = .none
    /// "∧" in the gutter: the second or a later premise of a conjunctive
    /// step. The conjunction is drawn where it lives.
    var conjunct = false
    var title: String
    var emphasis: Emphasis = .normal
    /// A sentence, shown in full rather than cut to two lines.
    var wraps = false
    /// R8: printed beside an unclassified, fixed-construction or stub
    /// barrier's title, every time it appears.
    var qualifier: String?
    /// The meta line.
    var detail: String?
    /// Further meta lines: assumptions, a weakened notion.
    var notes: [String] = []
    /// A capsule after the title: "given", "recorded", "3 steps".
    var badge: String?
    /// One `ModelTag` each.
    var models: [String] = []
    /// The compact stub badge, which names itself.
    var isStub = false
    var help: String?
    /// A sentence for VoiceOver, since the row is read as one element.
    var accessibilityLabel: String
    var action: Action?
    var links: [Link] = []
    var children: [ExplorerRow] = []
    var startsCollapsed = false
    /// Notes and captions are not things to act on.
    var isSelectable = true

    // What the row is about, for its primary action and context menu.

    /// Return and double-click.
    var primary: Target?
    var objectID: String?
    /// Explore From Here…: the objects the row names.
    var exploreFrom: [String]?
    var page: PageLink?
    /// Ask About This, or Show Proof.
    var ask: ExplorerQuery?
    var statement: String?
    var proof: ProofCopy?
}

/// Copy Proof as Text: the outline, two spaces per level, each step with
/// `[source; class; model]`, headed by the statement and where it came from.
struct ProofCopy: Sendable, Hashable {
    let statement: String
    let relationCount: Int
    let depth: Int
    let lines: [String]

    /// The commit makes a pasted proof reproducible. One step is the wiki's
    /// own result, and says so rather than "derived".
    func text(revision: String?) -> String {
        let source = revision.map { " (relations.json at \($0.prefix(12)))" } ?? ""
        let heading = depth <= 1
            ? DerivationWording.recordedTitle + source
            : DerivationWording.derivedBy(relationCount) + source
        return ([statement, heading] + lines).joined(separator: "\n")
    }
}
