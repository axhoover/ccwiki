import PDFKit
import SwiftUI

/// A paper's pages: PDFKit's `PDFView`, continuous and vertical, fitted to
/// the window's width (plans/reader-comforts.md §2.6).
///
/// Pages stay white in dark mode, as in Preview: they are the paper, not
/// chrome. The view takes the keyboard when its window appears, so Space
/// and Page Down scroll at once. It hands its zoom actions and its page
/// changes up to the window, which shows the page and gives the View menu's
/// Zoom In, Zoom Out and Zoom to Fit something to act on. It never takes a
/// dropped file: the window does, and keeps it (§2.6).
///
/// Replacing the paper at the same path is a new view: the window keys this
/// one by the record, not the URL.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let onPageChange: @MainActor (_ index: Int, _ count: Int) -> Void
    let onZoom: @MainActor (PaperZoomAction) -> Void   // hands its actions up

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange, onZoom: onZoom)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PaperPDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.acceptsDraggedFiles = false
        view.document = PDFDocument(url: url)
        context.coordinator.loadedURL = url
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        context.coordinator.onZoom = onZoom
        // Against the URL last loaded, not the document's own: a file that
        // no longer opens leaves no document, and PDFKit may spell the URL
        // another way. Either would reload on every update, and each reload
        // reports new zoom actions, which update the view again.
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.document = PDFDocument(url: url)
        context.coordinator.reportSoon()
    }

    /// Reports the page and the zoom actions to the window's state. Never
    /// during a view update: SwiftUI warns about state changed there.
    @MainActor
    final class Coordinator: NSObject {
        var onPageChange: @MainActor (Int, Int) -> Void
        var onZoom: @MainActor (PaperZoomAction) -> Void
        /// The file the view was last given.
        var loadedURL: URL?
        private weak var view: PDFView?

        init(
            onPageChange: @escaping @MainActor (Int, Int) -> Void,
            onZoom: @escaping @MainActor (PaperZoomAction) -> Void
        ) {
            self.onPageChange = onPageChange
            self.onZoom = onZoom
        }

        func attach(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
            reportSoon()
        }

        /// After the current update: the zoom actions, then the page.
        func reportSoon() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onZoom(PaperZoomAction(
                    zoomIn: { [weak self] in self?.view?.zoomIn(nil) },
                    zoomOut: { [weak self] in self?.view?.zoomOut(nil) },
                    zoomToFit: { [weak self] in self?.view?.autoScales = true }))
                self.reportPage()
            }
        }

        @objc private func pageChanged(_ notification: Notification) {
            reportPage()
        }

        private func reportPage() {
            guard let view, let document = view.document else { return }
            let index = view.currentPage.map { document.index(for: $0) } ?? 0
            onPageChange(index, document.pageCount)
        }
    }

    /// The pages. They take the keyboard once they are in a window, so the
    /// paper scrolls with Space, Page Down and the arrows without a click
    /// first, and they are never a drop target of their own.
    final class PaperPDFView: PDFView {
        private var hasTakenFocus = false

        /// A PDF dropped on the pages is the window's to keep (Keep This PDF,
        /// Replace the PDF). AppKit gives a drop to the deepest view
        /// registered for it, and a view that refuses one does not pass it
        /// up, so with `acceptsDraggedFiles` off the pages could still stand
        /// between the drop and the window. They never register at all.
        override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasTakenFocus, window != nil else { return }
            hasTakenFocus = true
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
