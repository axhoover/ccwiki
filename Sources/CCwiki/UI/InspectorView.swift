import SwiftUI

/// The right column: the page's outline, what links to it, or what it relates
/// to.
///
/// One pane with a segmented switch rather than three panes. The first two
/// answer the same question — "where am I in this, and what points here?" — and
/// Relations answers the one the wiki's own data now makes answerable: what
/// this object implies and what implies it. None is worth a permanent column.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            // Titles without icons. Two segments fitted comfortably with both;
            // three do not, and a truncated word is worse than no glyph — the
            // names are the affordance here, and macOS segmented controls are
            // routinely text-only.
            Picker("", selection: $model.inspectorTab) {
                ForEach(AppModel.InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.small)

            Divider()

            switch model.inspectorTab {
            case .outline: outline
            case .backlinks: backlinks
            case .relations: RelationsView()
            }
        }
        .navigationSplitViewColumnWidth(
            min: Theme.inspectorMinWidth,
            ideal: Theme.inspectorIdealWidth,
            max: Theme.inspectorMaxWidth)
    }

    // MARK: Outline

    private var outline: some View {
        Group {
            let headings = model.webController.outline
            if headings.isEmpty {
                emptyPane("No Headings", systemImage: "list.bullet.indent",
                          detail: "This page has no section headings.")
            } else {
                List {
                    ForEach(headings) { heading in
                        Button {
                            model.webController.scrollTo(anchor: heading.id)
                        } label: {
                            Text(heading.text)
                                .font(headingFont(heading.level))
                                .foregroundStyle(
                                    heading.id == model.webController.activeHeadingID
                                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Indent by level so the shape of the document
                                // is legible at a glance.
                                .padding(.leading, CGFloat(max(0, heading.level - 1)) * Theme.medium)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: Theme.Fonts.row.weight(.semibold)
        case 2: Theme.Fonts.row
        default: Theme.Fonts.rowSubtitle
        }
    }

    // MARK: Backlinks

    private var backlinks: some View {
        Group {
            let links = model.currentBacklinks
            if links.isEmpty {
                emptyPane("No Backlinks", systemImage: "arrow.turn.up.left",
                          detail: "No other page links here yet.")
            } else {
                List {
                    ForEach(links) { link in
                        Button {
                            model.openPage(link.sourcePath)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.title(forPath: link.sourcePath))
                                    .font(Theme.Fonts.row)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                // The line that mentions this page — *why* it
                                // links here, which is the useful half.
                                Text(link.context)
                                    .font(Theme.Fonts.rowSubtitle)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if let page = model.index?.pages[link.sourcePath],
                               let url = AppModel.siteURL(slug: page.slug) {
                                Button("Open on cryptology.city") { NSWorkspace.shared.open(url) }
                                Button("Copy Link") { model.copyToPasteboard(url.absoluteString) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func emptyPane(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: Theme.small) {
            Spacer()
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.Fonts.row)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(Theme.large)
        .frame(maxWidth: .infinity)
    }
}
