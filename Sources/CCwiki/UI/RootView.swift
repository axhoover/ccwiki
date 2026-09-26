import SwiftUI
import UniformTypeIdentifiers

/// The window's root: sidebar → reader → inspector.
///
/// A three-column `NavigationSplitView` is the macOS document-browser idiom
/// (Mail, Notes, Xcode), and it gets the sidebar's vibrancy, the toolbar's
/// unified title bar, and column resizing without any of it being hand-built.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
        } detail: {
            ReaderView()
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                }
        }
        .toolbar { toolbar }
        .navigationTitle("CCwiki")
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .sheet(isPresented: $model.quickSwitcherPresented) {
            QuickSwitcherView()
        }
        .sheet(isPresented: $model.searchPresented) {
            SearchView()
        }
        .sheet(isPresented: $model.ingestSheetPresented) {
            IngestSheet()
        }
        .sheet(isPresented: $model.syncLogPresented) {
            SyncLogView()
        }
        // The whole reader is a drop target: when you have the paper open, the
        // natural gesture is to drag it onto the wiki, not to go looking for a
        // form.
        .onDrop(of: [.pdf, .fileURL], isTargeted: $isDropTargeted) { providers in
            acceptDroppedPDF(providers)
        }
        .overlay { if isDropTargeted { dropOverlay } }
        .task {
            // Find git (one stat), read what is already on disk, and only then
            // touch the network — so the app is usable instantly and offline.
            // The ingestion tools are looked for in the background.
            await model.discoverTools()
            await model.loadLibrary()
            // A launch fetch keeps the wiki current for someone who never
            // presses ⌘R. Not under the screenshot harness, whose captures
            // must not depend on the network.
            let launchFetch = model.syncsAtLaunch && ScreenshotRunner.directory == nil
            if model.index == nil || launchFetch { model.sync() }
            ScreenshotRunner.run(model: model)
        }
        .onChange(of: model.jobsWindowRequests) { _, _ in
            openWindow(id: CCwikiApp.jobsWindowID)
        }
        .onChange(of: model.settingsRequests) { _, _ in
            openSettings()
        }
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.searchAction, FindAction { model.searchPresented = true })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("Back (⌘[)")

            Button { model.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("Forward (⌘])")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.presentQuickSwitcher() } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Quick switcher (⌘O)")

            Button { model.searchPresented = true } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .help("Search all pages (⇧⌘F)")

            Button { model.sync() } label: {
                if model.syncState.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(model.syncState.isRunning)
            .help("Sync with GitHub (⌘R)")

            Button { model.showInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle inspector (⌥⌘I)")
        }
    }

    // MARK: Drop

    private var dropOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: Theme.small) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Ingest this paper")
                    .font(Theme.Fonts.emptyTitle)
                Text("CCwiki will run an agent in a worktree and open a draft PR.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .allowsHitTesting(false)
    }

    private func acceptDroppedPDF(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in
                guard let staged = try? model.stagePDF(from: url) else { return }
                model.pendingDroppedPDF = staged
                model.ingestSheetPresented = true
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
                        Button("Details…") { model.syncLogPresented = true }
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

                if let error = model.webController.lastRenderError {
                    Label(error, systemImage: "exclamationmark.bubble")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
