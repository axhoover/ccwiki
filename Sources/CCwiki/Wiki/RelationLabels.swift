import Foundation

/// Wiki source text, reduced to something the **chrome** can show.
///
/// Titles in the manifest are wiki source: they carry `$…$` math written with
/// the site's own KaTeX macros (`$\classNP \subseteq \classBPP$`). The reader
/// renders that properly inside the web view, which has KaTeX and the macro
/// table; a SwiftUI `Text` in a 280 pt inspector column has neither.
///
/// The vocabulary that actually appears is small and closed (twenty commands
/// across the 610 titles in the manifest, plus a few more in the 75 security
/// losses and the rationales), so the substitution below is exact rather
/// than a guess. Anything outside it loses its backslash and keeps its
/// letters, which degrades to a readable word rather than to `\classFOO`.
enum RelationText {

    /// Commands whose plain-text form is a real symbol. Longest key first at
    /// application time, so no key can shadow a longer one.
    private static let symbols: [String: String] = [
        #"\subseteq"#: "⊆", #"\subsetneq"#: "⊊", #"\subset"#: "⊂",
        #"\supseteq"#: "⊇", #"\supset"#: "⊃",
        #"\neq"#: "≠", #"\leq"#: "≤", #"\geq"#: "≥", #"\le"#: "≤", #"\ge"#: "≥",
        #"\cap"#: "∩", #"\cup"#: "∪", #"\in"#: "∈", #"\notin"#: "∉",
        #"\Rightarrow"#: "⇒", #"\rightarrow"#: "→", #"\to"#: "→", #"\mapsto"#: "↦",
        #"\Leftrightarrow"#: "⇔", #"\leftrightarrow"#: "↔",
        #"\forall"#: "∀", #"\exists"#: "∃",
        #"\times"#: "×", #"\cdot"#: "·", #"\pm"#: "±", #"\approx"#: "≈",
        #"\sqrt"#: "√", #"\infty"#: "∞",
        #"\Omega"#: "Ω", #"\Theta"#: "Θ", #"\Delta"#: "Δ", #"\Sigma"#: "Σ",
        #"\lambda"#: "λ", #"\epsilon"#: "ε", #"\varepsilon"#: "ε",
        #"\alpha"#: "α", #"\beta"#: "β", #"\delta"#: "δ", #"\sigma"#: "σ",
        #"\mu"#: "μ", #"\nu"#: "ν", #"\ell"#: "ℓ", #"\poly"#: "poly", #"\negl"#: "negl",
        #"\secpar"#: "λ", #"\bits"#: "{0,1}",
        // The site's integers, which the curation's quotes use ($\ZZ_p^*$)
        // and no manifest title does.
        #"\ZZ"#: "ℤ",
        // Operator names and the site's advantage macro: the security losses
        // use `\Adv`, `\log` and `\min`, and one rationale uses `\bmod` (and
        // `\mapsto`, above). Spelled out although the fallback would produce
        // the same words, so the table says what the manifest needs.
        #"\Adv"#: "Adv", #"\log"#: "log", #"\min"#: "min", #"\bmod"#: "mod",
    ]

    /// Stands in for a literal `$` while the math is reduced, so the pass that
    /// deletes math delimiters cannot reach it. A private-use code point, which
    /// no wiki title contains.
    private static let literalDollar = "\u{E000}"

    /// Commands that are pure typesetting: drop the command, keep the argument.
    private static let typesetting = [
        #"\mathrm"#, #"\mathbf"#, #"\mathcal"#, #"\mathsf"#, #"\mathbb"#,
        #"\mathit"#, #"\text"#, #"\textbf"#, #"\operatorname"#, #"\left"#, #"\right"#,
    ]

    /// Plain text for a title, a proposition, or any other wiki string that has
    /// to appear in the app's own UI.
    ///
    /// **A `$` is a math delimiter only when it pairs.** The wiki's contract
    /// says a literal `$` stands for itself (`IND$-CPA Security`), and the
    /// site reads it the way micromark does: a run of n dollars opens math
    /// only if a later run of exactly n closes it (`escapeOutsideMath` in
    /// `relationMeta.ts`). Deleting every `$` turned IND$-CPA into IND-CPA,
    /// a different notion, and made one barrier state a false separation. So
    /// an unpaired `$`, or an escaped `\$`, is set aside first and put back
    /// at the end.
    ///
    /// For any string without one, this handling changes nothing, which
    /// matters beyond relations: `ConceptRanker` names headings with this, and
    /// heading text reaches it with every `$` already removed, so math and
    /// prose cannot be told apart there. That is also why braces and commands
    /// are still reduced across the whole string rather than inside math spans
    /// only. (No heading in the corpus uses the commands the table gained for
    /// security losses, so search names are unchanged too.)
    static func plain(_ source: String) -> String {
        reduced(source, mathNeedsEvidence: false)
    }

    /// Plain text for a sentence of the wiki's prose, such as a `rationale`.
    ///
    /// A rationale is prose with the odd math token in it (`$r_i$`,
    /// `level-$(j-1)$`, `$\Gen$`), and the site never renders one, so there
    /// is no site rule for its dollars to follow. The pairing rule alone is
    /// not enough here: one rationale says a counterexample "refutes only the
    /// claim that every CPA-secure scheme is itself IND$-CPA-secure; building
    /// some other IND$-CPA-secure scheme …", and its two literal dollars pair,
    /// which would turn both mentions into IND-CPA. So in a sentence a paired
    /// span counts as math only when it looks like math: it uses a command,
    /// or it is one token with no space in it. Anything else is two literal
    /// dollars. Titles keep the site's rule, through `plain`.
    static func sentence(_ source: String) -> String {
        reduced(source, mathNeedsEvidence: true)
    }

    /// The reduction `plain` and `sentence` share. `mathNeedsEvidence` only
    /// decides which paired dollars delimit math; everything after that is
    /// the same for both.
    private static func reduced(_ source: String, mathNeedsEvidence: Bool) -> String {
        guard !source.isEmpty else { return "" }
        var text = protectingLiteralDollars(source, mathNeedsEvidence: mathNeedsEvidence)

        // `\classPpoly` is the one class macro whose name is not its rendering.
        text = text.replacingOccurrences(of: #"\classPpoly"#, with: "P/poly")
        // Every other `\classXYZ` renders as `XYZ`.
        text = text.replacingOccurrences(
            of: #"\\class([A-Za-z]+)"#, with: "$1", options: .regularExpression)
        // The site's calligraphic letters, `\calA` for 𝒜: the letter alone
        // reads better in UI type than a script glyph at caption size.
        text = text.replacingOccurrences(
            of: #"\\cal([A-Za-z])(?![A-Za-z])"#, with: "$1", options: .regularExpression)

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

        // Only paired delimiters are left by now.
        text = text.replacingOccurrences(of: "$", with: "")
        text = text.replacingOccurrences(of: "{", with: "")
        text = text.replacingOccurrences(of: "}", with: "")
        text = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: literalDollar, with: "$")
    }

    /// `source` with every `$` that does not delimit math replaced by
    /// `literalDollar`: an escaped `\$`, and any run of dollars that no later
    /// run of the same length closes. A port of the scan in the site's
    /// `escapeOutsideMath`, without its backtick case: titles have no code
    /// spans, and a `$` inside one would only stay a `$` here anyway if it
    /// were unpaired.
    ///
    /// With `mathNeedsEvidence`, a run that pairs is still literal unless the
    /// span it would open looks like math (see `sentence`), and the scan goes
    /// on from just after it, so its would-be partner can still pair later.
    private static func protectingLiteralDollars(
        _ source: String, mathNeedsEvidence: Bool
    ) -> String {
        guard source.contains("$") else { return source }
        let characters = Array(source)
        var output = ""
        var i = 0
        while i < characters.count {
            let character = characters[i]
            if character == "\\", i + 1 < characters.count, characters[i + 1] == "$" {
                output += literalDollar
                i += 2
            } else if character == "\\", i + 1 < characters.count,
                      characters[i + 1].isASCII, characters[i + 1].isPunctuation
                        || characters[i + 1].isSymbol {
                // Any other escape is copied whole, so the character after the
                // backslash is never read as the start of something.
                output.append(character)
                output.append(characters[i + 1])
                i += 2
            } else if character == "$" {
                var end = i
                while end < characters.count, characters[end] == "$" { end += 1 }
                let run = end - i
                // The first later run of exactly `run` dollars closes it.
                var close: Int?
                var j = end
                while j < characters.count, close == nil {
                    guard characters[j] == "$" else { j += 1; continue }
                    var k = j
                    while k < characters.count, characters[k] == "$" { k += 1 }
                    if k - j == run { close = j }
                    j = k
                }
                if let close,
                   !mathNeedsEvidence || looksLikeMath(characters[end..<close]) {
                    output += String(characters[i..<(close + run)])
                    i = close + run
                } else {
                    output += String(repeating: literalDollar, count: run)
                    i = end
                }
            } else {
                output.append(character)
                i += 1
            }
        }
        return output
    }

    /// Whether a paired span in prose is math: it uses a command, or it is a
    /// single token. `$r_i$` and `$\mathbf{z} \mapsto \mathbf{A}\mathbf{z}$`
    /// are; the words between the dollars of two IND$-CPA mentions are not.
    private static func looksLikeMath(_ span: ArraySlice<Character>) -> Bool {
        span.contains(where: { $0 == "\\" }) || !span.contains(where: \.isWhitespace)
    }

    /// The citation key a `source` entry is shown by, read the way the site's
    /// `renderSource` reads it: `[[KEY - Title|KEY]]` → `KEY`, and a link with
    /// no display text takes the key from the filename, `[[KEY - Title]]` →
    /// `KEY`. A bare token such as `folklore` is itself. `nil` for an empty
    /// entry.
    static func citationKey(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = WikilinkParser.links(in: trimmed).first else {
            return trimmed.isEmpty ? nil : trimmed
        }
        if let alias = link.alias, !alias.isEmpty { return alias }
        let base = link.target.split(separator: "/").last.map(String.init) ?? link.target
        let key = base.components(separatedBy: " - ").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !key.isEmpty { return key }
        return base.isEmpty ? nil : base
    }

    /// What a wikilink entry such as `via`'s `[[fiat-shamir-heuristic|Fiat–Shamir]]`
    /// reads as: its display text, else its target. Anything that is not a
    /// wikilink is plain text already. Either way the result has been through
    /// `plain`.
    static func linkText(_ entry: String) -> String {
        guard let link = WikilinkParser.links(in: entry).first else { return plain(entry) }
        if let alias = link.alias, !alias.isEmpty { return plain(alias) }
        return plain(link.target)
    }
}

// MARK: - Rationale, for the chrome
//
// A `rationale` is wiki prose, and five in the corpus carry TeX (`$\classBPP$`,
// `level-$j$`, `$\mathbf{z} \mapsto \mathbf{A}\mathbf{z} \bmod q$`), which a
// tooltip cannot render. Every place the inspector shows one asks for it here,
// so none can be shown raw.

extension Relation {
    /// The record's reason for `field` (`class`, `model`, `via`, …), as plain
    /// text for the chrome; `nil` when it gives none.
    func why(_ field: String) -> String? {
        guard let sentence = rationale[field].map(RelationText.sentence),
              !sentence.isEmpty
        else { return nil }
        return sentence
    }
}

extension Barrier {
    /// The record's reason for `field` (`class`, `strength`, `oracle`, …), as
    /// plain text for the chrome; `nil` when it gives none.
    func why(_ field: String) -> String? {
        guard let sentence = rationale[field].map(RelationText.sentence),
              !sentence.isEmpty
        else { return nil }
        return sentence
    }
}

/// How the site names the parts of a relation record, so the inspector uses
/// the words cryptology.city uses (`quartz/plugins/transformers/relationMeta.ts`).
enum RelationVocabulary {

    /// The glossary page with one section per reduction class. Each section's
    /// heading slugs to the class id, and `unstated` has a section too, so
    /// `[[reduction-classes#<class>]]` always lands on the explanation.
    static let classPage = "reduction-classes"

    /// The display name of a `model` value, as the site prints it. A value the
    /// site does not name reads as "<value> model", as there.
    static func modelName(_ model: String) -> String {
        switch model {
        case "standard": "standard model"
        case "rom": "random oracle model"
        case "crs": "CRS model"
        case "generic-group": "generic group model"
        case "algebraic-group": "algebraic group model"
        case "quantum": "quantum setting"
        case "other": "non-standard model"
        default: "\(model) model"
        }
    }

    /// The page explaining an idealised model, for the models that have one.
    static func modelPage(_ model: String) -> String? {
        switch model {
        case "rom": "random-oracle-model"
        case "generic-group": "generic-group-model"
        case "algebraic-group": "algebraic-group-model"
        default: nil
        }
    }
}

/// Display names for manifest nodes.
///
/// A variant is a *section* of a page, and the honest name for it is the host
/// page's title plus that section's heading: `Hash function § Collision
/// resistance`. **Always both halves.** The heading alone is not a name: two
/// pages each have a "CPA Security" section, others have "Types" or
/// "Binding", and `owf`, the commonest endpoint in the corpus, is the hash
/// function page's "Preimage resistance (one-wayness)". With the host, every
/// label in the corpus is unique, which `RelationsTests` checks.
///
/// The section text is the manifest's own `title`, which is the heading text
/// with any math kept as TeX. Clones from before the wiki's final-form
/// manifest have `title` equal to `id` for every variant
/// (`"abe-selective-security"`); for those the heading is read from the host
/// page instead, which is why this is built once per library load with the
/// parsed wiki to hand.
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

        // Heading text per hosting page, computed once and only for an older
        // clone whose variant titles are their ids. 52 pages host the 131
        // variants, so that is at most 52 parses rather than 131.
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

            var hostTitle: String?
            if let host = object.of.flatMap({ manifest.object($0) }) {
                let title = RelationText.plain(host.title)
                hostTitle = title.isEmpty ? nil : title
            }

            // The manifest's title is the heading, unless it only echoes the
            // id, as every variant's did before the final-form manifest. Then
            // the host page's heading is the name, or, with no clone loaded,
            // the anchor made readable.
            var section: String?
            if !object.title.isEmpty, object.title != object.id {
                section = RelationText.plain(object.title)
            } else if let anchor = object.anchor {
                section = headingText(onPage: object.path, id: anchor).map(RelationText.plain)
                    ?? Self.humanized(anchor)
            }

            labels[object.id] = switch (hostTitle, section) {
            case (let host?, let section?): "\(host) § \(section)"
            case (let host?, nil): host
            case (nil, let section?): section
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

    /// One entry of a barrier's `conditionalOn`: an object id, named like any
    /// other node, or free text when the wiki has no node for the assumption
    /// ("the language has a sub-exponentially hard subset-membership
    /// problem"), which is kept as written.
    func assumption(_ entry: String) -> String {
        labels[entry] ?? RelationText.plain(entry)
    }

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
    /// The title is free text; this is derived from the data. A heuristic
    /// edge reads `Multilinear maps ⇢ iO`, here as in its row, so neither its
    /// tooltip nor Copy Statement states it as a theorem.
    func statement(_ relation: Relation) -> String {
        let left = relation.hypotheses.map(label).joined(separator: " ∧ ")
        return "\(left) \(relation.arrow) \(label(relation.conclusion))"
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
            manifest.reduction(consequence.target)
                .map(statement) ?? Self.humanized(consequence.target)
        }
    }
}
