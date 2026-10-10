import Foundation

/// The metadata line under the H1 of every reduction and barrier page, as the
/// site renders it:
///
/// ```
/// # RSA ⇔ FAC
/// Equivalence · free reduction · non-standard model · DLO24
/// ```
///
/// A port of the wiki's `quartz/plugins/transformers/relationMeta.ts`. The
/// wiki's body contract leaves kind, class, model, sources and security loss
/// out of the page text because this line states them, so without it a
/// reduction page in the reader would say none of those things.
///
/// Like the site, the line is built from the page's frontmatter as markdown
/// and spliced into the body under the H1 before anything else reads it. Its
/// wikilinks and markdown links then resolve through the same link map as the
/// body's, and its `$…$` reaches KaTeX like any other math, so there is no
/// second renderer to drift from the first. The manifest supplies what the
/// frontmatter cannot: the type of the conclusion, and the title and address
/// behind a `conditional-on` id.
///
/// The parts, their order, wording, links and separator are the site's; where
/// the two disagree, the site is right. `RelationMetaTests` ports the cases of
/// `relationMeta.test.ts`.
enum RelationMeta {

    /// The glossary page with one section per reduction class, each heading
    /// slugging to the class id.
    static let classPage = "reduction-classes"

    /// The idealised models with a page of their own. Others are plain text.
    static let modelPages: [String: String] = [
        "rom": "random-oracle-model",
        "generic-group": "generic-group-model",
        "algebraic-group": "algebraic-group-model",
    ]

    /// Display text per `model` value. One that is missing reads as
    /// "<value> model".
    static let modelNames: [String: String] = [
        "standard": "standard model",
        "rom": "random oracle model",
        "crs": "CRS model",
        "generic-group": "generic group model",
        "algebraic-group": "algebraic group model",
        "quantum": "quantum setting",
        "other": "non-standard model",
    ]

    /// A no-break space before the dot keeps it on the line of the item it
    /// follows, so a wrapped line never starts with a separator.
    static let separator = "\u{00A0}· "

    /// Ends the spliced line, so `ccwiki.js` can find the paragraph and give it
    /// the `relation-meta` class, as the site's markdown stage does.
    static let marker = "<!-- relation-meta -->"

    // MARK: The line

    /// The line for a page, marker included, or nil when the page is neither a
    /// reduction nor a barrier, or its fields leave nothing to say.
    static func line(
        for frontmatter: Frontmatter, manifest: RelationsManifest, labels: RelationLabels
    ) -> String? {
        let parts = Self.parts(for: frontmatter, manifest: manifest, labels: labels)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: separator) + " " + marker
    }

    /// The parts of the line, as markdown, in display order. Empty parts are
    /// left out, so the result may be empty.
    static func parts(
        for frontmatter: Frontmatter, manifest: RelationsManifest, labels: RelationLabels
    ) -> [String] {
        let fields = frontmatter.fields
        let reductionClass = scalar(fields["class"])
        func classLink(_ noun: String) -> String {
            link("\(classPage)#\(reductionClass)", "\(classPhrase(reductionClass)) \(noun)")
        }
        let sources = list(fields["source"]).map { Self.renderSource($0) }
        var parts: [String] = []

        switch scalar(fields["type"]) {
        case "reduction":
            let containment = isComplexityContainment(fields, manifest: manifest)
            let kind = scalar(fields["kind"])
            if !kind.isEmpty, kind != "implication" { parts.append(kind) }
            if !reductionClass.isEmpty, reductionClass != "unstated", !containment {
                parts.append(classLink("reduction"))
            }
            let model = scalar(fields["model"])
            if !model.isEmpty, !(containment && model == "standard") {
                let name = modelNames[model] ?? "\(model) model"
                if let page = modelPages[model] {
                    parts.append(link(page, name))
                } else {
                    parts.append(name)
                }
            }
            if isTrue(fields["heuristic"]) { parts.append("heuristic candidate") }
            let via = list(fields["via"])
            if !via.isEmpty { parts.append("via " + via.joined(separator: ", ")) }
            if !sources.isEmpty { parts.append(sources.joined(separator: ", ")) }
            let loss = scalar(fields["security-loss"])
            if !loss.isEmpty { parts.append("security loss: " + loss) }

        case "barrier":
            let strength = scalar(fields["strength"])
            if !strength.isEmpty { parts.append(strength) }
            if !reductionClass.isEmpty, reductionClass != "unstated" {
                parts.append("against " + classLink("reductions"))
            }
            let assumed = list(fields["conditional-on"]).map {
                Self.renderObject($0, manifest: manifest, labels: labels)
            }
            if !assumed.isEmpty { parts.append("assuming " + assumed.joined(separator: ", ")) }
            if !sources.isEmpty { parts.append(sources.joined(separator: ", ")) }

        default:
            break
        }

        if let first = parts.first { parts[0] = capitalizeFirst(first) }
        return parts
    }

    /// A containment or equality between complexity classes (or of a problem
    /// in a class) is recorded `class: free`, and the schema's stock note says
    /// the reduction-class axis does not apply to it; nor does the
    /// standard/idealised model axis. The line leaves both out rather than
    /// print "free reduction · standard model" under "IP ⊆ PSPACE". A
    /// `quantum` model is still shown.
    private static func isComplexityContainment(
        _ fields: [String: Frontmatter.Value], manifest: RelationsManifest
    ) -> Bool {
        let kind = scalar(fields["kind"])
        guard !kind.isEmpty, kind != "implication", scalar(fields["class"]) == "free"
        else { return false }
        if let type = manifest.object(scalar(fields["conclusion"]))?.type, !type.isEmpty {
            return type == "complexity-class"
        }
        return kind == "inclusion"
    }

    // MARK: Parts

    /// One `source` entry: a wikilink to a reference page, shown by its
    /// citation key, or the bare token `folklore`. A wikilink without display
    /// text gets the key from the filename (`KEY - Title`).
    static func renderSource(_ entry: String) -> String {
        let source = oneLine(entry)
        let ns = source as NSString
        guard let match = sourceWikilink.firstMatch(
            in: source, range: NSRange(location: 0, length: ns.length))
        else { return source }
        // Display text of its own (`|DLO24`) wins; a bare `|` is no text.
        let alias = match.range(at: 2)
        if alias.location != NSNotFound, alias.length > 1 { return source }

        let target = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let file = target.components(separatedBy: "/").last ?? target
        let base = file.components(separatedBy: "#")[0]
        let key = base.components(separatedBy: " - ")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return link(target, key.isEmpty ? base : key)
    }

    private static let sourceWikilink = try! NSRegularExpression(
        pattern: #"^\[\[([^\]|]+?)(\|[^\]]*)?\]\]$"#)

    /// An object or variant id, linked the way the generated sections link it:
    /// by title, from the manifest. An id the manifest does not know (an old
    /// clone, or free text such as "a sub-exponentially hard subset-membership
    /// problem") stays as written.
    private static func renderObject(
        _ id: String, manifest: RelationsManifest, labels: RelationLabels
    ) -> String {
        guard let object = manifest.object(id) else { return id }
        let title = object.title.isEmpty ? id : object.title
        guard object.isVariant else { return link(object.slug, title) }

        let target = object.slug + (object.anchor.map { "#" + $0 } ?? "")
        // A clone from before the wiki titled variants by their headings has
        // `title == id`; the app's own label, host and section, says more.
        return link(target, title == id ? labels.label(id) : variantDisplay(title))
    }

    /// Class id as written attributively in page titles ("fully-black-box").
    static func classPhrase(_ reductionClass: String) -> String {
        let prefix = "forall-exists-"
        guard reductionClass.hasPrefix(prefix) else { return reductionClass }
        return "∀∃-" + String(reductionClass.dropFirst(prefix.count))
    }

    /// Display text for a variant: its manifest title (the heading its anchor
    /// points at), lower-cased when it starts with an ordinary capitalised word
    /// ("Collision resistance" → "collision resistance", "CCA1 Security"
    /// kept), since it reads mid-sentence ("assuming …").
    static func variantDisplay(_ heading: String) -> String {
        let scalars = Array(heading.unicodeScalars.prefix(2))
        guard scalars.count == 2,
              scalars[0].properties.generalCategory == .uppercaseLetter,
              scalars[1].properties.generalCategory == .lowercaseLetter
        else { return heading }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: heading.unicodeScalars.dropFirst())
        return String(Character(scalars[0])).lowercased() + String(rest)
    }

    /// The part that leads the line starts with a capital. In `[[target|text]]`
    /// the text is what shows, so the text is what gets it.
    private static func capitalizeFirst(_ markdown: String) -> String {
        var start = markdown.startIndex
        if markdown.hasPrefix("[["), let bar = markdown.firstIndex(of: "|"),
           !markdown[markdown.index(markdown.startIndex, offsetBy: 2)..<bar].contains("]") {
            start = markdown.index(after: bar)
        }
        guard start < markdown.endIndex,
              markdown[start].unicodeScalars.first?.properties.generalCategory == .lowercaseLetter
        else { return markdown }
        return String(markdown[..<start]) + markdown[start].uppercased()
            + String(markdown[markdown.index(after: start)...])
    }

    // MARK: Markdown

    /// A link to `target` showing `text`. Text with a `$` becomes a markdown
    /// link: remark-math splits a wikilink whose alias holds math before the
    /// wikilink pass sees it, while a markdown link's text is inline content,
    /// so the math renders. `MarkdownLinkParser` resolves that form.
    private static func link(_ target: String, _ text: String) -> String {
        guard text.contains("$") else { return "[[\(target)|\(linkText(text))]]" }
        let shown = escapeOutsideMath(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return "[\(shown)](<\(target)>)"
    }

    /// Wikilink display text cannot contain `|`, `[` or `]`.
    private static func linkText(_ text: String) -> String {
        String(text.map { "|[]".contains($0) ? " " : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` as markdown showing exactly `text`: `$…$` and backtick spans
    /// kept, and outside them every `$`, `[` and `]` escaped, so a lone dollar
    /// (IND$-CPA) cannot pair with a dollar elsewhere in the line. A run of n
    /// dollars or backticks closes at the next run of exactly n, as micromark
    /// reads it.
    static func escapeOutsideMath(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\", i + 1 < scalars.count,
               MarkdownLinkParser.isASCIIPunctuation(scalars[i + 1].value) {
                out.append(contentsOf: scalars[i...(i + 1)])
                i += 2
            } else if c == "$" || c == "`" {
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
                    out.append(contentsOf: scalars[i..<(close + length)])
                    i = close + length
                } else {
                    if c == "$" {
                        for _ in 0..<length { out.append(contentsOf: "\\$".unicodeScalars) }
                    } else {
                        out.append(contentsOf: scalars[i..<end])
                    }
                    i = end
                }
            } else {
                if c == "[" || c == "]" { out.append("\\") }
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    // MARK: Splicing

    /// Inserts `line` as its own paragraph directly under the first ATX H1 of
    /// `body`, skipping fenced code; at the top of the body when there is no
    /// H1. Blank lines on both sides keep it from merging with a paragraph
    /// that follows the H1 without one.
    static func insertUnderH1(_ line: String, into body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        var fence: (marker: Character, length: Int)?
        var insertion: Int?
        for (i, text) in lines.enumerated() {
            if let run = fenceRun(text) {
                if let open = fence {
                    if run.marker == open.marker, run.length >= open.length { fence = nil }
                } else {
                    fence = run
                }
                continue
            }
            if fence == nil, isH1(text) {
                insertion = i + 1
                break
            }
        }

        if let insertion {
            lines.insert(contentsOf: ["", line, ""], at: insertion)
        } else {
            // No H1: lead the body, after any blank lines it starts with.
            let first = lines.firstIndex {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? lines.count
            lines.insert(contentsOf: [line, ""], at: first)
        }
        return lines.joined(separator: "\n")
    }

    /// `^ {0,3}(`{3,}|~{3,})`: the fence test the site's splice uses, which is
    /// all it needs to step over `# comment` lines in code.
    private static func fenceRun(_ line: String) -> (marker: Character, length: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    /// `^ {0,3}#(?:[ \t\r]|$)`: an ATX H1.
    private static func isH1(_ line: String) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        guard rest.first == "#" else { return false }
        let next = rest.dropFirst().first
        return next == nil || next == " " || next == "\t" || next == "\r"
    }

    // MARK: Frontmatter values

    /// YAML scalars that are not strings. The site reads frontmatter with
    /// js-yaml's JSON schema, where these are booleans and null and print as
    /// nothing; `Frontmatter` keeps them as text.
    private static let nonStrings: Set<String> = [
        "true", "True", "TRUE", "false", "False", "FALSE", "null", "Null", "NULL", "~",
    ]

    /// A scalar field as one line of text. A list, a mapping (which
    /// `Frontmatter` reads as null, or as `{…}` text when written inline), a
    /// boolean or null reads as empty, so a field the lint would reject is
    /// left out of the line rather than printed.
    private static func scalar(_ value: Frontmatter.Value?) -> String {
        guard case .string(let raw)? = value else { return "" }
        let text = oneLine(raw)
        if nonStrings.contains(text) || (text.hasPrefix("{") && text.hasSuffix("}")) {
            return ""
        }
        return text
    }

    /// A list field, or a lone scalar, as its non-empty scalar entries. Unlike
    /// `Frontmatter.list`, a lone scalar is never split on commas: it is one
    /// source or one assumption, whatever it says.
    private static func list(_ value: Frontmatter.Value?) -> [String] {
        switch value {
        case .some(.list(let items)):
            return items.map { Self.scalar(Frontmatter.Value.string($0)) }.filter { !$0.isEmpty }
        case .some(.string):
            let text = scalar(value)
            return text.isEmpty ? [] : [text]
        default:
            return []
        }
    }

    /// YAML's `true`, which is what `heuristic: true` must say. (A quoted
    /// "true" is a string to the site; `Frontmatter` cannot tell the two
    /// apart, and the lint allows only the boolean.)
    private static func isTrue(_ value: Frontmatter.Value?) -> Bool {
        guard case .string(let raw)? = value else { return false }
        return ["true", "True", "TRUE"].contains(oneLine(raw))
    }

    /// Collapses YAML line folding and stray whitespace to single spaces.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
