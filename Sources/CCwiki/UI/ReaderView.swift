import SwiftUI

/// The centre column: the rendered page, its metadata bar, and find-in-page.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session

    @State private var findText = ""
    @State private var findPresented = false
    /// What the bar says after a find: "3 of 17", "17 matches" or "No
    /// matches". Nil before one, and once the text changes or the page is
    /// drawn again.
    @State private var findStatus: String?

    var body: some View {
        Group {
            if model.index == nil, !session.location.isDocument {
                emptyState
            } else {
                WebPane(controller: session.webController)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.index != nil || session.location.isDocument { titleBar }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if findPresented { findBar }
        }
        .navigationTitle(documentTitle)
        .navigationSubtitle(subtitle)
        .focusedSceneValue(\.findAction, FindAction(
            perform: { findPresented = true },
            next: {
                findPresented = true
                Task { await find(backwards: false) }
            },
            previous: {
                findPresented = true
                Task { await find(backwards: true) }
            }))
    }

    // MARK: Title bar

    /// A quiet document-info strip: where this page sits, what state it is in,
    /// when it last changed, and — for a reference — who wrote it and where it
    /// appeared.
    ///
    /// Deliberately does *not* repeat the page title: the window title bar
    /// already carries it, and printing it twice a centimetre apart is the
    /// kind of chrome that makes an app feel like a web page in a frame.
    private var titleBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.small) {
                if let page = session.currentPage {
                    KindIcon(kind: page.kind)
                    Text(page.directory.isEmpty ? "Wiki" : page.directory)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                    StatusBadge(status: page.status)
                } else if case .folder(let slug) = session.location {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(slug)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                } else if case .document = session.location {
                    Image(systemName: "book.pages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("CCwiki")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Theme.small)

                // On a listing, the one control worth having to hand. Half the
                // Primitives are stubs, so this is the difference between a
                // page of things to read and a page of things to write.
                if case .folder = session.location {
                    Toggle("Hide stubs", isOn: Binding(
                        get: { model.hidesStubs },
                        set: { model.hidesStubs = $0 }))
                        .toggleStyle(.checkbox)
                        .font(Theme.Fonts.meta)
                        .help("Also applies to the sidebar. Change it in Settings (⌘,) too.")
                }

                if let page = session.currentPage, let modified = model.modifiedDates[page.path] {
                    Text(modified, format: .relative(presentation: .named))
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                        .help("Last change in git")
                }
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, 6)

            if let page = session.currentPage, page.kind == .reference {
                referenceBar(page)
            }
            Divider()
        }
        .background(.bar)
    }

    private func referenceBar(_ page: WikiPage) -> some View {
        HStack(spacing: Theme.small) {
            if let authors = page.authors {
                Text(authors)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(authors)
            }
            if let venue = page.venue {
                Text("·").foregroundStyle(.tertiary)
                Text(venue).font(Theme.Fonts.meta).foregroundStyle(.secondary)
            }
            if let published = page.publishedDisplay {
                Text("·").foregroundStyle(.tertiary)
                Text(published).font(Theme.Fonts.meta).foregroundStyle(.secondary).monospacedDigit()
            }

            Spacer(minLength: Theme.small)

            if let source = page.source, let url = URL(string: source) {
                Link(destination: url) {
                    Label(sourceLabel(for: source), systemImage: "arrow.up.forward.square")
                        .font(Theme.Fonts.meta)
                }
                .buttonStyle(.link)
            }
            ShowPaperButton(page: page)
            if let key = page.frontmatter.string("cryptobib_key") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                } label: {
                    Label(key, systemImage: "doc.on.clipboard")
                        .font(Theme.Fonts.meta)
                }
                .buttonStyle(.link)
                .help("Copy the CryptoBib key")
            } else if let bibtex = page.frontmatter.raw("bibtex") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bibtex, forType: .string)
                } label: {
                    Label("BibTeX", systemImage: "doc.on.clipboard")
                        .font(Theme.Fonts.meta)
                }
                .buttonStyle(.link)
                .help("Copy the inline BibTeX entry")
            }
        }
        .padding(.horizontal, Theme.large)
        .padding(.bottom, Theme.small)
    }

    private func sourceLabel(for source: String) -> String {
        if source.contains("eprint.iacr.org") { return "ePrint" }
        if source.contains("arxiv.org") { return "arXiv" }
        if source.contains("doi.org") { return "DOI" }
        return "Source"
    }

    private var documentTitle: String {
        if let page = session.currentPage { return page.displayTitle }
        if case .folder(let slug) = session.location { return slug }
        if case .document(let document) = session.location { return document.title }
        return "CCwiki"
    }

    /// A reference's frontmatter `title` is its citation key, which is exactly
    /// the identifier you want in the window title bar next to the paper name.
    /// Other pages have nothing worth a subtitle — the info strip carries the
    /// folder.
    private var subtitle: String {
        guard let page = session.currentPage, page.kind == .reference else { return "" }
        return page.title
    }

    // MARK: Find bar

    /// SwiftUI's `.findNavigator` is macOS 26, so this is hand-built over
    /// `WKWebView.find`, which has existed since macOS 11. `WKFindResult` only
    /// reports whether anything matched, so the page counts the matches in
    /// JavaScript (`FindCount`) for the bar's "3 of 17".
    private var findBar: some View {
        HStack(spacing: Theme.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { Task { await find(backwards: false) } }
                .onChange(of: findText) { _, _ in findStatus = nil }
                // The count was of the page as it was drawn. Another page,
                // or this one drawn again after a pull, makes it stale.
                .onChange(of: session.webController.renderGeneration) { _, _ in
                    findStatus = nil
                }

            // Monospaced digits, so the count does not jitter as it steps:
            // "3 of 17" and "4 of 17" are the same width. Never compressed
            // (SWIFTUI-RULES §2.2): cut to "12 of 1…" it reads as the wrong
            // number, so the field gives way first.
            if let findStatus {
                Text(findStatus)
                    .font(Theme.Fonts.meta)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Button { Task { await find(backwards: true) } } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous match (⇧⌘G)")

            Button { Task { await find(backwards: false) } } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next match (⌘G)")

            Button("Done") { dismissFind() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.large)
        .frame(height: Theme.findBarHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Finds the next match, or the previous, then counts them. The count
    /// reads the selection the find left, so it waits for the find.
    private func find(backwards: Bool) async {
        guard !findText.isEmpty else { return }
        let needle = findText
        let drawn = session.webController.renderGeneration
        let found = await session.webController.find(needle, backwards: backwards)
        var count: FindCount?
        if found { count = await session.webController.findCount(needle) }
        // Typed over while the page answered: the new text's find says.
        // Drawn again since, by a link or a pull: the count is of text that
        // has gone. A render after the count clears it (above).
        guard needle == findText, drawn == session.webController.renderGeneration else { return }
        findStatus = FindCount.label(found: found, count: count)
    }

    private func dismissFind() {
        findPresented = false
        findText = ""
        findStatus = nil
    }

    // MARK: Empty state

    /// Reading needs nothing installed: without git the wiki arrives as a
    /// tarball snapshot (`SnapshotService`). So the only empty state is
    /// "not downloaded yet", whatever the machine has on it.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("CCwiki", systemImage: "building.columns")
        } description: {
            Text("An offline reader for cryptology.city.\n"
                + "Download the wiki once — after that, reading needs no network.")
        } actions: {
            Button {
                model.sync()
            } label: {
                if model.syncState.isRunning {
                    Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Sync Now", systemImage: "arrow.down.circle")
                }
            }
            .disabled(model.syncState.isRunning)
        }
    }
}

/// A focused-value hook so ⌘F in the menu bar can reach the reader's find bar
/// without the command needing a reference to the view.
struct FindAction: Equatable {
    let perform: () -> Void
    /// Find Next / Find Previous (⌘G / ⇧⌘G). Only the reader offers them.
    let next: (() -> Void)?
    let previous: (() -> Void)?
    private let id = UUID()

    init(
        perform: @escaping () -> Void,
        next: (() -> Void)? = nil,
        previous: (() -> Void)? = nil
    ) {
        self.perform = perform
        self.next = next
        self.previous = previous
    }

    static func == (lhs: FindAction, rhs: FindAction) -> Bool { lhs.id == rhs.id }
}

// `@Entry` on a FocusedValues property is macOS 15; this is the macOS 14 form.
private struct FindActionKey: FocusedValueKey {
    typealias Value = FindAction
}

extension FocusedValues {
    var findAction: FindAction? {
        get { self[FindActionKey.self] }
        set { self[FindActionKey.self] = newValue }
    }
}
