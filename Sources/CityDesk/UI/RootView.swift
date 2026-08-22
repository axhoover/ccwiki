import SwiftUI

/// The window's root: sidebar → reader → inspector.
///
/// A three-column `NavigationSplitView` is the macOS document-browser idiom
/// (Mail, Notes, Xcode), and it gets the sidebar's vibrancy, the toolbar's
/// unified title bar, and column resizing without any of it being hand-built.
struct RootView: View {
    @Environment(AppModel.self) private var model

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
        .navigationTitle("CityDesk")
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .sheet(isPresented: $model.quickSwitcherPresented) {
            QuickSwitcherView()
        }
        .sheet(isPresented: $model.searchPresented) {
            SearchView()
        }
        .task {
            // Read what is already on disk before touching the network, so the
            // app is usable instantly and offline.
            await model.loadLibrary()
            if model.index == nil { model.sync() }
            ScreenshotRunner.run(model: model)
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
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .succeeded(let message):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                case .idle:
                    if let revision = model.headRevision {
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
                if !model.warnings.isEmpty {
                    Menu {
                        ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning)
                        }
                    } label: {
                        Label("\(model.warnings.count)", systemImage: "exclamationmark.triangle")
                            .font(Theme.Fonts.meta)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.orange)
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
