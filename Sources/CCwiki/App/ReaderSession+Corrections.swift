import Foundation

// Correcting the page this window shows (plans/corrections.md §7.1, §8, §9):
// Edit Page…, Describe a Correction… and Open an Issue About This Page…,
// from the Wiki menu, the toolbar and the reader's context menu. Per
// window, because the page, its selection and its sheets are (§17).
//
// Phase 0 declares these; Track C fills them (§11.4).
extension ReaderSession {

    /// Whether the correction commands apply: a wiki page is showing, not a
    /// folder, Welcome or What's New (§3.6, §9). Blockers are explained by
    /// the sheet or the alert, never by a disabled item.
    ///
    /// Phase 0: never, so the items are there and disabled.
    var canCorrectCurrentPage: Bool { false }

    /// From the menu bar and the toolbar: reads the selection, builds the
    /// target, then opens the editor or a sheet.
    func beginCorrection(_ route: CorrectionRoute) async {
        let selection = await webController.selectionSource()
        beginCorrection(route, selection: selection)
    }

    /// From the context menu, where the selection is already in hand.
    func beginCorrection(_ route: CorrectionRoute, selection: ReaderSelection?) {
        guard canCorrectCurrentPage else { return }
    }
}
