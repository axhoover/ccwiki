import SwiftUI

/// The centre column: the rendered page, its metadata bar, and find-in-page.
struct ReaderView: View {
    @Environment(AppModel.self) private var model

    @State private var findText = ""
    @State private var findPresented = false
    @State private var findFailed = false

    var body: some View {
        Group {
            if model.index == nil, !model.location.isDocument {
                emptyState
            } else {
                WebPane(controller: model.webController)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.index != nil || model.location.isDocument { titleBar }
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
                if let page = model.currentPage {
                    KindIcon(kind: page.kind)
                    Text(page.directory.isEmpty ? "Wiki" : page.directory)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                    StatusBadge(status: page.status)
                } else if case .folder(let slug) = model.location {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(slug)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                } else if case .document = model.location {
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
                if case .folder = model.location {
                    Toggle("Hide stubs", isOn: Binding(
                        get: { model.hidesStubs },
                        set: { model.hidesStubs = $0 }))
                        .toggleStyle(.checkbox)
                        .font(Theme.Fonts.meta)
                        .help("Also applies to the sidebar. Change it in Settings (⌘,) too.")
                }

                if let page = model.currentPage, let modified = model.modifiedDates[page.path] {
                    Text(modified, format: .relative(presentation: .named))
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                        .help("Last change in git")
                }
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, 6)

            if let page = model.currentPage, page.kind == .reference {
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
        if let page = model.currentPage { return page.displayTitle }
        if case .folder(let slug) = model.location { return slug }
        if case .document(let document) = model.location { return document.title }
        return "CCwiki"
    }

    /// A reference's frontmatter `title` is its citation key, which is exactly
    /// the identifier you want in the window title bar next to the paper name.
    /// Other pages have nothing worth a subtitle — the info strip carries the
    /// folder.
    private var subtitle: String {
        guard let page = model.currentPage, page.kind == .reference else { return "" }
        return page.title
    }

    // MARK: Find bar

    /// SwiftUI's `.findNavigator` is macOS 26, so this is hand-built over
    /// `WKWebView.find`, which has existed since macOS 11. `WKFindResult` only
    /// reports whether anything matched — there is no "3 of 17" to show
    /// without counting in JavaScript, so the bar says found / not found.
    private var findBar: some View {
        HStack(spacing: Theme.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { Task { await find(backwards: false) } }
                .onChange(of: findText) { _, _ in findFailed = false }

            if findFailed {
                Text("Not found")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
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

    private func find(backwards: Bool) async {
        guard !findText.isEmpty else { return }
        findFailed = !(await model.webController.find(findText, backwards: backwards))
    }

    private func dismissFind() {
        findPresented = false
        findText = ""
        findFailed = false
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
