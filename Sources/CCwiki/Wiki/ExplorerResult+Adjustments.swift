import Foundation

// The explorer's Adjustments (plans/relations-followups.md §2.5): what CCwiki
// applies that relations.json does not record, each beside the wiki's own
// text, so a reader can check it against the page.
//
// Each adjustment is shown once. A refused step carries its entry's quotes on
// its own row; a derivable answer's last section holds the entries no row
// shows, and a no-derivation answer's holds what its starts are. The words
// are DerivationWording's; this decides what each row says and links to.

extension ExplorerResult {

    /// The section's id, for the shortest proof's and the stronger proof's
    /// alike: Show It swaps one for the other.
    static let adjustmentsID = "adjustments"

    /// `nil` when the trace is empty. `idPrefix` keeps the stronger proof's
    /// row ids apart from the shortest's: "adjustments",
    /// "stronger-adjustments".
    static func adjustmentsSection(_ trace: CurationTrace, idPrefix: String,
                                   writer: ExplorerWriter) -> ExplorerSection? {
        guard !trace.isEmpty else { return nil }
        let rows = trace.items.map { writer.adjustmentRow($0, id: "\(idPrefix)/\($0.id)") }
        return ExplorerSection(id: adjustmentsID, title: DerivationWording.adjustmentsTitle,
                               help: DerivationWording.adjustmentsHelp, rows: rows)
    }
}

extension ExplorerWriter {

    // MARK: Evidence

    /// One entry's citations as notes, `“<quote>” — <page> § <section>`, and
    /// one link per page they are on, for a refused row, a recorded-on-pair
    /// row or an adjustment row. A quote the clone's page no longer has is
    /// not shown as the wiki's: its note says so, and that CCwiki still
    /// applies the entry as reviewed.
    func curationEvidence(_ key: DerivationCuration.Entry.Key,
                          rowID: String) -> (notes: [String], links: [ExplorerRow.Link]) {
        guard let entry = derivation.curation.entry(key) else { return ([], []) }
        var notes: [String] = []
        var pages: [String] = []
        var sections: [String: String] = [:]
        for citation in entry.cites {
            let path = citation.contentPath
            let page = citedPageTitle(path)
            if derivation.unverifiedCitations.contains(citation) {
                notes.append(DerivationWording.unverifiedQuote(
                    pageTitle: page, commit: derivation.curation.reviewedCommit))
            } else {
                let place = citation.section.map { page + " § " + RelationText.plain($0) } ?? page
                notes.append("“" + CurationTrace.plainQuote(citation.quote) + "” — " + place)
            }
            if !pages.contains(path) { pages.append(path) }
            if sections[path] == nil, let section = citation.section { sections[path] = section }
        }
        let links = pages.enumerated().map { index, path in
            ExplorerRow.Link(id: "\(rowID)/cite-\(index)", title: citedPageTitle(path),
                             target: citationTarget(path, section: sections[path]))
        }
        return (notes, links)
    }

    /// How a cited page is named: a reduction as a menu names it, a barrier
    /// by its title, an object's page by the object, and any other page by
    /// its file name.
    func citedPageTitle(_ path: String) -> String {
        if let relation = manifest.relation(onPage: path) { return reductionName(relation.id) }
        if let barrier = manifest.barrier(onPage: path) { return barrierTitle(barrier) }
        let host = manifest.objectIDs(onPage: path).first { manifest.object($0)?.isVariant == false }
        if let host { return label(host) }
        let file = path.split(separator: "/").last.map(String.init) ?? path
        return file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    }

    /// `links`, then each of `cited` that opens a page none of them opens. A
    /// link that opens a cited page whole opens it at the quote instead, so
    /// a refused step's own page is linked once, where the wiki says why.
    static func merging(_ cited: [ExplorerRow.Link],
                        into links: [ExplorerRow.Link]) -> [ExplorerRow.Link] {
        var merged = links
        for link in cited {
            guard let path = link.target.pagePath else { continue }
            guard let index = merged.firstIndex(where: { $0.target.pagePath == path }) else {
                merged.append(link)
                continue
            }
            if case .page = merged[index].target {
                let whole = merged[index]
                merged[index] = ExplorerRow.Link(id: whole.id, title: whole.title, target: link.target)
            }
        }
        return merged
    }

    private func citedPageKind(_ path: String) -> String {
        if manifest.relation(onPage: path) != nil { return "Reduction" }
        if manifest.barrier(onPage: path) != nil { return "Barrier" }
        return "Page"
    }

    /// The page at the cited heading, by the anchor the site gives it, or
    /// the whole page for a quote from anywhere in it.
    private func citationTarget(_ path: String, section: String?) -> ExplorerRow.Target {
        guard let section else { return .page(path) }
        return .section(path: path, anchor: GithubSlugger.slug(section))
    }

    // MARK: Rows

    /// One entry of the trace: what it did, then the wiki's text for it.
    func adjustmentRow(_ item: CurationTrace.Item, id: String) -> ExplorerRow {
        let title = adjustmentTitle(item)
        let evidence = curationEvidence(item.entry.key, rowID: id)
        var row = ExplorerRow(id: id, title: title, accessibilityLabel: title)
        row.wraps = true
        row.notes = evidence.notes
        row.links = evidence.links
        let quotesFound = !item.entry.cites.contains { derivation.unverifiedCitations.contains($0) }
        row.help = DerivationWording.adjustmentHelp(quotesFound: quotesFound)
        if let first = item.entry.cites.first {
            let path = first.contentPath
            row.primary = citationTarget(path, section: first.section)
            row.page = ExplorerRow.PageLink(kind: citedPageKind(path), title: citedPageTitle(path),
                                            path: path)
        }
        row.statement = ([title] + evidence.notes).joined(separator: "\n")
        return row
    }

    /// Each thing is said once (§2.5): an effect the proof row or the verdict
    /// already states has no sentence here, and an item made only of those
    /// is titled by the step or the object it is about.
    private func adjustmentTitle(_ item: CurationTrace.Item) -> String {
        let sentences = item.effects.compactMap { adjustmentSentence($0) }
        if !sentences.isEmpty { return sentences.joined(separator: " ") }
        return item.effects.first.map { adjustmentSubject($0) } ?? item.entry.id
    }

    private func adjustmentSentence(_ effect: CurationTrace.Effect) -> String? {
        switch effect {
        case .establishedBy(let relationID, let isReverse, let hypothesis, let producerID):
            return DerivationWording.establishedBy(
                step: stepName(relationID, isReverse: isReverse),
                notion: notion(relationID, isReverse: isReverse, hypothesis: hypothesis),
                producer: producer(producerID))
        case .notUsedHere(let relationID, let isReverse, let hypothesis, let producerID):
            return DerivationWording.notUsedHere(
                step: stepName(relationID, isReverse: isReverse),
                notion: notion(relationID, isReverse: isReverse, hypothesis: hypothesis),
                hypothesis: label(hypothesis), producer: producer(producerID))
        case .accepted(let producerID, let consumerID):
            return DerivationWording.accepted(
                consumer: producer(consumerID), producer: producer(producerID),
                notion: derivation.curation.weakens[producerID]?.notion ?? "")
        case .unstatedDirection(let relationID, let isReverse):
            return DerivationWording.unstatedDirection(step: stepName(relationID, isReverse: isReverse))
        case .assumed, .keptApart, .vacuous, .setting:
            return nil
        }
    }

    /// What an effect is about: its step, or the start it concerns.
    private func adjustmentSubject(_ effect: CurationTrace.Effect) -> String {
        switch effect {
        case .assumed(let relationID, let isReverse, _),
             .establishedBy(let relationID, let isReverse, _, _),
             .notUsedHere(let relationID, let isReverse, _, _),
             .unstatedDirection(let relationID, let isReverse):
            stepName(relationID, isReverse: isReverse)
        case .keptApart(let relationID), .accepted(let relationID, _):
            stepName(relationID, isReverse: false)
        case .vacuous(let objectID), .setting(let objectID):
            label(objectID)
        }
    }

    /// A step as a sentence names it, `OT ⇒ MPC (Kil88)`, in the direction
    /// it was used.
    private func stepName(_ relationID: String, isReverse: Bool) -> String {
        let key = Derivation.StepKey(relationID: relationID, isReverse: isReverse)
        return derivation.stepsByKey[key].map { stepText($0) } ?? producer(relationID)
    }

    /// The notion a step's precondition asks of a hypothesis, in the
    /// curation's words.
    private func notion(_ relationID: String, isReverse: Bool, hypothesis: String) -> String {
        derivation.curation.requirements(on: relationID, isReverse: isReverse)
            .first { $0.hypothesis == hypothesis }?.notion ?? label(hypothesis)
    }
}

extension ExplorerRow.Target {
    /// The page a target opens, whole or at a heading; `nil` for an object,
    /// a row or a question.
    var pagePath: String? {
        switch self {
        case .page(let path), .section(let path, _):
            return path
        case .object, .reveal, .ask:
            return nil
        }
    }
}
