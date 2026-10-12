import PDFKit
import SwiftUI

/// A paper's pages: PDFKit's `PDFView`, continuous and vertical, fitted to
/// the window's width (plans/reader-comforts.md §2.6).
///
/// Pages stay white in dark mode, as in Preview: they are the paper, not
/// chrome. The view takes the keyboard when its window appears, so Space
/// and Page Down scroll at once. It hands its zoom actions and its page
/// changes up to the window, which shows the page and gives the View menu's
/// Zoom In, Zoom Out and Actual Size something to act on.
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
        let view = FocusingPDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        context.coordinator.onZoom = onZoom
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            context.coordinator.reportSoon()
        }
    }

    /// Reports the page and the zoom actions to the window's state. Never
    /// during a view update: SwiftUI warns about state changed there.
    @MainActor
    final class Coordinator: NSObject {
        var onPageChange: @MainActor (Int, Int) -> Void
        var onZoom: @MainActor (PaperZoomAction) -> Void
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
                    actualSize: { [weak self] in self?.view?.autoScales = true }))
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

    /// Takes the keyboard once it is in a window, so the paper scrolls with
    /// Space, Page Down and the arrows without a click first.
    final class FocusingPDFView: PDFView {
        private var hasTakenFocus = false

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
