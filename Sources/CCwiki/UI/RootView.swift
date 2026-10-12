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
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
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
        // Two kinds of URL reach the app from outside: a PDF handed to it by
        // Finder or the Dock (Info.plist declares the type), and a
        // ccwiki:// link from anywhere (Info.plist declares the scheme;
        // CCwiki Dev's is ccwiki-dev://, read here as ccwiki://).
        .onOpenURL { url in
            if url.isFileURL {
                guard url.pathExtension.lowercased() == "pdf",
                      let staged = try? model.stagePDF(from: url)
                else { return }
                model.pendingDroppedPDF = staged
                model.requestIngestSheet(in: session.id)
                openWindow(id: CCwikiApp.jobsWindowID)
            } else if let destination = CCwikiURL.destination(
                of: CCwikiURL.internalString(for: url)) {
                session.navigate(to: destination)
            }
        }
        .onChange(of: model.settingsRequests) { _, _ in
            openSettings()
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

            Button { session.showInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle inspector (⌥⌘I)")
            .accessibilityLabel("Toggle Inspector")
        }
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
                Text("CCwiki will run an agent in a worktree and open a draft PR.")
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
                guard let staged = try? model.stagePDF(from: url) else { return }
                model.pendingDroppedPDF = staged
                model.requestIngestSheet(in: session.id)
                openWindow(id: CCwikiApp.jobsWindowID)
            }
        }
        return true
    }

    // MARK: Status bar

    /// The quiet strip macOS apps keep at the bottom: what just happened, and
    /// anything that needs attention but must not interrupt reading.
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.small) {
                switch model.syncState {
                case .running(let message):
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .failed(let message):
                    Image(systemName: model.syncState.isOffline
                        ? "wifi.slash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.syncState.isOffline
                            ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !model.syncLog.isEmpty {
                        Button("Details…") { session.syncLogPresented = true }
                            .buttonStyle(.link)
                            .font(Theme.Fonts.meta)
                            .fixedSize()
                    }
                case .succeeded(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .idle:
                    // The resting state says how current the wiki is, which
                    // a reader can act on; the hash is in the tooltip.
                    if let date = model.headDate {
                        Image(systemName: "clock")
                            .foregroundStyle(.tertiary)
                        (Text("Wiki as of ") + Text(date, format: .relative(presentation: .named)))
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help(model.headRevision.map { "Commit \($0.prefix(12))" } ?? "")
                    } else if let revision = model.headRevision {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .foregroundStyle(.tertiary)
                        Text(revision.prefix(7))
                            .font(Theme.Fonts.log)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: Theme.small)

                if let error = session.webController.lastRenderError {
                    Label(error, systemImage: "exclamationmark.bubble")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let progress = model.updateInstallProgress {
                    HStack(spacing: Theme.tight) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text(progress)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if model.activeJobCount > 0 {
                    Button {
                        openWindow(id: CCwikiApp.jobsWindowID)
                    } label: {
                        HStack(spacing: Theme.tight) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("\(model.activeJobCount) job\(model.activeJobCount == 1 ? "" : "s")")
                                .font(Theme.Fonts.meta)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Show the jobs window (⇧⌘J)")
                }
                if !model.warnings.isEmpty {
                    // Warnings are unique (`AppModel.warn`), so the text is a
                    // stable identity — and a row, once read, can be put away.
                    Menu {
                        ForEach(model.warnings, id: \.self) { warning in
                            Button(warning) { model.dismissWarning(warning) }
                        }
                        Divider()
                        Button("Dismiss All") { model.dismissAllWarnings() }
                    } label: {
                        Label("\(model.warnings.count)", systemImage: "exclamationmark.triangle")
                            .font(Theme.Fonts.meta)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.orange)
                    .help("Choose a warning to dismiss it")
                }
            }
            .padding(.horizontal, Theme.medium)
            .padding(.vertical, 5)
            .frame(height: 26)
            .background(.bar)
        }
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
