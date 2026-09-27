import SwiftUI

/// The left column: the repo's directory tree, with a status badge per page.
///
/// A `List` over `OutlineGroup` rather than nested `DisclosureGroup`s, so the
/// tree gets the standard sidebar look — vibrancy, the system selection
/// highlight, and keyboard navigation — for free.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollViewReader { proxy in
            List(selection: $model.sidebarSelection) {
                if model.index != nil {
                    // Only when the tree has nothing to say about where you
                    // are — which is exactly when you are on a reference.
                    if !model.citingPages.isEmpty {
                        Section("Cited by") {
                            ForEach(model.citingPages) { backlink in
                                citingRow(backlink)
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
            .onChange(of: model.sidebarSelection) { _, selection in
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
        .onChange(of: model.sidebarSelection) { _, newValue in
            guard let path = newValue, path.hasSuffix(".md") else { return }
            model.openPage(path)
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

    /// A page that cites the reference being read. Not part of the selection
    /// binding — the tree owns selection, and these rows are a way back rather
    /// than a place in the hierarchy.
    private func citingRow(_ backlink: WikiIndex.Backlink) -> some View {
        Button {
            model.openPage(backlink.sourcePath)
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
        .selectionDisabled()
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
    /// long sorted list belongs; ⌘O and ⇧⌘F reach any single page faster than
    /// scrolling ever would.
    private func collapsedFolderRow(
        _ name: String, systemImage: String, count: Int, help: String
    ) -> some View {
        Button {
            model.open(.folder(slug: name))
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
                .onTapGesture(count: 2) { model.open(.folder(slug: node.id)) }
                .contextMenu {
                    Button("Open Folder Page") { model.open(.folder(slug: node.id)) }
                }
            }
        } else {
            pageRow(node)
        }
    }

    private func expansion(of folder: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedFolders.contains(folder) },
            set: { isExpanded in
                if isExpanded { model.expandedFolders.insert(folder) }
                else { model.expandedFolders.remove(folder) }
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
        .contextMenu {
            if let page = node.page {
                if let url = AppModel.siteURL(slug: page.slug) {
                    Button("Open on cryptology.city") { NSWorkspace.shared.open(url) }
                    Button("Copy Link") { model.copyToPasteboard(url.absoluteString) }
                }
                Button("Copy Wikilink") {
                    let link = page.kind == .reference
                        ? "[[\(page.stem)|\(page.title)]]"
                        : "[[\(page.slug.components(separatedBy: "/").last ?? page.stem)]]"
                    model.copyToPasteboard(link)
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [model.paths.content.appending(path: page.path)])
                }
            }
        }
    }
}
