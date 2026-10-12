import AppKit
import Combine
import SwiftUI

/// A reader window, and the one place a session meets a window
/// (plans/reader-comforts.md §1.3).
///
/// SwiftUI makes the window from a `ReaderWindow` value. This view gives it
/// a session once AppKit says which window it is, puts the session where
/// the views inside and the menu bar find it, starts it, and lets it go
/// when the window closes. Its lifetime is the window's, not the view's:
/// SwiftUI may send `onDisappear` for a tab that is only deselected, so a
/// window's end is its `willCloseNotification`.
struct ReaderWindowView: View {
    /// The window's identity and what it was opened to show. Written only
    /// when its id cannot be used (`claim(in:)`).
    @Binding var window: ReaderWindow

    @Environment(AppModel.self) private var model
    @State private var session: ReaderSession?
    @State private var host = HostWindow()
    /// URLs from outside that came before the window had its session.
    @State private var pendingURLs: [URL] = []

    /// What macOS keeps of this window when it restores it (§1.3): the
    /// session's history, inspector and folders as `ReaderSessionState`,
    /// and apart from them the heading being read, so scrolling does not
    /// encode the history again. Declared here, where the window starts,
    /// rather than in the view that appears once the session is claimed.
    @SceneStorage("ccwiki.reader.state") private var savedState: Data?
    @SceneStorage("ccwiki.reader.anchor") private var savedAnchor: String?

    /// Readers tab only with readers, whatever the system's "Prefer tabs"
    /// setting says, and never with a paper or the explorer (§1.8).
    static let tabbingIdentifier = "ccwiki.reader"

    var body: some View {
        Group {
            if let session {
                ReaderSessionView(
                    session: session, window: window,
                    savedState: $savedState, savedAnchor: $savedAnchor)
            } else {
                // A plain background until there is a window to claim a
                // session for: no web view is made for a window that might
                // not keep its id.
                Color.clear
            }
        }
        .background {
            WindowReader { nsWindow in found(nsWindow) }
        }
        // A ccwiki:// link or a PDF from Finder goes to a reader window
        // that is already open, which SwiftUI brings forward. Otherwise
        // SwiftUI opens a new window for each.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // Here rather than in RootView, which is not there until the window
        // has its session: a URL that launches the app arrives about then.
        .onOpenURL { url in
            if let session { session.handleOpenURL(url) } else { pendingURLs.append(url) }
        }
        // The active reader, for the windows that are not readers, is the
        // one key most recently. `controlActiveState` would say as much, but
        // the macOS 15 SDK deprecates it for `appearsActive`, which macOS 14
        // lacks.
        .onReceive(Self.windowDidBecomeKey) { notification in
            guard let session, let nsWindow = hostWindow(of: notification) else { return }
            session.windowNumber = nsWindow.windowNumber
            model.sessionBecameKey(session.id)
        }
        .onReceive(Self.windowWillClose) { notification in
            guard let session, hostWindow(of: notification) != nil else { return }
            model.sessionDidClose(session.id)
        }
    }

    private static var windowDidBecomeKey: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
    }

    private static var windowWillClose: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
    }

    /// AppKit has put this view in its window. Called before the window is
    /// first shown, from inside a view update.
    private func found(_ nsWindow: NSWindow) {
        host.window = nsWindow
        nsWindow.tabbingIdentifier = Self.tabbingIdentifier
        // A window the app opened as a tab joins its group before it is
        // ever shown on its own (§1.4). Background tabs wait for the
        // maintainer's check on a Mac; until then every tab opens in front.
        if let request = model.takeTabbing(for: window.id),
           let number = request.tabbingInto,
           let source = NSApp.window(withWindowNumber: number), source !== nsWindow {
            WindowTabbing.join(
                nsWindow, to: source,
                inBackground: request.inBackground && WindowTabbing.joinsInBackground)
        }
        // Claiming changes what the model's observers read, which must not
        // happen inside the update that reported the window.
        Task { @MainActor in claim(in: nsWindow) }
    }

    /// The session for this window's id, made once. An id that is live in
    /// another window, or that closed earlier in this process, is replaced
    /// by a fresh one: this window is then a window of its own.
    private func claim(in nsWindow: NSWindow) {
        guard session == nil else { return }
        let number = nsWindow.windowNumber
        let claimed: ReaderSession
        if let forThisID = model.claimSession(for: window.id, windowNumber: number) {
            claimed = forThisID
        } else {
            window.id = UUID()
            guard let forFreshID = model.claimSession(for: window.id, windowNumber: number)
            else { return }
            claimed = forFreshID
        }
        session = claimed
        // Already key by now, most likely, and its notification gone by
        // with no session to tell.
        if nsWindow.isKeyWindow { model.sessionBecameKey(claimed.id) }
        for url in pendingURLs { claimed.handleOpenURL(url) }
        pendingURLs = []
    }

    /// The window a notification is about, when it is this view's.
    private func hostWindow(of notification: Notification) -> NSWindow? {
        guard let nsWindow = notification.object as? NSWindow, nsWindow === host.window else {
            return nil
        }
        return nsWindow
    }
}

/// The window a reader view is in, once AppKit has said. A reference, so
/// reporting it changes no view state; weak, since the window owns the view.
private final class HostWindow {
    weak var window: NSWindow?
}

/// A reader window with its session: the reader itself, the session put
/// where every view inside and the menu bar find it, and the session
/// started.
private struct ReaderSessionView: View {
    let session: ReaderSession
    let window: ReaderWindow
    @Binding var savedState: Data?
    @Binding var savedAnchor: String?

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Restoration is macOS's, and never the screenshot harness's: a capture
    /// shows what its plan says, whatever was on screen the time before.
    private var restores: Bool { ScreenshotRunner.directory == nil }

    var body: some View {
        RootView()
            .environment(session)
            // Both from the reader window, so the commands that need either
            // are enabled exactly while a reader window is key (§1.5).
            .focusedSceneValue(\.readerSession, session)
            .focusedSceneValue(\.appModel, model)
            .task { await start() }
            // `openWindow` is an environment action, so a view has to make
            // the call. The requests come from AppKit's menus and from
            // `AppModel.explore(_:)`; several windows answering one only
            // bring the explorer forward.
            .onChange(of: model.explorerWindowRequests) { _, _ in
                openWindow(id: CCwikiApp.explorerWindowID)
            }
            .onChange(of: session.restorationState) { _, state in
                guard restores else { return }
                savedState = state.encoded()
            }
            .onChange(of: session.webController.activeHeadingID) { _, heading in
                guard restores else { return }
                savedAnchor = heading
            }
    }

    /// Start the session as its plan says, then the launch, which runs once
    /// for the whole app, then the screenshot plan, which runs once too.
    /// SwiftUI may run this again when a tab is shown again; the session is
    /// started only the first time, so nothing meant for a new window is
    /// taken by an old one.
    ///
    /// A window macOS restored comes back with its history, inspector and
    /// folders, and its page where it was being read; saved state this build
    /// cannot read is ignored whole, and the window starts as a new one.
    private func start() async {
        if !session.isStarted {
            let restored = restores ? ReaderSessionState.decoded(from: savedState) : nil
            if let restored { session.restoreChrome(restored) }
            let plan = SessionStartPlan.plan(
                restored: restored, window: window,
                pending: model.takePendingReaderLocation(),
                launchDocument: model.takeLaunchDocument(),
                isColdStart: model.takeColdStart(),
                lastPage: restores ? CCwikiSettings.lastPage : nil)
            session.start(plan, readingAnchor: restored == nil ? nil : savedAnchor)
        }
        await model.launchIfNeeded()
        ScreenshotRunner.run(model: model, session: session, openWindow: openWindow)
    }
}
