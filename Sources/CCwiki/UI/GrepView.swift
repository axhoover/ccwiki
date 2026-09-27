import SwiftUI

/// ⇧⌘F — the literal text, on every page, with the lines it is on.
///
/// Where ⌘S answers "which pages are about this", this answers "where does
/// this string occur", all of it and in page order. The excerpts are the
/// markdown as written, so they are set in the monospaced face.
struct GrepView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        SearchPalette(
            query: $model.grepQuery,
            placeholder: "Find in all pages",
            systemImage: "doc.text.magnifyingglass",
            items: model.grepResults,
            error: nil,
            emptyTitle: "Find in All Pages",
            emptyDescription: "The exact text, on every page, references included. "
                + "Case matters only if you type a capital.",
            countLabel: { _ in model.grepSummary },
            open: { model.openGrepResult($0, query: model.grepQuery) }
        ) { hit in
            resultRow(hit)
        }
    }

    private func resultRow(_ hit: TextGrep.Hit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.small) {
                KindIcon(kind: hit.kind)
                Text(hit.title)
                    .font(Theme.Fonts.paletteSubtitle.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(hit.count, format: .number)
                    .font(Theme.Fonts.meta)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(hit.count) matches")
                Spacer(minLength: Theme.small)
                Text(hit.path)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(hit.excerpts.enumerated()), id: \.offset) { _, excerpt in
                    markedSnippet(excerpt)
                        .font(Theme.Fonts.log)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if hit.lineCount > hit.excerpts.count {
                    let more = hit.lineCount - hit.excerpts.count
                    Text("and \(more) more line\(more == 1 ? "" : "s")")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 20)
        }
    }
}
