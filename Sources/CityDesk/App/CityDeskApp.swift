import SwiftUI

/// App entry point. Owns the single `AppModel` and hands it to the view tree
/// through the environment.
@main
struct CityDeskApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(
                    minWidth: Theme.windowMinWidth,
                    minHeight: Theme.windowMinHeight)
        }
        .defaultSize(
            width: Theme.windowDefaultWidth,
            height: Theme.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands { CityDeskCommands() }
    }
}

/// Menu-bar commands.
///
/// Every primary action gets a shortcut and every shortcut appears in a menu,
/// so it is discoverable rather than folklore. The actions reach the focused
/// scene through `@FocusedValue` rather than through a shared singleton.
struct CityDeskCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.findAction) private var findAction
    @FocusedValue(\.searchAction) private var searchAction

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Toggle Inspector") { model?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.option, .command])
                .disabled(model == nil)

            Divider()

            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model?.canGoBack != true)

            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model?.canGoForward != true)
        }

        CommandGroup(replacing: .newItem) {
            Button("Quick Switcher…") { model?.presentQuickSwitcher() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find on Page…") { findAction?.perform() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(findAction == nil)

            Button("Search All Pages…") { searchAction?.perform() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(searchAction == nil)
        }

        CommandMenu("Wiki") {
            Button("Sync with GitHub") { model?.sync() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.syncState.isRunning ?? true)

            Button("Go Home") { model?.openHome() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model == nil)

            Divider()

            Button("Reveal Page in Finder") {
                guard let model, let page = model.currentPage else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [model.paths.content.appending(path: page.path)])
            }
            .disabled(model?.currentPage == nil)

            Button("Reveal Clone in Finder") {
                guard let model else { return }
                NSWorkspace.shared.activateFileViewerSelecting([model.paths.clone])
            }
            .disabled(model == nil)
        }
    }
}
