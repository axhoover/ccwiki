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
                if let index = model.index {
                    Section("Wiki") {
                        ForEach(model.pageTree()) { node in
                            nodeView(node)
                        }
                    }
                    .listSectionSeparator(.hidden)

                    Section {
                        Label("\(index.pages.count) pages", systemImage: "doc.on.doc")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
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
                    Text("CityDesk keeps a local copy of cryptology.city. Sync to fetch it.")
                } actions: {
                    Button("Sync Now") { model.sync() }
                        .disabled(model.syncState.isRunning)
                }
                .padding(Theme.medium)
            }
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
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [model.paths.content.appending(path: page.path)])
                }
                Button("Copy Wikilink") {
                    let link = page.kind == .reference
                        ? "[[\(page.stem)|\(page.title)]]"
                        : "[[\(page.slug.components(separatedBy: "/").last ?? page.stem)]]"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
        }
    }
}
