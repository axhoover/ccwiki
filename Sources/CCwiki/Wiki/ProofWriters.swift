import Foundation

// Copy a proof: LaTeX for a paper, wiki Markdown for a page, and the BibTeX
// of the cited works that CryptoBib lacks (plans/relations-followups.md §3).
//
// The honesty contract of relations-explorer.md §1 travels with the copy.
// Every item is one recorded, cited step and is written `⇒`; `⇒*` and
// "derived by CCwiki from N recorded reductions" appear only in the header,
// which is a comment, because in a paper the composition becomes the
// author's claim. A vacuous implication is the exception: it is said in
// visible text, outside every comment, so a compiled paper says it too.

// MARK: - Names

/// What a copy calls an object (§3.3): the name a paper would use, as the
/// wiki's own reduction titles do ("OWF ⇒ PRG"), not the explorer's label,
/// which names a section by its host and heading.
enum ProofNames {

    /// 1. A page object: its first alias (DDH, cPIR, OT, KEM).
    /// 2. A variant whose id has no hyphen: the id in capitals (OWF, CRHF,
    ///    SSDDH), which is what the reduction titles call it.
    /// 3. Any other variant: its title when the title names its host
    ///    ("Low-noise LPN", "Invertible PRFs"), otherwise "<host name>
    ///    <title>" ("PKE CPA Security"): a heading such as "CPA Security" or
    ///    "Binding" cannot be read alone in a paper.
    /// 4. Anything else: the explorer's label.
    ///
    /// The title is wiki source and keeps its `$…$`: the writers escape it.
    static func name(_ objectID: String, manifest: RelationsManifest,
                     labels: RelationLabels) -> String {
        guard let object = manifest.object(objectID) else { return labels.label(objectID) }
        guard object.isVariant else { return firstAlias(object) ?? labels.label(objectID) }
        if !object.id.contains("-") { return object.id.uppercased() }
        // A clone from before the final-form manifest titles a variant by
        // its id, which is no name.
        guard !object.title.isEmpty, object.title != object.id,
              let hostID = object.of, let host = manifest.object(hostID)
        else { return labels.label(objectID) }

        let hostName = host.isVariant ? labels.label(hostID) : firstAlias(host) ?? labels.label(hostID)
        let hostTitle = RelationText.plain(host.title)
        var words = host.aliases.map(RelationText.plain) + [RelationText.plain(hostName), hostTitle]
        if let head = hostTitle.split(whereSeparator: { $0.isWhitespace }).last {
            words.append(String(head))
        }
        let title = RelationText.plain(object.title)
        if words.contains(where: { namesWholeWord($0, in: title) }) { return object.title }
        return hostName + " " + object.title
    }

    private static func firstAlias(_ object: RelationObject) -> String? {
        object.aliases.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether `text` contains `word` as a whole word, ignoring case and a
    /// trailing plural "s" on either: "Invertible PRFs" names PRF, "BLS
    /// signatures" names Digital signature's head noun, and "Distributed
    /// Point Functions" names the function in "Function secret sharing".
    /// SKE's alias "SE" is not a word of "CPA Security".
    static func namesWholeWord(_ word: String, in text: String) -> Bool {
        let haystack = Array(text.lowercased())
        let needle = Array(word.trimmingCharacters(in: .whitespaces).lowercased())
        var needles = [needle]
        if needle.count > 1, needle.last == "s" { needles.append(Array(needle.dropLast())) }
        for candidate in needles where !candidate.isEmpty && candidate.count <= haystack.count {
            for start in 0...(haystack.count - candidate.count) {
                let end = start + candidate.count
                guard haystack[start..<end].elementsEqual(candidate) else { continue }
                if start > 0, isWordCharacter(haystack[start - 1]) { continue }
                if end == haystack.count || !isWordCharacter(haystack[end]) { return true }
                if haystack[end] == "s", end + 1 == haystack.count || !isWordCharacter(haystack[end + 1]) {
                    return true
                }
            }
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

// MARK: - Context

/// What the writers read besides the proof: the manifest and labels for
/// names and pages, the reference pages for citation keys, the wiki's macros
/// for math, and the clone's commit for the provenance line.
struct ProofWriterContext: Sendable {
    let manifest: RelationsManifest
    let labels: RelationLabels
    let citations: ProofCitations
    let macros: MacroTable
    /// The clone's HEAD.
    let revision: String?

    /// Some cited work has an inline entry: Copy BibTeX of Cited Works is
    /// offered.
    func hasInlineEntries(_ proof: ProofExport) -> Bool {
        citedWorks(proof).contains { $0.inlineEntry != nil }
    }

    func name(_ objectID: String) -> String {
        ProofNames.name(objectID, manifest: manifest, labels: labels)
    }

    /// The question restated with this proof's arrow: `⇒*` for a chain, `⇒`
    /// for the wiki's own one-step result.
    func statement(_ proof: ProofExport) -> String {
        let arrow = proof.isRecordedResult ? DerivationWording.recordedArrow : DerivationWording.derivedArrow
        let start = DerivationWording.conjoined(proof.start.map { name($0) })
        return "\(start) \(arrow) \(name(proof.target))"
    }

    /// Where the copy came from, sentence by sentence: what it states and
    /// which relations.json it was read from; for a chain, also the derived
    /// footer and the chain class, with the models outside the standard one.
    func provenance(_ proof: ProofExport) -> [String] {
        let manifestName = "cryptology.city relations.json"
        let source = revision.map { "\(manifestName) at \($0.prefix(12))" } ?? manifestName
        if proof.isRecordedResult {
            return ["\(statement(proof)): recorded in the wiki (\(source))."]
        }
        let derived = DerivationWording.derivedBy(proof.relationCount).lowercasedFirst
        var chain = DerivationWording.chainClass(proof.chainClass, unstatedSteps: proof.unstatedSteps) + "."
        if let uses = Self.usesSentence(proof.models) { chain += " " + uses }
        return ["\(statement(proof)): \(derived) (\(source)).", DerivationWording.derivedFooter, chain]
    }

    /// "Uses the quantum setting." `nil` for a standard-model proof.
    private static func usesSentence(_ models: [String]) -> String? {
        var parts: [String] = []
        let named = models.filter { $0 != Derivation.unknownModel }.map(DerivationWording.modelName)
        if !named.isEmpty { parts.append("the " + DerivationWording.list(named)) }
        if models.contains(Derivation.unknownModel) { parts.append("a stub reduction") }
        return parts.isEmpty ? nil : "Uses " + DerivationWording.list(parts) + "."
    }

    /// A step's model as a qualifier, `nil` in the standard model. A stub's
    /// model is not evidence (R3), so it is named as a stub, never a model.
    static func modelQualifier(_ step: ProofExport.Step) -> String? {
        if step.isStub || step.model == Derivation.unknownModel { return "through a stub reduction" }
        switch step.model {
        case Derivation.standardModel: return nil
        case "other": return "in a non-standard model"
        default: return "in the " + DerivationWording.modelName(step.model)
        }
    }

    // MARK: Citations

    /// The works a step cites, as its relation records them.
    func works(of step: ProofExport.Step) -> [ProofCitations.Citation] {
        citations.citations(step.source, from: manifest.reduction(step.relationID)?.path ?? "")
    }

    /// The works the reduction that establishes a precondition cites.
    func works(ofProducer relationID: String) -> [ProofCitations.Citation] {
        guard let relation = manifest.reduction(relationID) else { return [] }
        return citations.citations(relation.source, from: relation.path)
    }

    /// Every work the copy cites, in order of first appearance, one per
    /// `\cite` key: the refutations' (the vacuity sentence comes before the
    /// list), then each step's own, then the producers its qualifiers name.
    /// Folklore has no key and is not a work.
    func citedWorks(_ proof: ProofExport) -> [ProofCitations.Citation] {
        var cited: [ProofCitations.Citation] = []
        var keys: Set<String> = []
        func add(_ found: [ProofCitations.Citation]) {
            for citation in found {
                guard let key = citation.texKey, keys.insert(key).inserted else { continue }
                cited.append(citation)
            }
        }
        for refutation in proof.refutations { add(citations.citations(of: refutation)) }
        for step in proof.steps {
            add(works(of: step))
            for established in step.established { add(works(ofProducer: established.producer)) }
        }
        return cited
    }

    // MARK: Reductions

    /// A reduction's own title as plain text, or its statement when the
    /// title is empty: `ExplorerWriter.reductionTitle`'s rule.
    func reductionTitle(_ relationID: String) -> String {
        guard let relation = manifest.reduction(relationID) else { return relationID }
        let title = RelationText.plain(relation.title)
        return title.isEmpty ? labels.statement(relation) : title
    }

    /// A class as the explorer's rows name it: `ExplorerWriter.className`'s
    /// rule, which needs a derivation the copy does not. `unstated`, a
    /// sentinel, or a class the manifest does not define is unstated.
    func className(_ name: String) -> String {
        if name.isEmpty || manifest.isSentinel(name) || manifest.classes[name] == nil {
            return Derivation.unstatedClass
        }
        return manifest.classTitle(name).lowercased()
    }
}

// MARK: - LaTeX

/// A comment header, a visible sentence for each refuted start, then an
/// `enumerate` with one `\item` per step (§3.4). "By" is the citation, which
/// a paper wants in the text; the reduction's id and title go in the item's
/// comment.
enum ProofLaTeX {

    /// The header's macro line when the macro table did not load, so the
    /// copy cannot claim its math is free of the wiki's macros.
    static let macrosUnavailable = "Math may use cryptology.city macros, which are not "
        + "written out: CCwiki could not read them from macros.ts."

    static func write(_ proof: ProofExport, context: ProofWriterContext) -> String {
        var lines = context.provenance(proof).map { comment($0) }
        // Proofs are pasted into papers without the wiki's preamble, as the
        // reader's "Copy Algorithm as LaTeX (No Macros)" is. That holds only
        // when the macros were read: every way macros.ts can fail to load
        // leaves the table empty, and the math is then copied as written.
        lines.append(comment(context.macros.isEmpty
            ? ProofLaTeX.macrosUnavailable
            : "Math uses no cryptology.city macros."))
        let works = context.citedWorks(proof)
        let inCryptoBib = works.filter { $0.cryptobibKey != nil }.compactMap(\.texKey)
        if !inCryptoBib.isEmpty {
            lines.append(comment("In CryptoBib (crypto.bib): " + inCryptoBib.joined(separator: ", ") + "."))
        }
        let inline = works.filter { $0.inlineEntry != nil }.compactMap(\.texKey)
        if !inline.isEmpty {
            lines.append(comment("Not in CryptoBib; Copy BibTeX of Cited Works gives their entries: "
                + inline.joined(separator: ", ") + "."))
        }
        for refutation in proof.refutations {
            let name = TeXText.escape(context.name(refutation.objectID), macros: context.macros)
            let cited = cite(context.citations.citations(of: refutation))
            lines.append("\(name) is known to be false\(cited), so this implication is vacuous.")
        }
        lines.append(#"\begin{enumerate}"#)
        for step in proof.steps { lines.append("  " + #"\item "# + item(step, context: context)) }
        lines.append(#"\end{enumerate}"#)
        return lines.joined(separator: "\n")
    }

    /// `A $\wedge$ B $\Rightarrow$ C by~\cite{…}`, then the qualifiers, each
    /// after a comma, then the comment.
    private static func item(_ step: ProofExport.Step, context: ProofWriterContext) -> String {
        func tex(_ text: String) -> String { TeXText.escape(text, macros: context.macros) }
        let left = step.hypotheses.map { tex(context.name($0)) }.joined(separator: #" $\wedge$ "#)
        var text = "\(left) " + #"$\Rightarrow$"# + " \(tex(context.name(step.conclusion)))"

        let own = context.works(of: step)
        var fallbacks = fallbackKeys(own)
        if !own.compactMap(\.texKey).isEmpty {
            text += " by" + cite(own)
        } else if own.contains(where: { $0.isFolklore }) {
            text += " (folklore)"
        }

        var qualifiers: [String] = []
        if let model = ProofWriterContext.modelQualifier(step) { qualifiers.append(model) }
        if step.isReverse { qualifiers.append("used right to left") }
        for requirement in step.assumed {
            qualifiers.append("assuming " + notion(requirement.notion, requirement.notionMarkdown, context))
        }
        for established in step.established {
            let requirement = established.requirement
            let producer = context.works(ofProducer: established.producer)
            for key in fallbackKeys(producer) where !fallbacks.contains(key) { fallbacks.append(key) }
            let who = producer.compactMap(\.texKey).isEmpty
                ? " " + producerStatement(established.producer, context: context) + " (folklore)"
                : cite(producer)
            qualifiers.append("for \(notion(requirement.notion, requirement.notionMarkdown, context)), "
                + "which\(who) establishes")
        }
        if let weakening = step.weakening {
            qualifiers.append("giving only " + notion(weakening.notion, weakening.notionMarkdown, context))
        }
        text += qualifiers.map { ", " + $0 }.joined() + "."

        var note = "\(step.relationID) (\(context.reductionTitle(step.relationID))): "
            + context.className(step.reductionClass)
        for key in fallbacks { note += "; \(key) has no BibTeX key on its reference page" }
        return text + " " + comment(note)
    }

    /// `~\cite{A,B}`, tied to the word before it, or nothing when no work
    /// has a key.
    private static func cite(_ works: [ProofCitations.Citation]) -> String {
        var keys: [String] = []
        for key in works.compactMap(\.texKey) where !keys.contains(key) { keys.append(key) }
        return keys.isEmpty ? "" : "~" + #"\cite{"# + keys.joined(separator: ",") + "}"
    }

    /// The keys that fell back to the wiki's own, which no bibliography has.
    private static func fallbackKeys(_ works: [ProofCitations.Citation]) -> [String] {
        var keys: [String] = []
        for work in works where work.usesWikiKey && !keys.contains(work.key) { keys.append(work.key) }
        return keys
    }

    /// A folklore producer has no key to cite, so it is named as its step.
    private static func producerStatement(_ relationID: String, context: ProofWriterContext) -> String {
        guard let relation = context.manifest.reduction(relationID) else {
            return TeXText.escape(relationID, macros: context.macros)
        }
        let left = relation.hypotheses
            .map { TeXText.escape(context.name($0), macros: context.macros) }
            .joined(separator: #" $\wedge$ "#)
        return "\(left) " + #"$\Rightarrow$"# + " "
            + TeXText.escape(context.name(relation.conclusion), macros: context.macros)
    }

    /// `notionMarkdown` when the curation has it, which is text and `$…$`
    /// math only; otherwise the plain notion, escaped.
    private static func notion(_ plain: String, _ markdown: String?,
                               _ context: ProofWriterContext) -> String {
        TeXText.escape(markdown ?? plain, macros: context.macros)
    }

    /// A comment line. Its text is not escaped, since TeX ignores the rest
    /// of the line, but a newline would end it.
    private static func comment(_ text: String) -> String {
        "% " + text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - Wiki Markdown

/// A numbered list in the same order, for pasting into a wiki page, a Notes
/// bullet or "# Other results" (§3.5). The provenance goes in an HTML
/// comment: invisible on the site, masked by the wiki's lint, and deletable
/// by whoever pastes.
enum ProofMarkdown {

    static func write(_ proof: ProofExport, context: ProofWriterContext) -> String {
        let header = context.provenance(proof).joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "-->", with: "-- >")
        var lines = ["<!-- \(header) -->"]
        for refutation in proof.refutations {
            let sources = context.citations.citations(of: refutation).map(\.entry)
            let cited = sources.isEmpty ? "" : " (" + sources.joined(separator: ", ") + ")"
            lines.append("\(objectLink(refutation.objectID, context: context)) is known to be "
                + "false\(cited), so this implication is vacuous.")
            lines.append("")
        }
        for (index, step) in proof.steps.enumerated() {
            lines.append("\(index + 1). " + item(step, context: context))
        }
        return lines.joined(separator: "\n")
    }

    /// `A ∧ B ⇒ C by [[slug|title]] — <source>`, then the qualifiers.
    private static func item(_ step: ProofExport.Step, context: ProofWriterContext) -> String {
        let left = step.hypotheses.map { objectLink($0, context: context) }
            .joined(separator: " \(DerivationWording.conjunction) ")
        var text = "\(left) \(DerivationWording.recordedArrow) "
            + "\(objectLink(step.conclusion, context: context)) by "
            + reductionLink(step.relationID, context: context)
        // The wiki's Statement convention: the citation after an em dash.
        let source = step.source.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !source.isEmpty { text += " — " + source.joined(separator: ", ") }

        var qualifiers: [String] = []
        if let model = ProofWriterContext.modelQualifier(step) { qualifiers.append(model) }
        if step.isReverse { qualifiers.append("used right to left") }
        for requirement in step.assumed {
            qualifiers.append("assuming " + notion(requirement.notion, requirement.notionMarkdown))
        }
        for established in step.established {
            let requirement = established.requirement
            qualifiers.append("for \(notion(requirement.notion, requirement.notionMarkdown)), which "
                + producer(established.producer, context: context) + " establishes")
        }
        if let weakening = step.weakening {
            qualifiers.append("giving only " + notion(weakening.notion, weakening.notionMarkdown))
        }
        return text + qualifiers.map { ", " + $0 }.joined() + "."
    }

    /// An object linked as the generated "Participates in" sections link
    /// it: its page, or its host's page at its section, showing its copy
    /// name. A name with `$` becomes a markdown link, which the wiki's
    /// `wikilink-math` lint requires.
    static func objectLink(_ objectID: String, context: ProofWriterContext) -> String {
        let name = context.name(objectID)
        guard let object = context.manifest.object(objectID) else { return MarkdownText.escape(name) }
        let target = object.slug + (object.anchor.map { "#" + $0 } ?? "")
        return RelationMeta.link(target, name)
    }

    /// The reduction's page, by its slug, with its own title: here the
    /// title says more than the step ("PRF ⇒ CPA-secure SKE").
    private static func reductionLink(_ relationID: String, context: ProofWriterContext) -> String {
        guard let relation = context.manifest.reduction(relationID) else {
            return MarkdownText.escape(relationID)
        }
        let title = relation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return RelationMeta.link(relation.slug, title.isEmpty ? context.labels.statement(relation) : title)
    }

    /// The step that establishes a precondition, by its citations, or by its
    /// page when it is folklore.
    private static func producer(_ relationID: String, context: ProofWriterContext) -> String {
        let cited = (context.manifest.reduction(relationID)?.source ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != ProofCitations.Citation.folklore }
        return cited.isEmpty ? reductionLink(relationID, context: context) : cited.joined(separator: ", ")
    }

    /// `notionMarkdown` verbatim; otherwise the plain notion, escaped so
    /// "Z_p^*" opens no emphasis.
    private static func notion(_ plain: String, _ markdown: String?) -> String {
        markdown ?? MarkdownText.escape(plain)
    }
}

// MARK: - BibTeX

/// The inline entries of the cited works CryptoBib lacks (§3.6). A work in
/// CryptoBib is listed by key in the LaTeX header instead: an entry made up
/// from its reference page would clash with the real one in a paper that
/// loads `crypto.bib`.
enum ProofBibTeX {

    /// `nil` when no cited work has an inline entry: then there is nothing
    /// to copy, and the command is hidden or disabled.
    static func write(_ proof: ProofExport, context: ProofWriterContext) -> String? {
        let works = context.citedWorks(proof)
        let entries = works.compactMap(\.inlineEntry)
        guard !entries.isEmpty else { return nil }
        var heading = "% Works cited by the proof of \(context.statement(proof)) that are not in "
            + "CryptoBib, from cryptology.city's reference pages."
        let others = works.filter { $0.cryptobibKey != nil }.compactMap(\.texKey)
        if !others.isEmpty { heading += " The others: " + others.joined(separator: ", ") + "." }
        return ([heading.replacingOccurrences(of: "\n", with: " ")] + entries).joined(separator: "\n\n")
    }
}

// MARK: - Escaping

/// Text split where the site would set math or code: a run of n dollars (or
/// backticks) opens a span only if a later run of exactly n closes it, as
/// micromark reads it and `RelationMeta.escapeOutsideMath` scans it. A run
/// nothing closes is literal, and a backslash before ASCII punctuation is an
/// escape that keeps the two together.
enum MathSpans {

    struct Span: Equatable, Sendable {
        let text: String
        /// Math or code, delimiters included.
        let isDelimited: Bool
    }

    static func split(_ text: String, delimiters: Set<Unicode.Scalar>) -> [Span] {
        let scalars = Array(text.unicodeScalars)
        var spans: [Span] = []
        var plain = String.UnicodeScalarView()
        func flush() {
            guard !plain.isEmpty else { return }
            spans.append(Span(text: String(plain), isDelimited: false))
            plain = String.UnicodeScalarView()
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count,
               MarkdownLinkParser.isASCIIPunctuation(scalars[i + 1].value) {
                plain.append(contentsOf: scalars[i...(i + 1)])
                i += 2
            } else if delimiters.contains(c) {
                var end = i
                while end < scalars.count, scalars[end] == c { end += 1 }
                let length = end - i
                var close: Int?
                var j = end
                while j < scalars.count, close == nil {
                    guard scalars[j] == c else { j += 1; continue }
                    var k = j
                    while k < scalars.count, scalars[k] == c { k += 1 }
                    if k - j == length { close = j }
                    j = k
                }
                if let close {
                    flush()
                    var span = String.UnicodeScalarView()
                    span.append(contentsOf: scalars[i..<(close + length)])
                    spans.append(Span(text: String(span), isDelimited: true))
                    i = close + length
                } else {
                    plain.append(contentsOf: scalars[i..<end])
                    i = end
                }
            } else {
                plain.append(c)
                i += 1
            }
        }
        flush()
        return spans
    }
}

/// Wiki text as LaTeX that pdfLaTeX compiles without the wiki's preamble
/// (§3.7). Math keeps its delimiters and has the wiki's macros written out;
/// outside math, TeX's specials are escaped, and the arrows, symbols and
/// Greek letters that `RelationText` produces go into math, since pdfLaTeX
/// stops on one in text ("Unicode character Φ not set up for use with
/// LaTeX"). Latin-1 letters and curly quotes stay: pdfLaTeX has read UTF-8
/// input by default since 2018.
enum TeXText {

    static func escape(_ text: String, macros: MacroTable) -> String {
        var out = ""
        for span in MathSpans.split(text, delimiters: ["$"]) {
            out += span.isDelimited ? macros.expanded(span.text) : escapeText(span.text)
        }
        return out
    }

    private static func escapeText(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = ""
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count,
               MarkdownLinkParser.isASCIIPunctuation(scalars[i + 1].value) {
                // A markdown escape stands for the character itself.
                out += form(scalars[i + 1])
                i += 2
            } else if c == "⇒", i + 1 < scalars.count, scalars[i + 1] == "*" {
                out += #"$\Rightarrow^*$"#
                i += 2
            } else {
                out += form(c)
                i += 1
            }
        }
        return out
    }

    private static func form(_ c: Unicode.Scalar) -> String {
        if let text = textForms[c] { return text }
        if let math = mathForms[c] { return "$" + math + "$" }
        var kept = ""
        kept.unicodeScalars.append(c)
        return kept
    }

    /// TeX's specials, and the punctuation it sets otherwise.
    private static let textForms: [Unicode.Scalar: String] = [
        "\\": #"\textbackslash{}"#, "{": #"\{"#, "}": #"\}"#, "&": #"\&"#, "%": #"\%"#,
        "#": "\\#", "_": #"\_"#, "^": #"\^{}"#, "~": #"\textasciitilde{}"#, "$": #"\$"#,
        "<": #"\textless{}"#, ">": #"\textgreater{}"#, "|": #"\textbar{}"#,
        "§": #"\S{}"#, "–": "--", "—": "---", "…": #"\ldots{}"#,
    ]

    /// In math: the inverse of `RelationText`'s symbols, the explorer's
    /// arrows, and the Greek alphabet's letters that have a command.
    private static let mathForms: [Unicode.Scalar: String] = [
        "⇒": #"\Rightarrow"#, "⇔": #"\Leftrightarrow"#, "∧": #"\wedge"#,
        "≤": #"\le"#, "≥": #"\ge"#, "≠": #"\neq"#,
        "⊆": #"\subseteq"#, "⊊": #"\subsetneq"#, "⊂": #"\subset"#,
        "⊇": #"\supseteq"#, "⊃": #"\supset"#,
        "∩": #"\cap"#, "∪": #"\cup"#, "∈": #"\in"#, "∉": #"\notin"#,
        "→": #"\to"#, "↦": #"\mapsto"#, "↔": #"\leftrightarrow"#, "←": #"\gets"#, "≡": #"\equiv"#,
        "∀": #"\forall"#, "∃": #"\exists"#,
        "×": #"\times"#, "·": #"\cdot"#, "±": #"\pm"#, "≈": #"\approx"#,
        "√": #"\surd"#, "∞": #"\infty"#, "ℓ": #"\ell"#, "ℤ": #"\mathbb{Z}"#,
        "α": #"\alpha"#, "β": #"\beta"#, "γ": #"\gamma"#, "δ": #"\delta"#,
        "ε": #"\epsilon"#, "ϵ": #"\epsilon"#, "ζ": #"\zeta"#, "η": #"\eta"#,
        "θ": #"\theta"#, "ϑ": #"\vartheta"#, "ι": #"\iota"#, "κ": #"\kappa"#,
        "λ": #"\lambda"#, "μ": #"\mu"#, "ν": #"\nu"#, "ξ": #"\xi"#,
        "π": #"\pi"#, "ϖ": #"\varpi"#, "ρ": #"\rho"#, "ϱ": #"\varrho"#,
        "σ": #"\sigma"#, "ς": #"\varsigma"#, "τ": #"\tau"#, "υ": #"\upsilon"#,
        "φ": #"\phi"#, "ϕ": #"\phi"#, "χ": #"\chi"#, "ψ": #"\psi"#, "ω": #"\omega"#,
        "Γ": #"\Gamma"#, "Δ": #"\Delta"#, "Θ": #"\Theta"#, "Λ": #"\Lambda"#,
        "Ξ": #"\Xi"#, "Π": #"\Pi"#, "Σ": #"\Sigma"#, "Υ": #"\Upsilon"#,
        "Φ": #"\Phi"#, "Ψ": #"\Psi"#, "Ω": #"\Omega"#,
    ]
}

/// Wiki text as Markdown that shows exactly that text:
/// `RelationMeta.escapeOutsideMath`, with `*` and `_` escaped outside math
/// too, so the plain notion "DLOG hard in Z_p^*" opens no emphasis
/// (`DLOG hard in Z\_p^\*`).
enum MarkdownText {

    static func escape(_ text: String) -> String {
        var out = ""
        for span in MathSpans.split(text, delimiters: ["$", "`"]) {
            if span.isDelimited {
                out += span.text
                continue
            }
            let scalars = Array(span.text.unicodeScalars)
            var escaped = String.UnicodeScalarView()
            var i = 0
            while i < scalars.count {
                let c = scalars[i]
                if c == "\\", i + 1 < scalars.count,
                   MarkdownLinkParser.isASCIIPunctuation(scalars[i + 1].value) {
                    escaped.append(contentsOf: scalars[i...(i + 1)])
                    i += 2
                    continue
                }
                if specials.contains(c) { escaped.append("\\") }
                escaped.append(c)
                i += 1
            }
            out += String(escaped)
        }
        return out
    }

    /// Outside math and code: an unpaired `$`, the brackets of a link, and
    /// emphasis.
    private static let specials: Set<Unicode.Scalar> = ["$", "[", "]", "*", "_"]
}

// MARK: - Macros

extension MacroTable {

    /// `tex` with the wiki's macros written out, for a document without the
    /// preamble: the Swift twin of `expandMacros` in `ccwiki.js`
    /// (render-pipeline.md §3). A name is replaced only as a whole control
    /// word, so `\st` leaves `\stA` alone, and the pass repeats until the
    /// text stops changing, at most 10 times, so the result does not depend
    /// on the table's order and a body that uses another macro comes out in
    /// full.
    func expanded(_ tex: String) -> String {
        guard !macros.isEmpty, tex.contains("\\") else { return tex }
        let names = macros.keys.sorted()
        var result = tex
        for _ in 0..<10 {
            let before = result
            for name in names where result.contains(name) {
                guard let body = macros[name] else { continue }
                result = Self.replacingControlWord(name, with: body, in: result)
            }
            if result == before { break }
        }
        return result
    }

    private static func replacingControlWord(_ name: String, with body: String,
                                             in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: name) {
            out.append(contentsOf: rest[..<range.lowerBound])
            if let next = rest[range.upperBound...].unicodeScalars.first, continuesControlWord(next) {
                out.append(contentsOf: rest[range])
            } else {
                out.append(contentsOf: body)
            }
            rest = rest[range.upperBound...]
        }
        out.append(contentsOf: rest)
        return out
    }

    /// `[a-zA-Z@*]`, the JS rule's lookahead.
    private static func continuesControlWord(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x41...0x5A, 0x61...0x7A, 0x40, 0x2A: true
        default: false
        }
    }
}
