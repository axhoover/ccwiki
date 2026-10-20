import SwiftUI
import UniformTypeIdentifiers

/// The window's root: sidebar → reader → inspector.
///
/// A three-column `NavigationSplitView` is the macOS document-browser idiom
/// (Mail, Notes, Xcode), and it gets the sidebar's vibrancy, the toolbar's
/// unified title bar, and column resizing without any of it being hand-built.
///
/// What the window shows — its page, history, sidebar, inspector and sheets —
/// is its `ReaderSession`'s; what every window shares is the model's
/// (plans/reader-comforts.md §1.2). The window itself, which gives this view
/// its session and starts it, is `ReaderWindowView`'s.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var session = session

        NavigationSplitView {
            SidebarView()
        } detail: {
            ReaderView()
                .inspector(isPresented: $session.showInspector) {
                    InspectorView()
                }
        }
        .toolbar { toolbar }
        .navigationTitle("CCwiki")
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        .sheet(isPresented: $session.quickSwitcherPresented) {
            QuickSwitcherView()
        }
        .sheet(isPresented: $session.searchPresented) {
            SearchView()
        }
        .sheet(isPresented: $session.referenceSearchPresented) {
            ReferenceSearchView()
        }
        .sheet(isPresented: $session.grepPresented) {
            GrepView()
        }
        .sheet(isPresented: ingestSheetPresented) {
            IngestSheet()
        }
        .sheet(isPresented: $session.syncLogPresented) {
            SyncLogView()
        }
        // Describe a Correction and Open an Issue, about this window's page
        // (plans/corrections.md §8).
        .sheet(item: $session.correctionSheet) { request in
            switch request.kind {
            case .describe: CorrectionSheet(request: request)
            case .issue: IssueSheet(request: request)
            }
        }
        // The whole reader is a drop target: when you have the paper open, the
        // natural gesture is to drag it onto the wiki, not to go looking for a
        // form. Not while an ingest sheet is up, in any window: the sheet
        // takes its own drops, and one PDF is all it holds.
        .onDrop(
            of: model.ingestSheetTarget == nil ? Self.droppedTypes : [],
            isTargeted: $isDropTargeted
        ) { providers in
            acceptDroppedPDF(providers)
        }
        // Mounted permanently and faded, not inserted: a transition on a view
        // inserted inside a NavigationSplitView is SWIFTUI-RULES §1.1.
        .overlay {
            dropOverlay
                .opacity(isDropTargeted ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        }
        .onChange(of: model.jobsWindowRequests) { _, _ in
            openWindow(id: CCwikiApp.jobsWindowID)
        }
        // A URL from outside is the window's (`ReaderWindowView`), which
        // hands it to `ReaderSession.handleOpenURL`.
        .onChange(of: model.settingsRequests) { _, _ in
            openSettings()
        }
        // An editor asked for by AppKit or async code (corrections §7.2).
        // Every reader window hears it; the first to take the request opens
        // the editor, and the others find nil.
        .onChange(of: model.editorWindowRequestCount) { _, _ in
            if let target = model.takeEditorRequest() {
                openWindow(id: CCwikiApp.editorWindowID, value: target)
            }
        }
        .focusedSceneValue(\.searchAction, FindAction { session.searchPresented = true })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { session.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoBack)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")

            Button { session.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoForward)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.presentQuickSwitcher() } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Quick switcher (⌘O)")
            .accessibilityLabel("Quick Switcher")

            Button { session.searchPresented = true } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .help("Search the wiki (⌘S)")
            .accessibilityLabel("Search the Wiki")

            Button { session.referenceSearchPresented = true } label: {
                Image(systemName: "books.vertical")
            }
            .help("Search references (⇧⌘R)")
            .accessibilityLabel("Search References")

            Button { model.sync() } label: {
                if model.syncState.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(model.syncState.isRunning)
            .help("Sync with GitHub (⌘R)")
            .accessibilityLabel("Sync with GitHub")

            // Edit the page, describe a correction, or open an issue
            // (corrections §9), before the inspector toggle.
            Menu {
                Button("Edit Page…") { beginCorrection(.edit) }
                Button("Describe a Correction…") { beginCorrection(.describe) }
                Button("Open an Issue About This Page…") { beginCorrection(.issue) }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(!session.canCorrectCurrentPage)
            .help("Edit this page, describe a correction, or open an issue")
            .accessibilityLabel("Correct This Page")

            Button { session.showInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle inspector (⌥⌘I)")
            .accessibilityLabel("Toggle Inspector")
        }
    }

    /// From the toolbar, which carries whatever is selected on the page.
    private func beginCorrection(_ route: CorrectionRoute) {
        Task { await session.beginCorrection(route) }
    }

    // MARK: Ingest

    /// The ingest sheet is up on one window only, the one it was pinned to
    /// when it was asked for, so a click on another reader window never
    /// moves it, or its link, notes and PDF (§1.3).
    private var ingestSheetPresented: Binding<Bool> {
        Binding(
            get: { model.ingestSheetTarget == session.id },
            set: { if !$0 { model.dismissIngestSheet() } })
    }

    // MARK: Drop

    private static let droppedTypes: [UTType] = [.pdf, .fileURL]

    private var dropOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: Theme.small) {
                Image(systemName: "doc.badge.plus")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Ingest this paper")
                    .font(Theme.Fonts.emptyTitle)
                Text("CCwiki will run an agent in a worktree and show you its changes "
                    + "before opening a draft PR.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }

    private func acceptDroppedPDF(_ providers: [NSItemProvider]) -> Bool {
        guard model.ingestSheetTarget == nil, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in
                // Another window may have put a sheet up while the drop
                // loaded: that window comes forward, as for a PDF from
                // Finder (§1.3). The sheet up reads no PDF, so one left for
                // it would join the next ingestion instead.
                guard model.ingestSheetTarget == nil else {
                    model.requestIngestSheet(in: session.id)
                    return
                }
                guard let staged = try? model.stagePDF(from: url) else { return }
                model.pendingDroppedPDF = staged
                model.requestIngestSheet(in: session.id)
                openWindow(id: CCwikiApp.jobsWindowID)
            }
        }
        return true
    }
}

// MARK: - Focused values

private struct AppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

private struct SearchActionKey: FocusedValueKey {
    typealias Value = FindAction
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelKey.self] }
        set { self[AppModelKey.self] = newValue }
    }

    var searchAction: FindAction? {
        get { self[SearchActionKey.self] }
        set { self[SearchActionKey.self] = newValue }
    }
}
