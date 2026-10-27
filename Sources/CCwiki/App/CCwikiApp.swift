import SwiftUI

/// App entry point. Owns the single `AppModel` and hands it to the view tree
/// through the environment.
@main
struct CCwikiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // A reader window or tab, each with a session of its own
        // (plans/reader-comforts.md §1.3). The value is the window's identity
        // and where it opens. Every value is new, so opening one always
        // opens a window; the default is new too, and opens Home, for a
        // window SwiftUI opens by itself. The id lets the explorer open a
        // reader when none is on screen to show the page it was asked to
        // open.
        WindowGroup(id: CCwikiApp.mainWindowID, for: ReaderWindow.self) { $window in
            ReaderWindowView(window: $window)
                .environment(model)
                .frame(
                    minWidth: Theme.windowMinWidth,
                    minHeight: Theme.windowMinHeight)
                // The delegate is made before the model's view exists; this is
                // the first moment both are in hand.
                .onAppear { appDelegate.model = model }
        } defaultValue: {
            ReaderWindow()
        }
        .defaultSize(
            width: Theme.windowDefaultWidth,
            height: Theme.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CCwikiCommands(appModel: model)
            UndoCloseTabCommands(appModel: model)
        }

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
                // The view itself runs the launch and sets the tabbing
                // identifier that keeps papers out of a reader's tabs.
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

        // An editor gets a window of its own, one per file of a job, as a
        // document does (plans/corrections.md §7.2), restored with the job
        // it edits. After the reader's group, for the reason the paper's is.
        WindowGroup("Edit Page", id: CCwikiApp.editorWindowID, for: EditorTarget.self) { $target in
            EditorWindow(target: target)
                .environment(model)
                // Editors tab with editors, never with readers (§17).
                .background {
                    WindowReader { $0.tabbingIdentifier = EditorWindow.tabbingIdentifier }
                }
                // Restored with no reader window, an editor still needs git,
                // and a quit with unsaved text still has to ask (§17).
                .onAppear { appDelegate.model = model }
                .task { await model.launchIfNeeded() }
        }
        .defaultSize(width: Theme.editorDefaultWidth, height: Theme.editorDefaultHeight)
        .windowResizability(.contentMinSize)
        // Never for a ccwiki:// link or a PDF: those belong to a reader.
        .handlesExternalEvents(matching: [])
        // Nor from File ▸ New, which would open an editor with no file.
        .commandsRemoved()

        // Jobs get their own window rather than a fourth pane: the thing you
        // actually want is to watch a job run while reading the page it is
        // going to edit. Never a tab of anything (reader-comforts §1.8).
        Window("Jobs", id: CCwikiApp.jobsWindowID) {
            JobsView()
                .environment(model)
                .background { WindowReader { $0.tabbingMode = .disallowed } }
                // A review restored with no reader window still needs git,
                // and a quit with a publishing job still has to ask
                // (corrections §17).
                .onAppear { appDelegate.model = model }
                .task { await model.launchIfNeeded() }
        }
        .defaultSize(width: Theme.jobsDefaultWidth, height: Theme.jobsDefaultHeight)
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
    static let editorWindowID = "ccwiki.editor"
    static let explorerWindowID = "ccwiki.relations-explorer"
    static let mainWindowID = "ccwiki.main"
    static let paperWindowID = "ccwiki.paper"
}

/// The one AppKit hook SwiftUI does not offer: a say in whether the app quits.
///
/// An ingestion or correction job is a `claude` process with `node`
/// children, and nothing but this stops them when the app goes away. Left
/// alone they keep working in the worktree, and the next launch offers to
/// prune a worktree they are still writing to. A job awaiting review is not
/// running anything, so a quit never asks about it, and it survives the
/// relaunch (plans/corrections.md §4.3).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        // Agents are stopped; a publish is interrupted and goes back to
        // review. Counted apart, because they lose different things.
        let publishing = model.jobCenter.publishingCount
        let agents = model.activeJobCount - publishing
        if let wording = StopJobsWording.make(
            agents: agents, publishing: publishing, action: "quit", verb: "Quit",
            agentsMessage: agents == 1
                ? "Quit and stop the running job?"
                : "Quit and stop \(agents) running jobs?") {
            guard wording.confirm() else { return .terminateCancel }
            model.cancelActiveJobs()
        }

        // Text typed into an editor is saved before the app goes. SwiftUI
        // does not reliably run `onDisappear` during termination, so this is
        // the only dependable save (corrections §7.5).
        guard model.hasUnsavedEdits else { return .terminateNow }
        Task { @MainActor in
            await model.flushAllEditors()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
/// (sync, updates, text size). Neither is published by Jobs, the explorer, a
/// paper or Settings, so the reader's commands are disabled there
/// (plans/reader-comforts.md §1.5). Ingest a Paper is the exception: the
/// Jobs window offers it as ⇧⌘N, so it takes the app's model and works
/// whichever window is key.
struct CCwikiCommands: Commands {
    /// The app's model, for the commands that work in every window.
    let appModel: AppModel

    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.readerSession) private var session
    @FocusedValue(\.findAction) private var findAction
    @FocusedValue(\.searchAction) private var searchAction
    /// Set while a paper window is key: the text-size items zoom the PDF.
    @FocusedValue(\.paperZoom) private var paperZoom
    /// Review Changes, from an editor window, and Open Draft PR, from the
    /// Jobs window (plans/corrections.md §9). Nil elsewhere.
    @FocusedValue(\.reviewChangesAction) private var reviewChangesAction
    @FocusedValue(\.openDraftPRAction) private var openDraftPRAction
    @FocusedValue(\.proofCopyAction) private var proofCopyAction
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
        // for what they do there. ⌘0 fits the PDF to the window again, as it
        // opened, so it is Zoom to Fit: Actual Size means 100% in Preview
        // (reader-comforts §1.5).
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

            Button(paperZoom == nil ? "Actual Size" : "Zoom to Fit") {
                if let paperZoom { paperZoom.zoomToFit() } else { model?.resetTextSize() }
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
            // A window of its own at Home, whichever window is key: only the
            // first window of a launch opens the page read last (§1.7).
            Button("New Window") {
                openWindow(id: CCwikiApp.mainWindowID, value: ReaderWindow())
            }
            .keyboardShortcut("n", modifiers: .command)

            // At Home too, as a tab of the key reader window, in front, as
            // in Safari. While the explorer, Jobs or a paper is key there is
            // no reader to join, and it is a window of its own (§1.8).
            Button("New Tab") {
                let window = ReaderWindow()
                if let model, let request = ReaderWindowRequest(
                    opening: window, as: .newTab(inBackground: false),
                    beside: session?.hostWindowNumber) {
                    model.expectReaderWindow(request)
                }
                openWindow(id: CCwikiApp.mainWindowID, value: window)
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("Quick Switcher…") { session?.presentQuickSwitcher() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session == nil)

            Button("Ingest a Paper…") { ingestAPaper() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Copy Proof As ▸ Text, LaTeX (⌥⌘C), Wiki Markdown (⌥⇧⌘C): the
        // Relations Explorer's proof, so disabled in every other window.
        CommandGroup(after: .pasteboard) {
            ProofCopyCommandItems(action: proofCopyAction)
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

            // ⌘D, Safari's key for a bookmark. The page, not the section
            // being read; the sidebar's Saved section lists it in every
            // window (plans/efficiency.md §3.3).
            Button(isCurrentPageSaved ? "Remove from Saved" : "Save Page") {
                guard let model, let page = session?.currentPage else { return }
                model.toggleSaved(page)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(session?.currentPage == nil)

            // The saved pages for the keyboard, as Safari's Bookmarks menu
            // lists its bookmarks: the sidebar's rows are buttons, which ↑
            // and ↓ skip. A section reads "Page § Heading", and once it is
            // no longer on its page, opens the page at its top. A page the
            // wiki no longer has is dimmed here, as its row is.
            Menu("Saved Pages") {
                ForEach(model?.savedPages.entries ?? []) { entry in
                    Button(entry.menuTitle) {
                        session?.open(.page(path: entry.path, anchor: entry.anchorToOpen), .here)
                    }
                    .disabled(model?.index?.pages[entry.path] == nil)
                }
            }
            .disabled(session == nil || model?.savedPages.isEmpty != false)

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

            // ⌥⌘P: ⌘P is Print, and ⇧⌘P is Page Setup by convention.
            Button("Show Paper") {
                guard let model, let page = session?.currentPage else { return }
                ShowPaperCommand.perform(page, model: model, openWindow: openWindow)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!ShowPaperCommand.isEnabled(for: session?.currentPage))

            Divider()

            // Correcting the page being read (plans/corrections.md §9). The
            // titles stay fixed; each carries whatever is selected. ⌥⌘E:
            // ⌘E is Use Selection for Find, ⇧⌘E the Relations Explorer.
            Button("Edit Page…") { beginCorrection(.edit) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(session?.canCorrectCurrentPage != true)

            Button("Describe a Correction…") { beginCorrection(.describe) }
                .disabled(session?.canCorrectCurrentPage != true)

            Button("Open an Issue About This Page…") { beginCorrection(.issue) }
                .disabled(session?.canCorrectCurrentPage != true)

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
            Button("Ingest a Paper…") { ingestAPaper() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Show Jobs") { openWindow(id: CCwikiApp.jobsWindowID) }
                .keyboardShortcut("j", modifiers: [.command, .shift])

            Divider()

            // ⌘↩, only in an editor window: elsewhere it is a sheet's own
            // default button (corrections §9).
            Button("Review Changes") { reviewChangesAction?.perform() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(reviewChangesAction?.isEnabled != true)

            // No shortcut: Review Changes brings Jobs forward on the job, so
            // two presses from the editor would publish.
            Button("Open Draft PR") { openDraftPRAction?.perform() }
                .disabled(openDraftPRAction?.isEnabled != true)
        }
    }

    /// Whether the key reader's page is saved, which turns Save Page into
    /// Remove from Saved.
    private var isCurrentPageSaved: Bool {
        guard let model, let page = session?.currentPage else { return false }
        return model.isSaved(page.path)
    }

    /// A correction of the key reader's page, which carries what is selected
    /// on it.
    private func beginCorrection(_ route: CorrectionRoute) {
        guard let session else { return }
        Task { await session.beginCorrection(route) }
    }

    /// File ▸ and Jobs ▸ Ingest a Paper…: on the key reader, else the
    /// active one.
    private func ingestAPaper() {
        IngestCommand.perform(in: session?.id, model: appModel, openWindow: openWindow)
    }
}

/// Edit ▸ Undo Close Tab (⌘Z): the tab or window closed last, opened again,
/// as Safari's Undo Close Tab does (plans/reader-comforts.md §7).
///
/// Commands of their own, beside `CCwikiCommands`, whose body already
/// holds the ten groups a `CommandsBuilder` block can be counted on to
/// take.
struct UndoCloseTabCommands: Commands {
    let appModel: AppModel

    @FocusedValue(\.readerSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // An item of its own after Undo and Redo, which stay AppKit's: Undo
        // goes down the responder chain to the first responder's undo
        // manager, so text keeps ⌘Z whenever it has typing to undo. AppKit
        // gives a key equivalent to the first enabled item that has it, so
        // this item gets ⌘Z only while Undo is disabled, and it is itself
        // disabled while editable text has the keyboard.
        CommandGroup(after: .undoRedo) {
            Button("Undo Close Tab") { reopenClosedTab() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!appModel.canReopenClosedTab)
        }
    }

    /// A tab of the key reader window, else a window of its own. With
    /// nothing to open, as when text took the keyboard since the menu was
    /// last brought up to date, a beep, as AppKit gives for an Undo with
    /// nothing to undo.
    private func reopenClosedTab() {
        guard let window = appModel.reopenClosedTab(beside: session?.hostWindowNumber) else {
            NSSound.beep()
            return
        }
        openWindow(id: CCwikiApp.mainWindowID, value: window)
    }
}

/// Ingest a Paper, from the menus or the Jobs window: the sheet goes on the
/// reader that asked, else the active one, which comes forward
/// (plans/reader-comforts.md §1.8).
enum IngestCommand {

    /// With no reader open, one is opened to show the sheet, as the explorer
    /// opens one for a page. A request left waiting would show nothing now,
    /// then come up in whichever reader opened next, where it would turn
    /// away a PDF opened from Finder.
    @MainActor static func perform(
        in session: UUID?, model: AppModel, openWindow: OpenWindowAction
    ) {
        model.requestIngestSheet(in: session)
        guard model.mainWindowCount == 0 else { return }
        openWindow(id: CCwikiApp.mainWindowID, value: ReaderWindow())
    }
}

/// A command a window offers the Jobs menu: Review Changes from an editor,
/// Open Draft PR from the Jobs window (plans/corrections.md §9). Published
/// with `focusedSceneValue`; the item is disabled where none is.
struct JobCommandAction: Equatable {
    /// False where the command applies but cannot run now, as Open Draft
    /// PR with a blocking finding.
    let isEnabled: Bool
    let perform: () -> Void
    private let id = UUID()

    init(isEnabled: Bool = true, perform: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.perform = perform
    }

    static func == (lhs: JobCommandAction, rhs: JobCommandAction) -> Bool {
        lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled
    }
}

// `@Entry` on a FocusedValues property is macOS 15; this is the macOS 14 form.
private struct ReviewChangesActionKey: FocusedValueKey {
    typealias Value = JobCommandAction
}

private struct OpenDraftPRActionKey: FocusedValueKey {
    typealias Value = JobCommandAction
}

extension FocusedValues {
    var reviewChangesAction: JobCommandAction? {
        get { self[ReviewChangesActionKey.self] }
        set { self[ReviewChangesActionKey.self] = newValue }
    }

    var openDraftPRAction: JobCommandAction? {
        get { self[OpenDraftPRActionKey.self] }
        set { self[OpenDraftPRActionKey.self] = newValue }
    }
}
