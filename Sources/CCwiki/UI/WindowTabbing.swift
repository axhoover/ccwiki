import AppKit
import SwiftUI

/// Making a reader window a tab of another: the one step of opening a tab
/// SwiftUI has no API for (plans/reader-comforts.md §1.4).
@MainActor
enum WindowTabbing {

    /// False until the maintainer has checked background tabs on a Mac (§1.4).
    static let joinsInBackground: Bool = false

    /// Makes `window` a tab of `source`'s group, directly after `source`. In
    /// the background, `source` stays the selected tab and the key window.
    ///
    /// Does nothing until Track B fills it (B3): a new tab opens as a window
    /// of its own meanwhile.
    static func join(_ window: NSWindow, to source: NSWindow, inBackground: Bool) {}
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
