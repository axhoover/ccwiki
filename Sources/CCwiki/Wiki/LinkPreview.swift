import Foundation
import os

/// The card shown when the pointer rests on a link to a wiki page.
///
/// The site's Quartz popover fetches the target and shows all of it. The
/// reader is offline and exists to avoid a second full render, so a card is a
/// summary computed here with the page, and `ccwiki.js` only lays it out:
/// every word on it is chosen in Swift (relations-explorer.md §4).
///
/// A card shows recorded data only, never a derived claim: a page's title
/// and first paragraph, or a reduction's or barrier's whole hyperedge with the
/// fields its page states (derivations.md §7).
struct LinkPreview: Hashable, Sendable {
    /// "Reduction", "Primitive · stub", "Section of Hash function". Plain
    /// text.
    let kind: String
    /// Inline markdown, math kept and links removed. A reduction's statement
    /// is never cut; any other title is capped.
    let title: String
    /// Inline markdown parts, shown joined with `RelationMeta.separator`'s dot.
    let meta: [String]
    /// A caveat that has to travel with the title, plain text: R8's
    /// qualifier on a stub, unclassified or fixed-construction barrier,
    /// whose title alone reads as an unqualified result.
    let note: String?
    /// Inline markdown, at most `PreviewExcerpt.hardLimit` source characters.
    let excerpt: String?
    /// The whole card as plain text, for VoiceOver: KaTeX's HTML output,
    /// which the reader uses as the site does, is not readable by it.
    let label: String

    /// The caps that keep a card near 1.2 KB, so the busiest page's payload
    /// stays small: LWE links to 55 distinct targets.
    static let titleLimit = 160
    static let metaLimit = 120
    static let labelLimit = 700

    init(kind: String, title: String, meta: [String] = [], note: String? = nil, excerpt: String?) {
        self.kind = kind
        self.title = title
        self.meta = meta
        self.note = note
        self.excerpt = excerpt
        self.label = Self.spokenLabel(
            kind: kind, title: title, meta: meta, note: note, excerpt: excerpt)
    }

    /// The card read aloud, in the order it is laid out: each part a
    /// sentence, the meta parts a list. The note comes straight after the
    /// title it qualifies.
    private static func spokenLabel(
        kind: String, title: String, meta: [String], note: String?, excerpt: String?
    ) -> String {
        var sentences: [String] = [kind, PreviewExcerpt.plainText(title)]
        if let note { sentences.append(note) }
        sentences.append(meta.map(PreviewExcerpt.plainText).joined(separator: ", "))
        if let excerpt { sentences.append(PreviewExcerpt.plainText(excerpt)) }
        let text = sentences
            .filter { !$0.isEmpty }
            .map { sentence in
                guard let last = sentence.last, !".!?…".contains(last) else { return sentence }
                return sentence + "."
            }
            .joined(separator: " ")
        return PreviewExcerpt.capped(text, at: labelLimit)
    }

    /// The card as `ccwiki.js` reads it from `payload.previews`.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["kind": kind, "title": title, "meta": meta, "label": label]
        if let note { object["note"] = note }
        if let excerpt { object["excerpt"] = excerpt }
        return object
    }
}

/// Every page's card, built once per library load, and section cards on
/// demand.
///
/// Built in `loadLibrary`'s detached task beside `RelationLabels`: one
/// paragraph scan per page, a few tens of milliseconds for the corpus. A
/// link to `page#anchor` gets a card for that section, worked out the first
/// time a page holding the link is rendered; there are seldom more than ten.
struct LinkPreviews: Sendable {

    static let empty = LinkPreviews(pages: [:], manifest: .empty, cards: [:])

    /// Kept for section cards, which are worked out on demand.
    private let pages: [String: WikiPage]
    private let manifest: RelationsManifest
    private let cards: [String: LinkPreview]
    /// The section cards worked out so far, from `pages` and `manifest`.
    private let sections = SectionCards()

    private init(
        pages: [String: WikiPage], manifest: RelationsManifest, cards: [String: LinkPreview]
    ) {
        self.pages = pages
        self.manifest = manifest
        self.cards = cards
    }

    init(index: WikiIndex, manifest: RelationsManifest, labels: RelationLabels) {
        var cards: [String: LinkPreview] = [:]
        cards.reserveCapacity(index.pages.count)
        for (path, page) in index.pages {
            cards[path] = Self.card(for: page, manifest: manifest, labels: labels)
        }
        self.init(pages: index.pages, manifest: manifest, cards: cards)
    }

    /// How many pages have a card: every page in the index.
    var count: Int { cards.count }

    /// The card for a resolved page link: the section's when `anchor` names a
    /// heading on the page, else the page's. Nil for a page this library does
    /// not have.
    func preview(path: String, anchor: String?) -> LinkPreview? {
        if let anchor, !anchor.isEmpty, let page = pages[path] {
            let section = sections.card(path: path, anchor: anchor) {
                Self.sectionCard(for: page, anchor: anchor, manifest: manifest)
            }
            if let section { return section }
        }
        return cards[path]
    }

    // MARK: Page cards

    /// The card for a whole page, by what the page is.
    static func card(
        for page: WikiPage, manifest: RelationsManifest, labels: RelationLabels
    ) -> LinkPreview {
        switch page.kind {
        case .reduction:
            return reductionCard(page, manifest: manifest, labels: labels)
        case .barrier:
            return barrierCard(page, manifest: manifest, labels: labels)
        case .reference:
            return referenceCard(page)
        case .primitive, .assumption, .complexityClass, .glossary, .folklore, .note:
            return LinkPreview(
                kind: kindName(page.kind) + stubSuffix(page),
                title: pageTitle(page),
                excerpt: excerpt(PreviewExcerpt.firstParagraph(in: page.body, anchor: nil)))
        }
    }

    static func kindName(_ kind: PageKind) -> String {
        switch kind {
        case .primitive: "Primitive"
        case .assumption: "Assumption"
        case .complexityClass: "Complexity class"
        case .glossary: "Glossary"
        case .folklore: "Folklore"
        case .note: "Note"
        case .reference: "Reference"
        case .reduction: "Reduction"
        case .barrier: "Barrier"
        }
    }

    private static func stubSuffix(_ page: WikiPage) -> String {
        page.status == .stub ? " · stub" : ""
    }

    /// The page's own title, as markdown that shows it the way its H1 does:
    /// math kept, a lone dollar (IND$-CPA) and brackets escaped.
    private static func pageTitle(_ page: WikiPage) -> String {
        PreviewExcerpt.capped(
            RelationMeta.escapeOutsideMath(page.title), at: LinkPreview.titleLimit)
    }

    private static func excerpt(_ paragraph: String?) -> String? {
        guard let paragraph else { return nil }
        let inline = PreviewExcerpt.inlineWithoutLinks(paragraph)
        return inline.isEmpty ? nil : PreviewExcerpt.truncated(inline)
    }

    // MARK: Reductions

    /// Titled by the hyperedge from the manifest, every hypothesis and `⇢`
    /// for a heuristic edge, never cut: a title that dropped a conjunct would
    /// state an implication the wiki does not make. The meta is the page's
    /// own relation-meta line, without its links.
    private static func reductionCard(
        _ page: WikiPage, manifest: RelationsManifest, labels: RelationLabels
    ) -> LinkPreview {
        let kind: String
        let title: String
        if let relation = manifest.relation(onPage: page.path) {
            kind = relation.kind == .implication ? "Reduction" : relation.kind.title
            title = PreviewExcerpt.escaped(labels.statement(relation))
        } else {
            // A manifest that does not know the page (an old clone): the
            // frontmatter's kind, and the page's own title.
            switch page.frontmatter.string("kind") ?? "" {
            case "equivalence": kind = "Equivalence"
            case "inclusion": kind = "Inclusion"
            default: kind = "Reduction"
            }
            title = pageTitle(page)
        }

        var meta = metaParts(RelationMeta.parts(
            for: page.frontmatter, manifest: manifest, labels: labels))
        // The line leads with "Equivalence" or "Inclusion", which the card
        // already says above the title.
        if let first = meta.first, PreviewExcerpt.plainText(first).lowercased() == kind.lowercased() {
            meta.removeFirst()
            if let next = meta.first { meta[0] = capitalizingFirst(next) }
        }
        return LinkPreview(
            kind: kind + stubSuffix(page),
            title: title,
            meta: meta,
            excerpt: excerpt(PreviewExcerpt.firstParagraph(in: page.body, anchor: nil)))
    }

    // MARK: Barriers

    /// Titled by the page title ("No relativizing reduction from OWP to KE"),
    /// never the bare edge, which alone would read as an implication.
    ///
    /// The meta is the page's relation-meta line with two additions the
    /// line leaves out. An unstated class stays on the card: "against
    /// reductions of a class the wiki does not state", where the line, for
    /// the site's sake, says nothing (derivations.md §7). And a circumvented
    /// barrier says so, because the manifest's contract is that a barrier is
    /// never shown without its `circumventedBy`. R8's qualifier rides in
    /// `note`.
    private static func barrierCard(
        _ page: WikiPage, manifest: RelationsManifest, labels: RelationLabels
    ) -> LinkPreview {
        let barrier = manifest.barrier(onPage: page.path)
        let fields = page.frontmatter
        var parts = RelationMeta.parts(for: fields, manifest: manifest, labels: labels)

        // Exactly when `RelationMeta.parts` leaves the class out.
        let reductionClass = scalar(fields, "class")
        if reductionClass.isEmpty || reductionClass == "unstated" {
            let phrase = "against reductions of a class the wiki does not state"
            // After the strength, which leads the line when it is there.
            if scalar(fields, "strength").isEmpty {
                parts.insert(capitalizingFirst(phrase), at: 0)
            } else {
                parts.insert(phrase, at: min(1, parts.count))
            }
        }
        if let barrier, !barrier.circumventedBy.isEmpty {
            parts.append(PreviewExcerpt.escaped(circumvention(of: barrier, manifest: manifest)))
        }

        return LinkPreview(
            kind: "Barrier" + stubSuffix(page),
            title: pageTitle(page),
            meta: metaParts(parts),
            note: qualifier(page, barrier: barrier, manifest: manifest),
            excerpt: excerpt(PreviewExcerpt.firstParagraph(in: page.body, anchor: nil)))
    }

    /// R8's qualifier, which has to be printed beside a barrier's title
    /// wherever the title appears, because the wiki writes every barrier as
    /// an unqualified "No reduction from A to B". By the manifest's record
    /// when it has the barrier, else by the page's frontmatter.
    static func qualifier(
        _ page: WikiPage, barrier: Barrier?, manifest: RelationsManifest
    ) -> String? {
        let isStub: Bool
        let isUnclassified: Bool
        let reductionClass: String
        if let barrier {
            isStub = barrier.status == .stub
            reductionClass = barrier.reductionClass
            isUnclassified = manifest.isSentinel(reductionClass)
                || manifest.classes[reductionClass] == nil
        } else {
            isStub = page.status == .stub
            reductionClass = scalar(page.frontmatter, "class")
            isUnclassified = reductionClass.isEmpty || reductionClass == "unstated"
        }
        if isStub { return "Stub: its class and consequences are not evidence." }
        if isUnclassified {
            return "Rules out a kind of reduction the wiki does not classify; see its statement."
        }
        if reductionClass == "fixed-construction" {
            return "Refutes only the construction named on its page; building the target "
                + "another way is not ruled out."
        }
        return nil
    }

    /// "circumvented by BH26": the citation keys of the reductions that get
    /// around the barrier, as the Relations inspector words it.
    static func circumvention(of barrier: Barrier, manifest: RelationsManifest) -> String {
        var keys: [String] = []
        for relation in manifest.reductions(circumventing: barrier) {
            for key in relation.source.compactMap({ RelationText.citationKey($0) })
            where key != "folklore" && !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys.isEmpty ? "circumvented" : "circumvented by " + keys.joined(separator: ", ")
    }

    // MARK: References

    /// The paper's title, its authors, venue and year, and the first
    /// paragraph of its abstract. 234 reference pages have no abstract yet,
    /// only "TODO — abstract.", and get no excerpt rather than a later
    /// section's text passed off as one.
    private static func referenceCard(_ page: WikiPage) -> LinkPreview {
        var meta: [String] = []
        if let authors = page.authors.map(authorLine), !authors.isEmpty {
            meta.append(PreviewExcerpt.escaped(authors))
        }
        let venue = page.venue
        if let venue { meta.append(PreviewExcerpt.escaped(venue)) }
        // The venue usually carries the year already ("EUROCRYPT 2002").
        if let year = page.published.map({ String($0.prefix(4)) }),
           year.count == 4, year.allSatisfy(\.isNumber), !(venue?.contains(year) ?? false) {
            meta.append(year)
        }

        let paragraph: String?
        if let abstract = PreviewExcerpt.scope(of: page.body, anchor: "abstract") {
            paragraph = PreviewExcerpt.firstParagraph(inLines: abstract.lines)
        } else {
            paragraph = PreviewExcerpt.firstParagraph(in: page.body, anchor: nil)
        }
        return LinkPreview(
            kind: kindName(.reference),
            title: PreviewExcerpt.capped(
                PreviewExcerpt.escaped(page.displayTitle), at: LinkPreview.titleLimit),
            meta: metaParts(meta),
            excerpt: excerpt(paragraph))
    }

    /// Four authors or fewer by name, else the first "et al.". The wiki
    /// writes the list three ways: "A, B, and C", "A and B", and
    /// "Last, First; Last, First".
    static func authorLine(_ authors: String) -> String {
        let names = authorNames(authors)
        guard let first = names.first else { return "" }
        return names.count <= 4 ? names.joined(separator: ", ") : first + " et al."
    }

    private static func authorNames(_ authors: String) -> [String] {
        if authors.contains(";") {
            return authors.split(separator: ";").compactMap { entry -> String? in
                let parts = entry.split(separator: ",", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let name = parts.count == 2 ? parts[1] + " " + parts[0] : parts.joined()
                return name.isEmpty ? nil : name
            }
        }
        return authors.replacingOccurrences(of: " and ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Sections

    /// A link to `page#anchor`: "Section of" the page, titled by the variant
    /// the anchor names, else by the heading, with the section's first
    /// paragraph. Nil when no heading has that id, or it is the page's own
    /// H1, and the page's card serves.
    ///
    /// The host's title is the page's own words, so a reduction's or a
    /// barrier's keeps the rules its page card follows: never cut, since a
    /// cut can drop a conjunct or a barrier's conclusion, and a barrier's
    /// with R8's qualifier, which goes wherever its title does.
    static func sectionCard(
        for page: WikiPage, anchor: String, manifest: RelationsManifest
    ) -> LinkPreview? {
        guard let scope = PreviewExcerpt.scope(of: page.body, anchor: anchor),
              let heading = scope.heading, !scope.isWholePage
        else { return nil }

        let variant = manifest.objectIDs(onPage: page.path)
            .compactMap { manifest.object($0) }
            .first { $0.isVariant && $0.anchor == anchor }
        let title: String
        if let variant, !variant.title.isEmpty, variant.title != variant.id {
            title = RelationMeta.escapeOutsideMath(variant.title)
        } else {
            title = PreviewExcerpt.inlineWithoutLinks(heading)
        }
        let plainHost = RelationText.plain(page.title)
        let isRelationPage = page.kind == .reduction || page.kind == .barrier
        let host = isRelationPage
            ? plainHost : PreviewExcerpt.capped(plainHost, at: LinkPreview.metaLimit)
        let note: String? = page.kind == .barrier
            ? qualifier(page, barrier: manifest.barrier(onPage: page.path), manifest: manifest)
            : nil
        return LinkPreview(
            kind: "Section of \(host)",
            title: PreviewExcerpt.capped(title, at: LinkPreview.titleLimit),
            note: note,
            excerpt: excerpt(PreviewExcerpt.firstParagraph(inLines: scope.lines)))
    }

    // MARK: Helpers

    /// Relation-meta parts without their links, each capped: security losses
    /// run long.
    private static func metaParts(_ parts: [String]) -> [String] {
        parts
            .map { PreviewExcerpt.capped(PreviewExcerpt.inlineWithoutLinks($0), at: LinkPreview.metaLimit) }
            .filter { !$0.isEmpty }
    }

    /// The first letter in upper case, when it is a lower-case letter, as the
    /// relation-meta line leads with a capital.
    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + String(text.dropFirst())
    }

    /// A frontmatter field as `RelationMeta` reads a scalar: one line, and
    /// empty for a list, a mapping, a boolean or null.
    private static func scalar(_ frontmatter: Frontmatter, _ key: String) -> String {
        guard case .string(let raw)? = frontmatter.fields[key] else { return "" }
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let nonStrings: Set<String> = [
            "true", "True", "TRUE", "false", "False", "FALSE", "null", "Null", "NULL", "~",
        ]
        if nonStrings.contains(text) || (text.hasPrefix("{") && text.hasSuffix("}")) { return "" }
        return text
    }
}

/// The section cards one `LinkPreviews` has worked out, by page and anchor.
/// Each card reads its page's headings, and a page renders again on every
/// visit, so without this every render of a page with section links reads
/// each target page again (plans/efficiency.md, L6).
///
/// A card is a function of the pages and the manifest the previews hold,
/// which never change, so the box lives and dies with them and is never
/// invalidated (SWIFTUI-RULES §3.2): a load builds new previews, with an
/// empty box. A nil card is kept too, for an anchor that names no section
/// or the page's own H1. A lock, since renders may come from any task.
private final class SectionCards: Sendable {

    private struct Key: Hashable, Sendable {
        let path: String
        let anchor: String
    }

    private let cards = OSAllocatedUnfairLock<[Key: LinkPreview?]>(initialState: [:])

    /// The card for `anchor` on the page at `path`, from `make` the first
    /// time it is asked for.
    func card(path: String, anchor: String, _ make: () -> LinkPreview?) -> LinkPreview? {
        let key = Key(path: path, anchor: anchor)
        if let known = cards.withLock({ $0[key] }) { return known }
        let card = make()
        cards.withLock { $0[key] = .some(card) }
        return card
    }
}
