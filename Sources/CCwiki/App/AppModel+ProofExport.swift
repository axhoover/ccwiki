import Foundation

// Copy Proof As, for the explorer and the inspector (plans/relations-followups.md
// §3). The writers are pure; this is where they meet the library and the
// pasteboard.

extension AppModel {

    /// What the writers read: the derivation's manifest, the labels, the
    /// reference pages for citation keys, the wiki's macros for math, and the
    /// clone's commit for the provenance line. Built when asked: it holds
    /// the index, it does not walk it.
    var proofWriterContext: ProofWriterContext {
        ProofWriterContext(
            manifest: derivation.manifest, labels: relationLabels,
            citations: ProofCitations(index: index), macros: macros, revision: headRevision)
    }

    /// Text goes through `ProofCopy.text(revision:)`, as it always has. BibTeX
    /// copies nothing when no cited work has an inline entry: the commands
    /// that offer it are hidden or disabled then.
    func copyProof(_ copy: ProofCopy, as format: ProofFormat) {
        let text: String?
        switch format {
        case .text: text = copy.text(revision: headRevision)
        case .latex: text = ProofLaTeX.write(copy.export, context: proofWriterContext)
        case .wikiMarkdown: text = ProofMarkdown.write(copy.export, context: proofWriterContext)
        case .bibtex: text = ProofBibTeX.write(copy.export, context: proofWriterContext)
        }
        guard let text else { return }
        copyToPasteboard(text)
    }

    /// The inspector's derived rows: the row's own question, answered with
    /// the default models as the inspector shows it, then copied. One
    /// derivable answer, so milliseconds, and the explorer's own result
    /// builds the copy, so the two cannot differ.
    func copyDerivedProof(from start: [String], to target: String, as format: ProofFormat) {
        let query = ExplorerQuery(from: start, to: target)
        let result = ExplorerResult.compute(query, derivation: derivation, labels: relationLabels)
        guard let copy = result.proofCopy(selection: [], showingStronger: false) else { return }
        copyProof(copy, as: format)
    }
}
