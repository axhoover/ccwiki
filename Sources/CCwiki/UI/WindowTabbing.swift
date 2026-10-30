import AppKit
import SwiftUI

/// Making a reader window a tab of another: the one step of opening a tab
/// SwiftUI has no API for (plans/reader-comforts.md §1.4).
@MainActor
enum WindowTabbing {

    /// False until the maintainer has checked background tabs on a Mac (§1.4).
    /// Until then every new tab opens in front, whatever the caller asks.
    static let joinsInBackground: Bool = false

    /// Makes `window` a tab of `source`'s group, directly after `source`
    /// (`.above`), or directly before it (`.below`), where a closed tab goes
    /// back to its place. In the background, `source` stays the selected tab
    /// and the key window.
    ///
    /// Called when the new window's `WindowReader` first reports it. The
    /// window is hidden at once, so it never shows as a window of its own,
    /// and joins the group on the next turn of the main actor, after the
    /// view update that reported it. Moving a window into a tab group
    /// changes its frame, which inside that update is the constraint crash
    /// of `SWIFTUI-RULES` §1.1; and SwiftUI, which orders the new window in
    /// itself, should have done so by then, so it does not select the tab
    /// again after a background join (an unproven timing, §6). If `source`
    /// has closed in the meantime, `window` stays a window of its own.
    static func join(
        _ window: NSWindow, to source: NSWindow, ordered: NSWindow.OrderingMode = .above,
        inBackground: Bool
    ) {
        guard window !== source else { return }
        let background = inBackground && Self.joinsInBackground
        window.alphaValue = 0
        Task { @MainActor [weak window, weak source] in
            guard let window else { return }
            defer { window.alphaValue = 1 }
            guard let source, Self.isOpen(source) else { return }
            // A tab shares its group's identifier, so Merge All Windows and
            // Move Tab to New Window treat it as one of the group.
            window.tabbingIdentifier = source.tabbingIdentifier
            source.addTabbedWindow(window, ordered: ordered)
            if background {
                source.makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// On screen, or a tab of a group that is: a tab that is not selected is
    /// ordered out but still open. A closed window is neither.
    static func isOpen(_ window: NSWindow) -> Bool {
        window.isVisible || (window.tabbedWindows ?? []).contains { $0.isVisible }
    }
}

/// Hands the view's `NSWindow` to `onWindow` once the view is in one.
///
/// For the window settings SwiftUI has no modifier for: a tabbing mode, a
/// tab group, a frame clamped to the screen. Called from AppKit's
/// `viewDidMoveToWindow`, before the window is first shown, and again only
/// if the view moves to another window. A caller that changes SwiftUI state
/// in `onWindow` should defer that change: it runs inside a view update.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView(frame: .zero)
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onWindow = onWindow
    }

    /// An empty view that says which window it is in, and never takes a
    /// click from the view it sits behind.
    final class ReportingView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        private weak var reportedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== reportedWindow else { return }
            reportedWindow = window
            onWindow?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
