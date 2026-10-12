import AppKit
import Observation
import SwiftUI

/// The editor's source pane: a page's Markdown, frontmatter and all, in an
/// `NSTextView` (plans/corrections.md §7.3).
///
/// AppKit's text view rather than SwiftUI's `TextEditor`, which cannot
/// select a range from code before macOS 15; the deployment target is 14.
///
/// Everything that would quietly rewrite Markdown or LaTeX is off: smart
/// quotes and dashes, text replacement, spelling correction, link and data
/// detection. Continuous spell-checking starts off too, since a page of
/// `\calA` would be underlined throughout; the context menu turns it on.
/// Undo and the find bar are AppKit's own.
///
/// The view reports, it never decides: typing goes to `onTextChange`, the
/// caret to `onCursorMove`, and the text it is given replaces what it shows
/// only when the two differ, as after a reload from disk. Its reports never
/// happen inside a view update: SwiftUI warns about state changed there.
struct SourceTextView: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    /// Lines to select and scroll to the centre, once per request.
    let reveal: SourceReveal?
    /// The window's hold on the text view: the find bar, and the caret's
    /// line and column for the status line.
    let controller: SourceTextController
    let onTextChange: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            Self.configure(textView)
            context.coordinator.attach(textView)
            controller.textView = textView
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTextChange = onTextChange
        guard let textView = coordinator.textView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if textView.string != text { coordinator.replaceText(with: text) }
        if let reveal, reveal.id != coordinator.revealedID {
            coordinator.revealedID = reveal.id
            coordinator.reveal(reveal.lines)
        }
    }

    /// Plain monospaced text that wraps to the pane, with nothing that
    /// rewrites what is typed.
    private static func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = SourceTextView.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: Theme.small, height: Theme.medium)
        // Editable once the file is loaded and the job allows it.
        textView.isEditable = false
        textView.isSelectable = true
        textView.setAccessibilityLabel("Source")
    }

    /// The system's monospaced face at the system size: the source is read
    /// closely, character by character.
    @MainActor static var font: NSFont {
        .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    /// Reports typing and the caret through notifications, as the paper's
    /// view reports its page: no delegate to conform to.
    @MainActor
    final class Coordinator: NSObject {
        var onTextChange: @MainActor (String) -> Void
        private(set) weak var textView: NSTextView?
        private let controller: SourceTextController
        /// The last reveal applied, so each is applied once.
        var revealedID: UUID?
        /// Set while the view replaces its text from code, so the change
        /// is not reported back as typing.
        private var isReplacingText = false
        private var hasFocused = false

        init(controller: SourceTextController, onTextChange: @escaping @MainActor (String) -> Void) {
            self.controller = controller
            self.onTextChange = onTextChange
        }

        func attach(_ textView: NSTextView) {
            self.textView = textView
            NotificationCenter.default.addObserver(
                self, selector: #selector(textDidChange(_:)),
                name: NSText.didChangeNotification, object: textView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification, object: textView)
        }

        /// The text from the session: the file as loaded, or as reloaded
        /// from disk. The caret stays where it was, as near as the new text
        /// allows, and undo does not reach back across the replacement.
        func replaceText(with text: String) {
            guard let textView else { return }
            isReplacingText = true
            let caret = textView.selectedRange().location
            textView.string = text
            textView.font = SourceTextView.font
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
            textView.undoManager?.removeAllActions()
            isReplacingText = false
            // After the update that replaced it.
            Task { @MainActor [weak self] in
                self?.reportCaret()
                self?.focusOnce()
            }
        }

        /// Selects `lines` and scrolls them to the centre, once the view is
        /// in its window: on open that is a moment after it is made.
        func reveal(_ lines: LineRange) {
            Task { @MainActor [weak self] in
                for _ in 0..<20 {
                    guard let self, self.textView?.window == nil else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self?.select(lines)
            }
        }

        private func select(_ lines: LineRange) {
            guard let textView,
                  let range = TextLines.utf16Range(of: lines, in: textView.string)
            else { return }
            textView.setSelectedRange(range)
            centre(range)
            focusOnce()
        }

        /// `scrollRangeToVisible` puts a range at the edge; a revealed
        /// passage belongs in the middle, with what leads to it above.
        private func centre(_ range: NSRange) {
            guard let textView else { return }
            textView.scrollRangeToVisible(range)
            guard let window = textView.window else { return }
            let caret = NSRange(location: range.location, length: 0)
            let onScreen = textView.firstRect(forCharacterRange: caret, actualRange: nil)
            guard onScreen != .zero else { return }
            let inView = textView.convert(window.convertFromScreen(onScreen), from: nil)
            let visible = textView.visibleRect
            let bottom = max(textView.bounds.height - visible.height, 0)
            let top = min(max(inView.midY - visible.height / 2, 0), bottom)
            textView.scroll(NSPoint(x: visible.origin.x, y: top))
        }

        /// The source takes the keyboard when the window first shows it, so
        /// typing starts at once.
        private func focusOnce() {
            guard !hasFocused, let textView, let window = textView.window else { return }
            hasFocused = true
            window.makeFirstResponder(textView)
        }

        @objc private func textDidChange(_ notification: Notification) {
            guard !isReplacingText, let textView else { return }
            onTextChange(textView.string)
            reportCaret()
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard !isReplacingText else { return }
            reportCaret()
        }

        private func reportCaret() {
            guard let textView else { return }
            let position = TextLines.position(
                atUTF16Offset: textView.selectedRange().location, in: textView.string)
            controller.caretMoved(line: position.line, column: position.column)
        }
    }
}

/// Lines for the source view to select and centre. Each request is new,
/// so asking again for the same lines reveals them again.
struct SourceReveal: Equatable {
    let id = UUID()
    let lines: LineRange
}

/// What an editor window holds of its source view: the caret, which the
/// status line shows and the preview follows, and the find bar, which the
/// Find menu reaches through the window's `findAction`.
@MainActor
@Observable
final class SourceTextController {
    /// 1-based.
    private(set) var line = 1
    /// 1-based, in characters.
    private(set) var column = 1
    /// Called when the caret moves to another line.
    @ObservationIgnored var onLineChange: (@MainActor (Int) -> Void)?
    @ObservationIgnored weak var textView: NSTextView?

    func caretMoved(line newLine: Int, column newColumn: Int) {
        if newColumn != column { column = newColumn }
        guard newLine != line else { return }
        line = newLine
        onLineChange?(newLine)
    }

    /// Show the find bar, or find the next or previous match: the actions
    /// the Find menu's items send.
    func performFind(_ action: NSTextFinder.Action) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        // The text finder reads the action from its sender's tag.
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }
}
