import Foundation

/// Wiki source text, reduced to something the **chrome** can show.
///
/// Titles in the manifest are wiki source: they carry `$…$` math written with
/// the site's own KaTeX macros (`$\classNP \subseteq \classBPP$`). The reader
/// renders that properly inside the web view, which has KaTeX and the macro
/// table; a SwiftUI `Text` in a 280 pt inspector column has neither.
///
/// The vocabulary that actually appears is small and closed — twenty commands
/// across all 674 titles in the corpus — so the substitution below is exact
/// rather than a guess. Anything outside it loses its backslash and keeps its
/// letters, which degrades to a readable word rather than to `\classFOO`.
enum RelationText {

    /// Commands whose plain-text form is a real symbol. Longest key first at
    /// application time, so no key can shadow a longer one.
    private static let symbols: [String: String] = [
        #"\subseteq"#: "⊆", #"\subsetneq"#: "⊊", #"\subset"#: "⊂",
        #"\supseteq"#: "⊇", #"\supset"#: "⊃",
        #"\neq"#: "≠", #"\leq"#: "≤", #"\geq"#: "≥", #"\le"#: "≤", #"\ge"#: "≥",
        #"\cap"#: "∩", #"\cup"#: "∪", #"\in"#: "∈", #"\notin"#: "∉",
        #"\Rightarrow"#: "⇒", #"\rightarrow"#: "→", #"\to"#: "→",
        #"\Leftrightarrow"#: "⇔", #"\leftrightarrow"#: "↔",
        #"\forall"#: "∀", #"\exists"#: "∃",
        #"\times"#: "×", #"\cdot"#: "·", #"\pm"#: "±", #"\approx"#: "≈",
        #"\sqrt"#: "√", #"\infty"#: "∞",
        #"\Omega"#: "Ω", #"\Theta"#: "Θ", #"\Delta"#: "Δ", #"\Sigma"#: "Σ",
        #"\lambda"#: "λ", #"\epsilon"#: "ε", #"\varepsilon"#: "ε",
        #"\alpha"#: "α", #"\beta"#: "β", #"\delta"#: "δ", #"\sigma"#: "σ",
        #"\mu"#: "μ", #"\nu"#: "ν", #"\poly"#: "poly", #"\negl"#: "negl",
        #"\secpar"#: "λ", #"\bits"#: "{0,1}",
    ]

    /// Commands that are pure typesetting: drop the command, keep the argument.
    private static let typesetting = [
        #"\mathrm"#, #"\mathbf"#, #"\mathcal"#, #"\mathsf"#, #"\mathbb"#,
        #"\mathit"#, #"\text"#, #"\textbf"#, #"\operatorname"#, #"\left"#, #"\right"#,
    ]

    /// Plain text for a title, a proposition, or any other wiki string that has
    /// to appear in the app's own UI.
    static func plain(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        var text = source

        // `\classPpoly` is the one class macro whose name is not its rendering.
        text = text.replacingOccurrences(of: #"\classPpoly"#, with: "P/poly")
        // Every other `\classXYZ` renders as `XYZ`.
        text = text.replacingOccurrences(
            of: #"\\class([A-Za-z]+)"#, with: "$1", options: .regularExpression)

        for command in typesetting {
            text = text.replacingOccurrences(of: command, with: "")
        }
        for key in symbols.keys.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: key, with: symbols[key]!)
        }

        // Whatever is left is a command we have no rendering for. Keeping its
        // letters reads better than keeping its backslash.
        text = text.replacingOccurrences(
            of: #"\\([A-Za-z]+)"#, with: "$1", options: .regularExpression)

        text = text.replacingOccurrences(of: "$", with: "")
        text = text.replacingOccurrences(of: "{", with: "")
        text = text.replacingOccurrences(of: "}", with: "")
        text = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Display names for manifest nodes.
///
/// Built once per library load, because the interesting half needs the parsed
/// wiki: **all 131 variants in the corpus have `title` equal to their `id`**
/// (`"abe-selective-security"`), so the manifest cannot name them on its own. A
/// variant is a *section* of a page, and the honest name for it is the host
/// page's title plus that section's heading — which the app can produce,
/// because `WikiPage.headings()` already computes Quartz-identical heading ids.
struct RelationLabels: Sendable {

    private let labels: [String: String]
    /// Object id → where to navigate. Variants resolve to their host page plus
    /// an anchor, never to a page of their own.
    private let destinations: [String: Destination]

    struct Destination: Sendable, Hashable {
        let path: String
        let anchor: String?
    }

    static let empty = RelationLabels(labels: [:], destinations: [:])

    private init(labels: [String: String], destinations: [String: Destination]) {
        self.labels = labels
        self.destinations = destinations
    }

    init(manifest: RelationsManifest, index: WikiIndex?) {
        var labels: [String: String] = [:]
        var destinations: [String: Destination] = [:]

        // Heading text per hosting page, computed once. 48 pages host the 131
        // variants, so this is 48 parses rather than 131.
        var headingsByPath: [String: [String: String]] = [:]
        func headingText(onPage path: String, id anchor: String) -> String? {
            if headingsByPath[path] == nil {
                let page = index?.pages[path]
                headingsByPath[path] = Dictionary(
                    (page?.headings() ?? []).map { ($0.id, $0.text) },
                    uniquingKeysWith: { first, _ in first })
            }
            return headingsByPath[path]?[anchor]
        }

        for object in manifest.objectsByID.values {
            destinations[object.id] = Destination(path: object.path, anchor: object.anchor)

            guard object.isVariant else {
                labels[object.id] = RelationText.plain(object.title)
                continue
            }

            // A variant's own title is worth using only when it is a real
            // title rather than an echo of the id — which, today, it never is.
            let ownTitle = object.title == object.id
                ? nil : RelationText.plain(object.title)
            let host = object.of.flatMap { manifest.object($0) }
            let hostTitle = host.map { RelationText.plain($0.title) }
            let section = object.anchor.flatMap { headingText(onPage: object.path, id: $0) }
                ?? object.anchor.map(Self.humanized)

            labels[object.id] = switch (ownTitle, hostTitle, section) {
            case (let own?, _, _): own
            case (nil, let host?, let section?): "\(host) § \(section)"
            case (nil, let host?, nil): host
            case (nil, nil, let section?): section
            default: Self.humanized(object.id)
            }
        }

        self.labels = labels
        self.destinations = destinations
    }

    /// The display name for an object id. Falls back to the id itself, which is
    /// at least a real handle you can search for, rather than to an empty row.
    func label(_ objectID: String) -> String {
        labels[objectID] ?? Self.humanized(objectID)
    }

    func destination(_ objectID: String) -> Destination? { destinations[objectID] }

    /// `abe-selective-security` → `Abe selective security`. Only reached when
    /// the manifest and the clone disagree about what exists.
    static func humanized(_ id: String) -> String {
        let spaced = id.replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    // MARK: Statements

    /// The full hyperedge, as one line: `Sparse LPN ∧ DDH ⇒ SHE`.
    ///
    /// Built from the endpoint ids rather than from the relation's own `title`,
    /// so a multi-hypothesis edge is guaranteed to show **every** hypothesis.
    /// The title is free text; this is derived from the data.
    func statement(_ relation: Relation) -> String {
        let left = relation.hypotheses.map(label).joined(separator: " ∧ ")
        return "\(left) \(relation.kind.arrow) \(label(relation.conclusion))"
    }

    /// A barrier names the hyperedge it rules out, so it reads the same way.
    func statement(_ barrier: Barrier) -> String {
        let left = barrier.hypotheses.map(label).joined(separator: " ∧ ")
        return "\(left) ⇒ \(label(barrier.conclusion))"
    }

    /// What the existence of the ruled-out reduction would imply.
    func consequence(
        _ consequence: Barrier.Consequence, manifest: RelationsManifest
    ) -> String {
        switch consequence.kind {
        case .contradiction:
            "a contradiction"
        case .object:
            label(consequence.target)
        case .complexity:
            manifest.propositions[consequence.target].map {
                let title = RelationText.plain($0.title)
                return title.isEmpty ? Self.humanized(consequence.target) : title
            } ?? Self.humanized(consequence.target)
        case .reduction:
            manifest.reductions.first { $0.id == consequence.target }
                .map(statement) ?? Self.humanized(consequence.target)
        }
    }
}
