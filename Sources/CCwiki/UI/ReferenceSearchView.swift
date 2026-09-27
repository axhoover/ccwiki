import SwiftUI

/// ⇧⌘R — the papers: by citation key, author, title, the concept pages that
/// cite them, and their abstracts, in `ReferenceRanker`'s order.
///
/// A row reads like a bibliography entry, key first because the wiki cites
/// by key, and says why a paper matched when its entry alone does not show
/// it: the page that cites it, or the passage of its abstract.
struct ReferenceSearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        SearchPalette(
            query: $model.referenceQuery,
            placeholder: "Search papers by key, author, title or topic",
            systemImage: "books.vertical",
            items: model.referenceResults,
            error: model.referenceError,
            emptyTitle: "Search the References",
            emptyDescription: "A citation key such as GGM86, an author, words of a title, "
                + "or a topic. Add a year to narrow it: regev 2005.",
            countLabel: { "\($0) paper\($0 == 1 ? "" : "s")" },
            open: { model.openReferenceResult($0, query: model.referenceQuery) }
        ) { hit in
            resultRow(hit)
        }
    }

    private func resultRow(_ hit: ReferenceHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                KindIcon(kind: .reference)
                (Text(hit.key).fontWeight(.semibold) + Text("  ") + Text(hit.title))
                    .font(Theme.Fonts.paletteSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.small)
                if let year = hit.year {
                    Text(String(year))
                        .font(Theme.Fonts.meta)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                Text(byline(hit))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let citedBy = hit.citedBy {
                    Label("Cited by \(citedBy)", systemImage: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                } else if hit.field == .text, !hit.snippet.isEmpty {
                    markedSnippet(hit.snippet)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .font(Theme.Fonts.rowSubtitle)
            .padding(.leading, 20)
        }
    }

    /// "Oded Goldreich, Shafi Goldwasser, Silvio Micali · J. ACM"
    private func byline(_ hit: ReferenceHit) -> String {
        [hit.authors, hit.venue ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
