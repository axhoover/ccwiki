import SwiftUI

/// App entry point. Owns the single `AppModel` and hands it to the view tree
/// through the environment.
@main
struct CCwikiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(
                    minWidth: Theme.windowMinWidth,
                    minHeight: Theme.windowMinHeight)
                // The delegate is made before the model's view exists; this is
                // the first moment both are in hand.
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(
            width: Theme.windowDefaultWidth,
            height: Theme.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands { CCwikiCommands() }

        // Jobs get their own window rather than a fourth pane: the thing you
        // actually want is to watch a job run while reading the page it is
        // going to edit.
        Window("Jobs", id: CCwikiApp.jobsWindowID) {
            JobsView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 640)
        .keyboardShortcut("j", modifiers: [.command, .shift])

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    static let jobsWindowID = "ccwiki.jobs"
}

/// The one AppKit hook SwiftUI does not offer: a say in whether the app quits.
///
/// An ingestion job is a `claude` process with `node` children, and nothing
/// but this stops them when the app goes away. Left alone they keep working
/// in the worktree and can push and open a PR nobody is watching, and the
/// next launch offers to prune a worktree they are still writing to.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.activeJobCount > 0 else { return .terminateNow }
        let count = model.activeJobCount

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "Quit and stop the running job?"
            : "Quit and stop \(count) running jobs?"
        alert.informativeText = "The agent will be stopped before it opens a pull request. "
            + "Its worktree and transcript are kept, so you can inspect or prune them later."
        alert.addButton(withTitle: count == 1 ? "Stop Job and Quit" : "Stop Jobs and Quit")
        alert.addButton(withTitle: "Don't Quit")

        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.cancelActiveJobs()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt and braces for the paths that skip the question: a job that
        // started between the alert and now, or a termination the delegate
        // was not asked about.
        model?.cancelActiveJobs()
        Subprocess.terminateAll()
    }
}

/// Menu-bar commands.
///
/// Every primary action gets a shortcut and every shortcut appears in a menu,
/// so it is discoverable rather than folklore. The actions reach the focused
/// scene through `@FocusedValue` rather than through a shared singleton.
struct CCwikiCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.findAction) private var findAction
    @FocusedValue(\.searchAction) private var searchAction
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") { model?.makeTextBigger() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model == nil)

            Button("Make Text Smaller") { model?.makeTextSmaller() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model == nil)

            Button("Actual Size") { model?.resetTextSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model == nil || model?.webController.pageZoom == 1)

            Divider()

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

            Button("Ingest a Paper…") { model?.ingestSheetPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find on Page…") { findAction?.perform() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(findAction == nil)

            Button("Find Next") { findAction?.next?() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(findAction?.next == nil)

            Button("Find Previous") { findAction?.previous?() }
                .keyboardShortcut("g", modifiers: [.shift, .command])
                .disabled(findAction?.previous == nil)

            Button("Search All Pages…") { searchAction?.perform() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(searchAction == nil)
        }

        CommandMenu("Wiki") {
            Button("Sync with GitHub") { model?.sync() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.syncState.isRunning ?? true)

            // ⇧⌘H, as in Safari. ⌘0 is "Actual Size" everywhere else on the Mac.
            Button("Go Home") { model?.openHome() }
                .keyboardShortcut("h", modifiers: [.shift, .command])
                .disabled(model == nil)

            Button("Show Sync Log…") { model?.syncLogPresented = true }
                .disabled(model == nil)

            Divider()

            Button("Open on cryptology.city") {
                guard let url = model?.currentSiteURL else { return }
                NSWorkspace.shared.open(url)
            }
            .disabled(model?.currentSiteURL == nil)

            Button("Copy Link") {
                guard let model, let url = model.currentSiteURL else { return }
                model.copyToPasteboard(url.absoluteString)
            }
            .disabled(model?.currentSiteURL == nil)

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

        CommandMenu("Jobs") {
            Button("Ingest a Paper…") { model?.ingestSheetPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button("Show Jobs") { openWindow(id: CCwikiApp.jobsWindowID) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
        }
    }
}
