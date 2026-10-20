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
    /// The outline, backlinks and relations are this window's page's.
    @Environment(ReaderSession.self) private var session

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            // Titles without icons. Two segments fitted comfortably with both;
            // three do not, and a truncated word is worse than no glyph — the
            // names are the affordance here, and macOS segmented controls are
            // routinely text-only.
            Picker("Inspector", selection: $session.inspectorTab) {
                ForEach(AppModel.InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.small)

            Divider()

            switch session.inspectorTab {
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
            let headings = session.webController.outline
            if headings.isEmpty {
                emptyPane("No Headings", systemImage: "list.bullet.indent",
                          detail: "This page has no section headings.")
            } else {
                let path = session.location.path
                let active = session.webController.activeHeadingID
                List {
                    ForEach(headings) { heading in
                        OutlineRow(path: path, heading: heading, isActive: heading.id == active)
                            .equatable()
                            // A list trait: inside the EquatableView it never
                            // reaches the row.
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Backlinks

    private var backlinks: some View {
        Group {
            let links = session.currentBacklinks
            if links.isEmpty {
                emptyPane("No Backlinks", systemImage: "arrow.turn.up.left",
                          detail: "No other page links here yet.")
            } else {
                let groups = WikiIndex.BacklinkGroup.grouping(links) {
                    model.index?.pages[$0]?.kind
                }
                let present = Set(groups.keys)
                List {
                    ForEach(WikiIndex.BacklinkGroup.allCases, id: \.self) { group in
                        if let rows = groups[group] {
                            backlinkSection(group, rows: rows, among: present)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// One group, under a header that opens and closes it: a button with a
    /// turning chevron and the group's count, as the Relations tab's derived
    /// sections have, with no `withAnimation` (SWIFTUI-RULES §1.2).
    ///
    /// The prose that mentions the page starts open. Reductions and
    /// barriers, which an object's Relations tab lists, and references wait
    /// for a click, except that on a page no prose mentions the first of
    /// them opens. What the reader opens and closes, the window's session
    /// keeps.
    private func backlinkSection(
        _ group: WikiIndex.BacklinkGroup, rows: [WikiIndex.Backlink],
        among present: Set<WikiIndex.BacklinkGroup>
    ) -> some View {
        let isOpen = session.isBacklinkGroupOpen(group, among: present)
        let state: String = isOpen ? "expanded" : "collapsed"
        return Section {
            if isOpen {
                ForEach(rows) { link in
                    BacklinkRow(link: link)
                        .equatable()
                        // A list trait: inside the EquatableView it never
                        // reaches the row.
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            Button {
                session.toggleBacklinkGroup(group, among: present)
            } label: {
                HStack(spacing: Theme.tight) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(group.title)
                        .font(Theme.Fonts.sectionHeader)
                        .lineLimit(1)
                    Spacer(minLength: Theme.small)
                    Text("\(rows.count)")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title), \(rows.count)")
            .accessibilityValue(state)
            .accessibilityAddTraits(.isHeader)
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

/// One heading of the outline. A click scrolls the page to it; its menu
/// opens its section in a new tab or window, and copies a link to it, a
/// wikilink and a CCwiki link, as the page's own menu does
/// (plans/efficiency.md §3.2).
///
/// A view of its own, compared by its page, its heading and whether it is
/// the one being read, so its menu's links, which parse and resolve a
/// wikilink, are worked out when the row changes rather than on every
/// scroll that moves the highlight (SWIFTUI-RULES §6.3).
private struct OutlineRow: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session
    /// The page the outline is of; nil on the app's own pages, whose
    /// sections have no links.
    let path: String?
    let heading: WikiPage.Heading
    let isActive: Bool

    nonisolated static func == (lhs: OutlineRow, rhs: OutlineRow) -> Bool {
        lhs.path == rhs.path && lhs.heading == rhs.heading && lhs.isActive == rhs.isActive
    }

    var body: some View {
        Button {
            session.webController.scrollTo(anchor: heading.id)
        } label: {
            Text(heading.text)
                .font(Self.headingFont(heading.level))
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Indent by level so the shape of the document
                // is legible at a glance.
                .padding(.leading, CGFloat(max(0, heading.level - 1)) * Theme.medium)
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
    }

    /// New Tab and New Window open at the section, as a link to it would;
    /// then its links (plans/efficiency.md §3.2).
    @ViewBuilder
    private var menu: some View {
        if let path {
            OpenElsewhereItems { session.open(.page(path: path, anchor: heading.id), $0) }
            if let links = session.sectionLinks(path: path, id: heading.id, text: heading.text) {
                Divider()
                ForEach(links.copyItems, id: \.title) { item in
                    Button(item.title) { model.copyToPasteboard(item.text) }
                }
            }
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: Theme.Fonts.row.weight(.semibold)
        case 2: Theme.Fonts.row
        default: Theme.Fonts.rowSubtitle
        }
    }
}

/// One page that links to the page being read, and the lines that mention
/// it.
///
/// The first line that mentions the page shows under the title, as it
/// always has. A page that mentions it on several lines adds "N mentions",
/// a disclosure that lists each line; while it is open, the list holds the
/// first line, and the title stands alone (plans/efficiency.md §3.1). The
/// title opens the page at its first mention, and a listed line at that
/// line: scrolled to the block holding it, and outlined for a moment.
///
/// A view of its own, compared by its backlink, so the lines are reduced to
/// plain text (`Backlink.context`) when the backlink changes rather than on
/// every redraw of the pane (SWIFTUI-RULES §6.3).
private struct BacklinkRow: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session
    let link: WikiIndex.Backlink
    /// Whether a page that mentions this one on several lines lists them.
    @State private var listsMentions = false

    nonisolated static func == (lhs: BacklinkRow, rhs: BacklinkRow) -> Bool {
        lhs.link == rhs.link
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A button, so ⌘-click is a link's: a tab behind this one
            // (reader-comforts §1.1).
            Button {
                openMention(0, LinkDisposition.current)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title(forPath: link.sourcePath))
                        .font(Theme.Fonts.row)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The line that mentions this page — *why* it links
                    // here, which is the useful half. The first, until the
                    // list of every line takes its place.
                    if link.mentions.count == 1 || !listsMentions {
                        mentionLine(link.context)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu { menu(mention: 0) }

            if link.mentions.count > 1 {
                mentions
            }
        }
    }

    /// "N mentions", and each line under it while it is open.
    @ViewBuilder
    private var mentions: some View {
        let count = link.mentions.count
        let state: String = listsMentions ? "expanded" : "collapsed"
        let tooltip: String = listsMentions
            ? "Hide the lines that mention this page" : "Show each line that mentions this page"
        Button {
            listsMentions.toggle()
        } label: {
            HStack(spacing: Theme.tight) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(listsMentions ? 90 : 0))
                Text("\(count) mentions")
                    .font(Theme.Fonts.meta)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("\(count) mentions")
        .accessibilityValue(state)

        if listsMentions {
            ForEach(link.mentions.indices, id: \.self) { ordinal in
                Button {
                    openMention(ordinal, LinkDisposition.current)
                } label: {
                    mentionLine(WikiIndex.plainText(String(link.mentions[ordinal])))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, Theme.medium)
                .contextMenu { menu(mention: ordinal) }
            }
        }
    }

    private func mentionLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.rowSubtitle)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
    }

    /// New Tab and New Window land on the mention too.
    @ViewBuilder
    private func menu(mention ordinal: Int) -> some View {
        OpenElsewhereItems { openMention(ordinal, $0) }
        if let page = model.index?.pages[link.sourcePath],
           let url = AppModel.siteURL(slug: page.slug) {
            Divider()
            Button("Open on cryptology.city") { NSWorkspace.shared.open(url) }
            Button("Copy Link") { model.copyToPasteboard(url.absoluteString) }
        }
    }

    private func openMention(_ ordinal: Int, _ disposition: LinkDisposition) {
        session.openMention(ordinal, of: link.sourcePath, disposition)
    }
}
