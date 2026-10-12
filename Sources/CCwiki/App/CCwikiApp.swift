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
                // What the window shows is its session's, and every view in
                // it reads the session from here, never through the model
                // (plans/reader-comforts.md §1.2). The one session for now;
                // each window claims its own once the scene is
                // `WindowGroup(for: ReaderWindow.self)`.
                .environment(model.primarySession)
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

        // A paper gets a window of its own, one per paper, keyed by its
        // reference page's path: a PDF is a document, and it stays put while
        // the reader moves through the wiki (plans/reader-comforts.md §2.2).
        // After the reader's group, which has to stay the first scene:
        // SwiftUI opens the first `WindowGroup` when nothing is restored.
        WindowGroup("Paper", id: CCwikiApp.paperWindowID, for: String.self) { $referencePath in
            PaperWindowView(referencePath: referencePath)
                .environment(model)
                .frame(minWidth: Theme.paperMinWidth, minHeight: Theme.paperMinHeight)
                // A paper window restored on its own still needs the model.
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: Theme.paperDefaultWidth, height: Theme.paperDefaultHeight)
        .defaultPosition(.trailing)
        .windowResizability(.contentMinSize)
        // Never for a ccwiki:// link or a PDF from Finder: those belong to a
        // reader, and an empty paper window is no answer to either.
        .handlesExternalEvents(matching: [])
        // Nor from File ▸ New: the group's own New Paper Window item would
        // open a window with no paper. Only Show Paper opens one.
        .commandsRemoved()

        // Jobs get their own window rather than a fourth pane: the thing you
        // actually want is to watch a job run while reading the page it is
        // going to edit. Never a tab of anything (reader-comforts §1.8).
        Window("Jobs", id: CCwikiApp.jobsWindowID) {
            JobsView()
                .environment(model)
                .background { WindowReader { $0.tabbingMode = .disallowed } }
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
                .background { WindowReader { $0.tabbingMode = .disallowed } }
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
    static let paperWindowID = "ccwiki.paper"
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
///
/// Two values, both published by the key reader window: its session, for
/// everything about the page it shows, and the model, for what is app-wide
/// (sync, updates, text size, ingestion). Neither is published by Jobs, the
/// explorer, a paper or Settings, so the reader's commands are disabled there
/// (plans/reader-comforts.md §1.5).
struct CCwikiCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.readerSession) private var session
    @FocusedValue(\.findAction) private var findAction
    @FocusedValue(\.searchAction) private var searchAction
    /// Set while a paper window is key: the text-size items zoom the PDF.
    @FocusedValue(\.paperZoom) private var paperZoom
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

        // The same three keys zoom a paper while its window is key, titled
        // as Preview titles them (reader-comforts §1.5).
        CommandGroup(after: .toolbar) {
            Button(paperZoom == nil ? "Make Text Bigger" : "Zoom In") {
                if let paperZoom { paperZoom.zoomIn() } else { model?.makeTextBigger() }
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(paperZoom == nil && model == nil)

            Button(paperZoom == nil ? "Make Text Smaller" : "Zoom Out") {
                if let paperZoom { paperZoom.zoomOut() } else { model?.makeTextSmaller() }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(paperZoom == nil && model == nil)

            Button("Actual Size") {
                if let paperZoom { paperZoom.actualSize() } else { model?.resetTextSize() }
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(paperZoom == nil && (model == nil || model?.pageZoom == 1))

            Divider()

            Button("Toggle Inspector") { session?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.option, .command])
                .disabled(session == nil)

            Button("Show Outline") { session?.showInspectorTab(.outline) }
                .keyboardShortcut("1", modifiers: [.option, .command])
                .disabled(session == nil)
            Button("Show Backlinks") { session?.showInspectorTab(.backlinks) }
                .keyboardShortcut("2", modifiers: [.option, .command])
                .disabled(session == nil)
            Button("Show Relations") { session?.showInspectorTab(.relations) }
                .keyboardShortcut("3", modifiers: [.option, .command])
                .disabled(session == nil)

            Divider()

            Button("Back") { session?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session?.canGoBack != true)

            Button("Forward") { session?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session?.canGoForward != true)
        }

        CommandGroup(replacing: .newItem) {
            Button("Quick Switcher…") { session?.presentQuickSwitcher() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session == nil)

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
            Button("Find in All Pages…") { session?.grepPresented = true }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(session == nil)

            // ⌘S, because searching is the thing a reader does most and ⌘S is
            // the easiest chord to reach. It is Save by convention, but CCwiki
            // has nothing to save, and the Save slot is emptied below so no
            // default item can claim it.
            Button("Search the Wiki…") { searchAction?.perform() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(searchAction == nil)

            // ⇧⌘R, because ⌘R is Sync: reload, as in nearly every Mac app.
            Button("Search References…") { session?.referenceSearchPresented = true }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(session == nil)
        }

        // A reader has no documents: no Save, Save As, Revert or Duplicate.
        CommandGroup(replacing: .saveItem) {}

        // The page you are reading. The print panel's PDF menu is Save as PDF.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { session?.printCurrentPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(session == nil || session?.location == .empty)
        }

        // The default "CCwiki Help" item opens a help book that does not
        // exist. These are what help there is.
        CommandGroup(replacing: .help) {
            Button("Welcome to CCwiki") { session?.showWelcome() }
                .disabled(session == nil)
            Button("What's New in CCwiki") { session?.showWhatsNew() }
                .disabled(session == nil)
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
            Button("Go Home") { session?.openHome() }
                .keyboardShortcut("h", modifiers: [.shift, .command])
                .disabled(session == nil)

            Button("Show Sync Log…") { session?.syncLogPresented = true }
                .disabled(session == nil)

            Button("Random Page") { session?.openRandomPage() }
                .disabled(session == nil || model?.index == nil)

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
                guard let model, let query = session?.currentPageExplorerQuery else { return }
                model.explore(query)
                openWindow(id: CCwikiApp.explorerWindowID)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift, .option])
            .disabled(session?.canExploreCurrentPage != true)

            Divider()

            Button("Open on cryptology.city") {
                guard let url = session?.currentSiteURL else { return }
                NSWorkspace.shared.open(url)
            }
            .disabled(session?.currentSiteURL == nil)

            Button("Copy Link") {
                guard let model, let url = session?.currentSiteURL else { return }
                model.copyToPasteboard(url.absoluteString)
            }
            .disabled(session?.currentSiteURL == nil)

            Button("Copy Wikilink") {
                guard let model, let page = session?.currentPage else { return }
                model.copyToPasteboard(page.wikilink)
            }
            .disabled(session?.currentPage == nil)

            // ⌥⌘P: ⌘P is Print, and ⇧⌘P is Page Setup by convention. Out of
            // the menu until papers can be fetched.
            if ShowPaperCommand.isAvailable {
                Button("Show Paper") {
                    guard let model, let page = session?.currentPage else { return }
                    ShowPaperCommand.perform(page, model: model, openWindow: openWindow)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!ShowPaperCommand.isEnabled(for: session?.currentPage))
            }

            Divider()

            Button("Reveal Page in Finder") {
                guard let model, let page = session?.currentPage else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [model.paths.content.appending(path: page.path)])
            }
            .disabled(session?.currentPage == nil)

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
