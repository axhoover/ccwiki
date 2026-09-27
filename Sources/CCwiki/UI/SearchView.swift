import SwiftUI

/// ⌘S — concept search: every page but the references, names first, in
/// `ConceptRanker`'s order.
///
/// Distinct from the quick switcher: that one is "I know the page"; this one
/// is "which pages are about this". Results carry the matching passage, because
/// a list of titles does not tell you which hit you want, and a hit that
/// matched a heading names it and opens there.
struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        SearchPalette(
            query: $model.searchQuery,
            placeholder: "Search the wiki",
            systemImage: "text.magnifyingglass",
            items: model.searchResults,
            error: model.searchError,
            emptyTitle: "Search the Wiki",
            emptyDescription: "Names and aliases first, then headings, then text. "
                + "Primitives and assumptions lead. Papers have their own search, ⇧⌘R.",
            countLabel: { "\($0) page\($0 == 1 ? "" : "s")" },
            open: { model.openSearchResult($0, query: model.searchQuery) }
        ) { hit in
            resultRow(hit)
        }
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.small) {
                KindIcon(kind: hit.kind)
                title(hit)
                    .font(Theme.Fonts.paletteSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                StatusBadge(status: hit.status, compact: true)
                Spacer(minLength: Theme.small)
                Text(hit.path)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // A page found by its name alone has no passage to show.
            if !hit.snippet.isEmpty {
                markedSnippet(hit.snippet)
                    .font(Theme.Fonts.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 20)
            }
        }
    }

    /// "Learning with errors › Ring-LWE" when a section matched: the page in
    /// the weight of a title, the section as the lighter half of the trail.
    private func title(_ hit: SearchHit) -> Text {
        let page = Text(hit.title).fontWeight(.medium)
        guard let section = hit.section else { return page }
        return page + Text("  ›  \(section)").foregroundStyle(.secondary)
    }
}
