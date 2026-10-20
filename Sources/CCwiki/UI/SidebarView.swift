import SwiftUI

/// The left column: the repo's directory tree, with a status badge per page.
///
/// A `List` over `OutlineGroup` rather than nested `DisclosureGroup`s, so the
/// tree gets the standard sidebar look — vibrancy, the system selection
/// highlight, and keyboard navigation — for free.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The selection and the open folders are this window's; the tree and
    /// its counts are every window's.
    @Environment(ReaderSession.self) private var session
    /// Whether this window's Saved section is open.
    @State private var showsSaved = true

    var body: some View {
        @Bindable var session = session

        ScrollViewReader { proxy in
            List(selection: $session.sidebarSelection) {
                if model.index != nil {
                    // The pages the reader saved, in the order they gave
                    // them, the same in every window (plans/efficiency.md
                    // §3.3). Hidden when there are none. Out of the tree's
                    // selection: their ids are not paths, and the rows are
                    // selection-disabled.
                    if !model.savedPages.isEmpty {
                        Section("Saved", isExpanded: $showsSaved) {
                            ForEach(model.savedPages.entries) { entry in
                                SavedRow(entry: entry, page: model.index?.pages[entry.path])
                                    .selectionDisabled()
                            }
                            .onMove { model.moveSaved(fromOffsets: $0, toOffset: $1) }
                        }
                        .listSectionSeparator(.hidden)
                    }

                    // Only when the tree has nothing to say about where you
                    // are — which is exactly when you are on a reference.
                    if !session.citingPages.isEmpty {
                        Section("Cited by") {
                            ForEach(session.citingPages) { backlink in
                                CitingRow(backlink: backlink)
                                    .equatable()
                                    // A list trait: inside the EquatableView
                                    // it never reaches the row.
                                    .selectionDisabled()
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }

                    Section("Wiki") {
                        ForEach(model.pageTree) { node in
                            nodeView(node)
                        }
                        collapsedFolderRow(
                            "Reductions",
                            systemImage: "arrow.right",
                            count: model.reductionCount,
                            help: "Browse all \(model.reductionCount) reduction pages")
                        collapsedFolderRow(
                            "References",
                            systemImage: "text.book.closed",
                            count: model.referenceCount,
                            help: "Browse all \(model.referenceCount) reference pages")
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            // Opening a page from a link or the quick switcher expands its
            // folder; without this the row it just revealed is usually below
            // the fold, and the sidebar looks like it disagrees with the reader.
            .onChange(of: session.sidebarSelection) { _, selection in
                guard let selection else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: Theme.sidebarMinWidth,
            ideal: Theme.sidebarIdealWidth,
            max: Theme.sidebarMaxWidth)
        .onChange(of: session.sidebarSelection) { _, newValue in
            guard let path = newValue, path.hasSuffix(".md") else { return }
            session.openPage(path)
        }
        .overlay {
            if model.index == nil {
                ContentUnavailableView {
                    Label("No Wiki Yet", systemImage: "arrow.down.circle")
                } description: {
                    Text("CCwiki keeps a local copy of cryptology.city. Sync to fetch it.")
                } actions: {
                    Button("Sync Now") { model.sync() }
                        .disabled(model.syncState.isRunning)
                }
                .padding(Theme.medium)
            }
        }
    }

    /// A folder that is too big to be a branch of the tree, as one row.
    ///
    /// Two of them now. References (200 pages) for the reason in
    /// `plans/design-system.md` §3a, and Reductions (343) for that reason and a
    /// sharper one: a reduction page is not somewhere you browse *to*. You
    /// arrive at one from the relation it states, on an endpoint's page — which
    /// is what the Relations inspector is for. Putting 343 of them in the tree
    /// would bury the 93 concept pages the wiki is actually about.
    ///
    /// Opening the row shows the folder listing in the reading pane, where a
    /// long sorted list belongs; ⌘O and ⌘S reach any single page faster than
    /// scrolling ever would.
    private func collapsedFolderRow(
        _ name: String, systemImage: String, count: Int, help: String
    ) -> some View {
        let location = AppModel.Location.folder(slug: name)
        return Button {
            session.open(location, LinkDisposition.current)
        } label: {
            HStack(spacing: Theme.small) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(name)
                    .font(Theme.Fonts.row)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.tight)
                Text("\(count)")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .help(help)
        .contextMenu {
            OpenElsewhereItems { session.open(location, $0) }
        }
    }

    @ViewBuilder
    private func nodeView(_ node: PageTreeNode) -> some View {
        if node.isFolder {
            // Bound expansion, not `DisclosureGroup`'s own state: opening a
            // page from a link, the quick switcher or search has to be able to
            // reveal the folder it lives in.
            DisclosureGroup(isExpanded: expansion(of: node.id)) {
                ForEach(node.children) { child in
                    pageRow(child)
                }
            } label: {
                HStack(spacing: Theme.small) {
                    Text(node.name)
                        .font(Theme.Fonts.row)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.tight)
                    Text("\(node.pageCount)")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .contentShape(.rect)
                .onTapGesture(count: 2) { session.open(.folder(slug: node.id)) }
                .contextMenu {
                    Button("Open Folder Page") { session.open(.folder(slug: node.id)) }
                    OpenElsewhereItems(title: "Open Folder Page") {
                        session.open(.folder(slug: node.id), $0)
                    }
                }
                // Double-click and the context menu are both invisible to
                // VoiceOver; a named action is not.
                .accessibilityAction(named: "Open Folder Page") {
                    session.open(.folder(slug: node.id))
                }
                .help("Double-click to see every page in \(node.name)")
            }
        } else {
            pageRow(node)
        }
    }

    private func expansion(of folder: String) -> Binding<Bool> {
        Binding(
            get: { session.expandedFolders.contains(folder) },
            set: { isExpanded in
                if isExpanded { session.expandedFolders.insert(folder) }
                else { session.expandedFolders.remove(folder) }
            })
    }

    private func pageRow(_ node: PageTreeNode) -> some View {
        HStack(spacing: Theme.small) {
            if let page = node.page {
                StatusBadge(status: page.status, compact: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title)
                        .font(Theme.Fonts.row)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // A reference's title is a citation key, which tells you
                    // nothing on its own — show the paper it stands for.
                    if page.kind == .reference {
                        Text(page.displayTitle)
                            .font(Theme.Fonts.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .tag(node.id)
        // Selection, not a button, so ⌘-click keeps `List`'s own meaning, as
        // in Finder's and Mail's sidebars; a new tab is in the menu
        // (reader-comforts §1.1).
        .contextMenu {
            if let page = node.page {
                OpenElsewhereItems { session.open(.page(path: page.path, anchor: nil), $0) }
                Divider()
                if let url = AppModel.siteURL(slug: page.slug) {
                    Button("Open on cryptology.city") { NSWorkspace.shared.open(url) }
                    Button("Copy Link") { model.copyToPasteboard(url.absoluteString) }
                }
                Button("Copy Wikilink") { model.copyToPasteboard(page.wikilink) }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [model.paths.content.appending(path: page.path)])
                }
            }
        }
    }
}

/// A page that cites the reference being read. Not part of the selection
/// binding — the tree owns selection, and these rows are a way back rather
/// than a place in the hierarchy. A button, so ⌘-click is a link's: a tab
/// behind this one (reader-comforts §1.1). The sidebar applies
/// `.selectionDisabled()` outside `.equatable()`: list traits do not pass
/// through an `EquatableView`.
///
/// Equatable on its backlink, and drawn `.equatable()`, so its tooltip, the
/// citing line as plain text, is worked out when the row changes rather
/// than each time the sidebar is drawn: on every navigation, and every
/// change to the tree or its selection.
private struct CitingRow: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session
    let backlink: WikiIndex.Backlink

    nonisolated static func == (lhs: CitingRow, rhs: CitingRow) -> Bool {
        lhs.backlink == rhs.backlink
    }

    var body: some View {
        let location = AppModel.Location.page(path: backlink.sourcePath, anchor: nil)
        Button {
            session.open(location, LinkDisposition.current)
        } label: {
            HStack(spacing: Theme.small) {
                Image(systemName: "arrow.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(model.title(forPath: backlink.sourcePath))
                    .font(Theme.Fonts.row)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(backlink.context)
        .contextMenu {
            OpenElsewhereItems { session.open(location, $0) }
        }
    }
}

/// A saved page (plans/efficiency.md §3.3). A button, as a Cited by row is:
/// out of the tree's selection, and ⌘-click is a link's. The sidebar applies
/// `.selectionDisabled()`.
///
/// A page the wiki no longer has, and that reconciliation could not find by
/// its title, stays where the reader put it, dimmed, and a click searches
/// the wiki for its title.
private struct SavedRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session
    let entry: SavedPages.Entry
    /// Nil when the wiki no longer has the page.
    let page: WikiPage?

    var body: some View {
        let location = AppModel.Location.page(path: entry.path, anchor: entry.anchor)
        Button {
            if page == nil {
                searchForTitle()
            } else {
                session.open(location, LinkDisposition.current)
            }
        } label: {
            // Dimmed by colour, never by weight, when the page is gone.
            HStack(spacing: Theme.small) {
                Image(systemName: page == nil ? "bookmark.slash" : "bookmark")
                    .font(.caption)
                    .foregroundStyle(page == nil
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title)
                        .font(Theme.Fonts.row)
                        .foregroundStyle(page == nil
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Fonts.rowSubtitle)
                            .foregroundStyle(page == nil
                                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .contextMenu {
            if page == nil {
                Button("Search the Wiki for “\(entry.title)”") { searchForTitle() }
            } else {
                OpenElsewhereItems { session.open(location, $0) }
            }
            Divider()
            Button("Remove from Saved") { model.removeSaved(entry) }
        }
        // The context menu is invisible to VoiceOver; a named action is not.
        .accessibilityAction(named: "Remove from Saved") { model.removeSaved(entry) }
    }

    /// The second line: the paper a reference's key stands for, as in the
    /// tree, or why the row is dimmed.
    private var subtitle: String? {
        guard let page else { return "No longer in the wiki" }
        return page.kind == .reference ? page.displayTitle : nil
    }

    private var tooltip: Text {
        guard page != nil else {
            return Text("No longer in the wiki. Click to search for “\(entry.title)”.")
        }
        return Text("Saved \(entry.savedAt, format: .dateTime.day().month().year())")
    }

    /// ⌘S, opened on the page's title.
    private func searchForTitle() {
        model.searchQuery = entry.title
        session.searchPresented = true
    }
}
