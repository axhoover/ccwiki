import SwiftUI

/// App entry point. Owns the single `AppModel` and hands it to the view tree
/// through the environment.
@main
struct CCwikiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // An id, so the explorer can open a reader when none is on screen to
        // show the page it was asked to open.
        WindowGroup(id: CCwikiApp.mainWindowID) {
            RootView()
                .modifier(ReaderWindowHooks())
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

        // The Relations Explorer, in a window of its own for the same reason:
        // you want the proof open while reading the page it is about. No
        // shortcut on the scene: ⇧⌘E is the Wiki menu's, so the key
        // equivalent lives on one menu item, not two.
        Window("Relations Explorer", id: CCwikiApp.explorerWindowID) {
            RelationsExplorerView()
                .environment(model)
        }
        .defaultSize(width: Theme.explorerDefaultWidth, height: Theme.explorerDefaultHeight)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    static let jobsWindowID = "ccwiki.jobs"
    static let explorerWindowID = "ccwiki.relations-explorer"
    static let mainWindowID = "ccwiki.main"
}

/// What a reader window does for the others: it counts itself, so the
/// explorer knows whether a page it opens will be seen, and it answers the
/// model's requests to open the explorer. `openWindow` is an environment
/// action, so a view has to make the call; the requests come from AppKit's
/// menus and from `AppModel.explore(_:)`. The Jobs window's requests are
/// answered the same way, in `RootView`.
private struct ReaderWindowHooks: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear { model.mainWindowCount += 1 }
            .onDisappear { model.mainWindowCount -= 1 }
            .onChange(of: model.explorerWindowRequests) { _, _ in
                openWindow(id: CCwikiApp.explorerWindowID)
            }
    }
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
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model?.checkForUpdates() }
                .disabled(model == nil || model?.isCheckingForUpdates == true
                    || model?.isInstallingUpdate == true)

            if let installed = model?.installedUpdate {
                Button("Relaunch to Update to \(installed.version)") { model?.relaunchToUpdate() }
            }
        }

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

            Button("Show Outline") { model?.showInspectorTab(.outline) }
                .keyboardShortcut("1", modifiers: [.option, .command])
                .disabled(model == nil)
            Button("Show Backlinks") { model?.showInspectorTab(.backlinks) }
                .keyboardShortcut("2", modifiers: [.option, .command])
                .disabled(model == nil)
            Button("Show Relations") { model?.showInspectorTab(.relations) }
                .keyboardShortcut("3", modifiers: [.option, .command])
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

            // ⇧⌘F, as Find in Project is in Xcode: the literal text, everywhere.
            Button("Find in All Pages…") { model?.grepPresented = true }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(model == nil)

            // ⌘S, because searching is the thing a reader does most and ⌘S is
            // the easiest chord to reach. It is Save by convention, but CCwiki
            // has nothing to save, and the Save slot is emptied below so no
            // default item can claim it.
            Button("Search the Wiki…") { searchAction?.perform() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(searchAction == nil)

            // ⇧⌘R, because ⌘R is Sync: reload, as in nearly every Mac app.
            Button("Search References…") { model?.referenceSearchPresented = true }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(model == nil)
        }

        // A reader has no documents: no Save, Save As, Revert or Duplicate.
        CommandGroup(replacing: .saveItem) {}

        // The page you are reading. The print panel's PDF menu is Save as PDF.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.printCurrentPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model == nil || model?.location == .empty)
        }

        // The default "CCwiki Help" item opens a help book that does not
        // exist. These are what help there is.
        CommandGroup(replacing: .help) {
            Button("Welcome to CCwiki") { model?.showWelcome() }
                .disabled(model == nil)
            Button("What's New in CCwiki") { model?.showWhatsNew() }
                .disabled(model == nil)
            Divider()
            Button("Report an Issue…") {
                if let url = URL(string: "https://github.com/axhoover/ccwiki/issues/new") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("CCwiki on GitHub") {
                if let url = URL(string: "https://github.com/axhoover/ccwiki") {
                    NSWorkspace.shared.open(url)
                }
            }
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

            Button("Random Page") { model?.openRandomPage() }
                .disabled(model?.index == nil)

            Divider()

            // ⇧⌘E, the shape of ⇧⌘J for the other secondary window; E for
            // explore. It opens the window directly, as Show Jobs does, so it
            // works whichever window is key.
            Button("Relations Explorer") { openWindow(id: CCwikiApp.explorerWindowID) }
                .keyboardShortcut("e", modifiers: [.command, .shift])

            // ⌥⇧⌘E: the Option form is the "this page" variant. It needs the
            // reader's page, so it is disabled unless a reader window is key
            // and its page has something to explore.
            Button("Explore From This Page") {
                guard let model, let query = model.currentPageExplorerQuery else { return }
                model.explore(query)
                openWindow(id: CCwikiApp.explorerWindowID)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift, .option])
            .disabled(model?.canExploreCurrentPage != true)

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

            Button("Copy Wikilink") {
                guard let model, let page = model.currentPage else { return }
                model.copyToPasteboard(page.wikilink)
            }
            .disabled(model?.currentPage == nil)

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
